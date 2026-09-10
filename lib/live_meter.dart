import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'capture_metadata.dart';
import 'exposure.dart';
import 'metering.dart';
import 'spot_servo.dart';

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
  });

  /// Scene brightness at ISO 100, before calibration.
  final double sceneEv100;

  /// EV₁₀₀ the camera's own exposure corresponds to.
  final double cameraEv100;

  /// Stops of correction applied for the patch not sitting on mid grey.
  final double correctionStops;

  /// Stops per encoded unit used for that correction.
  final double slope;

  final double encodedLuminance;
  final LiveReadingQuality quality;

  /// Whether auto-exposure had settled for this frame.
  final bool aeConverged;

  /// Rough bound on the error, in stops.
  ///
  /// Slope uncertainty only ever acts on the correction, so a reading taken
  /// near mid grey is accurate almost regardless of how wrong the slope is.
  double get estimatedErrorStops => (correctionStops * 0.3).abs();
}

/// Derives scene EV from every preview frame, continuously.
///
/// The camera is already doing the hard part. Pointing auto-exposure at the
/// metered spot makes it drive that spot towards mid grey by itself, and the
/// capture metadata reports what exposure it settled on — so a reading is
/// available on every frame, with no measurement cycle to run.
///
/// This replaces an explicit servo that stepped exposure compensation and
/// waited for each step to settle. That loop reached the same place several
/// seconds later, because it was re-deriving what auto-exposure had already
/// worked out.
///
/// What remains necessary is the residual correction: auto-exposure aims for
/// mid grey but rarely lands exactly there, and the gap has to be converted
/// from encoded units into stops. The slope for that is measured from the
/// device's own behaviour as exposure moves, so no tone curve is assumed.
class LiveMeter {
  LiveMeter();

  /// Encoded value auto-exposure aims a metered spot at.
  static const double target = SpotServo.defaultTargetEncoded;

  /// Beyond this distance from target the reading is only fair.
  static const double fairBand = 0.16;

  /// Outside this the patch is crushed or clipped; nothing survives.
  static const double usableMin = 0.06;
  static const double usableMax = 0.88;

  /// Observations used to measure the device's response slope.
  ///
  /// Auto-exposure moving in response to a re-aim produces exactly the pairs
  /// needed — a known change in exposure against an observed change in
  /// encoding — so the slope is learned from ordinary use rather than from a
  /// dedicated calibration.
  final List<ServoObservation> _slopeSamples = [];

  /// Enough to average out noise, few enough to stay current as the scene
  /// changes.
  static const int _maxSlopeSamples = 12;

  double? _learnedSlope;

  /// Slope currently in use, in stops per encoded unit.
  double get slope =>
      _learnedSlope ?? SpotServo.srgbSlopeAt(target);

  /// Whether the slope has been measured rather than assumed.
  bool get slopeIsMeasured => _learnedSlope != null;

  /// Records a frame so the slope can be learned from it.
  ///
  /// [cameraEv100] stands in for exposure: a lower metered EV means more light
  /// was let in, which is the same axis exposure compensation moves along.
  void observe({
    required double cameraEv100,
    required double encodedLuminance,
  }) {
    if (!cameraEv100.isFinite || !encodedLuminance.isFinite) return;
    if (encodedLuminance <= 0 || encodedLuminance >= 1) return;

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
  }) {
    final cameraEv = metadata.ev100;
    if (cameraEv == null || !cameraEv.isFinite) return null;

    final encoded = sample.encodedLuminance;
    if (!encoded.isFinite) return null;

    observe(cameraEv100: cameraEv, encodedLuminance: encoded);

    if (encoded < usableMin || encoded > usableMax) {
      return LiveReading(
        sceneEv100: double.nan,
        cameraEv100: cameraEv,
        correctionStops: double.nan,
        slope: slope,
        encodedLuminance: encoded,
        quality: LiveReadingQuality.unusable,
        aeConverged: metadata.aeConverged ?? false,
      );
    }

    final residual = encoded - target;
    final correction = residual * slope;

    return LiveReading(
      sceneEv100: cameraEv + correction,
      cameraEv100: cameraEv,
      correctionStops: correction,
      slope: slope,
      encodedLuminance: encoded,
      quality: residual.abs() <= fairBand
          ? LiveReadingQuality.good
          : LiveReadingQuality.fair,
      aeConverged: metadata.aeConverged ?? false,
    );
  }

  /// Scene EV without capture metadata, from a still capture's exposure.
  ///
  /// The fallback for iOS and for Android builds without the forked plugin.
  /// Same arithmetic, but the exposure is whatever the last still reported
  /// rather than this frame's own.
  LiveReading? readFromParams({
    required ExposureParams params,
    required SpotSample sample,
  }) {
    final cameraEv = params.ev100;
    if (!cameraEv.isFinite) return null;

    final encoded = sample.encodedLuminance;
    if (!encoded.isFinite) return null;

    if (encoded < usableMin || encoded > usableMax) {
      return LiveReading(
        sceneEv100: double.nan,
        cameraEv100: cameraEv,
        correctionStops: double.nan,
        slope: slope,
        encodedLuminance: encoded,
        quality: LiveReadingQuality.unusable,
        aeConverged: true,
      );
    }

    final residual = encoded - target;
    final correction = residual * slope;

    return LiveReading(
      sceneEv100: cameraEv + correction,
      cameraEv100: cameraEv,
      correctionStops: correction,
      slope: slope,
      encodedLuminance: encoded,
      quality: residual.abs() <= fairBand
          ? LiveReadingQuality.good
          : LiveReadingQuality.fair,
      aeConverged: true,
    );
  }

  /// Forgets the learned slope, for when the camera or scene changes enough
  /// that past observations no longer describe it.
  void reset() {
    _slopeSamples.clear();
    _learnedSlope = null;
  }

  /// Smoothing factor for the displayed value.
  ///
  /// Heavier when the reading is settled, lighter while auto-exposure is still
  /// moving, so the number tracks a re-aim quickly but does not jitter once
  /// pointed.
  static double smoothingFor(LiveReading reading) {
    if (!reading.aeConverged) return 0.5;
    return reading.quality == LiveReadingQuality.good ? 0.25 : 0.35;
  }

  /// Nudges [previous] towards [next] by the appropriate amount.
  static double smooth(double? previous, double next, LiveReading reading) {
    if (previous == null || !previous.isFinite) return next;
    final factor = smoothingFor(reading);
    final blended = previous + (next - previous) * factor;
    // A large jump means the scene really did change; snap rather than crawl.
    return (next - previous).abs() > 2.0 ? next : blended;
  }

  static double log2(double x) => math.log(x) / ExposureMath.ln2;
}
