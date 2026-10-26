import 'dart:math' as math;

/// A neutral density filter in front of the lens.
///
/// The phone meters the scene without the filter, so the scene's EV is
/// unchanged; what changes is the exposure the film needs. A filter that
/// passes `1/factor` of the light means the film sees a scene [stops] darker,
/// so the shutter must stay open [factor] times longer (or the aperture open
/// [stops] stops wider).
///
/// Filters are named three ways in the wild, and all describe the same glass:
///
/// * by factor — ND8 passes 1/8 of the light
/// * by stops — "3-stop"
/// * by optical density — 0.9 (density × 3.32 = stops, since log₁₀2 ≈ 0.301)
class NdFilter {
  const NdFilter._(this.stops);

  /// No filter.
  static const NdFilter none = NdFilter._(0);

  /// A filter that passes `1/[factor]` of the light, e.g. `fromFactor(8)`.
  factory NdFilter.fromFactor(num factor) {
    if (!factor.isFinite || factor <= 1) return none;
    return NdFilter._(math.log(factor) / math.ln2);
  }

  /// A filter that cuts [stops] stops of light.
  factory NdFilter.fromStops(num stops) {
    if (!stops.isFinite || stops <= 0) return none;
    return NdFilter._(stops.toDouble());
  }

  /// A filter of optical [density], e.g. `fromDensity(0.9)` for ND 0.9.
  factory NdFilter.fromDensity(num density) {
    if (!density.isFinite || density <= 0) return none;
    return NdFilter._(density / _log10Of2);
  }

  static final double _log10Of2 = math.log(2) / math.ln10;

  /// Light cut, in stops. Zero for no filter.
  final double stops;

  bool get isNone => stops <= 0;

  /// How many times longer the exposure must be. 1 for no filter.
  double get factor => math.pow(2, stops).toDouble();

  /// Optical density (ND 0.9 = 3 stops).
  double get density => stops * _log10Of2;

  /// Scene EV₁₀₀ as the film sees it through the filter.
  double adjustEv100(double ev100) => ev100 - stops;

  /// The shutter time to use through the filter, given the unfiltered one.
  double lengthenShutter(double seconds) => seconds * factor;

  /// Name in the usual shorthand: "ND8", "ND1000", or "ND 2.5 stops" when the
  /// filter isn't a round factor.
  String get name {
    if (isNone) return 'None';
    final f = factor;
    final rounded = f.round();
    // 2, 4, 8 … come out exact; 1000 comes out as 9.97 stops, so match on the
    // factor rather than on the stops.
    if ((f - rounded).abs() < 0.005 * f) return 'ND$rounded';
    return 'ND ${_trim(stops)} stops';
  }

  /// "3 stops" / "1 stop".
  String get stopsLabel {
    final s = _trim(stops);
    return s == '1' ? '1 stop' : '$s stops';
  }

  /// One line for a picker row: "ND8 · 3 stops".
  String get label => isNone ? 'None' : '$name · $stopsLabel';

  /// Longer description with density, for a subtitle.
  String get detail =>
      isNone ? 'No filter' : '$stopsLabel · ${factor.round()}× · OD ${_trim(density)}';

  /// Whole numbers print bare; anything else to one decimal, so ND1000's
  /// 9.97 stops reads "10" rather than "9.97".
  static String _trim(double v) {
    final nearest = v.roundToDouble();
    if ((v - nearest).abs() < 0.05) return nearest.toInt().toString();
    return v.toStringAsFixed(1);
  }

  /// Filters people actually own, weakest first.
  static final List<NdFilter> presets = List.unmodifiable([
    none,
    for (final f in const [
      2, 4, 8, 16, 32, 64, 128, 256, 500, 1000, //
      2000, 4000, 8000, 16000, 32000, 64000, 100000,
    ])
      NdFilter.fromFactor(f),
  ]);

  @override
  bool operator ==(Object other) =>
      other is NdFilter && (other.stops - stops).abs() < 1e-9;

  @override
  int get hashCode => (stops * 1e6).round().hashCode;

  @override
  String toString() => 'NdFilter($label)';
}
