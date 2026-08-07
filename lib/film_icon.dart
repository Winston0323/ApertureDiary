import 'package:flutter/material.dart';

const Color _accent = Color(0xFFFFB300);

/// Film-box thumbnail with optional format badge and a label fallback.
class FilmIcon extends StatelessWidget {
  const FilmIcon({
    super.key,
    this.asset,
    this.fallbackLabel,
    this.formatLabel,
    this.size = 52,
  });

  /// Square icon that expands to fill its parent (use inside [AspectRatio] /
  /// stretched layout).
  const FilmIcon.fill({
    super.key,
    this.asset,
    this.fallbackLabel,
    this.formatLabel,
  }) : size = null;

  final String? asset;
  final String? fallbackLabel;

  /// e.g. `135` / `120` shown on the icon corner.
  final String? formatLabel;

  /// Fixed square size. Null means fill the parent constraints.
  final double? size;

  @override
  Widget build(BuildContext context) {
    final side = size;
    final badgeSize = side ?? 72;
    final child = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: asset != null
                ? Image.asset(
                    asset!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _fallback(badgeSize),
                  )
                : _fallback(badgeSize),
          ),
        ),
        if (formatLabel != null)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: const BoxDecoration(
                color: Color(0xE60A0A0A),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(6),
                  bottomRight: Radius.circular(10),
                ),
              ),
              child: Text(
                formatLabel!,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: (badgeSize * 0.18).clamp(10.0, 16.0),
                  height: 1.1,
                ),
              ),
            ),
          ),
      ],
    );

    if (side == null) {
      return child;
    }
    return SizedBox(width: side, height: side, child: child);
  }

  Widget _fallback(double side) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF221C0A),
        border: Border.all(color: const Color(0x55FFB300)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        fallbackLabel ?? '?',
        style: TextStyle(
          color: _accent,
          fontWeight: FontWeight.w800,
          fontSize: side * 0.28,
        ),
      ),
    );
  }
}
