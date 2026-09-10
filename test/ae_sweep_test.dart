import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/ae_sweep.dart';
import 'package:aperture_diary/exposure.dart';
import 'package:aperture_diary/metering.dart';

/// Inverse of [ExposureMath.srgbToLinear], for building fixtures from a
/// desired linear luminance.
double linearToSrgb(double linear) {
  final l = linear.clamp(0.0, 1.0);
  if (l <= 0.0031308) return l * 12.92;
  return 1.055 * math.pow(l, 1 / 2.4) - 0.055;
}

/// A rung where the camera metered [ev100] and the patch rendered at
/// [encoded] (gamma-encoded luminance).
AeSweepPoint rung({
  required double offset,
  required double ev100,
  required double encoded,
}) {
  const aperture = 1.8;
  final shutter = aperture * aperture / math.pow(2.0, ev100);
  final channel = (encoded * 255).round().clamp(0, 255);

  return AeSweepPoint(
    requestedOffset: offset,
    params: ExposureParams(
      aperture: aperture,
      shutterSeconds: shutter.toDouble(),
      iso: 100,
    ),
    sample: SpotSample(
      linearLuminance: ExposureMath.srgbToLinear(encoded),
      encodedLuminance: encoded,
      r: channel,
      g: channel,
      b: channel,
    ),
  );
}

/// sRGB encoding of 18% middle grey.
final double midGreyEncoded = linearToSrgb(ExposureMath.middleGrey);

/// A perfectly self-consistent camera: each stop of extra exposure lowers the
/// metered EV by one stop and lifts the patch by exactly one stop, so the
/// reported scene EV never moves.
List<AeSweepPoint> consistentSweep() {
  final points = <AeSweepPoint>[];
  for (var i = -2; i <= 2; i++) {
    final offset = i.toDouble();
    final linear = ExposureMath.middleGrey * math.pow(2.0, offset);
    final encoded = linearToSrgb(linear.toDouble());
    final channel = (encoded * 255).round().clamp(0, 255);
    final ev100 = 10.0 - offset;

    points.add(
      AeSweepPoint(
        requestedOffset: offset,
        params: ExposureParams(
          aperture: 1.8,
          shutterSeconds: (1.8 * 1.8 / math.pow(2.0, ev100)).toDouble(),
          iso: 100,
        ),
        sample: SpotSample(
          linearLuminance: linear.toDouble(),
          encodedLuminance: encoded,
          r: channel,
          g: channel,
          b: channel,
        ),
      ),
    );
  }
  return points;
}

void main() {
  group('AeSweepPoint', () {
    test('a patch on middle grey reports the metered EV unchanged', () {
      final p = rung(offset: 0, ev100: 10, encoded: midGreyEncoded);
      expect(p.sceneEv, closeTo(10, 0.01));
    });

    test('a patch one stop above middle grey reads one stop brighter', () {
      final encoded = linearToSrgb(ExposureMath.middleGrey * 2);
      final p = rung(offset: 0, ev100: 10, encoded: encoded);
      expect(p.sceneEv, closeTo(11, 0.01));
    });
  });

  group('AeSweepResult', () {
    test('an empty or single-rung sweep cannot be judged', () {
      expect(const AeSweepResult(points: []).isEmpty, isTrue);
      expect(
        AeSweepResult(
          points: [rung(offset: 0, ev100: 10, encoded: midGreyEncoded)],
        ).isEmpty,
        isTrue,
      );
    });

    test('a self-consistent camera shows near-zero spread', () {
      final result = AeSweepResult(points: consistentSweep());
      expect(result.spread, lessThan(1.0 / 3.0));
      expect(result.isConsistent, isTrue);
      expect(result.referenceEv, closeTo(10, 0.05));
      expect(result.verdict, contains('Consistent'));
    });

    test('reference EV is the median, so one bad rung cannot drag it', () {
      final result = AeSweepResult(
        points: [
          rung(offset: -1, ev100: 10, encoded: midGreyEncoded),
          rung(offset: 0, ev100: 10, encoded: midGreyEncoded),
          // A wildly wrong rung: the mean would be 12, the median stays 10.
          rung(offset: 1, ev100: 16, encoded: midGreyEncoded),
        ],
      );
      expect(result.referenceEv, closeTo(10, 0.05));
    });

    test('clipped and crushed rungs are excluded from the usable set', () {
      final result = AeSweepResult(
        points: [
          rung(offset: -2, ev100: 10, encoded: 0.01), // crushed
          rung(offset: 0, ev100: 10, encoded: midGreyEncoded),
          rung(offset: 2, ev100: 10, encoded: 0.99), // clipped
        ],
      );
      expect(result.usablePoints.length, 1);
      // Residuals still cover every rung so the chart can show the bad ones.
      expect(result.residuals.length, 3);
    });

    test('an inconsistent sweep is flagged rather than called consistent', () {
      // The patch barely moves while the metered EV swings: the pipelines
      // disagree, so the reported scene EV drifts.
      final result = AeSweepResult(
        points: [
          rung(offset: -2, ev100: 12, encoded: 0.42),
          rung(offset: -1, ev100: 11, encoded: 0.44),
          rung(offset: 0, ev100: 10, encoded: midGreyEncoded),
          rung(offset: 1, ev100: 9, encoded: 0.48),
          rung(offset: 2, ev100: 8, encoded: 0.50),
        ],
      );
      expect(result.isConsistent, isFalse);
      expect(result.spread, greaterThan(1.0 / 3.0));
      expect(result.verdict, isNot(contains('Consistent to')));
    });

    test('a brightness-dependent error yields a positive residual slope', () {
      // Metered EV held fixed while the patch brightens, so the reported EV
      // must climb with encoded luminance.
      final result = AeSweepResult(
        points: [
          rung(offset: -2, ev100: 10, encoded: 0.20),
          rung(offset: -1, ev100: 10, encoded: 0.33),
          rung(offset: 0, ev100: 10, encoded: midGreyEncoded),
          rung(offset: 1, ev100: 10, encoded: 0.60),
          rung(offset: 2, ev100: 10, encoded: 0.70),
        ],
      );
      expect(result.residualSlopePerEncodedUnit, greaterThan(0));
      expect(result.verdict, contains('tone curve'));
    });

    test('slope needs at least three usable rungs', () {
      final result = AeSweepResult(
        points: [
          rung(offset: 0, ev100: 10, encoded: midGreyEncoded),
          rung(offset: 1, ev100: 10, encoded: 0.6),
        ],
      );
      expect(result.residualSlopePerEncodedUnit.isNaN, isTrue);
    });

    test('CSV has one row per rung plus a header, with matching columns', () {
      final result = AeSweepResult(points: consistentSweep());
      final lines = result.toCsv().trim().split('\n');
      expect(lines.length, result.points.length + 1);
      expect(lines.first.split(','), AeSweepResult.csvColumns);
      for (final line in lines.skip(1)) {
        expect(line.split(',').length, AeSweepResult.csvColumns.length);
      }
    });
  });

  group('AeSweepProgress', () {
    test('fraction is bounded even with nonsense totals', () {
      expect(
        const AeSweepProgress(done: 0, total: 0, message: '').fraction,
        0.0,
      );
      expect(
        const AeSweepProgress(done: 9, total: 3, message: '').fraction,
        1.0,
      );
      expect(
        const AeSweepProgress(done: 1, total: 4, message: '').fraction,
        closeTo(0.25, 1e-9),
      );
    });
  });
}
