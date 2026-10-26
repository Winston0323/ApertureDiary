import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The frame you are on for one roll. One is the first frame.
class FrameCount {
  static const int min = 1;
  static const int max = 999;

  static int clamp(num value) {
    if (!value.isFinite) return min;
    return value.round().clamp(min, max);
  }

  /// The frame after this one. Stops at [max].
  static int advance(int current) => clamp(current + 1);
}

/// Remembers the frame number for each film roll.
class FrameCounterStore {
  static const String _fileName = 'frame_counts.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<Map<String, int>> _read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return {};
      final counts = <String, int>{};
      for (final entry in data.entries) {
        final value = entry.value;
        if (entry.key.isEmpty || value is! num) continue;
        counts[entry.key] = FrameCount.clamp(value);
      }
      return counts;
    } catch (_) {
      return {};
    }
  }

  /// The saved frame for [filmId], or 1 when this roll has no counter yet.
  static Future<int> load(String filmId) async {
    if (filmId.isEmpty) return FrameCount.min;
    return (await _read())[filmId] ?? FrameCount.min;
  }

  static Future<void> save(String filmId, int count) async {
    if (filmId.isEmpty) return;
    try {
      final counts = await _read();
      counts[filmId] = FrameCount.clamp(count);
      final file = await _file();
      await file.writeAsString(jsonEncode(counts));
    } catch (_) {
      // A missed save only loses the latest frame number.
    }
  }
}
