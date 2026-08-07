import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'film_format.dart';

/// Physical lens / sensor info for the active camera.
@immutable
class LensInfo {
  const LensInfo({
    required this.focalLengthMm,
    this.sensorWidthMm,
    this.sensorHeightMm,
    this.equivalent35mm,
  });

  /// Native (un-zoomed) focal length in millimetres.
  final double focalLengthMm;

  /// Sensor active array size in millimetres, when known.
  final double? sensorWidthMm;
  final double? sensorHeightMm;

  /// 35 mm-equivalent focal length, when the device or EXIF reports it.
  final double? equivalent35mm;

  bool get isUsable => focalLengthMm > 0;

  bool get hasSensorSize =>
      sensorWidthMm != null &&
      sensorHeightMm != null &&
      sensorWidthMm! > 0 &&
      sensorHeightMm! > 0;

  /// Crop fraction for a focal simulation on [format] at [zoom].
  double cropForFormat(FilmFormat format, double simulatedFocalMm, double zoom) {
    if (hasSensorSize) {
      return FilmOptics.cropFraction(
        format: format,
        phoneFocalMm: focalLengthMm,
        phoneSensorWidthMm: sensorWidthMm!,
        phoneSensorHeightMm: sensorHeightMm!,
        simulatedFocalMm: simulatedFocalMm,
        zoom: zoom,
      );
    }
    final eq = equivalent35mm;
    if (eq != null && eq > 0) {
      return FilmOptics.cropFractionFrom35mm(
        format: format,
        phone35mmEquivalent: eq,
        simulatedFocalMm: simulatedFocalMm,
        zoom: zoom,
      );
    }
    // Last resort: treat the reported focal as already 35 mm-equivalent.
    return FilmOptics.cropFractionFrom35mm(
      format: format,
      phone35mmEquivalent: focalLengthMm,
      simulatedFocalMm: simulatedFocalMm,
      zoom: zoom,
    );
  }

  @override
  String toString() {
    final bits = <String>['${focalLengthMm.toStringAsFixed(2)} mm'];
    if (equivalent35mm != null) {
      bits.add('≈ ${equivalent35mm!.round()} mm eq');
    }
    if (hasSensorSize) {
      bits.add(
        'sensor ${sensorWidthMm!.toStringAsFixed(2)}×'
        '${sensorHeightMm!.toStringAsFixed(2)} mm',
      );
    }
    return bits.join(' · ');
  }
}

const _channel = MethodChannel('com.example.aperture_diary/lens');

/// Reads lens info from the Android Camera2 characteristics.
Future<LensInfo?> readLensInfoFromPlatform({String? cameraName}) async {
  if (kIsWeb) return null;
  try {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'getLensInfo',
      <String, Object?>{'cameraName': cameraName},
    );
    if (raw == null) return null;

    // Prefer the platform-chosen primary wide focal; do not fall back to the
    // shortest listed length (often the ultra-wide), which overstates FOV.
    double? focal = (raw['focalLengthMm'] as num?)?.toDouble();
    if (focal == null || focal <= 0) {
      final focals = raw['focalLengthsMm'];
      if (focals is List && focals.isNotEmpty) {
        final values = focals
            .map((e) => (e as num).toDouble())
            .where((e) => e > 0)
            .toList()
          ..sort();
        if (values.isNotEmpty) focal = values.first;
      }
    }
    if (focal == null || focal <= 0) return null;

    return LensInfo(
      focalLengthMm: focal,
      sensorWidthMm: (raw['sensorWidthMm'] as num?)?.toDouble(),
      sensorHeightMm: (raw['sensorHeightMm'] as num?)?.toDouble(),
      equivalent35mm: (raw['equivalent35mm'] as num?)?.toDouble(),
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Pulls lens info from a JPEG's EXIF as a fallback / cross-check.
LensInfo? parseLensInfoFromExif(Map<String, IfdTag> tags) {
  final focal = _tagNumber(tags, const [
    'EXIF FocalLength',
    'Image FocalLength',
  ]);
  final equiv = _tagNumber(tags, const [
    'EXIF FocalLengthIn35mmFilm',
    'EXIF FocalLenIn35mmFilm',
    'Image FocalLengthIn35mmFilm',
  ]);

  if ((focal == null || focal <= 0) && (equiv == null || equiv <= 0)) {
    return null;
  }

  return LensInfo(
    focalLengthMm: (focal != null && focal > 0) ? focal : equiv!,
    equivalent35mm: (equiv != null && equiv > 0) ? equiv : null,
  );
}

double? _tagNumber(Map<String, IfdTag> tags, List<String> keys) {
  for (final key in keys) {
    final tag = tags[key];
    if (tag == null) continue;
    final values = tag.values.toList();
    if (values.isNotEmpty) {
      final v = values.first;
      if (v is Ratio) {
        final d = v.toDouble();
        if (d.isFinite && d > 0) return d;
        continue;
      }
      if (v is num) {
        final d = v.toDouble();
        if (d.isFinite && d > 0) return d;
        continue;
      }
    }
    final text = tag.printable.split(',').first.trim();
    if (text.contains('/')) {
      final parts = text.split('/');
      if (parts.length == 2) {
        final n = double.tryParse(parts[0].trim());
        final d = double.tryParse(parts[1].trim());
        if (n != null && d != null && d != 0) return n / d;
      }
    } else {
      final parsed = double.tryParse(text);
      if (parsed != null && parsed > 0) return parsed;
    }
  }
  return null;
}

/// Prefer platform info; fall back to EXIF-derived values.
LensInfo? mergeLensInfo(LensInfo? platform, LensInfo? exif) {
  if (platform == null) return exif;
  if (exif == null) return platform;
  return LensInfo(
    focalLengthMm: platform.focalLengthMm,
    sensorWidthMm: platform.sensorWidthMm,
    sensorHeightMm: platform.sensorHeightMm,
    equivalent35mm: platform.equivalent35mm ?? exif.equivalent35mm,
  );
}
