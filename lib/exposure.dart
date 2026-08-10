import 'dart:math';
import 'dart:typed_data';

/// APEX / photographic exposure helpers.
///
/// Two EV conventions are used:
/// - **EV₁₀₀** — ISO-normalized scene brightness:
///   `EV₁₀₀ = log2(N² / t) − log2(S / 100)`
/// - **Lens EV** (Hasselblad / Compur orange scale) — shutter×aperture only:
///   `EV_lens = Av + Tv = log2(N² / t)`
///   Set that number on the lens for the film ISO already dialled on the meter.
class ExposureMath {
  ExposureMath._();

  static const double ln2 = 0.6931471805599453;

  /// Linear reflectance a meter is calibrated to render as mid-tone.
  static const double middleGrey = 0.18;

  static double log2(double x) => log(x) / ln2;

  /// Hasselblad-style lens EV for a shutter/aperture pair: `log2(N² / t)`.
  ///
  /// Matches the orange EV scale beside the shutter ring (ISO is not in this
  /// number — it was already applied when the meter chose the EV).
  static double lensEv({
    required double aperture,
    required double shutterSeconds,
  }) {
    if (aperture <= 0 || shutterSeconds <= 0) return double.nan;
    return log2(aperture * aperture / shutterSeconds);
  }

  /// Convert ISO-normalized EV₁₀₀ → lens EV at film [iso].
  static double lensEvFromEv100({
    required double ev100,
    required int iso,
  }) {
    if (iso <= 0) return double.nan;
    return ev100 + log2(iso / 100.0);
  }

  /// Convert Hasselblad lens EV → EV₁₀₀ at film [iso].
  static double ev100FromLensEv({
    required double lensEv,
    required int iso,
  }) {
    if (iso <= 0) return double.nan;
    return lensEv - log2(iso / 100.0);
  }

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
    return lensEv(aperture: aperture, shutterSeconds: shutterSeconds) -
        log2(iso / 100.0);
  }

  /// Scene EV₁₀₀ at a sampled point, given the exposure the frame was shot at
  /// and the point's linear luminance (0..1, where [middleGrey] is mid-tone).
  ///
  /// Convert with [lensEvFromEv100] for the Hasselblad lens-scale readout at
  /// the working film ISO.
  static double sceneEv({
    required double cameraEv100,
    required double linearLuminance,
  }) {
    final l = linearLuminance.clamp(1e-6, 1.0);
    return cameraEv100 + log2(l / middleGrey);
  }

  /// Shutter for a Hasselblad lens EV and aperture (`t = N² / 2^EV`).
  static double shutterFromLensEv({
    required double lensEv,
    required double aperture,
  }) {
    final double n2 = aperture * aperture;
    return n2 / pow(2.0, lensEv);
  }

  /// f-number for a Hasselblad lens EV and shutter (`N = √(t · 2^EV)`).
  static double apertureFromLensEv({
    required double lensEv,
    required double shutterSeconds,
  }) {
    return sqrt(shutterSeconds * pow(2.0, lensEv));
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
  ///
  /// Equivalent to [shutterFromLensEv] after [lensEvFromEv100].
  static double shutterFromEv({
    required double ev100,
    required double aperture,
    required int iso,
  }) {
    return shutterFromLensEv(
      lensEv: lensEvFromEv100(ev100: ev100, iso: iso),
      aperture: aperture,
    );
  }

  /// f-number for a given EV₁₀₀, shutter time (seconds), and film ISO.
  static double apertureFromEv({
    required double ev100,
    required double shutterSeconds,
    required int iso,
  }) {
    return apertureFromLensEv(
      lensEv: lensEvFromEv100(ev100: ev100, iso: iso),
      shutterSeconds: shutterSeconds,
    );
  }

  /// Sentinel for bulb (B) — not a timed exposure.
  static const double bulbShutter = -1;

  static bool isBulb(double seconds) => seconds == bulbShutter;

  /// Format shutter as a photographic fraction / seconds string, or `B`.
  ///
  /// Long bulb holds use minutes (`2'`) and hours (`1.5h`) with no upper cap.
  static String formatShutter(double seconds) {
    if (isBulb(seconds)) return 'B';
    if (seconds <= 0 || seconds.isNaN || seconds.isInfinite) return '—';
    if (seconds >= 3600) {
      final hours = seconds / 3600.0;
      if ((hours - hours.round()).abs() < 0.05) return '${hours.round()}h';
      return '${hours.toStringAsFixed(1)}h';
    }
    if (seconds >= 60) {
      final mins = seconds / 60.0;
      if ((mins - mins.round()).abs() < 0.05) return "${mins.round()}'";
      final whole = seconds ~/ 60;
      final secs = (seconds - whole * 60).round().clamp(0, 59);
      if (secs == 0) return "$whole'";
      return "$whole'$secs\"";
    }
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

  /// Snap a continuous shutter to the nearest timed speed (seconds).
  ///
  /// [options] may include [bulbShutter]; bulb is ignored for snapping.
  ///
  /// When [allowUnlimited] is true and [seconds] is slower than the slowest
  /// timed option, continues on a 1-stop grid with no upper bound (bulb holds).
  static double snapShutter(
    double seconds, {
    List<double>? options,
    bool allowUnlimited = false,
  }) {
    final timed = (options ?? standardShutters).where((s) => s > 0).toList();
    if (timed.isEmpty) return standardShutters.first;
    if (seconds <= 0 || seconds.isNaN || seconds.isInfinite) {
      return timed.first;
    }
    final slowest = timed.reduce((a, b) => a > b ? a : b);
    if (allowUnlimited && seconds > slowest * (1 + 1e-9)) {
      return _snapUnlimitedLong(seconds, from: slowest);
    }
    return _nearestLog(timed, seconds);
  }

  /// 1-stop grid from [from] upward: 30″ → 60″ → 120″ → … with no ceiling.
  static double _snapUnlimitedLong(double seconds, {required double from}) {
    if (from <= 0) from = 30;
    final k = (log(seconds / from) / ln2).round();
    return from * pow(2.0, k < 0 ? 0 : k);
  }

  /// Snap a continuous f-number to the nearest stop in [options].
  static double snapAperture(double n, {List<double>? options}) {
    final opts = options ?? standardApertures;
    if (opts.isEmpty) return standardApertures.first;
    if (n <= 0 || n.isNaN || n.isInfinite) return opts.first;
    return _nearestLog(opts, n);
  }

  /// Standard apertures from widest ([maxAperture]) to smallest ([minAperture]).
  ///
  /// Non-standard ends such as f/3.5 are inserted so they appear on the dial.
  static List<double> aperturesInRange({
    double? maxAperture,
    double? minAperture,
  }) {
    var list = List<double>.from(standardApertures);
    void ensure(double? n) {
      if (n == null || n <= 0 || n.isNaN || n.isInfinite) return;
      if (list.any((a) => (a - n).abs() < 1e-6)) return;
      list.add(n);
    }

    ensure(maxAperture);
    ensure(minAperture);
    list.sort();

    if (maxAperture != null && maxAperture > 0) {
      list = list.where((n) => n + 1e-9 >= maxAperture).toList();
    }
    if (minAperture != null && minAperture > 0) {
      list = list.where((n) => n - 1e-9 <= minAperture).toList();
    }
    return list.isEmpty ? List<double>.from(standardApertures) : list;
  }

  /// Timed shutters from [fastest] (smallest seconds) to [slowest], optionally + B.
  ///
  /// [slowest] is the marked timed floor. With bulb, longer standard speeds
  /// (past 1″ / past [slowest]) stay available as suggested hold times, then B.
  static List<double> shuttersInRange({
    required double fastest,
    required double slowest,
    bool includeBulb = false,
  }) {
    final lo = fastest <= slowest ? fastest : slowest;
    final hi = fastest <= slowest ? slowest : fastest;
    var list = standardShutters
        .where((s) => s + 1e-12 >= lo && s - 1e-12 <= hi)
        .toList();
    if (includeBulb) {
      // Marked slowest is a reference — bulb means longer timed suggestions OK.
      final longer = standardShutters.where((s) => s > hi + 1e-12).toList();
      if (longer.isNotEmpty) list = [...list, ...longer];
    }
    final out = list.isEmpty ? List<double>.from(standardShutters) : list;
    if (includeBulb) return [...out, bulbShutter];
    return out;
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
    25, 50, 64, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1600, 3200,
    6400,
  ];

  /// Nearest standard ISO (log space).
  static int snapIso(double iso) {
    if (iso <= 0 || iso.isNaN || iso.isInfinite) return standardIsos.first;
    return _nearestLog(
      standardIsos.map((e) => e.toDouble()).toList(),
      iso,
    ).round();
  }

  /// Kodak-style EI under daylight with a Wratten 85 (−⅔ stop).
  ///
  /// Example: Vision3 500T → 320; CineStill 800T → 500.
  static int eiWithWratten85(int tungstenIso) {
    if (tungstenIso <= 0) return tungstenIso;
    return snapIso(tungstenIso / pow(2.0, 2.0 / 3.0));
  }

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
