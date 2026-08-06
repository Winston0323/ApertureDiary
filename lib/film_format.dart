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

  /// 35 mm-equivalent focal length of a lens on this format.
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

  /// 120 film 6×6 — 60×60 mm.
  static const FilmFormat sixBySix = FilmFormat(
    id: '6x6',
    label: '6×6',
    widthMm: 60,
    heightMm: 60,
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

  /// Fraction of the phone's current covered view to keep in order to match
  /// [simulatedFocalMm] on [format].
  ///
  /// Uses the phone sensor's physical size when available: first take the
  /// centre strip of the sensor that has the film's aspect ratio (as
  /// `BoxFit.cover` does), then match horizontal FOV.
  static double cropFraction({
    required FilmFormat format,
    required double phoneFocalMm,
    required double phoneSensorWidthMm,
    required double phoneSensorHeightMm,
    required double simulatedFocalMm,
    double zoom = 1.0,
  }) {
    if (phoneFocalMm <= 0 ||
        phoneSensorWidthMm <= 0 ||
        phoneSensorHeightMm <= 0 ||
        simulatedFocalMm <= 0 ||
        zoom <= 0) {
      return 1.0;
    }

    final fPhone = phoneFocalMm * zoom;
    final phoneAspect = phoneSensorWidthMm / phoneSensorHeightMm;
    final filmAspect = format.aspectRatio;

    // Sensor region visible after covering the film aspect.
    final double visibleWidthMm;
    if (phoneAspect > filmAspect) {
      // Phone relatively wider — height fills, sides cropped.
      visibleWidthMm = phoneSensorHeightMm * filmAspect;
    } else {
      visibleWidthMm = phoneSensorWidthMm;
    }

    final fovPhone = fieldOfViewRadians(fPhone, visibleWidthMm);
    final fovSim = fieldOfViewRadians(simulatedFocalMm, format.widthMm);
    if (!fovPhone.isFinite || !fovSim.isFinite || fovPhone <= 0) return 1.0;
    if (fovSim >= fovPhone) return 1.0;

    return (tan(fovSim / 2) / tan(fovPhone / 2)).clamp(0.05, 1.0);
  }

  /// Crop using 35 mm-equivalent focal lengths when sensor size is unknown.
  static double cropFractionFrom35mm({
    required FilmFormat format,
    required double phone35mmEquivalent,
    required double simulatedFocalMm,
    double zoom = 1.0,
  }) {
    if (phone35mmEquivalent <= 0 || simulatedFocalMm <= 0 || zoom <= 0) {
      return 1.0;
    }
    final sim35 = format.to35mmEquivalent(simulatedFocalMm);
    final phone = phone35mmEquivalent * zoom;
    if (sim35 <= phone) return 1.0;
    return (phone / sim35).clamp(0.05, 1.0);
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
