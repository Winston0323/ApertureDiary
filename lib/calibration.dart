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
