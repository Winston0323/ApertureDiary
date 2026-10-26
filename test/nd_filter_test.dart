import 'package:aperture_diary/exposure.dart';
import 'package:aperture_diary/nd_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NdFilter maths', () {
    test('factor, stops and density describe the same filter', () {
      final nd8 = NdFilter.fromFactor(8);
      expect(nd8.stops, closeTo(3, 1e-9));
      expect(nd8.factor, closeTo(8, 1e-9));
      expect(nd8.density, closeTo(0.9, 0.01));

      expect(NdFilter.fromStops(3), nd8);
      // ND 0.9 is the density name for an 8× filter.
      // Densities are quoted to one decimal, so 0.9 is 2.99 stops.
      expect(NdFilter.fromDensity(0.9).stops, closeTo(3, 0.02));
      expect(NdFilter.fromDensity(3.0).stops, closeTo(10, 0.05));
    });

    test('ND1000 is just under ten stops, not exactly ten', () {
      final nd = NdFilter.fromFactor(1000);
      expect(nd.stops, closeTo(9.966, 1e-3));
      expect(nd.factor, closeTo(1000, 1e-6));
    });

    test('no filter changes nothing', () {
      expect(NdFilter.none.isNone, isTrue);
      expect(NdFilter.none.factor, 1);
      expect(NdFilter.none.adjustEv100(12.3), 12.3);
      expect(NdFilter.none.lengthenShutter(0.5), 0.5);
    });

    test('nonsense input falls back to no filter', () {
      expect(NdFilter.fromFactor(1), NdFilter.none);
      expect(NdFilter.fromFactor(0.5), NdFilter.none);
      expect(NdFilter.fromFactor(double.nan), NdFilter.none);
      expect(NdFilter.fromStops(-2), NdFilter.none);
      expect(NdFilter.fromStops(double.infinity), NdFilter.none);
      expect(NdFilter.fromDensity(0), NdFilter.none);
    });
  });

  group('NdFilter through the exposure maths', () {
    test('ND8 turns 1/125 into 8/125 s, three stops longer', () {
      final ev = ExposureMath.cameraEv100(
        aperture: 8,
        shutterSeconds: 1 / 125,
        iso: 100,
      );
      final bare = ExposureMath.shutterFromEv(
        ev100: ev,
        aperture: 8,
        iso: 100,
      );
      final filtered = ExposureMath.shutterFromEv(
        ev100: NdFilter.fromFactor(8).adjustEv100(ev),
        aperture: 8,
        iso: 100,
      );
      expect(bare, closeTo(1 / 125, 1e-9));
      expect(filtered, closeTo(8 / 125, 1e-9));
      expect(filtered, closeTo(NdFilter.fromFactor(8).lengthenShutter(bare), 1e-9));
    });

    test('ND1000 in full sun gives a few seconds', () {
      // Sunny 16: f/16, 1/100 s at ISO 100.
      final ev = ExposureMath.cameraEv100(
        aperture: 16,
        shutterSeconds: 1 / 100,
        iso: 100,
      );
      final t = ExposureMath.shutterFromEv(
        ev100: NdFilter.fromFactor(1000).adjustEv100(ev),
        aperture: 16,
        iso: 100,
      );
      expect(t, closeTo(10, 1e-6));
    });

    test('through the filter the aperture opens by the same number of stops', () {
      final ev = ExposureMath.cameraEv100(
        aperture: 16,
        shutterSeconds: 1 / 100,
        iso: 100,
      );
      // Keep 1/100 s and open up: ND4 is two stops, so f/16 becomes f/8.
      final n = ExposureMath.apertureFromEv(
        ev100: NdFilter.fromFactor(4).adjustEv100(ev),
        shutterSeconds: 1 / 100,
        iso: 100,
      );
      expect(n, closeTo(8, 1e-6));
    });

    test('adjusts the film exposure, never the scene reading', () {
      // adjustEv100 is applied to the solve only; the reading itself is
      // whatever the meter measured.
      const sceneEv = 13.0;
      expect(NdFilter.fromStops(3).adjustEv100(sceneEv), 10.0);
    });
  });

  group('NdFilter naming', () {
    test('round factors use the usual shorthand', () {
      expect(NdFilter.fromFactor(8).name, 'ND8');
      expect(NdFilter.fromFactor(64).name, 'ND64');
      expect(NdFilter.fromFactor(1000).name, 'ND1000');
      expect(NdFilter.fromFactor(500).name, 'ND500');
    });

    test('labels read naturally', () {
      expect(NdFilter.fromFactor(2).label, 'ND2 · 1 stop');
      expect(NdFilter.fromFactor(8).label, 'ND8 · 3 stops');
      expect(NdFilter.fromFactor(1000).label, 'ND1000 · 10 stops');
      expect(NdFilter.none.label, 'None');
    });

    test('a filter that is not a round factor is named by its stops', () {
      expect(NdFilter.fromStops(2.5).name, 'ND 2.5 stops');
    });
  });

  group('presets', () {
    test('start with none and run weakest to strongest', () {
      final p = NdFilter.presets;
      expect(p.first, NdFilter.none);
      for (var i = 1; i < p.length; i++) {
        expect(p[i].stops, greaterThan(p[i - 1].stops));
      }
    });

    test('include the common filters', () {
      for (final f in [2, 4, 8, 64, 1000]) {
        expect(NdFilter.presets, contains(NdFilter.fromFactor(f)));
      }
    });

    test('are equal by value, so a picker can find the current one', () {
      expect(NdFilter.presets.indexOf(NdFilter.fromFactor(64)), isNonNegative);
      expect(NdFilter.fromFactor(64).hashCode, NdFilter.fromStops(6).hashCode);
    });
  });
}
