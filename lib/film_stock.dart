import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:path_provider/path_provider.dart';

import 'app_backup.dart';
import 'film_format.dart';

/// Roll size: 135, 120, or Instax pack film.
enum FilmType {
  thirtyFive('135'),
  oneTwenty('120'),
  instax('Instax');

  const FilmType(this.label);
  final String label;

  static FilmType? fromLabel(String? label) {
    if (label == null) return null;
    for (final t in values) {
      if (t.label == label || t.name == label) return t;
    }
    return null;
  }

  /// Viewfinder formats allowed for this roll size.
  List<FilmFormat> get allowedFormats {
    switch (this) {
      case FilmType.thirtyFive:
        return const [FilmFormat.thirtyFive];
      case FilmType.oneTwenty:
        return const [FilmFormat.sixFourFive, FilmFormat.sixBySix];
      case FilmType.instax:
        return FilmFormat.instaxFormats;
    }
  }

  FilmFormat get defaultFormat {
    switch (this) {
      case FilmType.thirtyFive:
        return FilmFormat.thirtyFive;
      case FilmType.oneTwenty:
        return FilmFormat.sixBySix;
      case FilmType.instax:
        return FilmFormat.instaxMini;
    }
  }
}

/// Colour balance of the emulsion (affects meter EI under daylight).
enum FilmBalance {
  daylight('Daylight'),
  tungsten('Tungsten');

  const FilmBalance(this.label);
  final String label;

  static FilmBalance? fromName(String? name) {
    if (name == null) return null;
    for (final b in values) {
      if (b.name == name || b.label == name) return b;
    }
    return null;
  }

  /// Infer from stock name / key (`500T`, `800T`, …).
  static FilmBalance infer({String? name, String? iconKey}) {
    final hay = '${name ?? ''} ${iconKey ?? ''}'.toLowerCase();
    // Word-boundary style: "500t", "800t", " tungsten", trailing " t ".
    if (RegExp(r'(^|[^a-z])\d{2,4}t([^a-z]|$)').hasMatch(hay) ||
        hay.contains('tungsten') ||
        hay.contains(' tungsten')) {
      return FilmBalance.tungsten;
    }
    return FilmBalance.daylight;
  }
}

/// Process / emulsion family for catalog grouping.
enum FilmCategory {
  colorNegative('Color negative'),
  blackAndWhite('Black & white'),
  colorSlide('Color slide');

  const FilmCategory(this.label);
  final String label;

  static FilmCategory? fromLabel(String? label) {
    if (label == null) return null;
    for (final c in values) {
      if (c.label == label || c.name == label) return c;
    }
    return null;
  }
}

/// Manufacturer / house brand for timeline cues.
enum FilmBrand {
  kodak('Kodak', Color(0xFFFFB300)),
  fujifilm('Fuji', Color(0xFF2E7D32)),
  ilford('Ilford', Color(0xFFB0BEC5)),
  cinestill('CineStill', Color(0xFFE53935)),
  other('Other', Color(0xFF6B6B6B));

  const FilmBrand(this.label, this.color);
  final String label;
  final Color color;

  static FilmBrand? fromLabel(String? label) {
    if (label == null) return null;
    for (final b in values) {
      if (b.label == label || b.name == label) return b;
    }
    return null;
  }

  /// Best-effort brand from a stock name or icon key (legacy rows).
  static FilmBrand infer({String? name, String? iconKey}) {
    final hay = '${name ?? ''} ${iconKey ?? ''}'.toLowerCase();
    if (hay.contains('kodak') ||
        hay.contains('portra') ||
        hay.contains('tri-x') ||
        hay.contains('tmax') ||
        hay.contains('ektar') ||
        hay.contains('ektachrome') ||
        hay.contains('ultramax') ||
        hay.contains('gold-200')) {
      return FilmBrand.kodak;
    }
    if (hay.contains('fuji') ||
        hay.contains('velvia') ||
        hay.contains('provia') ||
        hay.contains('acros') ||
        hay.contains('superia') ||
        hay.contains('neopan') ||
        hay.contains('instax')) {
      return FilmBrand.fujifilm;
    }
    if (hay.contains('ilford') ||
        hay.contains('hp5') ||
        hay.contains('delta') ||
        hay.contains('fp4')) {
      return FilmBrand.ilford;
    }
    if (hay.contains('cinestill') || hay.contains('cine still')) {
      return FilmBrand.cinestill;
    }
    return FilmBrand.other;
  }
}

/// A film stock the user can load into the meter.
class FilmStock {
  FilmStock({
    required this.id,
    required this.name,
    required this.type,
    required this.iso,
    FilmFormat? frameFormat,
    this.brand = FilmBrand.other,
    this.category,
    FilmBalance? balance,
    this.isCustom = false,
    this.iconKey,
    this.addedAt,
    this.cameraId,
    this.cameraLabel,
    this.lensId,
    this.lensLabel,
    this.meterDaylight85 = false,
  })  : frameFormat = normalizeFrameFormat(type, frameFormat),
        balance = balance ??
            FilmBalance.infer(name: name, iconKey: iconKey);

  final String id;
  final String name;
  final FilmType type;

  /// Viewfinder / gate format for this roll (locked for the life of the roll).
  ///
  /// 135 → [FilmFormat.thirtyFive]; 120 → 645 or 6×6.
  final FilmFormat frameFormat;

  final int iso;
  final FilmBrand brand;
  final FilmCategory? category;

  /// Daylight vs tungsten colour balance of the emulsion.
  final FilmBalance balance;

  final bool isCustom;

  /// Asset key under `assets/films/` (without extension), if any.
  final String? iconKey;

  /// When this roll was added to the home timeline.
  final DateTime? addedAt;

  /// [UserCamera.id] this roll is loaded in, if chosen.
  final String? cameraId;

  /// Display snapshot e.g. `Hasselblad 500CM` (kept if the body is deleted).
  final String? cameraLabel;

  /// [UserLens.id] currently mounted for metering, if chosen.
  final String? lensId;

  /// Display snapshot e.g. `Hasselblad Planar 80`.
  final String? lensLabel;

  /// For tungsten stocks: meter at daylight EI with an 85 filter (−⅔ stop).
  final bool meterDaylight85;

  bool get isTungsten => balance == FilmBalance.tungsten;

  String? get iconAsset =>
      iconKey == null ? null : 'assets/films/$iconKey.png';

  /// Timeline / meter badge: `135`, `645` / `6×6`, or Instax `Mini` / `SQ`.
  String get rollFormatLabel {
    if (type == FilmType.thirtyFive) return type.label;
    if (type == FilmType.instax) return 'Instax ${frameFormat.label}';
    return frameFormat.label;
  }

  /// Formats the meter may use for this roll (always a single choice).
  List<FilmFormat> get allowedFormats => [frameFormat];

  /// Coerce [format] to a valid gate for [type].
  static FilmFormat normalizeFrameFormat(FilmType type, FilmFormat? format) {
    switch (type) {
      case FilmType.thirtyFive:
        return FilmFormat.thirtyFive;
      case FilmType.oneTwenty:
        if (format == FilmFormat.sixFourFive || format == FilmFormat.sixBySix) {
          return format!;
        }
        return FilmFormat.sixBySix;
      case FilmType.instax:
        if (format == FilmFormat.instaxMini ||
            format == FilmFormat.instaxSquare) {
          return format!;
        }
        return FilmFormat.instaxMini;
    }
  }

  static bool looksLikeInstax({String? name, String? iconKey}) {
    final hay = '${name ?? ''} ${iconKey ?? ''}'.toLowerCase();
    return hay.contains('instax');
  }

  /// Sort key for the home timeline (newest first). Falls back to the roll id.
  DateTime get timelineAt {
    if (addedAt != null) return addedAt!;
    final match = RegExp(r'roll-(\d+)').firstMatch(id);
    if (match != null) {
      final micros = int.tryParse(match.group(1)!);
      if (micros != null) {
        return DateTime.fromMicrosecondsSinceEpoch(micros);
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  FilmStock copyWith({
    String? id,
    String? name,
    FilmType? type,
    FilmFormat? frameFormat,
    int? iso,
    FilmBrand? brand,
    FilmCategory? category,
    FilmBalance? balance,
    bool? isCustom,
    String? iconKey,
    DateTime? addedAt,
    String? cameraId,
    String? cameraLabel,
    String? lensId,
    String? lensLabel,
    bool? meterDaylight85,
    bool clearCamera = false,
    bool clearLens = false,
  }) {
    final nextType = type ?? this.type;
    return FilmStock(
      id: id ?? this.id,
      name: name ?? this.name,
      type: nextType,
      frameFormat: frameFormat ?? this.frameFormat,
      iso: iso ?? this.iso,
      brand: brand ?? this.brand,
      category: category ?? this.category,
      balance: balance ?? this.balance,
      isCustom: isCustom ?? this.isCustom,
      iconKey: iconKey ?? this.iconKey,
      addedAt: addedAt ?? this.addedAt,
      cameraId: clearCamera ? null : (cameraId ?? this.cameraId),
      cameraLabel: clearCamera ? null : (cameraLabel ?? this.cameraLabel),
      lensId: clearLens ? null : (lensId ?? this.lensId),
      lensLabel: clearLens ? null : (lensLabel ?? this.lensLabel),
      meterDaylight85: meterDaylight85 ?? this.meterDaylight85,
    );
  }

  /// A fresh home-list entry for this stock (unique id per selection).
  FilmStock asNewRoll() {
    final now = DateTime.now();
    return FilmStock(
      id: 'roll-${now.microsecondsSinceEpoch}',
      name: name,
      type: type,
      frameFormat: frameFormat,
      iso: iso,
      brand: brand,
      category: category,
      balance: balance,
      isCustom: isCustom,
      iconKey: iconKey,
      addedAt: now,
      cameraId: cameraId,
      cameraLabel: cameraLabel,
      lensId: lensId,
      lensLabel: lensLabel,
      meterDaylight85: meterDaylight85,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.label,
        'frameFormat': frameFormat.id,
        'iso': iso,
        'brand': brand.name,
        'balance': balance.name,
        'isCustom': isCustom,
        'meterDaylight85': meterDaylight85,
        if (category != null) 'category': category!.name,
        if (iconKey != null) 'iconKey': iconKey,
        if (addedAt != null) 'addedAt': addedAt!.toIso8601String(),
        if (cameraId != null) 'cameraId': cameraId,
        if (cameraLabel != null) 'cameraLabel': cameraLabel,
        if (lensId != null) 'lensId': lensId,
        if (lensLabel != null) 'lensLabel': lensLabel,
      };

  static FilmStock? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    var type = FilmType.fromLabel(json['type'] as String?);
    final iso = json['iso'];
    if (id is! String || name is! String || type == null || iso is! num) {
      return null;
    }
    final iconKey = json['iconKey'] is String ? json['iconKey'] as String : null;
    final addedRaw = json['addedAt'];
    DateTime? addedAt;
    if (addedRaw is String) {
      addedAt = DateTime.tryParse(addedRaw);
    }
    final brand = FilmBrand.fromLabel(json['brand'] as String?) ??
        FilmBrand.infer(name: name, iconKey: iconKey);
    var frameFormat = FilmFormat.byId(json['frameFormat'] as String?);
    // Older Instax rolls were saved as 120 + 645/6×6 — migrate.
    if (looksLikeInstax(name: name, iconKey: iconKey) &&
        type != FilmType.instax) {
      type = FilmType.instax;
      if (frameFormat == null || !frameFormat.isInstax) {
        frameFormat = frameFormat == FilmFormat.sixBySix
            ? FilmFormat.instaxSquare
            : FilmFormat.instaxMini;
      }
    }
    final cameraId =
        json['cameraId'] is String ? json['cameraId'] as String : null;
    final cameraLabel =
        json['cameraLabel'] is String ? json['cameraLabel'] as String : null;
    final lensId = json['lensId'] is String ? json['lensId'] as String : null;
    final lensLabel =
        json['lensLabel'] is String ? json['lensLabel'] as String : null;
    return FilmStock(
      id: id,
      name: name,
      type: type,
      frameFormat: frameFormat,
      iso: iso.toInt(),
      brand: brand,
      category: FilmCategory.fromLabel(json['category'] as String?),
      balance: FilmBalance.fromName(json['balance'] as String?) ??
          FilmBalance.infer(name: name, iconKey: iconKey),
      isCustom: json['isCustom'] == true,
      iconKey: iconKey,
      addedAt: addedAt,
      cameraId: cameraId,
      cameraLabel: cameraLabel,
      lensId: lensId,
      lensLabel: lensLabel,
      meterDaylight85: json['meterDaylight85'] == true,
    );
  }
}

/// One catalog row: a stock that may ship in 135, 120, or both.
class FilmCatalogEntry {
  const FilmCatalogEntry({
    required this.iconKey,
    required this.name,
    required this.iso,
    required this.formats,
    required this.category,
    required this.brand,
    this.balance,
    this.motionPicture = false,
  });

  final String iconKey;
  final String name;
  final int iso;
  final List<FilmType> formats;
  final FilmCategory category;
  final FilmBrand brand;

  /// Explicit colour balance; inferred from name/key when null.
  final FilmBalance? balance;

  /// Cinema / aerial camera stocks (shown under the Movie brand chip).
  final bool motionPicture;

  FilmBalance get resolvedBalance =>
      balance ?? FilmBalance.infer(name: name, iconKey: iconKey);

  String get iconAsset => 'assets/films/$iconKey.png';

  bool offers(FilmType type) => formats.contains(type);

  bool get isInstax => formats.contains(FilmType.instax);

  String get formatsLabel =>
      isInstax ? 'Mini · SQ' : formats.map((f) => f.label).join(' · ');

  /// List section label: Movie stocks are grouped apart from still brands.
  String get brandGroupLabel => motionPicture ? 'Movie' : brand.label;

  FilmStock toStock(FilmType type, {FilmFormat? frameFormat}) {
    assert(offers(type));
    final format = FilmStock.normalizeFrameFormat(type, frameFormat);
    return FilmStock(
      id: '$iconKey-${type.label}-${format.id}',
      name: name,
      type: type,
      frameFormat: format,
      iso: iso,
      brand: brand,
      category: category,
      balance: resolvedBalance,
      iconKey: iconKey,
    );
  }
}

/// Well-known stocks — each listed once, with every format it ships in.
class PopularFilms {
  PopularFilms._();

  static const _both = [FilmType.thirtyFive, FilmType.oneTwenty];
  static const _only135 = [FilmType.thirtyFive];
  static const _onlyInstax = [FilmType.instax];

  static const List<FilmCatalogEntry> catalog = [
    // —— Color negative ——
    FilmCatalogEntry(
      iconKey: 'portra-160',
      name: 'Kodak Portra 160',
      iso: 160,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'portra-400',
      name: 'Kodak Portra 400',
      iso: 400,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'portra-800',
      name: 'Kodak Portra 800',
      iso: 800,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'gold-200',
      name: 'Kodak Gold 200',
      iso: 200,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'ultramax-400',
      name: 'Kodak Ultramax 400',
      iso: 400,
      formats: _only135,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'ektar-100',
      name: 'Kodak Ektar 100',
      iso: 100,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'cinestill-800t',
      name: 'CineStill 800T',
      iso: 800,
      formats: _only135,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.cinestill,
      balance: FilmBalance.tungsten,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-pro-400h',
      name: 'Fujifilm Pro 400H',
      iso: 400,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.fujifilm,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-superia-400',
      name: 'Fujifilm Superia X-TRA 400',
      iso: 400,
      formats: _only135,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.fujifilm,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-200',
      name: 'Fujifilm 200',
      iso: 200,
      formats: _only135,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.fujifilm,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-400',
      name: 'Fujifilm 400',
      iso: 400,
      formats: _only135,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.fujifilm,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-instax-800',
      name: 'Fujifilm Instax',
      iso: 800,
      formats: _onlyInstax,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.fujifilm,
    ),
    FilmCatalogEntry(
      iconKey: 'kodak-vision3-250d',
      name: 'Kodak Vision3 250D (5207)',
      iso: 250,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
      motionPicture: true,
    ),
    FilmCatalogEntry(
      iconKey: 'kodak-vision3-500t',
      name: 'Kodak Vision3 500T (5219)',
      iso: 500,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
      balance: FilmBalance.tungsten,
      motionPicture: true,
    ),
    FilmCatalogEntry(
      iconKey: 'kodak-vision3-50d',
      name: 'Kodak Vision3 50D (5203)',
      iso: 50,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
      motionPicture: true,
    ),
    FilmCatalogEntry(
      iconKey: 'kodak-aerocolor-2460',
      name: 'Kodak Aerocolor IV (2460)',
      iso: 100,
      formats: _both,
      category: FilmCategory.colorNegative,
      brand: FilmBrand.kodak,
      motionPicture: true,
    ),
    // —— Black & white ——
    FilmCatalogEntry(
      iconKey: 'tri-x-400',
      name: 'Kodak Tri-X 400',
      iso: 400,
      formats: _both,
      category: FilmCategory.blackAndWhite,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'tmax-100',
      name: 'Kodak T-Max 100',
      iso: 100,
      formats: _both,
      category: FilmCategory.blackAndWhite,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'tmax-400',
      name: 'Kodak T-Max 400',
      iso: 400,
      formats: _both,
      category: FilmCategory.blackAndWhite,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'hp5-400',
      name: 'Ilford HP5 Plus',
      iso: 400,
      formats: _both,
      category: FilmCategory.blackAndWhite,
      brand: FilmBrand.ilford,
    ),
    FilmCatalogEntry(
      iconKey: 'delta-100',
      name: 'Ilford Delta 100',
      iso: 100,
      formats: _both,
      category: FilmCategory.blackAndWhite,
      brand: FilmBrand.ilford,
    ),
    FilmCatalogEntry(
      iconKey: 'delta-400',
      name: 'Ilford Delta 400',
      iso: 400,
      formats: _both,
      category: FilmCategory.blackAndWhite,
      brand: FilmBrand.ilford,
    ),
    FilmCatalogEntry(
      iconKey: 'fp4-125',
      name: 'Ilford FP4 Plus',
      iso: 125,
      formats: _both,
      category: FilmCategory.blackAndWhite,
      brand: FilmBrand.ilford,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-acros-100',
      name: 'Fujifilm Neopan Acros 100 II',
      iso: 100,
      formats: _both,
      category: FilmCategory.blackAndWhite,
      brand: FilmBrand.fujifilm,
    ),
    // —— Color slide ——
    FilmCatalogEntry(
      iconKey: 'ektachrome-100',
      name: 'Kodak Ektachrome E100',
      iso: 100,
      formats: _both,
      category: FilmCategory.colorSlide,
      brand: FilmBrand.kodak,
    ),
    FilmCatalogEntry(
      iconKey: 'kodak-ektachrome-100d-5294',
      name: 'Kodak Ektachrome 100D (5294)',
      iso: 100,
      formats: _only135,
      category: FilmCategory.colorSlide,
      brand: FilmBrand.kodak,
      motionPicture: true,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-velvia-50',
      name: 'Fujichrome Velvia 50',
      iso: 50,
      formats: _both,
      category: FilmCategory.colorSlide,
      brand: FilmBrand.fujifilm,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-velvia-100',
      name: 'Fujichrome Velvia 100',
      iso: 100,
      formats: _both,
      category: FilmCategory.colorSlide,
      brand: FilmBrand.fujifilm,
    ),
    FilmCatalogEntry(
      iconKey: 'fuji-provia-100',
      name: 'Fujichrome Provia 100F',
      iso: 100,
      formats: _both,
      category: FilmCategory.colorSlide,
      brand: FilmBrand.fujifilm,
    ),
  ];
}

/// Persists the user's selected film rolls (home list) across launches.
class FilmStockStore {
  static const String _fileName = 'films.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<List<FilmStock>> loadSelected() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return const [];
      final films = <FilmStock>[];
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          final film = FilmStock.fromJson(item);
          if (film != null) films.add(film);
        } else if (item is Map) {
          final film = FilmStock.fromJson(Map<String, dynamic>.from(item));
          if (film != null) films.add(film);
        }
      }
      films.sort((a, b) => b.timelineAt.compareTo(a.timelineAt));
      return films;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveSelected(List<FilmStock> films) async {
    try {
      final ordered = [...films]
        ..sort((a, b) => b.timelineAt.compareTo(a.timelineAt));
      final file = await _file();
      await file.writeAsString(
        jsonEncode(ordered.map((f) => f.toJson()).toList()),
      );
      await AppDataBackup.writeMirror();
    } catch (_) {
      // Ignore write failures.
    }
  }

  static Future<void> upsertSelected(FilmStock film) async {
    final list = [...await loadSelected()];
    final i = list.indexWhere((f) => f.id == film.id);
    if (i >= 0) {
      list[i] = film;
    } else {
      list.insert(0, film);
    }
    await saveSelected(list);
  }
}
