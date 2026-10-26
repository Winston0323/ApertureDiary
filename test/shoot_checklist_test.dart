import 'package:aperture_diary/frame_counter.dart';
import 'package:aperture_diary/checklist_icons.dart';
import 'package:aperture_diary/shoot_checklist.dart';
import 'package:aperture_diary/shoot_checklist_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FrameCount', () {
    test('starts at 1 and steps forward, staying inside 1 to 999', () {
      expect(FrameCount.clamp(0), 1);
      expect(FrameCount.clamp(1.6), 2);
      expect(FrameCount.clamp(double.nan), 1);
      expect(FrameCount.advance(1), 2);
      expect(FrameCount.advance(999), 999);
      expect(FrameCount.advance(0), 1);
    });
  });

  group('ShootChecklist', () {
    test('starts as the sheet-film routine, nothing ticked', () {
      final list = ShootChecklist.fresh();
      expect(
        list.steps.map((s) => s.text).toList(),
        [
          'Check shutter speed and aperture',
          'Cock the shutter',
          'Check the dark slide',
          'Take the shot',
          'Advance the film',
        ],
      );
      expect(list.doneCount, 0);
      expect(list.next?.id, ShootChecklist.checkExposure.id);
      expect(list.isComplete, isFalse);
    });

    test('ticking walks to the next unticked step', () {
      final once = ShootChecklist.fresh().toggle(ShootChecklist.checkExposure.id);
      expect(once.isChecked(ShootChecklist.checkExposure.id), isTrue);
      expect(once.next?.id, ShootChecklist.cockShutter.id);
      expect(once.doneCount, 1);

      final twice = once.toggle(ShootChecklist.checkExposure.id);
      expect(twice.isChecked(ShootChecklist.checkExposure.id), isFalse);
      expect(twice.next?.id, ShootChecklist.checkExposure.id);
    });

    test('a tick on an unknown step is ignored', () {
      final list = ShootChecklist.fresh();
      expect(identical(list.toggle('nope'), list), isTrue);
    });

    test('is complete only when every remaining step is ticked', () {
      var list = ShootChecklist.fresh();
      for (final step in list.steps) {
        list = list.toggle(step.id);
      }
      expect(list.isComplete, isTrue);
      expect(list.next, isNull);
      expect(list.cleared().doneCount, 0);
      expect(list.cleared().steps, list.steps);
      expect(list.markedThrough(2).doneCount, 2);
      expect(list.markedThrough(2).isChecked(ShootChecklist.checkExposure.id), isTrue);
      expect(list.markedThrough(2).isChecked(ShootChecklist.cockShutter.id), isTrue);
      expect(list.markedThrough(2).isChecked(ShootChecklist.darkSlide.id), isFalse);
      expect(list.markedThrough(0).doneCount, 0);
      expect(list.markedThrough(99).isComplete, isTrue);
    });

    test('move reorders and clamps', () {
      final list = ShootChecklist.fresh();
      final moved = list.move(0, 2);
      expect(moved.steps.first.id, ShootChecklist.cockShutter.id);
      expect(moved.steps[2].id, ShootChecklist.checkExposure.id);
      // A tick stays with the step.
      final checked = list.toggle(ShootChecklist.darkSlide.id).move(2, 0);
      expect(checked.steps.first.id, ShootChecklist.darkSlide.id);
      expect(checked.isChecked(ShootChecklist.darkSlide.id), isTrue);

      expect(list.move(0, 0).steps, list.steps);
      expect(list.move(-5, 99).steps.last.id, ShootChecklist.checkExposure.id);
    });

    test('add trims, and refuses a blank, a duplicate id, or a full list', () {
      final added = ShootChecklist.fresh().add('  Pull the dark slide  ', id: 'x');
      expect(added!.steps.last.text, 'Pull the dark slide');

      expect(ShootChecklist.fresh().add('   ', id: 'x'), isNull);
      expect(ShootChecklist.fresh().add('Ok', id: '  '), isNull);
      expect(
        ShootChecklist.fresh().add('Again', id: ShootChecklist.cockShutter.id),
        isNull,
      );
      expect(
        ShootChecklist.fresh().add('x' * (ShootChecklist.maxTextLength + 1), id: 'long'),
        isNull,
      );

      var full = const ShootChecklist(steps: []);
      for (var i = 0; i < ShootChecklist.maxSteps; i++) {
        full = full.add('Step $i', id: 's$i')!;
      }
      expect(full.add('One more', id: 'overflow'), isNull);
    });

    test('rename keeps the tick, remove drops the step and its tick', () {
      final list = ShootChecklist.fresh()
          .toggle(ShootChecklist.darkSlide.id)
          .rename(ShootChecklist.darkSlide.id, ' Dark slide out ')!;
      expect(list.steps[2].text, 'Dark slide out');
      expect(list.steps[2].iconId, 'dark-slide');
      expect(list.isChecked(ShootChecklist.darkSlide.id), isTrue);
      expect(list.setIcon(ShootChecklist.darkSlide.id, 'flash')!.steps[2].iconId, 'flash');
      expect(list.setIcon(ShootChecklist.darkSlide.id, 'no-such-icon'), isNull);
      expect(list.rename(ShootChecklist.darkSlide.id, '  '), isNull);
      expect(list.rename('missing', 'Hello'), isNull);

      final gone = list.remove(ShootChecklist.darkSlide.id);
      expect(gone.steps.map((s) => s.id), isNot(contains(ShootChecklist.darkSlide.id)));
      expect(gone.isChecked(ShootChecklist.darkSlide.id), isFalse);
    });

    test('json keeps order and ticks, and drops junk', () {
      final list = ShootChecklist.fresh()
          .move(4, 0)
          .toggle(ShootChecklist.advanceFilm.id)
          .add('Close the back', id: 'close')!;
      final restored = ShootChecklist.fromJson(list.toJson());
      expect(restored.steps.map((s) => s.id), list.steps.map((s) => s.id));
      expect(restored.isChecked(ShootChecklist.advanceFilm.id), isTrue);
      expect(restored.steps.first.iconId, 'advance');
      expect(restored.steps.last.iconId, checklistIconNote);

      expect(ShootChecklist.fromJson(null).steps, ShootChecklist.defaults);
      expect(ShootChecklist.fromJson({'steps': []}).steps, isEmpty);
      expect(
        ShootChecklist.fromJson({
          'steps': [
            {'id': '', 'text': ''},
          ],
        }).steps,
        ShootChecklist.defaults,
      );
      expect(
        ShootChecklist.fromJson({
          'steps': [
            {'id': 'a', 'text': 'One'},
            {'id': 'a', 'text': 'Duplicate'},
            {'id': '', 'text': 'No id'},
            {'text': 'No id field'},
            {'id': 'b', 'text': '  Two  '},
          ],
          'checked': ['a', 'missing', 3],
        }).steps.map((s) => s.text),
        ['One', 'Two'],
      );
      final partial = ShootChecklist.fromJson({
        'steps': [
          {'id': 'a', 'text': 'One'},
        ],
        'checked': ['a', 'gone'],
      });
      expect(partial.isChecked('a'), isTrue);
      expect(partial.isChecked('gone'), isFalse);

      final remembered = ShootChecklist.fromJson({
        'steps': [
          {'id': 'shutter-aperture', 'text': 'Check shutter speed and aperture'},
          {'id': 'custom', 'text': 'Wait', 'icon': 'timer'},
          {'id': 'custom-2', 'text': 'Odd', 'icon': 'not-a-real-icon'},
        ],
      });
      expect(remembered.steps[0].iconId, 'exposure');
      expect(remembered.steps[1].iconId, 'timer');
      expect(remembered.steps[2].iconId, checklistIconNote);
    });

    test('the icon library and the stored keys are the same set', () {
      expect(
        checklistIconLibrary.map((c) => c.id).toSet(),
        checklistIconIds,
      );
      expect(
        ShootChecklist.fresh().steps.map((s) => s.iconId),
        ['exposure', 'cock', 'dark-slide', 'shot', 'advance'],
      );
    });
  });

  testWidgets('ticking, adding and removing a step', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ShootChecklistPage(
          persist: false,
          initial: ShootChecklist(steps: ShootChecklist.defaults),
        ),
      ),
    );

    expect(find.text('0 of 5'), findsOneWidget);
    expect(find.text('Add step'), findsNothing);
    expect(find.byKey(const ValueKey('delete-dark-slide')), findsNothing);
    expect(find.byType(Checkbox), findsNothing);

    Text styleOf(String text) => tester.widget<Text>(find.text(text));

    expect(styleOf('Check shutter speed and aperture').style?.color, const Color(0xFFFFB300));

    await tester.drag(find.byType(ListWheelScrollView), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.text('1 of 5'), findsOneWidget);
    expect(styleOf('Check shutter speed and aperture').style?.color, const Color(0xFF8A8A8A));
    expect(styleOf('Cock the shutter').style?.color, const Color(0xFFFFB300));

    await tester.drag(find.byType(ListWheelScrollView), const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(find.text('0 of 5'), findsOneWidget);
    expect(styleOf('Check shutter speed and aperture').style?.color, const Color(0xFFFFB300));

    await tester.tap(find.byKey(const ValueKey('checklist-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Add step'), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-dark-slide')), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsWidgets);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Close the back');
    await tester.tap(find.byKey(const ValueKey('icon-choice-flash')));
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Close the back'), findsOneWidget);
    expect(find.byIcon(Icons.flash_on), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-dark-slide')));
    await tester.pump();
    expect(find.text('Check the dark slide'), findsNothing);
  });
}
