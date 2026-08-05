import 'dart:math';
import 'dart:ui' show Offset, Size;

import 'package:camera/camera.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';

import 'exposure.dart';

/// The exposure the camera actually used for a frame, read from EXIF.
@immutable
class ExposureParams {
  final double aperture;
  final double shutterSeconds;
  final double iso;

  const ExposureParams({
    required this.aperture,
    required this.shutterSeconds,
    required this.iso,
  });

  /// EV₁₀₀ these settings expose middle grey at.
  double get ev100 => ExposureMath.cameraEv100(
        aperture: aperture,
        shutterSeconds: shutterSeconds,
        iso: iso,
      );

  bool get isValid =>
      aperture > 0 && shutterSeconds > 0 && iso > 0 && !ev100.isNaN;

  String get summary => '${ExposureMath.formatAperture(aperture)}  '
      '${ExposureMath.formatShutter(shutterSeconds)}  '
      'ISO ${iso.round()}';

  @override
  String toString() => summary;
}

/// Reads exposure settings out of a JPEG's EXIF block.
///
/// Falls back to the APEX aperture/shutter tags, which some devices write
/// instead of the direct values.
ExposureParams? parseExposureParams(Map<String, IfdTag> tags) {
  double? aperture = _tagNumber(tags, const [
    'EXIF FNumber',
    'Image FNumber',
  ]);
  final apexAperture = _tagNumber(tags, const [
    'EXIF ApertureValue',
    'Image ApertureValue',
  ]);
  if (aperture == null && apexAperture != null) {
    // Av = 2·log2(N)
    aperture = pow(2.0, apexAperture / 2.0).toDouble();
  }

  double? shutter = _tagNumber(tags, const [
    'EXIF ExposureTime',
    'Image ExposureTime',
  ]);
  final apexShutter = _tagNumber(tags, const [
    'EXIF ShutterSpeedValue',
    'Image ShutterSpeedValue',
  ]);
  if (shutter == null && apexShutter != null) {
    // Tv = log2(1/t)
    shutter = pow(2.0, -apexShutter).toDouble();
  }

  final iso = _tagNumber(tags, const [
    'EXIF ISOSpeedRatings',
    'EXIF PhotographicSensitivity',
    'EXIF RecommendedExposureIndex',
    'Image ISOSpeedRatings',
  ]);

  if (aperture == null || shutter == null || iso == null) return null;

  final params = ExposureParams(
    aperture: aperture,
    shutterSeconds: shutter,
    iso: iso,
  );
  return params.isValid ? params : null;
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
        if (d.isFinite && d != 0) return d;
        continue;
      }
      if (v is num) {
        final d = v.toDouble();
        if (d.isFinite && d != 0) return d;
        continue;
      }
    }
    final parsed = _parsePrintable(tag.printable);
    if (parsed != null) return parsed;
  }
  return null;
}

double? _parsePrintable(String printable) {
  final text = printable.split(',').first.trim();
  if (text.isEmpty) return null;
  if (text.contains('/')) {
    final parts = text.split('/');
    if (parts.length == 2) {
      final n = double.tryParse(parts[0].trim());
      final d = double.tryParse(parts[1].trim());
      if (n != null && d != null && d != 0) return n / d;
    }
    return null;
  }
  return double.tryParse(text);
}

/// A spot reading averaged over a small patch of the frame.
@immutable
class SpotSample {
  /// Mean linear luminance of the patch (0..1, relative).
  final double linearLuminance;

  /// Mean gamma-encoded luminance, used to judge clipping.
  final double encodedLuminance;

  final int r;
  final int g;
  final int b;

  const SpotSample({
    required this.linearLuminance,
    required this.encodedLuminance,
    required this.r,
    required this.g,
    required this.b,
  });

  /// Patch is near white; the tone curve is compressed here so a reading
  /// derived from it understates the true brightness.
  bool get isClipped => encodedLuminance > 0.94;

  /// Patch is near black; noise dominates.
  bool get isCrushed => encodedLuminance < 0.03;

  bool get isUsable => !isClipped && !isCrushed;

  /// Stops the patch sits above (or below) middle grey.
  double get stopsFromMiddleGrey =>
      ExposureMath.log2(linearLuminance.clamp(1e-6, 1.0) /
          ExposureMath.middleGrey);
}

/// Where a tapped preview point lands in the camera frame's own pixel space.
@immutable
class SpotMapping {
  final double x;
  final double y;
  final double radius;

  const SpotMapping({
    required this.x,
    required this.y,
    required this.radius,
  });
}

/// Maps a point in the preview widget to frame pixel coordinates.
///
/// The frame arrives in sensor orientation (landscape) while the preview is
/// drawn rotated by [quarterTurns] and centre-cropped with `BoxFit.cover`, so
/// both the rotation and the crop have to be undone to sample the pixel the
/// crosshair is actually sitting on.
SpotMapping? mapSpotToFrame({
  required int frameWidth,
  required int frameHeight,
  required int quarterTurns,
  required bool mirror,
  required Size widgetSize,
  required Offset spot,
  required double radiusInWidgetPixels,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) return null;
  if (widgetSize.width <= 0 || widgetSize.height <= 0) return null;

  final turns = quarterTurns % 4;
  final swap = turns.isOdd;

  // Frame dimensions as displayed, after rotation.
  final rotatedWidth = (swap ? frameHeight : frameWidth).toDouble();
  final rotatedHeight = (swap ? frameWidth : frameHeight).toDouble();

  // BoxFit.cover: scale so the frame covers the widget, cropping the overflow.
  final scale = max(
    widgetSize.width / rotatedWidth,
    widgetSize.height / rotatedHeight,
  );

  var u = spot.dx;
  if (mirror) u = 1.0 - u;

  final xr = rotatedWidth / 2 + (u * widgetSize.width - widgetSize.width / 2) / scale;
  final yr = rotatedHeight / 2 +
      (spot.dy * widgetSize.height - widgetSize.height / 2) / scale;
  final radius = radiusInWidgetPixels / scale;

  double fx, fy;
  switch (turns) {
    case 1:
      fx = yr;
      fy = (rotatedWidth - 1) - xr;
      break;
    case 2:
      fx = (frameWidth - 1) - xr;
      fy = (frameHeight - 1) - yr;
      break;
    case 3:
      fx = (rotatedHeight - 1) - yr;
      fy = xr;
      break;
    default:
      fx = xr;
      fy = yr;
  }

  return SpotMapping(x: fx, y: fy, radius: radius);
}

/// Averages a circular patch of the frame around the mapped spot.
///
/// Averaging in linear light (not in gamma-encoded values) is what makes this
/// a photometric measurement rather than a perceptual one.
SpotSample? sampleSpot({
  required CameraImage image,
  required Offset spot,
  required Size widgetSize,
  required int quarterTurns,
  required bool mirror,
  required double radiusInWidgetPixels,
}) {
  final mapping = mapSpotToFrame(
    frameWidth: image.width,
    frameHeight: image.height,
    quarterTurns: quarterTurns,
    mirror: mirror,
    widgetSize: widgetSize,
    spot: spot,
    radiusInWidgetPixels: radiusInWidgetPixels,
  );
  if (mapping == null) return null;

  final reader = _PixelReader.of(image);
  if (reader == null) return null;

  final radius = mapping.radius.clamp(1.0, 200.0);
  // Cap the sample grid so frame processing stays cheap.
  final step = max(1, (2 * radius / 15).ceil());
  final radiusSquared = radius * radius;

  double linearSum = 0;
  double encodedSum = 0;
  int rSum = 0, gSum = 0, bSum = 0;
  int count = 0;

  final cx = mapping.x.round();
  final cy = mapping.y.round();
  final r = radius.ceil();

  for (var dy = -r; dy <= r; dy += step) {
    final y = cy + dy;
    if (y < 0 || y >= image.height) continue;
    for (var dx = -r; dx <= r; dx += step) {
      if (dx * dx + dy * dy > radiusSquared) continue;
      final x = cx + dx;
      if (x < 0 || x >= image.width) continue;

      final pixel = reader.read(x, y);
      if (pixel == null) continue;

      linearSum += ExposureMath.linearLuminance8(pixel.r, pixel.g, pixel.b);
      encodedSum += (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) / 255.0;
      rSum += pixel.r;
      gSum += pixel.g;
      bSum += pixel.b;
      count++;
    }
  }

  if (count == 0) {
    // Patch fell outside the frame; fall back to the single centre pixel.
    final pixel = reader.read(
      cx.clamp(0, image.width - 1),
      cy.clamp(0, image.height - 1),
    );
    if (pixel == null) return null;
    return SpotSample(
      linearLuminance: ExposureMath.linearLuminance8(pixel.r, pixel.g, pixel.b),
      encodedLuminance:
          (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) / 255.0,
      r: pixel.r,
      g: pixel.g,
      b: pixel.b,
    );
  }

  return SpotSample(
    linearLuminance: linearSum / count,
    encodedLuminance: encodedSum / count,
    r: rSum ~/ count,
    g: gSum ~/ count,
    b: bSum ~/ count,
  );
}

@immutable
class _Rgb {
  final int r;
  final int g;
  final int b;
  const _Rgb(this.r, this.g, this.b);
}

/// Reads gamma-encoded RGB out of a [CameraImage] regardless of plane layout.
abstract class _PixelReader {
  _Rgb? read(int x, int y);

  static _PixelReader? of(CameraImage image) {
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        return _Yuv420Reader(image);
      case ImageFormatGroup.bgra8888:
        return _Bgra8888Reader(image);
      default:
        return null;
    }
  }
}

class _Yuv420Reader implements _PixelReader {
  _Yuv420Reader(this.image)
      : yPlane = image.planes[0],
        uPlane = image.planes.length > 1 ? image.planes[1] : null,
        vPlane = image.planes.length > 2 ? image.planes[2] : null;

  final CameraImage image;
  final Plane yPlane;
  final Plane? uPlane;
  final Plane? vPlane;

  @override
  _Rgb? read(int x, int y) {
    final yStride = yPlane.bytesPerPixel ?? 1;
    final yIndex = y * yPlane.bytesPerRow + x * yStride;
    if (yIndex < 0 || yIndex >= yPlane.bytes.length) return null;
    final luma = yPlane.bytes[yIndex] & 0xFF;

    var u = 128;
    var v = 128;
    final uv = uPlane;
    final vv = vPlane;
    if (uv != null && vv != null) {
      final uvRow = y >> 1;
      final uvCol = x >> 1;
      final uIndex = uvRow * uv.bytesPerRow + uvCol * (uv.bytesPerPixel ?? 1);
      final vIndex = uvRow * vv.bytesPerRow + uvCol * (vv.bytesPerPixel ?? 1);
      if (uIndex >= 0 && uIndex < uv.bytes.length) u = uv.bytes[uIndex] & 0xFF;
      if (vIndex >= 0 && vIndex < vv.bytes.length) v = vv.bytes[vIndex] & 0xFF;
    } else if (uv != null) {
      // Semi-planar NV21: interleaved V,U in a single chroma plane.
      final uvRow = y >> 1;
      final uvCol = x >> 1;
      final index = uvRow * uv.bytesPerRow + uvCol * 2;
      if (index >= 0 && index + 1 < uv.bytes.length) {
        v = uv.bytes[index] & 0xFF;
        u = uv.bytes[index + 1] & 0xFF;
      }
    }

    final yd = luma.toDouble();
    final ud = u - 128.0;
    final vd = v - 128.0;
    final r = (yd + 1.402 * vd).clamp(0.0, 255.0);
    final g = (yd - 0.344136 * ud - 0.714136 * vd).clamp(0.0, 255.0);
    final b = (yd + 1.772 * ud).clamp(0.0, 255.0);
    return _Rgb(r.round(), g.round(), b.round());
  }
}

class _Bgra8888Reader implements _PixelReader {
  _Bgra8888Reader(this.image) : plane = image.planes[0];

  final CameraImage image;
  final Plane plane;

  @override
  _Rgb? read(int x, int y) {
    final index = y * plane.bytesPerRow + x * 4;
    if (index < 0 || index + 2 >= plane.bytes.length) return null;
    return _Rgb(
      plane.bytes[index + 2] & 0xFF,
      plane.bytes[index + 1] & 0xFF,
      plane.bytes[index] & 0xFF,
    );
  }
}
