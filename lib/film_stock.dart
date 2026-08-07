import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:path_provider/path_provider.dart';

import 'film_format.dart';

/// Roll size: 135 (35 mm) or 120 (medium format).
enum FilmType {
  thirtyFive('135'),
  oneTwenty('120');

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
    }
  }

  FilmFormat get defaultFormat {
    switch (this) {
      case FilmType.thirtyFive:
        return FilmFormat.thirtyFive;
      case FilmType.oneTwenty:
        return FilmFormat.sixBySix;
    }
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
        hay.contains('neopan')) {
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
    this.isCustom = false,
    this.iconKey,
    this.addedAt,
  }) : frameFormat = normalizeFrameFormat(type, frameFormat);

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
  final bool isCustom;

  /// Asset key under `assets/films/` (without extension), if any.
  final String? iconKey;

  /// When this roll was added to the home timeline.
  final DateTime? addedAt;

  String? get iconAsset =>
      iconKey == null ? null : 'assets/films/$iconKey.png';

  /// Timeline / meter badge: `135`, or `645` / `6×6` for medium format.
  String get rollFormatLabel {
    if (type == FilmType.thirtyFive) return type.label;
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
    }
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
    bool? isCustom,
    String? iconKey,
    DateTime? addedAt,
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
      isCustom: isCustom ?? this.isCustom,
      iconKey: iconKey ?? this.iconKey,
      addedAt: addedAt ?? this.addedAt,
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
      isCustom: isCustom,
      iconKey: iconKey,
      addedAt: now,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.label,
        'frameFormat': frameFormat.id,
        'iso': iso,
        'brand': brand.name,
        'isCustom': isCustom,
        if (category != null) 'category': category!.name,
        if (iconKey != null) 'iconKey': iconKey,
        if (addedAt != null) 'addedAt': addedAt!.toIso8601String(),
      };

  static FilmStock? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final type = FilmType.fromLabel(json['type'] as String?);
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
    final frameFormat = FilmFormat.byId(json['frameFormat'] as String?);
    return FilmStock(
      id: id,
      name: name,
      type: type,
      frameFormat: frameFormat,
      iso: iso.toInt(),
      brand: brand,
      category: FilmCategory.fromLabel(json['category'] as String?),
      isCustom: json['isCustom'] == true,
      iconKey: iconKey,
      addedAt: addedAt,
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
  });

  final String iconKey;
  final String name;
  final int iso;
  final List<FilmType> formats;
  final FilmCategory category;
  final FilmBrand brand;

  String get iconAsset => 'assets/films/$iconKey.png';

  bool offers(FilmType type) => formats.contains(type);

  String get formatsLabel => formats.map((f) => f.label).join(' · ');

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
      iconKey: iconKey,
    );
  }
}

/// Well-known stocks — each listed once, with every format it ships in.
class PopularFilms {
  PopularFilms._();

  static const _both = [FilmType.thirtyFive, FilmType.oneTwenty];
  static const _only135 = [FilmType.thirtyFive];

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
    } catch (_) {
      // Ignore write failures.
    }
  }
}
