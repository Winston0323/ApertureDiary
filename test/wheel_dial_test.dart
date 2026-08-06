import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/wheel_dial.dart';

Future<void> pumpDial(WidgetTester tester, {int initialIndex = 3}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: WheelDialSheet<int>(
          title: 'Film ISO',
          items: const [25, 50, 100, 200, 400, 800],
          initialIndex: initialIndex,
          labelOf: (v) => '$v',
          accent: const Color(0xFFFFB300),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the initial choice large in the readout', (tester) async {
    await pumpDial(tester, initialIndex: 3);
    // Header readout for 200.
    expect(find.text('200'), findsWidgets);
    final readout = tester.widget<Text>(
      find.descendant(
        of: find.byType(WheelDialSheet<int>),
        matching: find.text('200'),
      ).first,
    );
    expect(readout.style?.fontSize, 36);
    expect(readout.style?.color, const Color(0xFFFFB300));
  });

  testWidgets('updates the readout when the wheel scrolls', (tester) async {
    await pumpDial(tester, initialIndex: 3);
    await tester.drag(find.byType(ListWheelScrollView), const Offset(0, -120));
    await tester.pumpAndSettle();

    // Scrolling up moves toward higher indices (400, 800).
    expect(find.text('400'), findsWidgets);
  });

  testWidgets('Done returns the centred value', (tester) async {
    int? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<int>(
                  context: context,
                  builder: (_) => WheelDialSheet<int>(
                    title: 'Film ISO',
                    items: const [100, 200, 400],
                    initialIndex: 1,
                    labelOf: (v) => '$v',
                    accent: const Color(0xFFFFB300),
                  ),
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
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(result, 200);
  });
}
