import 'package:flutter_test/flutter_test.dart';
import 'package:light_meter/flash.dart';

void main() {
  group('guide number scaling', () {
    test('ISO 100 uses the rated guide number', () {
      expect(
        FlashMath.guideNumberAtIso(guideNumberIso100: 36, iso: 100),
        closeTo(36, 1e-9),
      );
    });

    test('four times the ISO doubles the guide number', () {
      expect(
        FlashMath.guideNumberAtIso(guideNumberIso100: 36, iso: 400),
        closeTo(72, 1e-9),
      );
    });

    test('a stop of ISO is a factor of √2', () {
      expect(
        FlashMath.guideNumberAtIso(guideNumberIso100: 36, iso: 200),
        closeTo(36 * 1.4142135, 1e-5),
      );
    });
  });

  group('power needed', () {
    test('GN 36 at f/8 and 4.5 m is exactly full power', () {
      // N × d = 36, which is the guide number itself.
      final fraction = FlashMath.powerFraction(
        guideNumberIso100: 36,
        iso: 100,
        aperture: 8,
        distance: 4.5,
      );
      expect(fraction, closeTo(1.0, 1e-9));
      expect(FlashMath.snapPower(fraction), 1.0);
    });

    test('halving the distance needs a quarter of the power', () {
      final fraction = FlashMath.powerFraction(
        guideNumberIso100: 36,
        iso: 100,
        aperture: 8,
        distance: 2.25,
      );
      expect(fraction, closeTo(0.25, 1e-9));
      expect(FlashMath.formatPower(FlashMath.snapPower(fraction)), '1/4');
    });

    test('two stops of extra ISO saves two stops of power', () {
      final fraction = FlashMath.powerFraction(
        guideNumberIso100: 36,
        iso: 400,
        aperture: 8,
        distance: 4.5,
      );
      expect(fraction, closeTo(0.25, 1e-9));
    });

    test('closing down two stops needs four times the power', () {
      final wide = FlashMath.powerFraction(
        guideNumberIso100: 36,
        iso: 100,
        aperture: 2.8,
        distance: 3,
      );
      final closed = FlashMath.powerFraction(
        guideNumberIso100: 36,
        iso: 100,
        aperture: 5.6,
        distance: 3,
      );
      expect(closed / wide, closeTo(4.0, 1e-9));
    });

    test('out of reach when it exceeds full power', () {
      final fraction = FlashMath.powerFraction(
        guideNumberIso100: 20,
        iso: 100,
        aperture: 11,
        distance: 6,
      );
      expect(fraction, greaterThan(1.0));
      // 66/20 = 3.3× the guide number, so 2·log2(3.3) ≈ 3.44 stops short.
      expect(FlashMath.stopsBeyondFullPower(fraction), closeTo(3.44, 0.01));
    });

    test('invalid inputs do not produce a number', () {
      expect(
        FlashMath.powerFraction(
          guideNumberIso100: 0,
          iso: 100,
          aperture: 8,
          distance: 4,
        ).isNaN,
        isTrue,
      );
      expect(
        FlashMath.powerFraction(
          guideNumberIso100: 36,
          iso: 100,
          aperture: 8,
          distance: 0,
        ).isNaN,
        isTrue,
      );
    });
  });

  group('reach', () {
    test('full power reach is GN ÷ aperture', () {
      expect(
        FlashMath.distanceAtPower(
          guideNumberIso100: 36,
          iso: 100,
          aperture: 8,
          fraction: 1,
        ),
        closeTo(4.5, 1e-9),
      );
    });

    test('quarter power halves the reach', () {
      expect(
        FlashMath.distanceAtPower(
          guideNumberIso100: 36,
          iso: 100,
          aperture: 8,
          fraction: 0.25,
        ),
        closeTo(2.25, 1e-9),
      );
    });

    test('aperture for a distance at full power', () {
      expect(
        FlashMath.apertureAtPower(
          guideNumberIso100: 36,
          iso: 100,
          distance: 4.5,
          fraction: 1,
        ),
        closeTo(8.0, 1e-9),
      );
    });

    test('reach and required power are inverses', () {
      const gn = 45.0;
      const iso = 200;
      const aperture = 4.0;
      const fraction = 1 / 8;
      final d = FlashMath.distanceAtPower(
        guideNumberIso100: gn,
        iso: iso,
        aperture: aperture,
        fraction: fraction,
      );
      final back = FlashMath.powerFraction(
        guideNumberIso100: gn,
        iso: iso,
        aperture: aperture,
        distance: d,
      );
      expect(back, closeTo(fraction, 1e-9));
    });
  });

  group('snapping to dial settings', () {
    test('snaps by stops, not arithmetic distance', () {
      // 0.2 is closer to 0.25 than to 0.125 in stops.
      expect(FlashMath.snapPower(0.2), 0.25);
      expect(FlashMath.snapPower(0.09), 1 / 8);
      expect(FlashMath.snapPower(0.7), 1 / 2);
    });

    test('clamps to the weakest available setting', () {
      expect(FlashMath.snapPower(0.0001), FlashMath.weakestPower);
    });

    test('reports the rounding error in stops', () {
      final error = FlashMath.snapErrorStops(exact: 0.2, snapped: 0.25);
      expect(error, closeTo(0.32, 0.01)); // Slightly over-exposed.
      expect(
        FlashMath.snapErrorStops(exact: 0.25, snapped: 0.25),
        closeTo(0, 1e-9),
      );
    });
  });

  group('formatting', () {
    test('power as a dial fraction', () {
      expect(FlashMath.formatPower(1), '1/1');
      expect(FlashMath.formatPower(0.25), '1/4');
      expect(FlashMath.formatPower(1 / 128), '1/128');
      expect(FlashMath.formatPower(0), '—');
    });

    test('power as a percentage', () {
      expect(FlashMath.formatPowerPercent(1), '100%');
      expect(FlashMath.formatPowerPercent(0.25), '25%');
      expect(FlashMath.formatPowerPercent(0.019), '1.9%');
    });
  });
}
