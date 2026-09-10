import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'color_temperature.dart';

/// A 3×3 matrix, row-major, as the Camera2 colour transforms are reported.
@immutable
class Matrix3 {
  const Matrix3(this.values);

  /// Nine elements, row-major.
  final List<double> values;

  static const Matrix3 identity = Matrix3([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  double at(int row, int col) => values[row * 3 + col];

  Matrix3 multiply(Matrix3 other) {
    final out = List<double>.filled(9, 0);
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        var sum = 0.0;
        for (var k = 0; k < 3; k++) {
          sum += at(row, k) * other.at(k, col);
        }
        out[row * 3 + col] = sum;
      }
    }
    return Matrix3(out);
  }

  List<double> transform(List<double> vector) {
    return [
      for (var row = 0; row < 3; row++)
        at(row, 0) * vector[0] + at(row, 1) * vector[1] + at(row, 2) * vector[2],
    ];
  }

  /// Element-wise interpolation, `t` running 0 → this, 1 → other.
  Matrix3 lerp(Matrix3 other, double t) {
    return Matrix3([
      for (var i = 0; i < 9; i++)
        values[i] + (other.values[i] - values[i]) * t,
    ]);
  }

  double get determinant =>
      at(0, 0) * (at(1, 1) * at(2, 2) - at(1, 2) * at(2, 1)) -
      at(0, 1) * (at(1, 0) * at(2, 2) - at(1, 2) * at(2, 0)) +
      at(0, 2) * (at(1, 0) * at(2, 1) - at(1, 1) * at(2, 0));

  /// Inverse, or null when singular.
  Matrix3? get inverse {
    final det = determinant;
    if (!det.isFinite || det.abs() < 1e-12) return null;
    final inv = 1.0 / det;
    return Matrix3([
      (at(1, 1) * at(2, 2) - at(1, 2) * at(2, 1)) * inv,
      (at(0, 2) * at(2, 1) - at(0, 1) * at(2, 2)) * inv,
      (at(0, 1) * at(1, 2) - at(0, 2) * at(1, 1)) * inv,
      (at(1, 2) * at(2, 0) - at(1, 0) * at(2, 2)) * inv,
      (at(0, 0) * at(2, 2) - at(0, 2) * at(2, 0)) * inv,
      (at(0, 2) * at(1, 0) - at(0, 0) * at(1, 2)) * inv,
      (at(1, 0) * at(2, 1) - at(1, 1) * at(2, 0)) * inv,
      (at(0, 1) * at(2, 0) - at(0, 0) * at(2, 1)) * inv,
      (at(0, 0) * at(1, 1) - at(0, 1) * at(1, 0)) * inv,
    ]);
  }

  static Matrix3? fromList(Object? raw) {
    if (raw is! List || raw.length != 9) return null;
    final out = <double>[];
    for (final item in raw) {
      if (item is! num) return null;
      final d = item.toDouble();
      if (!d.isFinite) return null;
      out.add(d);
    }
    return Matrix3(out);
  }
}

/// EXIF light source codes, as `SENSOR_REFERENCE_ILLUMINANT*` reports them.
///
/// Only the temperature matters here, so this maps each code straight to one.
/// Codes outside this set have no defined temperature and are rejected rather
/// than approximated.
double? kelvinForIlluminant(int code) {
  switch (code) {
    case 1: // Daylight
      return 5500;
    case 2: // Fluorescent — nominal; well off the Planckian locus.
      return 4150;
    case 3: // Tungsten (incandescent)
      return 2856;
    case 4: // Flash
      return 5500;
    case 9: // Fine weather
      return 5500;
    case 10: // Cloudy weather
      return 6504;
    case 11: // Shade
      return 7504;
    case 12: // Daylight fluorescent (D 5700–7100 K)
      return 6430;
    case 13: // Day white fluorescent (N 4600–5500 K)
      return 5000;
    case 14: // Cool white fluorescent (W 3800–4500 K)
      return 4150;
    case 15: // White fluorescent (WW 3250–3800 K)
      return 3450;
    case 17: // Standard light A
      return 2856;
    case 18: // Standard light B
      return 4874;
    case 19: // Standard light C
      return 6774;
    case 20: // D55
      return 5503;
    case 21: // D65
      return 6504;
    case 22: // D75
      return 7504;
    case 23: // D50
      return 5003;
    case 24: // ISO studio tungsten
      return 3200;
    default:
      return null;
  }
}

/// The sensor's DNG colour calibration, as Camera2 reports it.
///
/// Converting a raw white point into a colour temperature needs the mapping
/// from sensor space to CIE XYZ, and that mapping itself depends on the
/// illuminant — the reason this is solved by iteration rather than a single
/// matrix multiply.
@immutable
class SensorColorCalibration {
  const SensorColorCalibration({
    required this.kelvin1,
    required this.kelvin2,
    required this.colorTransform1,
    required this.colorTransform2,
    required this.calibrationTransform1,
    required this.calibrationTransform2,
  });

  /// Temperature of the first reference illuminant, the warmer of the two.
  final double kelvin1;
  final double kelvin2;

  /// XYZ → reference-sensor colour, per illuminant.
  final Matrix3 colorTransform1;
  final Matrix3 colorTransform2;

  /// Reference sensor → this individual sensor, per illuminant.
  final Matrix3 calibrationTransform1;
  final Matrix3 calibrationTransform2;

  /// Interpolation weight for [kelvin], in reciprocal temperature.
  ///
  /// Mired rather than Kelvin because colour differences scale with reciprocal
  /// temperature: the step from 2800 K to 3000 K is a far larger visual change
  /// than 6800 K to 7000 K, and DNG specifies the interpolation this way.
  double weightFor(double kelvin) {
    if (kelvin <= 0) return 0;
    final warm = math.min(kelvin1, kelvin2);
    final cool = math.max(kelvin1, kelvin2);
    if (cool - warm < 1) return 0;

    final invTarget = 1.0 / kelvin.clamp(warm, cool);
    final invWarm = 1.0 / warm;
    final invCool = 1.0 / cool;
    // 0 at the warm end, 1 at the cool end.
    return ((invTarget - invWarm) / (invCool - invWarm)).clamp(0.0, 1.0);
  }

  /// Whether [colorTransform1] belongs to the warmer illuminant.
  bool get firstIsWarmer => kelvin1 <= kelvin2;

  /// Sensor-space → XYZ for an assumed illuminant temperature, or null when the
  /// interpolated matrix cannot be inverted.
  Matrix3? sensorToXyzFor(double kelvin) {
    final t = weightFor(kelvin);
    // Interpolate from warm to cool regardless of which slot holds which.
    final warmColor = firstIsWarmer ? colorTransform1 : colorTransform2;
    final coolColor = firstIsWarmer ? colorTransform2 : colorTransform1;
    final warmCal = firstIsWarmer ? calibrationTransform1 : calibrationTransform2;
    final coolCal = firstIsWarmer ? calibrationTransform2 : calibrationTransform1;

    final cm = warmColor.lerp(coolColor, t);
    final cc = warmCal.lerp(coolCal, t);

    // DNG defines XYZ → sensor as CC · CM, so the inverse is what is needed.
    return cc.multiply(cm).inverse;
  }

  static SensorColorCalibration? fromMap(Map<String, Object?>? raw) {
    if (raw == null) return null;

    final code1 = raw['referenceIlluminant1'];
    final code2 = raw['referenceIlluminant2'];
    if (code1 is! num || code2 is! num) return null;

    final kelvin1 = kelvinForIlluminant(code1.toInt());
    final kelvin2 = kelvinForIlluminant(code2.toInt());
    if (kelvin1 == null || kelvin2 == null) return null;
    // Two identical illuminants give nothing to interpolate between.
    if ((kelvin1 - kelvin2).abs() < 1) return null;

    final color1 = Matrix3.fromList(raw['colorTransform1']);
    final color2 = Matrix3.fromList(raw['colorTransform2']);
    if (color1 == null || color2 == null) return null;

    // A missing calibration transform means the sensor matches the reference,
    // which is what the identity expresses.
    final cal1 = Matrix3.fromList(raw['calibrationTransform1']) ?? Matrix3.identity;
    final cal2 = Matrix3.fromList(raw['calibrationTransform2']) ?? Matrix3.identity;

    return SensorColorCalibration(
      kelvin1: kelvin1,
      kelvin2: kelvin2,
      colorTransform1: color1,
      colorTransform2: color2,
      calibrationTransform1: cal1,
      calibrationTransform2: cal2,
    );
  }

  @override
  String toString() =>
      'calibrated at ${kelvin1.round()}K and ${kelvin2.round()}K';
}

/// Derives a colour temperature from a raw sensor white point.
///
/// This is the measurement auto white balance makes impossible from rendered
/// pixels. AWB divides the illuminant's colour out — measured on one device as
/// gains of 1.85 on red and 1.74 on blue, nearly a stop — so a white wall under
/// tungsten renders neutral and reads as daylight. `SENSOR_NEUTRAL_COLOR_POINT`
/// is stated in raw sensor space, before that correction, so it still describes
/// the light.
///
/// The conversion is circular by nature: mapping sensor space to XYZ requires
/// knowing the illuminant, which is what is being solved for. DNG resolves this
/// by iterating, and it converges in two or three passes because the matrices
/// vary slowly with temperature.
class RawWhitePointSolver {
  RawWhitePointSolver._();

  /// Iterations before giving up. Three is ample; the loop also exits early
  /// once the estimate stops moving.
  static const int maxIterations = 5;

  /// Stop once successive estimates agree this closely, in Kelvin.
  static const double convergenceKelvin = 1.0;

  /// Colour temperature from a raw neutral point, or null when it cannot be
  /// determined.
  ///
  /// [neutral] is `SENSOR_NEUTRAL_COLOR_POINT` — three values in the sensor's
  /// raw colour space, conventionally normalised so green is 1.
  static ColorTemperature? solve({
    required List<double> neutral,
    required SensorColorCalibration calibration,
  }) {
    if (neutral.length != 3) return null;
    for (final value in neutral) {
      if (!value.isFinite || value <= 0) return null;
    }

    // Start from the midpoint of the calibration range in mired: any starting
    // guess converges, and this one is never far from the answer.
    var estimate =
        2.0 / (1.0 / calibration.kelvin1 + 1.0 / calibration.kelvin2);

    ColorTemperature? result;
    for (var i = 0; i < maxIterations; i++) {
      final sensorToXyz = calibration.sensorToXyzFor(estimate);
      if (sensorToXyz == null) return null;

      final xyz = sensorToXyz.transform(neutral);
      final sum = xyz[0] + xyz[1] + xyz[2];
      if (!sum.isFinite || sum <= 0) return null;

      final uv = Uv.fromXy(xyz[0] / sum, xyz[1] / sum);
      if (uv == null) return null;

      final candidate = ColorTemperatureMath.fromUv(uv);
      if (candidate == null) return null;

      result = candidate;
      if ((candidate.kelvin - estimate).abs() < convergenceKelvin) {
        break;
      }
      estimate = candidate.kelvin;
    }
    return result;
  }
}

const _channel = MethodChannel('com.example.aperture_diary/lens');

/// Reads the sensor's colour calibration from the platform.
///
/// Returns null on platforms without Camera2, and on sensors that publish no
/// calibration — in which case a raw white point cannot be interpreted and
/// colour has to be measured from rendered pixels instead.
Future<SensorColorCalibration?> readSensorColorCalibration({
  String? cameraName,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'getColorCalibration',
      <String, Object?>{'cameraName': cameraName},
    );
    return SensorColorCalibration.fromMap(raw);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
