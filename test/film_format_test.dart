import 'dart:math';

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

    test('6×6 is square 56 mm gate and 80 mm ≈ 44 mm eq', () {
      expect(FilmFormat.sixBySix.isSquare, isTrue);
      expect(FilmFormat.sixBySix.widthMm, 56);
      // 80 mm on 56×56 ≈ 43.7 mm on 35 mm (diagonal crop).
      expect(
        FilmFormat.sixBySix.to35mmEquivalent(80),
        closeTo(43.7, 0.3),
      );
    });
  });

  group('screen axes', () {
    test('portrait maps short sensor side to horizontal', () {
      final axes = FilmOptics.screenAxesFromSensor(
        sensorWidthMm: 7.0,
        sensorHeightMm: 5.0,
        previewPortrait: true,
      );
      expect(axes.horizMm, 5.0);
      expect(axes.vertMm, 7.0);
    });

    test('landscape maps long sensor side to horizontal', () {
      final axes = FilmOptics.screenAxesFromSensor(
        sensorWidthMm: 7.0,
        sensorHeightMm: 5.0,
        previewPortrait: false,
      );
      expect(axes.horizMm, 7.0);
      expect(axes.vertMm, 5.0);
    });
  });

  group('FOV crop', () {
    test('matching FOVs keep the full frame on 6×6', () {
      final fraction = FilmOptics.cropFraction(
        format: FilmFormat.sixBySix,
        phoneFocalMm: 80,
        phoneSensorWidthMm: 56,
        phoneSensorHeightMm: 56,
        simulatedFocalMm: 80,
        previewPortrait: false,
      );
      expect(fraction, 1.0);
    });

    test('6×6 uses the 56 mm gate, not a 60 mm film width', () {
      final crop56 = FilmOptics.cropFraction(
        format: FilmFormat.sixBySix,
        phoneFocalMm: 4.2,
        phoneSensorWidthMm: 6.3,
        phoneSensorHeightMm: 4.7,
        simulatedFocalMm: 150,
      );
      // Same phone, but FOV as if the gate were the old incorrect 60 mm.
      final fov60 = FilmOptics.fieldOfViewRadians(150, 60);
      final screen = FilmOptics.screenAxesFromSensor(
        sensorWidthMm: 6.3,
        sensorHeightMm: 4.7,
      );
      final fovPhone = FilmOptics.fieldOfViewRadians(4.2, screen.horizMm);
      final crop60 = tan(fov60 / 2) / tan(fovPhone / 2);
      expect(crop56, lessThan(crop60));
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
      expect(normal, lessThan(1.0));
      expect(tele, lessThan(normal));
    });

    test('645 and 6×6 share the 56 mm width so HFOV crop matches', () {
      // Both gates are 56 mm wide; horizontal FOV — and thus crop — match.
      // They differ only in viewfinder aspect (and vertical FOV).
      const phoneF = 4.2;
      const sensorW = 7.0;
      const sensorH = 5.2;
      final crop645 = FilmOptics.cropFraction(
        format: FilmFormat.sixFourFive,
        phoneFocalMm: phoneF,
        phoneSensorWidthMm: sensorW,
        phoneSensorHeightMm: sensorH,
        simulatedFocalMm: 75,
      );
      final crop66 = FilmOptics.cropFraction(
        format: FilmFormat.sixBySix,
        phoneFocalMm: phoneF,
        phoneSensorWidthMm: sensorW,
        phoneSensorHeightMm: sensorH,
        simulatedFocalMm: 75,
      );
      expect(crop645, closeTo(crop66, 1e-9));
      expect(FilmFormat.sixFourFive.aspectRatio, isNot(1));
      expect(FilmFormat.sixBySix.isSquare, isTrue);
    });

    test('portrait axis mapping changes the crop vs landscape sensor axes', () {
      final portrait = FilmOptics.cropFraction(
        format: FilmFormat.thirtyFive,
        phoneFocalMm: 4.2,
        phoneSensorWidthMm: 7.0,
        phoneSensorHeightMm: 5.2,
        simulatedFocalMm: 50,
        previewPortrait: true,
      );
      final landscape = FilmOptics.cropFraction(
        format: FilmFormat.thirtyFive,
        phoneFocalMm: 4.2,
        phoneSensorWidthMm: 7.0,
        phoneSensorHeightMm: 5.2,
        simulatedFocalMm: 50,
        previewPortrait: false,
      );
      expect(portrait, isNot(closeTo(landscape, 1e-6)));
    });

    test('sensor path covers film aspect before matching FOV', () {
      final fraction = FilmOptics.cropFraction(
        format: FilmFormat.thirtyFive,
        phoneFocalMm: 4,
        phoneSensorWidthMm: 7,
        phoneSensorHeightMm: 5,
        simulatedFocalMm: 50,
        previewPortrait: false,
      );
      expect(fraction, lessThan(1.0));
      expect(fraction, greaterThan(0.05));
    });

    test('wider than phone FOV hits the limit', () {
      final fraction = FilmOptics.cropFractionFrom35mm(
        format: FilmFormat.thirtyFive,
        phone35mmEquivalent: 26,
        simulatedFocalMm: 24,
      );
      expect(fraction, 1.0);
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

    test('diagonal 35 mm-eq from sensor matches full-frame identity', () {
      final eq = FilmOptics.equivalent35mmFromSensor(
        focalMm: 50,
        sensorWidthMm: 36,
        sensorHeightMm: 24,
      );
      expect(eq, closeTo(50, 0.01));
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
