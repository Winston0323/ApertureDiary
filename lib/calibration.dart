import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists the user's EV calibration offset so a meter matched against a
/// known reference stays matched across launches.
class CalibrationStore {
  static const String _fileName = 'calibration.json';

  static const double maxOffset = 3.0;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<double> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return 0.0;
      final data = jsonDecode(await file.readAsString());
      if (data is Map && data['evOffset'] is num) {
        final value = (data['evOffset'] as num).toDouble();
        return value.clamp(-maxOffset, maxOffset);
      }
    } catch (_) {
      // Calibration is a convenience; a failed read should not block metering.
    }
    return 0.0;
  }

  static Future<void> save(double evOffset) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode({'evOffset': evOffset}));
    } catch (_) {
      // Ignore write failures.
    }
  }
}

/// Why a calibration run did or did not produce an offset.
enum EvCalibrationStatus {
  /// An offset was solved and is within the allowed range.
  ok,

  /// Not enough settled frames were collected.
  tooFewSamples,

  /// The readings wandered too much for one number to describe them — the
  /// scene or the light moved, or the phone was not held still.
  unstable,

  /// The offset needed exceeds [CalibrationStore.maxOffset]. That is more likely
  /// a wrong reference or a wrong film speed than a real meter error.
  outOfRange,
}

/// The outcome of [EvCalibrationRun.solve].
class EvCalibrationResult {
  const EvCalibrationResult({
    required this.status,
    required this.samples,
    this.offset,
    this.measuredEv100,
    this.spread,
  });

  final EvCalibrationStatus status;

  /// Frames the result is based on.
  final int samples;

  /// Stops to add to every reading so the meter agrees with the reference.
  final double? offset;

  /// Median scene EV₁₀₀ the meter produced before calibration.
  final double? measuredEv100;

  /// Half the spread between the 10th and 90th percentile, in stops. A
  /// plain-language "±" for how steady the readings were.
  final double? spread;

  bool get isOk => status == EvCalibrationStatus.ok;
}

/// Collects raw (pre-calibration) scene EV readings from the live video feed
/// and solves the single offset that makes them match a reference meter.
///
/// The meter itself is not touched: this only chooses the constant that the
/// existing calibration offset already adds to every reading. Using the median
/// of many settled frames, rather than one frame, keeps sensor noise and a
/// single odd frame from becoming a permanent error.
class EvCalibrationRun {
  /// Frames wanted before the run stops collecting.
  static const int targetSamples = 40;

  /// Fewest frames a result is allowed to be based on.
  static const int minSamples = 15;

  /// Largest [EvCalibrationResult.spread] that still counts as steady.
  static const double maxSpreadStops = 0.20;

  final List<double> _samples = [];

  int get count => _samples.length;

  bool get isFull => _samples.length >= targetSamples;

  /// Adds one raw scene EV₁₀₀ reading. Non-finite values are ignored.
  void add(double rawSceneEv100) {
    if (!rawSceneEv100.isFinite || isFull) return;
    _samples.add(rawSceneEv100);
  }

  void clear() => _samples.clear();

  /// Solves the offset for a reference scene EV₁₀₀.
  EvCalibrationResult solve(double referenceEv100) {
    if (!referenceEv100.isFinite || _samples.length < minSamples) {
      return EvCalibrationResult(
        status: EvCalibrationStatus.tooFewSamples,
        samples: _samples.length,
      );
    }

    final sorted = [..._samples]..sort();
    final median = _percentile(sorted, 0.5);
    final spread = (_percentile(sorted, 0.9) - _percentile(sorted, 0.1)) / 2;

    if (spread > maxSpreadStops) {
      return EvCalibrationResult(
        status: EvCalibrationStatus.unstable,
        samples: sorted.length,
        measuredEv100: median,
        spread: spread,
      );
    }

    final offset = referenceEv100 - median;
    if (offset.abs() > CalibrationStore.maxOffset) {
      return EvCalibrationResult(
        status: EvCalibrationStatus.outOfRange,
        samples: sorted.length,
        offset: offset,
        measuredEv100: median,
        spread: spread,
      );
    }

    return EvCalibrationResult(
      status: EvCalibrationStatus.ok,
      samples: sorted.length,
      offset: double.parse(offset.toStringAsFixed(2)),
      measuredEv100: median,
      spread: spread,
    );
  }

  /// Linear-interpolated percentile of an already sorted list.
  static double _percentile(List<double> sorted, double fraction) {
    if (sorted.length == 1) return sorted.first;
    final position = (sorted.length - 1) * fraction;
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];
    final weight = position - lower;
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight;
  }
}
