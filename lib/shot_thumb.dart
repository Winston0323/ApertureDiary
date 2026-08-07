import 'dart:io';

import 'package:flutter/material.dart';

import 'album_shot.dart';
import 'film_format.dart';

const Color _accent = Color(0xFFFFB300);

/// Side-by-side meter | scan pair; each preview keeps the film aspect ratio.
class ShotThumbStack extends StatelessWidget {
  const ShotThumbStack({
    super.key,
    required this.shot,
    this.height = 96,
    this.borderRadius = 8,
    this.showArrow = true,
  });

  final AlbumShot shot;
  final double height;
  final double borderRadius;
  final bool showArrow;

  bool get _hasScan =>
      shot.hasScan &&
      shot.scanImagePath != null &&
      File(shot.scanImagePath!).existsSync();

  double get _aspect {
    final label = shot.formatLabel;
    if (label != null) {
      for (final format in FilmFormat.all) {
        if (format.label == label) return format.aspectRatio;
      }
    }
    return 3 / 2;
  }

  @override
  Widget build(BuildContext context) {
    final hasScan = _hasScan;
    final aspect = _aspect;

    return SizedBox(
      height: height,
      width: double.infinity,
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Center(
                  child: _sizedFrame(
                    maxWidth: constraints.maxWidth,
                    maxHeight: constraints.maxHeight,
                    aspect: aspect,
                    path: shot.imagePath,
                    fit: BoxFit.cover,
                  ),
                );
              },
            ),
          ),
          if (showArrow)
            const SizedBox(
              width: 20,
              child: Center(
                child: Icon(
                  Icons.arrow_forward,
                  color: Colors.white24,
                  size: 16,
                ),
              ),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Center(
                  child: _sizedFrame(
                    maxWidth: constraints.maxWidth,
                    maxHeight: constraints.maxHeight,
                    aspect: aspect,
                    path: hasScan ? shot.scanImagePath : null,
                    fit: BoxFit.contain,
                    placeholder: true,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _sizedFrame({
    required double maxWidth,
    required double maxHeight,
    required double aspect,
    required String? path,
    required BoxFit fit,
    bool placeholder = false,
  }) {
    final ratio = aspect <= 0 ? 1.0 : aspect;
    var width = maxHeight * ratio;
    var height = maxHeight;
    if (width > maxWidth) {
      width = maxWidth;
      height = width / ratio;
    }
    return SizedBox(
      width: width,
      height: height,
      child: _frame(
        path: path,
        fit: fit,
        placeholder: placeholder,
      ),
    );
  }

  Widget _frame({
    required String? path,
    required BoxFit fit,
    bool placeholder = false,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ColoredBox(
        color: const Color(0xFF161616),
        child: path == null
            ? Center(
                child: placeholder
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_photo_alternate_outlined,
                            color: Colors.white24,
                            size: 22,
                          ),
                          SizedBox(height: 4),
                          Text(
                            'No scan',
                            style: TextStyle(
                              color: Colors.white24,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      )
                    : null,
              )
            : Image.file(
                File(path),
                fit: fit,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white24,
                    size: 22,
                  ),
                ),
              ),
      ),
    );
  }
}

/// Tiny label chip used next to album meta when a scan is paired.
class ScanChip extends StatelessWidget {
  const ScanChip({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x33221C0A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x55FFB300)),
      ),
      child: const Text(
        'Scan',
        style: TextStyle(
          color: _accent,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    );
  }
}
