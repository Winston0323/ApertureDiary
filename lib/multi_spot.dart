import 'package:flutter/foundation.dart';

/// Which statistic of the frame a spot stands for.
///
/// Declared dark → bright so the list order is also the legend order.
enum MultiSpotRole {
  lowest('Low'),
  quarter('25%'),
  center('Center'),
  threeQuarter('75%'),
  highest('High');

  const MultiSpotRole(this.label);

  final String label;
}

/// How far a value can be believed.
enum MultiSpotTrust {
  /// Inside the range the tone model describes well.
  good,

  /// Usable but outside the well-modelled band; treat as an estimate.
  approximate,

  /// Crushed to black or blown to white. The real value lies beyond the number
  /// shown — below it for shadows, above it for highlights.
  clipped,
}

/// One cell of the sampled frame: where it sits in the viewfinder and how
/// bright the preview rendered it.
@immutable
class LumaCell {
  const LumaCell({required this.x, required this.y, required this.encoded});

  /// Position in viewfinder space, 0..1 from the top-left.
  final double x;
  final double y;

  /// Gamma-encoded luma, 0..1.
  final double encoded;
}

/// A selected spot with its measured value.
@immutable
class MultiSpotPoint {
  const MultiSpotPoint({
    required this.role,
    required this.x,
    required this.y,
    required this.encoded,
    required this.ev100,
    required this.trust,
  });

  final MultiSpotRole role;
  final double x;
  final double y;
  final double encoded;

  /// Scene EV₁₀₀ at this spot, before the user's calibration offset.
  final double ev100;

  final MultiSpotTrust trust;

  /// Whether a clipped value is clipped towards black rather than white.
  bool get isDarkSide => encoded < 0.5;

  /// Symbol that qualifies the number: `≤` for crushed shadows, `≥` for blown
  /// highlights, `~` for an estimate, nothing for a trusted value.
  String get prefix {
    switch (trust) {
      case MultiSpotTrust.good:
        return '';
      case MultiSpotTrust.approximate:
        return '~';
      case MultiSpotTrust.clipped:
        return isDarkSide ? '≤' : '≥';
    }
  }
}

/// The five spots for one frame.
@immutable
class MultiSpotResult {
  const MultiSpotResult(this.points);

  /// Ordered by [MultiSpotRole] (dark → bright).
  final List<MultiSpotPoint> points;

  MultiSpotPoint? pointFor(MultiSpotRole role) {
    for (final p in points) {
      if (p.role == role) return p;
    }
    return null;
  }

  /// Stops between the lowest and highest spot.
  double? get rangeStops {
    final low = pointFor(MultiSpotRole.lowest);
    final high = pointFor(MultiSpotRole.highest);
    if (low == null || high == null) return null;
    return high.ev100 - low.ev100;
  }

  /// A range measured to a clipped end is a floor, not the real range: the
  /// scene is at least this contrasty.
  bool get rangeIsLowerBound =>
      pointFor(MultiSpotRole.lowest)?.trust == MultiSpotTrust.clipped ||
      pointFor(MultiSpotRole.highest)?.trust == MultiSpotTrust.clipped;
}

/// Converts an encoded luma into scene EV, or null if it cannot be.
typedef MultiSpotEvaluator = ({double ev100, MultiSpotTrust trust})? Function(
  double encoded,
);

/// Picks the lowest, 25 %, centre, 75 % and highest spots from a sampled
/// frame.
class MultiSpotAnalyzer {
  MultiSpotAnalyzer._();

  /// Fewest cells that make a percentile meaningful.
  static const int minCells = 12;

  /// Cells within this encoded distance of a target value count as ties.
  ///
  /// Real frames are full of equal values — a blown sky, a flat wall — and
  /// picking the first of them lets the marker jump around frame to frame.
  /// Among ties the cell nearest the previous marker wins.
  static const double tieTolerance = 0.006;

  static MultiSpotResult? analyze({
    required List<LumaCell> cells,
    required LumaCell center,
    required MultiSpotEvaluator evaluate,
    MultiSpotResult? previous,
  }) {
    if (cells.length < minCells) return null;

    final sorted = [...cells]..sort((a, b) => a.encoded.compareTo(b.encoded));

    double percentileValue(double fraction) =>
        sorted[((sorted.length - 1) * fraction).round()].encoded;

    LumaCell pick(MultiSpotRole role, double target) {
      final prev = previous?.pointFor(role);
      final ax = prev?.x ?? 0.5;
      final ay = prev?.y ?? 0.5;

      var best = sorted.first;
      var bestDistance = double.infinity;
      for (final c in sorted) {
        if ((c.encoded - target).abs() > tieTolerance) continue;
        final dx = c.x - ax;
        final dy = c.y - ay;
        final d = dx * dx + dy * dy;
        if (d < bestDistance) {
          bestDistance = d;
          best = c;
        }
      }
      return best;
    }

    final chosen = <MultiSpotRole, LumaCell>{
      MultiSpotRole.lowest: pick(MultiSpotRole.lowest, sorted.first.encoded),
      MultiSpotRole.quarter: pick(MultiSpotRole.quarter, percentileValue(0.25)),
      MultiSpotRole.center: center,
      MultiSpotRole.threeQuarter:
          pick(MultiSpotRole.threeQuarter, percentileValue(0.75)),
      MultiSpotRole.highest: pick(MultiSpotRole.highest, sorted.last.encoded),
    };

    final points = <MultiSpotPoint>[];
    for (final role in MultiSpotRole.values) {
      final cell = chosen[role]!;
      final reading = evaluate(cell.encoded);
      if (reading == null || !reading.ev100.isFinite) return null;
      points.add(
        MultiSpotPoint(
          role: role,
          x: cell.x,
          y: cell.y,
          encoded: cell.encoded,
          ev100: reading.ev100,
          trust: reading.trust,
        ),
      );
    }
    return MultiSpotResult(points);
  }
}
