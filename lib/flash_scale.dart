import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'exposure.dart';
import 'flash.dart';
import 'units.dart';

/// Horizontal flash range rulers.
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

  static const double _minTickWidth = 52;
  static const double _axisHeight = 64;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    // Weak/short on the left → full/long on the right.
    final powers = FlashMath.standardPowers.reversed.toList();
    final distances = _integerDistances();
    final unit = useFeet ? 'ft' : 'm';

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
        const SizedBox(height: 10),
        _axis(
          title: 'Power',
          valueTitle: unit,
          accent: accent,
          count: powers.length,
          ticks: [
            for (final power in powers) _powerTick(power, accent),
          ],
        ),
        if (distances.isNotEmpty) ...[
          const SizedBox(height: 14),
          _axis(
            title: unit,
            valueTitle: 'Power',
            accent: accent,
            count: distances.length,
            ticks: [
              for (final d in distances) _distanceTick(d, accent),
            ],
          ),
        ],
      ],
    );
  }

  Widget _axis({
    required String title,
    required String valueTitle,
    required Color accent,
    required int count,
    required List<Widget> ticks,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
            const Spacer(),
            Text(
              valueTitle,
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final minWidth = count * _minTickWidth;
            final width = math.max(minWidth, constraints.maxWidth);
            final itemWidth = width / count;
            final row = SizedBox(
              width: width,
              height: _axisHeight,
              child: Stack(
                children: [
                  Positioned(
                    left: itemWidth / 2,
                    right: itemWidth / 2,
                    top: 26,
                    height: 1,
                    child: const ColoredBox(color: Colors.white12),
                  ),
                  Row(
                    children: [
                      for (final tick in ticks)
                        SizedBox(width: itemWidth, child: tick),
                    ],
                  ),
                ],
              ),
            );
            if (width > constraints.maxWidth + 0.5) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: row,
              );
            }
            return row;
          },
        ),
      ],
    );
  }

  Widget _powerTick(double power, Color accent) {
    final distance = FlashMath.distanceAtPower(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
      aperture: aperture,
      fraction: power,
    );
    final selected = highlightedPower != null &&
        (power - highlightedPower!).abs() < 1e-9;

    return _tick(
      accent: accent,
      selected: selected,
      axisLabel: FlashMath.formatPower(power),
      valueLabel: formatLength(distance, useFeet: useFeet),
      key: ValueKey('flash-power-${FlashMath.formatPower(power)}'),
      recommendedKey: selected
          ? const ValueKey('flash-recommended-power')
          : null,
    );
  }

  Widget _distanceTick(int distanceUnits, Color accent) {
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

    return _tick(
      accent: accent,
      selected: selected,
      axisLabel: '$distanceUnits',
      valueLabel: valueLabel,
    );
  }

  Widget _tick({
    required Color accent,
    required bool selected,
    required String axisLabel,
    required String valueLabel,
    Key? key,
    Key? recommendedKey,
  }) {
    return Container(
      key: recommendedKey,
      decoration: selected
          ? BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Column(
        children: [
          SizedBox(
            height: 22,
            child: Center(
              child: Text(
                axisLabel,
                key: key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? accent : Colors.white54,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 10,
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
                  : Container(width: 1.5, height: 6, color: Colors.white24),
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                valueLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? accent : Colors.white70,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
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
  /// (weak/short on the left → full/long on the right).
  List<int> _integerDistances() {
    final full = FlashMath.distanceAtPower(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
      aperture: aperture,
      fraction: 1,
    );
    if (!full.isFinite || full <= 0) return const [];
    final maxU = convertLength(full, useFeet: useFeet).ceil().clamp(1, 200);

    const head = [1, 2, 4, 5];
    final out = <int>[];
    for (final d in head) {
      if (d <= maxU) out.add(d);
    }
    for (var d = 10; d <= maxU; d += 5) {
      out.add(d);
    }
    if (out.isEmpty) out.add(1);
    return out;
  }
}
