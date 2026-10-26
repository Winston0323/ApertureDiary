import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'exposure.dart';
import 'flash.dart';
import 'flash_prefs.dart';
import 'flash_scale.dart';
import 'number_input_dialog.dart';
import 'units.dart';

const Color _accent = Color(0xFFFFB300);

/// Standalone guide-number flash calculator.
class FlashPage extends StatefulWidget {
  const FlashPage({
    super.key,
    required this.iso,
    required this.aperture,
    this.ambientEv,
    this.initialDistance,
  });

  final int iso;
  final double aperture;

  /// Ambient EV₁₀₀ from the meter, if a reading exists. Used only for the
  /// "ambient alone needs …" sync-speed note.
  final double? ambientEv;

  /// Last measured subject distance from the meter (metres), if any.
  final double? initialDistance;

  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> {
  /// Locked to the film ISO from the light meter — edit ISO there only.
  int get _iso => widget.iso;
  late double _aperture = widget.aperture;

  /// Guide number at ISO 100 and flash-to-subject distance, both in metres.
  double _guideNumber = FlashPrefsStore.defaultGuideNumber;
  late double _distance = _initialDistanceOrDefault();
  bool _useFeet = false;

  @override
  void initState() {
    super.initState();
    _loadGuideNumber();
  }

  Future<void> _loadGuideNumber() async {
    final gn = await FlashPrefsStore.loadGuideNumber();
    if (!mounted) return;
    setState(() => _guideNumber = gn);
  }

  double _initialDistanceOrDefault() {
    final d = widget.initialDistance;
    if (d != null && d.isFinite && d > 0.2 && d < 40) return d;
    return 3.0;
  }

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
    final gn = toMetres(entered, useFeet: _useFeet);
    setState(() => _guideNumber = gn);
    await FlashPrefsStore.saveGuideNumber(gn);
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
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
                          label: 'Guide no. (ISO 100)',
                          value: formatNumber(_convertLength(_guideNumber)),
                          onTap: _promptGuideNumber,
                          icon: Icons.edit_outlined,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
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
            _ApertureDial(
              value: _aperture,
              onChanged: (v) => setState(() => _aperture = v),
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

/// Horizontal f-stop ring, pinned to the bottom like a lens aperture dial.
class _ApertureDial extends StatefulWidget {
  const _ApertureDial({
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_ApertureDial> createState() => _ApertureDialState();
}

class _ApertureDialState extends State<_ApertureDial> {
  static const double _itemWidth = 56;
  static const List<double> _stops = ExposureMath.standardApertures;

  late final ScrollController _controller;
  late int _index;
  bool _syncing = false;

  int _nearestIndex(double aperture) {
    var best = 0;
    var bestDiff = double.infinity;
    for (var i = 0; i < _stops.length; i++) {
      final d = (_stops[i] - aperture).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = i;
      }
    }
    return best;
  }

  double _offsetForIndex(int i) => i * _itemWidth;

  int _indexForOffset(double offset) {
    if (_stops.isEmpty) return 0;
    return (offset / _itemWidth)
        .round()
        .clamp(0, _stops.length - 1);
  }

  @override
  void initState() {
    super.initState();
    _index = _nearestIndex(widget.value);
    _controller = ScrollController(
      initialScrollOffset: _offsetForIndex(_index),
    );
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _syncing = true;
      _controller.jumpTo(_offsetForIndex(_index));
      _syncing = false;
    });
  }

  @override
  void didUpdateWidget(covariant _ApertureDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _nearestIndex(widget.value);
    if (next == _index) return;
    if (!_controller.hasClients) return;
    if (_controller.position.isScrollingNotifier.value) return;
    _index = next;
    _syncing = true;
    _controller.jumpTo(_offsetForIndex(next));
    _syncing = false;
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_syncing || !_controller.hasClients) return;
    final next = _indexForOffset(_controller.offset);
    if (next == _index) return;
    HapticFeedback.selectionClick();
    _index = next;
    widget.onChanged(_stops[next]);
    setState(() {});
  }

  void _onScrollEnd() {
    if (!_controller.hasClients) return;
    final target = _offsetForIndex(_indexForOffset(_controller.offset));
    if ((target - _controller.offset).abs() < 0.5) return;
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
  }

  String _ringLabel(double n) {
    if (n < 10) {
      final s = n.toStringAsFixed(1);
      return s.endsWith('.0') ? n.toStringAsFixed(0) : s;
    }
    return n.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final current = _stops[_index];
    return Material(
      color: Colors.transparent,
      child: Container(
        height: 118,
        decoration: BoxDecoration(
          border: const Border(
            top: BorderSide(color: Color(0x22FFB300)),
          ),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: 0.55),
              Colors.black.withValues(alpha: 0.92),
            ],
            stops: const [0.0, 0.28, 1.0],
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            const Text(
              'Aperture',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              ExposureMath.formatAperture(current),
              style: const TextStyle(
                color: _accent,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                height: 1.1,
                letterSpacing: -0.4,
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sidePad =
                      (constraints.maxWidth - _itemWidth) / 2;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n is ScrollEndNotification) {
                            _onScrollEnd();
                          }
                          return false;
                        },
                        child: SingleChildScrollView(
                          controller: _controller,
                          scrollDirection: Axis.horizontal,
                          physics: const _StopSnapPhysics(
                            itemWidth: _itemWidth,
                            parent: BouncingScrollPhysics(),
                          ),
                          child: SizedBox(
                            width:
                                _stops.length * _itemWidth + sidePad * 2,
                            height: constraints.maxHeight,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: sidePad,
                              ),
                              child: Row(
                                children: [
                                  for (var i = 0; i < _stops.length; i++)
                                    SizedBox(
                                      width: _itemWidth,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {
                                          _controller.animateTo(
                                            _offsetForIndex(i),
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            curve: Curves.easeOutCubic,
                                          );
                                        },
                                        child: Center(
                                          child: Text(
                                            _ringLabel(_stops[i]),
                                            style: TextStyle(
                                              fontSize:
                                                  i == _index ? 18 : 14,
                                              fontWeight: i == _index
                                                  ? FontWeight.w800
                                                  : FontWeight.w500,
                                              color: i == _index
                                                  ? _accent
                                                  : Colors.white54,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      IgnorePointer(
                        child: Center(
                          child: Container(
                            width: _itemWidth,
                            height: 36,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _accent.withValues(alpha: 0.55),
                              ),
                              color: _accent.withValues(alpha: 0.08),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Snaps a horizontal f-stop ring onto whole stop centres.
class _StopSnapPhysics extends ScrollPhysics {
  const _StopSnapPhysics({required this.itemWidth, super.parent});

  final double itemWidth;

  @override
  _StopSnapPhysics applyTo(ScrollPhysics? ancestor) {
    return _StopSnapPhysics(
      itemWidth: itemWidth,
      parent: buildParent(ancestor),
    );
  }

  double _targetPixels(ScrollMetrics position, double velocity) {
    final projected = position.pixels + velocity.clamp(-900, 900) * 0.12;
    final index = (projected / itemWidth).round();
    return (index * itemWidth).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final target = _targetPixels(position, velocity);
    if ((target - position.pixels).abs() < 0.5 && velocity.abs() < 20) {
      return null;
    }
    return ScrollSpringSimulation(
      const SpringDescription(mass: 0.8, stiffness: 180, damping: 22),
      position.pixels,
      target,
      velocity,
      tolerance: toleranceFor(position),
    );
  }
}
