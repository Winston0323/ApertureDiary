import 'package:flutter/material.dart';

/// Bottom-sheet scroll dial with a clearly marked current choice.
///
/// [ListWheelScrollView] keeps recycled children, so styles that depend on the
/// selected index must be rebuilt from a fresh child list on every change —
/// a builder alone is not enough.
class WheelDialSheet<T> extends StatefulWidget {
  const WheelDialSheet({
    super.key,
    required this.title,
    required this.items,
    required this.initialIndex,
    required this.labelOf,
    required this.accent,
  });

  final String title;
  final List<T> items;
  final int initialIndex;
  final String Function(T) labelOf;
  final Color accent;

  @override
  State<WheelDialSheet<T>> createState() => _WheelDialSheetState<T>();
}

class _WheelDialSheetState<T> extends State<WheelDialSheet<T>> {
  static const double _itemExtent = 56;

  late final FixedExtentScrollController _controller;
  late int _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialIndex.clamp(0, widget.items.length - 1);
    _controller = FixedExtentScrollController(initialItem: _selected);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    Navigator.of(context).pop(widget.items[_selected]);
  }

  @override
  Widget build(BuildContext context) {
    final currentLabel = widget.labelOf(widget.items[_selected]);

    return SafeArea(
      child: SizedBox(
        height: 380,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _confirm,
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
            // Big live readout of the centred value.
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                currentLabel,
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  color: widget.accent,
                  letterSpacing: -0.8,
                  height: 1.0,
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IgnorePointer(
                    child: Container(
                      height: _itemExtent,
                      margin: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        color: widget.accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: widget.accent.withValues(alpha: 0.7),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  ListWheelScrollView(
                    controller: _controller,
                    itemExtent: _itemExtent,
                    physics: const FixedExtentScrollPhysics(),
                    perspective: 0.002,
                    diameterRatio: 1.8,
                    useMagnifier: true,
                    magnification: 1.25,
                    overAndUnderCenterOpacity: 0.28,
                    onSelectedItemChanged: (i) {
                      setState(() => _selected = i);
                    },
                    // Fresh list each rebuild so the selected row's style
                    // actually updates (a builder alone reuses stale children).
                    children: [
                      for (var i = 0; i < widget.items.length; i++)
                        _DialRow(
                          key: ValueKey(i),
                          label: widget.labelOf(widget.items[i]),
                          selected: i == _selected,
                          accent: widget.accent,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialRow extends StatelessWidget {
  const _DialRow({
    super.key,
    required this.label,
    required this.selected,
    required this.accent,
  });

  final String label;
  final bool selected;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: TextStyle(
          fontSize: selected ? 28 : 18,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w400,
          color: selected ? accent : Colors.white38,
          letterSpacing: selected ? -0.5 : 0,
        ),
      ),
    );
  }
}
