import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_meter/number_input_dialog.dart';

/// Opens the dialog the way the app does and reports what it returned.
Future<void> pumpHost(
  WidgetTester tester,
  void Function(double? result) onResult, {
  String initialText = '36',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final value = await showDialog<double>(
                context: context,
                builder: (_) => NumberInputDialog(
                  title: 'Guide number',
                  helper: 'As rated at ISO 100, in metres',
                  initialText: initialText,
                ),
              );
              onResult(value);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('entering a number and confirming returns it', (tester) async {
    double? result;
    var called = false;
    await pumpHost(tester, (v) {
      result = v;
      called = true;
    });

    await tester.enterText(find.byType(TextField), '12.5');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, 12.5);
  });

  testWidgets('typing does not tear down the field', (tester) async {
    // Reproduces the crash path: the controller used to be disposed by the
    // caller while the field was still mounted.
    await pumpHost(tester, (_) {});

    await tester.enterText(find.byType(TextField), '4');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '45');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('45'), findsOneWidget);

    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling returns nothing', (tester) async {
    double? result;
    var called = false;
    await pumpHost(tester, (v) {
      result = v;
      called = true;
    });

    await tester.enterText(find.byType(TextField), '99');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, isNull);
  });

  testWidgets('submitting from the keyboard confirms', (tester) async {
    double? result;
    await pumpHost(tester, (v) => result = v);

    await tester.enterText(find.byType(TextField), '7.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(result, 7.5);
  });

  testWidgets('empty or unparseable input returns nothing', (tester) async {
    double? result = 1;
    await pumpHost(tester, (v) => result = v);

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('shows the initial value and the helper text', (tester) async {
    await pumpHost(tester, (_) {}, initialText: '20');
    expect(find.text('20'), findsOneWidget);
    expect(find.text('As rated at ISO 100, in metres'), findsOneWidget);
  });

  group('parseNumber', () {
    test('accepts a comma as the decimal separator', () {
      expect(parseNumber('12,5'), 12.5);
      expect(parseNumber('12.5'), 12.5);
    });

    test('rejects empty and malformed text', () {
      expect(parseNumber(''), isNull);
      expect(parseNumber('   '), isNull);
      expect(parseNumber('abc'), isNull);
    });

    test('tolerates surrounding whitespace', () {
      expect(parseNumber(' 36 '), 36.0);
    });
  });
}
