import 'dart:math';
import 'dart:ui' show Offset, Size;

import 'package:camera/camera.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';

import 'color_temperature.dart';
import 'exposure.dart';
import 'multi_spot.dart';
import 'tone_curve.dart';

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
  bool get isClipped => encodedLuminance > ExposureMath.usableEncodedMax;

  /// Patch is near black; the tone curve is crushed here and noise dominates.
  bool get isCrushed => encodedLuminance < ExposureMath.usableEncodedMin;

  /// Whether the plain sRGB inversion can be trusted for this patch.
  ///
  /// Measured against a real phone pipeline, sRGB is within about ⅓ stop over
  /// [ExposureMath.usableEncodedMin]…[ExposureMath.usableEncodedMax] and wrong
  /// by up to two stops outside it, so the band is narrow on purpose: it is
  /// better to re-meter than to report a reading that is stops out.
  bool get isUsable => !isClipped && !isCrushed;

  /// Stops the patch sits above (or below) middle grey.
  double get stopsFromMiddleGrey =>
      ExposureMath.log2(linearLuminance.clamp(1e-6, 1.0) /
          ExposureMath.middleGrey);

  /// Correlated colour temperature of the patch, or null when the colour is
  /// not something a temperature describes.
  ///
  /// Pass a measured [curve] to linearize with the device's real response, and
  /// a [reference] to undo the camera's white-balance bias.
  ColorTemperature? colorTemperature({
    ToneCurve? curve,
    WhiteBalanceReference? reference,
  }) {
    return ColorTemperatureMath.fromRgb8(
      r,
      g,
      b,
      curve: curve,
      reference: reference,
    );
  }

  /// Correlated colour temperature in Kelvin, or null if too dark to trust.
  double? get cctKelvin {
    if (encodedLuminance < 0.04) return null;
    return colorTemperature()?.kelvin;
  }
}

/// McCamy CCT (Kelvin) from gamma-encoded 8-bit sRGB.
///
/// Retained for the tests that pin the historical behaviour; new code should
/// use [ColorTemperatureMath.fromRgb8], which searches the black-body locus
/// directly instead of relying on a polynomial that drifts by hundreds of
/// Kelvin outside 2856–6500 K, and which refuses colours no temperature
/// describes rather than inventing a number for them.
@Deprecated('Use ColorTemperatureMath.fromRgb8')
double? cctKelvinFromSrgb8(int r, int g, int b) {
  return ColorTemperatureMath.fromRgb8(r, g, b)?.kelvin;
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
/// Encoded luminance is taken from the Y plane on YUV frames (the luma the
/// ISP actually produced) rather than a YUV→RGB→Rec.709 round trip, which
/// clips saturated colours and is slower. Speculars are trimmed so a glint
/// does not pull the spot a stop bright. RGB is still averaged, on a coarser
/// grid, for white-balance.
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
  // Denser than before: luma is a single byte, so a ~24-sample diameter
  // stays cheap at 30 fps and averages sensor noise down.
  final step = max(1, (2 * radius / 24).ceil());
  final rgbStep = step * 2;
  final radiusSquared = radius * radius;

  final encodedSamples = <double>[];
  int rSum = 0, gSum = 0, bSum = 0;
  int rgbCount = 0;

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

      final luma = reader.luma(x, y);
      if (luma == null) continue;
      encodedSamples.add(luma / 255.0);

      if (dx % rgbStep == 0 && dy % rgbStep == 0) {
        final pixel = reader.read(x, y);
        if (pixel == null) continue;
        rSum += pixel.r;
        gSum += pixel.g;
        bSum += pixel.b;
        rgbCount++;
      }
    }
  }

  if (encodedSamples.isEmpty) {
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

  final encoded = _trimmedMean(encodedSamples);
  if (encoded == null) return null;

  double linearSum = 0;
  var linearCount = 0;
  for (final e in encodedSamples) {
    if ((e - encoded).abs() > 0.35) continue;
    linearSum += ExposureMath.srgbToLinear(e);
    linearCount++;
  }

  final rgb = rgbCount == 0
      ? reader.read(
          cx.clamp(0, image.width - 1),
          cy.clamp(0, image.height - 1),
        )
      : null;

  return SpotSample(
    linearLuminance:
        linearCount == 0 ? ExposureMath.srgbToLinear(encoded) : linearSum / linearCount,
    encodedLuminance: encoded,
    r: rgbCount == 0 ? (rgb?.r ?? 0) : rSum ~/ rgbCount,
    g: rgbCount == 0 ? (rgb?.g ?? 0) : gSum ~/ rgbCount,
    b: rgbCount == 0 ? (rgb?.b ?? 0) : bSum ~/ rgbCount,
  );
}

/// Samples the whole viewfinder as a grid of cells, for the multi-spot view.
///
/// Cells are laid out in viewfinder space with square-ish proportions and a
/// small [margin] kept clear of the edge, where lens falloff would otherwise
/// make every frame's darkest spot a corner. Each cell is the mean of a 3×3
/// cluster of luma samples, so a single hot pixel cannot become the "highest"
/// value. [luma] reads the encoded luma (0–255) at a frame pixel.
///
/// [toPreview] maps a viewfinder point into preview space when the focal
/// simulation has cropped the frame; [radiusScale] is that crop fraction, so a
/// cell covers the same part of the picture the user sees.
List<LumaCell>? sampleLumaGrid({
  required int frameWidth,
  required int frameHeight,
  required int? Function(int x, int y) luma,
  required Size widgetSize,
  required int quarterTurns,
  required bool mirror,
  int columns = 18,
  double margin = 0.05,
  Offset Function(Offset normalized)? toPreview,
  double radiusScale = 1.0,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) return null;
  if (widgetSize.width <= 0 || widgetSize.height <= 0) return null;
  if (columns < 1) return null;

  final span = 1.0 - 2 * margin;
  final cellWidth = widgetSize.width * span / columns;
  final rows = (widgetSize.height * span / cellWidth).round().clamp(4, 48);
  final cellHeight = widgetSize.height * span / rows;
  final halfCell = min(cellWidth, cellHeight) / 2 * radiusScale;

  final cells = <LumaCell>[];
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < columns; c++) {
      final nx = margin + span * (c + 0.5) / columns;
      final ny = margin + span * (r + 0.5) / rows;
      final point = Offset(nx, ny);
      final spot = toPreview == null ? point : toPreview(point);

      final mapping = mapSpotToFrame(
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        quarterTurns: quarterTurns,
        mirror: mirror,
        widgetSize: widgetSize,
        spot: spot,
        radiusInWidgetPixels: halfCell,
      );
      if (mapping == null) continue;

      final reach = (mapping.radius * 0.6).clamp(1.0, 100.0);
      var sum = 0.0;
      var count = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final x = (mapping.x + dx * reach).round().clamp(0, frameWidth - 1);
          final y = (mapping.y + dy * reach).round().clamp(0, frameHeight - 1);
          final v = luma(x, y);
          if (v == null) continue;
          sum += v;
          count++;
        }
      }
      if (count == 0) continue;
      cells.add(LumaCell(x: nx, y: ny, encoded: sum / count / 255.0));
    }
  }
  return cells.isEmpty ? null : cells;
}

/// [sampleLumaGrid] over a live [CameraImage].
List<LumaCell>? sampleLumaGridFromImage({
  required CameraImage image,
  required Size widgetSize,
  required int quarterTurns,
  required bool mirror,
  int columns = 18,
  Offset Function(Offset normalized)? toPreview,
  double radiusScale = 1.0,
}) {
  final reader = _PixelReader.of(image);
  if (reader == null) return null;
  return sampleLumaGrid(
    frameWidth: image.width,
    frameHeight: image.height,
    luma: reader.luma,
    widgetSize: widgetSize,
    quarterTurns: quarterTurns,
    mirror: mirror,
    columns: columns,
    toPreview: toPreview,
    radiusScale: radiusScale,
  );
}

/// Mean after dropping the brightest and darkest tails (speculars / noise).
double? _trimmedMean(List<double> values, {double trim = 0.1}) {
  if (values.isEmpty) return null;
  if (values.length < 8) {
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }
  final sorted = [...values]..sort();
  final drop = (sorted.length * trim).floor().clamp(1, sorted.length ~/ 5);
  var sum = 0.0;
  var n = 0;
  for (var i = drop; i < sorted.length - drop; i++) {
    sum += sorted[i];
    n++;
  }
  return n == 0 ? null : sum / n;
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

  /// Encoded luma 0–255. On YUV this is the Y plane; on BGRA it is Rec.709
  /// of the stored bytes, without a colour-matrix round trip.
  int? luma(int x, int y);

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

  @override
  int? luma(int x, int y) {
    final yStride = yPlane.bytesPerPixel ?? 1;
    final yIndex = y * yPlane.bytesPerRow + x * yStride;
    if (yIndex < 0 || yIndex >= yPlane.bytes.length) return null;
    return yPlane.bytes[yIndex] & 0xFF;
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

  @override
  int? luma(int x, int y) {
    final pixel = read(x, y);
    if (pixel == null) return null;
    return (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b)
        .round()
        .clamp(0, 255);
  }
}
