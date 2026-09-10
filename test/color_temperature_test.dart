import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/color_temperature.dart';

/// Published CIE 1931 xy chromaticities of standard illuminants, with the
/// temperature each is defined at. These are the yardstick: an implementation
/// that misplaces them is wrong regardless of how plausible its output looks.
const List<({String name, double x, double y, double kelvin})> illuminants = [
  // CIE Illuminant A — tungsten, a true black body at 2856 K.
  (name: 'A', x: 0.44757, y: 0.40745, kelvin: 2856),
  // Daylight series: on the daylight locus, slightly above the Planckian one.
  (name: 'D50', x: 0.34567, y: 0.35850, kelvin: 5003),
  (name: 'D55', x: 0.33242, y: 0.34743, kelvin: 5503),
  (name: 'D65', x: 0.31271, y: 0.32902, kelvin: 6504),
  (name: 'D75', x: 0.29902, y: 0.31485, kelvin: 7504),
];

ColorTemperature? fromXy(double x, double y) {
  final uv = Uv.fromXy(x, y);
  if (uv == null) return null;
  return ColorTemperatureMath.fromUv(uv);
}

void main() {
  group('CIE 1960 uv conversion', () {
    test('places D65 where the standard says', () {
      final uv = Uv.fromXy(0.31271, 0.32902)!;
      expect(uv.u, closeTo(0.19783, 0.0002));
      expect(uv.v, closeTo(0.31229, 0.0002));
    });

    test('rejects a degenerate chromaticity', () {
      // -2x + 12y + 3 == 0 has no uv image.
      expect(Uv.fromXy(1.5, 0.0), isNull);
    });
  });

  group('Planckian locus', () {
    test('is only defined over the range it was fitted for', () {
      expect(ColorTemperatureMath.planckianXy(1000), isNull);
      expect(ColorTemperatureMath.planckianXy(30000), isNull);
      expect(ColorTemperatureMath.planckianXy(double.nan), isNull);
      expect(ColorTemperatureMath.planckianXy(5000), isNotNull);
    });

    test('runs from red through to blue as temperature rises', () {
      // Rising temperature must move the locus monotonically toward less x.
      double? previousX;
      for (var t = 1700.0; t <= 25000; t *= 1.1) {
        final xy = ColorTemperatureMath.planckianXy(t)!;
        if (previousX != null) {
          expect(xy.x, lessThan(previousX), reason: 'at $t K');
        }
        previousX = xy.x;
      }
    });

    test('matches Illuminant A, which is a real black body', () {
      final xy = ColorTemperatureMath.planckianXy(2856)!;
      expect(xy.x, closeTo(0.44757, 0.002));
      expect(xy.y, closeTo(0.40745, 0.002));
    });
  });

  group('temperature recovery', () {
    test('round trips every temperature it claims to support', () {
      for (var t = 1700.0; t <= 24000; t *= 1.15) {
        final uv = ColorTemperatureMath.planckianUv(t)!;
        final result = ColorTemperatureMath.fromUv(uv)!;
        // A point exactly on the locus must come back as itself.
        expect(
          result.kelvin,
          closeTo(t, t * 0.005),
          reason: 'expected $t, got ${result.kelvin}',
        );
        expect(result.duv.abs(), lessThan(1e-4), reason: 'at $t K');
        expect(result.confidence, CctConfidence.high, reason: 'at $t K');
      }
    });

    test('recovers the standard illuminants to within a per cent', () {
      for (final illuminant in illuminants) {
        final result = fromXy(illuminant.x, illuminant.y);
        expect(result, isNotNull, reason: illuminant.name);
        expect(
          result!.kelvin,
          closeTo(illuminant.kelvin, illuminant.kelvin * 0.01),
          reason: '${illuminant.name}: got ${result.kelvin}',
        );
      }
    });

    test('puts the daylight series just above the black-body locus', () {
      // The D series is not Planckian; it sits a touch green of the locus.
      // Reproducing that sign is a check that Duv is oriented correctly.
      for (final name in ['D50', 'D55', 'D65', 'D75']) {
        final illuminant = illuminants.firstWhere((i) => i.name == name);
        final result = fromXy(illuminant.x, illuminant.y)!;
        expect(result.duv, greaterThan(0), reason: name);
        expect(result.duv, lessThan(0.01), reason: name);
      }
    });

    test('Illuminant A sits essentially on the locus', () {
      final result = fromXy(0.44757, 0.40745)!;
      expect(result.duv.abs(), lessThan(0.002));
      expect(result.confidence, CctConfidence.high);
    });

    test('flags a match that ran into the end of the range', () {
      final veryBlue = ColorTemperatureMath.planckianUv(
        ColorTemperatureMath.maxKelvin,
      )!;
      final result = ColorTemperatureMath.fromUv(veryBlue)!;
      expect(result.atSearchLimit, isTrue);
      // Hitting the rail is itself a reason not to claim confidence.
      expect(result.confidence, CctConfidence.low);
    });
  });

  group('rejecting colours a temperature cannot describe', () {
    test('a saturated colour is refused, not guessed at', () {
      // Pure red is nowhere near the locus; the old polynomial happily
      // returned a number for this.
      expect(ColorTemperatureMath.fromRgb8(255, 0, 0), isNull);
      expect(ColorTemperatureMath.fromRgb8(0, 200, 0), isNull);
      expect(ColorTemperatureMath.fromRgb8(0, 0, 200), isNull);
    });

    test('a clipped channel is refused', () {
      // Once a channel pins, its ratio to the others is invented.
      expect(ColorTemperatureMath.fromRgb8(255, 200, 180), isNull);
      expect(ColorTemperatureMath.fromRgb8(180, 252, 200), isNull);
    });

    test('a patch buried in noise is refused', () {
      expect(ColorTemperatureMath.fromRgb8(0, 0, 0), isNull);
      expect(ColorTemperatureMath.fromRgb8(8, 6, 4), isNull);
    });

    test('a plausible warm surface is accepted', () {
      final result = ColorTemperatureMath.fromRgb8(220, 180, 140);
      expect(result, isNotNull);
      expect(result!.kelvin, lessThan(4500));
    });

    test('reports low confidence off the locus rather than refusing', () {
      // Fluorescent-like greenish white: worth reporting, not worth trusting.
      final result = ColorTemperatureMath.fromRgb8(180, 190, 170);
      expect(result, isNotNull);
      expect(result!.confidence, CctConfidence.low);
      expect(result.duv.abs(), greaterThan(ColorTemperatureMath.highConfidenceDuv));
    });
  });

  group('direction of the measurement', () {
    test('warm patches read cooler in Kelvin than cool patches', () {
      final warm = ColorTemperatureMath.fromRgb8(220, 180, 140)!;
      final cool = ColorTemperatureMath.fromRgb8(140, 180, 220)!;
      expect(warm.kelvin, lessThan(cool.kelvin));
    });

    test('a neutral sRGB patch reads as D65, since that is sRGB white', () {
      final result = ColorTemperatureMath.fromRgb8(128, 128, 128)!;
      expect(result.kelvin, closeTo(6500, 200));
    });

    test('scaling linear intensity does not move the temperature', () {
      // Chromaticity is a ratio, so exposure must not enter into it. Tested in
      // linear light, where the invariance is exact.
      final dim = ColorTemperatureMath.fromLinearRgb(0.05, 0.06, 0.075)!;
      final bright = ColorTemperatureMath.fromLinearRgb(0.5, 0.6, 0.75)!;
      expect(dim.kelvin, closeTo(bright.kelvin, 1e-6));
      expect(dim.duv, closeTo(bright.duv, 1e-9));
    });

    test('gamma-encoded brightness barely moves it at usable temperatures', () {
      // Encoded values run through a near-power-law curve, which preserves
      // ratios only approximately, and 8-bit steps quantise them. Around
      // daylight that is worth a few per cent.
      final dim = ColorTemperatureMath.fromRgb8(90, 96, 104)!;
      final bright = ColorTemperatureMath.fromRgb8(180, 192, 208)!;
      expect(dim.kelvin, closeTo(bright.kelvin, bright.kelvin * 0.08));
    });

    test('is deliberately ill-conditioned at the blue extreme', () {
      // Above roughly 10000 K the locus flattens, so a chromaticity shift too
      // small to see swings the temperature by thousands. This is a property of
      // CCT, not a defect — which is why such readings are flagged rather than
      // presented as measurements.
      final a = ColorTemperatureMath.fromRgb8(60, 75, 92)!;
      final b = ColorTemperatureMath.fromRgb8(120, 150, 184)!;
      expect(a.kelvin, greaterThan(10000));
      expect(b.kelvin, greaterThan(10000));
      expect((a.kelvin - b.kelvin).abs(), greaterThan(500));
      // Both must decline to claim confidence.
      expect(a.confidence, CctConfidence.low);
      expect(b.confidence, CctConfidence.low);
    });
  });

  group('white balance reference', () {
    test('a neutral patch under a declared light yields those gains', () {
      // The camera reported neutral; the light was really tungsten. The
      // reference has to carry the whole difference.
      final reference = WhiteBalanceReference.fromNeutralPatch(
        r: 128,
        g: 128,
        b: 128,
        kelvin: 3200,
      );
      expect(reference, isNotNull);
      // Tungsten is red-heavy and blue-poor relative to D65.
      expect(reference!.gainR, greaterThan(1.0));
      expect(reference.gainB, lessThan(1.0));
      expect(reference.referenceKelvin, 3200);
    });

    test('applying the reference recovers the declared temperature', () {
      // This is the property that makes the reference worth storing.
      for (final kelvin in [2800.0, 3200.0, 4000.0, 5500.0]) {
        final reference = WhiteBalanceReference.fromNeutralPatch(
          r: 128,
          g: 128,
          b: 128,
          kelvin: kelvin,
        );
        expect(reference, isNotNull, reason: '$kelvin');
        final corrected = ColorTemperatureMath.fromRgb8(
          128,
          128,
          128,
          reference: reference,
        );
        expect(corrected, isNotNull, reason: '$kelvin');
        expect(
          corrected!.kelvin,
          closeTo(kelvin, kelvin * 0.02),
          reason: 'declared $kelvin, read back ${corrected.kelvin}',
        );
      }
    });

    test('refuses a patch that was clearly not neutral', () {
      // A strongly coloured "reference" would poison every later reading.
      expect(
        WhiteBalanceReference.fromNeutralPatch(
          r: 240,
          g: 60,
          b: 30,
          kelvin: 5500,
        ),
        isNull,
      );
    });

    test('refuses clipped or noise-level patches', () {
      expect(
        WhiteBalanceReference.fromNeutralPatch(
          r: 251,
          g: 251,
          b: 251,
          kelvin: 5500,
        ),
        isNull,
      );
      expect(
        WhiteBalanceReference.fromNeutralPatch(
          r: 4,
          g: 4,
          b: 4,
          kelvin: 5500,
        ),
        isNull,
      );
    });

    test('refuses a temperature outside the supported range', () {
      expect(
        WhiteBalanceReference.fromNeutralPatch(
          r: 128,
          g: 128,
          b: 128,
          kelvin: 900,
        ),
        isNull,
      );
    });

    test('round trips through JSON', () {
      final reference = WhiteBalanceReference.fromNeutralPatch(
        r: 128,
        g: 128,
        b: 128,
        kelvin: 3200,
      )!;
      final restored = WhiteBalanceReference.fromJson(reference.toJson())!;
      expect(restored.gainR, closeTo(reference.gainR, 1e-12));
      expect(restored.gainB, closeTo(reference.gainB, 1e-12));
      expect(restored.referenceKelvin, reference.referenceKelvin);
    });

    test('rejects corrupt or hostile stored values', () {
      expect(WhiteBalanceReference.fromJson(null), isNull);
      expect(WhiteBalanceReference.fromJson('nope'), isNull);
      // Zero or negative gains would produce nonsense or division by zero.
      expect(
        WhiteBalanceReference.fromJson(
          {'gainR': 0, 'gainB': 1, 'referenceKelvin': 5500},
        ),
        isNull,
      );
      expect(
        WhiteBalanceReference.fromJson(
          {'gainR': -1, 'gainB': 1, 'referenceKelvin': 5500},
        ),
        isNull,
      );
      // A gain this large did not come from a neutral patch.
      expect(
        WhiteBalanceReference.fromJson(
          {'gainR': 64, 'gainB': 1, 'referenceKelvin': 5500},
        ),
        isNull,
      );
      expect(
        WhiteBalanceReference.fromJson(
          {'gainR': 1, 'gainB': 1, 'referenceKelvin': 100},
        ),
        isNull,
      );
      expect(
        WhiteBalanceReference.fromJson(
          {'gainR': double.nan, 'gainB': 1, 'referenceKelvin': 5500},
        ),
        isNull,
      );
    });

    test('reports how hard it is working', () {
      final mild = WhiteBalanceReference.fromNeutralPatch(
        r: 128,
        g: 128,
        b: 128,
        kelvin: 6000,
      )!;
      final strong = WhiteBalanceReference.fromNeutralPatch(
        r: 128,
        g: 128,
        b: 128,
        kelvin: 2800,
      )!;
      expect(strong.strengthStops, greaterThan(mild.strengthStops));
    });
  });
}
