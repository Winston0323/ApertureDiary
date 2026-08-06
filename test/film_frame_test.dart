import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:aperture_diary/film_frame.dart';

Uint8List tinyJpeg({int width = 64, int height = 48}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(40, 80, 120));
  img.fillRect(
    image,
    x1: 10,
    y1: 10,
    x2: 40,
    y2: 30,
    color: img.ColorRgb8(220, 180, 40),
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FilmFrameCaption', () {
    test('formats the exposure triad', () {
      const caption = FilmFrameCaption(
        shutter: '1/125',
        aperture: 'f/2.8',
        iso: '400',
      );
      expect(caption.exposureLine, '1/125  ·  f/2.8  ·  ISO 400');
    });
  });

  group('stampFilmFrame', () {
    test('produces a larger JPEG with a border', () async {
      final jpeg = tinyJpeg();
      final stamped = await stampFilmFrame(
        jpegBytes: jpeg,
        caption: const FilmFrameCaption(
          shutter: '1/60',
          aperture: 'f/5.6',
          iso: '200',
          ev: 'EV 11.0',
        ),
      );

      expect(stamped.length, greaterThan(100));
      // JPEG SOI marker.
      expect(stamped[0], 0xFF);
      expect(stamped[1], 0xD8);

      final codec = await instantiateImageCodec(stamped);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(64));
      expect(frame.image.height, greaterThan(48));
      expect(frame.image.height - 48, greaterThan(frame.image.width - 64));
      frame.image.dispose();
    });

    test('keeps full pixel resolution from a large capture', () async {
      final jpeg = tinyJpeg(width: 1600, height: 1200);
      final stamped = await stampFilmFrame(
        jpegBytes: jpeg,
        caption: const FilmFrameCaption(
          shutter: '1/125',
          aperture: 'f/8',
          iso: '100',
        ),
      );
      final codec = await instantiateImageCodec(stamped);
      final frame = await codec.getNextFrame();
      // Border grows the canvas; the photo itself stays 1600-wide.
      expect(frame.image.width, greaterThanOrEqualTo(1600));
      expect(frame.image.height, greaterThan(1200));
      frame.image.dispose();
    });

    test('applies an aspect focal crop when asked', () async {
      final jpeg = tinyJpeg(width: 90, height: 60);
      final stamped = await stampFilmFrame(
        jpegBytes: jpeg,
        caption: const FilmFrameCaption(
          shutter: '1/125',
          aperture: 'f/8',
          iso: '100',
          extra: '36×24 50 mm',
        ),
        cropFraction: 0.5,
        cropAspectRatio: 1.5,
      );
      final codec = await instantiateImageCodec(stamped);
      final frame = await codec.getNextFrame();
      expect(frame.image.height, greaterThan(frame.image.width));
      frame.image.dispose();
    });

    test('rejects undecodable input', () async {
      expect(
        () => stampFilmFrame(
          jpegBytes: Uint8List.fromList([1, 2, 3]),
          caption: const FilmFrameCaption(
            shutter: '1/125',
            aperture: 'f/2.8',
            iso: '100',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
