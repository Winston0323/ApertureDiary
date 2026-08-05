import 'package:flutter_test/flutter_test.dart';
import 'package:light_meter/exposure.dart';

void main() {
  group('exposure solving', () {
    test('sunny 16: f/16, ISO 100 at EV 15 → ~1/125s', () {
      // t = 16² / 2^15 = 256/32768 = 1/128
      final t = ExposureMath.shutterFromEv(ev100: 15, aperture: 16, iso: 100);
      expect(t, closeTo(1 / 128, 0.0001));
      expect(ExposureMath.formatShutter(ExposureMath.snapShutter(t)), '1/125');
    });

    test('solve aperture from shutter', () {
      final n = ExposureMath.apertureFromEv(
        ev100: 15,
        shutterSeconds: 1 / 125,
        iso: 100,
      );
      // N = sqrt(t · 2^EV) = sqrt(32768/125) ≈ 16.19
      expect(n, closeTo(16.19, 0.05));
      expect(ExposureMath.snapAperture(n), 16.0);
    });

    test('quadrupling ISO quarters the shutter time', () {
      final t100 =
          ExposureMath.shutterFromEv(ev100: 12, aperture: 5.6, iso: 100);
      final t400 =
          ExposureMath.shutterFromEv(ev100: 12, aperture: 5.6, iso: 400);
      expect(t400, closeTo(t100 / 4, 1e-9));
    });
  });

  group('camera exposure → EV', () {
    test('EV₁₀₀ of a known exposure', () {
      // f/16, 1/128s, ISO 100 is EV 15.
      final ev = ExposureMath.cameraEv100(
        aperture: 16,
        shutterSeconds: 1 / 128,
        iso: 100,
      );
      expect(ev, closeTo(15.0, 0.001));
    });

    test('higher ISO for the same exposure means a darker scene', () {
      final low = ExposureMath.cameraEv100(
        aperture: 2.0,
        shutterSeconds: 1 / 60,
        iso: 100,
      );
      final high = ExposureMath.cameraEv100(
        aperture: 2.0,
        shutterSeconds: 1 / 60,
        iso: 1600,
      );
      expect(low - high, closeTo(4.0, 1e-9));
    });

    test('round trip: solving for the shutter reproduces the exposure', () {
      const aperture = 2.8;
      const iso = 200;
      const shutter = 1 / 250;
      final ev = ExposureMath.cameraEv100(
        aperture: aperture,
        shutterSeconds: shutter,
        iso: iso.toDouble(),
      );
      final solved = ExposureMath.shutterFromEv(
        ev100: ev,
        aperture: aperture,
        iso: iso,
      );
      expect(solved, closeTo(shutter, 1e-9));
    });
  });

  group('scene EV from a sampled point', () {
    test('a middle grey patch reads the exposure EV itself', () {
      final ev = ExposureMath.sceneEv(
        cameraEv100: 12.0,
        linearLuminance: ExposureMath.middleGrey,
      );
      expect(ev, closeTo(12.0, 1e-9));
    });

    test('doubling patch luminance adds one stop', () {
      final base = ExposureMath.sceneEv(
        cameraEv100: 10.0,
        linearLuminance: 0.18,
      );
      final brighter = ExposureMath.sceneEv(
        cameraEv100: 10.0,
        linearLuminance: 0.36,
      );
      expect(brighter - base, closeTo(1.0, 1e-9));
    });

    test('black patch stays finite', () {
      final ev =
          ExposureMath.sceneEv(cameraEv100: 10.0, linearLuminance: 0.0);
      expect(ev.isFinite, isTrue);
    });
  });

  group('sRGB linearization', () {
    test('endpoints and mid grey', () {
      expect(ExposureMath.srgbToLinear(0.0), closeTo(0.0, 1e-9));
      expect(ExposureMath.srgbToLinear(1.0), closeTo(1.0, 1e-9));
      // 18% linear grey encodes to roughly 0.46 in sRGB.
      expect(ExposureMath.srgbToLinear(0.4613), closeTo(0.18, 0.005));
    });

    test('lookup table matches the function', () {
      expect(ExposureMath.srgbLut[255], closeTo(1.0, 1e-9));
      expect(
        ExposureMath.srgbLut[128],
        closeTo(ExposureMath.srgbToLinear(128 / 255), 1e-12),
      );
    });

    test('a mid grey pixel linearizes near 18%', () {
      expect(
        ExposureMath.linearLuminance8(118, 118, 118),
        closeTo(0.18, 0.01),
      );
    });

    test('encoded grey is not linear grey', () {
      // The old reading treated encoded values as linear, which overstates
      // shadow luminance by a lot.
      expect(ExposureMath.linearLuminance8(128, 128, 128), lessThan(0.25));
    });
  });

  group('formatting', () {
    test('shutter', () {
      expect(ExposureMath.formatShutter(1 / 125), '1/125');
      expect(ExposureMath.formatShutter(1 / 60), '1/60');
      expect(ExposureMath.formatShutter(1.0), '1"');
      expect(ExposureMath.formatShutter(2.0), '2"');
      expect(ExposureMath.formatShutter(0), '—');
    });

    test('aperture', () {
      expect(ExposureMath.formatAperture(2.8), 'f/2.8');
      expect(ExposureMath.formatAperture(16), 'f/16');
    });

    test('stops', () {
      expect(ExposureMath.formatStops(1.25), '+1.3 EV');
      expect(ExposureMath.formatStops(-0.5), '−0.5 EV');
    });
  });
}
