import 'dart:math';
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

/// Centre-crops [image] to a square, then keeps [fraction] of that square
/// (still centred) to match a longer simulated focal length.
ui.Rect sixBySixSourceRect(ui.Image image, double fraction) {
  final w = image.width.toDouble();
  final h = image.height.toDouble();
  final side = min(w, h);
  final left = (w - side) / 2;
  final top = (h - side) / 2;
  final f = fraction.clamp(0.05, 1.0);
  final kept = side * f;
  final inset = (side - kept) / 2;
  return ui.Rect.fromLTWH(left + inset, top + inset, kept, kept);
}

/// Wraps a captured JPEG in a film-style border with exposure info.
///
/// Orientation is baked from EXIF first so a portrait phone shot stays upright
/// when drawn without an EXIF tag. When [cropFraction] is set, the photo is
/// first reduced to a centred square and then to that fraction of the square,
/// matching a 6×6 focal-length simulation.
Future<Uint8List> stampFilmFrame({
  required Uint8List jpegBytes,
  required FilmFrameCaption caption,
  double? cropFraction,
}) async {
  final oriented = _bakeOrientation(jpegBytes);
  final codec = await ui.instantiateImageCodec(oriented);
  final frame = await codec.getNextFrame();
  final photo = frame.image;

  try {
    final src = cropFraction == null
        ? ui.Rect.fromLTWH(
            0,
            0,
            photo.width.toDouble(),
            photo.height.toDouble(),
          )
        : sixBySixSourceRect(photo, cropFraction);

    final photoW = src.width;
    final photoH = src.height;

    // Border scales with the long edge so it stays proportional.
    final longEdge = photoW > photoH ? photoW : photoH;
    final side = (longEdge * 0.04).clamp(24.0, 72.0);
    final bottom = (longEdge * 0.14).clamp(90.0, 220.0);

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
        ..strokeWidth = 1,
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
      text: const TextSpan(
        text: 'LIGHT METER',
        style: TextStyle(
          color: Color(0xFFFFB300),
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 2.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textMaxWidth);

    final exposurePainter = TextPainter(
      text: TextSpan(
        text: caption.exposureLine,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
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
          style: const TextStyle(
            color: Color(0x99FFFFFF),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: textMaxWidth);
    }

    final blockHeight = titlePainter.height +
        8 +
        exposurePainter.height +
        (secondaryPainter != null ? 6 + secondaryPainter.height : 0);
    var y = stripTop + (stripHeight - blockHeight) / 2;

    titlePainter.paint(canvas, Offset(side, y));
    y += titlePainter.height + 8;
    exposurePainter.paint(canvas, Offset(side, y));
    y += exposurePainter.height;
    if (secondaryPainter != null) {
      y += 6;
      secondaryPainter.paint(canvas, Offset(side, y));
    }

    final picture = recorder.endRecording();
    final stamped = await picture.toImage(outW, outH);
    try {
      final bytes = await stamped.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        throw StateError('Failed to encode stamped frame');
      }
      return bytes.buffer.asUint8List();
    } finally {
      stamped.dispose();
    }
  } finally {
    photo.dispose();
  }
}

Uint8List _bakeOrientation(Uint8List jpegBytes) {
  try {
    final decoded = img.decodeImage(jpegBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode the captured image');
    }
    final upright = img.bakeOrientation(decoded);
    return Uint8List.fromList(img.encodeJpg(upright, quality: 95));
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('Could not decode the captured image: $e');
  }
}
