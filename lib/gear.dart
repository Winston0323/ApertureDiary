import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_backup.dart';
import 'film_format.dart';
import 'film_stock.dart';

/// Case-insensitive mount equality. Empty mounts never match.
bool sameLensMount(String? a, String? b) {
  final left = a?.trim().toLowerCase();
  final right = b?.trim().toLowerCase();
  if (left == null || left.isEmpty || right == null || right.isEmpty) {
    return false;
  }
  return left == right;
}

String formatGearAperture(double n) =>
    n < 10 ? 'f/${n.toStringAsFixed(1)}' : 'f/${n.round()}';

/// e.g. `f/2.8`, `f/22`, or `f/2.8–22` when both ends are set.
String? formatGearApertureRange(double? maxAperture, double? minAperture) {
  if (maxAperture != null && minAperture != null) {
    final maxLabel = maxAperture < 10
        ? maxAperture.toStringAsFixed(1)
        : '${maxAperture.round()}';
    final minLabel = minAperture < 10
        ? minAperture.toStringAsFixed(1)
        : '${minAperture.round()}';
    return 'f/$maxLabel–$minLabel';
  }
  if (maxAperture != null) return formatGearAperture(maxAperture);
  if (minAperture != null) return formatGearAperture(minAperture);
  return null;
}

/// Built-in camera / lens brands (custom brands are stored via [GearStore]).
const List<String> kPresetCameraBrands = [
  'Hasselblad',
  'Leica',
  'Nikon',
  'Canon',
  'Fujifilm',
  'Pentax',
  'Rollei',
  'Mamiya',
  'Contax',
  'Other',
];

/// Normalizes a stored brand label (tolerates old enum names).
String normalizeCameraBrand(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return 'Other';
  for (final preset in kPresetCameraBrands) {
    if (preset.toLowerCase() == value.toLowerCase()) return preset;
  }
  // Legacy enum `.name` values from early builds.
  const legacy = {
    'hasselblad': 'Hasselblad',
    'leica': 'Leica',
    'nikon': 'Nikon',
    'canon': 'Canon',
    'fuji': 'Fujifilm',
    'pentax': 'Pentax',
    'rollei': 'Rollei',
    'mamiya': 'Mamiya',
    'contax': 'Contax',
    'other': 'Other',
  };
  return legacy[value.toLowerCase()] ?? value;
}

/// A user-owned film camera body.
@immutable
class UserCamera {
  const UserCamera({
    required this.id,
    required this.brand,
    required this.name,
    required this.interchangeableLenses,
    required this.format,
    this.changeableBack = false,
    this.mount,
    this.fixedFocalMm,
    this.fixedMaxAperture,
    this.fixedMinAperture,
    this.fastestShutter = 1 / 500,
    this.slowestShutter = 1.0,
    this.hasBulb = true,
    this.notes,
    this.addedAt,
  });

  final String id;
  final String brand;
  final String name;

  /// When false, the body has a fixed lens ([fixedFocalMm] / apertures).
  final bool interchangeableLenses;

  /// When true, frame size comes from interchangeable [UserBack]s (e.g. 645 + 6×6).
  final bool changeableBack;

  /// Frame / film gate format of this body.
  ///
  /// When [changeableBack] is true this is a film-type hint only (usually 120);
  /// actual frame sizes live on backs.
  final FilmFormat format;

  /// Lens mount when [interchangeableLenses] is true (e.g. `V`, `F`, `M`).
  final String? mount;

  final double? fixedFocalMm;

  /// Widest aperture (smallest f-number), e.g. 2.8.
  final double? fixedMaxAperture;

  /// Smallest aperture (largest f-number), e.g. 22.
  final double? fixedMinAperture;

  /// Fastest timed shutter (smallest seconds), e.g. `1/500`.
  final double fastestShutter;

  /// Slowest timed shutter (largest seconds), e.g. `1`.
  final double slowestShutter;

  /// Body offers bulb (B). Defaults to true for mechanical cameras.
  final bool hasBulb;

  final String? notes;
  final DateTime? addedAt;

  FilmType get filmType {
    if (format == FilmFormat.thirtyFive) return FilmType.thirtyFive;
    if (format.isInstax) return FilmType.instax;
    return FilmType.oneTwenty;
  }

  String get formatLabel {
    if (filmType == FilmType.thirtyFive) return '135';
    if (filmType == FilmType.instax) return 'Instax ${format.label}';
    if (changeableBack) return '120 · Changeable back';
    return '120 ${format.label}';
  }

  String get summary {
    final parts = <String>[formatLabel];
    if (interchangeableLenses) {
      final m = mount?.trim();
      parts.add(m == null || m.isEmpty ? 'Interchangeable' : 'Mount $m');
    } else {
      if (fixedFocalMm != null) {
        parts.add('${fixedFocalMm!.round()} mm');
      }
      final aperture =
          formatGearApertureRange(fixedMaxAperture, fixedMinAperture);
      if (aperture != null) parts.add(aperture);
      if (parts.length == 1) parts.add('Fixed lens');
    }
    return parts.join('  ·  ');
  }

  UserCamera copyWith({
    String? id,
    String? brand,
    String? name,
    bool? interchangeableLenses,
    bool? changeableBack,
    FilmFormat? format,
    String? mount,
    double? fixedFocalMm,
    double? fixedMaxAperture,
    double? fixedMinAperture,
    double? fastestShutter,
    double? slowestShutter,
    bool? hasBulb,
    String? notes,
    DateTime? addedAt,
    bool clearMount = false,
    bool clearFixedFocal = false,
    bool clearFixedAperture = false,
    bool clearFixedMinAperture = false,
    bool clearNotes = false,
  }) {
    return UserCamera(
      id: id ?? this.id,
      brand: brand ?? this.brand,
      name: name ?? this.name,
      interchangeableLenses:
          interchangeableLenses ?? this.interchangeableLenses,
      changeableBack: changeableBack ?? this.changeableBack,
      format: format ?? this.format,
      mount: clearMount ? null : (mount ?? this.mount),
      fixedFocalMm:
          clearFixedFocal ? null : (fixedFocalMm ?? this.fixedFocalMm),
      fixedMaxAperture: clearFixedAperture
          ? null
          : (fixedMaxAperture ?? this.fixedMaxAperture),
      fixedMinAperture: clearFixedMinAperture
          ? null
          : (fixedMinAperture ?? this.fixedMinAperture),
      fastestShutter: fastestShutter ?? this.fastestShutter,
      slowestShutter: slowestShutter ?? this.slowestShutter,
      hasBulb: hasBulb ?? this.hasBulb,
      notes: clearNotes ? null : (notes ?? this.notes),
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'brand': brand,
        'name': name,
        'interchangeableLenses': interchangeableLenses,
        'changeableBack': changeableBack,
        'formatId': format.id,
        'mount': mount,
        'fixedFocalMm': fixedFocalMm,
        'fixedMaxAperture': fixedMaxAperture,
        'fixedMinAperture': fixedMinAperture,
        'fastestShutter': fastestShutter,
        'slowestShutter': slowestShutter,
        'hasBulb': hasBulb,
        'notes': notes,
        'addedAt': addedAt?.toIso8601String(),
      };

  static UserCamera? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    final interchangeable = json['interchangeableLenses'] == true;
    final changeableBack = json['changeableBack'] == true;
    // Default true when field missing (older saves).
    final hasBulb = json['hasBulb'] != false;
    DateTime? addedAt;
    final rawAdded = json['addedAt'];
    if (rawAdded is String) addedAt = DateTime.tryParse(rawAdded);

    double? asDouble(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    final format = FilmFormat.byId(json['formatId'] as String?) ??
        FilmFormat.thirtyFive;

    return UserCamera(
      id: id,
      brand: normalizeCameraBrand(json['brand'] as String?),
      name: name,
      interchangeableLenses: interchangeable,
      changeableBack: changeableBack,
      format: format,
      mount: json['mount'] is String ? json['mount'] as String : null,
      fixedFocalMm: asDouble(json['fixedFocalMm']),
      fixedMaxAperture: asDouble(json['fixedMaxAperture']),
      fixedMinAperture: asDouble(json['fixedMinAperture']),
      fastestShutter: asDouble(json['fastestShutter']) ?? 1 / 500,
      slowestShutter: asDouble(json['slowestShutter']) ?? 1.0,
      hasBulb: hasBulb,
      notes: json['notes'] is String ? json['notes'] as String : null,
      addedAt: addedAt,
    );
  }
}

/// An interchangeable film back (e.g. Hasselblad A12 / A16).
@immutable
class UserBack {
  const UserBack({
    required this.id,
    required this.brand,
    required this.name,
    required this.format,
    this.cameraIds = const [],
    this.notes,
    this.addedAt,
  });

  final String id;
  final String brand;
  final String name;
  final FilmFormat format;
  final List<String> cameraIds;
  final String? notes;
  final DateTime? addedAt;

  String get formatLabel {
    if (format == FilmFormat.thirtyFive) return '135';
    if (format.isInstax) return 'Instax ${format.label}';
    return '120 ${format.label}';
  }

  String get summary => formatLabel;

  UserBack copyWith({
    String? id,
    String? brand,
    String? name,
    FilmFormat? format,
    List<String>? cameraIds,
    String? notes,
    DateTime? addedAt,
    bool clearNotes = false,
  }) {
    return UserBack(
      id: id ?? this.id,
      brand: brand ?? this.brand,
      name: name ?? this.name,
      format: format ?? this.format,
      cameraIds: cameraIds ?? this.cameraIds,
      notes: clearNotes ? null : (notes ?? this.notes),
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'brand': brand,
        'name': name,
        'formatId': format.id,
        'cameraIds': cameraIds,
        'notes': notes,
        'addedAt': addedAt?.toIso8601String(),
      };

  static UserBack? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;

    final format = FilmFormat.byId(json['formatId'] as String?);
    if (format == null) return null;

    DateTime? addedAt;
    final rawAdded = json['addedAt'];
    if (rawAdded is String) addedAt = DateTime.tryParse(rawAdded);

    final ids = <String>[];
    final rawIds = json['cameraIds'];
    if (rawIds is List) {
      for (final item in rawIds) {
        if (item is String && item.isNotEmpty) ids.add(item);
      }
    }

    return UserBack(
      id: id,
      brand: normalizeCameraBrand(json['brand'] as String?),
      name: name,
      format: format,
      cameraIds: ids,
      notes: json['notes'] is String ? json['notes'] as String : null,
      addedAt: addedAt,
    );
  }
}

/// A user-owned lens (for interchangeable bodies, or catalogued optics).
@immutable
class UserLens {
  const UserLens({
    required this.id,
    required this.brand,
    required this.name,
    required this.minFocalMm,
    this.maxFocalMm,
    this.maxAperture,
    this.minAperture,
    this.mount,
    this.cameraIds = const [],
    this.notes,
    this.addedAt,
  });

  final String id;
  final String brand;
  final String name;
  final double minFocalMm;

  /// Null or equal to [minFocalMm] means a prime.
  final double? maxFocalMm;

  /// Widest aperture (smallest f-number), e.g. 2.8.
  final double? maxAperture;

  /// Smallest aperture (largest f-number), e.g. 22.
  final double? minAperture;
  final String? mount;

  /// Optional links to [UserCamera.id] bodies this lens fits.
  final List<String> cameraIds;
  final String? notes;
  final DateTime? addedAt;

  bool get isZoom =>
      maxFocalMm != null && (maxFocalMm! - minFocalMm).abs() > 0.5;

  String get focalLabel {
    if (isZoom) {
      return '${minFocalMm.round()}–${maxFocalMm!.round()} mm';
    }
    return '${minFocalMm.round()} mm';
  }

  String get summary {
    final parts = <String>[focalLabel];
    final aperture = formatGearApertureRange(maxAperture, minAperture);
    if (aperture != null) parts.add(aperture);
    final m = mount?.trim();
    if (m != null && m.isNotEmpty) parts.add(m);
    return parts.join('  ·  ');
  }

  UserLens copyWith({
    String? id,
    String? brand,
    String? name,
    double? minFocalMm,
    double? maxFocalMm,
    double? maxAperture,
    double? minAperture,
    String? mount,
    List<String>? cameraIds,
    String? notes,
    DateTime? addedAt,
    bool clearMaxFocal = false,
    bool clearMaxAperture = false,
    bool clearMinAperture = false,
    bool clearMount = false,
    bool clearNotes = false,
  }) {
    return UserLens(
      id: id ?? this.id,
      brand: brand ?? this.brand,
      name: name ?? this.name,
      minFocalMm: minFocalMm ?? this.minFocalMm,
      maxFocalMm: clearMaxFocal ? null : (maxFocalMm ?? this.maxFocalMm),
      maxAperture:
          clearMaxAperture ? null : (maxAperture ?? this.maxAperture),
      minAperture:
          clearMinAperture ? null : (minAperture ?? this.minAperture),
      mount: clearMount ? null : (mount ?? this.mount),
      cameraIds: cameraIds ?? this.cameraIds,
      notes: clearNotes ? null : (notes ?? this.notes),
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'brand': brand,
        'name': name,
        'minFocalMm': minFocalMm,
        'maxFocalMm': maxFocalMm,
        'maxAperture': maxAperture,
        'minAperture': minAperture,
        'mount': mount,
        'cameraIds': cameraIds,
        'notes': notes,
        'addedAt': addedAt?.toIso8601String(),
      };

  static UserLens? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;

    double? asDouble(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    final minFocal = asDouble(json['minFocalMm']);
    if (minFocal == null || minFocal <= 0) return null;

    DateTime? addedAt;
    final rawAdded = json['addedAt'];
    if (rawAdded is String) addedAt = DateTime.tryParse(rawAdded);

    final ids = <String>[];
    final rawIds = json['cameraIds'];
    if (rawIds is List) {
      for (final item in rawIds) {
        if (item is String && item.isNotEmpty) ids.add(item);
      }
    }

    return UserLens(
      id: id,
      brand: normalizeCameraBrand(json['brand'] as String?),
      name: name,
      minFocalMm: minFocal,
      maxFocalMm: asDouble(json['maxFocalMm']),
      maxAperture: asDouble(json['maxAperture']),
      minAperture: asDouble(json['minAperture']),
      mount: json['mount'] is String ? json['mount'] as String : null,
      cameraIds: ids,
      notes: json['notes'] is String ? json['notes'] as String : null,
      addedAt: addedAt,
    );
  }
}

/// Lenses that fit a body: same mount, or explicitly linked.
List<UserLens> lensesForCamera(UserCamera camera, List<UserLens> lenses) {
  if (!camera.interchangeableLenses) return const [];
  return lenses.where((lens) {
    if (lens.cameraIds.contains(camera.id)) return true;
    return sameLensMount(camera.mount, lens.mount);
  }).toList();
}

/// Bodies a lens can mount on: same mount, or explicitly linked.
List<UserCamera> camerasForLens(UserLens lens, List<UserCamera> cameras) {
  return cameras.where((camera) {
    if (!camera.interchangeableLenses) return false;
    if (lens.cameraIds.contains(camera.id)) return true;
    return sameLensMount(camera.mount, lens.mount);
  }).toList();
}

/// Film backs linked to a changeable-back body.
List<UserBack> backsForCamera(UserCamera camera, List<UserBack> backs) {
  if (!camera.changeableBack) return const [];
  return backs.where((b) => b.cameraIds.contains(camera.id)).toList();
}

/// Bodies a back can attach to (changeable-back cameras, explicitly linked).
List<UserCamera> camerasForBack(UserBack back, List<UserCamera> cameras) {
  return cameras.where((camera) {
    if (!camera.changeableBack) return false;
    return back.cameraIds.contains(camera.id);
  }).toList();
}

/// Persists user cameras and lenses under the app support directory.
class GearStore {
  static const String _camerasFile = 'cameras.json';
  static const String _lensesFile = 'lenses.json';
  static const String _backsFile = 'backs.json';
  static const String _mountsFile = 'lens_mounts.json';
  static const String _brandsFile = 'camera_brands.json';

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _file(String name) async {
    final dir = await _dir();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  static Future<List<UserCamera>> loadCameras() async {
    try {
      final file = await _file(_camerasFile);
      if (!await file.exists()) return const [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return const [];
      final out = <UserCamera>[];
      for (final item in data) {
        final map = item is Map<String, dynamic>
            ? item
            : item is Map
                ? Map<String, dynamic>.from(item)
                : null;
        if (map == null) continue;
        final camera = UserCamera.fromJson(map);
        if (camera != null) out.add(camera);
      }
      out.sort((a, b) {
        final at = a.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<List<UserLens>> loadLenses() async {
    try {
      final file = await _file(_lensesFile);
      if (!await file.exists()) return const [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return const [];
      final out = <UserLens>[];
      for (final item in data) {
        final map = item is Map<String, dynamic>
            ? item
            : item is Map
                ? Map<String, dynamic>.from(item)
                : null;
        if (map == null) continue;
        final lens = UserLens.fromJson(map);
        if (lens != null) out.add(lens);
      }
      out.sort((a, b) {
        final at = a.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveCameras(List<UserCamera> cameras) async {
    try {
      final file = await _file(_camerasFile);
      await file.writeAsString(
        jsonEncode(cameras.map((c) => c.toJson()).toList()),
      );
      revision.value++;
      await AppDataBackup.writeMirror();
    } catch (_) {}
  }

  static Future<void> saveLenses(List<UserLens> lenses) async {
    try {
      final file = await _file(_lensesFile);
      await file.writeAsString(
        jsonEncode(lenses.map((l) => l.toJson()).toList()),
      );
      revision.value++;
      await AppDataBackup.writeMirror();
    } catch (_) {}
  }

  static Future<List<UserBack>> loadBacks() async {
    try {
      final file = await _file(_backsFile);
      if (!await file.exists()) return const [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return const [];
      final out = <UserBack>[];
      for (final item in data) {
        final map = item is Map<String, dynamic>
            ? item
            : item is Map
                ? Map<String, dynamic>.from(item)
                : null;
        if (map == null) continue;
        final back = UserBack.fromJson(map);
        if (back != null) out.add(back);
      }
      out.sort((a, b) {
        final at = a.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveBacks(List<UserBack> backs) async {
    try {
      final file = await _file(_backsFile);
      await file.writeAsString(
        jsonEncode(backs.map((b) => b.toJson()).toList()),
      );
      revision.value++;
      await AppDataBackup.writeMirror();
    } catch (_) {}
  }

  /// Mount names stored on disk only (no gear merge).
  static Future<List<String>> loadMountHistoryStored() async {
    try {
      final file = await _file(_mountsFile);
      if (!await file.exists()) return const [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return const [];
      return data.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveMountHistory(List<String> mounts) async {
    try {
      final file = await _file(_mountsFile);
      await file.writeAsString(jsonEncode(mounts));
    } catch (_) {}
  }

  /// Mount names the user has entered, newest first.
  static Future<List<String>> loadMountHistory() async {
    final seen = <String>{};
    final out = <String>[];

    void add(String? raw) {
      final m = raw?.trim();
      if (m == null || m.isEmpty) return;
      if (seen.add(m)) out.add(m);
    }

    for (final item in await loadMountHistoryStored()) {
      add(item);
    }

    // Fold in mounts already used on gear (keeps history useful after reinstall).
    for (final c in await loadCameras()) {
      add(c.mount);
    }
    for (final l in await loadLenses()) {
      add(l.mount);
    }

    return out;
  }

  static Future<void> rememberMount(String mount) async {
    final trimmed = mount.trim();
    if (trimmed.isEmpty) return;
    final history = [...await loadMountHistory()];
    history.removeWhere((m) => m.toLowerCase() == trimmed.toLowerCase());
    history.insert(0, trimmed);
    await saveMountHistory(history);
  }

  /// Custom brands stored on disk only (no presets / gear merge).
  static Future<List<String>> loadBrandHistoryStored() async {
    try {
      final file = await _file(_brandsFile);
      if (!await file.exists()) return const [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return const [];
      return data
          .whereType<String>()
          .map(normalizeCameraBrand)
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveBrandHistory(List<String> brands) async {
    try {
      final file = await _file(_brandsFile);
      await file.writeAsString(jsonEncode(brands));
    } catch (_) {}
  }

  /// Brand chips: custom history (newest first), then presets not already listed.
  static Future<List<String>> loadBrandOptions() async {
    final seen = <String>{};
    final out = <String>[];

    void add(String? raw) {
      final brand = normalizeCameraBrand(raw);
      final key = brand.toLowerCase();
      if (seen.add(key)) out.add(brand);
    }

    for (final item in await loadBrandHistoryStored()) {
      add(item);
    }

    for (final c in await loadCameras()) {
      add(c.brand);
    }
    for (final l in await loadLenses()) {
      add(l.brand);
    }
    for (final b in await loadBacks()) {
      add(b.brand);
    }
    for (final preset in kPresetCameraBrands) {
      add(preset);
    }

    return out;
  }

  static Future<void> rememberBrand(String brand) async {
    final trimmed = normalizeCameraBrand(brand);
    if (trimmed.isEmpty) return;
    final history = <String>[];
    final seen = <String>{};

    void add(String? raw) {
      final b = normalizeCameraBrand(raw);
      final key = b.toLowerCase();
      if (seen.add(key)) history.add(b);
    }

    add(trimmed);
    for (final item in await loadBrandHistoryStored()) {
      add(item);
    }
    await saveBrandHistory(history);
  }

  static Future<void> upsertCamera(UserCamera camera) async {
    final list = [...await loadCameras()];
    final i = list.indexWhere((c) => c.id == camera.id);
    if (i >= 0) {
      list[i] = camera;
    } else {
      list.insert(0, camera);
    }
    await saveCameras(list);
    await rememberBrand(camera.brand);
    if (camera.mount != null) await rememberMount(camera.mount!);
  }

  static Future<void> upsertLens(UserLens lens) async {
    final list = [...await loadLenses()];
    final i = list.indexWhere((l) => l.id == lens.id);
    if (i >= 0) {
      list[i] = lens;
    } else {
      list.insert(0, lens);
    }
    await saveLenses(list);
    await rememberBrand(lens.brand);
    if (lens.mount != null) await rememberMount(lens.mount!);
  }

  static Future<void> upsertBack(UserBack back) async {
    final list = [...await loadBacks()];
    final i = list.indexWhere((b) => b.id == back.id);
    if (i >= 0) {
      list[i] = back;
    } else {
      list.insert(0, back);
    }
    await saveBacks(list);
    await rememberBrand(back.brand);
  }

  static Future<void> removeCamera(String id) async {
    final cameras = [...await loadCameras()]
      ..removeWhere((c) => c.id == id);
    await saveCameras(cameras);

    // Drop dangling camera links from lenses.
    final lenses = await loadLenses();
    var lensChanged = false;
    final updatedLenses = lenses.map((l) {
      if (!l.cameraIds.contains(id)) return l;
      lensChanged = true;
      return l.copyWith(
        cameraIds: l.cameraIds.where((cid) => cid != id).toList(),
      );
    }).toList();
    if (lensChanged) await saveLenses(updatedLenses);

    final backs = await loadBacks();
    var backChanged = false;
    final updatedBacks = backs.map((b) {
      if (!b.cameraIds.contains(id)) return b;
      backChanged = true;
      return b.copyWith(
        cameraIds: b.cameraIds.where((cid) => cid != id).toList(),
      );
    }).toList();
    if (backChanged) await saveBacks(updatedBacks);
  }

  static Future<void> removeLens(String id) async {
    final lenses = [...await loadLenses()]
      ..removeWhere((l) => l.id == id);
    await saveLenses(lenses);
  }

  static Future<void> removeBack(String id) async {
    final backs = [...await loadBacks()]..removeWhere((b) => b.id == id);
    await saveBacks(backs);
  }
}
