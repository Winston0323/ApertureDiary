import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A captured frame kept in the in-app album timeline.
class AlbumShot {
  const AlbumShot({
    required this.id,
    required this.imagePath,
    required this.takenAt,
    required this.shutter,
    required this.aperture,
    required this.iso,
    required this.filmName,
    this.filmId,
    this.formatLabel,
    this.focalMm,
    this.ev,
    this.flash = false,
    this.scanImagePath,
  });

  final String id;
  final String imagePath;
  final DateTime takenAt;
  final String shutter;
  final String aperture;
  final int iso;
  final String filmName;

  /// Home-timeline roll id this frame was shot with, if known.
  final String? filmId;
  final String? formatLabel;
  final double? focalMm;
  final double? ev;
  final bool flash;

  /// Optional developed/scanned JPEG paired with this meter capture.
  final String? scanImagePath;

  bool get hasScan {
    final path = scanImagePath;
    return path != null && path.isNotEmpty;
  }

  AlbumShot copyWith({
    String? id,
    String? imagePath,
    DateTime? takenAt,
    String? shutter,
    String? aperture,
    int? iso,
    String? filmName,
    String? filmId,
    String? formatLabel,
    double? focalMm,
    double? ev,
    bool? flash,
    String? scanImagePath,
    bool clearScan = false,
  }) {
    return AlbumShot(
      id: id ?? this.id,
      imagePath: imagePath ?? this.imagePath,
      takenAt: takenAt ?? this.takenAt,
      shutter: shutter ?? this.shutter,
      aperture: aperture ?? this.aperture,
      iso: iso ?? this.iso,
      filmName: filmName ?? this.filmName,
      filmId: filmId ?? this.filmId,
      formatLabel: formatLabel ?? this.formatLabel,
      focalMm: focalMm ?? this.focalMm,
      ev: ev ?? this.ev,
      flash: flash ?? this.flash,
      scanImagePath:
          clearScan ? null : (scanImagePath ?? this.scanImagePath),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'imagePath': imagePath,
        'takenAt': takenAt.toIso8601String(),
        'shutter': shutter,
        'aperture': aperture,
        'iso': iso,
        'filmName': filmName,
        'filmId': filmId,
        'formatLabel': formatLabel,
        'focalMm': focalMm,
        'ev': ev,
        'flash': flash,
        'scanImagePath': scanImagePath,
      };

  static AlbumShot? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final imagePath = json['imagePath'];
    final takenRaw = json['takenAt'];
    final shutter = json['shutter'];
    final aperture = json['aperture'];
    final iso = json['iso'];
    final filmName = json['filmName'];
    if (id is! String ||
        imagePath is! String ||
        takenRaw is! String ||
        shutter is! String ||
        aperture is! String ||
        iso is! int ||
        filmName is! String) {
      return null;
    }
    final takenAt = DateTime.tryParse(takenRaw);
    if (takenAt == null) return null;

    final scanRaw = json['scanImagePath'];
    final scanPath = scanRaw is String && scanRaw.isNotEmpty ? scanRaw : null;

    return AlbumShot(
      id: id,
      imagePath: imagePath,
      takenAt: takenAt,
      shutter: shutter,
      aperture: aperture,
      iso: iso,
      filmName: filmName,
      filmId: json['filmId'] is String ? json['filmId'] as String : null,
      formatLabel: json['formatLabel'] is String
          ? json['formatLabel'] as String
          : null,
      focalMm: (json['focalMm'] as num?)?.toDouble(),
      ev: (json['ev'] as num?)?.toDouble(),
      flash: json['flash'] == true,
      scanImagePath: scanPath,
    );
  }
}

/// Persists album shots (JPEG files + metadata) across launches.
class AlbumShotStore {
  static const String _metaFileName = 'album.json';
  static const String _dirName = 'album';

  /// Bumped after add / update / remove so open album pages can reload.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Background saves still in progress (meter → album).
  static final ValueNotifier<int> pendingSaves = ValueNotifier<int>(0);

  static void _notifyChanged() {
    revision.value++;
  }

  static void beginBackgroundSave() {
    pendingSaves.value++;
  }

  static void endBackgroundSave() {
    if (pendingSaves.value > 0) {
      pendingSaves.value--;
    }
  }

  static Future<Directory> _albumDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}${Platform.pathSeparator}$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _metaFile() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_metaFileName');
  }

  static String _scanPathForId(Directory dir, String shotId) =>
      '${dir.path}${Platform.pathSeparator}$shotId-scan.jpg';

  static Future<void> _deleteFileQuietly(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort.
    }
  }

  static Future<List<AlbumShot>> load() async {
    try {
      final file = await _metaFile();
      if (!await file.exists()) return [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return [];
      final shots = <AlbumShot>[];
      for (final item in data) {
        final Map<String, dynamic>? map = item is Map<String, dynamic>
            ? item
            : item is Map
                ? Map<String, dynamic>.from(item)
                : null;
        if (map == null) continue;
        var shot = AlbumShot.fromJson(map);
        if (shot == null) continue;
        if (!await File(shot.imagePath).exists()) continue;
        final scan = shot.scanImagePath;
        if (scan != null && !await File(scan).exists()) {
          shot = shot.copyWith(clearScan: true);
        }
        shots.add(shot);
      }
      shots.sort((a, b) => b.takenAt.compareTo(a.takenAt));
      return shots;
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveAll(List<AlbumShot> shots) async {
    final ordered = [...shots]..sort((a, b) => b.takenAt.compareTo(a.takenAt));
    final file = await _metaFile();
    await file.writeAsString(
      jsonEncode(ordered.map((s) => s.toJson()).toList()),
    );
  }

  /// Writes [jpegBytes] to disk and appends a new timeline entry.
  static Future<AlbumShot> add({
    required Uint8List jpegBytes,
    required String shutter,
    required String aperture,
    required int iso,
    required String filmName,
    String? filmId,
    String? formatLabel,
    double? focalMm,
    double? ev,
    bool flash = false,
    DateTime? takenAt,
  }) async {
    final id = 'shot-${DateTime.now().microsecondsSinceEpoch}';
    final when = takenAt ?? DateTime.now();
    final dir = await _albumDir();
    final path = '${dir.path}${Platform.pathSeparator}$id.jpg';
    await File(path).writeAsBytes(jpegBytes, flush: true);

    final shot = AlbumShot(
      id: id,
      imagePath: path,
      takenAt: when,
      shutter: shutter,
      aperture: aperture,
      iso: iso,
      filmName: filmName,
      filmId: filmId,
      formatLabel: formatLabel,
      focalMm: focalMm,
      ev: ev,
      flash: flash,
    );

    final shots = List<AlbumShot>.from(await load());
    shots.insert(0, shot);
    await _saveAll(shots);
    _notifyChanged();
    return shot;
  }

  static Future<void> update(AlbumShot shot) async {
    final shots = await load();
    final next = [
      for (final s in shots) s.id == shot.id ? shot : s,
    ];
    await _saveAll(next);
    _notifyChanged();
  }

  /// Writes a developed/scanned JPEG for [shotId], replacing any previous scan.
  static Future<AlbumShot?> setScan({
    required String shotId,
    required Uint8List jpegBytes,
  }) async {
    final shots = await load();
    final index = shots.indexWhere((s) => s.id == shotId);
    if (index < 0) return null;

    final existing = shots[index];
    final dir = await _albumDir();
    final path = _scanPathForId(dir, shotId);
    await _deleteFileQuietly(existing.scanImagePath);
    await File(path).writeAsBytes(jpegBytes, flush: true);

    final updated = existing.copyWith(scanImagePath: path);
    shots[index] = updated;
    await _saveAll(shots);
    _notifyChanged();
    return updated;
  }

  /// Removes the scan image for [shotId], if any.
  static Future<AlbumShot?> clearScan(String shotId) async {
    final shots = await load();
    final index = shots.indexWhere((s) => s.id == shotId);
    if (index < 0) return null;

    final existing = shots[index];
    await _deleteFileQuietly(existing.scanImagePath);
    final updated = existing.copyWith(clearScan: true);
    shots[index] = updated;
    await _saveAll(shots);
    _notifyChanged();
    return updated;
  }

  static Future<void> remove(AlbumShot shot) async {
    final shots = await load();
    shots.removeWhere((s) => s.id == shot.id);
    await _saveAll(shots);
    await _deleteFileQuietly(shot.imagePath);
    await _deleteFileQuietly(shot.scanImagePath);
    _notifyChanged();
  }
}
