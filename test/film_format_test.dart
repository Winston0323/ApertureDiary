import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/film_format.dart';

void main() {
  group('format geometry', () {
    test('36×24 is 3:2', () {
      expect(FilmFormat.thirtyFive.aspectRatio, closeTo(1.5, 1e-9));
      expect(FilmFormat.thirtyFive.to35mmEquivalent(50), closeTo(50, 0.01));
    });

    test('645 is about 1.35:1', () {
      expect(FilmFormat.sixFourFive.aspectRatio, closeTo(56 / 41.5, 1e-9));
      // 75 mm on 645 ≈ 46.6 mm on 35 mm.
      expect(
        FilmFormat.sixFourFive.to35mmEquivalent(75),
        closeTo(46.6, 0.3),
      );
    });

    test('6×6 is square and 80 mm ≈ 41 mm eq', () {
      expect(FilmFormat.sixBySix.isSquare, isTrue);
      expect(
        FilmFormat.sixBySix.to35mmEquivalent(80),
        closeTo(40.8, 0.2),
      );
    });
  });

  group('FOV crop', () {
    test('matching FOVs keep the full frame on 6×6', () {
      final fraction = FilmOptics.cropFraction(
        format: FilmFormat.sixBySix,
        phoneFocalMm: 80,
        phoneSensorWidthMm: 60,
        phoneSensorHeightMm: 60,
        simulatedFocalMm: 80,
      );
      expect(fraction, 1.0);
    });

    test('36×24 at 50 mm matches a 50 mm-eq phone', () {
      final fraction = FilmOptics.cropFractionFrom35mm(
        format: FilmFormat.thirtyFive,
        phone35mmEquivalent: 50,
        simulatedFocalMm: 50,
      );
      expect(fraction, 1.0);
    });

    test('longer 36×24 lens crops tighter', () {
      final normal = FilmOptics.cropFractionFrom35mm(
        format: FilmFormat.thirtyFive,
        phone35mmEquivalent: 26,
        simulatedFocalMm: 50,
      );
      final tele = FilmOptics.cropFractionFrom35mm(
        format: FilmFormat.thirtyFive,
        phone35mmEquivalent: 26,
        simulatedFocalMm: 85,
      );
      expect(normal, closeTo(26 / 50, 1e-6));
      expect(tele, lessThan(normal));
      expect(tele, closeTo(26 / 85, 1e-6));
    });

    test('645 crop uses the format diagonal', () {
      final fraction = FilmOptics.cropFractionFrom35mm(
        format: FilmFormat.sixFourFive,
        phone35mmEquivalent: 26,
        simulatedFocalMm: 75,
      );
      expect(
        fraction,
        closeTo(26 / FilmFormat.sixFourFive.to35mmEquivalent(75), 1e-9),
      );
    });

    test('sensor path covers film aspect before matching FOV', () {
      // Phone 7×5 mm landscape; film 3:2 → visible width = 5 * 1.5 = 7.5? 
      // phoneAspect 1.4, filmAspect 1.5 → phone is narrower relatively,
      // so width fills: visibleWidth = 7.
      final fraction = FilmOptics.cropFraction(
        format: FilmFormat.thirtyFive,
        phoneFocalMm: 4,
        phoneSensorWidthMm: 7,
        phoneSensorHeightMm: 5,
        simulatedFocalMm: 50,
      );
      expect(fraction, lessThan(1.0));
      expect(fraction, greaterThan(0.05));
    });

    test('zoom reduces how much digital crop is needed', () {
      final unzoomed = FilmOptics.cropFraction(
        format: FilmFormat.sixBySix,
        phoneFocalMm: 4,
        phoneSensorWidthMm: 7,
        phoneSensorHeightMm: 5,
        simulatedFocalMm: 80,
        zoom: 1,
      );
      final zoomed = FilmOptics.cropFraction(
        format: FilmFormat.sixBySix,
        phoneFocalMm: 4,
        phoneSensorWidthMm: 7,
        phoneSensorHeightMm: 5,
        simulatedFocalMm: 80,
        zoom: 2,
      );
      expect(zoomed, greaterThan(unzoomed));
    });
  });

  group('viewfinder fit', () {
    test('letterboxes a landscape frame in a portrait bound', () {
      final fitted = FilmOptics.fitAspect(
        maxWidth: 400,
        maxHeight: 800,
        aspect: 1.5,
      );
      expect(fitted.width, closeTo(400, 1e-9));
      expect(fitted.height, closeTo(400 / 1.5, 1e-9));
    });

    test('pillarboxes a square in a wide bound', () {
      final fitted = FilmOptics.fitAspect(
        maxWidth: 800,
        maxHeight: 400,
        aspect: 1,
      );
      expect(fitted.width, closeTo(400, 1e-9));
      expect(fitted.height, closeTo(400, 1e-9));
    });
  });

  group('viewfinder mapping', () {
    test('centre stays centre', () {
      final p = FilmOptics.mapViewfinderToPreview(0.5, 0.5, 0.5);
      expect(p.x, 0.5);
      expect(p.y, 0.5);
    });

    test('edges map inward by the crop fraction', () {
      final p = FilmOptics.mapViewfinderToPreview(0.0, 1.0, 0.5);
      expect(p.x, closeTo(0.25, 1e-9));
      expect(p.y, closeTo(0.75, 1e-9));
    });
  });
}
