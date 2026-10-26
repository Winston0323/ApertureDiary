import 'package:aperture_diary/calibration.dart';
import 'package:aperture_diary/exposure.dart';
import 'package:flutter_test/flutter_test.dart';

EvCalibrationRun runWith(Iterable<double> values) {
  final run = EvCalibrationRun();
  for (final v in values) {
    run.add(v);
  }
  return run;
}

void main() {
  group('EvCalibrationRun', () {
    test('solves the offset that maps the meter onto the reference', () {
      // The meter reads EV 12.4 where a trusted meter says 13.0.
      final run = runWith(List<double>.filled(30, 12.4));
      final result = run.solve(13.0);
      expect(result.status, EvCalibrationStatus.ok);
      expect(result.offset, closeTo(0.6, 1e-9));
      expect(result.measuredEv100, closeTo(12.4, 1e-9));
    });

    test('a negative offset when the meter reads high', () {
      final run = runWith(List<double>.filled(30, 14.2));
      expect(run.solve(13.7).offset, closeTo(-0.5, 1e-9));
    });

    test('applying the offset makes the readings equal the reference', () {
      final raw = [for (var i = 0; i < 30; i++) 11.0 + (i % 3 - 1) * 0.05];
      final result = runWith(raw).solve(12.0);
      final corrected = result.measuredEv100! + result.offset!;
      expect(corrected, closeTo(12.0, 0.01));
    });

    test('median ignores a stray bright frame', () {
      final values = [...List<double>.filled(29, 10.0), 14.0];
      final result = runWith(values).solve(10.0);
      expect(result.status, EvCalibrationStatus.ok);
      expect(result.offset, closeTo(0, 1e-9));
    });

    test('refuses to calibrate from too few frames', () {
      final result = runWith(List<double>.filled(5, 12)).solve(12);
      expect(result.status, EvCalibrationStatus.tooFewSamples);
      expect(result.offset, isNull);
    });

    test('refuses when the readings are not steady', () {
      final values = [for (var i = 0; i < 30; i++) 10.0 + (i % 2) * 2.0];
      final result = runWith(values).solve(11);
      expect(result.status, EvCalibrationStatus.unstable);
      expect(result.offset, isNull);
      expect(result.spread, greaterThan(EvCalibrationRun.maxSpreadStops));
    });

    test('flags an offset larger than the calibration range', () {
      final result = runWith(List<double>.filled(30, 5)).solve(12);
      expect(result.status, EvCalibrationStatus.outOfRange);
      expect(result.offset, closeTo(7, 1e-9));
    });

    test('ignores non-finite readings and stops at the target', () {
      final run = EvCalibrationRun()
        ..add(double.nan)
        ..add(double.infinity);
      expect(run.count, 0);
      for (var i = 0; i < EvCalibrationRun.targetSamples + 10; i++) {
        run.add(10);
      }
      expect(run.count, EvCalibrationRun.targetSamples);
      expect(run.isFull, isTrue);
    });

    test('a non-finite reference cannot be solved', () {
      final run = runWith(List<double>.filled(30, 10));
      expect(run.solve(double.nan).status, EvCalibrationStatus.tooFewSamples);
    });
  });

  group('reference conversion', () {
    test('a lens-scale reading converts to EV100 at the film speed', () {
      // EV 12 on the lens scale at ISO 400 is EV100 10.
      expect(ExposureMath.ev100FromLensEv(lensEv: 12, iso: 400), closeTo(10, 1e-9));
    });

    test('sunny 16 is EV 15 at ISO 100', () {
      // f/16 at 1/100 s, ISO 100.
      final ev = ExposureMath.cameraEv100(
        aperture: 16,
        shutterSeconds: 1 / 100,
        iso: 100,
      );
      expect(ev, closeTo(14.64, 0.01));
    });
  });
}
