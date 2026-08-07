import 'dart:math';

/// A film / sensor format used by the focal-length viewfinder.
class FilmFormat {
  const FilmFormat({
    required this.id,
    required this.label,
    required this.widthMm,
    required this.heightMm,
    required this.standardLensesMm,
    required this.defaultFocalMm,
  });

  final String id;
  final String label;

  /// Active image area in millimetres (landscape: width ≥ height).
  final double widthMm;
  final double heightMm;

  final List<double> standardLensesMm;
  final double defaultFocalMm;

  /// Width ÷ height of the frame.
  double get aspectRatio => widthMm / heightMm;

  double get diagonalMm => sqrt(widthMm * widthMm + heightMm * heightMm);

  bool get isSquare => (aspectRatio - 1.0).abs() < 0.01;

  /// 35 mm-equivalent focal length of a lens on this format (diagonal crop).
  double to35mmEquivalent(double focalMm) =>
      focalMm * FilmOptics.fullFrameDiagonalMm / diagonalMm;

  /// Full-frame 35 mm (36×24 mm).
  static const FilmFormat thirtyFive = FilmFormat(
    id: '36x24',
    label: '36×24',
    widthMm: 36,
    heightMm: 24,
    standardLensesMm: [24, 28, 35, 50, 85, 105, 135, 200],
    defaultFocalMm: 50,
  );

  /// 120 film 6×4.5 — nominal image area 56×41.5 mm.
  static const FilmFormat sixFourFive = FilmFormat(
    id: '645',
    label: '645',
    widthMm: 56,
    heightMm: 41.5,
    standardLensesMm: [45, 55, 75, 90, 120, 150, 210],
    defaultFocalMm: 75,
  );

  /// 120 film 6×6 — actual image gate ≈ 56×56 mm (not the full 60 mm film).
  static const FilmFormat sixBySix = FilmFormat(
    id: '6x6',
    label: '6×6',
    widthMm: 56,
    heightMm: 56,
    standardLensesMm: [40, 50, 60, 75, 80, 100, 120, 150, 180, 250],
    defaultFocalMm: 80,
  );

  static const List<FilmFormat> all = [thirtyFive, sixFourFive, sixBySix];

  static FilmFormat? byId(String? id) {
    if (id == null) return null;
    for (final f in all) {
      if (f.id == id) return f;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is FilmFormat && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Shared FOV / crop math for any [FilmFormat].
class FilmOptics {
  FilmOptics._();

  static const double fullFrameDiagonalMm = 43.266615;

  static double fieldOfViewRadians(double focalMm, double sideMm) {
    if (focalMm <= 0 || sideMm <= 0) return double.nan;
    return 2 * atan((sideMm / 2) / focalMm);
  }

  /// 35 mm-equivalent focal length from physical sensor size (diagonal FOV).
  static double equivalent35mmFromSensor({
    required double focalMm,
    required double sensorWidthMm,
    required double sensorHeightMm,
  }) {
    if (focalMm <= 0 || sensorWidthMm <= 0 || sensorHeightMm <= 0) {
      return double.nan;
    }
    final diagonal =
        sqrt(sensorWidthMm * sensorWidthMm + sensorHeightMm * sensorHeightMm);
    return focalMm * fullFrameDiagonalMm / diagonal;
  }

  static String formatFocal(double mm) {
    if (!mm.isFinite || mm <= 0) return '—';
    if ((mm - mm.round()).abs() < 0.05) return '${mm.round()} mm';
    return '${mm.toStringAsFixed(1)} mm';
  }

  /// Fits a viewfinder of [aspect] (width÷height) inside [bounds].
  static ({double width, double height}) fitAspect({
    required double maxWidth,
    required double maxHeight,
    required double aspect,
  }) {
    if (aspect <= 0 || maxWidth <= 0 || maxHeight <= 0) {
      return (width: maxWidth, height: maxHeight);
    }
    if (maxWidth / maxHeight > aspect) {
      return (width: maxHeight * aspect, height: maxHeight);
    }
    return (width: maxWidth, height: maxWidth / aspect);
  }

  /// Maps Camera2 landscape sensor size onto on-screen axes.
  ///
  /// When the preview is portrait-locked, the short sensor side is horizontal
  /// on screen and the long side is vertical.
  static ({double horizMm, double vertMm}) screenAxesFromSensor({
    required double sensorWidthMm,
    required double sensorHeightMm,
    bool previewPortrait = true,
  }) {
    final short = min(sensorWidthMm, sensorHeightMm);
    final long = max(sensorWidthMm, sensorHeightMm);
    if (previewPortrait) {
      return (horizMm: short, vertMm: long);
    }
    return (horizMm: long, vertMm: short);
  }

  /// Fraction of the phone's covered view to keep to match [simulatedFocalMm]
  /// on [format].
  ///
  /// Maps the physical sensor onto screen axes for the locked preview
  /// orientation, takes the centred strip that covers the film aspect (as
  /// `BoxFit.cover` does), then matches horizontal FOV.
  static double cropFraction({
    required FilmFormat format,
    required double phoneFocalMm,
    required double phoneSensorWidthMm,
    required double phoneSensorHeightMm,
    required double simulatedFocalMm,
    double zoom = 1.0,
    bool previewPortrait = true,
  }) {
    if (phoneFocalMm <= 0 ||
        phoneSensorWidthMm <= 0 ||
        phoneSensorHeightMm <= 0 ||
        simulatedFocalMm <= 0 ||
        zoom <= 0) {
      return 1.0;
    }

    final fPhone = phoneFocalMm * zoom;
    final screen = screenAxesFromSensor(
      sensorWidthMm: phoneSensorWidthMm,
      sensorHeightMm: phoneSensorHeightMm,
      previewPortrait: previewPortrait,
    );
    final phoneAspect = screen.horizMm / screen.vertMm;
    final filmAspect = format.aspectRatio;

    // Sensor region visible after covering the film aspect on screen.
    final double visibleHorizMm;
    if (phoneAspect > filmAspect) {
      // Screen relatively wider — height fills, sides cropped.
      visibleHorizMm = screen.vertMm * filmAspect;
    } else {
      visibleHorizMm = screen.horizMm;
    }

    final fovPhone = fieldOfViewRadians(fPhone, visibleHorizMm);
    final fovSim = fieldOfViewRadians(simulatedFocalMm, format.widthMm);
    if (!fovPhone.isFinite || !fovSim.isFinite || fovPhone <= 0) return 1.0;
    if (fovSim >= fovPhone) return 1.0;

    return (tan(fovSim / 2) / tan(fovPhone / 2)).clamp(0.05, 1.0);
  }

  /// Crop using 35 mm-equivalent focal lengths when sensor size is unknown.
  ///
  /// Matches the film's native horizontal FOV to the phone's horizontal FOV
  /// implied by a diagonal 35 mm-equivalent (assuming a typical 4:3 phone
  /// sensor, where width/diagonal ≈ 0.8).
  static double cropFractionFrom35mm({
    required FilmFormat format,
    required double phone35mmEquivalent,
    required double simulatedFocalMm,
    double zoom = 1.0,
  }) {
    if (phone35mmEquivalent <= 0 || simulatedFocalMm <= 0 || zoom <= 0) {
      return 1.0;
    }
    final phone = phone35mmEquivalent * zoom;
    // 4:3 sensor: width = 0.8 × diagonal. At diagonal-eq E, horizontal FOV
    // equals 2·atan((0.4 × 43.27) / E).
    const phoneWidthOverDiagonal = 0.8;
    final phoneWidthMm = fullFrameDiagonalMm * phoneWidthOverDiagonal;
    final fovPhone = fieldOfViewRadians(phone, phoneWidthMm);
    final fovSim =
        fieldOfViewRadians(simulatedFocalMm, format.widthMm);
    if (!fovPhone.isFinite || !fovSim.isFinite || fovPhone <= 0) return 1.0;
    if (fovSim >= fovPhone) return 1.0;

    return (tan(fovSim / 2) / tan(fovPhone / 2)).clamp(0.05, 1.0);
  }

  /// Maps a tap in the viewfinder (0..1) back into the cover-fitted preview
  /// (0..1) given the centre crop [fraction].
  static ({double x, double y}) mapViewfinderToPreview(
    double x,
    double y,
    double fraction,
  ) {
    final f = fraction.clamp(0.05, 1.0);
    return (x: 0.5 + (x - 0.5) * f, y: 0.5 + (y - 0.5) * f);
  }
}
