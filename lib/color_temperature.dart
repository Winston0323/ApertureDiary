import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'exposure.dart';
import 'tone_curve.dart';

/// A point on the CIE 1960 uniform chromaticity scale.
///
/// CCT is defined as the temperature of the black body closest to a colour, and
/// "closest" is only meaningful in a space where equal distances mean equal
/// perceptual differences. CIE 1960 uv is the space that definition was written
/// against, so the search happens here rather than in xy.
@immutable
class Uv {
  const Uv(this.u, this.v);

  final double u;
  final double v;

  double distanceTo(Uv other) {
    final du = u - other.u;
    final dv = v - other.v;
    return math.sqrt(du * du + dv * dv);
  }

  static Uv? fromXy(double x, double y) {
    final denom = -2 * x + 12 * y + 3;
    if (denom.abs() < 1e-9) return null;
    return Uv(4 * x / denom, 6 * y / denom);
  }
}

/// How much the measured colour can be trusted as an illuminant temperature.
enum CctConfidence {
  /// Sits within a hair of the black-body locus — an incandescent, halogen, or
  /// daylight source, or a genuinely neutral surface under one.
  high,

  /// Measurably off the locus. Fluorescent and many LED sources live here, as
  /// do faintly tinted surfaces. The number is indicative, not a measurement.
  low,
}

/// A correlated colour temperature with the evidence for it.
@immutable
class ColorTemperature {
  const ColorTemperature({
    required this.kelvin,
    required this.duv,
    required this.confidence,
    required this.atSearchLimit,
  });

  final double kelvin;

  /// Signed distance from the black-body locus in CIE 1960 uv.
  ///
  /// Positive is above the locus (greener), negative below (pinker). Daylight
  /// runs about +0.003; fluorescent tubes reach +0.01 and beyond. Far from zero
  /// the colour is simply not something a temperature describes.
  final double duv;

  final CctConfidence confidence;

  /// True when the best match landed on the end of the searched range, so the
  /// real temperature may lie outside it.
  final bool atSearchLimit;

  /// Rounded to the nearest 50 K, which is finer than the measurement
  /// justifies but matches how film filtration is discussed.
  int get roundedKelvin => (kelvin / 50).round() * 50;

  @override
  String toString() =>
      '${roundedKelvin}K (Duv ${duv >= 0 ? '+' : ''}${duv.toStringAsFixed(4)}, '
      '${confidence.name})';
}

/// Correlated colour temperature from a camera patch.
///
/// ## What this can and cannot measure
///
/// Auto white balance exists to make the scene render neutral, so by the time
/// pixels reach here the illuminant's colour has largely been divided out —
/// the same problem auto-exposure poses for EV. A white wall under tungsten
/// comes back neutral, which is to say it comes back as daylight.
///
/// The `camera` plugin exposes no white-balance control and no access to the
/// AWB gains, so there is no way to undo this from Dart. What is left is the
/// residual cast the camera did not remove, which tracks the illuminant
/// directionally but not absolutely. [WhiteBalanceReference] exists to pin the
/// absolute level with one measurement against a known light.
///
/// Within those limits the arithmetic here is exact: the locus search is
/// accurate to a few Kelvin where McCamy's polynomial drifts by hundreds, and
/// colours that no temperature describes are rejected instead of being given a
/// number.
class ColorTemperatureMath {
  ColorTemperatureMath._();

  /// Range the black-body approximation is valid over.
  static const double minKelvin = 1667;
  static const double maxKelvin = 25000;

  /// Beyond this distance from the locus, a temperature says nothing useful —
  /// the patch is a coloured object, not a white surface under a warm or cool
  /// light.
  static const double maxMeaningfulDuv = 0.05;

  /// Inside this distance the source is close enough to a black body (or to
  /// the daylight locus) for the temperature to be a real measurement.
  static const double highConfidenceDuv = 0.006;

  /// A channel at or above this is clipped; its ratio to the others is no
  /// longer the scene's, so the chromaticity is fiction.
  static const int clippedChannel = 250;

  /// Below this the brightest channel is buried in sensor noise.
  static const int minBrightestChannel = 16;

  /// Resolution of the coarse locus table. Bracketing is all it has to do —
  /// the ternary refinement supplies the precision.
  static const int _tableSize = 200;

  /// Black-body chromaticities, log-spaced over [minKelvin]…[maxKelvin].
  ///
  /// Built once: a per-frame rebuild would dominate the cost of the search.
  static final List<double> _tableKelvin = List<double>.generate(
    _tableSize,
    (i) => minKelvin *
        math.pow(maxKelvin / minKelvin, i / (_tableSize - 1)).toDouble(),
  );

  static final List<Uv> _tableUv =
      _tableKelvin.map((t) => planckianUv(t)!).toList(growable: false);

  /// Black-body chromaticity in CIE 1931 xy, by Kim et al.'s cubic fit.
  ///
  /// Accurate to a few Kelvin across the whole range, and cheap enough to run
  /// inside a search loop — evaluating Planck's law against colour matching
  /// functions would need a 95-entry table per call for no useful gain.
  static ({double x, double y})? planckianXy(double kelvin) {
    if (!kelvin.isFinite || kelvin < minKelvin || kelvin > maxKelvin) {
      return null;
    }
    final t = kelvin;
    final t2 = t * t;
    final t3 = t2 * t;

    final double x;
    if (t <= 4000) {
      x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910;
    } else {
      x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390;
    }

    final x2 = x * x;
    final x3 = x2 * x;

    final double y;
    if (t <= 2222) {
      y = -1.1063814 * x3 -
          1.34811020 * x2 +
          2.18555832 * x -
          0.20219683;
    } else if (t <= 4000) {
      y = -0.9549476 * x3 -
          1.37418593 * x2 +
          2.09137015 * x -
          0.16748867;
    } else {
      y = 3.0817580 * x3 -
          5.87338670 * x2 +
          3.75112997 * x -
          0.37001483;
    }

    return (x: x, y: y);
  }

  static Uv? planckianUv(double kelvin) {
    final xy = planckianXy(kelvin);
    if (xy == null) return null;
    return Uv.fromXy(xy.x, xy.y);
  }

  /// Finds the black-body temperature closest to [sample].
  ///
  /// Coarse table lookup brackets the minimum, then a ternary search closes on
  /// it. The distance function is smooth and locally unimodal, so ternary
  /// search converges reliably — and unlike the parabolic shortcut it cannot
  /// be thrown off by an unlucky bracket.
  static ColorTemperature? fromUv(Uv sample) {
    if (!sample.u.isFinite || !sample.v.isFinite) return null;

    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < _tableSize; i++) {
      final d = sample.distanceTo(_tableUv[i]);
      if (d < bestDistance) {
        bestDistance = d;
        bestIndex = i;
      }
    }

    final atSearchLimit = bestIndex == 0 || bestIndex == _tableSize - 1;

    var lo = _tableKelvin[bestIndex == 0 ? 0 : bestIndex - 1];
    var hi = _tableKelvin[
        bestIndex == _tableSize - 1 ? _tableSize - 1 : bestIndex + 1];

    // ~60 halvings of the bracket: far more than the fit's own accuracy.
    for (var i = 0; i < 60 && hi - lo > 1e-4; i++) {
      final third = (hi - lo) / 3;
      final a = lo + third;
      final b = hi - third;
      final da = _distanceAt(sample, a);
      final db = _distanceAt(sample, b);
      if (da < db) {
        hi = b;
      } else {
        lo = a;
      }
    }

    final kelvin = (lo + hi) / 2;
    final locus = planckianUv(kelvin);
    if (locus == null) return null;

    final distance = sample.distanceTo(locus);
    // Above the locus is the greener side; this is the sign convention Duv is
    // quoted with, and it puts daylight at about +0.003.
    final duv = sample.v >= locus.v ? distance : -distance;

    if (distance > maxMeaningfulDuv) return null;

    final confident = distance <= highConfidenceDuv && !atSearchLimit;

    return ColorTemperature(
      kelvin: kelvin,
      duv: duv,
      confidence: confident ? CctConfidence.high : CctConfidence.low,
      atSearchLimit: atSearchLimit,
    );
  }

  static double _distanceAt(Uv sample, double kelvin) {
    final locus = planckianUv(kelvin);
    if (locus == null) return double.infinity;
    return sample.distanceTo(locus);
  }

  /// CCT from gamma-encoded 8-bit channels.
  ///
  /// [curve] linearizes the channels when the device's real response has been
  /// measured; it is used for all three channels or none, since mixing two
  /// different inversions would distort the very ratios being measured.
  /// [reference] removes the camera's white-balance bias when one has been
  /// established.
  static ColorTemperature? fromRgb8(
    int r,
    int g,
    int b, {
    ToneCurve? curve,
    WhiteBalanceReference? reference,
  }) {
    final rc = r.clamp(0, 255);
    final gc = g.clamp(0, 255);
    final bc = b.clamp(0, 255);

    // A clipped channel has lost its ratio to the others for good.
    if (rc >= clippedChannel || gc >= clippedChannel || bc >= clippedChannel) {
      return null;
    }
    if (math.max(rc, math.max(gc, bc)) < minBrightestChannel) return null;

    var rl = _linearize(rc, curve);
    var gl = _linearize(gc, curve);
    var bl = _linearize(bc, curve);
    if (rl == null || gl == null || bl == null) {
      rl = ExposureMath.srgbLut[rc];
      gl = ExposureMath.srgbLut[gc];
      bl = ExposureMath.srgbLut[bc];
    }

    if (reference != null) {
      rl *= reference.gainR;
      bl *= reference.gainB;
    }

    return fromLinearRgb(rl, gl, bl);
  }

  /// CCT from linear RGB in sRGB primaries.
  static ColorTemperature? fromLinearRgb(double r, double g, double b) {
    if (!r.isFinite || !g.isFinite || !b.isFinite) return null;
    if (r < 0 || g < 0 || b < 0) return null;

    // sRGB primaries, D65 white.
    final x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
    final y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
    final z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;

    final sum = x + y + z;
    if (sum < 1e-9) return null;

    final sample = Uv.fromXy(x / sum, y / sum);
    if (sample == null) return null;
    return fromUv(sample);
  }

  /// Uses the measured curve only when it covers all three channels, so the
  /// three are always inverted the same way.
  static double? _linearize(int channel, ToneCurve? curve) {
    if (curve == null) return null;
    return curve.linearFor(channel / 255.0);
  }

  /// Linear sRGB of the black body at [kelvin], normalised to G = 1.
  ///
  /// Used to work out what a neutral surface under a known light should look
  /// like, which is what makes a white-balance reference possible.
  static ({double r, double g, double b})? linearRgbForKelvin(double kelvin) {
    final xy = planckianXy(kelvin);
    if (xy == null) return null;
    if (xy.y.abs() < 1e-9) return null;

    // Unit luminance at the target chromaticity.
    final x = xy.x / xy.y;
    const y = 1.0;
    final z = (1 - xy.x - xy.y) / xy.y;

    // Inverse of the sRGB primaries matrix above.
    final r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    final g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    final b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;

    if (g.abs() < 1e-9) return null;
    // Negative components mean the temperature is outside the sRGB gamut; the
    // ratios are still the right target even so.
    return (r: r / g, g: 1.0, b: b / g);
  }
}

/// Von Kries gains that undo the camera's white-balance bias.
///
/// Auto white balance has already divided out most of the illuminant, and the
/// plugin gives no way to read what it divided by. Measuring one neutral
/// surface under a light of known temperature pins that unknown down: the gap
/// between what the camera reported and what the light should have produced is
/// the bias, and it is stable enough to reuse.
///
/// Held as channel gains rather than as a shift in uv, because the bias arises
/// as a per-channel gain in the camera and correcting it in the same form is
/// what keeps it valid across the range.
@immutable
class WhiteBalanceReference {
  const WhiteBalanceReference({
    required this.gainR,
    required this.gainB,
    required this.referenceKelvin,
    this.recordedAt,
  });

  final double gainR;
  final double gainB;

  /// Temperature the user declared the reference light to be.
  final double referenceKelvin;

  final DateTime? recordedAt;

  /// Stops of correction being applied, as a rough magnitude for display.
  double get strengthStops {
    final r = ExposureMath.log2(gainR).abs();
    final b = ExposureMath.log2(gainB).abs();
    return math.max(r, b);
  }

  /// Derives gains from a neutral patch shot under a light of known
  /// temperature.
  ///
  /// Returns null when the patch is unusable, or when the correction comes out
  /// so large that the patch was probably not neutral after all — a bad
  /// reference is worse than none, since it biases every later reading.
  static WhiteBalanceReference? fromNeutralPatch({
    required int r,
    required int g,
    required int b,
    required double kelvin,
    ToneCurve? curve,
    DateTime? recordedAt,
  }) {
    final rc = r.clamp(0, 255);
    final gc = g.clamp(0, 255);
    final bc = b.clamp(0, 255);

    if (rc >= ColorTemperatureMath.clippedChannel ||
        gc >= ColorTemperatureMath.clippedChannel ||
        bc >= ColorTemperatureMath.clippedChannel) {
      return null;
    }
    if (math.max(rc, math.max(gc, bc)) <
        ColorTemperatureMath.minBrightestChannel) {
      return null;
    }

    final target = ColorTemperatureMath.linearRgbForKelvin(kelvin);
    if (target == null) return null;
    if (target.r <= 0 || target.b <= 0) return null;

    var rl = curve?.linearFor(rc / 255.0);
    var gl = curve?.linearFor(gc / 255.0);
    var bl = curve?.linearFor(bc / 255.0);
    if (rl == null || gl == null || bl == null) {
      rl = ExposureMath.srgbLut[rc];
      gl = ExposureMath.srgbLut[gc];
      bl = ExposureMath.srgbLut[bc];
    }
    if (rl <= 0 || gl <= 0 || bl <= 0) return null;

    // Normalise both sides to G, so only the two colour ratios matter and
    // overall brightness drops out.
    final gainR = target.r / (rl / gl);
    final gainB = target.b / (bl / gl);

    if (!gainR.isFinite || !gainB.isFinite) return null;
    if (gainR <= 0 || gainB <= 0) return null;

    // More than two stops on either channel means the patch was coloured, not
    // neutral.
    if (ExposureMath.log2(gainR).abs() > 2.0 ||
        ExposureMath.log2(gainB).abs() > 2.0) {
      return null;
    }

    return WhiteBalanceReference(
      gainR: gainR,
      gainB: gainB,
      referenceKelvin: kelvin,
      recordedAt: recordedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'gainR': gainR,
        'gainB': gainB,
        'referenceKelvin': referenceKelvin,
        'recordedAt': recordedAt?.toIso8601String(),
      };

  static WhiteBalanceReference? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final r = raw['gainR'];
    final b = raw['gainB'];
    final k = raw['referenceKelvin'];
    if (r is! num || b is! num || k is! num) return null;

    final rd = r.toDouble();
    final bd = b.toDouble();
    final kd = k.toDouble();
    if (!rd.isFinite || !bd.isFinite || !kd.isFinite) return null;
    if (rd <= 0 || bd <= 0) return null;
    // Reject a stored reference that would swamp every reading.
    if (ExposureMath.log2(rd).abs() > 2.0 ||
        ExposureMath.log2(bd).abs() > 2.0) {
      return null;
    }
    if (kd < ColorTemperatureMath.minKelvin ||
        kd > ColorTemperatureMath.maxKelvin) {
      return null;
    }

    final at = raw['recordedAt'];
    return WhiteBalanceReference(
      gainR: rd,
      gainB: bd,
      referenceKelvin: kd,
      recordedAt: at is String ? DateTime.tryParse(at) : null,
    );
  }
}

/// Persists the white-balance reference across launches.
class WhiteBalanceStore {
  WhiteBalanceStore._();

  static const String _fileName = 'white_balance.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<WhiteBalanceReference?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      return WhiteBalanceReference.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } catch (_) {
      // A broken reference just means metering the camera's own white balance.
      return null;
    }
  }

  static Future<void> save(WhiteBalanceReference reference) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(reference.toJson()), flush: true);
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
