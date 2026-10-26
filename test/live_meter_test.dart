import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/capture_metadata.dart';
import 'package:aperture_diary/exposure.dart';
import 'package:aperture_diary/live_meter.dart';
import 'package:aperture_diary/metering.dart';

/// Metadata describing a frame exposed at [ev100].
CaptureMetadata frameAt({
  required double ev100,
  bool aeConverged = true,
}) {
  // Work back to a shutter time at f/1.88, ISO 72 — the values the test device
  // actually reports.
  const aperture = 1.88;
  const iso = 72.0;
  final lensEv = ev100 + ExposureMath.log2(iso / 100.0);
  final shutter = aperture * aperture / _pow2(lensEv);

  return CaptureMetadata(
    exposureTimeSeconds: shutter,
    iso: iso.round(),
    aperture: aperture,
    postRawSensitivityBoost: 100,
    aeConverged: aeConverged,
    receivedAt: DateTime.now(),
  );
}

double _pow2(double x) {
  var result = 1.0;
  for (var i = 0; i < x.floor().abs(); i++) {
    result = x >= 0 ? result * 2 : result / 2;
  }
  final frac = x - x.floor();
  return result * _exp2Frac(frac);
}

double _exp2Frac(double f) {
  // 2^f for f in [0,1), via the series for exp(f·ln2).
  final x = f * 0.6931471805599453;
  var term = 1.0;
  var sum = 1.0;
  for (var n = 1; n < 20; n++) {
    term *= x / n;
    sum += term;
  }
  return sum;
}

SpotSample patchAt(double encoded) {
  final channel = (encoded * 255).round().clamp(0, 255);
  return SpotSample(
    linearLuminance: ExposureMath.srgbToLinear(encoded),
    encodedLuminance: encoded,
    r: channel,
    g: channel,
    b: channel,
  );
}

void main() {
  group('reading a frame', () {
    test('a patch on target reports the exposure unchanged', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 8.0),
        sample: patchAt(LiveMeter.target),
      );

      expect(reading, isNotNull);
      expect(reading!.sceneEv100, closeTo(8.0, 0.01));
      expect(reading.correctionStops, closeTo(0.0, 0.01));
      expect(reading.quality, LiveReadingQuality.good);
    });

    test('a brighter patch reads brighter than the exposure', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 8.0),
        sample: patchAt(LiveMeter.target + 0.1),
      )!;

      expect(reading.sceneEv100, greaterThan(8.0));
      expect(reading.correctionStops, greaterThan(0));
    });

    test('a darker patch reads darker', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 8.0),
        sample: patchAt(LiveMeter.target - 0.1),
      )!;

      expect(reading.sceneEv100, lessThan(8.0));
      expect(reading.correctionStops, lessThan(0));
    });

    test('needs no measurement cycle — one frame is a reading', () {
      // The whole point of the rewrite: no stepping, no waiting.
      final meter = LiveMeter();
      expect(
        meter.read(
          metadata: frameAt(ev100: 12.0),
          sample: patchAt(LiveMeter.target),
        ),
        isNotNull,
      );
    });

    test('refuses a frame with no exposure', () {
      final meter = LiveMeter();
      expect(
        meter.read(
          metadata: CaptureMetadata(receivedAt: DateTime.now()),
          sample: patchAt(0.5),
        ),
        isNull,
      );
    });
  });

  group('quality', () {
    test('near target is good', () {
      final meter = LiveMeter();
      for (final offset in [-0.1, 0.0, 0.1]) {
        final reading = meter.read(
          metadata: frameAt(ev100: 8),
          sample: patchAt(LiveMeter.target + offset),
        )!;
        expect(reading.quality, LiveReadingQuality.good, reason: '$offset');
      }
    });

    test('well off target is fair, not silently good', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 8),
        sample: patchAt(LiveMeter.target + 0.25),
      )!;
      expect(reading.quality, LiveReadingQuality.fair);
    });

    test('crushed or clipped is unusable and carries no value', () {
      final meter = LiveMeter();
      for (final encoded in [0.02, 0.08, 0.18, 0.90, 0.95]) {
        final reading = meter.read(
          metadata: frameAt(ev100: 8),
          sample: patchAt(encoded),
        )!;
        expect(reading.quality, LiveReadingQuality.unusable, reason: '$encoded');
        // A number here would be wrong by stops, so none is offered.
        expect(reading.sceneEv100.isNaN, isTrue);
      }
    });

    test('the error bound shrinks as the patch nears target', () {
      final meter = LiveMeter();
      final near = meter.read(
        metadata: frameAt(ev100: 8),
        sample: patchAt(LiveMeter.target + 0.02),
      )!;
      final far = meter.read(
        metadata: frameAt(ev100: 8),
        sample: patchAt(LiveMeter.target + 0.14),
      )!;
      expect(near.estimatedErrorStops, lessThan(far.estimatedErrorStops));
    });
  });

  group('learning the slope', () {
    test('starts from the sRGB prior', () {
      final meter = LiveMeter();
      expect(meter.slopeIsMeasured, isFalse);
      expect(meter.slope, closeTo(6.6, 0.5));
    });

    test('learns from exposure moving against patch brightness', () {
      final meter = LiveMeter();
      // A pipeline where one stop of exposure moves the patch 0.10 encoded
      // units, i.e. a slope of 10 — well away from the sRGB prior.
      // Learning only happens while AE is hunting; settled frames from
      // different scenes must not be paired.
      for (var i = 0; i < 8; i++) {
        final ev = 8.0 - i * 0.5;
        final encoded = 0.30 + i * 0.05;
        meter.read(
          metadata: frameAt(ev100: ev, aeConverged: false),
          sample: patchAt(encoded),
        );
      }
      expect(meter.slopeIsMeasured, isTrue);
      // Should have moved towards 10 and away from 6.6.
      expect(meter.slope, greaterThan(7.0));
    });

    test('a still scene teaches nothing and leaves the prior alone', () {
      final meter = LiveMeter();
      final prior = meter.slope;
      for (var i = 0; i < 10; i++) {
        meter.read(
          metadata: frameAt(ev100: 8.0),
          sample: patchAt(0.46),
        );
      }
      // No exposure change means no pair to learn from.
      expect(meter.slope, closeTo(prior, 1e-9));
    });

    test('reset forgets what was learned', () {
      final meter = LiveMeter();
      for (var i = 0; i < 8; i++) {
        meter.read(
          metadata: frameAt(ev100: 8.0 - i * 0.5, aeConverged: false),
          sample: patchAt(0.30 + i * 0.05),
        );
      }
      expect(meter.slopeIsMeasured, isTrue);
      meter.reset();
      expect(meter.slopeIsMeasured, isFalse);
    });

    test('settled frames from different scenes do not move the slope', () {
      final meter = LiveMeter();
      final prior = meter.slope;
      meter.read(
        metadata: frameAt(ev100: 8.0),
        sample: patchAt(0.40),
      );
      meter.read(
        metadata: frameAt(ev100: 12.0),
        sample: patchAt(0.55),
      );
      expect(meter.slope, closeTo(prior, 1e-9));
    });
  });

  group('smoothing', () {
    test('the first value is taken as-is', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 8),
        sample: patchAt(LiveMeter.target),
      )!;
      expect(LiveMeter.smooth(null, 8.0, reading), 8.0);
    });

    test('eases towards a nearby value rather than jumping', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 8),
        sample: patchAt(LiveMeter.target),
      )!;
      final smoothed = LiveMeter.smooth(8.0, 8.4, reading);
      expect(smoothed, greaterThan(8.0));
      expect(smoothed, lessThan(8.4));
    });

    test('snaps when the scene genuinely changes', () {
      // Easing across a large jump would crawl for seconds; re-aiming from a
      // dim interior to a bright window has to track immediately.
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 8),
        sample: patchAt(LiveMeter.target),
      )!;
      expect(LiveMeter.smooth(5.0, 12.0, reading), 12.0);
    });

    test('tracks faster while auto-exposure is still moving', () {
      final meter = LiveMeter();
      final settling = meter.read(
        metadata: frameAt(ev100: 8, aeConverged: false),
        sample: patchAt(LiveMeter.target),
      )!;
      final settled = meter.read(
        metadata: frameAt(ev100: 8, aeConverged: true),
        sample: patchAt(LiveMeter.target),
      )!;
      expect(
        LiveMeter.smoothingFor(settling),
        greaterThan(LiveMeter.smoothingFor(settled)),
      );
    });
  });

  group('fallback without capture metadata', () {
    test('reads from a still capture the same way', () {
      final meter = LiveMeter();
      final reading = meter.readFromParams(
        params: const ExposureParams(
          aperture: 1.88,
          shutterSeconds: 1 / 50,
          iso: 72,
        ),
        sample: patchAt(LiveMeter.target),
      );

      expect(reading, isNotNull);
      expect(reading!.quality, LiveReadingQuality.good);
      expect(reading.correctionStops, closeTo(0.0, 0.01));
    });

    test('still refuses an unusable patch', () {
      final meter = LiveMeter();
      final reading = meter.readFromParams(
        params: const ExposureParams(
          aperture: 1.88,
          shutterSeconds: 1 / 50,
          iso: 72,
        ),
        sample: patchAt(0.97),
      )!;
      expect(reading.quality, LiveReadingQuality.unusable);
    });
  });

  group('accuracy on a real device sweep', () {
    // vivo V2505A, 2026-09-03. Fixed scene, true EV₁₀₀ = 6.312. Same rungs
    // as test/spot_servo_test.dart. Open-loop sRGB inversion spread 2.3 EV
    // across this sweep; the live meter has to stay inside a third of a stop
    // on the rungs AE can actually hold near mid grey.
    const trueEv = 6.312;
    const rungs = <List<double>>[
      [-4.000, 0.04738, 9.807],
      [-2.667, 0.12716, 8.465],
      [-1.333, 0.31929, 7.055],
      [0.000, 0.56773, 5.756],
      [1.333, 0.70411, 4.906],
      [2.667, 0.79853, 3.455],
      [4.000, 0.83983, 2.192],
    ];

    test('usable rungs stay within ⅓ stop of the true scene EV', () {
      final meter = LiveMeter();
      final errors = <String, double>{};
      for (final row in rungs) {
        final encoded = row[1];
        final cameraEv = row[2];
        final reading = meter.read(
          metadata: frameAt(ev100: cameraEv, aeConverged: false),
          sample: patchAt(encoded),
        );
        if (reading == null ||
            reading.quality == LiveReadingQuality.unusable) {
          continue;
        }
        errors['${row[0]}'] = reading.sceneEv100 - trueEv;
      }
      expect(errors, isNotEmpty);
      for (final entry in errors.entries) {
        expect(
          entry.value.abs(),
          lessThan(0.40),
          reason: 'offset ${entry.key} EV error ${entry.value}',
        );
      }
    });

    test('crushed shadows that would be >1 stop out are refused', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 8.465, aeConverged: false),
        sample: patchAt(0.12716),
      )!;
      expect(reading.quality, LiveReadingQuality.unusable);
    });

    test('the mid-grey rung is inside 0.15 EV', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: 5.756),
        sample: patchAt(0.56773),
      )!;
      expect(reading.quality, isNot(LiveReadingQuality.unusable));
      expect(reading.sceneEv100, closeTo(trueEv, 0.15));
    });

    test('a patch on target is accurate almost regardless of slope', () {
      final meter = LiveMeter();
      final reading = meter.read(
        metadata: frameAt(ev100: trueEv),
        sample: patchAt(LiveMeter.target),
      )!;
      expect(reading.sceneEv100, closeTo(trueEv, 0.03));
      expect(reading.estimatedErrorStops, lessThan(0.1));
    });
  });
}
