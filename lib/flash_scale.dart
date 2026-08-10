import 'package:flutter/material.dart';

import 'exposure.dart';
import 'flash.dart';
import 'units.dart';

/// Side-by-side flash range dials.
///
/// * **Power** axis — each manual power, with reach distance.
/// * **Distance** axis — integer metres/feet, with the power that covers it.
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

  static const double _labelWidth = 40;
  static const double _tickWidth = 12;
  static const double _rowHeight = 26;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final powers = FlashMath.standardPowers.reversed.toList();
    final distances = _integerDistances();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${ExposureMath.formatAperture(aperture)} · ISO $iso'
          '${subjectDistance == null ? '' : '  ·  subject ${formatLength(subjectDistance!, useFeet: useFeet)}'}',
          style: TextStyle(
            fontSize: 10,
            color: subjectDistance == null
                ? Colors.white38
                : accent.withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _axisColumn(
                title: 'Power',
                valueTitle: useFeet ? 'ft' : 'm',
                accent: accent,
                child: Column(
                  children: [
                    for (final power in powers)
                      _powerRow(power, accent),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _axisColumn(
                title: useFeet ? 'ft' : 'm',
                valueTitle: 'Power',
                accent: accent,
                child: Column(
                  children: [
                    for (final d in distances)
                      _distanceRow(d, accent),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _axisColumn({
    required String title,
    required String valueTitle,
    required Color accent,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: _labelWidth,
              child: Text(
                title,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ),
            const SizedBox(width: _tickWidth),
            Text(
              valueTitle,
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Stack(
          children: [
            Positioned(
              left: _labelWidth + _tickWidth / 2,
              top: 4,
              bottom: 4,
              width: 1,
              child: const ColoredBox(color: Colors.white12),
            ),
            child,
          ],
        ),
      ],
    );
  }

  Widget _powerRow(double power, Color accent) {
    final distance = FlashMath.distanceAtPower(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
      aperture: aperture,
      fraction: power,
    );
    final selected = highlightedPower != null &&
        (power - highlightedPower!).abs() < 1e-9;

    return _tickRow(
      accent: accent,
      selected: selected,
      axisLabel: FlashMath.formatPower(power),
      valueLabel: formatLength(distance, useFeet: useFeet),
    );
  }

  Widget _distanceRow(int distanceUnits, Color accent) {
    final metres = toMetres(distanceUnits.toDouble(), useFeet: useFeet);
    final exact = FlashMath.powerFraction(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
      aperture: aperture,
      distance: metres,
    );
    final selected = _isSelectedDistance(distanceUnits);
    final valueLabel = !exact.isFinite
        ? '—'
        : exact > 1
            ? 'over'
            : FlashMath.formatPower(FlashMath.snapPower(exact));

    return _tickRow(
      accent: accent,
      selected: selected,
      axisLabel: '$distanceUnits',
      valueLabel: valueLabel,
    );
  }

  Widget _tickRow({
    required Color accent,
    required bool selected,
    required String axisLabel,
    required String valueLabel,
  }) {
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
              axisLabel,
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
              valueLabel,
              style: TextStyle(
                fontSize: 12,
                color: selected ? accent : Colors.white70,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSelectedDistance(int distanceUnits) {
    final subject = subjectDistance;
    if (subject == null || !subject.isFinite) return false;
    final subjectUnits = convertLength(subject, useFeet: useFeet);
    return (subjectUnits.round() - distanceUnits).abs() == 0;
  }

  /// Distance ticks: 1, 2, 4, 5, then +5 — near → far, matching the power axis
  /// (weak/short at top → full/long at bottom).
  List<int> _integerDistances() {
    final full = FlashMath.distanceAtPower(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
      aperture: aperture,
      fraction: 1,
    );
    final maxU = full.isFinite && full > 0
        ? convertLength(full, useFeet: useFeet).ceil().clamp(1, 200)
        : 40;

    const head = [1, 2, 4, 5];
    final out = <int>[];
    for (final d in head) {
      if (d <= maxU) out.add(d);
    }
    for (var d = 10; d <= maxU; d += 5) {
      out.add(d);
    }
    // Always show at least the head that fits, or 1 alone.
    if (out.isEmpty) out.add(1);
    return out;
  }
}
