import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'exposure.dart';

/// One observation for a tone-curve fit: how bright the preview rendered a
/// patch, and what exposure the camera used to get there.
@immutable
class ToneCurveSample {
  const ToneCurveSample({
    required this.encodedLuminance,
    required this.cameraEv100,
  });

  /// Gamma-encoded luminance the preview reported, 0..1.
  final double encodedLuminance;

  /// EV₁₀₀ the camera exposed at for that frame.
  final double cameraEv100;
}

/// The measured relationship between encoded preview luminance and true
/// linear luminance for one device.
///
/// The plain sRGB inversion assumes a pipeline nothing ships: phone ISPs use a
/// contrasty S-curve that crushes shadows and rolls off highlights, so
/// inverting with sRGB understates luminance by whole stops away from mid
/// grey. This holds the real curve, measured from an AE sweep.
///
/// Stored as knots in (encoded, log₂ linear) space because exposure reasoning
/// is logarithmic: interpolating there is interpolating in stops, which is
/// what makes a straight line between knots the right guess.
@immutable
class ToneCurve {
  const ToneCurve({
    required this.encoded,
    required this.log2Linear,
    required this.sceneEv100,
    this.recordedAt,
  });

  /// Strictly ascending encoded luminances, 0..1.
  final List<double> encoded;

  /// log₂ of the true linear luminance at each knot. Strictly ascending.
  ///
  /// Values above 0 are legitimate: a highlight can be brighter than diffuse
  /// white at the exposure it was measured under.
  final List<double> log2Linear;

  /// Scene EV₁₀₀ the fit resolved to. Provenance only — not used at runtime.
  final double sceneEv100;

  final DateTime? recordedAt;

  double get minEncoded => encoded.first;
  double get maxEncoded => encoded.last;

  /// Stops between the darkest and brightest knot — how much of the scene's
  /// range this curve can speak for.
  double get rangeInStops => log2Linear.last - log2Linear.first;

  bool coversEncoded(double value) =>
      value >= minEncoded && value <= maxEncoded;

  /// True linear luminance for an encoded value, or null outside the measured
  /// range.
  ///
  /// Returning null rather than extrapolating is deliberate: beyond the last
  /// knot the curve is in unmeasured rolloff, where a guess would be wrong by
  /// stops and there is no way to know by how much.
  double? linearFor(double value) {
    if (!value.isFinite || !coversEncoded(value)) return null;

    // Binary search for the bracketing knots.
    var lo = 0;
    var hi = encoded.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) ~/ 2;
      if (encoded[mid] <= value) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final span = encoded[hi] - encoded[lo];
    final t = span <= 0 ? 0.0 : (value - encoded[lo]) / span;
    final l2 = log2Linear[lo] + (log2Linear[hi] - log2Linear[lo]) * t;
    return math.pow(2.0, l2).toDouble();
  }

  /// Stops by which the plain sRGB inversion is wrong at [value].
  ///
  /// Positive means sRGB reads brighter than the truth.
  double? srgbErrorStops(double value) {
    final truth = linearFor(value);
    if (truth == null || truth <= 0) return null;
    final srgb = ExposureMath.srgbToLinear(value);
    if (srgb <= 0) return null;
    return ExposureMath.log2(srgb / truth);
  }

  /// Largest absolute sRGB error across the measured knots, in stops.
  double get worstSrgbErrorStops {
    var worst = 0.0;
    for (final e in encoded) {
      final err = srgbErrorStops(e);
      if (err != null && err.abs() > worst) worst = err.abs();
    }
    return worst;
  }

  /// Fits a curve from sweep observations.
  ///
  /// The scene is fixed across a sweep, so a single unknown scene EV ties
  /// every rung together:
  ///
  ///   `log₂(L) = (E + log₂(0.18)) − EV₁₀₀`
  ///
  /// That makes the *shape* fully determined by the data — only the absolute
  /// level needs pinning. It is anchored by declaring that whatever the
  /// pipeline renders at sRGB mid grey really is 18% reflectance, which is the
  /// convention the rest of the app already meters against.
  ///
  /// Returns null when the observations cannot describe a curve: too few
  /// points, or a response that is not monotone (which means the scene moved,
  /// or auto-exposure fought back during the sweep).
  static ToneCurve? fit(
    List<ToneCurveSample> samples, {
    double? anchorEncoded,
    double anchorLinear = ExposureMath.middleGrey,
    DateTime? recordedAt,
  }) {
    final anchor = anchorEncoded ?? ExposureMath.middleGreyEncoded;
    if (anchorLinear <= 0) return null;

    final usable = samples
        .where(
          (s) =>
              s.encodedLuminance.isFinite &&
              s.cameraEv100.isFinite &&
              s.encodedLuminance > 0 &&
              s.encodedLuminance < 1,
        )
        .toList()
      ..sort((a, b) => a.encodedLuminance.compareTo(b.encodedLuminance));

    if (usable.length < 3) return null;

    // Deduplicate encoded values; a repeated x has no defined slope.
    final encoded = <double>[];
    final negEv = <double>[];
    for (final s in usable) {
      if (encoded.isNotEmpty &&
          (s.encodedLuminance - encoded.last).abs() < 1e-4) {
        continue;
      }
      encoded.add(s.encodedLuminance);
      // Brighter patch at a lower metered EV means more light reached it, so
      // the relative log luminance runs opposite to the metered EV.
      negEv.add(-s.cameraEv100);
    }
    if (encoded.length < 3) return null;

    // A real tone curve is monotone: more light out for more light in. If the
    // data is not, something moved and the fit would be meaningless.
    for (var i = 1; i < negEv.length; i++) {
      if (negEv[i] <= negEv[i - 1]) return null;
    }

    // The anchor has to sit inside the measured range for the level to be
    // pinned by data rather than by extrapolation.
    if (anchor < encoded.first || anchor > encoded.last) return null;

    final anchorRelative = _interpolate(encoded, negEv, anchor);
    if (anchorRelative == null) return null;

    // Shift the relative curve so the anchor lands on the declared luminance.
    final offset = ExposureMath.log2(anchorLinear) - anchorRelative;
    final log2Linear = negEv.map((v) => v + offset).toList();

    // E = K − log₂(0.18), where K is the shifted curve's constant term.
    final sceneEv100 = offset - ExposureMath.log2(ExposureMath.middleGrey);

    return ToneCurve(
      encoded: encoded,
      log2Linear: log2Linear,
      sceneEv100: sceneEv100,
      recordedAt: recordedAt ?? DateTime.now(),
    );
  }

  static double? _interpolate(List<double> xs, List<double> ys, double x) {
    if (xs.length != ys.length || xs.length < 2) return null;
    if (x < xs.first || x > xs.last) return null;
    for (var i = 1; i < xs.length; i++) {
      if (x <= xs[i]) {
        final span = xs[i] - xs[i - 1];
        final t = span <= 0 ? 0.0 : (x - xs[i - 1]) / span;
        return ys[i - 1] + (ys[i] - ys[i - 1]) * t;
      }
    }
    return ys.last;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'encoded': encoded,
        'log2Linear': log2Linear,
        'sceneEv100': sceneEv100,
        'recordedAt': recordedAt?.toIso8601String(),
      };

  /// Rebuilds a curve from stored JSON, rejecting anything malformed.
  ///
  /// A corrupt curve would silently bias every reading, so validation here is
  /// strict rather than forgiving.
  static ToneCurve? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final encodedRaw = raw['encoded'];
    final logRaw = raw['log2Linear'];
    if (encodedRaw is! List || logRaw is! List) return null;
    if (encodedRaw.length != logRaw.length || encodedRaw.length < 3) {
      return null;
    }

    final encoded = <double>[];
    final log2Linear = <double>[];
    for (var i = 0; i < encodedRaw.length; i++) {
      final e = encodedRaw[i];
      final l = logRaw[i];
      if (e is! num || l is! num) return null;
      final ed = e.toDouble();
      final ld = l.toDouble();
      if (!ed.isFinite || !ld.isFinite) return null;
      if (ed < 0 || ed > 1) return null;
      if (encoded.isNotEmpty && ed <= encoded.last) return null;
      if (log2Linear.isNotEmpty && ld <= log2Linear.last) return null;
      encoded.add(ed);
      log2Linear.add(ld);
    }

    final scene = raw['sceneEv100'];
    final at = raw['recordedAt'];
    return ToneCurve(
      encoded: encoded,
      log2Linear: log2Linear,
      sceneEv100: scene is num && scene.toDouble().isFinite
          ? scene.toDouble()
          : double.nan,
      recordedAt: at is String ? DateTime.tryParse(at) : null,
    );
  }
}

/// Persists the measured tone curve across launches.
class ToneCurveStore {
  ToneCurveStore._();

  static const String _fileName = 'tone_curve.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<ToneCurve?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      return ToneCurve.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      // A missing or broken curve just means falling back to sRGB.
      return null;
    }
  }

  static Future<void> save(ToneCurve curve) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(curve.toJson()), flush: true);
    } catch (_) {
      // Ignore write failures.
    }
  }

  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Ignore.
    }
  }
}
