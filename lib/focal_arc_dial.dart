import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'film_format.dart';

/// Linear focal dial with magnetic snap to typical lens stops.
class FocalArcDial extends StatefulWidget {
  const FocalArcDial({
    super.key,
    required this.lensesMm,
    required this.valueMm,
    required this.format,
    required this.onChanged,
    required this.onInteraction,
    required this.accent,
  });

  final List<double> lensesMm;
  final double valueMm;
  final FilmFormat format;
  final ValueChanged<double> onChanged;
  final VoidCallback onInteraction;
  final Color accent;

  @override
  State<FocalArcDial> createState() => _FocalArcDialState();
}

class _FocalArcDialState extends State<FocalArcDial> {
  /// Horizontal pixels per millimetre of focal length.
  static const double _pxPerMm = 10;

  /// Detent spacing — stick to every 5 mm stop.
  static const double _stepMm = 5;

  /// Stick when nearly stopped this close to a 5 mm stop.
  static const double _adhesiveMm = 2.0;

  late ScrollController _controller;
  late double _minMm;
  late double _maxMm;
  late List<double> _magnets;
  late List<double> _typicalLenses;
  double _reportedMm = 0;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _configureRange();
    _reportedMm = _clampMm(widget.valueMm);
    _controller = ScrollController(
      initialScrollOffset: _offsetForMm(_reportedMm),
    );
    _controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant FocalArcDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lensesMm != widget.lensesMm) {
      _configureRange();
    }
    final next = _clampMm(widget.valueMm);
    if ((next - _reportedMm).abs() < 0.05) return;
    if (!_controller.hasClients) return;
    if (_controller.position.isScrollingNotifier.value) return;
    _reportedMm = next;
    _syncing = true;
    _controller.jumpTo(_offsetForMm(next));
    _syncing = false;
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _configureRange() {
    _typicalLenses = List<double>.from(widget.lensesMm)..sort();
    if (_typicalLenses.isEmpty) {
      _minMm = 20;
      _maxMm = 200;
    } else {
      // Extend to 5 mm grid covering the format's usual lenses.
      _minMm = (_typicalLenses.first / _stepMm).floor() * _stepMm;
      _maxMm = (_typicalLenses.last / _stepMm).ceil() * _stepMm;
      if (_maxMm <= _minMm) _maxMm = _minMm + _stepMm;
    }
    _magnets = [
      for (var mm = _minMm; mm <= _maxMm + 0.001; mm += _stepMm) mm,
    ];
  }

  double get _contentWidth => math.max(1, (_maxMm - _minMm) * _pxPerMm);

  double _clampMm(double mm) => mm.clamp(_minMm, _maxMm);

  double _offsetForMm(double mm) => (_clampMm(mm) - _minMm) * _pxPerMm;

  double _mmForOffset(double offset) =>
      _clampMm(_minMm + offset / _pxPerMm);

  double _nearestMagnet(double mm) {
    if (_magnets.isEmpty) return mm;
    var best = _magnets.first;
    var bestDiff = double.infinity;
    for (final m in _magnets) {
      final d = (m - mm).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = m;
      }
    }
    return best;
  }

  void _onScroll() {
    if (_syncing || !_controller.hasClients) return;
    widget.onInteraction();
    final raw = double.parse(_mmForOffset(_controller.offset).toStringAsFixed(1));
    if ((raw - _reportedMm).abs() >= 0.05) {
      final wasNearMagnet = _magnets.any((m) => (raw - m).abs() < 0.2);
      final previouslyNear =
          _magnets.any((m) => (_reportedMm - m).abs() < 0.2);
      if (wasNearMagnet && !previouslyNear) {
        HapticFeedback.selectionClick();
      }
      _reportedMm = raw;
      widget.onChanged(raw);
      setState(() {});
    } else {
      setState(() {});
    }
  }

  void _onScrollEnd() {
    if (!_controller.hasClients) return;
    widget.onInteraction();
    // Keep the linear value; only nudge onto a typical stop if already inside
    // the narrow adhesive band (detent), otherwise leave mm as-is.
    final mm = _mmForOffset(_controller.offset);
    final magnet = _nearestMagnet(mm);
    final targetMm =
        (mm - magnet).abs() <= _adhesiveMm ? magnet : mm;
    if ((targetMm - mm).abs() > 0.05) {
      _controller.animateTo(
        _offsetForMm(targetMm),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
      _reportedMm = targetMm;
      widget.onChanged(targetMm);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayMm = _reportedMm;
    final magnet = _nearestMagnet(displayMm);
    final onMagnet = (displayMm - magnet).abs() < 0.2;
    final eq = widget.format.to35mmEquivalent(onMagnet ? magnet : displayMm);

    return Material(
      color: Colors.transparent,
      child: Container(
        height: 128,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: 0.55),
              Colors.black.withValues(alpha: 0.88),
            ],
            stops: const [0.0, 0.35, 1.0],
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 6),
            Text(
              onMagnet
                  ? '${magnet.round()} mm'
                  : '${displayMm.toStringAsFixed(displayMm == displayMm.roundToDouble() ? 0 : 1)} mm',
              style: TextStyle(
                color: widget.accent,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1.1,
              ),
            ),
            Text(
              '≈ ${eq.round()} mm eq  ·  ${widget.format.label}',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sidePad = constraints.maxWidth / 2;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n is ScrollStartNotification ||
                              n is ScrollUpdateNotification) {
                            widget.onInteraction();
                          }
                          if (n is ScrollEndNotification) {
                            _onScrollEnd();
                          }
                          return false;
                        },
                        child: SingleChildScrollView(
                          controller: _controller,
                          scrollDirection: Axis.horizontal,
                          physics: _MagneticScrollPhysics(
                            magnetsMm: _magnets,
                            minMm: _minMm,
                            pxPerMm: _pxPerMm,
                            adhesiveMm: _adhesiveMm,
                            parent: const ClampingScrollPhysics(),
                          ),
                          child: SizedBox(
                            width: _contentWidth + sidePad * 2,
                            height: constraints.maxHeight,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: sidePad,
                              ),
                              child: CustomPaint(
                                painter: _LinearRulerPainter(
                                  minMm: _minMm,
                                  maxMm: _maxMm,
                                  magnets: _magnets,
                                  typicalLenses: _typicalLenses,
                                  accent: widget.accent,
                                  pxPerMm: _pxPerMm,
                                ),
                                size: Size(
                                  _contentWidth,
                                  constraints.maxHeight,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      IgnorePointer(
                        child: CustomPaint(
                          size: Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          ),
                          painter: _CenterHairPainter(accent: widget.accent),
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

/// Mostly free linear scrolling; only sticks when almost stopped on a typical stop.
class _MagneticScrollPhysics extends ScrollPhysics {
  const _MagneticScrollPhysics({
    required this.magnetsMm,
    required this.minMm,
    required this.pxPerMm,
    required this.adhesiveMm,
    super.parent,
  });

  final List<double> magnetsMm;
  final double minMm;
  final double pxPerMm;
  final double adhesiveMm;

  @override
  _MagneticScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _MagneticScrollPhysics(
      magnetsMm: magnetsMm,
      minMm: minMm,
      pxPerMm: pxPerMm,
      adhesiveMm: adhesiveMm,
      parent: buildParent(ancestor),
    );
  }

  double _mmForPixels(double pixels) => minMm + pixels / pxPerMm;

  double _pixelsForMm(double mm) => (mm - minMm) * pxPerMm;

  double _nearestMagnetMm(double mm) {
    if (magnetsMm.isEmpty) return mm;
    var best = magnetsMm.first;
    var bestDiff = double.infinity;
    for (final m in magnetsMm) {
      final d = (m - mm).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = m;
      }
    }
    return best;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final mm = _mmForPixels(position.pixels);
    final magnet = _nearestMagnetMm(mm);
    final dist = (mm - magnet).abs();

    // Free linear coast by default. Detent only when nearly stopped in-band.
    if (velocity.abs() < 80 && dist <= adhesiveMm) {
      final target = _pixelsForMm(magnet).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < 0.5) return null;
      return ScrollSpringSimulation(
        SpringDescription(mass: 1, stiffness: 180, damping: 22),
        position.pixels,
        target,
        velocity,
        tolerance: toleranceFor(position),
      );
    }

    return super.createBallisticSimulation(position, velocity);
  }
}

class _LinearRulerPainter extends CustomPainter {
  _LinearRulerPainter({
    required this.minMm,
    required this.maxMm,
    required this.magnets,
    required this.typicalLenses,
    required this.accent,
    required this.pxPerMm,
  });

  final double minMm;
  final double maxMm;
  final List<double> magnets;
  final List<double> typicalLenses;
  final Color accent;
  final double pxPerMm;

  bool _isTypical(double mm) =>
      typicalLenses.any((m) => (m - mm).abs() < 0.01);

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height * 0.42;
    final minor = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    final fivePaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.5;
    final typicalPaint = Paint()
      ..color = accent.withValues(alpha: 0.95)
      ..strokeWidth = 2;

    final start = minMm.ceil();
    final end = maxMm.floor();
    for (var mm = start; mm <= end; mm++) {
      final x = (mm - minMm) * pxPerMm;
      final isFive = magnets.any((m) => (m - mm).abs() < 0.01);
      final isTypical = _isTypical(mm.toDouble());
      final h = isTypical ? 22.0 : (isFive ? 16.0 : 8.0);
      final paint = isTypical ? typicalPaint : (isFive ? fivePaint : minor);
      canvas.drawLine(
        Offset(x, baseline - h / 2),
        Offset(x, baseline + h / 2),
        paint,
      );

      if (isFive) {
        final tp = TextPainter(
          text: TextSpan(
            text: '$mm',
            style: TextStyle(
              color: isTypical ? accent : Colors.white54,
              fontSize: isTypical ? 12 : 10,
              fontWeight: isTypical ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(x - tp.width / 2, baseline + h / 2 + 4),
        );
      }
    }

    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _LinearRulerPainter old) =>
      old.minMm != minMm ||
      old.maxMm != maxMm ||
      old.pxPerMm != pxPerMm ||
      old.accent != accent ||
      old.magnets != magnets ||
      old.typicalLenses != typicalLenses;
}

class _CenterHairPainter extends CustomPainter {
  _CenterHairPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    canvas.drawLine(
      Offset(cx, 4),
      Offset(cx, size.height - 8),
      Paint()
        ..color = accent
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    final fade = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withValues(alpha: 0.7),
          Colors.transparent,
          Colors.transparent,
          Colors.black.withValues(alpha: 0.7),
        ],
        stops: const [0.0, 0.18, 0.82, 1.0],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, fade);
  }

  @override
  bool shouldRepaint(covariant _CenterHairPainter old) =>
      old.accent != accent;
}
