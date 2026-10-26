import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'capture_metadata.dart';
import 'exposure.dart';
import 'metering.dart';
import 'multi_spot.dart';
import 'spot_servo.dart';
import 'tone_curve.dart';

/// How far a live reading can be trusted.
enum LiveReadingQuality {
  /// The patch sits close enough to mid grey that the reading is essentially
  /// the exposure itself.
  good,

  /// Usable, but the patch is far enough off mid grey that the correction is
  /// doing real work and the tone curve's shape starts to matter.
  fair,

  /// The patch is crushed or clipped. Nothing derived from it is meaningful.
  unusable,
}

/// A scene EV reading derived from a single preview frame.
@immutable
class LiveReading {
  const LiveReading({
    required this.sceneEv100,
    required this.cameraEv100,
    required this.correctionStops,
    required this.slope,
    required this.encodedLuminance,
    required this.quality,
    required this.aeConverged,
    this.usedToneCurve = false,
  });

  /// Scene brightness at ISO 100, before calibration.
  final double sceneEv100;

  /// EV₁₀₀ the camera's own exposure corresponds to.
  final double cameraEv100;

  /// Stops of correction applied for the patch not sitting on mid grey.
  final double correctionStops;

  /// Stops per encoded unit used for that correction (diagnostic).
  final double slope;

  final double encodedLuminance;
  final LiveReadingQuality quality;

  /// Whether auto-exposure had settled for this frame.
  final bool aeConverged;

  /// Whether the residual was inverted with a measured [ToneCurve].
  final bool usedToneCurve;

  /// Rough bound on the error, in stops.
  ///
  /// Near mid grey the exposure itself is the reading, so slope error barely
  /// matters. A measured curve is better than a global slope, which is better
  /// than the sRGB prior.
  double get estimatedErrorStops {
    if (!correctionStops.isFinite) return double.infinity;
    final fraction = usedToneCurve
        ? 0.08
        : (slopeIsUnknown ? 0.25 : 0.12);
    return math.max(0.05, correctionStops.abs() * fraction);
  }

  bool get slopeIsUnknown => slope.isNaN;
}

/// Derives scene EV from every preview frame, continuously.
///
/// The camera is already doing the hard part. Pointing auto-exposure at the
/// metered spot makes it drive that spot towards mid grey by itself, and the
/// capture metadata reports what exposure it settled on — so a reading is
/// available on every frame, with no measurement cycle to run.
///
/// Residual correction converts “the patch is not exactly mid grey” into
/// stops. That conversion is done in **log luminance** (true stops), not as
/// `(encoded − target) × slope`, which is only a first-order tangent and was
/// already ~0.1 EV off at the edge of the “good” band. When a measured
/// [ToneCurve] covers the patch it is used instead of sRGB.
///
/// Slope is learned only while auto-exposure is hunting. Pairing settled
/// frames from different scenes looks like a pipeline slope and is not.
class LiveMeter {
  LiveMeter();

  /// Encoded value auto-exposure aims a metered spot at.
  static const double target = SpotServo.defaultTargetEncoded;

  /// Beyond this distance from target the reading is only fair.
  static const double fairBand = 0.12;

  /// Outside this the patch is crushed or clipped unless a tone curve covers
  /// the value. 0.13 encoded on a real phone was 1.5 stops off sRGB; refusing
  /// it is more accurate than inventing a number.
  static const double usableMin = 0.20;
  static const double usableMax = 0.78;

  /// Band in which exposure-vs-encoding pairs are worth learning from.
  static const double _learnMin = 0.22;
  static const double _learnMax = 0.72;

  /// Observations used to measure the device's response slope.
  final List<ServoObservation> _slopeSamples = [];

  /// Enough to average out noise, few enough to stay current as the scene
  /// changes.
  static const int _maxSlopeSamples = 12;

  double? _learnedSlope;
  bool _hunting = false;

  /// Slope currently in use, in stops per encoded unit at mid grey.
  double get slope => _learnedSlope ?? SpotServo.srgbSlopeAt(target);

  /// Whether the slope has been measured rather than assumed.
  bool get slopeIsMeasured => _learnedSlope != null;

  /// Records a frame so the slope can be learned from it.
  ///
  /// [cameraEv100] stands in for exposure: a lower metered EV means more light
  /// was let in, which is the same axis exposure compensation moves along.
  void observe({
    required double cameraEv100,
    required double encodedLuminance,
    bool aeConverged = true,
  }) {
    if (!cameraEv100.isFinite || !encodedLuminance.isFinite) return;
    if (encodedLuminance < _learnMin || encodedLuminance > _learnMax) return;

    // Settled frames from different scenes must not be paired. Hunt windows
    // are the only time exposure and encoding move as one pipeline.
    if (aeConverged) {
      _hunting = false;
      return;
    }
    if (!_hunting) {
      _slopeSamples.clear();
      _hunting = true;
    }

    _slopeSamples.add(
      ServoObservation(
        // Negated so that "more exposure" increases with the patch brightening,
        // which is the sign convention the slope estimator expects.
        appliedOffset: -cameraEv100,
        encodedLuminance: encodedLuminance,
      ),
    );
    if (_slopeSamples.length > _maxSlopeSamples) {
      _slopeSamples.removeAt(0);
    }

    final servo = SpotServo();
    for (final sample in _slopeSamples) {
      servo.record(sample);
    }
    final measured = servo.measuredSlope();
    if (measured != null) {
      // Ease towards the new estimate; a single noisy pair should not move the
      // slope far.
      final previous = _learnedSlope;
      _learnedSlope =
          previous == null ? measured : previous + (measured - previous) * 0.3;
    }
  }

  /// Scene EV for a frame, or null when the patch cannot support a reading.
  LiveReading? read({
    required CaptureMetadata metadata,
    required SpotSample sample,
    ToneCurve? curve,
  }) {
    final cameraEv = metadata.ev100;
    if (cameraEv == null || !cameraEv.isFinite) return null;
    return _read(
      cameraEv: cameraEv,
      sample: sample,
      aeConverged: metadata.aeConverged ?? false,
      curve: curve,
      learn: true,
    );
  }

  /// Encoded values at or beyond these are crushed or blown: the true level
  /// lies further out than any number derived from them.
  static const double clippedLow = 0.04;
  static const double clippedHigh = 0.97;

  /// Scene EV for any encoded luma under a given camera exposure.
  ///
  /// Uses exactly the tone model the main reading uses, but never learns from
  /// the value and never rejects it: the multi-spot view wants the darkest and
  /// brightest places in the frame, and those are usually outside the band a
  /// single reading would trust. [MultiSpotTrust] says how far to believe it.
  ({double ev100, MultiSpotTrust trust})? readEncoded({
    required double cameraEv100,
    required double encoded,
    ToneCurve? curve,
  }) {
    if (!cameraEv100.isFinite || !encoded.isFinite) return null;

    // Half a code value above zero: pure black has no finite log luminance.
    final e = encoded.clamp(0.5 / 255.0, 1.0).toDouble();
    final linear = _linearFor(e, curve);
    if (linear == null || linear <= 0 || !linear.isFinite) return null;

    final ev = cameraEv100 + ExposureMath.log2(linear / ExposureMath.middleGrey);

    final MultiSpotTrust trust;
    if (e <= clippedLow || e >= clippedHigh) {
      trust = MultiSpotTrust.clipped;
    } else if ((curve?.coversEncoded(e) ?? false) ||
        (e >= usableMin && e <= usableMax)) {
      trust = MultiSpotTrust.good;
    } else {
      trust = MultiSpotTrust.approximate;
    }
    return (ev100: ev, trust: trust);
  }

  /// Scene EV without capture metadata, from a still capture's exposure.
  ///
  /// The fallback for iOS and for Android builds without the forked plugin.
  /// Same arithmetic, but the exposure is whatever the last still reported
  /// rather than this frame's own.
  LiveReading? readFromParams({
    required ExposureParams params,
    required SpotSample sample,
    ToneCurve? curve,
  }) {
    final cameraEv = params.ev100;
    if (!cameraEv.isFinite) return null;
    return _read(
      cameraEv: cameraEv,
      sample: sample,
      aeConverged: true,
      curve: curve,
      learn: false,
    );
  }

  LiveReading? _read({
    required double cameraEv,
    required SpotSample sample,
    required bool aeConverged,
    ToneCurve? curve,
    required bool learn,
  }) {
    final encoded = sample.encodedLuminance;
    if (!encoded.isFinite) return null;

    if (learn) {
      observe(
        cameraEv100: cameraEv,
        encodedLuminance: encoded,
        aeConverged: aeConverged,
      );
    }

    final coveredByCurve = curve != null && curve.coversEncoded(encoded);
    if (!coveredByCurve &&
        (encoded < usableMin || encoded > usableMax)) {
      return LiveReading(
        sceneEv100: double.nan,
        cameraEv100: cameraEv,
        correctionStops: double.nan,
        slope: slope,
        encodedLuminance: encoded,
        quality: LiveReadingQuality.unusable,
        aeConverged: aeConverged,
      );
    }

    final linear = _linearFor(encoded, curve);
    if (linear == null || linear <= 0 || !linear.isFinite) {
      return LiveReading(
        sceneEv100: double.nan,
        cameraEv100: cameraEv,
        correctionStops: double.nan,
        slope: slope,
        encodedLuminance: encoded,
        quality: LiveReadingQuality.unusable,
        aeConverged: aeConverged,
        usedToneCurve: coveredByCurve,
      );
    }

    final correction =
        ExposureMath.log2(linear / ExposureMath.middleGrey);
    final residual = encoded - target;
    final quality = residual.abs() <= fairBand
        ? LiveReadingQuality.good
        : LiveReadingQuality.fair;

    return LiveReading(
      sceneEv100: cameraEv + correction,
      cameraEv100: cameraEv,
      correctionStops: correction,
      slope: slope,
      encodedLuminance: encoded,
      quality: quality,
      aeConverged: aeConverged,
      usedToneCurve: coveredByCurve,
    );
  }

  /// Linear luminance of [encoded], from a measured curve when it covers the
  /// point, otherwise sRGB with the learned mid-grey slope as contrast.
  double? _linearFor(double encoded, ToneCurve? curve) {
    final fromCurve = curve?.linearFor(encoded);
    if (fromCurve != null) return fromCurve;

    final srgb = ExposureMath.srgbToLinear(encoded.clamp(0.0, 1.0));
    if (srgb <= 0) return null;
    final prior = SpotServo.srgbSlopeAt(target);
    final scale = slope / prior;
    if (!scale.isFinite || scale <= 0) return srgb;
    // L = 0.18 · (srgb / 0.18)^scale. scale = 1 is plain sRGB; larger is a
    // contrastier S-curve around mid grey, which is what phones do.
    final ratio = srgb / ExposureMath.middleGrey;
    return ExposureMath.middleGrey * math.pow(ratio, scale);
  }

  /// Forgets the learned slope, for when the camera or scene changes enough
  /// that past observations no longer describe it.
  void reset() {
    _slopeSamples.clear();
    _learnedSlope = null;
    _hunting = false;
  }

  /// Smoothing factor for the displayed value.
  ///
  /// Heavier when the reading is settled, lighter while auto-exposure is still
  /// moving, so the number tracks a re-aim quickly but does not jitter once
  /// pointed.
  static double smoothingFor(LiveReading reading) {
    if (!reading.aeConverged) return 0.55;
    return reading.quality == LiveReadingQuality.good ? 0.22 : 0.35;
  }

  /// Nudges [previous] towards [next] by the appropriate amount.
  static double smooth(double? previous, double next, LiveReading reading) {
    if (previous == null || !previous.isFinite) return next;
    if (!next.isFinite) return previous;
    final factor = smoothingFor(reading);
    final blended = previous + (next - previous) * factor;
    // A large jump means the scene really did change; snap rather than crawl.
    return (next - previous).abs() > 1.5 ? next : blended;
  }

  static double log2(double x) => math.log(x) / ExposureMath.ln2;
}
