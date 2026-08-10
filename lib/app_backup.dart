import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'calibration.dart';
import 'film_stock.dart';
import 'flash_prefs.dart';
import 'gear.dart';

/// Export / import / durable mirror for films + gear so reinstalls don't wipe you.
///
/// App-private storage is always cleared on uninstall. This writes a JSON mirror
/// under public Downloads when possible.
class AppDataBackup {
  AppDataBackup._();

  static const int formatVersion = 1;
  static const String mirrorFileName = 'aperture_diary_backup.json';

  static bool _restoring = false;

  /// Human-readable path shown after a successful export (best mirror hit).
  static String? lastMirrorPath;

  static Future<Map<String, dynamic>> collect() async {
    final films = await FilmStockStore.loadSelected();
    final cameras = await GearStore.loadCameras();
    final lenses = await GearStore.loadLenses();
    final backs = await GearStore.loadBacks();
    final mounts = await GearStore.loadMountHistoryStored();
    final brands = await GearStore.loadBrandHistoryStored();
    final calibration = await CalibrationStore.load();
    final guideNumber = await FlashPrefsStore.loadGuideNumber();
    return {
      'formatVersion': formatVersion,
      'savedAt': DateTime.now().toIso8601String(),
      'films': films.map((f) => f.toJson()).toList(),
      'cameras': cameras.map((c) => c.toJson()).toList(),
      'lenses': lenses.map((l) => l.toJson()).toList(),
      'backs': backs.map((b) => b.toJson()).toList(),
      'mounts': mounts,
      'brands': brands,
      'calibration': {'evOffset': calibration},
      'flash': {'guideNumberIso100': guideNumber},
    };
  }

  static Future<void> apply(Map<String, dynamic> data) async {
    _restoring = true;
    try {
      final filmsRaw = data['films'];
      if (filmsRaw is List) {
        final films = <FilmStock>[];
        for (final item in filmsRaw) {
          final map = _asMap(item);
          if (map == null) continue;
          final film = FilmStock.fromJson(map);
          if (film != null) films.add(film);
        }
        await FilmStockStore.saveSelected(films);
      }

      final camerasRaw = data['cameras'];
      if (camerasRaw is List) {
        final cameras = <UserCamera>[];
        for (final item in camerasRaw) {
          final map = _asMap(item);
          if (map == null) continue;
          final camera = UserCamera.fromJson(map);
          if (camera != null) cameras.add(camera);
        }
        await GearStore.saveCameras(cameras);
      }

      final lensesRaw = data['lenses'];
      if (lensesRaw is List) {
        final lenses = <UserLens>[];
        for (final item in lensesRaw) {
          final map = _asMap(item);
          if (map == null) continue;
          final lens = UserLens.fromJson(map);
          if (lens != null) lenses.add(lens);
        }
        await GearStore.saveLenses(lenses);
      }

      final backsRaw = data['backs'];
      if (backsRaw is List) {
        final backs = <UserBack>[];
        for (final item in backsRaw) {
          final map = _asMap(item);
          if (map == null) continue;
          final back = UserBack.fromJson(map);
          if (back != null) backs.add(back);
        }
        await GearStore.saveBacks(backs);
      }

      final mounts = data['mounts'];
      if (mounts is List) {
        await GearStore.saveMountHistory(
          mounts.whereType<String>().toList(),
        );
      }

      final brands = data['brands'];
      if (brands is List) {
        await GearStore.saveBrandHistory(
          brands.whereType<String>().toList(),
        );
      }

      final calibration = data['calibration'];
      if (calibration is Map && calibration['evOffset'] is num) {
        await CalibrationStore.save(
          (calibration['evOffset'] as num).toDouble(),
        );
      }

      final flash = data['flash'];
      if (flash is Map && flash['guideNumberIso100'] is num) {
        await FlashPrefsStore.saveGuideNumber(
          (flash['guideNumberIso100'] as num).toDouble(),
        );
      }
    } finally {
      _restoring = false;
    }
  }

  /// Best-effort copy outside the app sandbox (survives uninstall on Android).
  static Future<String?> writeMirror() async {
    if (_restoring) return lastMirrorPath;
    lastMirrorPath = null;
    try {
      final json = jsonEncode(await collect());
      final dirs = await _mirrorDirs();
      for (final dir in dirs) {
        try {
          if (!await dir.exists()) await dir.create(recursive: true);
          final file = File(
            '${dir.path}${Platform.pathSeparator}$mirrorFileName',
          );
          await file.writeAsString(json);
          lastMirrorPath ??= file.path;
        } catch (_) {
          // Try the next candidate path.
        }
      }
    } catch (_) {
      // Mirroring must never break normal saves.
    }
    return lastMirrorPath;
  }

  /// If local stores are empty but a mirror exists, restore it.
  static Future<bool> restoreFromMirrorIfEmpty() async {
    try {
      final films = await FilmStockStore.loadSelected();
      final cameras = await GearStore.loadCameras();
      if (films.isNotEmpty || cameras.isNotEmpty) return false;
      return restoreFromMirror();
    } catch (_) {
      return false;
    }
  }

  /// Restore from the newest readable mirror (Downloads / app docs).
  static Future<bool> restoreFromMirror() async {
    try {
      File? newest;
      DateTime? newestTime;
      for (final dir in await _mirrorDirs()) {
        final file = File(
          '${dir.path}${Platform.pathSeparator}$mirrorFileName',
        );
        if (!await file.exists()) continue;
        final modified = await file.lastModified();
        if (newest == null || modified.isAfter(newestTime!)) {
          newest = file;
          newestTime = modified;
        }
      }
      if (newest == null) return false;
      final raw = jsonDecode(await newest.readAsString());
      if (raw is! Map) return false;
      await apply(Map<String, dynamic>.from(raw));
      await writeMirror();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Explicit export — same as mirror write; returns the path written.
  static Future<String?> exportBackup() => writeMirror();

  static Future<List<Directory>> _mirrorDirs() async {
    final out = <Directory>[];
    if (Platform.isAndroid) {
      out.add(Directory('/storage/emulated/0/Download/ApertureDiary'));
      out.add(Directory('/sdcard/Download/ApertureDiary'));
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          out.add(Directory('${ext.path}${Platform.pathSeparator}backup'));
        }
      } catch (_) {}
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      out.add(Directory('${docs.path}${Platform.pathSeparator}backup'));
    } catch (_) {}
    return out;
  }

  static Map<String, dynamic>? _asMap(Object? item) {
    if (item is Map<String, dynamic>) return item;
    if (item is Map) return Map<String, dynamic>.from(item);
    return null;
  }
}
