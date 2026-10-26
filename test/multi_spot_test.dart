import 'dart:ui' show Offset, Size;

import 'package:aperture_diary/exposure.dart';
import 'package:aperture_diary/live_meter.dart';
import 'package:aperture_diary/metering.dart';
import 'package:aperture_diary/multi_spot.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 10×10 grid of cells whose brightness runs 0.00 → 0.99 in reading order.
List<LumaCell> ramp({int n = 10}) {
  return [
    for (var r = 0; r < n; r++)
      for (var c = 0; c < n; c++)
        LumaCell(
          x: (c + 0.5) / n,
          y: (r + 0.5) / n,
          encoded: (r * n + c) / (n * n),
        ),
  ];
}

({double ev100, MultiSpotTrust trust})? flatEvaluator(double encoded) =>
    (ev100: encoded * 10, trust: MultiSpotTrust.good);

MultiSpotResult analyze(
  List<LumaCell> cells, {
  LumaCell center = const LumaCell(x: 0.5, y: 0.5, encoded: 0.5),
  MultiSpotResult? previous,
}) {
  return MultiSpotAnalyzer.analyze(
    cells: cells,
    center: center,
    evaluate: flatEvaluator,
    previous: previous,
  )!;
}

void main() {
  group('selection', () {
    test('returns the five roles dark to bright', () {
      final result = analyze(ramp());
      expect(
        result.points.map((p) => p.role).toList(),
        MultiSpotRole.values,
      );
    });

    test('lowest and highest are the extreme cells', () {
      final result = analyze(ramp());
      final low = result.pointFor(MultiSpotRole.lowest)!;
      final high = result.pointFor(MultiSpotRole.highest)!;
      expect(low.encoded, 0.0);
      expect(high.encoded, closeTo(0.99, 1e-9));
      // Reading order: first cell is top-left, last is bottom-right.
      expect(low.x, lessThan(0.2));
      expect(low.y, lessThan(0.2));
      expect(high.x, greaterThan(0.8));
      expect(high.y, greaterThan(0.8));
    });

    test('25% and 75% sit a quarter and three quarters up the brightness', () {
      final result = analyze(ramp());
      expect(
        result.pointFor(MultiSpotRole.quarter)!.encoded,
        closeTo(0.25, 0.02),
      );
      expect(
        result.pointFor(MultiSpotRole.threeQuarter)!.encoded,
        closeTo(0.75, 0.02),
      );
    });

    test('percentiles order the same way the values do', () {
      final result = analyze(ramp());
      final values = result.points.map((p) => p.ev100).toList();
      // Centre was supplied at 0.5, so the list is fully sorted.
      final sorted = [...values]..sort();
      expect(values, sorted);
    });

    test('centre uses the supplied centre cell, not a percentile', () {
      final result = analyze(
        ramp(),
        center: const LumaCell(x: 0.5, y: 0.5, encoded: 0.9),
      );
      final centre = result.pointFor(MultiSpotRole.center)!;
      expect(centre.encoded, 0.9);
      expect(centre.x, 0.5);
      expect(centre.y, 0.5);
    });

    test('too few cells to judge returns null', () {
      final tiny = ramp(n: 3);
      expect(
        MultiSpotAnalyzer.analyze(
          cells: tiny,
          center: const LumaCell(x: 0.5, y: 0.5, encoded: 0.5),
          evaluate: flatEvaluator,
        ),
        isNull,
      );
    });

    test('an evaluator that cannot read a value rejects the frame', () {
      expect(
        MultiSpotAnalyzer.analyze(
          cells: ramp(),
          center: const LumaCell(x: 0.5, y: 0.5, encoded: 0.5),
          evaluate: (_) => null,
        ),
        isNull,
      );
    });
  });

  group('ties between equal cells', () {
    // A flat frame: every cell identical, so every choice is a tie.
    List<LumaCell> flat() => [
          for (var r = 0; r < 6; r++)
            for (var c = 0; c < 6; c++)
              LumaCell(x: (c + 0.5) / 6, y: (r + 0.5) / 6, encoded: 0.4),
        ];

    test('without history, ties resolve to the cell nearest the centre', () {
      final result = analyze(flat());
      final low = result.pointFor(MultiSpotRole.lowest)!;
      expect((low.x - 0.5).abs(), lessThan(0.17));
      expect((low.y - 0.5).abs(), lessThan(0.17));
    });

    test('with history, ties keep the previous marker where it was', () {
      final first = analyze(flat());
      // Move the previous marker to a corner; the tie must follow it.
      final corner = MultiSpotResult([
        for (final p in first.points)
          MultiSpotPoint(
            role: p.role,
            x: 0.08,
            y: 0.08,
            encoded: p.encoded,
            ev100: p.ev100,
            trust: p.trust,
          ),
      ]);
      final second = analyze(flat(), previous: corner);
      final low = second.pointFor(MultiSpotRole.lowest)!;
      expect(low.x, lessThan(0.2));
      expect(low.y, lessThan(0.2));
    });

    test('a real difference still beats history', () {
      final cells = ramp();
      final stale = analyze(cells);
      final moved = [
        for (final c in cells)
          LumaCell(
            x: c.x,
            y: c.y,
            // Flip the picture: the darkest cell is now bottom-right.
            encoded: 1.0 - c.encoded - 0.01,
          ),
      ];
      final fresh = analyze(moved, previous: stale);
      expect(fresh.pointFor(MultiSpotRole.lowest)!.x, greaterThan(0.8));
    });
  });

  group('range', () {
    test('is the stops between the highest and the lowest', () {
      expect(analyze(ramp()).rangeStops, closeTo(9.9, 1e-9));
    });

    test('is flagged as a floor when an end is clipped', () {
      final result = MultiSpotAnalyzer.analyze(
        cells: ramp(),
        center: const LumaCell(x: 0.5, y: 0.5, encoded: 0.5),
        evaluate: (e) => (
          ev100: e * 10,
          trust: e > 0.9 ? MultiSpotTrust.clipped : MultiSpotTrust.good,
        ),
      )!;
      expect(result.rangeIsLowerBound, isTrue);
      expect(analyze(ramp()).rangeIsLowerBound, isFalse);
    });
  });

  group('prefix', () {
    MultiSpotPoint point(double encoded, MultiSpotTrust trust) =>
        MultiSpotPoint(
          role: MultiSpotRole.lowest,
          x: 0,
          y: 0,
          encoded: encoded,
          ev100: 5,
          trust: trust,
        );

    test('trusted values carry no symbol', () {
      expect(point(0.5, MultiSpotTrust.good).prefix, '');
    });

    test('estimates are marked approximate', () {
      expect(point(0.1, MultiSpotTrust.approximate).prefix, '~');
    });

    test('crushed shadows read "at most", blown highlights "at least"', () {
      expect(point(0.01, MultiSpotTrust.clipped).prefix, '≤');
      expect(point(0.99, MultiSpotTrust.clipped).prefix, '≥');
    });
  });

  group('LiveMeter.readEncoded', () {
    final meter = LiveMeter();

    test('a mid grey patch reads the camera exposure itself', () {
      final r = meter.readEncoded(
        cameraEv100: 10,
        encoded: ExposureMath.middleGreyEncoded,
      )!;
      expect(r.ev100, closeTo(10, 0.05));
      expect(r.trust, MultiSpotTrust.good);
    });

    test('brighter patches read brighter, darker read darker', () {
      double ev(double e) =>
          meter.readEncoded(cameraEv100: 10, encoded: e)!.ev100;
      expect(ev(0.7), greaterThan(ev(0.5)));
      expect(ev(0.5), greaterThan(ev(0.3)));
    });

    test('one stop of patch brightness is one stop of EV', () {
      // sRGB: doubling linear luminance adds one stop.
      final base = ExposureMath.srgbToLinear(0.4);
      final doubled = ExposureMath.linearToSrgb(base * 2);
      final a = meter.readEncoded(cameraEv100: 8, encoded: 0.4)!.ev100;
      final b = meter.readEncoded(cameraEv100: 8, encoded: doubled)!.ev100;
      expect(b - a, closeTo(1.0, 0.05));
    });

    test('pure black and pure white still give finite, clipped numbers', () {
      final black = meter.readEncoded(cameraEv100: 10, encoded: 0)!;
      final white = meter.readEncoded(cameraEv100: 10, encoded: 1)!;
      expect(black.ev100.isFinite, isTrue);
      expect(white.ev100.isFinite, isTrue);
      expect(black.trust, MultiSpotTrust.clipped);
      expect(white.trust, MultiSpotTrust.clipped);
      expect(white.ev100, greaterThan(black.ev100));
    });

    test('the band between usable and clipped is only approximate', () {
      expect(
        meter.readEncoded(cameraEv100: 10, encoded: 0.1)!.trust,
        MultiSpotTrust.approximate,
      );
      expect(
        meter.readEncoded(cameraEv100: 10, encoded: 0.9)!.trust,
        MultiSpotTrust.approximate,
      );
    });

    test('a non-finite exposure or value yields nothing', () {
      expect(meter.readEncoded(cameraEv100: double.nan, encoded: 0.5), isNull);
      expect(meter.readEncoded(cameraEv100: 10, encoded: double.nan), isNull);
    });

    test('agrees with the main reading for the same patch', () {
      // The multi-spot view must not disagree with the single spot.
      final a = LiveMeter();
      final b = LiveMeter();
      const encoded = 0.6;
      final multi = a.readEncoded(cameraEv100: 9, encoded: encoded)!.ev100;
      final linear = ExposureMath.srgbToLinear(encoded);
      final single = ExposureMath.sceneEv(
        cameraEv100: 9,
        linearLuminance: linear,
      );
      expect(multi, closeTo(single, 1e-9));
      expect(b.slope, a.slope);
    });
  });

  group('sampleLumaGrid orientation', () {
    // A 400×300 sensor frame whose luma rises with frame x only.
    int? lumaByFrameX(int x, int y) => (x / 399.0 * 255).round();

    // The same frame, rising with frame y only.
    int? lumaByFrameY(int x, int y) => (y / 299.0 * 255).round();

    List<LumaCell> grid(
      int? Function(int, int) luma,
      int turns, {
      bool mirror = false,
    }) {
      return sampleLumaGrid(
        frameWidth: 400,
        frameHeight: 300,
        luma: luma,
        widgetSize: const Size(300, 400),
        quarterTurns: turns,
        mirror: mirror,
      )!;
    }

    double meanWhere(List<LumaCell> cells, bool Function(LumaCell) test) {
      final picked = cells.where(test).toList();
      return picked.map((c) => c.encoded).reduce((a, b) => a + b) /
          picked.length;
    }

    test('covers the viewfinder in a regular grid', () {
      final cells = grid(lumaByFrameX, 0);
      expect(cells.length, greaterThan(100));
      for (final c in cells) {
        expect(c.x, inInclusiveRange(0.05, 0.95));
        expect(c.y, inInclusiveRange(0.05, 0.95));
      }
    });

    test('unrotated, brightness along frame x runs left to right', () {
      final cells = grid(lumaByFrameX, 0);
      expect(
        meanWhere(cells, (c) => c.x > 0.5),
        greaterThan(meanWhere(cells, (c) => c.x < 0.5)),
      );
      // …and does not vary top to bottom.
      expect(
        (meanWhere(cells, (c) => c.y > 0.5) -
                meanWhere(cells, (c) => c.y < 0.5))
            .abs(),
        lessThan(0.02),
      );
    });

    test('a 90° sensor turns frame x into top-to-bottom', () {
      final cells = grid(lumaByFrameX, 1);
      expect(
        meanWhere(cells, (c) => c.y > 0.5),
        greaterThan(meanWhere(cells, (c) => c.y < 0.5) + 0.2),
      );
      expect(
        (meanWhere(cells, (c) => c.x > 0.5) -
                meanWhere(cells, (c) => c.x < 0.5))
            .abs(),
        lessThan(0.03),
      );
    });

    test('a 90° sensor turns frame y into right-to-left', () {
      // With the display rotated a quarter turn, frame y runs against the
      // viewfinder's x axis.
      final cells = grid(lumaByFrameY, 1);
      expect(
        meanWhere(cells, (c) => c.x < 0.5),
        greaterThan(meanWhere(cells, (c) => c.x > 0.5) + 0.2),
      );
    });

    test('mirroring flips left and right only', () {
      final plain = grid(lumaByFrameX, 0);
      final mirrored = grid(lumaByFrameX, 0, mirror: true);
      expect(
        meanWhere(mirrored, (c) => c.x < 0.5),
        greaterThan(meanWhere(mirrored, (c) => c.x > 0.5)),
      );
      expect(
        meanWhere(plain, (c) => c.x > 0.5),
        greaterThan(meanWhere(plain, (c) => c.x < 0.5)),
      );
    });

    test('a hot pixel does not become the highest spot', () {
      // Flat grey with one saturated pixel: the 3×3 cluster average must stay
      // far below white.
      int? hot(int x, int y) => (x == 200 && y == 150) ? 255 : 100;
      final cells = grid(hot, 0);
      final brightest =
          cells.map((c) => c.encoded).reduce((a, b) => a > b ? a : b);
      expect(brightest, lessThan(0.6));
    });

    test('rejects a degenerate frame or widget', () {
      expect(
        sampleLumaGrid(
          frameWidth: 0,
          frameHeight: 300,
          luma: lumaByFrameX,
          widgetSize: const Size(300, 400),
          quarterTurns: 0,
          mirror: false,
        ),
        isNull,
      );
      expect(
        sampleLumaGrid(
          frameWidth: 400,
          frameHeight: 300,
          luma: lumaByFrameX,
          widgetSize: Size.zero,
          quarterTurns: 0,
          mirror: false,
        ),
        isNull,
      );
    });

    test('a crop callback is honoured', () {
      // Map every viewfinder point to the left edge of the preview. A portrait
      // widget covering a landscape frame only shows its middle 225 px, so
      // that edge is frame x ≈ 92 (luma ≈ 0.23), not 0 — and nowhere near the
      // 0.5 an un-mapped grid would average to.
      final cells = sampleLumaGrid(
        frameWidth: 400,
        frameHeight: 300,
        luma: lumaByFrameX,
        widgetSize: const Size(300, 400),
        quarterTurns: 0,
        mirror: false,
        toPreview: (p) => Offset(0.02, p.dy),
      )!;
      final mean =
          cells.map((c) => c.encoded).reduce((a, b) => a + b) / cells.length;
      expect(mean, closeTo(0.23, 0.03));
    });
  });
}
