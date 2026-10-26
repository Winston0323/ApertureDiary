import 'package:aperture_diary/exposure.dart';
import 'package:aperture_diary/reference_exposure.dart';
import 'package:aperture_diary/reference_exposure_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseShutter', () {
    test('fractions', () {
      expect(ReferenceExposure.parseShutter('1/125'), closeTo(1 / 125, 1e-12));
      expect(ReferenceExposure.parseShutter('1/8000'), closeTo(1 / 8000, 1e-12));
      expect(ReferenceExposure.parseShutter(' 1/60 s '), closeTo(1 / 60, 1e-12));
    });

    test('seconds, with the quote marks cameras print', () {
      expect(ReferenceExposure.parseShutter('0.5'), closeTo(0.5, 1e-12));
      expect(ReferenceExposure.parseShutter('2'), 2);
      expect(ReferenceExposure.parseShutter('2"'), 2);
      expect(ReferenceExposure.parseShutter('30"'), 30);
      expect(ReferenceExposure.parseShutter('0,5'), closeTo(0.5, 1e-12));
    });

    test('a bare 125 is refused, not guessed', () {
      expect(ReferenceExposure.parseShutter('125'), isNull);
      expect(ReferenceExposure.parseShutter('250'), isNull);
    });

    test('nonsense is refused', () {
      expect(ReferenceExposure.parseShutter(''), isNull);
      expect(ReferenceExposure.parseShutter('abc'), isNull);
      expect(ReferenceExposure.parseShutter('1/0'), isNull);
      expect(ReferenceExposure.parseShutter('1/2/3'), isNull);
      expect(ReferenceExposure.parseShutter('0'), isNull);
    });
  });

  group('parseAperture', () {
    test('accepts the ways people type it', () {
      expect(ReferenceExposure.parseAperture('5.6'), 5.6);
      expect(ReferenceExposure.parseAperture('f5.6'), 5.6);
      expect(ReferenceExposure.parseAperture('f/5.6'), 5.6);
      expect(ReferenceExposure.parseAperture('F/5,6'), 5.6);
      expect(ReferenceExposure.parseAperture('8'), 8);
    });

    test('rejects out-of-range values', () {
      expect(ReferenceExposure.parseAperture('0'), isNull);
      expect(ReferenceExposure.parseAperture('500'), isNull);
      expect(ReferenceExposure.parseAperture('x'), isNull);
    });
  });

  group('parseIso', () {
    test('accepts a plain number or an ISO prefix', () {
      expect(ReferenceExposure.parseIso('400'), 400);
      expect(ReferenceExposure.parseIso('ISO 100'), 100);
    });

    test('rejects nonsense', () {
      expect(ReferenceExposure.parseIso('0'), isNull);
      expect(ReferenceExposure.parseIso('-100'), isNull);
      expect(ReferenceExposure.parseIso(''), isNull);
    });
  });

  group('ev100', () {
    test('sunny 16', () {
      const ref = ReferenceExposure(
        aperture: 16,
        shutterSeconds: 1 / 128,
        iso: 100,
      );
      expect(ref.ev100, closeTo(15, 1e-9));
    });

    test('a faster ISO at the same exposure is a darker scene', () {
      const slow = ReferenceExposure(
        aperture: 5.6,
        shutterSeconds: 1 / 125,
        iso: 100,
      );
      const fast = ReferenceExposure(
        aperture: 5.6,
        shutterSeconds: 1 / 125,
        iso: 400,
      );
      expect(slow.ev100 - fast.ev100, closeTo(2, 1e-9));
    });

    test('agrees with the shutter the meter would then pick', () {
      // The camera says f/5.6, 1/60 at ISO 400; solving that scene back for
      // f/5.6 at ISO 400 must give 1/60.
      const ref = ReferenceExposure(
        aperture: 5.6,
        shutterSeconds: 1 / 60,
        iso: 400,
      );
      final t = ExposureMath.shutterFromEv(
        ev100: ref.ev100,
        aperture: 5.6,
        iso: 400,
      );
      expect(t, closeTo(1 / 60, 1e-9));
    });

    test('validity bounds', () {
      expect(
        const ReferenceExposure(aperture: 5.6, shutterSeconds: 1 / 125, iso: 100)
            .isValid,
        isTrue,
      );
      expect(
        const ReferenceExposure(aperture: 0, shutterSeconds: 1 / 125, iso: 100)
            .isValid,
        isFalse,
      );
      expect(
        const ReferenceExposure(aperture: 5.6, shutterSeconds: 0, iso: 100)
            .isValid,
        isFalse,
      );
    });
  });

  group('the one-stop case', () {
    test('a meter reading a stop bright is corrected by a −1 offset', () {
      // f/8 at 1/128 s, ISO 100 is exactly EV 13. The phone says 14.
      const camera = ReferenceExposure(
        aperture: 8,
        shutterSeconds: 1 / 128,
        iso: 100,
      );
      expect(camera.ev100, closeTo(13, 1e-9));
      const phoneReading = 14.0; // one stop bright
      final offset = camera.ev100 - phoneReading;
      expect(offset, closeTo(-1, 1e-9));

      // Uncorrected, the phone picks a shutter a stop too fast.
      final before = ExposureMath.shutterFromEv(
        ev100: phoneReading,
        aperture: 8,
        iso: 100,
      );
      expect(before, closeTo(1 / 256, 1e-9));

      // Corrected, it matches the camera.
      final after = ExposureMath.shutterFromEv(
        ev100: phoneReading + offset,
        aperture: 8,
        iso: 100,
      );
      expect(after, closeTo(1 / 128, 1e-9));
    });
  });

  group('dialog', () {
    Future<ReferenceExposure?> run(
      WidgetTester tester, {
      required String aperture,
      required String shutter,
      String? iso,
    }) async {
      ReferenceExposure? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showDialog<ReferenceExposure>(
                      context: ctx,
                      builder: (_) =>
                          const ReferenceExposureDialog(initialIso: 400),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), aperture);
      await tester.enterText(fields.at(1), shutter);
      if (iso != null) await tester.enterText(fields.at(2), iso);
      await tester.pump();
      return result;
    }

    testWidgets('prefills ISO and shows the EV it will use', (tester) async {
      await run(tester, aperture: '8', shutter: '1/125');
      // f/8, 1/125, ISO 400 → log2(64·125) − 2 = 10.97
      expect(find.textContaining('EV₁₀₀ 11.0'), findsOneWidget);
    });

    testWidgets('Calibrate is disabled until all three parse', (tester) async {
      await run(tester, aperture: '8', shutter: '125');
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Calibrate'),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('not a bare 125'), findsOneWidget);
    });

    testWidgets('returns the entered exposure', (tester) async {
      ReferenceExposure? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  result = await showDialog<ReferenceExposure>(
                    context: ctx,
                    builder: (_) =>
                        const ReferenceExposureDialog(initialIso: 400),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'f/5.6');
      await tester.enterText(fields.at(1), '1/60');
      await tester.enterText(fields.at(2), '200');
      await tester.pump();
      await tester.tap(find.text('Calibrate'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.aperture, 5.6);
      expect(result!.shutterSeconds, closeTo(1 / 60, 1e-12));
      expect(result!.iso, 200);
    });
  });
}
