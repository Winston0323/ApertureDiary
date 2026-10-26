import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// One line of the shooting checklist.
class ChecklistStep {
  const ChecklistStep({
    required this.id,
    required this.text,
    this.iconId = checklistIconNote,
  });

  final String id;
  final String text;

  /// Key into [checklistIcons]. Unknown keys draw the note icon.
  final String iconId;

  Map<String, String> toJson() => {'id': id, 'text': text, 'icon': iconId};

  static ChecklistStep? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (id is! String || text is! String) return null;
    final trimmedId = id.trim();
    final trimmed = text.trim();
    if (trimmedId.isEmpty || trimmed.isEmpty) return null;
    if (trimmed.length > ShootChecklist.maxTextLength) return null;
    final icon = raw['icon'];
    final iconId = icon is String && checklistIconIds.contains(icon)
        ? icon
        : checklistIconForStep(trimmedId);
    return ChecklistStep(id: trimmedId, text: trimmed, iconId: iconId);
  }
}

/// Icon keys. The pictures live in [checklistIconData], kept out of this file
/// so the list itself does not depend on Flutter.
const String checklistIconNote = 'note';

const Set<String> checklistIconIds = {
  'exposure',
  'shutter',
  'aperture',
  'cock',
  'dark-slide',
  'shot',
  'advance',
  'flash',
  'meter',
  'focus',
  'lens',
  'cap',
  'filter',
  'timer',
  'light',
  'tripod',
  'film',
  'note',
  'check',
  'lock',
  'bag',
  'place',
  'subject',
  'flag',
};

/// Icon for a built-in step. Anything else is a note.
String checklistIconForStep(String stepId) {
  switch (stepId) {
    case 'shutter-aperture':
      return 'exposure';
    case 'cock-shutter':
      return 'cock';
    case 'dark-slide':
      return 'dark-slide';
    case 'take-shot':
      return 'shot';
    case 'advance-film':
      return 'advance';
    default:
      return checklistIconNote;
  }
}

/// The order of things to do for one frame, plus which of them are ticked.
///
/// The meter does not drive this list. It is a reminder the photographer
/// works through, then clears for the next frame.
class ShootChecklist {
  const ShootChecklist({
    required this.steps,
    this.checkedIds = const {},
  });

  static const int maxTextLength = 80;
  static const int maxSteps = 40;

  static const ChecklistStep checkExposure = ChecklistStep(
    id: 'shutter-aperture',
    text: 'Check shutter speed and aperture',
    iconId: 'exposure',
  );
  static const ChecklistStep cockShutter = ChecklistStep(
    id: 'cock-shutter',
    text: 'Cock the shutter',
    iconId: 'cock',
  );
  static const ChecklistStep darkSlide = ChecklistStep(
    id: 'dark-slide',
    text: 'Check the dark slide',
    iconId: 'dark-slide',
  );
  static const ChecklistStep takeShot = ChecklistStep(
    id: 'take-shot',
    text: 'Take the shot',
    iconId: 'shot',
  );
  static const ChecklistStep advanceFilm = ChecklistStep(
    id: 'advance-film',
    text: 'Advance the film',
    iconId: 'advance',
  );

  /// The routine a sheet-film camera wants, until the user changes it.
  static const List<ChecklistStep> defaults = [
    checkExposure,
    cockShutter,
    darkSlide,
    takeShot,
    advanceFilm,
  ];

  factory ShootChecklist.fresh() =>
      const ShootChecklist(steps: defaults);

  final List<ChecklistStep> steps;

  /// Ids of steps currently ticked. Ids that are no longer in [steps] are
  /// ignored by [isChecked].
  final Set<String> checkedIds;

  bool isChecked(String id) => checkedIds.contains(id);

  int get doneCount => steps.where((s) => isChecked(s.id)).length;

  bool get isEmpty => steps.isEmpty;

  bool get isComplete => steps.isNotEmpty && doneCount == steps.length;

  /// The first unticked step, which is the one to do now.
  ChecklistStep? get next {
    for (final step in steps) {
      if (!isChecked(step.id)) return step;
    }
    return null;
  }

  ShootChecklist toggle(String id) {
    if (!steps.any((s) => s.id == id)) return this;
    final next = Set<String>.of(checkedIds);
    if (!next.remove(id)) next.add(id);
    return ShootChecklist(steps: steps, checkedIds: next);
  }

  /// Moves the step at [from] to [to]. Indexes are clamped.
  ShootChecklist move(int from, int to) {
    if (steps.isEmpty) return this;
    final start = from.clamp(0, steps.length - 1);
    final end = to.clamp(0, steps.length - 1);
    if (start == end) return this;
    final next = [...steps];
    next.insert(end, next.removeAt(start));
    return ShootChecklist(steps: next, checkedIds: checkedIds);
  }

  /// Adds [text] at the end. Blank text and a full list are refused.
  ///
  /// An unknown [iconId] is stored as the note icon.
  ShootChecklist? add(
    String text, {
    required String id,
    String iconId = checklistIconNote,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > maxTextLength) return null;
    if (steps.length >= maxSteps) return null;
    if (id.trim().isEmpty || steps.any((s) => s.id == id)) return null;
    return ShootChecklist(
      steps: [
        ...steps,
        ChecklistStep(
          id: id,
          text: trimmed,
          iconId: checklistIconIds.contains(iconId) ? iconId : checklistIconNote,
        ),
      ],
      checkedIds: checkedIds,
    );
  }

  /// Rewords a step. Blank text is refused; the id and icon stay.
  ShootChecklist? rename(String id, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > maxTextLength) return null;
    final index = steps.indexWhere((s) => s.id == id);
    if (index < 0) return null;
    final next = [...steps];
    next[index] = ChecklistStep(
      id: id,
      text: trimmed,
      iconId: steps[index].iconId,
    );
    return ShootChecklist(steps: next, checkedIds: checkedIds);
  }

  /// Swaps the picture on a step. An unknown icon is refused.
  ShootChecklist? setIcon(String id, String iconId) {
    if (!checklistIconIds.contains(iconId)) return null;
    final index = steps.indexWhere((s) => s.id == id);
    if (index < 0) return null;
    final next = [...steps];
    next[index] = ChecklistStep(
      id: id,
      text: steps[index].text,
      iconId: iconId,
    );
    return ShootChecklist(steps: next, checkedIds: checkedIds);
  }

  ShootChecklist remove(String id) {
    return ShootChecklist(
      steps: [for (final s in steps) if (s.id != id) s],
      checkedIds: {for (final c in checkedIds) if (c != id) c},
    );
  }

  /// Unticks everything, ready for the next frame. The order stays.
  ShootChecklist cleared() => ShootChecklist(steps: steps);

  /// The first [count] steps are done and the rest are not.
  ///
  /// The wheel uses this: swiping up onto a step marks every step before it.
  ShootChecklist markedThrough(int count) {
    final n = count.clamp(0, steps.length);
    return ShootChecklist(
      steps: steps,
      checkedIds: {for (var i = 0; i < n; i++) steps[i].id},
    );
  }

  Map<String, Object> toJson() => {
        'steps': [for (final s in steps) s.toJson()],
        'checked': checkedIds.toList(),
      };

  /// A stored list, or the default routine when the data is missing or empty.
  factory ShootChecklist.fromJson(Object? raw) {
    if (raw is! Map) return ShootChecklist.fresh();
    final rawSteps = raw['steps'];
    if (rawSteps is! List) return ShootChecklist.fresh();

    final steps = <ChecklistStep>[];
    final seen = <String>{};
    for (final item in rawSteps) {
      if (steps.length >= maxSteps) break;
      final step = ChecklistStep.fromJson(item);
      if (step == null || !seen.add(step.id)) continue;
      steps.add(step);
    }
    // An empty list is a choice the user made. Only a missing or unreadable
    // list falls back to the routine.
    if (steps.isEmpty) {
      if (rawSteps.isEmpty) return const ShootChecklist(steps: []);
      return ShootChecklist.fresh();
    }

    final checked = <String>{};
    final rawChecked = raw['checked'];
    if (rawChecked is List) {
      for (final id in rawChecked) {
        if (id is String && seen.contains(id)) checked.add(id);
      }
    }
    return ShootChecklist(steps: steps, checkedIds: checked);
  }
}

/// Remembers the checklist, including which steps are ticked, across launches.
class ShootChecklistStore {
  static const String _fileName = 'shoot_checklist.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<ShootChecklist> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return ShootChecklist.fresh();
      return ShootChecklist.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return ShootChecklist.fresh();
    }
  }

  static Future<void> save(ShootChecklist checklist) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(checklist.toJson()));
    } catch (_) {
      // A missed save only loses the latest edit.
    }
  }
}
