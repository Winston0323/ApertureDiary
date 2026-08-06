import 'dart:ui';

import 'package:exif/exif.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/metering.dart';

/// 640×480 sensor frame shown in a 480×640 portrait preview.
SpotMapping? mapPortrait(Offset spot, {int quarterTurns = 1}) {
  return mapSpotToFrame(
    frameWidth: 640,
    frameHeight: 480,
    quarterTurns: quarterTurns,
    mirror: false,
    widgetSize: const Size(480, 640),
    spot: spot,
    radiusInWidgetPixels: 18,
  );
}

IfdTag ratioTag(int numerator, int denominator) => IfdTag(
      tag: 0,
      tagType: 'Ratio',
      printable: '$numerator/$denominator',
      values: IfdRatios([Ratio(numerator, denominator)]),
    );

IfdTag intTag(int value) => IfdTag(
      tag: 0,
      tagType: 'Int',
      printable: '$value',
      values: IfdInts([value]),
    );

void main() {
  group('spot → frame mapping', () {
    test('centre of the preview is the centre of the frame', () {
      final m = mapPortrait(const Offset(0.5, 0.5))!;
      expect(m.x, closeTo(320, 1.5));
      expect(m.y, closeTo(240, 1.5));
    });

    test('a portrait preview rotates the axes', () {
      // With a 90° sensor, the top of a portrait preview is the left edge of
      // the landscape frame — mapping straight through would meter the wrong
      // part of the scene entirely.
      final top = mapPortrait(const Offset(0.5, 0.0))!;
      expect(top.x, closeTo(0, 1.5));
      expect(top.y, closeTo(240, 1.5));

      final bottom = mapPortrait(const Offset(0.5, 1.0))!;
      expect(bottom.x, closeTo(639, 1.5));
      expect(bottom.y, closeTo(240, 1.5));

      final left = mapPortrait(const Offset(0.0, 0.5))!;
      expect(left.x, closeTo(320, 1.5));
      expect(left.y, closeTo(479, 1.5));

      final right = mapPortrait(const Offset(1.0, 0.5))!;
      expect(right.x, closeTo(320, 1.5));
      expect(right.y, closeTo(0, 1.5));
    });

    test('an unrotated frame maps straight through', () {
      final m = mapSpotToFrame(
        frameWidth: 640,
        frameHeight: 480,
        quarterTurns: 0,
        mirror: false,
        widgetSize: const Size(640, 480),
        spot: const Offset(0.25, 0.75),
        radiusInWidgetPixels: 10,
      )!;
      expect(m.x, closeTo(160, 1.5));
      expect(m.y, closeTo(360, 1.5));
      expect(m.radius, closeTo(10, 0.01));
    });

    test('mirroring flips the horizontal axis only', () {
      final normal = mapPortrait(const Offset(0.2, 0.5))!;
      final mirrored = mapSpotToFrame(
        frameWidth: 640,
        frameHeight: 480,
        quarterTurns: 1,
        mirror: true,
        widgetSize: const Size(480, 640),
        spot: const Offset(0.8, 0.5),
        radiusInWidgetPixels: 18,
      )!;
      expect(mirrored.x, closeTo(normal.x, 0.01));
      expect(mirrored.y, closeTo(normal.y, 0.01));
    });

    test('cover cropping scales the sampled radius', () {
      // A 4:3 frame filling a 16:9 preview is scaled by 1280/640 = 2, so each
      // widget pixel covers half a frame pixel.
      final m = mapSpotToFrame(
        frameWidth: 640,
        frameHeight: 480,
        quarterTurns: 0,
        mirror: false,
        widgetSize: const Size(1280, 720),
        spot: const Offset(0.5, 0.5),
        radiusInWidgetPixels: 18,
      )!;
      expect(m.x, closeTo(320, 1.5));
      expect(m.y, closeTo(240, 1.5));
      expect(m.radius, closeTo(9, 0.01));
    });

    test('degenerate sizes are rejected', () {
      expect(
        mapSpotToFrame(
          frameWidth: 0,
          frameHeight: 480,
          quarterTurns: 1,
          mirror: false,
          widgetSize: const Size(480, 640),
          spot: Offset.zero,
          radiusInWidgetPixels: 18,
        ),
        isNull,
      );
      expect(
        mapSpotToFrame(
          frameWidth: 640,
          frameHeight: 480,
          quarterTurns: 1,
          mirror: false,
          widgetSize: Size.zero,
          spot: Offset.zero,
          radiusInWidgetPixels: 18,
        ),
        isNull,
      );
    });
  });

  group('EXIF exposure parsing', () {
    test('reads direct exposure tags', () {
      final params = parseExposureParams({
        'EXIF ExposureTime': ratioTag(1, 120),
        'EXIF FNumber': ratioTag(18, 10),
        'EXIF ISOSpeedRatings': intTag(250),
      });
      expect(params, isNotNull);
      expect(params!.shutterSeconds, closeTo(1 / 120, 1e-9));
      expect(params.aperture, closeTo(1.8, 1e-9));
      expect(params.iso, 250);
      // EV₁₀₀ = log2(1.8²·120) − log2(2.5) ≈ 7.28, a bright interior.
      expect(params.ev100, closeTo(7.28, 0.01));
    });

    test('falls back to APEX aperture and shutter values', () {
      final params = parseExposureParams({
        // Av 4 → f/4, Tv 7 → 1/128s
        'EXIF ApertureValue': ratioTag(4, 1),
        'EXIF ShutterSpeedValue': ratioTag(7, 1),
        'EXIF PhotographicSensitivity': intTag(100),
      });
      expect(params, isNotNull);
      expect(params!.aperture, closeTo(4.0, 1e-6));
      expect(params.shutterSeconds, closeTo(1 / 128, 1e-9));
    });

    test('returns null when exposure data is missing', () {
      expect(parseExposureParams({}), isNull);
      expect(
        parseExposureParams({'EXIF ExposureTime': ratioTag(1, 60)}),
        isNull,
      );
    });

    test('rejects nonsense values', () {
      expect(
        parseExposureParams({
          'EXIF ExposureTime': ratioTag(0, 60),
          'EXIF FNumber': ratioTag(18, 10),
          'EXIF ISOSpeedRatings': intTag(100),
        }),
        isNull,
      );
    });
  });

  group('spot sample quality', () {
    SpotSample sample(double encoded, double linear) => SpotSample(
          linearLuminance: linear,
          encodedLuminance: encoded,
          r: 0,
          g: 0,
          b: 0,
        );

    test('flags clipped and crushed patches', () {
      expect(sample(0.99, 0.98).isClipped, isTrue);
      expect(sample(0.99, 0.98).isUsable, isFalse);
      expect(sample(0.01, 0.001).isCrushed, isTrue);
      expect(sample(0.46, 0.18).isUsable, isTrue);
    });

    test('reports stops from middle grey', () {
      expect(sample(0.46, 0.18).stopsFromMiddleGrey, closeTo(0.0, 1e-9));
      expect(sample(0.6, 0.36).stopsFromMiddleGrey, closeTo(1.0, 1e-9));
    });
  });
}
