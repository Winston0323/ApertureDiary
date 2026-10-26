import 'package:flutter/material.dart';

import 'shoot_checklist.dart';

/// One picture the user can put on a checklist step.
class ChecklistIconChoice {
  const ChecklistIconChoice(this.id, this.icon, this.label);

  final String id;
  final IconData icon;
  final String label;
}

/// Pictures for the built-in routine and for steps the user adds.
///
/// The ids match [checklistIconIds].
const List<ChecklistIconChoice> checklistIconLibrary = [
  ChecklistIconChoice('exposure', Icons.exposure, 'Exposure'),
  ChecklistIconChoice('shutter', Icons.shutter_speed, 'Shutter'),
  ChecklistIconChoice('aperture', Icons.camera, 'Aperture'),
  ChecklistIconChoice('cock', Icons.autorenew, 'Cock'),
  ChecklistIconChoice('dark-slide', Icons.credit_card, 'Dark slide'),
  ChecklistIconChoice('shot', Icons.photo_camera, 'Shot'),
  ChecklistIconChoice('advance', Icons.skip_next, 'Advance'),
  ChecklistIconChoice('flash', Icons.flash_on, 'Flash'),
  ChecklistIconChoice('meter', Icons.speed, 'Meter'),
  ChecklistIconChoice('focus', Icons.center_focus_strong, 'Focus'),
  ChecklistIconChoice('lens', Icons.lens, 'Lens'),
  ChecklistIconChoice('cap', Icons.circle_outlined, 'Lens cap'),
  ChecklistIconChoice('filter', Icons.filter_alt, 'Filter'),
  ChecklistIconChoice('timer', Icons.timer, 'Timer'),
  ChecklistIconChoice('light', Icons.wb_sunny, 'Light'),
  ChecklistIconChoice('tripod', Icons.vertical_align_bottom, 'Tripod'),
  ChecklistIconChoice('film', Icons.movie, 'Film'),
  ChecklistIconChoice('note', Icons.edit_note, 'Note'),
  ChecklistIconChoice('check', Icons.fact_check, 'Check'),
  ChecklistIconChoice('lock', Icons.lock_outline, 'Lock'),
  ChecklistIconChoice('bag', Icons.work_outline, 'Bag'),
  ChecklistIconChoice('place', Icons.place_outlined, 'Place'),
  ChecklistIconChoice('subject', Icons.person_outline, 'Subject'),
  ChecklistIconChoice('flag', Icons.flag_outlined, 'Flag'),
];

ChecklistIconChoice checklistIconChoice(String iconId) {
  for (final choice in checklistIconLibrary) {
    if (choice.id == iconId) return choice;
  }
  return checklistIconLibrary.firstWhere((c) => c.id == checklistIconNote);
}

/// A tappable grid of [checklistIconLibrary].
class ChecklistIconPicker extends StatelessWidget {
  const ChecklistIconPicker({
    super.key,
    required this.selectedId,
    required this.onSelected,
    this.accent = const Color(0xFFFFB300),
  });

  final String selectedId;
  final ValueChanged<String> onSelected;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final choice in checklistIconLibrary)
          _IconCell(
            choice: choice,
            selected: choice.id == selectedId,
            accent: accent,
            onTap: () => onSelected(choice.id),
          ),
      ],
    );
  }
}

class _IconCell extends StatelessWidget {
  const _IconCell({
    required this.choice,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final ChecklistIconChoice choice;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: choice.label,
      child: InkWell(
        key: ValueKey('icon-choice-${choice.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.2) : const Color(0xFF1C1C1C),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? accent : Colors.white12,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Icon(
            choice.icon,
            size: 22,
            color: selected ? accent : Colors.white70,
          ),
        ),
      ),
    );
  }
}
