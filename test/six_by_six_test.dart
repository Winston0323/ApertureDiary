import 'package:flutter_test/flutter_test.dart';
import 'package:light_meter/six_by_six.dart';

void main() {
  group('6×6 equivalents', () {
    test('80 mm on 6×6 is about 41 mm on 35 mm', () {
      expect(SixBySix.to35mmEquivalent(80), closeTo(40.8, 0.2));
    });

    test('formats focal lengths', () {
      expect(SixBySix.formatFocal(80), '80 mm');
      expect(SixBySix.formatFocal(75.5), '75.5 mm');
    });
  });

  group('FOV crop', () {
    test('matching FOVs keep the full frame', () {
      // Phone short side 5 mm at 4.2 mm ≈ FOV of 80 mm on 6×6?
      // Use identical FOV by construction: phone sensor 60 mm, focal 80 mm.
      final fraction = SixBySix.cropFraction(
        phoneFocalMm: 80,
        phoneSensorWidthMm: 60,
        simulatedFocalMm: 80,
      );
      expect(fraction, 1.0);
    });

    test('doubling the simulated focal halves the crop (small-angle)', () {
      // Wide phone: short side 7 mm, focal 4 mm.
      final wide = SixBySix.cropFraction(
        phoneFocalMm: 4,
        phoneSensorWidthMm: 7,
        simulatedFocalMm: 80,
      );
      final tele = SixBySix.cropFraction(
        phoneFocalMm: 4,
        phoneSensorWidthMm: 7,
        simulatedFocalMm: 160,
      );
      expect(wide, lessThan(1.0));
      expect(tele, lessThan(wide));
      // Exact ratio isn't 1/2 because tan isn't linear, but close.
      expect(tele / wide, closeTo(0.5, 0.08));
    });

    test('zoom narrows the phone FOV and reduces crop demand', () {
      final unzoomed = SixBySix.cropFraction(
        phoneFocalMm: 4,
        phoneSensorWidthMm: 7,
        simulatedFocalMm: 80,
        zoom: 1,
      );
      final zoomed = SixBySix.cropFraction(
        phoneFocalMm: 4,
        phoneSensorWidthMm: 7,
        simulatedFocalMm: 80,
        zoom: 2,
      );
      expect(zoomed, greaterThan(unzoomed));
    });

    test('35 mm-equivalent path matches the diagonal conversion', () {
      // Phone at 26 mm eq, 80 mm on 6×6 ≈ 40.8 mm eq → crop ≈ 26/40.8.
      final fraction = SixBySix.cropFractionFrom35mm(
        phone35mmEquivalent: 26,
        simulatedFocalMm: 80,
      );
      expect(fraction, closeTo(26 / SixBySix.to35mmEquivalent(80), 1e-9));
    });

    test('asking for a wider lens than the phone can see stays at 1.0', () {
      final fraction = SixBySix.cropFractionFrom35mm(
        phone35mmEquivalent: 50,
        simulatedFocalMm: 40, // ~20 mm eq — wider than the phone
      );
      expect(fraction, 1.0);
    });
  });

  group('viewfinder mapping', () {
    test('centre stays centre', () {
      final p = SixBySix.mapViewfinderToPreview(0.5, 0.5, 0.5);
      expect(p.x, 0.5);
      expect(p.y, 0.5);
    });

    test('edges map inward by the crop fraction', () {
      final p = SixBySix.mapViewfinderToPreview(0.0, 1.0, 0.5);
      expect(p.x, closeTo(0.25, 1e-9));
      expect(p.y, closeTo(0.75, 1e-9));
    });
  });
}
