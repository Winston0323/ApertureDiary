import 'dart:math';

import 'exposure.dart';

/// Guide-number flash math.
///
/// A guide number is the product of aperture and distance a flash correctly
/// exposes at full power: `GN = N × d`. It is quoted for ISO 100, and since
/// light falls off with the square of distance:
///
///  * doubling ISO multiplies the usable guide number by √2 (one stop),
///  * halving flash power divides it by √2 (one stop).
///
/// Shutter speed does not appear: it controls only the ambient contribution,
/// as the flash burst is far shorter than any sync speed.
class FlashMath {
  FlashMath._();

  /// Manual power settings found on a typical speedlight, full → weakest.
  static const List<double> standardPowers = [
    1,
    1 / 2,
    1 / 4,
    1 / 8,
    1 / 16,
    1 / 32,
    1 / 64,
    1 / 128,
  ];

  static double get weakestPower => standardPowers.last;

  /// Guide number usable at [iso], from an ISO 100 rating.
  static double guideNumberAtIso({
    required double guideNumberIso100,
    required int iso,
  }) {
    if (guideNumberIso100 <= 0 || iso <= 0) return double.nan;
    return guideNumberIso100 * sqrt(iso / 100.0);
  }

  /// Fraction of full power needed, where 1.0 is full and 0.25 is 1/4.
  ///
  /// Greater than 1.0 means the flash cannot reach the subject at these
  /// settings.
  static double powerFraction({
    required double guideNumberIso100,
    required int iso,
    required double aperture,
    required double distance,
  }) {
    final gn = guideNumberAtIso(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
    );
    if (gn.isNaN || gn <= 0 || aperture <= 0 || distance <= 0) {
      return double.nan;
    }
    final ratio = (aperture * distance) / gn;
    return ratio * ratio;
  }

  /// Distance correctly exposed at a given power [fraction].
  static double distanceAtPower({
    required double guideNumberIso100,
    required int iso,
    required double aperture,
    required double fraction,
  }) {
    final gn = guideNumberAtIso(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
    );
    if (gn.isNaN || aperture <= 0 || fraction <= 0) return double.nan;
    return gn * sqrt(fraction) / aperture;
  }

  /// Aperture correctly exposed at a given power [fraction] and distance.
  static double apertureAtPower({
    required double guideNumberIso100,
    required int iso,
    required double distance,
    required double fraction,
  }) {
    final gn = guideNumberAtIso(
      guideNumberIso100: guideNumberIso100,
      iso: iso,
    );
    if (gn.isNaN || distance <= 0 || fraction <= 0) return double.nan;
    return gn * sqrt(fraction) / distance;
  }

  /// Nearest switchable power setting, chosen by stops rather than by
  /// arithmetic distance.
  static double snapPower(double fraction) {
    if (!fraction.isFinite || fraction <= 0) return standardPowers.first;
    var best = standardPowers.first;
    var bestDiff = double.infinity;
    final target = log(fraction.clamp(1e-6, 1.0));
    for (final p in standardPowers) {
      final d = (log(p) - target).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = p;
      }
    }
    return best;
  }

  /// Stops of over- (positive) or under-exposure (negative) from settling on
  /// [snapped] instead of the exact [exact] requirement.
  static double snapErrorStops({
    required double exact,
    required double snapped,
  }) {
    if (!exact.isFinite || exact <= 0 || snapped <= 0) return double.nan;
    return ExposureMath.log2(snapped / exact);
  }

  /// Stops the requirement exceeds full power by; 0 or less means it fits.
  static double stopsBeyondFullPower(double fraction) {
    if (!fraction.isFinite || fraction <= 0) return double.nan;
    return ExposureMath.log2(fraction);
  }

  /// Format a power fraction as a flash dial setting, e.g. `1/4`.
  static String formatPower(double fraction) {
    if (!fraction.isFinite || fraction <= 0) return '—';
    if (fraction >= 1) return '1/1';
    final denom = 1 / fraction;
    if ((denom - denom.round()).abs() < 0.05) return '1/${denom.round()}';
    return '1/${denom.toStringAsFixed(1)}';
  }

  /// Format a power fraction as a percentage of full output.
  static String formatPowerPercent(double fraction) {
    if (!fraction.isFinite || fraction <= 0) return '—';
    final percent = fraction * 100;
    if (percent >= 10) return '${percent.round()}%';
    if (percent >= 1) return '${percent.toStringAsFixed(1)}%';
    return '${percent.toStringAsFixed(2)}%';
  }
}
