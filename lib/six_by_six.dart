import 'dart:math';

/// Medium-format 6×6 (60×60 mm) focal-length viewfinder math.
///
/// A phone lens sees a certain field of view. To simulate a lens of focal
/// length [simulatedFocalMm] on 6×6, keep only the centre fraction of that
/// FOV whose angle matches the 6×6 lens:
///
/// ```
/// FOV = 2 · atan(filmSide / (2 · f))
/// crop = tan(FOV_sim / 2) / tan(FOV_phone / 2)
/// ```
class SixBySix {
  SixBySix._();

  /// Active image area on 120 film in a 6×6 camera, in millimetres.
  static const double filmSideMm = 60.0;

  /// Full-frame (36×24) diagonal, used when converting via 35 mm equivalents.
  static const double fullFrameDiagonalMm = 43.266615;

  /// 6×6 diagonal = √(60² + 60²).
  static const double filmDiagonalMm = 84.852814;

  /// Common 6×6 lenses, wide → tele.
  static const List<double> standardLensesMm = [
    40,
    50,
    60,
    75,
    80,
    100,
    120,
    150,
    180,
    250,
  ];

  /// Default "normal" lens for 6×6 (~50 mm equivalent on 35 mm).
  static const double defaultFocalMm = 80;

  /// 35 mm-equivalent focal length of a 6×6 lens.
  static double to35mmEquivalent(double focalMm) =>
      focalMm * fullFrameDiagonalMm / filmDiagonalMm;

  /// Horizontal/vertical FOV for a square film of [sideMm] at [focalMm].
  static double fieldOfViewRadians(double focalMm, {double sideMm = filmSideMm}) {
    if (focalMm <= 0 || sideMm <= 0) return double.nan;
    return 2 * atan((sideMm / 2) / focalMm);
  }

  /// Fraction of the phone's current view to keep in order to match
  /// [simulatedFocalMm] on 6×6.
  ///
  /// [phoneFocalMm] and [phoneSensorWidthMm] are the physical values for the
  /// dimension that maps onto the square viewfinder side. [zoom] is the camera
  /// zoom already applied to the preview (≥ 1).
  ///
  /// Returns 1.0 when the phone is already narrower than the simulation.
  static double cropFraction({
    required double phoneFocalMm,
    required double phoneSensorWidthMm,
    required double simulatedFocalMm,
    double zoom = 1.0,
  }) {
    if (phoneFocalMm <= 0 ||
        phoneSensorWidthMm <= 0 ||
        simulatedFocalMm <= 0 ||
        zoom <= 0) {
      return 1.0;
    }

    final effectivePhoneFocal = phoneFocalMm * zoom;
    final fovPhone = fieldOfViewRadians(
      effectivePhoneFocal,
      sideMm: phoneSensorWidthMm,
    );
    final fovSim = fieldOfViewRadians(simulatedFocalMm);
    if (!fovPhone.isFinite || !fovSim.isFinite || fovPhone <= 0) return 1.0;
    if (fovSim >= fovPhone) return 1.0;

    final fraction = tan(fovSim / 2) / tan(fovPhone / 2);
    return fraction.clamp(0.05, 1.0);
  }

  /// Same crop using 35 mm-equivalent focal lengths (when sensor size is unknown).
  static double cropFractionFrom35mm({
    required double phone35mmEquivalent,
    required double simulatedFocalMm,
    double zoom = 1.0,
  }) {
    if (phone35mmEquivalent <= 0 || simulatedFocalMm <= 0 || zoom <= 0) {
      return 1.0;
    }
    final sim35 = to35mmEquivalent(simulatedFocalMm);
    final phone = phone35mmEquivalent * zoom;
    if (sim35 <= phone) return 1.0;
    return (phone / sim35).clamp(0.05, 1.0);
  }

  /// Maps a tap in the square viewfinder (0..1) back into the full preview
  /// (0..1) given the centre crop [fraction].
  static ({double x, double y}) mapViewfinderToPreview(
    double x,
    double y,
    double fraction,
  ) {
    final f = fraction.clamp(0.05, 1.0);
    return (x: 0.5 + (x - 0.5) * f, y: 0.5 + (y - 0.5) * f);
  }

  static String formatFocal(double mm) {
    if (!mm.isFinite || mm <= 0) return '—';
    if ((mm - mm.round()).abs() < 0.05) return '${mm.round()} mm';
    return '${mm.toStringAsFixed(1)} mm';
  }
}
