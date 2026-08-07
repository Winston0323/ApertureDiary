import 'package:flutter/material.dart';

import 'exposure.dart';
import 'flash.dart';
import 'flash_scale.dart';
import 'number_input_dialog.dart';
import 'units.dart';
import 'wheel_dial.dart';

const Color _accent = Color(0xFFFFB300);

/// Standalone guide-number flash calculator.
class FlashPage extends StatefulWidget {
  const FlashPage({
    super.key,
    required this.iso,
    required this.aperture,
    this.ambientEv,
  });

  final int iso;
  final double aperture;

  /// Ambient EV₁₀₀ from the meter, if a reading exists. Used only for the
  /// "ambient alone needs …" sync-speed note.
  final double? ambientEv;

  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> {
  /// Locked to the film ISO from the light meter — edit ISO there only.
  int get _iso => widget.iso;
  late double _aperture = widget.aperture;

  /// Guide number at ISO 100 and flash-to-subject distance, both in metres.
  double _guideNumber = 36.0;
  double _distance = 3.0;
  bool _useFeet = false;

  double _convertLength(double metres) =>
      convertLength(metres, useFeet: _useFeet);

  String _formatLength(double metres) =>
      formatLength(metres, useFeet: _useFeet);

  _FlashResult get _result {
    final exact = FlashMath.powerFraction(
      guideNumberIso100: _guideNumber,
      iso: _iso,
      aperture: _aperture,
      distance: _distance,
    );
    if (!exact.isFinite) {
      return const _FlashResult(
        title: 'Flash power',
        value: '—',
        detail: 'Enter a guide number and a distance',
      );
    }

    final fullPowerReach = FlashMath.distanceAtPower(
      guideNumberIso100: _guideNumber,
      iso: _iso,
      aperture: _aperture,
      fraction: 1,
    );
    final workingGn = FlashMath.guideNumberAtIso(
      guideNumberIso100: _guideNumber,
      iso: _iso,
    );
    final reachNote = 'Full power reaches ${_formatLength(fullPowerReach)} at '
        '${ExposureMath.formatAperture(_aperture)}  ·  '
        'GN ${formatNumber(_convertLength(workingGn))} at ISO $_iso';

    if (exact > 1) {
      final short = FlashMath.stopsBeyondFullPower(exact);
      final needed = FlashMath.apertureAtPower(
        guideNumberIso100: _guideNumber,
        iso: _iso,
        distance: _distance,
        fraction: 1,
      );
      return _FlashResult(
        title: 'Flash power',
        value: '1/1',
        detail: reachNote,
        warning: 'Out of reach by ${short.toStringAsFixed(1)} stops — open to '
            '${ExposureMath.formatAperture(needed)}, move closer, or use '
            'faster film',
      );
    }

    final snapped = FlashMath.snapPower(exact);
    final error = FlashMath.snapErrorStops(exact: exact, snapped: snapped);

    String? warning;
    if (exact < FlashMath.weakestPower) {
      final weakestReach = FlashMath.distanceAtPower(
        guideNumberIso100: _guideNumber,
        iso: _iso,
        aperture: _aperture,
        fraction: FlashMath.weakestPower,
      );
      warning = 'Less light needed than 1/128 gives — stop down or move back '
          'past ${_formatLength(weakestReach)}';
    }

    return _FlashResult(
      title: 'Flash power',
      value: FlashMath.formatPower(snapped),
      detail: 'exact ${FlashMath.formatPowerPercent(exact)}  ·  '
          'rounding ${ExposureMath.formatStops(error)}',
      note: reachNote,
      warning: warning,
    );
  }

  /// Shutter that would expose the ambient light the same way, so you can see
  /// whether the background will register alongside the flash.
  String? get _ambientShutterNote {
    final ev = widget.ambientEv;
    if (ev == null) return null;
    final t =
        ExposureMath.shutterFromEv(ev100: ev, aperture: _aperture, iso: _iso);
    return 'Ambient alone needs '
        '${ExposureMath.formatShutter(ExposureMath.snapShutter(t))} — stay at '
        'or below your sync speed to keep it dark';
  }

  /// The setting the scale should mark, or null when the subject is out of
  /// reach at full power.
  double? get _recommendedPower {
    final exact = FlashMath.powerFraction(
      guideNumberIso100: _guideNumber,
      iso: _iso,
      aperture: _aperture,
      distance: _distance,
    );
    if (!exact.isFinite || exact > 1) return null;
    return FlashMath.snapPower(exact);
  }

  Future<void> _promptGuideNumber() async {
    final entered = await _promptNumber(
      title: 'Guide number',
      helper: 'As rated at ISO 100, in ${_useFeet ? 'feet' : 'metres'}',
      initial: _convertLength(_guideNumber),
      lowest: 1,
      highest: 300,
    );
    if (entered == null) return;
    setState(() {
      _guideNumber = toMetres(entered, useFeet: _useFeet);
    });
  }

  Future<void> _promptDistance() async {
    final entered = await _promptNumber(
      title: 'Flash to subject',
      helper: _useFeet ? 'In feet' : 'In metres',
      initial: _convertLength(_distance),
      lowest: 0.1,
      highest: 300,
    );
    if (entered == null) return;
    setState(() {
      _distance = toMetres(entered, useFeet: _useFeet);
    });
  }

  Future<double?> _promptNumber({
    required String title,
    required String helper,
    required double initial,
    required double lowest,
    required double highest,
  }) async {
    final entered = await showDialog<double>(
      context: context,
      builder: (ctx) => NumberInputDialog(
        title: title,
        helper: helper,
        initialText: formatNumber(initial),
      ),
    );
    if (entered == null || !entered.isFinite || entered <= 0) return null;
    return entered.clamp(lowest, highest);
  }

  Future<void> _pickAperture() async {
    final chosen = await _showWheelPicker<double>(
      title: 'Aperture',
      items: ExposureMath.standardApertures,
      initial: _aperture,
      labelOf: ExposureMath.formatAperture,
    );
    if (chosen != null) setState(() => _aperture = chosen);
  }

  Future<T?> _showWheelPicker<T>({
    required String title,
    required List<T> items,
    required T initial,
    required String Function(T) labelOf,
  }) {
    var index = items.indexOf(initial);
    if (index < 0) index = 0;

    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => WheelDialSheet<T>(
        title: title,
        items: items,
        initialIndex: index,
        labelOf: labelOf,
        accent: _accent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        title: const Text('Flash'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: _readOnlyTile(
                    label: 'Film ISO',
                    value: '$_iso',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _pickerTile(
                    label: 'Aperture',
                    value: ExposureMath.formatAperture(_aperture),
                    onTap: _pickAperture,
                    emphasize: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _pickerTile(
                    label: 'Guide no. (ISO 100)',
                    value: formatNumber(_convertLength(_guideNumber)),
                    onTap: _promptGuideNumber,
                    icon: Icons.edit_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _pickerTile(
                    label: 'Distance',
                    value: _formatLength(_distance),
                    onTap: _promptDistance,
                    icon: Icons.edit_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 72,
                  child: _pickerTile(
                    label: 'Unit',
                    value: _useFeet ? 'ft' : 'm',
                    onTap: () => setState(() => _useFeet = !_useFeet),
                    icon: Icons.swap_horiz,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildResultCard(result),
            const SizedBox(height: 12),
            FlashRangeScale(
              guideNumberIso100: _guideNumber,
              iso: _iso,
              aperture: _aperture,
              useFeet: _useFeet,
              highlightedPower: _recommendedPower,
              subjectDistance: _distance,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(_FlashResult result) {
    final ambient = _ambientShutterNote;
    const noteStyle = TextStyle(fontSize: 10.5, color: Colors.white38);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33FFB300)),
      ),
      child: Column(
        children: [
          Text(
            result.title,
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          Text(
            result.value,
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: _accent,
              letterSpacing: -0.5,
              height: 1.1,
            ),
          ),
          Text(result.detail, style: noteStyle, textAlign: TextAlign.center),
          if (result.note != null)
            Text(result.note!, style: noteStyle, textAlign: TextAlign.center),
          if (ambient != null)
            Text(ambient, style: noteStyle, textAlign: TextAlign.center),
          if (result.warning != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      result.warning!,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Colors.orangeAccent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _readOnlyTile({
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickerTile({
    required String label,
    required String value,
    required VoidCallback onTap,
    IconData icon = Icons.expand_more,
    bool emphasize = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: emphasize
              ? const Color(0xFF221C0A)
              : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: emphasize ? const Color(0x55FFB300) : Colors.white12,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: emphasize ? _accent.withValues(alpha: 0.8) : Colors.white54,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: emphasize ? 22 : 19,
                      fontWeight: FontWeight.w700,
                      color: emphasize ? _accent : Colors.white,
                      letterSpacing: emphasize ? -0.4 : 0,
                    ),
                  ),
                ),
                Icon(
                  icon,
                  color: emphasize
                      ? _accent.withValues(alpha: 0.7)
                      : Colors.white38,
                  size: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

@immutable
class _FlashResult {
  final String title;
  final String value;
  final String detail;
  final String? note;
  final String? warning;

  const _FlashResult({
    required this.title,
    required this.value,
    required this.detail,
    this.note,
    this.warning,
  });
}
