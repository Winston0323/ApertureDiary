import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'exposure.dart';
import 'metering.dart';

/// Writes diagnostic files somewhere reachable from a desktop over adb.
///
/// App-private storage needs `run-as` (blocked on release builds), so
/// diagnostics go to public Downloads where `adb pull` can reach them without
/// ceremony.
class DiagnosticsExport {
  DiagnosticsExport._();

  /// Public folder the app already uses for its backups.
  static const String folderName = 'ApertureDiary';

  /// Path of the most recent successful write, for display.
  static String? lastPath;

  /// Rejects anything that is not a plain file name, so a caller cannot walk
  /// out of the diagnostics folder.
  static bool _isSafeName(String name) {
    if (name.isEmpty || name.length > 128) return false;
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) &&
        name != '.' &&
        name != '..';
  }

  static Future<bool> _ensureAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      var status = await Permission.manageExternalStorage.status;
      if (status.isGranted) return true;
      status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;
      final storage = await Permission.storage.request();
      return storage.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Directory>> _targetDirs() async {
    final out = <Directory>[];
    if (Platform.isAndroid) {
      out.add(Directory('/storage/emulated/0/Download/$folderName'));
      out.add(Directory('/sdcard/Download/$folderName'));
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          out.add(Directory('${ext.path}${Platform.pathSeparator}diagnostics'));
        }
      } catch (_) {
        // Fall through to the app documents directory.
      }
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      out.add(Directory('${docs.path}${Platform.pathSeparator}diagnostics'));
    } catch (_) {
      // Nothing else to try.
    }
    return out;
  }

  /// Writes [contents] to every reachable diagnostics folder.
  ///
  /// Returns the first path written, or null when nothing was writable.
  static Future<String?> write(String fileName, String contents) async {
    if (!_isSafeName(fileName)) return null;
    await _ensureAccess();

    String? first;
    for (final dir in await _targetDirs()) {
      try {
        if (!await dir.exists()) await dir.create(recursive: true);
        final file = File('${dir.path}${Platform.pathSeparator}$fileName');
        await file.writeAsString(contents, encoding: utf8, flush: true);
        first ??= file.path;
      } catch (_) {
        // Try the next candidate.
      }
    }
    if (first != null) lastPath = first;
    return first;
  }

  /// `2026-09-03T14-22-05` — safe on every filesystem.
  static String timestampSlug([DateTime? at]) {
    final t = at ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}'
        'T${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
  }
}

/// A full snapshot of everything the EV reading was derived from.
///
/// Metering accuracy cannot be reasoned about from the final number alone: an
/// error of +1 EV could come from the EXIF exposure, from the tone curve
/// inversion of the sampled patch, or from the calibration offset. This carries
/// every intermediate so a reading can be attributed to its source.
@immutable
class MeterDebugInfo {
  const MeterDebugInfo({
    required this.params,
    required this.sample,
    required this.rawSceneEv,
    required this.calibration,
    required this.smoothedEv100,
    required this.lensEv,
    required this.meterIso,
    required this.cctKelvin,
    required this.frameWidth,
    required this.frameHeight,
    required this.frameFormat,
    required this.exposureLocked,
    required this.measuredAt,
    required this.aeSettleMs,
    this.toneCurveRange,
    this.readingOutOfRange = false,
    this.servoResidual,
    this.servoSlope,
    this.servoCorrection,
    this.servoErrorBound,
    this.servoIterations,
    this.servoOutcome,
    this.duv,
    this.cctConfidence,
    this.wbReferenceKelvin,
    this.cctSource,
    this.exposureSource,
  });

  /// Exposure the camera reported for the metering still (EXIF).
  final ExposureParams? params;

  /// Latest sampled patch from the preview stream.
  final SpotSample? sample;

  /// Scene EV₁₀₀ before calibration and before smoothing.
  final double? rawSceneEv;

  final double calibration;

  /// Displayed EV₁₀₀ (calibrated + smoothed).
  final double? smoothedEv100;

  /// Displayed Hasselblad lens-scale EV at [meterIso].
  final double? lensEv;

  final int meterIso;
  final double? cctKelvin;

  final int? frameWidth;
  final int? frameHeight;
  final String? frameFormat;

  final bool exposureLocked;
  final DateTime? measuredAt;
  final int aeSettleMs;

  /// Encoded span the measured tone curve covers, or null when metering is
  /// still falling back to the sRGB inversion.
  final String? toneCurveRange;

  /// True when the patch is outside any described range, so the shown EV is
  /// held over rather than current.
  final bool readingOutOfRange;

  /// How far the patch sits from the servo's mid-grey target, encoded units.
  final double? servoResidual;

  /// Slope the servo measured on this device, stops per encoded unit.
  final double? servoSlope;

  /// Stops of correction the residual contributes to the reading.
  final double? servoCorrection;

  /// Rough error bound implied by residual times slope uncertainty.
  final double? servoErrorBound;

  final int? servoIterations;
  final String? servoOutcome;

  /// Signed distance of the patch from the black-body locus. Far from zero, the
  /// colour is not something a temperature describes.
  final double? duv;

  final String? cctConfidence;

  /// Temperature the white-balance reference was anchored to, if any.
  final double? wbReferenceKelvin;

  /// Where the colour temperature came from: the sensor's raw white point, or
  /// the rendered pixels that auto white balance has already corrected.
  final String? cctSource;

  /// Where the exposure came from: the preview frame's own metadata, or a still
  /// capture's EXIF.
  final String? exposureSource;

  /// Age of the EXIF exposure the reading leans on. A stale one means the
  /// scene may have changed since the camera last reported its settings.
  Duration? get sinceMeasured {
    final at = measuredAt;
    if (at == null) return null;
    return DateTime.now().difference(at);
  }

  static const List<String> csvColumns = [
    'timestamp',
    'ref_ev',
    'lens_ev',
    'ev100',
    'ev100_raw',
    'cal',
    'exif_n',
    'exif_t',
    'exif_iso',
    'exif_ev100',
    'lin_y',
    'enc_y',
    'stops_from_mid',
    'r',
    'g',
    'b',
    'cct',
    'meter_iso',
    'frame_w',
    'frame_h',
    'format',
    'ae_locked',
    'note',
  ];

  static String get csvHeader => csvColumns.join(',');

  /// One CSV row. [referenceEv] is the trusted meter's lens-scale EV, which is
  /// what the error column is computed against offline.
  String toCsvRow({double? referenceEv, String note = ''}) {
    String n(double? v, [int digits = 4]) =>
        (v == null || !v.isFinite) ? '' : v.toStringAsFixed(digits);

    final s = sample;
    final p = params;
    return [
      DateTime.now().toIso8601String(),
      n(referenceEv, 2),
      n(lensEv, 2),
      n(smoothedEv100, 3),
      n(rawSceneEv, 3),
      n(calibration, 2),
      n(p?.aperture, 3),
      n(p?.shutterSeconds, 6),
      n(p?.iso, 1),
      n(p?.ev100, 3),
      n(s?.linearLuminance, 5),
      n(s?.encodedLuminance, 5),
      n(s?.stopsFromMiddleGrey, 3),
      s?.r.toString() ?? '',
      s?.g.toString() ?? '',
      s?.b.toString() ?? '',
      n(cctKelvin, 0),
      meterIso.toString(),
      frameWidth?.toString() ?? '',
      frameHeight?.toString() ?? '',
      frameFormat ?? '',
      exposureLocked ? '1' : '0',
      _escapeCsv(note),
    ].join(',');
  }

  static String _escapeCsv(String value) {
    if (!value.contains(RegExp(r'[",\n\r]'))) return value;
    return '"${value.replaceAll('"', '""')}"';
  }
}

/// Append-only CSV log of metering samples, for building an error curve
/// against a trusted meter.
///
/// Lives in the app-support directory: it is diagnostic data, not a user
/// document, and should not survive a reinstall or clutter the gallery.
class MeterLogStore {
  MeterLogStore._();

  static const String _fileName = 'meter_log.csv';

  /// Cap the log so a forgotten debug session cannot grow without bound.
  static const int maxRows = 2000;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<void> append(String row) async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        await file.writeAsString(
          '${MeterDebugInfo.csvHeader}\n$row\n',
          encoding: utf8,
        );
        return;
      }

      final existing = await file.readAsString(encoding: utf8);
      final rows = existing
          .split('\n')
          .skip(1) // header
          .where((l) => l.trim().isNotEmpty)
          .toList();

      if (rows.length < maxRows) {
        await file.writeAsString(
          '$row\n',
          mode: FileMode.append,
          encoding: utf8,
        );
        return;
      }

      // Roll the oldest samples out so a forgotten session cannot grow the
      // file without bound.
      final kept = rows.sublist(rows.length - maxRows + 1);
      await file.writeAsString(
        '${MeterDebugInfo.csvHeader}\n${kept.join('\n')}\n$row\n',
        encoding: utf8,
      );
    } catch (_) {
      // Diagnostics must never break metering.
    }
  }

  static Future<String> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return '';
      return await file.readAsString(encoding: utf8);
    } catch (_) {
      return '';
    }
  }

  /// Number of logged samples (excluding the header).
  static Future<int> count() async {
    final text = await read();
    if (text.isEmpty) return 0;
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty);
    return lines.isEmpty ? 0 : lines.length - 1;
  }

  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Ignore.
    }
  }

  /// Copies the log to public Downloads so it can be pulled off the device.
  ///
  /// Returns the written path, or null when storage was not writable.
  static Future<String?> export() async {
    final csv = await read();
    if (csv.isEmpty) return null;
    return DiagnosticsExport.write(
      'meter_log_${DiagnosticsExport.timestampSlug()}.csv',
      csv,
    );
  }
}

/// Compact live readout of the metering internals, drawn over the preview.
class MeterDebugOverlay extends StatelessWidget {
  const MeterDebugOverlay({
    super.key,
    required this.info,
    required this.onLogSample,
    required this.onOpenLog,
    required this.onClose,
  });

  final MeterDebugInfo info;
  final VoidCallback onLogSample;
  final VoidCallback onOpenLog;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = info.params;
    final s = info.sample;
    final age = info.sinceMeasured;

    return Container(
      width: 168,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'METER DEBUG',
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onClose,
                child: const Icon(Icons.close, size: 12, color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _row('lensEV', _fmt(info.lensEv, 2), highlight: true),
          _row('EV100', _fmt(info.smoothedEv100, 3)),
          _row('EV100 raw', _fmt(info.rawSceneEv, 3)),
          _row('cal', _fmt(info.calibration, 2)),
          const Divider(height: 8, color: Colors.white12),
          _row(
            'EXIF',
            p == null
                ? '—'
                : 'f/${p.aperture.toStringAsFixed(2)} '
                    '${ExposureMath.formatShutter(p.shutterSeconds)} '
                    'ISO${p.iso.round()}',
          ),
          _row('EXIF EV100', _fmt(p?.ev100, 3)),
          const Divider(height: 8, color: Colors.white12),
          _row('linear Y', _fmt(s?.linearLuminance, 5)),
          _row(
            'encoded Y',
            _fmt(s?.encodedLuminance, 4),
            // Outside this band the tone curve is compressed and the sRGB
            // inversion no longer describes it.
            warn: s != null &&
                (s.encodedLuminance > 0.72 || s.encodedLuminance < 0.12),
          ),
          _row(
            'stops→mid',
            _fmt(s?.stopsFromMiddleGrey, 2),
            warn: s != null && s.stopsFromMiddleGrey.abs() > 1.5,
          ),
          _row('RGB', s == null ? '—' : '${s.r} ${s.g} ${s.b}'),
          _row('CCT', info.cctKelvin == null
              ? '—'
              : '${info.cctKelvin!.round()}K'),
          _row(
            'Duv',
            info.duv == null
                ? '—'
                : '${info.duv! >= 0 ? '+' : ''}${info.duv!.toStringAsFixed(4)}',
            // Off the locus the temperature stops being a measurement.
            warn: info.duv != null && info.duv!.abs() > 0.006,
          ),
          _row('CCT conf', info.cctConfidence ?? '—'),
          _row(
            'CCT from',
            info.cctSource ?? '—',
            // Rendered pixels have had the illuminant divided out of them.
            warn: info.cctSource == 'rendered pixels',
          ),
          _row(
            'exp from',
            info.exposureSource ?? '—',
            warn: info.exposureSource == 'still EXIF',
          ),
          _row(
            'WB ref',
            info.wbReferenceKelvin == null
                ? 'none — AWB relative'
                : '${info.wbReferenceKelvin!.round()}K',
            warn: info.wbReferenceKelvin == null,
          ),
          const Divider(height: 8, color: Colors.white12),
          _row('servo', info.servoOutcome ?? '—'),
          _row(
            'residual',
            _fmt(info.servoResidual, 4),
            // Outside the band the correction is doing more work than it
            // should, and the slope's uncertainty starts to matter.
            warn: info.servoResidual != null &&
                info.servoResidual!.abs() > 0.055,
          ),
          _row('slope', _fmt(info.servoSlope, 2)),
          _row('correction', _fmt(info.servoCorrection, 3)),
          _row(
            '± error',
            _fmt(info.servoErrorBound, 3),
            warn: info.servoErrorBound != null &&
                info.servoErrorBound! > 1.0 / 3.0,
          ),
          _row('steps', info.servoIterations?.toString() ?? '—'),
          const Divider(height: 8, color: Colors.white12),
          _row(
            'curve',
            info.toneCurveRange ?? 'not needed',
          ),
          _row(
            'in range',
            info.readingOutOfRange ? 'NO — stale' : 'yes',
            warn: info.readingOutOfRange,
          ),
          const Divider(height: 8, color: Colors.white12),
          _row(
            'frame',
            info.frameWidth == null
                ? '—'
                : '${info.frameWidth}×${info.frameHeight} '
                    '${info.frameFormat ?? ''}',
          ),
          _row('meter ISO', info.meterIso.toString()),
          _row('AE', info.exposureLocked ? 'held' : 'live'),
          _row('AE settle', '${info.aeSettleMs} ms'),
          _row(
            'EXIF age',
            age == null ? '—' : '${(age.inMilliseconds / 1000).toStringAsFixed(1)} s',
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _button('Log sample', onLogSample, primary: true),
              const SizedBox(width: 6),
              _button('Log…', onOpenLog),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(double? v, int digits) {
    if (v == null || !v.isFinite) return '—';
    return v.toStringAsFixed(digits);
  }

  Widget _row(
    String label,
    String value, {
    bool highlight = false,
    bool warn = false,
  }) {
    final color = warn
        ? Colors.orangeAccent
        : highlight
            ? const Color(0xFFFFB300)
            : Colors.white70;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 66,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 9,
                color: Colors.white38,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontFamily: 'monospace',
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _button(String label, VoidCallback onTap, {bool primary = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: primary ? const Color(0xFFFFB300) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: primary ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }
}

/// Sheet for reviewing, copying, and clearing the metering log.
class MeterLogSheet extends StatefulWidget {
  const MeterLogSheet({super.key});

  @override
  State<MeterLogSheet> createState() => _MeterLogSheetState();
}

class _MeterLogSheetState extends State<MeterLogSheet> {
  String _csv = '';
  bool _loading = true;
  bool _exporting = false;
  String? _savedPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final csv = await MeterLogStore.read();
    if (!mounted) return;
    setState(() {
      _csv = csv;
      _loading = false;
    });
  }

  int get _rowCount {
    if (_csv.isEmpty) return 0;
    final lines = _csv.split('\n').where((l) => l.trim().isNotEmpty);
    return lines.isEmpty ? 0 : lines.length - 1;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text(
                  'Metering log',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '$_rowCount samples',
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Meter a grey card, enter the reading from a meter you trust, '
              'and log it. Repeat across EV 3–16, then copy the CSV out and '
              'plot the error against EV: a flat error means a single offset '
              'is enough, a sloped one means the tone curve needs a per-EV '
              'calibration curve.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: Text(
                          _csv.isEmpty ? 'No samples logged yet.' : _csv,
                          style: const TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 10),
            if (_savedPath != null) ...[
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
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _csv.isEmpty || _exporting
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            setState(() => _exporting = true);
                            final path = await MeterLogStore.export();
                            if (!mounted) return;
                            setState(() {
                              _exporting = false;
                              _savedPath = path;
                            });
                            if (path == null) {
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Could not write the file — storage '
                                    'access was refused',
                                  ),
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            }
                          },
                    child: Text(_exporting ? 'Saving…' : 'Save to Downloads'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _csv.isEmpty
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.of(context);
                          await Clipboard.setData(
                            ClipboardData(text: _csv),
                          );
                          if (!mounted) return;
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('CSV copied'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                  child: const Text('Copy'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _csv.isEmpty
                      ? null
                      : () async {
                          await MeterLogStore.clear();
                          if (!mounted) return;
                          setState(() => _savedPath = null);
                          await _load();
                        },
                  child: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
