import 'dart:async';
import 'dart:math';
import 'dart:ui' show Offset, Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'metering.dart';

/// Confidence band for a distance reading.
enum DistanceConfidence { low, medium, high }

/// One completed (or in-progress) distance estimate.
@immutable
class DistanceEstimate {
  const DistanceEstimate({
    required this.metres,
    required this.confidence,
    required this.progress,
    required this.baselineMetres,
    required this.sampleCount,
    this.lostTrack = false,
    this.coaching = 'Keep the spot on the subject — move sideways slowly',
  });

  final double metres;
  final DistanceConfidence confidence;

  /// 0..1 fill for the measure UI.
  final double progress;

  /// Largest camera translation used so far.
  final double baselineMetres;

  final int sampleCount;
  final bool lostTrack;
  final String coaching;

  bool get isUsable =>
      metres.isFinite &&
      metres > 0.25 &&
      metres < 25 &&
      confidence != DistanceConfidence.low &&
      sampleCount > 0;

  String get displayPrefix =>
      confidence == DistanceConfidence.high ? '' : '~';
}

/// Approximate pinhole intrinsics for the active preview stream.
@immutable
class CameraIntrinsics {
  const CameraIntrinsics({
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
  });

  final double fx;
  final double fy;
  final double cx;
  final double cy;

  /// Build from frame size + optional physical lens/sensor, else ~65° HFOV.
  factory CameraIntrinsics.approximate({
    required int width,
    required int height,
    double? focalLengthMm,
    double? sensorWidthMm,
  }) {
    final w = width.toDouble();
    final h = height.toDouble();
    double fx;
    if (focalLengthMm != null &&
        focalLengthMm > 0 &&
        sensorWidthMm != null &&
        sensorWidthMm > 0) {
      fx = focalLengthMm * w / sensorWidthMm;
    } else {
      // Typical phone wide FOV ≈ 65° horizontal.
      const hfov = 65 * pi / 180;
      fx = w / (2 * tan(hfov / 2));
    }
    final fy = fx;
    return CameraIntrinsics(fx: fx, fy: fy, cx: w / 2, cy: h / 2);
  }

  /// Pixel → camera-ray direction (not unit length).
  List<double> ray(double x, double y) => [(x - cx) / fx, (y - cy) / fy, 1.0];
}

/// Short-window visual-inertial distance estimate at a tracked preview spot.
class DistanceEstimator {
  DistanceEstimator({
    required this.quarterTurns,
    required this.mirror,
    this.focalLengthMm,
    this.sensorWidthMm,
  });

  final int quarterTurns;
  final bool mirror;
  final double? focalLengthMm;
  final double? sensorWidthMm;

  static const int _templateRadius = 10;
  static const int _searchRadius = 28;
  static const double _minBaselineM = 0.06;
  static const double _goodBaselineM = 0.22;
  static const int _maxSamples = 12;
  static const Duration _maxDuration = Duration(seconds: 8);

  final _imu = _ImuOdometry();
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<UserAccelerometerEvent>? _accelSub;

  bool _running = false;
  DateTime? _startedAt;

  Float64List? _template;
  int _templateSize = 0;
  double? _trackX;
  double? _trackY;
  int _misses = 0;

  _Keyframe? _keyframe;
  final List<double> _depths = [];
  double _maxBaseline = 0;
  DistanceEstimate? _last;

  bool get isRunning => _running;

  DistanceEstimate? get last => _last;

  Future<void> start({
    required Offset spotNormalized,
    required Size widgetSize,
    required CameraImage firstFrame,
  }) async {
    await stop();
    _running = true;
    _startedAt = DateTime.now();
    _depths.clear();
    _maxBaseline = 0;
    _misses = 0;
    _last = null;
    _keyframe = null;
    _trackX = null;
    _trackY = null;
    _template = null;

    _imu.reset();
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_imu.onGyro);
    _accelSub = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_imu.onAccel);

    final mapping = _mapSpot(firstFrame, spotNormalized, widgetSize);
    if (mapping == null) {
      _last = const DistanceEstimate(
        metres: double.nan,
        confidence: DistanceConfidence.low,
        progress: 0,
        baselineMetres: 0,
        sampleCount: 0,
        lostTrack: true,
        coaching: 'Could not lock onto that point — try again',
      );
      return;
    }

    final tmpl = _extractTemplate(firstFrame, mapping.x, mapping.y);
    if (tmpl == null) {
      _last = const DistanceEstimate(
        metres: double.nan,
        confidence: DistanceConfidence.low,
        progress: 0,
        baselineMetres: 0,
        sampleCount: 0,
        lostTrack: true,
        coaching: 'Point needs more texture — try a detailed area',
      );
      return;
    }

    _template = tmpl.$1;
    _templateSize = tmpl.$2;
    _trackX = mapping.x;
    _trackY = mapping.y;
    _keyframe = _Keyframe(
      x: mapping.x,
      y: mapping.y,
      pose: _imu.snapshot(),
    );
    _last = DistanceEstimate(
      metres: double.nan,
      confidence: DistanceConfidence.low,
      progress: 0.05,
      baselineMetres: 0,
      sampleCount: 0,
      coaching: 'Keep the spot on the subject — move sideways slowly',
    );
  }

  Future<void> stop() async {
    _running = false;
    await _gyroSub?.cancel();
    await _accelSub?.cancel();
    _gyroSub = null;
    _accelSub = null;
  }

  /// Feed a preview frame. Returns the latest estimate (may still be incomplete).
  DistanceEstimate? processFrame({
    required CameraImage image,
    required Offset spotNormalized,
    required Size widgetSize,
  }) {
    if (!_running) return _last;
    final started = _startedAt;
    if (started != null && DateTime.now().difference(started) > _maxDuration) {
      _running = false;
      _last = _finalize(coaching: 'Timed out — try a larger sideways move');
      return _last;
    }

    final pose = _imu.snapshot();
    final key = _keyframe;
    final tmpl = _template;
    var tx = _trackX;
    var ty = _trackY;
    if (key == null || tmpl == null || tx == null || ty == null) {
      return _last;
    }

    final tracked = _track(image, tmpl, _templateSize, tx, ty);
    if (tracked == null) {
      _misses++;
      if (_misses >= 8) {
        _running = false;
        _last = DistanceEstimate(
          metres: _medianOrNan(),
          confidence: DistanceConfidence.low,
          progress: _progress(),
          baselineMetres: _maxBaseline,
          sampleCount: _depths.length,
          lostTrack: true,
          coaching: 'Lost the point — retap the subject and measure again',
        );
      }
      return _last;
    }
    _misses = 0;
    _trackX = tracked.$1;
    _trackY = tracked.$2;
    tx = tracked.$1;
    ty = tracked.$2;

    final delta = pose.translationDelta(key.pose);
    final baseline = delta.length;
    if (baseline > _maxBaseline) _maxBaseline = baseline;

    // Reject pure rotation / tiny translation.
    if (baseline < _minBaselineM) {
      _last = DistanceEstimate(
        metres: _medianOrNan(),
        confidence: _confidence(),
        progress: _progress(),
        baselineMetres: _maxBaseline,
        sampleCount: _depths.length,
        coaching: baseline < 0.02
            ? 'Move the phone sideways (not just turn)'
            : 'A little more sideways motion…',
      );
      return _last;
    }

    final K = CameraIntrinsics.approximate(
      width: image.width,
      height: image.height,
      focalLengthMm: focalLengthMm,
      sensorWidthMm: sensorWidthMm,
    );

    final R = pose.rotationRelativeTo(key.pose);
    final depth = _triangulateDepth(
      x0: key.x,
      y0: key.y,
      x1: tx,
      y1: ty,
      R: R,
      T: delta,
      K: K,
    );

    if (depth != null && depth > 0.3 && depth < 20) {
      _depths.add(depth);
      if (_depths.length > _maxSamples) {
        _depths.removeAt(0);
      }
      // Refresh keyframe occasionally so drift stays bounded.
      if (baseline > _goodBaselineM * 0.7) {
        _keyframe = _Keyframe(x: tx, y: ty, pose: pose);
        final retmpl = _extractTemplate(image, tx, ty);
        if (retmpl != null) {
          _template = retmpl.$1;
          _templateSize = retmpl.$2;
        }
      }
    }

    final metres = _medianOrNan();
    final conf = _confidence();
    final done = conf == DistanceConfidence.high && _depths.length >= 4;

    _last = DistanceEstimate(
      metres: metres,
      confidence: conf,
      progress: done ? 1.0 : _progress(),
      baselineMetres: _maxBaseline,
      sampleCount: _depths.length,
      coaching: done
          ? 'Distance locked'
          : (conf == DistanceConfidence.medium
              ? 'Looking good — a bit more motion helps'
              : 'Keep the spot on the subject — move sideways slowly'),
    );

    if (done) {
      // Leave running until UI stops; progress stays full.
    }
    return _last;
  }

  DistanceEstimate _finalize({required String coaching}) {
    final metres = _medianOrNan();
    return DistanceEstimate(
      metres: metres,
      confidence: _confidence(),
      progress: _progress().clamp(0.0, 1.0),
      baselineMetres: _maxBaseline,
      sampleCount: _depths.length,
      coaching: coaching,
    );
  }

  double _progress() {
    final b = (_maxBaseline / _goodBaselineM).clamp(0.0, 0.7);
    final s = (_depths.length / 4.0).clamp(0.0, 0.3);
    return (0.05 + b + s).clamp(0.0, 1.0);
  }

  DistanceConfidence _confidence() {
    if (_depths.length < 2 || _maxBaseline < _minBaselineM) {
      return DistanceConfidence.low;
    }
    final m = _medianOrNan();
    if (!m.isFinite) return DistanceConfidence.low;
    final spread = _relativeSpread();
    if (_depths.length >= 4 &&
        _maxBaseline >= _goodBaselineM &&
        spread < 0.25) {
      return DistanceConfidence.high;
    }
    if (_depths.length >= 2 && _maxBaseline >= _minBaselineM && spread < 0.45) {
      return DistanceConfidence.medium;
    }
    return DistanceConfidence.low;
  }

  double _medianOrNan() {
    if (_depths.isEmpty) return double.nan;
    final sorted = List<double>.from(_depths)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return 0.5 * (sorted[mid - 1] + sorted[mid]);
  }

  double _relativeSpread() {
    if (_depths.length < 2) return 1.0;
    final m = _medianOrNan();
    if (!m.isFinite || m <= 0) return 1.0;
    var sum = 0.0;
    for (final d in _depths) {
      sum += (d - m).abs();
    }
    return (sum / _depths.length) / m;
  }

  SpotMapping? _mapSpot(
    CameraImage image,
    Offset spotNormalized,
    Size widgetSize,
  ) {
    return mapSpotToFrame(
      frameWidth: image.width,
      frameHeight: image.height,
      quarterTurns: quarterTurns,
      mirror: mirror,
      widgetSize: widgetSize,
      spot: spotNormalized,
      radiusInWidgetPixels: 18,
    );
  }

  /// Returns (template bytes as doubles 0..1, size).
  (Float64List, int)? _extractTemplate(
    CameraImage image,
    double cx,
    double cy,
  ) {
    final luma = _LumaPlane.of(image);
    if (luma == null) return null;
    final size = _templateRadius * 2 + 1;
    final out = Float64List(size * size);
    var i = 0;
    var sum = 0.0;
    for (var dy = -_templateRadius; dy <= _templateRadius; dy++) {
      for (var dx = -_templateRadius; dx <= _templateRadius; dx++) {
        final v = luma.read((cx + dx).round(), (cy + dy).round());
        if (v == null) return null;
        final n = v / 255.0;
        out[i++] = n;
        sum += n;
      }
    }
    final mean = sum / out.length;
    var varSum = 0.0;
    for (var k = 0; k < out.length; k++) {
      final d = out[k] - mean;
      out[k] = d;
      varSum += d * d;
    }
    // Reject flat patches (sky / blank wall).
    if (varSum / out.length < 1e-4) return null;
    return (out, size);
  }

  (double, double)? _track(
    CameraImage image,
    Float64List template,
    int size,
    double cx,
    double cy,
  ) {
    final luma = _LumaPlane.of(image);
    if (luma == null) return null;
    final half = size ~/ 2;
    var bestScore = -1.0;
    var bestX = cx;
    var bestY = cy;

    for (var oy = -_searchRadius; oy <= _searchRadius; oy += 1) {
      for (var ox = -_searchRadius; ox <= _searchRadius; ox += 1) {
        final px = cx + ox;
        final py = cy + oy;
        final score = _ncc(luma, template, size, half, px, py);
        if (score > bestScore) {
          bestScore = score;
          bestX = px;
          bestY = py;
        }
      }
    }
    if (bestScore < 0.35) return null;
    return (bestX, bestY);
  }

  double _ncc(
    _LumaPlane luma,
    Float64List template,
    int size,
    int half,
    double cx,
    double cy,
  ) {
    var sum = 0.0;
    var sumSq = 0.0;
    var cross = 0.0;
    var n = 0;
    var ti = 0;
    for (var dy = -half; dy <= half; dy++) {
      for (var dx = -half; dx <= half; dx++) {
        final v = luma.read((cx + dx).round(), (cy + dy).round());
        if (v == null) return -1;
        final p = v / 255.0;
        sum += p;
        sumSq += p * p;
        cross += p * template[ti++];
        n++;
      }
    }
    if (n == 0) return -1;
    final mean = sum / n;
    // Template is already mean-subtracted.
    var tmplEnergy = 0.0;
    for (final t in template) {
      tmplEnergy += t * t;
    }
    final patchEnergy = sumSq - n * mean * mean;
    if (patchEnergy < 1e-6 || tmplEnergy < 1e-6) return -1;
    // cross was with mean-subtracted template vs raw patch → subtract mean*sum(tmpl)=0
    // Adjust: cross_centered = Σ (p - mean) * t = Σ p*t - mean*Σ t, Σ t = 0
    return cross / sqrt(patchEnergy * tmplEnergy);
  }

  /// Depth along the first camera ray (metres), or null if poorly conditioned.
  static double? _triangulateDepth({
    required double x0,
    required double y0,
    required double x1,
    required double y1,
    required _Mat3 R,
    required _Vec3 T,
    required CameraIntrinsics K,
  }) {
    final d0 = K.ray(x0, y0);
    final d1 = K.ray(x1, y1);
    final rd0 = R.mulVec(_Vec3(d0[0], d0[1], d0[2]));
    final v1 = _Vec3(d1[0], d1[1], d1[2]);

    // z * (d1 × R d0) = -(d1 × T)
    final crossA = v1.cross(rd0);
    final crossB = v1.cross(T);
    final denom = crossA.dot(crossA);
    if (denom < 1e-10) return null;
    final z = -crossB.dot(crossA) / denom;
    if (!z.isFinite || z <= 0) return null;

    // Residual: how parallel is the second ray to the predicted point.
    final predicted = rd0.scale(z).plus(T);
    final predLen = predicted.length;
    if (predLen < 1e-9) return null;
    final cosAng = predicted.dot(v1) / (predLen * v1.length);
    if (cosAng < 0.97) return null; // ~14° — reject bad tracks

    // Metric depth along optical axis of cam0.
    final dirLen = sqrt(d0[0] * d0[0] + d0[1] * d0[1] + d0[2] * d0[2]);
    return z * (d0[2] / dirLen);
  }
}

class _Keyframe {
  _Keyframe({required this.x, required this.y, required this.pose});
  final double x;
  final double y;
  final _PoseSample pose;
}

class _PoseSample {
  _PoseSample({required this.rotation, required this.position});
  final _Mat3 rotation;
  final _Vec3 position;

  _Vec3 translationDelta(_PoseSample earlier) =>
      position.minus(earlier.position);

  _Mat3 rotationRelativeTo(_PoseSample earlier) =>
      rotation.mul(earlier.rotation.transpose());
}

/// Integrates gyro + user-accel into a short-lived camera pose.
class _ImuOdometry {
  _Mat3 _rotation = _Mat3.identity();
  _Vec3 _velocity = _Vec3.zero;
  _Vec3 _position = _Vec3.zero;
  DateTime? _lastGyro;
  DateTime? _lastAccel;

  void reset() {
    _rotation = _Mat3.identity();
    _velocity = _Vec3.zero;
    _position = _Vec3.zero;
    _lastGyro = null;
    _lastAccel = null;
  }

  void onGyro(GyroscopeEvent e) {
    final now = DateTime.now();
    final prev = _lastGyro;
    _lastGyro = now;
    if (prev == null) return;
    final dt = now.difference(prev).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 0.1) return;
    // Device coords: x right, y up, z out of screen (typical).
    _rotation = _rotation.mul(
      _Mat3.rotationFromAxisAngle(_Vec3(e.x, e.y, e.z), dt),
    );
    // Re-orthonormalize lightly.
    _rotation = _rotation.orthonormalized();
  }

  void onAccel(UserAccelerometerEvent e) {
    final now = DateTime.now();
    final prev = _lastAccel;
    _lastAccel = now;
    if (prev == null) return;
    final dt = now.difference(prev).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 0.1) return;

    final aDevice = _Vec3(e.x, e.y, e.z);
    final aWorld = _rotation.mulVec(aDevice);

    // Zero-velocity update when nearly still — curbs double-integration drift.
    final still = aDevice.length < 0.35;
    if (still) {
      _velocity = _velocity.scale(0.85);
    } else {
      _velocity = _velocity.plus(aWorld.scale(dt));
      // Soft damping.
      _velocity = _velocity.scale(0.995);
    }
    _position = _position.plus(_velocity.scale(dt));
  }

  _PoseSample snapshot() =>
      _PoseSample(rotation: _rotation, position: _position);
}

class _Vec3 {
  const _Vec3(this.x, this.y, this.z);
  final double x, y, z;
  static const zero = _Vec3(0, 0, 0);

  double get length => sqrt(x * x + y * y + z * z);

  _Vec3 plus(_Vec3 o) => _Vec3(x + o.x, y + o.y, z + o.z);
  _Vec3 minus(_Vec3 o) => _Vec3(x - o.x, y - o.y, z - o.z);
  _Vec3 scale(double s) => _Vec3(x * s, y * s, z * s);
  double dot(_Vec3 o) => x * o.x + y * o.y + z * o.z;
  _Vec3 cross(_Vec3 o) => _Vec3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );
}

class _Mat3 {
  _Mat3(this.m);
  final List<double> m; // row-major 9

  static _Mat3 identity() => _Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  static _Mat3 rotationFromAxisAngle(_Vec3 w, double dt) {
    final wx = w.x * dt;
    final wy = w.y * dt;
    final wz = w.z * dt;
    // Small-angle Rodrigues.
    return _Mat3([
      1,
      -wz,
      wy,
      wz,
      1,
      -wx,
      -wy,
      wx,
      1,
    ]).orthonormalized();
  }

  _Mat3 mul(_Mat3 o) {
    final a = m;
    final b = o.m;
    return _Mat3([
      a[0] * b[0] + a[1] * b[3] + a[2] * b[6],
      a[0] * b[1] + a[1] * b[4] + a[2] * b[7],
      a[0] * b[2] + a[1] * b[5] + a[2] * b[8],
      a[3] * b[0] + a[4] * b[3] + a[5] * b[6],
      a[3] * b[1] + a[4] * b[4] + a[5] * b[7],
      a[3] * b[2] + a[4] * b[5] + a[5] * b[8],
      a[6] * b[0] + a[7] * b[3] + a[8] * b[6],
      a[6] * b[1] + a[7] * b[4] + a[8] * b[7],
      a[6] * b[2] + a[7] * b[5] + a[8] * b[8],
    ]);
  }

  _Vec3 mulVec(_Vec3 v) => _Vec3(
        m[0] * v.x + m[1] * v.y + m[2] * v.z,
        m[3] * v.x + m[4] * v.y + m[5] * v.z,
        m[6] * v.x + m[7] * v.y + m[8] * v.z,
      );

  _Mat3 transpose() => _Mat3([
        m[0],
        m[3],
        m[6],
        m[1],
        m[4],
        m[7],
        m[2],
        m[5],
        m[8],
      ]);

  _Mat3 orthonormalized() {
    var c0 = _Vec3(m[0], m[3], m[6]);
    var c1 = _Vec3(m[1], m[4], m[7]);
    c0 = c0.scale(1.0 / max(1e-12, c0.length));
    c1 = c1.minus(c0.scale(c0.dot(c1)));
    c1 = c1.scale(1.0 / max(1e-12, c1.length));
    final c2 = c0.cross(c1);
    return _Mat3([c0.x, c1.x, c2.x, c0.y, c1.y, c2.y, c0.z, c1.z, c2.z]);
  }
}

/// Grayscale access for patch tracking.
class _LumaPlane {
  _LumaPlane({
    required this.width,
    required this.height,
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
    required this.isBgra,
  });

  final int width;
  final int height;
  final Uint8List bytes;
  final int bytesPerRow;
  final int bytesPerPixel;
  final bool isBgra;

  static _LumaPlane? of(CameraImage image) {
    if (image.planes.isEmpty) return null;
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        final p = image.planes[0];
        return _LumaPlane(
          width: image.width,
          height: image.height,
          bytes: p.bytes,
          bytesPerRow: p.bytesPerRow,
          bytesPerPixel: p.bytesPerPixel ?? 1,
          isBgra: false,
        );
      case ImageFormatGroup.bgra8888:
        final p = image.planes[0];
        return _LumaPlane(
          width: image.width,
          height: image.height,
          bytes: p.bytes,
          bytesPerRow: p.bytesPerRow,
          bytesPerPixel: 4,
          isBgra: true,
        );
      default:
        return null;
    }
  }

  int? read(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return null;
    if (isBgra) {
      final i = y * bytesPerRow + x * 4;
      if (i + 2 >= bytes.length) return null;
      final b = bytes[i] & 0xFF;
      final g = bytes[i + 1] & 0xFF;
      final r = bytes[i + 2] & 0xFF;
      return (0.2126 * r + 0.7152 * g + 0.0722 * b).round();
    }
    final i = y * bytesPerRow + x * bytesPerPixel;
    if (i < 0 || i >= bytes.length) return null;
    return bytes[i] & 0xFF;
  }
}
