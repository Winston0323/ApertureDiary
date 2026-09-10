import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/exposure.dart';
import 'package:aperture_diary/spot_servo.dart';

/// Real tone response measured on a vivo V2505A, 2026-09-03.
///
/// Rows are (exposure compensation, encoded luminance, metered EV₁₀₀) on a
/// fixed scene. The true scene EV₁₀₀ was 6.31; the open-loop algorithm spread
/// its readings across 2.31 EV on this same data.
const List<List<double>> v2505a = [
  [-4.000, 0.04738, 9.807],
  [-2.667, 0.12716, 8.465],
  [-1.333, 0.31929, 7.055],
  [0.000, 0.56773, 5.756],
  [1.333, 0.70411, 4.906],
  [2.667, 0.79853, 3.455],
  [4.000, 0.83983, 2.192],
];

/// Ground truth recovered from the sweep.
const double trueSceneEv = 6.312;

/// Interpolates the device's real response, so a simulated servo run is
/// driving the pipeline that actually caused the problem.
class DeviceModel {
  const DeviceModel();

  /// Encoded luminance the preview would render at a given compensation.
  double encodedAt(double offset) => _interp(offset, 0, 1);

  /// EV₁₀₀ the camera would report at a given compensation.
  double meteredEvAt(double offset) => _interp(offset, 0, 2);

  double get minOffset => v2505a.first[0];
  double get maxOffset => v2505a.last[0];

  double _interp(double x, int xi, int yi) {
    if (x <= v2505a.first[xi]) return v2505a.first[yi];
    if (x >= v2505a.last[xi]) return v2505a.last[yi];
    for (var i = 1; i < v2505a.length; i++) {
      if (x <= v2505a[i][xi]) {
        final x0 = v2505a[i - 1][xi];
        final x1 = v2505a[i][xi];
        final t = (x - x0) / (x1 - x0);
        return v2505a[i - 1][yi] + (v2505a[i][yi] - v2505a[i - 1][yi]) * t;
      }
    }
    return v2505a.last[yi];
  }
}

/// Runs the servo against [device] from a starting compensation.
({double? ev, ServoOutcome outcome, int iterations}) runServo(
  DeviceModel device, {
  double startOffset = 0.0,
  double stepSize = 1 / 6,
}) {
  final servo = SpotServo();
  var offset = startOffset;

  for (var i = 0; i < 8; i++) {
    servo.record(
      ServoObservation(
        appliedOffset: offset,
        encodedLuminance: device.encodedAt(offset),
      ),
    );
    final next = servo.nextOffset(
      currentOffset: offset,
      minOffset: device.minOffset,
      maxOffset: device.maxOffset,
      stepSize: stepSize,
    );
    if (next == null) break;
    offset = next;
  }

  return (
    ev: servo.resolve(cameraEv100: device.meteredEvAt(offset)),
    outcome: servo.outcome(
      currentOffset: offset,
      minOffset: device.minOffset,
      maxOffset: device.maxOffset,
    ),
    iterations: servo.iterations,
  );
}

void main() {
  group('sRGB slope prior', () {
    test('the literal target really is sRGB mid grey', () {
      // The constructor default has to be a compile-time constant, so it is
      // written as a literal; this keeps it honest.
      expect(
        SpotServo.defaultTargetEncoded,
        closeTo(ExposureMath.middleGreyEncoded, 0.001),
      );
    });

    test('is about 6.6 stops per encoded unit at mid grey', () {
      final slope = SpotServo.srgbSlopeAt(ExposureMath.middleGreyEncoded);
      expect(slope, closeTo(6.6, 0.3));
    });

    test('is clamped in the crushed and clipped extremes', () {
      // Without a clamp these blow up and produce nonsense corrections.
      expect(SpotServo.srgbSlopeAt(0.0), lessThanOrEqualTo(14.0));
      expect(SpotServo.srgbSlopeAt(0.0), greaterThanOrEqualTo(2.0));
      expect(SpotServo.srgbSlopeAt(1.0), greaterThanOrEqualTo(2.0));
    });

    test('falls as the patch brightens', () {
      expect(
        SpotServo.srgbSlopeAt(0.7),
        lessThan(SpotServo.srgbSlopeAt(0.3)),
      );
    });
  });

  group('measured slope', () {
    test('needs at least two observations', () {
      final servo = SpotServo();
      expect(servo.measuredSlope(), isNull);
      servo.record(
        const ServoObservation(appliedOffset: 0, encodedLuminance: 0.4),
      );
      expect(servo.measuredSlope(), isNull);
    });

    test('recovers the slope from a known exposure change', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0.0, encodedLuminance: 0.40),
        )
        ..record(
          // One stop more exposure lifted the patch by 0.15 encoded units, so
          // the slope is 1/0.15 ≈ 6.67 stops per unit.
          const ServoObservation(appliedOffset: 1.0, encodedLuminance: 0.55),
        );
      expect(servo.measuredSlope(), closeTo(6.67, 0.05));
    });

    test('needs no assumption about the transfer function', () {
      // A pipeline half as contrasty as sRGB is measured just as correctly.
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0.0, encodedLuminance: 0.30),
        )
        ..record(
          const ServoObservation(appliedOffset: 1.0, encodedLuminance: 0.60),
        );
      expect(servo.measuredSlope(), closeTo(3.33, 0.05));
    });

    test('rejects a patch that did not respond to exposure', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0.0, encodedLuminance: 0.50),
        )
        ..record(
          // Two stops of exposure moved nothing: clipped, or the scene moved.
          const ServoObservation(appliedOffset: 2.0, encodedLuminance: 0.502),
        );
      expect(servo.measuredSlope(), isNull);
    });

    test('rejects an inverted response', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0.0, encodedLuminance: 0.60),
        )
        ..record(
          // More exposure, darker patch: physically impossible.
          const ServoObservation(appliedOffset: 1.0, encodedLuminance: 0.40),
        );
      expect(servo.measuredSlope(), isNull);
    });

    test('is dominated by the widest pair, not the noisiest', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0.0, encodedLuminance: 0.30),
        )
        ..record(
          // A narrow, noisy pair implying an absurd 10 stops/unit.
          const ServoObservation(appliedOffset: 0.2, encodedLuminance: 0.32),
        )
        ..record(
          const ServoObservation(appliedOffset: 2.0, encodedLuminance: 0.62),
        );
      // The wide pair says 2.0/0.32 = 6.25; weighting must lean that way.
      expect(servo.measuredSlope(), closeTo(6.4, 0.6));
    });
  });

  group('convergence on the real device response', () {
    test('lands on the true scene EV from a mid start', () {
      final result = runServo(const DeviceModel(), startOffset: 0.0);
      expect(result.outcome, ServoOutcome.converged);
      expect(result.ev, isNotNull);
      // The open loop was 2.31 EV wide on this data; a third of a stop is the
      // finest step a film workflow acts on.
      expect((result.ev! - trueSceneEv).abs(), lessThan(1.0 / 3.0));
    });

    test('lands there from a badly underexposed start too', () {
      // The old algorithm was worst here: encoded 0.047 cost it 2.08 EV.
      final result = runServo(const DeviceModel(), startOffset: -4.0);
      expect(result.ev, isNotNull);
      expect((result.ev! - trueSceneEv).abs(), lessThan(1.0 / 3.0));
    });

    test('lands there from a blown-highlight start too', () {
      final result = runServo(const DeviceModel(), startOffset: 4.0);
      expect(result.ev, isNotNull);
      expect((result.ev! - trueSceneEv).abs(), lessThan(1.0 / 3.0));
    });

    test('agrees with itself wherever it starts', () {
      final readings = <double>[];
      for (final start in [-4.0, -2.0, 0.0, 2.0, 4.0]) {
        final r = runServo(const DeviceModel(), startOffset: start);
        if (r.ev != null) readings.add(r.ev!);
      }
      expect(readings.length, 5);
      final spread = readings.reduce((a, b) => a > b ? a : b) -
          readings.reduce((a, b) => a < b ? a : b);
      // This is the headline: the same 2.31 EV of starting conditions that
      // broke the open loop now agree to a fraction of a stop.
      expect(spread, lessThan(1.0 / 3.0), reason: 'readings were $readings');
    });

    test('gets there in a handful of iterations', () {
      final result = runServo(const DeviceModel(), startOffset: -4.0);
      expect(result.iterations, lessThanOrEqualTo(5));
    });

    test('survives the coarse compensation steps a real camera exposes', () {
      for (final step in [1 / 6, 1 / 3, 1 / 2]) {
        final result = runServo(
          const DeviceModel(),
          startOffset: -2.0,
          stepSize: step,
        );
        expect(result.ev, isNotNull, reason: 'step $step');
        expect(
          (result.ev! - trueSceneEv).abs(),
          lessThan(0.5),
          reason: 'step $step gave ${result.ev}',
        );
      }
    });
  });

  group('the reading barely depends on the slope', () {
    test('a converged run is accurate even with a badly wrong slope', () {
      // This is the whole argument for closing the loop: drive the residual to
      // zero and the correction term — with all its uncertainty — vanishes.
      final servo = SpotServo()
        ..record(
          ServoObservation(
            appliedOffset: 0,
            // Just inside tolerance.
            encodedLuminance: ExposureMath.middleGreyEncoded + 0.05,
          ),
        );
      final reading = servo.resolve(cameraEv100: 8.0)!;
      // Even if the true slope were double the prior, the error stays small.
      expect((reading - 8.0).abs(), lessThan(0.4));
    });

    test('reports an honest error bound that shrinks with the residual', () {
      double boundAt(double residual) {
        final servo = SpotServo()
          ..record(
            ServoObservation(
              appliedOffset: 0,
              encodedLuminance: ExposureMath.middleGreyEncoded + residual,
            ),
          );
        return servo.estimatedErrorStops!;
      }

      expect(boundAt(0.0), lessThan(0.01));
      expect(boundAt(0.05), lessThan(0.15));
      expect(boundAt(0.05), greaterThan(boundAt(0.01)));
    });

    test('refuses a reading needing an implausibly large correction', () {
      // Far outside the band the local linearisation simply does not reach.
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0, encodedLuminance: 0.02),
        );
      expect(servo.resolve(cameraEv100: 8.0), isNull);
    });
  });

  group('servo control', () {
    test('drives a dark patch towards more exposure', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0, encodedLuminance: 0.20),
        );
      final next = servo.nextOffset(
        currentOffset: 0,
        minOffset: -4,
        maxOffset: 4,
      );
      expect(next, isNotNull);
      expect(next!, greaterThan(0));
    });

    test('drives a bright patch towards less exposure', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0, encodedLuminance: 0.80),
        );
      final next = servo.nextOffset(
        currentOffset: 0,
        minOffset: -4,
        maxOffset: 4,
      );
      expect(next, isNotNull);
      expect(next!, lessThan(0));
    });

    test('stops once inside the band', () {
      final servo = SpotServo()
        ..record(
          ServoObservation(
            appliedOffset: 0,
            encodedLuminance: ExposureMath.middleGreyEncoded,
          ),
        );
      expect(
        servo.nextOffset(currentOffset: 0, minOffset: -4, maxOffset: 4),
        isNull,
      );
      expect(servo.isConverged, isTrue);
    });

    test('respects the compensation rails', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 1.9, encodedLuminance: 0.15),
        );
      final next = servo.nextOffset(
        currentOffset: 1.9,
        minOffset: -2,
        maxOffset: 2,
      );
      // May stop or step, but must never exceed the rail.
      if (next != null) expect(next, lessThanOrEqualTo(2.0));
    });

    test('stops after the iteration budget', () {
      final servo = SpotServo(maxIterations: 2);
      for (var i = 0; i < 3; i++) {
        servo.record(
          const ServoObservation(appliedOffset: 0, encodedLuminance: 0.20),
        );
      }
      expect(
        servo.nextOffset(currentOffset: 0, minOffset: -4, maxOffset: 4),
        isNull,
      );
    });

    test('reports being pinned at a rail rather than claiming success', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: -2.0, encodedLuminance: 0.15),
        );
      expect(
        servo.outcome(currentOffset: -2.0, minOffset: -2.0, maxOffset: 2.0),
        ServoOutcome.clampedAtLimit,
      );
    });

    test('reports an unresponsive patch', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(appliedOffset: 0.0, encodedLuminance: 0.95),
        )
        ..record(
          const ServoObservation(appliedOffset: 2.0, encodedLuminance: 0.951),
        );
      expect(
        servo.outcome(currentOffset: 2.0, minOffset: -4.0, maxOffset: 4.0),
        ServoOutcome.unresponsive,
      );
    });

    test('ignores non-finite observations', () {
      final servo = SpotServo()
        ..record(
          const ServoObservation(
            appliedOffset: 0,
            encodedLuminance: double.nan,
          ),
        )
        ..record(
          ServoObservation(
            appliedOffset: double.infinity,
            encodedLuminance: 0.4,
          ),
        );
      expect(servo.iterations, 0);
      expect(servo.residual, isNull);
    });
  });
}
