import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'exposure.dart';
import 'meter_debug.dart';
import 'metering.dart';
import 'tone_curve.dart';

/// One rung of an AE sweep: the exposure the camera settled on for a requested
/// EV compensation, plus the patch as the preview rendered it.
@immutable
class AeSweepPoint {
  const AeSweepPoint({
    required this.requestedOffset,
    required this.params,
    required this.sample,
  });

  /// EV compensation asked of the camera.
  final double requestedOffset;

  /// What the camera actually exposed at, per EXIF.
  final ExposureParams params;

  /// The metered patch as the preview stream rendered it at that exposure.
  final SpotSample sample;

  /// Scene EV₁₀₀ this rung reports, uncalibrated.
  ///
  /// The scene did not change during a sweep, so every rung should report the
  /// same number. Whatever spread appears is measurement error.
  double get sceneEv => ExposureMath.sceneEv(
        cameraEv100: params.ev100,
        linearLuminance: sample.linearLuminance,
      );
}

/// Result of sweeping AE across its compensation range on a static scene.
///
/// Because the scene is fixed, the true EV is constant. Any spread in
/// [AeSweepPoint.sceneEv] is error, and its shape says where the error is:
///
/// - **flat** — the pipeline is self-consistent; a single calibration offset
///   is enough, and any absolute error lies outside this measurement.
/// - **sloped/curved against patch luminance** — the sRGB inversion does not
///   describe the real tone curve, or the stills and preview pipelines
///   disagree. A per-luminance correction is required; one offset cannot fix
///   it.
@immutable
class AeSweepResult {
  const AeSweepResult({required this.points});

  final List<AeSweepPoint> points;

  bool get isEmpty => points.length < 2;

  /// Rungs whose patch is neither clipped nor crushed. Points outside this are
  /// beyond recovery and would poison a fit.
  List<AeSweepPoint> get usablePoints =>
      points.where((p) => p.sample.isUsable).toList();

  /// Reference EV: the median of the usable rungs, which is robust to a single
  /// bad rung in a way the mean is not.
  double get referenceEv {
    final usable = usablePoints.isEmpty ? points : usablePoints;
    final values = usable.map((p) => p.sceneEv).toList()..sort();
    if (values.isEmpty) return double.nan;
    final mid = values.length ~/ 2;
    if (values.length.isOdd) return values[mid];
    return (values[mid - 1] + values[mid]) / 2;
  }

  /// Per-rung deviation from [referenceEv], in stops.
  List<double> get residuals {
    final ref = referenceEv;
    return points.map((p) => p.sceneEv - ref).toList();
  }

  /// Largest disagreement between any two usable rungs, in stops.
  ///
  /// This is the headline number: it is how wrong the reading can be purely
  /// from where the camera happened to set its exposure.
  double get spread {
    final usable = usablePoints;
    if (usable.length < 2) return double.nan;
    final evs = usable.map((p) => p.sceneEv);
    return evs.reduce(max) - evs.reduce(min);
  }

  /// Least-squares slope of residual against encoded patch luminance.
  ///
  /// A non-zero slope means the error depends on where the patch sits on the
  /// tone curve — exactly what a constant offset cannot correct.
  double get residualSlopePerEncodedUnit {
    final usable = usablePoints;
    if (usable.length < 3) return double.nan;

    final ref = referenceEv;
    final xs = usable.map((p) => p.sample.encodedLuminance).toList();
    final ys = usable.map((p) => p.sceneEv - ref).toList();
    final n = xs.length;
    final meanX = xs.reduce((a, b) => a + b) / n;
    final meanY = ys.reduce((a, b) => a + b) / n;

    var num = 0.0;
    var den = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = xs[i] - meanX;
      num += dx * (ys[i] - meanY);
      den += dx * dx;
    }
    if (den.abs() < 1e-12) return double.nan;
    return num / den;
  }

  /// Whether the pipeline is consistent enough that one offset would do.
  ///
  /// A third of a stop is the finest adjustment most film workflows act on, so
  /// a spread below that is not worth modelling.
  bool get isConsistent {
    final s = spread;
    return s.isFinite && s < 1.0 / 3.0;
  }

  /// Fits this sweep into a tone curve for the device.
  ///
  /// The scene held still across the sweep, so every rung describes the same
  /// light at a different exposure — which is exactly the data needed to
  /// recover how the pipeline maps encoded values onto real luminance.
  ///
  /// Uses every rung, including ones outside the sRGB-usable band: those are
  /// the most valuable, because they cover the shadow and highlight regions
  /// where sRGB fails worst.
  ToneCurve? fitToneCurve() {
    return ToneCurve.fit(
      points
          .map(
            (p) => ToneCurveSample(
              encodedLuminance: p.sample.encodedLuminance,
              cameraEv100: p.params.ev100,
            ),
          )
          .toList(),
      recordedAt: DateTime.now(),
    );
  }

  /// Plain-language reading of what the sweep found.
  String get verdict {
    if (isEmpty) return 'Not enough rungs to judge.';
    final s = spread;
    if (!s.isFinite) return 'Not enough usable rungs to judge.';

    if (isConsistent) {
      return 'Consistent to ${s.toStringAsFixed(2)} EV across the AE range. '
          'The stills and preview pipelines agree, so a single calibration '
          'offset is enough — any remaining error is a constant and does not '
          'come from the tone curve.';
    }

    final slope = residualSlopePerEncodedUnit;
    if (slope.isFinite && slope.abs() > 0.5) {
      return 'Spread of ${s.toStringAsFixed(2)} EV, drifting '
          '${slope > 0 ? 'up' : 'down'} with patch brightness '
          '(${slope.toStringAsFixed(2)} EV per unit of encoded luminance). '
          'The sRGB inversion does not match the real tone curve. A single '
          'offset cannot fix this — a per-luminance correction is needed.';
    }

    return 'Spread of ${s.toStringAsFixed(2)} EV with no clean dependence on '
        'patch brightness. This points at the stills capture and the preview '
        'stream disagreeing (HDR / multi-frame processing on the still), not '
        'at the tone curve.';
  }

  static const List<String> csvColumns = [
    'requested_offset',
    'exif_n',
    'exif_t',
    'exif_iso',
    'exif_ev100',
    'lin_y',
    'enc_y',
    'stops_from_mid',
    'scene_ev',
    'residual',
    'usable',
  ];

  String toCsv() {
    final ref = referenceEv;
    final buffer = StringBuffer()..writeln(csvColumns.join(','));
    for (final p in points) {
      buffer.writeln([
        p.requestedOffset.toStringAsFixed(3),
        p.params.aperture.toStringAsFixed(3),
        p.params.shutterSeconds.toStringAsFixed(6),
        p.params.iso.toStringAsFixed(1),
        p.params.ev100.toStringAsFixed(3),
        p.sample.linearLuminance.toStringAsFixed(5),
        p.sample.encodedLuminance.toStringAsFixed(5),
        p.sample.stopsFromMiddleGrey.toStringAsFixed(3),
        p.sceneEv.toStringAsFixed(3),
        (p.sceneEv - ref).toStringAsFixed(3),
        p.sample.isUsable ? '1' : '0',
      ].join(','));
    }
    return buffer.toString();
  }

  /// CSV prefixed with a comment block carrying the conclusion, so the file is
  /// self-describing when read back on a desktop.
  String toReport({String? note}) {
    String num(double v, [int digits = 3]) =>
        v.isFinite ? v.toStringAsFixed(digits) : 'n/a';

    final buffer = StringBuffer()
      ..writeln('# ApertureDiary AE consistency sweep')
      ..writeln('# recorded: ${DateTime.now().toIso8601String()}')
      ..writeln('# rungs: ${points.length} (${usablePoints.length} usable)')
      ..writeln('# reference_ev100: ${num(referenceEv, 3)}')
      ..writeln('# spread_ev: ${num(spread, 3)}')
      ..writeln(
        '# residual_slope_per_encoded_unit: '
        '${num(residualSlopePerEncodedUnit, 3)}',
      )
      ..writeln('# consistent: $isConsistent')
      ..writeln('# verdict: $verdict');
    if (note != null && note.trim().isNotEmpty) {
      buffer.writeln('# note: ${note.trim().replaceAll('\n', ' ')}');
    }
    buffer.write(toCsv());
    return buffer.toString();
  }
}

/// Live progress of a running sweep.
@immutable
class AeSweepProgress {
  const AeSweepProgress({
    required this.done,
    required this.total,
    required this.message,
  });

  final int done;
  final int total;
  final String message;

  double get fraction => total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
}

/// Sheet that runs the sweep and reports what it found.
class AeSweepSheet extends StatefulWidget {
  const AeSweepSheet({
    super.key,
    required this.run,
    required this.accent,
    this.onCurveApplied,
  });

  /// Drives the sweep, reporting progress. Returns null if it could not run.
  final Future<AeSweepResult?> Function(void Function(AeSweepProgress))? run;

  final Color accent;

  /// Called once a fitted curve has been stored, so the meter can pick it up.
  final void Function(ToneCurve)? onCurveApplied;

  @override
  State<AeSweepSheet> createState() => _AeSweepSheetState();
}

class _AeSweepSheetState extends State<AeSweepSheet> {
  AeSweepProgress? _progress;
  AeSweepResult? _result;
  bool _running = false;
  String? _error;

  /// Where the last sweep was written, so it can be pulled off the device.
  String? _savedPath;

  /// Curve fitted from the last sweep, offered for use as the correction.
  ToneCurve? _fittedCurve;
  bool _curveApplied = false;

  Future<void> _start() async {
    final runner = widget.run;
    if (runner == null || _running) return;

    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _savedPath = null;
      _fittedCurve = null;
      _curveApplied = false;
      _progress = const AeSweepProgress(
        done: 0,
        total: 1,
        message: 'Starting…',
      );
    });

    try {
      final result = await runner((p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() {
        _result = result;
        _running = false;
        if (result == null) {
          _error = 'This device did not report enough exposure data to sweep.';
        } else if (result.isEmpty) {
          _error = 'Too few rungs completed to draw a conclusion.';
        }
      });

      // Persist straight away: a sweep is slow to repeat, and the file is the
      // artefact worth keeping.
      if (result != null && !result.isEmpty) {
        final path = await DiagnosticsExport.write(
          'ae_sweep_${DiagnosticsExport.timestampSlug()}.csv',
          result.toReport(),
        );
        if (!mounted) return;
        setState(() {
          _savedPath = path;
          _fittedCurve = result.fitToneCurve();
          if (path == null) {
            _error = 'Could not write the sweep file — grant storage access '
                'and use Copy CSV instead.';
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = 'Sweep failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'AE consistency sweep',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'Point at any evenly lit surface and hold the phone still. The '
              'sweep steps the camera through its exposure range while the '
              'scene stays put, so every step should report the same EV. '
              'Whatever spread appears is measurement error — no grey card or '
              'reference meter needed.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 14),
            if (_running) ...[
              LinearProgressIndicator(
                value: _progress?.fraction,
                color: widget.accent,
                backgroundColor: Colors.white12,
              ),
              const SizedBox(height: 8),
              Text(
                _progress?.message ?? '',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 4),
              const Text(
                'Keep the phone still and the scene unchanged.',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ],
            if (_error != null) ...[
              Text(
                _error!,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.orangeAccent,
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (result != null && !result.isEmpty) ...[
              _headline(result),
              const SizedBox(height: 10),
              _chart(result),
              const SizedBox(height: 10),
              Text(
                result.verdict,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              if (_fittedCurve != null) ...[
                const SizedBox(height: 10),
                _curveCard(_fittedCurve!),
              ],
              if (_savedPath != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121212),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Saved to',
                        style: TextStyle(fontSize: 9, color: Colors.white38),
                      ),
                      Text(
                        _savedPath!,
                        style: const TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
            ],
            if (!_running)
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: widget.run == null ? null : _start,
                      child: Text(
                        result == null ? 'Run sweep' : 'Run again',
                      ),
                    ),
                  ),
                  if (result != null && !result.isEmpty) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await Clipboard.setData(
                          ClipboardData(text: result.toCsv()),
                        );
                        if (!mounted) return;
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('Sweep CSV copied'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: const Text('Copy CSV'),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Offers the fitted curve as a correction, with what it would fix.
  Widget _curveCard(ToneCurve curve) {
    final worst = curve.worstSrgbErrorStops;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _curveApplied
              ? Colors.greenAccent.withValues(alpha: 0.4)
              : widget.accent.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _curveApplied
                    ? Icons.check_circle_outline
                    : Icons.auto_graph,
                size: 16,
                color: _curveApplied ? Colors.greenAccent : widget.accent,
              ),
              const SizedBox(width: 6),
              Text(
                _curveApplied
                    ? 'Tone curve in use'
                    : 'Tone curve measured',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _curveApplied ? Colors.greenAccent : widget.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Covers encoded ${curve.minEncoded.toStringAsFixed(2)}–'
            '${curve.maxEncoded.toStringAsFixed(2)} '
            '(${curve.rangeInStops.toStringAsFixed(1)} stops of scene range). '
            'Over that span the plain sRGB inversion is out by as much as '
            '${worst.toStringAsFixed(1)} EV; this replaces it with what the '
            'camera actually did.',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          if (!_curveApplied) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await ToneCurveStore.save(curve);
                  widget.onCurveApplied?.call(curve);
                  if (!mounted) return;
                  setState(() => _curveApplied = true);
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Tone curve applied to metering'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Use this correction'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _headline(AeSweepResult result) {
    final spread = result.spread;
    final ok = result.isConsistent;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ok ? Colors.greenAccent.withValues(alpha: 0.4) : Colors.orangeAccent,
        ),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.warning_amber_rounded,
            size: 18,
            color: ok ? Colors.greenAccent : Colors.orangeAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spread.isFinite
                      ? 'Spread ${spread.toStringAsFixed(2)} EV'
                      : 'Spread unavailable',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: ok ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                ),
                Text(
                  '${result.usablePoints.length} usable of '
                  '${result.points.length} rungs · '
                  'reference EV₁₀₀ ${result.referenceEv.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Residual per rung, as a small bar chart around the zero line.
  Widget _chart(AeSweepResult result) {
    final residuals = result.residuals;
    final peak = residuals.fold<double>(
      0.25,
      (acc, r) => max(acc, r.abs()),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Deviation from the median reading (±${peak.toStringAsFixed(1)} EV)',
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 64,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < result.points.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: _bar(
                        residual: residuals[i],
                        peak: peak,
                        usable: result.points[i].sample.isUsable,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '${result.points.first.requestedOffset.toStringAsFixed(1)} EV',
                style: const TextStyle(fontSize: 9, color: Colors.white38),
              ),
              const Spacer(),
              const Text(
                'AE compensation',
                style: TextStyle(fontSize: 9, color: Colors.white38),
              ),
              const Spacer(),
              Text(
                '+${result.points.last.requestedOffset.toStringAsFixed(1)} EV',
                style: const TextStyle(fontSize: 9, color: Colors.white38),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bar({
    required double residual,
    required double peak,
    required bool usable,
  }) {
    final frac = (residual / peak).clamp(-1.0, 1.0);
    final color = !usable
        ? Colors.white24
        : residual.abs() < 1.0 / 3.0
            ? Colors.greenAccent
            : Colors.orangeAccent;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final half = constraints.maxHeight / 2;
        final height = (half * frac.abs()).clamp(1.0, half);
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: half,
              child: Container(height: 1, color: Colors.white24),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: frac >= 0 ? half - height : half,
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
