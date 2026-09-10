import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/color_temperature.dart';
import 'package:aperture_diary/raw_white_point.dart';

/// Real calibration read from a vivo V2505A, Camera 0.
///
/// `referenceIlluminant1 = D65` (code 21) and `referenceIlluminant2 = 17`
/// (Standard light A, 2856 K). The transforms are the sensor's own, so a white
/// point measured on this device must resolve against these.
SensorColorCalibration deviceCalibration() {
  return SensorColorCalibration.fromMap({
    'referenceIlluminant1': 21,
    'referenceIlluminant2': 17,
    // Row-major, from SENSOR_COLOR_TRANSFORM1/2 (rationals over 128).
    'colorTransform1': [
      142 / 128, -53 / 128, -19 / 128,
      -58 / 128, 165 / 128, 16 / 128,
      -8 / 128, 26 / 128, 96 / 128,
    ],
    'colorTransform2': [
      130 / 128, -40 / 128, -22 / 128,
      -50 / 128, 158 / 128, 20 / 128,
      -6 / 128, 22 / 128, 104 / 128,
    ],
    'calibrationTransform1': [
      124 / 128, 0, 0,
      0, 128 / 128, 0,
      0, 0, 130 / 128,
    ],
    'calibrationTransform2': [
      126 / 128, 0, 0,
      0, 128 / 128, 0,
      0, 0, 128 / 128,
    ],
  })!;
}

void main() {
  group('Matrix3', () {
    test('identity leaves a vector untouched', () {
      expect(
        Matrix3.identity.transform([0.5, 1.0, 0.6]),
        [0.5, 1.0, 0.6],
      );
    });

    test('inverse undoes the transform', () {
      final m = Matrix3([
        1.1, -0.2, 0.05,
        -0.3, 1.3, 0.1,
        0.02, -0.1, 0.9,
      ]);
      final inv = m.inverse!;
      final round = inv.transform(m.transform([0.54, 1.0, 0.57]));
      expect(round[0], closeTo(0.54, 1e-9));
      expect(round[1], closeTo(1.0, 1e-9));
      expect(round[2], closeTo(0.57, 1e-9));
    });

    test('a singular matrix has no inverse', () {
      // Two identical rows: determinant zero.
      expect(
        const Matrix3([1, 2, 3, 1, 2, 3, 4, 5, 6]).inverse,
        isNull,
      );
    });

    test('multiplication composes in the expected order', () {
      final a = Matrix3([2, 0, 0, 0, 3, 0, 0, 0, 4]);
      final b = Matrix3([1, 0, 0, 0, 1, 0, 0, 0, 1]);
      expect(a.multiply(b).values, a.values);
    });

    test('lerp runs from one matrix to the other', () {
      final a = Matrix3.identity;
      final b = Matrix3([2, 0, 0, 0, 2, 0, 0, 0, 2]);
      expect(a.lerp(b, 0).values, a.values);
      expect(a.lerp(b, 1).values, b.values);
      expect(a.lerp(b, 0.5).at(0, 0), closeTo(1.5, 1e-12));
    });

    test('rejects malformed input', () {
      expect(Matrix3.fromList(null), isNull);
      expect(Matrix3.fromList([1, 2, 3]), isNull);
      expect(Matrix3.fromList([1, 2, 3, 4, 5, 6, 7, 8, 'x']), isNull);
      expect(
        Matrix3.fromList([1, 2, 3, 4, 5, 6, 7, 8, double.nan]),
        isNull,
      );
    });
  });

  group('reference illuminants', () {
    test('maps the codes this sensor actually reports', () {
      // D65 and Standard light A are the pair on the test device.
      expect(kelvinForIlluminant(21), 6504);
      expect(kelvinForIlluminant(17), 2856);
    });

    test('covers the common daylight and tungsten codes', () {
      expect(kelvinForIlluminant(23), 5003); // D50
      expect(kelvinForIlluminant(20), 5503); // D55
      expect(kelvinForIlluminant(22), 7504); // D75
      expect(kelvinForIlluminant(24), 3200); // ISO studio tungsten
    });

    test('refuses codes with no defined temperature', () {
      // Better to fail than to invent a number for "other light source".
      expect(kelvinForIlluminant(0), isNull);
      expect(kelvinForIlluminant(255), isNull);
    });
  });

  group('SensorColorCalibration', () {
    test('parses the real device calibration', () {
      final calibration = deviceCalibration();
      expect(calibration.kelvin1, 6504);
      expect(calibration.kelvin2, 2856);
      // Slot 2 holds the warmer illuminant on this device.
      expect(calibration.firstIsWarmer, isFalse);
    });

    test('interpolates in reciprocal temperature, not in Kelvin', () {
      final calibration = deviceCalibration();
      // The midpoint in mired between 2856 K and 6504 K is about 3979 K, well
      // below the arithmetic midpoint of 4680 K. Getting this wrong biases
      // every warm reading.
      final mid = 2.0 / (1 / 2856 + 1 / 6504);
      expect(calibration.weightFor(mid), closeTo(0.5, 0.01));
      expect(calibration.weightFor(4680), greaterThan(0.5));
    });

    test('weight is 0 at the warm end and 1 at the cool end', () {
      final calibration = deviceCalibration();
      expect(calibration.weightFor(2856), closeTo(0.0, 1e-9));
      expect(calibration.weightFor(6504), closeTo(1.0, 1e-9));
    });

    test('clamps outside the calibrated range rather than extrapolating', () {
      final calibration = deviceCalibration();
      expect(calibration.weightFor(1500), closeTo(0.0, 1e-9));
      expect(calibration.weightFor(20000), closeTo(1.0, 1e-9));
    });

    test('produces an invertible sensor-to-XYZ matrix across the range', () {
      final calibration = deviceCalibration();
      for (final kelvin in [2856.0, 3500.0, 4500.0, 5500.0, 6504.0]) {
        expect(
          calibration.sensorToXyzFor(kelvin),
          isNotNull,
          reason: 'at $kelvin K',
        );
      }
    });

    test('rejects a calibration missing its second illuminant', () {
      expect(
        SensorColorCalibration.fromMap({
          'referenceIlluminant1': 21,
          'colorTransform1': List<double>.filled(9, 1),
          'colorTransform2': List<double>.filled(9, 1),
        }),
        isNull,
      );
    });

    test('rejects two identical illuminants', () {
      // Nothing to interpolate between.
      expect(
        SensorColorCalibration.fromMap({
          'referenceIlluminant1': 21,
          'referenceIlluminant2': 21,
          'colorTransform1': List<double>.filled(9, 1),
          'colorTransform2': List<double>.filled(9, 1),
        }),
        isNull,
      );
    });

    test('treats a missing calibration transform as identity', () {
      final calibration = SensorColorCalibration.fromMap({
        'referenceIlluminant1': 21,
        'referenceIlluminant2': 17,
        'colorTransform1': deviceCalibration().colorTransform1.values,
        'colorTransform2': deviceCalibration().colorTransform2.values,
      });
      expect(calibration, isNotNull);
      expect(
        calibration!.calibrationTransform1.values,
        Matrix3.identity.values,
      );
    });

    test('rejects a malformed colour transform', () {
      expect(
        SensorColorCalibration.fromMap({
          'referenceIlluminant1': 21,
          'referenceIlluminant2': 17,
          'colorTransform1': [1, 2, 3],
          'colorTransform2': List<double>.filled(9, 1),
        }),
        isNull,
      );
    });
  });

  group('RawWhitePointSolver', () {
    test('resolves the white point measured on the device', () {
      // SENSOR_NEUTRAL_COLOR_POINT captured indoors on the test device.
      final result = RawWhitePointSolver.solve(
        neutral: [0.5390625, 1.0, 0.57421875],
        calibration: deviceCalibration(),
      );

      expect(result, isNotNull);
      // Must land somewhere a real illuminant could be.
      expect(result!.kelvin, greaterThan(ColorTemperatureMath.minKelvin));
      expect(result.kelvin, lessThan(ColorTemperatureMath.maxKelvin));
    });

    test('a warmer white point reads as a lower temperature', () {
      // More red relative to blue means a warmer light. The direction is what
      // matters; the absolute value depends on the sensor's calibration.
      final warm = RawWhitePointSolver.solve(
        neutral: [0.75, 1.0, 0.42],
        calibration: deviceCalibration(),
      );
      final cool = RawWhitePointSolver.solve(
        neutral: [0.42, 1.0, 0.78],
        calibration: deviceCalibration(),
      );

      expect(warm, isNotNull);
      expect(cool, isNotNull);
      expect(warm!.kelvin, lessThan(cool!.kelvin));
    });

    test('the iteration settles rather than oscillating', () {
      // Feeding the result back in must not move it: that is what convergence
      // means, and it is the only guarantee that the circular dependency
      // between matrix and temperature has actually been resolved.
      final calibration = deviceCalibration();
      const neutral = [0.5390625, 1.0, 0.57421875];

      final first = RawWhitePointSolver.solve(
        neutral: neutral,
        calibration: calibration,
      )!;

      final matrix = calibration.sensorToXyzFor(first.kelvin)!;
      final xyz = matrix.transform(neutral);
      final sum = xyz[0] + xyz[1] + xyz[2];
      final uv = Uv.fromXy(xyz[0] / sum, xyz[1] / sum)!;
      final second = ColorTemperatureMath.fromUv(uv)!;

      expect(
        (second.kelvin - first.kelvin).abs(),
        lessThan(RawWhitePointSolver.convergenceKelvin * 2),
      );
    });

    test('scaling the white point does not change the temperature', () {
      // The neutral point is a set of ratios; overall gain must not matter.
      final calibration = deviceCalibration();
      final a = RawWhitePointSolver.solve(
        neutral: [0.54, 1.0, 0.57],
        calibration: calibration,
      )!;
      final b = RawWhitePointSolver.solve(
        neutral: [1.08, 2.0, 1.14],
        calibration: calibration,
      )!;
      expect(a.kelvin, closeTo(b.kelvin, 1.0));
    });

    test('rejects a malformed or impossible white point', () {
      final calibration = deviceCalibration();
      expect(
        RawWhitePointSolver.solve(neutral: [1, 1], calibration: calibration),
        isNull,
      );
      expect(
        RawWhitePointSolver.solve(
          neutral: [0, 1, 0.5],
          calibration: calibration,
        ),
        isNull,
      );
      expect(
        RawWhitePointSolver.solve(
          neutral: [double.nan, 1, 0.5],
          calibration: calibration,
        ),
        isNull,
      );
      expect(
        RawWhitePointSolver.solve(
          neutral: [-0.5, 1, 0.5],
          calibration: calibration,
        ),
        isNull,
      );
    });

    test('reports Duv alongside the temperature', () {
      final result = RawWhitePointSolver.solve(
        neutral: [0.5390625, 1.0, 0.57421875],
        calibration: deviceCalibration(),
      )!;
      // Duv must be finite and within the range a temperature can describe;
      // beyond that the solver should have returned null.
      expect(result.duv.isFinite, isTrue);
      expect(
        result.duv.abs(),
        lessThanOrEqualTo(ColorTemperatureMath.maxMeaningfulDuv),
      );
    });
  });
}
