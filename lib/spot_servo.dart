import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'exposure.dart';

/// One closed-loop observation: what exposure compensation was in force, and
/// how bright the preview rendered the metered patch under it.
@immutable
class ServoObservation {
  const ServoObservation({
    required this.appliedOffset,
    required this.encodedLuminance,
  });

  /// Exposure compensation the camera was actually holding, in stops.
  final double appliedOffset;

  /// Gamma-encoded luminance of the patch, 0..1.
  final double encodedLuminance;
}

/// Why a servo run stopped.
enum ServoOutcome {
  /// The patch was driven into the trusted band around mid grey.
  converged,

  /// The patch is as close as the camera's compensation range allows. The
  /// reading stands but leans on the local slope more than it should.
  clampedAtLimit,

  /// Ran out of iterations while still outside the band.
  exhausted,

  /// The patch did not respond to exposure changes, so nothing can be
  /// concluded — the scene moved, or the pipeline is fighting back.
  unresponsive,
}

/// Drives exposure until the metered patch renders near mid grey, then reads
/// the scene EV off the exposure itself.
///
/// This is the difference between an open and a closed loop. Extrapolating a
/// reading from wherever auto-exposure happened to land needs the pipeline's
/// whole tone curve, and phone curves depart from sRGB by up to two stops in
/// shadows and highlights. Driving the patch to mid grey instead needs only
/// that the curve be locally smooth there, which every pipeline satisfies:
/// measured error at mid grey was 0.12 EV against 2.1 EV in the shadows.
///
/// It also all but removes the dependency on pixel values. As the residual
/// goes to zero the reading becomes `cameraEv100` plus a vanishing
/// correction, so the disagreement between the stills and preview pipelines
/// stops mattering too.
class SpotServo {
  SpotServo({
    this.targetEncoded = defaultTargetEncoded,
    this.tolerance = defaultTolerance,
    // Five is what escaping fully clipped highlights took on a real device;
    // an ordinary scene converges in one or two, since auto-exposure is
    // already aiming near mid grey.
    this.maxIterations = 5,
  });

  /// Encoded value to aim the patch at: what a pipeline renders 18% grey as.
  ///
  /// Chosen because it is where tone curves are most alike, and where the
  /// sensor response is most trustworthy. Written as a literal because it has
  /// to be a compile-time default; [ExposureMath.middleGreyEncoded] computes
  /// the same value and is checked against this in tests.
  static const double defaultTargetEncoded = 0.4614;

  /// Half-width of the band counted as converged, in encoded units.
  ///
  /// At the slopes phones exhibit (5–7 stops per encoded unit) this is worth
  /// under 0.4 EV of correction, and the *error* in that correction is a
  /// fraction of it.
  static const double defaultTolerance = 0.055;

  /// Widest local slope worth trusting for the final correction, in stops per
  /// encoded unit.
  ///
  /// Beyond this the patch is in crushed or clipped territory where a tiny
  /// pixel change stands for a huge light change, so a correction scaled by it
  /// is noise. Steering by such a slope is fine — see [maxControlSlope] — but
  /// reporting a reading based on one is not.
  static const double maxCredibleSlope = 14.0;
  static const double minCredibleSlope = 2.0;

  /// Widest slope allowed when deciding how far to move next.
  ///
  /// Steering and correcting want opposite things from an extreme slope. In
  /// highlight rolloff the patch barely responds to exposure — a real device
  /// measured 32 stops per encoded unit there — so a capped slope produces
  /// steps far too small to escape, and the servo stalls short of target.
  /// Control therefore believes a large measured slope, while the correction
  /// keeps refusing to.
  static const double maxControlSlope = 60.0;

  final double targetEncoded;
  final double tolerance;
  final int maxIterations;

  final List<ServoObservation> _observations = [];

  List<ServoObservation> get observations =>
      List.unmodifiable(_observations);

  int get iterations => _observations.length;

  ServoObservation? get latest =>
      _observations.isEmpty ? null : _observations.last;

  void record(ServoObservation observation) {
    if (!observation.encodedLuminance.isFinite ||
        !observation.appliedOffset.isFinite) {
      return;
    }
    _observations.add(observation);
  }

  void reset() => _observations.clear();

  /// Signed distance of the latest patch from the target, in encoded units.
  double? get residual {
    final last = latest;
    if (last == null) return null;
    return last.encodedLuminance - targetEncoded;
  }

  bool get isConverged {
    final r = residual;
    return r != null && r.abs() <= tolerance;
  }

  /// Slope of log₂ luminance against encoded value, measured from this run.
  ///
  /// Every pair of observations brackets a known change in exposure and an
  /// observed change in encoding, which is the slope directly — no assumption
  /// about the transfer function required. Pairs are weighted by how far apart
  /// they are in encoding, since a wide pair is far less sensitive to noise
  /// than a narrow one.
  ///
  /// Returns null when the run has not moved the patch enough to say.
  double? measuredSlope() => _measureSlope(maxCredibleSlope);

  /// As [measuredSlope], but willing to believe the steep slopes found in
  /// highlight rolloff so the servo can still steer out of them.
  double? measuredControlSlope() => _measureSlope(maxControlSlope);

  double? _measureSlope(double slopeCeiling) {
    if (_observations.length < 2) return null;

    var weightedSum = 0.0;
    var weightTotal = 0.0;

    for (var i = 0; i < _observations.length; i++) {
      for (var j = i + 1; j < _observations.length; j++) {
        final a = _observations[i];
        final b = _observations[j];
        final dEncoded = b.encodedLuminance - a.encodedLuminance;
        // More exposure must mean a brighter patch; if it did not, the pair
        // says nothing.
        final dStops = b.appliedOffset - a.appliedOffset;
        if (dEncoded.abs() < 0.01 || dStops.abs() < 0.05) continue;
        final slope = dStops / dEncoded;
        if (slope <= 0) continue;
        if (slope < minCredibleSlope || slope > slopeCeiling) continue;

        final weight = dEncoded.abs();
        weightedSum += slope * weight;
        weightTotal += weight;
      }
    }

    if (weightTotal <= 0) return null;
    return weightedSum / weightTotal;
  }

  /// Slope to use for the residual correction.
  ///
  /// Prefers what this run measured; falls back to the analytic sRGB slope at
  /// the patch, which is a reasonable prior near mid grey and is only ever
  /// applied to a residual already driven small.
  double slopeForCorrection() {
    final measured = measuredSlope();
    if (measured != null) return measured;
    final last = latest;
    return srgbSlopeAt(last?.encodedLuminance ?? targetEncoded);
  }

  /// Slope to steer by, which may be far steeper than one worth reporting.
  double slopeForControl() {
    final measured = measuredControlSlope();
    if (measured != null) return measured;
    final last = latest;
    return srgbSlopeAt(last?.encodedLuminance ?? targetEncoded);
  }

  /// Analytic d(log₂ L)/d(encoded) for the sRGB transfer function.
  ///
  /// Used only as a prior: at mid grey it is about 6.6 stops per encoded unit,
  /// close enough to real pipelines that a small residual costs little.
  static double srgbSlopeAt(double encoded) {
    final e = encoded.clamp(0.0, 1.0);
    if (e <= 0.04045) {
      // Linear segment: d(log₂(e/12.92))/de = 1/(e·ln2).
      final safe = e < 1e-4 ? 1e-4 : e;
      return (1.0 / (safe * ExposureMath.ln2))
          .clamp(minCredibleSlope, maxCredibleSlope);
    }
    // L = ((e+0.055)/1.055)^2.4 → d(log₂L)/de = 2.4/((e+0.055)·ln2)
    return (2.4 / ((e + 0.055) * ExposureMath.ln2))
        .clamp(minCredibleSlope, maxCredibleSlope);
  }

  /// Exposure compensation to try next, or null when there is nothing to do.
  ///
  /// [currentOffset] is what the camera holds now; [minOffset]/[maxOffset]
  /// bound what it will accept.
  double? nextOffset({
    required double currentOffset,
    required double minOffset,
    required double maxOffset,
    double? stepSize,
  }) {
    final r = residual;
    if (r == null) return null;
    if (r.abs() <= tolerance) return null;
    if (_observations.length >= maxIterations) return null;

    final slope = slopeForControl();

    // A patch darker than target needs more exposure, so the correction runs
    // opposite to the residual.
    var correction = -r * slope;

    // Damp the step: the slope is a local linearisation of a curve, and
    // overshooting into the rolloff makes the next estimate worse, not better.
    correction *= 0.85;

    // Allow a big first move — escaping clipped highlights needs one — but
    // never an unbounded leap.
    correction = correction.clamp(-4.0, 4.0);

    var target = currentOffset + correction;
    target = target.clamp(minOffset, maxOffset);

    if (stepSize != null && stepSize > 0) {
      target = (target / stepSize).roundToDouble() * stepSize;
      target = target.clamp(minOffset, maxOffset);
    }

    // Already at the rail, or the step rounds away to nothing.
    if ((target - currentOffset).abs() < 1e-6) return null;
    return target;
  }

  /// How the run ended, given the compensation rail it was working against.
  ServoOutcome outcome({
    required double currentOffset,
    required double minOffset,
    required double maxOffset,
  }) {
    if (isConverged) return ServoOutcome.converged;
    if (_observations.length >= 2 && measuredSlope() == null) {
      return ServoOutcome.unresponsive;
    }
    final atRail = (currentOffset - minOffset).abs() < 1e-6 ||
        (currentOffset - maxOffset).abs() < 1e-6;
    if (atRail) return ServoOutcome.clampedAtLimit;
    return ServoOutcome.exhausted;
  }

  /// Scene EV₁₀₀ from the exposure the camera settled on.
  ///
  /// With the patch on target this is just `cameraEv100`; the residual term
  /// only trims what the servo could not remove. Returns null when the patch
  /// never responded, because then neither term can be trusted.
  double? resolve({required double cameraEv100}) {
    if (!cameraEv100.isFinite) return null;
    final r = residual;
    if (r == null) return null;

    final slope = slopeForCorrection();
    if (!slope.isFinite) return null;

    // Refuse a correction so large it means the servo never got near target;
    // the local linearisation does not reach that far.
    final correctionStops = r * slope;
    if (correctionStops.abs() > 3.0) return null;

    return cameraEv100 + correctionStops;
  }

  /// Stops of correction the residual is contributing, for diagnostics.
  double? get correctionStops {
    final r = residual;
    if (r == null) return null;
    return r * slopeForCorrection();
  }

  /// Rough bound on the reading's error, in stops.
  ///
  /// Slope uncertainty only ever acts on the residual, so a converged run is
  /// accurate almost regardless of how wrong the slope is. This reports that
  /// product rather than pretending to a precision the method lacks.
  double? get estimatedErrorStops {
    final r = residual;
    if (r == null) return null;
    // Phone slopes observed between about 5 and 7 stops per encoded unit; take
    // 30% as a conservative uncertainty on whatever slope is in use.
    return (r.abs() * slopeForCorrection() * 0.3).abs();
  }

  /// Encoded band the servo treats as trustworthy.
  double get bandMin => math.max(0.0, targetEncoded - tolerance);
  double get bandMax => math.min(1.0, targetEncoded + tolerance);
}
