import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'exposure.dart';

/// Exposure and colour metadata for one preview frame, straight from the
/// camera's own capture result.
///
/// This is the frame's own account of itself. Everything here was decided by
/// the camera for the very frame whose pixels are being sampled, which is what
/// makes it usable where a still capture's EXIF is not: stills run through a
/// different pipeline, so their numbers describe a different image.
@immutable
class CaptureMetadata {
  const CaptureMetadata({
    this.exposureTimeSeconds,
    this.iso,
    this.aperture,
    this.postRawSensitivityBoost,
    this.focalLengthMm,
    this.aeState,
    this.aeConverged,
    this.aeExposureCompensation,
    this.neutralColorPoint,
    this.awbState,
    this.awbConverged,
    this.awbMode,
    this.colorCorrectionGains,
    required this.receivedAt,
  });

  final double? exposureTimeSeconds;

  /// Sensor sensitivity, before any post-raw boost.
  final int? iso;

  final double? aperture;

  /// Sensitivity applied after the raw stage, as a percentage where 100 means
  /// none. Devices that use it would otherwise appear less sensitive than they
  /// are, making every scene read brighter than it is.
  final int? postRawSensitivityBoost;

  final double? focalLengthMm;

  final int? aeState;

  /// Whether auto-exposure has settled. Lets a measurement wait for the fact
  /// rather than for a fixed delay that may be too short or needlessly long.
  final bool? aeConverged;

  final int? aeExposureCompensation;

  /// The ISP's white point in raw sensor space, as three values.
  ///
  /// Not affected by the auto white balance gains, so unlike the rendered
  /// pixels it still describes the illuminant.
  final List<double>? neutralColorPoint;

  final int? awbState;
  final bool? awbConverged;
  final int? awbMode;

  /// The gains auto white balance applied, as R, Ge, Go, B.
  final List<double>? colorCorrectionGains;

  final DateTime receivedAt;

  /// Effective ISO including any post-raw boost.
  double? get effectiveIso {
    final base = iso;
    if (base == null || base <= 0) return null;
    final boost = postRawSensitivityBoost;
    if (boost == null || boost <= 0) return base.toDouble();
    return base * boost / 100.0;
  }

  /// Whether this describes a real exposure that EV can be derived from.
  bool get hasExposure {
    final t = exposureTimeSeconds;
    final n = aperture;
    final s = effectiveIso;
    return t != null &&
        t > 0 &&
        n != null &&
        n > 0 &&
        s != null &&
        s > 0;
  }

  /// EV₁₀₀ these settings expose middle grey at.
  double? get ev100 {
    if (!hasExposure) return null;
    return ExposureMath.cameraEv100(
      aperture: aperture!,
      shutterSeconds: exposureTimeSeconds!,
      iso: effectiveIso!,
    );
  }

  /// How long ago this arrived. Metadata is thinned to about 10 Hz, so a value
  /// much older than that means the stream has stopped.
  Duration get age => DateTime.now().difference(receivedAt);

  String get summary {
    if (!hasExposure) return 'no exposure data';
    return '${ExposureMath.formatAperture(aperture!)}  '
        '${ExposureMath.formatShutter(exposureTimeSeconds!)}  '
        'ISO ${effectiveIso!.round()}';
  }

  static CaptureMetadata? fromMap(Object? raw) {
    if (raw is! Map) return null;

    double? asDouble(String key) {
      final v = raw[key];
      if (v is! num) return null;
      final d = v.toDouble();
      return d.isFinite ? d : null;
    }

    int? asInt(String key) {
      final v = raw[key];
      return v is num ? v.toInt() : null;
    }

    bool? asBool(String key) {
      final v = raw[key];
      return v is bool ? v : null;
    }

    List<double>? asDoubles(String key, int length) {
      final v = raw[key];
      if (v is! List || v.length != length) return null;
      final out = <double>[];
      for (final item in v) {
        if (item is! num) return null;
        final d = item.toDouble();
        if (!d.isFinite) return null;
        out.add(d);
      }
      return out;
    }

    final exposureNs = raw['exposureTimeNs'];
    final exposureSeconds =
        exposureNs is num ? exposureNs.toDouble() / 1e9 : null;

    return CaptureMetadata(
      exposureTimeSeconds:
          exposureSeconds != null && exposureSeconds > 0 ? exposureSeconds : null,
      iso: asInt('sensitivityIso'),
      aperture: asDouble('aperture'),
      postRawSensitivityBoost: asInt('postRawSensitivityBoost'),
      focalLengthMm: asDouble('focalLengthMm'),
      aeState: asInt('aeState'),
      aeConverged: asBool('aeConverged'),
      aeExposureCompensation: asInt('aeExposureCompensation'),
      neutralColorPoint: asDoubles('neutralColorPoint', 3),
      awbState: asInt('awbState'),
      awbConverged: asBool('awbConverged'),
      awbMode: asInt('awbMode'),
      colorCorrectionGains: asDoubles('colorCorrectionGains', 4),
      receivedAt: DateTime.now(),
    );
  }
}

/// Subscribes to the per-frame capture metadata the forked CameraX plugin
/// publishes.
///
/// Absence is a normal state, not an error: iOS, the web, an unforked plugin,
/// or a CameraX version whose internals have moved all produce no events. Every
/// caller must keep working from [latest] being null.
class CaptureMetadataStream {
  CaptureMetadataStream();

  static const EventChannel _channel = EventChannel(
    'plugins.flutter.io/camera_android_camerax/capture_metadata',
  );

  static const MethodChannel _probeChannel = MethodChannel(
    'plugins.flutter.io/camera_android_camerax/capture_metadata_probe',
  );

  /// Asks the platform whether the forked plugin is running, and what it has
  /// seen so far.
  ///
  /// Returns null when the channel does not exist, which is the unambiguous
  /// signal that the fork is not in play — distinct from a fork that is running
  /// but has nothing to report. Neither logging nor file writes can make that
  /// distinction: vendor ROMs drop application logs, and a file write can fail
  /// on its own.
  static Future<Map<String, Object?>?> probeStatus() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final result = await _probeChannel.invokeMapMethod<String, Object?>(
        'status',
      );
      return result;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  StreamSubscription<dynamic>? _subscription;
  final StreamController<CaptureMetadata> _controller =
      StreamController<CaptureMetadata>.broadcast();

  CaptureMetadata? _latest;

  /// Most recent metadata, or null if none has arrived.
  CaptureMetadata? get latest => _latest;

  /// Whether the platform is actually delivering metadata.
  bool get isAvailable => _latest != null;

  Stream<CaptureMetadata> get stream => _controller.stream;

  void start() {
    if (_subscription != null) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      debugPrint('CaptureMetadata: subscribing to platform stream');
      _subscription = _channel.receiveBroadcastStream().listen(
        (event) {
          final metadata = CaptureMetadata.fromMap(event);
          if (metadata == null) return;
          if (_latest == null) {
            debugPrint(
              'CaptureMetadata: first event — ${metadata.summary}, '
              'neutral=${metadata.neutralColorPoint}',
            );
          }
          _latest = metadata;
          if (!_controller.isClosed) _controller.add(metadata);
        },
        onError: (Object error) {
          // An unforked plugin has no such channel. Callers fall back.
          debugPrint('CaptureMetadata: stream error — $error');
        },
        cancelOnError: false,
      );
    } on MissingPluginException catch (e) {
      debugPrint('CaptureMetadata: channel missing — $e');
    }
  }

  /// Waits for auto-exposure to converge, or gives up after [timeout].
  ///
  /// Returns the metadata that reported convergence, or null if it never did.
  /// Waiting for the camera to say so beats a fixed delay in both directions:
  /// it does not cut a slow convergence short, and it does not sit idle once a
  /// fast one is done.
  ///
  /// [after] rejects readings taken before it. Exposure compensation takes a
  /// moment to be applied, so without this the still-converged state from
  /// before the change would satisfy the wait immediately and the servo would
  /// read the old exposure.
  Future<CaptureMetadata?> waitForAeConvergence({
    Duration timeout = const Duration(milliseconds: 1200),
    DateTime? after,
  }) async {
    bool acceptable(CaptureMetadata m) {
      if (m.aeConverged != true) return false;
      if (after != null && m.receivedAt.isBefore(after)) return false;
      return true;
    }

    final current = _latest;
    // Metadata arrives at about 10 Hz, so anything within a couple of frames
    // still describes now.
    if (current != null &&
        acceptable(current) &&
        current.age < const Duration(milliseconds: 250)) {
      return current;
    }

    try {
      return await stream.firstWhere(acceptable).timeout(timeout);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Next metadata to arrive after now, or null if none does in time.
  Future<CaptureMetadata?> nextFrame({
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    try {
      return await stream.first.timeout(timeout);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}
