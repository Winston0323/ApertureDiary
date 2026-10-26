import 'package:flutter/foundation.dart';

import 'exposure.dart';

/// The exposure a trusted camera settled on for a scene — what its display
/// shows, not an EV.
///
/// A camera in aperture priority reads out an f-number, a shutter speed and an
/// ISO. Those three numbers already contain the scene brightness as that camera
/// measures it, so they are all the user needs to type to calibrate against it.
@immutable
class ReferenceExposure {
  const ReferenceExposure({
    required this.aperture,
    required this.shutterSeconds,
    required this.iso,
  });

  final double aperture;
  final double shutterSeconds;
  final double iso;

  static const double minAperture = 0.7;
  static const double maxAperture = 90;
  static const double minShutterSeconds = 1 / 32000;
  static const double maxShutterSeconds = 3600;
  static const double minIso = 6;
  static const double maxIso = 409600;

  bool get isValid =>
      aperture.isFinite &&
      aperture >= minAperture &&
      aperture <= maxAperture &&
      shutterSeconds.isFinite &&
      shutterSeconds >= minShutterSeconds &&
      shutterSeconds <= maxShutterSeconds &&
      iso.isFinite &&
      iso >= minIso &&
      iso <= maxIso;

  /// Scene brightness at ISO 100 that those settings correspond to.
  double get ev100 => ExposureMath.cameraEv100(
        aperture: aperture,
        shutterSeconds: shutterSeconds,
        iso: iso,
      );

  /// Parses an f-number such as `5.6`, `f5.6`, `f/5.6` or `F/5,6`.
  static double? parseAperture(String text) {
    var t = text.trim().toLowerCase().replaceAll(',', '.');
    if (t.startsWith('f')) t = t.substring(1);
    t = t.replaceFirst(RegExp(r'^[\s/:]+'), '');
    final value = double.tryParse(t);
    if (value == null || !value.isFinite) return null;
    if (value < minAperture || value > maxAperture) return null;
    return value;
  }

  /// Parses a shutter speed such as `1/125`, `1/125s`, `0.5`, `2`, `2"` or
  /// `30"`.
  ///
  /// A bare number is read as seconds. A bare 125 is therefore rejected rather
  /// than guessed at: it could be 1/125 s or two minutes, and a calibration
  /// built on the wrong one is wrong by seven stops.
  static double? parseShutter(String text) {
    var t = text.trim().toLowerCase().replaceAll(',', '.');
    t = t
        .replaceAll('"', '')
        .replaceAll('″', '')
        .replaceAll('”', '')
        .replaceAll('sec', '')
        .replaceAll('s', '')
        .trim();
    if (t.isEmpty) return null;

    double? seconds;
    if (t.contains('/')) {
      final parts = t.split('/');
      if (parts.length != 2) return null;
      final n = double.tryParse(parts[0].trim());
      final d = double.tryParse(parts[1].trim());
      if (n == null || d == null || d == 0) return null;
      seconds = n / d;
    } else {
      seconds = double.tryParse(t);
      // Bare numbers above a minute are almost certainly a missing "1/".
      if (seconds != null && seconds > 60) return null;
    }

    if (seconds == null || !seconds.isFinite) return null;
    if (seconds < minShutterSeconds || seconds > maxShutterSeconds) return null;
    return seconds;
  }

  /// Parses an ISO such as `400` or `ISO 400`.
  static double? parseIso(String text) {
    final t = text.trim().toLowerCase().replaceFirst('iso', '').trim();
    final value = double.tryParse(t.replaceAll(',', '.'));
    if (value == null || !value.isFinite) return null;
    if (value < minIso || value > maxIso) return null;
    return value;
  }

  @override
  String toString() =>
      '${ExposureMath.formatAperture(aperture)}  '
      '${ExposureMath.formatShutter(shutterSeconds)}  ISO ${iso.round()}';
}
