import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/exposure.dart';
import 'package:aperture_diary/tone_curve.dart';

/// Real sweep captured on a vivo V2505A, 2026-09-03.
///
/// The scene was fixed, so every rung describes the same light. The plain sRGB
/// inversion spread these across 2.31 EV; a fitted curve must collapse them.
const List<List<double>> v2505aSweep = [
  // encoded, cameraEv100
  [0.04738, 9.807],
  [0.12716, 8.465],
  [0.31929, 7.055],
  [0.56773, 5.756],
  [0.70411, 4.906],
  [0.79853, 3.455],
  [0.83983, 2.192],
];

List<ToneCurveSample> realSamples() => v2505aSweep
    .map(
      (r) => ToneCurveSample(encodedLuminance: r[0], cameraEv100: r[1]),
    )
    .toList();

/// A synthetic pipeline that really is sRGB, for the ideal case.
List<ToneCurveSample> srgbSamples({double sceneEv = 8.0}) {
  final out = <ToneCurveSample>[];
  for (final encoded in [0.1, 0.25, 0.4663, 0.65, 0.85]) {
    final linear = ExposureMath.srgbToLinear(encoded);
    // sceneEv = cameraEv + log2(linear / 0.18)
    final cameraEv =
        sceneEv - ExposureMath.log2(linear / ExposureMath.middleGrey);
    out.add(
      ToneCurveSample(encodedLuminance: encoded, cameraEv100: cameraEv),
    );
  }
  return out;
}

void main() {
  group('ToneCurve.fit', () {
    test('refuses fewer than three usable observations', () {
      expect(ToneCurve.fit([]), isNull);
      expect(
        ToneCurve.fit([
          const ToneCurveSample(encodedLuminance: 0.4, cameraEv100: 8),
          const ToneCurveSample(encodedLuminance: 0.6, cameraEv100: 7),
        ]),
        isNull,
      );
    });

    test('refuses a non-monotone response', () {
      // A brighter patch reported at a brighter metered EV cannot happen on a
      // static scene: something moved.
      expect(
        ToneCurve.fit([
          const ToneCurveSample(encodedLuminance: 0.2, cameraEv100: 8),
          const ToneCurveSample(encodedLuminance: 0.5, cameraEv100: 9),
          const ToneCurveSample(encodedLuminance: 0.8, cameraEv100: 10),
        ]),
        isNull,
      );
    });

    test('refuses data that does not bracket the anchor', () {
      // All rungs sit in deep shadow, so mid grey is outside the measured
      // span and the absolute level would have to be extrapolated.
      expect(
        ToneCurve.fit([
          const ToneCurveSample(encodedLuminance: 0.02, cameraEv100: 10),
          const ToneCurveSample(encodedLuminance: 0.05, cameraEv100: 9),
          const ToneCurveSample(encodedLuminance: 0.09, cameraEv100: 8),
        ]),
        isNull,
      );
    });

    test('ignores out-of-band encoded values', () {
      final curve = ToneCurve.fit([
        const ToneCurveSample(encodedLuminance: 0.0, cameraEv100: 12),
        const ToneCurveSample(encodedLuminance: 0.2, cameraEv100: 9),
        const ToneCurveSample(encodedLuminance: 0.4663, cameraEv100: 8),
        const ToneCurveSample(encodedLuminance: 0.7, cameraEv100: 7),
        const ToneCurveSample(encodedLuminance: 1.0, cameraEv100: 5),
      ]);
      expect(curve, isNotNull);
      expect(curve!.minEncoded, closeTo(0.2, 1e-9));
      expect(curve.maxEncoded, closeTo(0.7, 1e-9));
    });

    test('recovers a genuinely sRGB pipeline as near-zero correction', () {
      final curve = ToneCurve.fit(srgbSamples(sceneEv: 8.0));
      expect(curve, isNotNull);
      // Nothing to correct: sRGB already describes this pipeline.
      expect(curve!.worstSrgbErrorStops, lessThan(0.1));
      expect(curve.sceneEv100, closeTo(8.0, 0.1));
    });
  });

  group('ToneCurve on real device data', () {
    test('collapses a 2.31 EV spread to well under a third of a stop', () {
      final curve = ToneCurve.fit(realSamples())!;

      final readings = <double>[];
      for (final row in v2505aSweep) {
        final linear = curve.linearFor(row[0]);
        expect(
          linear,
          isNotNull,
          reason: 'curve must cover its own measurement at ${row[0]}',
        );
        readings.add(
          ExposureMath.sceneEv(
            cameraEv100: row[1],
            linearLuminance: linear!,
          ),
        );
      }

      final spread = readings.reduce(math.max) - readings.reduce(math.min);
      // The whole point of the fit: one scene, one answer.
      expect(spread, lessThan(0.01), reason: 'readings were $readings');
    });

    test('the same data under plain sRGB really is that far out', () {
      // Guards the premise: if this ever passes, the correction is pointless.
      final readings = v2505aSweep
          .map(
            (row) => ExposureMath.sceneEv(
              cameraEv100: row[1],
              linearLuminance: ExposureMath.srgbToLinear(row[0]),
            ),
          )
          .toList();
      final spread = readings.reduce(math.max) - readings.reduce(math.min);
      expect(spread, greaterThan(2.0));
    });

    test('sRGB error is worst in the shadows and highlights', () {
      final curve = ToneCurve.fit(realSamples())!;

      // Deep shadow and blown highlight: sRGB understates badly.
      expect(curve.srgbErrorStops(0.04738)!.abs(), greaterThan(1.5));
      expect(curve.srgbErrorStops(0.83983)!.abs(), greaterThan(1.5));
      // Near mid grey it is close enough that sRGB alone would have done.
      expect(curve.srgbErrorStops(0.56773)!.abs(), lessThan(0.4));
    });

    test('refuses to extrapolate beyond what it measured', () {
      final curve = ToneCurve.fit(realSamples())!;
      expect(curve.linearFor(0.01), isNull);
      expect(curve.linearFor(0.99), isNull);
      expect(curve.coversEncoded(0.5), isTrue);
    });

    test('is monotone across its whole span', () {
      final curve = ToneCurve.fit(realSamples())!;
      double? previous;
      for (var e = curve.minEncoded; e <= curve.maxEncoded; e += 0.01) {
        final linear = curve.linearFor(e);
        if (linear == null) continue;
        if (previous != null) {
          expect(
            linear,
            greaterThan(previous),
            reason: 'brighter encoding must mean more light at $e',
          );
        }
        previous = linear;
      }
    });

    test('reports the scene range it can speak for', () {
      final curve = ToneCurve.fit(realSamples())!;
      // The sweep spanned roughly 7.6 stops of metered exposure.
      expect(curve.rangeInStops, greaterThan(7.0));
    });
  });

  group('ToneCurve serialization', () {
    test('round trips through JSON unchanged', () {
      final curve = ToneCurve.fit(realSamples())!;
      final restored = ToneCurve.fromJson(curve.toJson())!;

      expect(restored.encoded, curve.encoded);
      expect(restored.log2Linear, curve.log2Linear);
      expect(restored.sceneEv100, closeTo(curve.sceneEv100, 1e-9));
      expect(
        restored.linearFor(0.5),
        closeTo(curve.linearFor(0.5)!, 1e-12),
      );
    });

    test('rejects malformed or corrupt stored curves', () {
      expect(ToneCurve.fromJson(null), isNull);
      expect(ToneCurve.fromJson('not a map'), isNull);
      // Mismatched lengths.
      expect(
        ToneCurve.fromJson({
          'encoded': [0.1, 0.5, 0.9],
          'log2Linear': [-3.0, -1.0],
        }),
        isNull,
      );
      // Too few knots.
      expect(
        ToneCurve.fromJson({
          'encoded': [0.1, 0.9],
          'log2Linear': [-3.0, -1.0],
        }),
        isNull,
      );
      // Non-ascending encoded values would break the search.
      expect(
        ToneCurve.fromJson({
          'encoded': [0.5, 0.2, 0.9],
          'log2Linear': [-3.0, -2.0, -1.0],
        }),
        isNull,
      );
      // Non-ascending luminance is not a tone curve.
      expect(
        ToneCurve.fromJson({
          'encoded': [0.1, 0.5, 0.9],
          'log2Linear': [-1.0, -2.0, -3.0],
        }),
        isNull,
      );
      // Encoded values must be a fraction.
      expect(
        ToneCurve.fromJson({
          'encoded': [0.1, 0.5, 1.4],
          'log2Linear': [-3.0, -2.0, -1.0],
        }),
        isNull,
      );
      // Non-numeric entries.
      expect(
        ToneCurve.fromJson({
          'encoded': [0.1, 'x', 0.9],
          'log2Linear': [-3.0, -2.0, -1.0],
        }),
        isNull,
      );
    });
  });

  group('usable encoded band', () {
    test('matches where sRGB was measured to be acceptable', () {
      final curve = ToneCurve.fit(realSamples())!;
      // Inside the band the sRGB fallback is within about a third of a stop.
      for (final e in [
        ExposureMath.usableEncodedMin + 0.02,
        0.5,
        ExposureMath.usableEncodedMax - 0.02,
      ]) {
        final err = curve.srgbErrorStops(e);
        expect(err, isNotNull);
        expect(
          err!.abs(),
          lessThan(0.45),
          reason: 'sRGB should be usable at encoded $e',
        );
      }
    });
  });
}
