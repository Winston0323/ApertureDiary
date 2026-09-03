import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'album_shot.dart';
import 'calibration.dart';
import 'film_stock.dart';
import 'flash_prefs.dart';
import 'gear.dart';

/// Export / import / durable mirror for films + gear + album images.
///
/// App-private storage is always cleared on uninstall / signature-mismatch
/// reinstall (`flutter run` does this). Mirrors live under public Downloads as
/// a ZIP (`backup.json` + `album/*.jpg`). Legacy JSON-only mirrors still
/// restore metadata but cannot recover missing JPEGs.
class AppDataBackup {
  AppDataBackup._();

  static const int formatVersion = 3;
  static const String mirrorFileName = 'aperture_diary_backup.zip';
  static const String legacyMirrorFileName = 'aperture_diary_backup.json';
  static const String _jsonEntryName = 'backup.json';

  static bool _restoring = false;

  /// Human-readable path shown after a successful export (best mirror hit).
  static String? lastMirrorPath;

  /// Last restore error for UI (empty when ok).
  static String? lastError;

  static Future<Map<String, dynamic>> collect() async {
    final films = await FilmStockStore.loadSelected();
    final cameras = await GearStore.loadCameras();
    final lenses = await GearStore.loadLenses();
    final backs = await GearStore.loadBacks();
    final mounts = await GearStore.loadMountHistoryStored();
    final brands = await GearStore.loadBrandHistoryStored();
    final calibration = await CalibrationStore.load();
    final guideNumber = await FlashPrefsStore.loadGuideNumber();
    final album = await AlbumShotStore.loadAllMeta();
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
      'album': album.map((s) => s.toJson()).toList(),
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

      final albumRaw = data['album'];
      if (albumRaw is List) {
        final shots = <AlbumShot>[];
        for (final item in albumRaw) {
          final map = _asMap(item);
          if (map == null) continue;
          // iso may be num in older dumps
          if (map['iso'] is num) map['iso'] = (map['iso'] as num).toInt();
          final shot = AlbumShot.fromJson(map);
          if (shot != null) shots.add(shot);
        }
        await AlbumShotStore.restoreMeta(shots);
      }
    } finally {
      _restoring = false;
    }
  }

  /// Ask Android for all-files access so Downloads mirrors stay readable
  /// after uninstall / reinstall.
  static Future<bool> ensureStorageAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      var status = await Permission.manageExternalStorage.status;
      if (status.isGranted) return true;
      status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;
      // Fall back to legacy read/write where still applicable.
      final storage = await Permission.storage.request();
      return storage.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort copy outside the app sandbox (survives uninstall on Android).
  static Future<String?> writeMirror() async {
    if (_restoring) return lastMirrorPath;
    lastMirrorPath = null;
    lastError = null;
    try {
      final films = await FilmStockStore.loadSelected();
      final cameras = await GearStore.loadCameras();
      // Never clobber a real Downloads backup with an empty post-wipe state.
      if (films.isEmpty && cameras.isEmpty) {
        final existing = await _newestMirrorFile();
        if (existing != null && await _mirrorHasData(existing)) {
          lastMirrorPath = existing.path;
          return lastMirrorPath;
        }
      }

      await ensureStorageAccess();
      final zipBytes = await _buildZipBytes();
      final dirs = await _mirrorDirs();
      for (final dir in dirs) {
        try {
          if (!await dir.exists()) await dir.create(recursive: true);
          final file = File(
            '${dir.path}${Platform.pathSeparator}$mirrorFileName',
          );
          await file.writeAsBytes(zipBytes, flush: true);
          lastMirrorPath ??= file.path;
        } catch (_) {
          // Try the next candidate path.
        }
      }
      if (lastMirrorPath == null) {
        lastError = 'Could not write Downloads/ApertureDiary backup';
      }
    } catch (e) {
      lastError = '$e';
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
    lastError = null;
    try {
      await ensureStorageAccess();
      final newest = await _newestMirrorFile();
      if (newest == null) {
        lastError =
            'No backup found. Expected Downloads/ApertureDiary/'
            '$mirrorFileName (grant “All files access” if prompted).';
        return false;
      }
      final ok = await _restoreFromFile(newest);
      if (!ok) return false;
      await writeMirror();
      lastMirrorPath = newest.path;
      return true;
    } catch (e) {
      lastError = '$e';
      return false;
    }
  }

  /// Explicit export — same as mirror write; returns the path written.
  static Future<String?> exportBackup() => writeMirror();

  static Future<Uint8List> _buildZipBytes() async {
    final data = await collect();
    final archive = Archive();
    final jsonBytes = utf8.encode(jsonEncode(data));
    archive.addFile(ArchiveFile.bytes(_jsonEntryName, jsonBytes));

    final albumRaw = data['album'];
    if (albumRaw is List) {
      final added = <String>{};
      for (final item in albumRaw) {
        final map = _asMap(item);
        if (map == null) continue;
        await _addAlbumFile(archive, map['imagePath'], added);
        await _addAlbumFile(archive, map['scanImagePath'], added);
      }
    }

    return ZipEncoder().encodeBytes(archive);
  }

  static Future<void> _addAlbumFile(
    Archive archive,
    Object? pathObj,
    Set<String> added,
  ) async {
    if (pathObj is! String || pathObj.isEmpty) return;
    final name = pathObj.replaceAll('\\', '/').split('/').last;
    if (name.isEmpty || added.contains(name)) return;
    final file = File(pathObj);
    if (!await file.exists()) return;
    try {
      final bytes = await file.readAsBytes();
      added.add(name);
      archive.addFile(
        ArchiveFile.noCompress('album/$name', bytes.length, bytes),
      );
    } catch (_) {}
  }

  static Future<bool> _restoreFromFile(File file) async {
    final lower = file.path.toLowerCase();
    if (lower.endsWith('.zip')) {
      return _restoreFromZip(file);
    }
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) {
      lastError = 'Backup file is not valid JSON';
      return false;
    }
    await apply(Map<String, dynamic>.from(raw));
    return true;
  }

  static Future<bool> _restoreFromZip(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Extract album images before rewriting meta paths.
    final albumDir = await AlbumShotStore.albumDirectory();
    if (!await albumDir.exists()) {
      await albumDir.create(recursive: true);
    }
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (!name.startsWith('album/') && !name.contains('/album/')) continue;
      final base = name.split('/').last;
      if (base.isEmpty || !base.toLowerCase().endsWith('.jpg')) continue;
      final out = File('${albumDir.path}${Platform.pathSeparator}$base');
      final data = entry.content;
      if (data.isEmpty) continue;
      await out.writeAsBytes(data, flush: true);
    }

    Map<String, dynamic>? payload;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/').split('/').last;
      if (name != _jsonEntryName && name != legacyMirrorFileName) continue;
      final data = entry.content;
      if (data.isEmpty) continue;
      final raw = jsonDecode(utf8.decode(data));
      if (raw is Map) {
        payload = Map<String, dynamic>.from(raw);
        break;
      }
    }

    // Older zip layouts: only album/ + a root json with another name.
    if (payload == null) {
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final name = entry.name.replaceAll('\\', '/').split('/').last;
        if (!name.endsWith('.json')) continue;
        final data = entry.content;
        if (data.isEmpty) continue;
        try {
          final raw = jsonDecode(utf8.decode(data));
          if (raw is Map &&
              (raw.containsKey('films') || raw.containsKey('album'))) {
            payload = Map<String, dynamic>.from(raw);
            break;
          }
        } catch (_) {}
      }
    }

    if (payload == null) {
      // Image-only zip (very old): keep extracted JPEGs, no meta apply.
      lastError = null;
      return true;
    }
    await apply(payload);
    return true;
  }

  static Future<bool> _mirrorHasData(File file) async {
    try {
      final lower = file.path.toLowerCase();
      if (lower.endsWith('.zip')) {
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        for (final entry in archive) {
          if (!entry.isFile) continue;
          final name = entry.name.replaceAll('\\', '/').split('/').last;
          if (!name.endsWith('.json')) continue;
          final data = entry.content;
          if (data.isEmpty) continue;
          final raw = jsonDecode(utf8.decode(data));
          if (raw is! Map) continue;
          return _payloadHasData(Map<String, dynamic>.from(raw));
        }
        // Zip with only album images still counts as real data.
        return archive.any(
          (e) =>
              e.isFile &&
              e.name.replaceAll('\\', '/').toLowerCase().contains('album/') &&
              e.name.toLowerCase().endsWith('.jpg'),
        );
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return false;
      return _payloadHasData(Map<String, dynamic>.from(raw));
    } catch (_) {
      return false;
    }
  }

  static bool _payloadHasData(Map<String, dynamic> raw) {
    final ef = raw['films'];
    final ec = raw['cameras'];
    final ea = raw['album'];
    return (ef is List && ef.isNotEmpty) ||
        (ec is List && ec.isNotEmpty) ||
        (ea is List && ea.isNotEmpty);
  }

  static Future<File?> _newestMirrorFile() async {
    File? newest;
    DateTime? newestTime;
    var newestIsZip = false;
    for (final file in await _candidateMirrorFiles()) {
      try {
        if (!await file.exists()) continue;
        final modified = await file.lastModified();
        final isZip = file.path.toLowerCase().endsWith('.zip');
        if (newest == null) {
          newest = file;
          newestTime = modified;
          newestIsZip = isZip;
          continue;
        }
        // Prefer ZIP over JSON when timestamps are close (JSON may be newer
        // after a metadata-only write, but ZIP is the full backup).
        if (isZip && !newestIsZip) {
          newest = file;
          newestTime = modified;
          newestIsZip = true;
          continue;
        }
        if (!isZip && newestIsZip) {
          // Keep the zip unless this JSON is clearly newer by > 1 day
          // (user might have only a fresh JSON). Prefer zip still if same day.
          if (modified.difference(newestTime!).inHours > 24) {
            newest = file;
            newestTime = modified;
            newestIsZip = false;
          }
          continue;
        }
        if (modified.isAfter(newestTime!)) {
          newest = file;
          newestTime = modified;
          newestIsZip = isZip;
        }
      } catch (_) {}
    }
    return newest;
  }

  static Future<List<File>> _candidateMirrorFiles() async {
    final out = <File>[];
    for (final dir in await _mirrorDirs()) {
      try {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.isEmpty
              ? entity.path
              : entity.uri.pathSegments.last;
          final lower = name.toLowerCase();
          if (lower == mirrorFileName ||
              lower == legacyMirrorFileName ||
              (lower.startsWith('aperture_diary_backup') &&
                  (lower.endsWith('.json') || lower.endsWith('.zip')))) {
            out.add(entity);
          }
        }
      } catch (_) {}
      // Also try the exact primary names even if list() is blocked.
      out.add(File('${dir.path}${Platform.pathSeparator}$mirrorFileName'));
      out.add(
        File('${dir.path}${Platform.pathSeparator}$legacyMirrorFileName'),
      );
    }
    // Extra well-known absolute paths (Android).
    if (Platform.isAndroid) {
      for (final base in [
        '/storage/emulated/0/Download/ApertureDiary',
        '/sdcard/Download/ApertureDiary',
        '/storage/emulated/0/ApertureDiary/data',
      ]) {
        out.add(File('$base/$mirrorFileName'));
        out.add(File('$base/$legacyMirrorFileName'));
      }
    }
    return out;
  }

  static Future<List<Directory>> _mirrorDirs() async {
    final out = <Directory>[];
    if (Platform.isAndroid) {
      out.add(Directory('/storage/emulated/0/Download/ApertureDiary'));
      out.add(Directory('/sdcard/Download/ApertureDiary'));
      out.add(Directory('/storage/emulated/0/ApertureDiary/data'));
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
