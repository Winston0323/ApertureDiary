import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Exposure settings stamped onto a saved frame.
@immutable
class FilmFrameCaption {
  const FilmFrameCaption({
    required this.shutter,
    required this.aperture,
    required this.iso,
    this.ev,
    this.extra,
  });

  final String shutter;
  final String aperture;
  final String iso;
  final String? ev;
  final String? extra;

  /// Primary line: shutter · aperture · ISO
  String get exposureLine => '$shutter  ·  $aperture  ·  ISO $iso';
}

/// Centre-crops [image] to [aspectRatio] (width÷height), then keeps
/// [fraction] of that frame (still centred) for a longer simulated focal length.
ui.Rect filmSourceRect(
  ui.Image image, {
  required double aspectRatio,
  required double fraction,
}) {
  final w = image.width.toDouble();
  final h = image.height.toDouble();
  final aspect = aspectRatio <= 0 ? 1.0 : aspectRatio;

  late final double frameW;
  late final double frameH;
  if (w / h > aspect) {
    frameH = h;
    frameW = h * aspect;
  } else {
    frameW = w;
    frameH = w / aspect;
  }

  final f = fraction.clamp(0.05, 1.0);
  final keptW = frameW * f;
  final keptH = frameH * f;
  return ui.Rect.fromCenter(
    center: ui.Offset(w / 2, h / 2),
    width: keptW,
    height: keptH,
  );
}

/// Wraps a captured JPEG in a film-style border with exposure info.
///
/// Orientation is baked from EXIF first so a portrait phone shot stays upright
/// when drawn without an EXIF tag. When [cropFraction] is set, the photo is
/// first reduced to [cropAspectRatio] and then to that fraction of the frame,
/// matching a focal-length simulation on that film format.
///
/// Returns a high-quality JPEG at the full capture resolution (plus border).
Future<Uint8List> stampFilmFrame({
  required Uint8List jpegBytes,
  required FilmFrameCaption caption,
  double? cropFraction,
  double cropAspectRatio = 1.0,
}) async {
  final photo = await _orientedUiImage(jpegBytes);

  try {
    final src = cropFraction == null
        ? ui.Rect.fromLTWH(
            0,
            0,
            photo.width.toDouble(),
            photo.height.toDouble(),
          )
        : filmSourceRect(
            photo,
            aspectRatio: cropAspectRatio,
            fraction: cropFraction,
          );

    final photoW = src.width;
    final photoH = src.height;

    // Scale matte and type with the long edge so 12 MP frames don't get a
    // postage-stamp caption.
    final longEdge = photoW > photoH ? photoW : photoH;
    final side = (longEdge * 0.045).clamp(28.0, 220.0);
    final bottom = (longEdge * 0.155).clamp(110.0, 560.0);
    final titleSize = (longEdge * 0.016).clamp(13.0, 56.0);
    final exposureSize = (longEdge * 0.030).clamp(20.0, 96.0);
    final secondarySize = (longEdge * 0.018).clamp(12.0, 56.0);
    final titleTracking = (longEdge * 0.0025).clamp(1.5, 8.0);

    final outW = (photoW + side * 2).round();
    final outH = (photoH + side + bottom).round();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      Paint()..color = const Color(0xFF0A0A0A),
    );

    canvas.drawRect(
      Rect.fromLTWH(side - 1, side - 1, photoW + 2, photoH + 2),
      Paint()
        ..color = const Color(0xFF2A2A2A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (longEdge * 0.0015).clamp(1.0, 4.0),
    );

    canvas.drawImageRect(
      photo,
      src,
      Rect.fromLTWH(side, side, photoW, photoH),
      Paint()..filterQuality = FilterQuality.high,
    );

    final stripTop = side + photoH;
    final stripHeight = bottom;
    final textMaxWidth = outW - side * 2;

    final titlePainter = TextPainter(
      text: TextSpan(
        text: 'LIGHT METER',
        style: TextStyle(
          color: const Color(0xFFFFB300),
          fontSize: titleSize,
          fontWeight: FontWeight.w700,
          letterSpacing: titleTracking,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textMaxWidth);

    final exposurePainter = TextPainter(
      text: TextSpan(
        text: caption.exposureLine,
        style: TextStyle(
          color: Colors.white,
          fontSize: exposureSize,
          fontWeight: FontWeight.w700,
          letterSpacing: titleTracking * 0.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: textMaxWidth);

    String? secondary;
    if (caption.ev != null && caption.extra != null) {
      secondary = '${caption.ev}  ·  ${caption.extra}';
    } else {
      secondary = caption.ev ?? caption.extra;
    }

    TextPainter? secondaryPainter;
    if (secondary != null) {
      secondaryPainter = TextPainter(
        text: TextSpan(
          text: secondary,
          style: TextStyle(
            color: const Color(0x99FFFFFF),
            fontSize: secondarySize,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: textMaxWidth);
    }

    final gapTitle = (longEdge * 0.008).clamp(6.0, 24.0);
    final gapSecondary = (longEdge * 0.006).clamp(4.0, 18.0);
    final blockHeight = titlePainter.height +
        gapTitle +
        exposurePainter.height +
        (secondaryPainter != null
            ? gapSecondary + secondaryPainter.height
            : 0);
    var y = stripTop + (stripHeight - blockHeight) / 2;

    titlePainter.paint(canvas, Offset(side, y));
    y += titlePainter.height + gapTitle;
    exposurePainter.paint(canvas, Offset(side, y));
    y += exposurePainter.height;
    if (secondaryPainter != null) {
      y += gapSecondary;
      secondaryPainter.paint(canvas, Offset(side, y));
    }

    final picture = recorder.endRecording();
    final stamped = await picture.toImage(outW, outH);
    try {
      return await _encodeJpeg(stamped, quality: 98);
    } finally {
      stamped.dispose();
    }
  } finally {
    photo.dispose();
  }
}

/// Decodes a capture, applies EXIF orientation, and uploads pixels to the GPU
/// without a lossy JPEG round-trip.
Future<ui.Image> _orientedUiImage(Uint8List jpegBytes) async {
  try {
    final decoded = img.decodeImage(jpegBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode the captured image');
    }
    final upright = img.bakeOrientation(decoded);
    final rgba = upright.convert(numChannels: 4);
    final bytes = Uint8List.fromList(
      rgba.getBytes(order: img.ChannelOrder.rgba),
    );

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      rgba.width,
      rgba.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('Could not decode the captured image: $e');
  }
}

Future<Uint8List> _encodeJpeg(ui.Image image, {int quality = 98}) async {
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) {
    throw StateError('Failed to read stamped frame pixels');
  }
  final rgba = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: byteData.buffer,
    bytesOffset: byteData.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(rgba, quality: quality));
}
