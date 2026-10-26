import 'dart:async';

import 'package:flutter/material.dart';

import 'checklist_icons.dart';
import 'frame_counter.dart';
import 'number_input_dialog.dart';
import 'shoot_checklist.dart';

const Color _accent = Color(0xFFFFB300);
const Color _done = Color(0xFF8A8A8A);
const Color _pendingFill = Color(0xFF2A2416);
const double _wheelExtent = 64;

/// The shooting checklist: tick steps, drag them into a new order, add one.
class ShootChecklistPage extends StatefulWidget {
  const ShootChecklistPage({
    super.key,
    this.initial,
    this.persist = true,
    this.filmId,
  });

  /// Skips the disk read. Tests pass a list here.
  final ShootChecklist? initial;

  /// When false, edits stay in memory. The app always persists.
  final bool persist;

  /// Roll whose frame number this page counts. Empty in tests.
  final String? filmId;

  @override
  State<ShootChecklistPage> createState() => _ShootChecklistPageState();
}

class _ShootChecklistPageState extends State<ShootChecklistPage> {
  ShootChecklist? _list;
  int _idClock = 0;
  bool _editing = false;

  /// Wheel position. Steps before this index are done. One past the last step
  /// means the frame is finished.
  int _index = 0;
  FixedExtentScrollController? _wheel;

  /// The frame of this roll you are shooting now.
  int _frame = FrameCount.min;

  @override
  void initState() {
    super.initState();
    final given = widget.initial;
    if (given != null) {
      _list = given;
      _attachWheel(given);
    } else {
      _load();
    }
    _loadFrame();
  }

  Future<void> _loadFrame() async {
    final filmId = widget.filmId;
    if (filmId == null || filmId.isEmpty) return;
    final frame = await FrameCounterStore.load(filmId);
    if (!mounted) return;
    setState(() => _frame = frame);
  }

  Future<void> _setFrame(int frame) async {
    final next = FrameCount.clamp(frame);
    setState(() => _frame = next);
    final filmId = widget.filmId;
    if (widget.persist && filmId != null && filmId.isNotEmpty) {
      await FrameCounterStore.save(filmId, next);
    }
  }

  Future<void> _editFrame() async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) => NumberInputDialog(
        title: 'Frame',
        helper: 'The frame you are on',
        initialText: '$_frame',
      ),
    );
    if (value == null) return;
    await _setFrame(value.round());
  }

  @override
  void dispose() {
    _wheel?.dispose();
    super.dispose();
  }

  void _attachWheel(ShootChecklist list) {
    if (_wheel != null) return;
    final open = list.steps.indexWhere((s) => !list.isChecked(s.id));
    _index = list.steps.isEmpty
        ? 0
        : (open < 0 ? list.steps.length : open);
    _wheel = FixedExtentScrollController(initialItem: _index);
  }

  /// Swipe up onto [index]. Every step before it is done; swiping back undoes
  /// that. [index] may be one past the last step, which finishes the frame.
  void _settleWheel(int index) {
    final list = _list;
    if (list == null) return;
    final marked = list.markedThrough(index);
    setState(() {
      _index = index;
      _list = marked;
    });
    if (widget.persist) unawaited(ShootChecklistStore.save(marked));
  }

  Future<void> _load() async {
    final list = await ShootChecklistStore.load();
    if (!mounted) return;
    setState(() {
      _list = list;
      _attachWheel(list);
    });
  }

  void _apply(ShootChecklist next) {
    setState(() {
      _list = next;
      if (next.steps.isEmpty) {
        _index = 0;
      } else if (_index >= next.steps.length) {
        _index = next.steps.length - 1;
      }
      if (next.doneCount == 0) _index = 0;
    });
    if (next.doneCount == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final wheel = _wheel;
        if (mounted && wheel != null && wheel.hasClients) {
          wheel.jumpToItem(0);
        }
      });
    }
    if (widget.persist) unawaited(ShootChecklistStore.save(next));
  }

  void _toggleEdit() {
    final turningOff = _editing;
    setState(() => _editing = !_editing);
    if (!turningOff) return;
    final list = _list;
    if (list == null) return;
    final open = list.steps.indexWhere((s) => !list.isChecked(s.id));
    final index = list.steps.isEmpty
        ? 0
        : (open < 0 ? list.steps.length : open);
    setState(() => _index = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final wheel = _wheel;
      if (mounted && wheel != null && wheel.hasClients) {
        wheel.jumpToItem(index);
      }
    });
  }

  String _newId() {
    _idClock += 1;
    return 'step-${DateTime.now().microsecondsSinceEpoch}-$_idClock';
  }

  Future<void> _add() async {
    final drafted = await _askForStep(title: 'Add a step');
    if (drafted == null) return;
    final list = _list;
    if (list == null) return;
    final next = list.add(drafted.text, id: _newId(), iconId: drafted.iconId);
    if (next == null) {
      _tell(list.steps.length >= ShootChecklist.maxSteps
          ? 'The list is full'
          : 'Enter a step');
      return;
    }
    _apply(next);
  }

  Future<void> _rename(ChecklistStep step) async {
    final drafted = await _askForStep(
      title: 'Edit step',
      initialText: step.text,
      initialIconId: step.iconId,
    );
    if (drafted == null) return;
    final renamed = _list?.rename(step.id, drafted.text);
    final next = renamed?.setIcon(step.id, drafted.iconId);
    if (next == null) {
      _tell('Enter a step');
      return;
    }
    _apply(next);
  }

  Future<void> _pickIcon(ChecklistStep step) async {
    final iconId = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Icon'),
        content: SizedBox(
          width: 320,
          child: ChecklistIconPicker(
            selectedId: step.iconId,
            onSelected: (id) => Navigator.pop(ctx, id),
          ),
        ),
      ),
    );
    if (iconId == null) return;
    final next = _list?.setIcon(step.id, iconId);
    if (next != null) _apply(next);
  }

  Future<({String text, String iconId})?> _askForStep({
    required String title,
    String? initialText,
    String initialIconId = checklistIconNote,
  }) {
    return showDialog<({String text, String iconId})>(
      context: context,
      builder: (ctx) => _StepDialog(
        title: title,
        initialText: initialText ?? '',
        initialIconId: initialIconId,
        confirmLabel: initialText == null ? 'Add' : 'Save',
      ),
    );
  }

  void _tell(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Checklist',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            if (list != null)
              Text(
                list.isEmpty
                    ? 'No steps yet'
                    : list.isComplete
                        ? 'Frame done'
                        : '${list.doneCount} of ${list.steps.length}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('checklist-edit'),
            onPressed: list == null ? null : _toggleEdit,
            child: Text(
              _editing ? 'Done' : 'Edit',
              style: TextStyle(
                color: list == null ? Colors.white24 : _accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Clear checks',
            onPressed: list == null || list.doneCount == 0
                ? null
                : () => _apply(list.cleared()),
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      floatingActionButton: _editing
          ? FloatingActionButton.extended(
              onPressed: list == null ? null : _add,
              backgroundColor: _accent,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.add),
              label: const Text('Add step'),
            )
          : null,
      body: list == null
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : list.isEmpty
              ? const Center(
                  child: Text(
                    'Add the first step.',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : _editing
              ? Column(
                  children: [
                    _frameReadout(),
                    Expanded(child: _editList(list)),
                    if (list.isComplete) _nextFrameButton(list),
                  ],
                )
              : _swipeDeck(list),
    );
  }

  /// The same kind of wheel as the shutter and aperture dials. The row in the
  /// window is the step you are on. Swiping up moves to the next row and marks
  /// the one you left as done. Swiping down brings a step back.
  Widget _swipeDeck(ShootChecklist list) {
    final wheel = _wheel;
    if (wheel == null) return const SizedBox.shrink();
    return Column(
      children: [
        _frameReadout(),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              IgnorePointer(
                child: Container(
                  height: _wheelExtent,
                  margin: const EdgeInsets.symmetric(horizontal: 18),
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _accent.withValues(alpha: 0.7),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              ListWheelScrollView(
                controller: wheel,
                itemExtent: _wheelExtent,
                physics: const FixedExtentScrollPhysics(),
                perspective: 0.002,
                diameterRatio: 2.2,
                overAndUnderCenterOpacity: 0.45,
                onSelectedItemChanged: _settleWheel,
                children: [
                  for (var i = 0; i < list.steps.length; i++)
                    _WheelStep(
                      key: ValueKey(list.steps[i].id),
                      step: list.steps[i],
                      passed: i < _index,
                      selected: i == _index,
                    ),
                  _WheelStep(
                    key: const ValueKey('frame-done'),
                    label: 'Frame done',
                    icon: Icons.check,
                    passed: false,
                    selected: _index >= list.steps.length,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (list.isComplete) _nextFrameButton(list),
      ],
    );
  }

  Widget _frameReadout() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: InkWell(
        key: const ValueKey('frame-counter'),
        onTap: _editFrame,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Frame',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$_frame',
                style: const TextStyle(
                  color: _accent,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nextFrameButton(ShootChecklist list) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              unawaited(_setFrame(FrameCount.advance(_frame)));
              _apply(list.cleared());
            },
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text(
              'Next frame',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    );
  }

  Widget _editList(ShootChecklist list) {
    return ReorderableListView.builder(
                        padding: const EdgeInsets.only(bottom: 88),
                        buildDefaultDragHandles: false,
                        itemCount: list.steps.length,
                        onReorderItem: (from, to) => _apply(list.move(from, to)),
                        itemBuilder: (context, index) {
                          final step = list.steps[index];
                          final checked = list.isChecked(step.id);
                          final current = index == _index && !checked;
                          final picture = checklistIconChoice(step.iconId);
                          final ink = checked
                              ? _done
                              : (current ? Colors.white : Colors.white70);
                          return Padding(
                            key: ValueKey(step.id),
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                            child: Material(
                              color: checked
                                  ? const Color(0xFF121212)
                                  : current
                                      ? _pendingFill
                                      : const Color(0xFF141414),
                              borderRadius: BorderRadius.circular(12),
                              child: ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(
                                    color: checked
                                        ? Colors.white10
                                        : current
                                            ? _accent.withValues(alpha: 0.7)
                                            : Colors.white12,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    InkWell(
                                      key: ValueKey('icon-${step.id}'),
                                      onTap: _editing ? () => _pickIcon(step) : null,
                                      borderRadius: BorderRadius.circular(8),
                                      child: Icon(
                                        picture.icon,
                                        size: 22,
                                        color: checked
                                            ? _done
                                            : current
                                                ? _accent
                                                : Colors.white54,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: GestureDetector(
                                        key: ValueKey('edit-${step.id}'),
                                        onTap: _editing ? () => _rename(step) : null,
                                        child: Text(
                                          step.text,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: ink,
                                            fontWeight: checked
                                                ? FontWeight.w500
                                                : FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: _editing
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            key: ValueKey('delete-${step.id}'),
                                            tooltip: 'Remove',
                                            onPressed: () =>
                                                _apply(list.remove(step.id)),
                                            icon: const Icon(
                                              Icons.close,
                                              size: 18,
                                              color: Colors.white54,
                                            ),
                                          ),
                                          ReorderableDragStartListener(
                                            index: index,
                                            child: const Icon(
                                              Icons.drag_handle,
                                              key: ValueKey('move-handle'),
                                              color: Colors.white54,
                                            ),
                                          ),
                                        ],
                                      )
                                    : null,
                              ),
                            ),
                          );
                        },
    );
  }
}

class _WheelStep extends StatelessWidget {
  const _WheelStep({
    super.key,
    this.step,
    this.label,
    this.icon,
    required this.passed,
    required this.selected,
  });

  final ChecklistStep? step;
  final String? label;
  final IconData? icon;
  final bool passed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final picture = step == null
        ? (icon ?? Icons.check)
        : checklistIconChoice(step!.iconId).icon;
    final text = step?.text ?? label ?? '';
    final color = passed ? _done : (selected ? _accent : Colors.white38);
    // Inset to match the highlight window, so a long name stops at the border
    // instead of painting past it. The wheel would otherwise scale the row.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Align(
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(picture, size: selected ? 22 : 18, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: selected ? 16 : 14,
                  height: 1.15,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepDialog extends StatefulWidget {
  const _StepDialog({
    required this.title,
    required this.initialText,
    required this.initialIconId,
    required this.confirmLabel,
  });

  final String title;
  final String initialText;
  final String initialIconId;
  final String confirmLabel;

  @override
  State<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends State<_StepDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initialText);
  late String _iconId = widget.initialIconId;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(
        context,
        (text: _text.text, iconId: _iconId),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF161616),
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _text,
                autofocus: true,
                maxLength: ShootChecklist.maxTextLength,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'What to check',
                  counterText: '',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              const Text(
                'Icon',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              ChecklistIconPicker(
                selectedId: _iconId,
                onSelected: (id) => setState(() => _iconId = id),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
