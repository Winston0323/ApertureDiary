import 'dart:math';
import 'dart:typed_data';

/// APEX / photographic exposure helpers.
///
/// EV (at ISO 100) relates aperture N, shutter t (seconds), and ISO S by:
///   EV = log2(N² / t) − log2(S / 100)
class ExposureMath {
  ExposureMath._();

  static const double ln2 = 0.6931471805599453;

  /// Linear reflectance a meter is calibrated to render as mid-tone.
  static const double middleGrey = 0.18;

  static double log2(double x) => log(x) / ln2;

  /// EV at ISO 100 that a camera's own exposure settings were metered for.
  ///
  /// A frame shot at these settings renders the metered subject as middle
  /// grey, so this is the EV of whatever the camera's AE aimed at.
  static double cameraEv100({
    required double aperture,
    required double shutterSeconds,
    required double iso,
  }) {
    if (aperture <= 0 || shutterSeconds <= 0 || iso <= 0) return double.nan;
    return log2(aperture * aperture / shutterSeconds) - log2(iso / 100.0);
  }

  /// EV at a sampled point, given the exposure the frame was shot at and the
  /// point's linear luminance (0..1, where [middleGrey] is a mid-tone).
  ///
  /// A point brighter than middle grey is that many stops above the EV the
  /// camera exposed for.
  static double sceneEv({
    required double cameraEv100,
    required double linearLuminance,
  }) {
    final l = linearLuminance.clamp(1e-6, 1.0);
    return cameraEv100 + log2(l / middleGrey);
  }

  /// sRGB electro-optical transfer function: encoded 0..1 → linear 0..1.
  ///
  /// Camera output is gamma-encoded; luminance must be linearized before it
  /// can be reasoned about in stops.
  static double srgbToLinear(double encoded) {
    final c = encoded.clamp(0.0, 1.0);
    if (c <= 0.04045) return c / 12.92;
    return pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  /// 256-entry lookup table for [srgbToLinear] over 8-bit values.
  static final Float64List srgbLut = Float64List.fromList(
    List<double>.generate(256, (i) => srgbToLinear(i / 255.0)),
  );

  /// Relative linear luminance (BT.709) from gamma-encoded 8-bit channels.
  static double linearLuminance8(int r, int g, int b) {
    return 0.2126 * srgbLut[r.clamp(0, 255)] +
        0.7152 * srgbLut[g.clamp(0, 255)] +
        0.0722 * srgbLut[b.clamp(0, 255)];
  }

  /// Shutter time in seconds for a given EV₁₀₀, aperture, and film ISO.
  static double shutterFromEv({
    required double ev100,
    required double aperture,
    required int iso,
  }) {
    final double n2 = aperture * aperture;
    final double isoFactor = iso / 100.0;
    return n2 / (pow(2.0, ev100) * isoFactor);
  }

  /// f-number for a given EV₁₀₀, shutter time (seconds), and film ISO.
  static double apertureFromEv({
    required double ev100,
    required double shutterSeconds,
    required int iso,
  }) {
    final double isoFactor = iso / 100.0;
    return sqrt(shutterSeconds * pow(2.0, ev100) * isoFactor);
  }

  /// Format shutter as a photographic fraction / seconds string.
  static String formatShutter(double seconds) {
    if (seconds <= 0 || seconds.isNaN || seconds.isInfinite) return '—';
    if (seconds >= 1.0) {
      if ((seconds - seconds.round()).abs() < 0.05) {
        return '${seconds.round()}"';
      }
      return '${seconds.toStringAsFixed(1)}"';
    }
    final double denom = 1.0 / seconds;
    if ((denom - denom.round()).abs() < 0.05 || denom >= 10) {
      return '1/${denom.round()}';
    }
    return '1/${denom.toStringAsFixed(1)}';
  }

  /// Format aperture as f/N.
  static String formatAperture(double n) {
    if (n <= 0 || n.isNaN || n.isInfinite) return '—';
    if (n < 10) return 'f/${n.toStringAsFixed(1)}';
    return 'f/${n.toStringAsFixed(0)}';
  }

  /// Signed EV difference, e.g. "+1.3 EV".
  static String formatStops(double stops) {
    final sign = stops >= 0 ? '+' : '−';
    return '$sign${stops.abs().toStringAsFixed(1)} EV';
  }

  /// Snap a continuous shutter to the nearest standard speed (seconds).
  static double snapShutter(double seconds) {
    if (seconds <= 0 || seconds.isNaN || seconds.isInfinite) {
      return standardShutters.first;
    }
    return _nearestLog(standardShutters, seconds);
  }

  /// Snap a continuous f-number to the nearest standard stop.
  static double snapAperture(double n) {
    if (n <= 0 || n.isNaN || n.isInfinite) return standardApertures.first;
    return _nearestLog(standardApertures, n);
  }

  /// Nearest entry in log space, so it snaps by stops rather than by
  /// arithmetic distance.
  static double _nearestLog(List<double> options, double value) {
    double best = options.first;
    double bestDiff = double.infinity;
    final target = log(value);
    for (final o in options) {
      final d = (log(o) - target).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = o;
      }
    }
    return best;
  }

  static const List<int> standardIsos = [
    25, 50, 64, 100, 125, 160, 200, 400, 800, 1600, 3200, 6400,
  ];

  static const List<double> standardApertures = [
    1.0, 1.2, 1.4, 1.8, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0, 22.0, 32.0,
  ];

  /// Shutter speeds in seconds (fast → slow).
  static const List<double> standardShutters = [
    1 / 8000,
    1 / 4000,
    1 / 2000,
    1 / 1000,
    1 / 500,
    1 / 250,
    1 / 125,
    1 / 60,
    1 / 30,
    1 / 15,
    1 / 8,
    1 / 4,
    1 / 2,
    1.0,
    2.0,
    4.0,
    8.0,
    15.0,
    30.0,
  ];
}

/// Which exposure factor the user last set by hand.
///
/// The opposite factor is what the calculator solves for: last-edited shutter
/// means solve aperture, and last-edited aperture means solve shutter.
enum LastEdited { shutter, aperture }
