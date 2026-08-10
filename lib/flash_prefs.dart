import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Remembers the user's flash guide number (ISO 100, metres) across launches.
class FlashPrefsStore {
  static const String _fileName = 'flash_prefs.json';
  static const double defaultGuideNumber = 36.0;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<double> loadGuideNumber() async {
    try {
      final file = await _file();
      if (!await file.exists()) return defaultGuideNumber;
      final data = jsonDecode(await file.readAsString());
      if (data is Map && data['guideNumberIso100'] is num) {
        final value = (data['guideNumberIso100'] as num).toDouble();
        if (value.isFinite && value >= 1 && value <= 300) return value;
      }
    } catch (_) {
      // Prefs are a convenience; ignore corrupt reads.
    }
    return defaultGuideNumber;
  }

  static Future<void> saveGuideNumber(double guideNumberIso100) async {
    if (!guideNumberIso100.isFinite ||
        guideNumberIso100 < 1 ||
        guideNumberIso100 > 300) {
      return;
    }
    try {
      final file = await _file();
      Map<String, dynamic> data = {};
      if (await file.exists()) {
        final existing = jsonDecode(await file.readAsString());
        if (existing is Map) {
          data = Map<String, dynamic>.from(existing);
        }
      }
      data['guideNumberIso100'] = guideNumberIso100;
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // Ignore write failures.
    }
  }
}
