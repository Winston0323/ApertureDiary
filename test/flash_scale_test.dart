import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/flash.dart';
import 'package:aperture_diary/flash_scale.dart';
import 'package:aperture_diary/units.dart';

Future<void> pumpScale(
  WidgetTester tester, {
  double guideNumber = 36,
  int iso = 100,
  double aperture = 8,
  bool useFeet = false,
  double? highlightedPower,
  double? subjectDistance,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(primary: Color(0xFFFFB300)),
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: FlashRangeScale(
            guideNumberIso100: guideNumber,
            iso: iso,
            aperture: aperture,
            useFeet: useFeet,
            highlightedPower: highlightedPower,
            subjectDistance: subjectDistance,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('lists every manual power setting', (tester) async {
    await pumpScale(tester);
    for (final power in FlashMath.standardPowers) {
      expect(
        find.text(FlashMath.formatPower(power)),
        findsOneWidget,
        reason: 'missing ${FlashMath.formatPower(power)}',
      );
    }
  });

  testWidgets('runs from the weakest setting down to full power',
      (tester) async {
    await pumpScale(tester);
    final weakest = tester.getCenter(find.text('1/128'));
    final full = tester.getCenter(find.text('1/1'));
    expect(weakest.dy, lessThan(full.dy));
  });

  testWidgets('shows the distance each setting covers', (tester) async {
    // GN 36 at f/8 reaches 4.5 m at full power, halving every two stops down.
    await pumpScale(tester);
    expect(find.text('4.5 m'), findsOneWidget); // 1/1
    expect(find.text('3.2 m'), findsOneWidget); // 1/2
    expect(find.text('2.3 m'), findsOneWidget); // 1/4
    expect(find.text('1.6 m'), findsOneWidget); // 1/8
  });

  testWidgets('converts to feet', (tester) async {
    await pumpScale(tester, useFeet: true);
    expect(
      find.text(formatLength(4.5, useFeet: true)),
      findsOneWidget,
    );
    expect(find.textContaining('m', findRichText: false), findsNothing);
  });

  testWidgets('marks the recommended setting', (tester) async {
    await pumpScale(tester, highlightedPower: 0.25);
    expect(find.text('set this'), findsOneWidget);

    final marker = tester.getCenter(find.text('set this'));
    final quarter = tester.getCenter(find.text('1/4'));
    expect(marker.dy, closeTo(quarter.dy, 1.0));
  });

  testWidgets('marks nothing when out of reach', (tester) async {
    await pumpScale(tester);
    expect(find.text('set this'), findsNothing);
  });

  testWidgets('header states the aperture, ISO, and subject distance',
      (tester) async {
    await pumpScale(tester, aperture: 2.8, iso: 400, subjectDistance: 3);
    expect(find.text('Covers at f/2.8 · ISO 400'), findsOneWidget);
    expect(find.text('subject 3 m'), findsOneWidget);
  });

  testWidgets('an unusable guide number leaves the distances blank',
      (tester) async {
    await pumpScale(tester, guideNumber: 0);
    expect(find.text('—'), findsNWidgets(FlashMath.standardPowers.length));
  });

  group('units', () {
    test('formats lengths in both systems', () {
      expect(formatLength(4.5, useFeet: false), '4.5 m');
      expect(formatLength(3, useFeet: false), '3 m');
      expect(formatLength(1, useFeet: true), '3.3 ft');
    });

    test('round trips through the display unit', () {
      final shown = convertLength(12, useFeet: true);
      expect(toMetres(shown, useFeet: true), closeTo(12, 1e-9));
    });

    test('rejects non-finite lengths', () {
      expect(formatLength(double.nan, useFeet: false), '—');
      expect(formatLength(0, useFeet: false), '—');
    });
  });
}
