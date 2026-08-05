import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:light_meter/film_frame.dart';

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
    test('produces a larger PNG with a border', () async {
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

      expect(stamped.length, greaterThan(jpeg.length ~/ 2));
      // PNG signature.
      expect(stamped.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);

      final codec = await instantiateImageCodec(stamped);
      final frame = await codec.getNextFrame();
      // Border grows both width and height beyond the 64×48 source.
      expect(frame.image.width, greaterThan(64));
      expect(frame.image.height, greaterThan(48));
      // Bottom strip is taller than the side margins.
      expect(frame.image.height - 48, greaterThan(frame.image.width - 64));
      frame.image.dispose();
    });

    test('applies a square focal crop when asked', () async {
      final jpeg = tinyJpeg(width: 80, height: 60);
      final stamped = await stampFilmFrame(
        jpegBytes: jpeg,
        caption: const FilmFrameCaption(
          shutter: '1/125',
          aperture: 'f/8',
          iso: '100',
          extra: '6×6 80 mm',
        ),
        cropFraction: 0.5,
      );
      final codec = await instantiateImageCodec(stamped);
      final frame = await codec.getNextFrame();
      // Source becomes a square of side 60*0.5=30 before the border.
      expect(frame.image.width, greaterThan(30));
      expect(
        (frame.image.width - frame.image.height).abs(),
        lessThan(frame.image.width), // border makes it taller, still near-square photo
      );
      // With a square photo the output is taller than wide because of the strip.
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
