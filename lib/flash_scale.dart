import 'package:flutter/material.dart';

import 'exposure.dart';
import 'flash.dart';
import 'units.dart';

/// Vertical axis of every manual power setting and the distance it covers.
///
/// Each step down the dial is one stop, so the distances shrink by √2 — seeing
/// the whole range at once makes it obvious how much room there is to move
/// before the next setting is needed.
class FlashRangeScale extends StatelessWidget {
  const FlashRangeScale({
    super.key,
    required this.guideNumberIso100,
    required this.iso,
    required this.aperture,
    required this.useFeet,
    this.highlightedPower,
    this.subjectDistance,
  });

  final double guideNumberIso100;
  final int iso;
  final double aperture;
  final bool useFeet;

  /// The setting to mark as recommended, if any is in range.
  final double? highlightedPower;

  /// Where the subject actually is, shown for reference.
  final double? subjectDistance;

  static const double _labelWidth = 46;
  static const double _tickWidth = 16;
  static const double _rowHeight = 26;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final powers = FlashMath.standardPowers.reversed.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(accent),
        const SizedBox(height: 4),
        Stack(
          children: [
            // The axis itself, running behind the tick marks.
            Positioned(
              left: _labelWidth + _tickWidth / 2,
              top: 4,
              bottom: 4,
              width: 1,
              child: const ColoredBox(color: Colors.white12),
            ),
            Column(
              children: [
                for (final power in powers) _row(power, accent),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _header(Color accent) {
    return Row(
      children: [
        const SizedBox(
          width: _labelWidth,
          child: Text(
            'Power',
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ),
        const SizedBox(width: _tickWidth),
        Expanded(
          child: Text(
            'Covers at ${ExposureMath.formatAperture(aperture)} · ISO $iso',
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ),
        if (subjectDistance != null)
          Text(
            'subject ${formatLength(subjectDistance!, useFeet: useFeet)}',
            style: TextStyle(fontSize: 10, color: accent.withValues(alpha: 0.8)),
          ),
      ],
    );
  }

  Widget _row(double power, Color accent) {
    final distance = FlashMath.distanceAtPower(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
      aperture: aperture,
      fraction: power,
    );
    final selected = highlightedPower != null &&
        (power - highlightedPower!).abs() < 1e-9;

    return Container(
      height: _rowHeight,
      decoration: selected
          ? BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: Text(
              FlashMath.formatPower(power),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                color: selected ? accent : Colors.white54,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: _tickWidth,
            child: Center(
              child: selected
                  ? Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    )
                  : Container(width: 6, height: 1.5, color: Colors.white24),
            ),
          ),
          Expanded(
            child: Text(
              formatLength(distance, useFeet: useFeet),
              style: TextStyle(
                fontSize: 12,
                color: selected ? accent : Colors.white70,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          if (selected)
            Text(
              'set this',
              style: TextStyle(fontSize: 10, color: accent),
            ),
        ],
      ),
    );
  }
}
