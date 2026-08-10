import 'dart:async';
import 'dart:io';
import 'dart:math' show max;

import 'package:camera/camera.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'album_page.dart';
import 'album_shot.dart';
import 'calibration.dart';
import 'distance_estimator.dart';
import 'exposure.dart';
import 'film_format.dart';
import 'film_frame.dart';
import 'film_stock.dart';
import 'flash_page.dart';
import 'focal_arc_dial.dart';
import 'gear.dart';
import 'home_page.dart';
import 'lens_info.dart';
import 'metering.dart';
import 'units.dart';
import 'wheel_dial.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0A0A0A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final cameras = await availableCameras();
  if (cameras.isEmpty) {
    runApp(const _NoCameraApp());
    return;
  }
  final rear = cameras.firstWhere(
    (c) => c.lensDirection == CameraLensDirection.back,
    orElse: () => cameras.first,
  );
  runApp(ApertureDiaryApp(camera: rear));
}

const Color _accent = Color(0xFFFFB300);

/// Sentinel returned by the focal picker for the free-zoom option.
const Object _freeZoomChoice = Object();

final ThemeData _darkTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF0A0A0A),
  colorScheme: const ColorScheme.dark(
    primary: _accent,
    secondary: _accent,
    surface: Color(0xFF141414),
    onPrimary: Colors.black,
    onSurface: Colors.white,
  ),
  useMaterial3: true,
  sliderTheme: const SliderThemeData(
    activeTrackColor: _accent,
    thumbColor: _accent,
  ),
);

class _NoCameraApp extends StatelessWidget {
  const _NoCameraApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _darkTheme,
      home: const Scaffold(
        body: Center(child: Text('No camera found on this device.')),
      ),
    );
  }
}

class ApertureDiaryApp extends StatelessWidget {
  final CameraDescription camera;
  const ApertureDiaryApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ApertureDiary',
      debugShowCheckedModeBanner: false,
      theme: _darkTheme,
      home: Builder(
        builder: (context) => HomePage(
          onOpenMeter: (film) async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ApertureDiaryPage(
                  camera: camera,
                  film: film,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class ApertureDiaryPage extends StatefulWidget {
  final CameraDescription camera;
  final FilmStock film;

  const ApertureDiaryPage({
    super.key,
    required this.camera,
    required this.film,
  });

  @override
  State<ApertureDiaryPage> createState() => _ApertureDiaryPageState();
}

class _ApertureDiaryPageState extends State<ApertureDiaryPage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;
  String _errorMsg = '';

  /// Metering point, normalized to the preview widget.
  Offset _meterPoint = const Offset(0.5, 0.5);

  /// Radius of the metered patch, in preview logical pixels.
  static const double _spotRadius = 18.0;

  /// How long to let auto-exposure settle before trusting its choice.
  static const Duration _aeSettleDelay = Duration(milliseconds: 900);
  static const Duration _autoMeterCooldown = Duration(seconds: 2);

  ExposureParams? _params;
  SpotSample? _sample;

  /// Scene brightness as EV₁₀₀ (ISO-normalized). Display uses Hasselblad
  /// lens EV via [_lensEv].
  double? _ev;
  double _calibration = 0.0;

  /// Hasselblad / Compur orange-scale EV at the current metering EI.
  double? get _lensEv {
    final ev100 = _ev;
    if (ev100 == null) return null;
    return ExposureMath.lensEvFromEv100(ev100: ev100, iso: _meterIso);
  }

  /// RGB / calibration row; collapsed unless the user expands it.
  bool _meterDetailsOpen = false;

  bool _measuring = false;
  bool _saving = false;
  /// Inline status to the left of the shutter (replaces save SnackBars).
  String? _captureHint;
  bool _captureHintError = false;
  Timer? _captureHintTimer;
  String _status = 'Starting camera…';
  DateTime? _lastMeasuredAt;
  int _failedMeasurements = 0;

  bool _isProcessing = false;
  final Stopwatch _publishClock = Stopwatch()..start();
  Size? _previewSize;

  /// True while a dialog or sheet is up. Frame processing, repaints, and
  /// automatic re-metering all pause: a measurement restarts the capture
  /// session on devices that refuse a still capture mid-stream, and doing that
  /// under an open dialog churns the tree while it holds keyboard focus.
  bool _modalOpen = false;

  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  /// Point-first subject distance (IMU + track). Null when idle.
  DistanceEstimator? _distanceEstimator;
  DistanceEstimate? _distanceEstimate;
  double? _subjectDistanceM;
  bool _distanceStartPending = false;
  bool _distanceSessionActive = false;
  bool get _measuringDistance => _distanceSessionActive;

  /// Last factor the user set by hand. The opposite is what we solve for.
  LastEdited _lastEdited = LastEdited.aperture;
  /// Starts from the loaded film; editable only on this page.
  late FilmStock _film = widget.film;
  /// Box / tungsten-rated speed. Daylight+85 uses [_meterIso].
  late int _iso = _film.iso;
  /// Tungsten stocks: meter at Kodak daylight EI with an 85 filter (−⅔ stop).
  late bool _daylight85 = _film.isTungsten && _film.meterDaylight85;
  double _aperture = 2.8;
  double _shutter = 1 / 125;

  /// EI used for EV / shutter / aperture solves.
  int get _meterIso {
    if (_film.isTungsten && _daylight85) {
      return ExposureMath.eiWithWratten85(_iso);
    }
    return _iso;
  }

  String get _isoChipLabel {
    if (_film.isTungsten && _daylight85) return 'EI $_meterIso';
    return 'ISO $_iso';
  }

  String get _isoSubtitle {
    if (_film.isTungsten && _daylight85) {
      return 'EI $_meterIso +85';
    }
    if (_film.isTungsten) return 'ISO $_iso T';
    return 'ISO $_iso';
  }

  UserCamera? _body;
  List<UserLens> _availableLenses = [];
  UserLens? _selectedLens;

  /// Focal-length viewfinder simulation — format is locked by the loaded roll.
  FilmFormat get _simFormat => _film.frameFormat;
  late double _simFocalMm = _simFormat.defaultFocalMm;
  LensInfo? _lensInfo;

  List<double> get _availableApertures {
    if (_body != null && !_body!.interchangeableLenses) {
      return ExposureMath.aperturesInRange(
        maxAperture: _body!.fixedMaxAperture,
        minAperture: _body!.fixedMinAperture,
      );
    }
    if (_selectedLens != null) {
      return ExposureMath.aperturesInRange(
        maxAperture: _selectedLens!.maxAperture,
        minAperture: _selectedLens!.minAperture,
      );
    }
    return ExposureMath.standardApertures;
  }

  List<double> get _availableShutters {
    final body = _body;
    if (body == null) return ExposureMath.standardShutters;
    return ExposureMath.shuttersInRange(
      fastest: body.fastestShutter,
      slowest: body.slowestShutter,
      includeBulb: body.hasBulb,
    );
  }

  List<double> get _timedShutters =>
      _availableShutters.where((s) => s > 0).toList();

  /// Bulb (or no body yet): long holds continue past 30″ with no ceiling.
  bool get _unlimitedBulbHolds {
    final body = _body;
    if (body == null) return true;
    return body.hasBulb;
  }

  /// Timed shutter used for EV solve when B is selected.
  double get _solveShutterSeconds {
    if (!ExposureMath.isBulb(_shutter)) return _shutter;
    final timed = _timedShutters;
    return timed.isNotEmpty ? timed.last : 1.0;
  }

  List<double> get _focalDialLensesMm {
    final lens = _selectedLens;
    if (lens != null) {
      if (lens.isZoom && lens.maxFocalMm != null) {
        return [lens.minFocalMm, lens.maxFocalMm!];
      }
      return [lens.minFocalMm];
    }
    final body = _body;
    if (body != null &&
        !body.interchangeableLenses &&
        body.fixedFocalMm != null) {
      return [body.fixedFocalMm!];
    }
    return _simFormat.standardLensesMm;
  }

  /// Popup arc dial for choosing simulated focal length.
  bool _focalDialOpen = false;
  Timer? _focalDialHideTimer;
  static const Duration _focalDialHideDelay = Duration(milliseconds: 1500);

  final GlobalKey _previewKey = GlobalKey();

  int get _quarterTurns => (widget.camera.sensorOrientation ~/ 90) % 4;

  bool get _mirror =>
      widget.camera.lensDirection == CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCalibration();
    _loadGear();
    _startCamera();
  }

  Future<void> _loadCalibration() async {
    final value = await CalibrationStore.load();
    if (mounted && value != 0.0) {
      setState(() => _calibration = value);
    }
  }

  Future<void> _loadGear() async {
    // Prefer the persisted roll (includes last lens) over the constructor snapshot.
    final saved = await FilmStockStore.loadSelected();
    for (final f in saved) {
      if (f.id == _film.id) {
        if (!mounted) return;
        setState(() {
          _film = f;
          _iso = f.iso;
          _daylight85 = f.isTungsten && f.meterDaylight85;
        });
        break;
      }
    }

    final cameraId = _film.cameraId;
    if (cameraId == null) return;

    final cameras = await GearStore.loadCameras();
    UserCamera? body;
    for (final c in cameras) {
      if (c.id == cameraId) {
        body = c;
        break;
      }
    }
    final cam = body;
    if (cam == null || !mounted) return;

    final allLenses = await GearStore.loadLenses();
    final lenses = lensesForCamera(cam, allLenses);
    UserLens? selected;
    final lensId = _film.lensId;
    if (lensId != null) {
      for (final l in lenses) {
        if (l.id == lensId) {
          selected = l;
          break;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _body = cam;
      _availableLenses = lenses;
      _selectedLens = selected;
      _clampExposureToGear();
      if (selected != null) {
        _simFocalMm = _clampFocalToLens(selected, _simFocalMm);
      } else if (!cam.interchangeableLenses && cam.fixedFocalMm != null) {
        _simFocalMm = cam.fixedFocalMm!;
      }
    });
  }

  /// Keep simulated focal inside a lens zoom range (or snap to a prime).
  double _clampFocalToLens(UserLens lens, double mm) {
    if (!lens.isZoom || lens.maxFocalMm == null) return lens.minFocalMm;
    final lo = lens.minFocalMm <= lens.maxFocalMm!
        ? lens.minFocalMm
        : lens.maxFocalMm!;
    final hi = lens.minFocalMm <= lens.maxFocalMm!
        ? lens.maxFocalMm!
        : lens.minFocalMm;
    return mm.clamp(lo, hi);
  }

  void _clampExposureToGear() {
    final apertures = _availableApertures;
    final shutters = _availableShutters;
    if (apertures.isNotEmpty && !apertures.contains(_aperture)) {
      _aperture = ExposureMath.snapAperture(_aperture, options: apertures);
    }
    if (shutters.isNotEmpty) {
      final match = shutters.any((s) => (s - _shutter).abs() < 1e-12);
      if (!match) {
        _shutter = ExposureMath.snapShutter(
          ExposureMath.isBulb(_shutter) ? 1 / 125 : _shutter,
          options: shutters,
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      if (ctrl.value.isStreamingImages) ctrl.stopImageStream();
    } else if (state == AppLifecycleState.resumed) {
      if (!ctrl.value.isStreamingImages) ctrl.startImageStream(_onFrame);
    }
  }

  @override
  void dispose() {
    _focalDialHideTimer?.cancel();
    _captureHintTimer?.cancel();
    unawaited(_distanceEstimator?.stop());
    _distanceEstimator = null;
    WidgetsBinding.instance.removeObserver(this);
    final ctrl = _controller;
    if (ctrl != null) {
      if (ctrl.value.isStreamingImages) ctrl.stopImageStream();
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _startCamera() async {
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );

    try {
      await _controller!.initialize();
      _minZoom = await _controller!.getMinZoomLevel();
      _maxZoom = await _controller!.getMaxZoomLevel();
      // Keep optical zoom at its native wide end — framing is done by the
      // format / focal simulation instead.
      if (_maxZoom > _minZoom) {
        await _controller!.setZoomLevel(_minZoom);
      }
      await _controller!.startImageStream(_onFrame);
      await _loadLensInfo();
      if (!mounted) return;
      setState(() {
        _isInitialized = true;
        _status = 'Metering…';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _errorMsg = 'Camera failed to start:\n$e');
      }
    }
  }

  Future<void> _loadLensInfo() async {
    final platform = await readLensInfoFromPlatform(
      cameraName: widget.camera.name,
    );
    if (!mounted) return;
    if (platform != null) {
      setState(() => _lensInfo = platform);
    }
  }

  // ---------------------------------------------------------------- metering

  /// Locks auto-exposure onto the metered spot, then reads back the exposure
  /// the camera chose. Those settings are what make an absolute EV possible:
  /// pixel brightness alone only says how the scene compares to whatever the
  /// camera exposed for.
  Future<void> _measure({bool auto = false}) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _measuring) return;
    if (_modalOpen) return;

    setState(() {
      _measuring = true;
      _status = auto ? 'Re-metering…' : 'Metering…';
    });

    try {
      try {
        await ctrl.setExposureMode(ExposureMode.auto);
        await ctrl.setExposurePoint(_meterPoint);
      } on CameraException {
        // Device may not support a metering point; AE average will do.
      }

      await Future<void>.delayed(_aeSettleDelay);

      // Lock before capturing so the still and the preview stream share one
      // exposure, and the reading stays valid while panning around.
      try {
        await ctrl.setExposureMode(ExposureMode.locked);
      } on CameraException {
        // Not fatal: the reading is still correct for this instant.
      }

      final params = await _readExposure(ctrl);
      _lastMeasuredAt = DateTime.now();
      if (!mounted) return;

      setState(() {
        if (params == null) {
          _failedMeasurements++;
          _params = null;
          _ev = null;
          _status = _failedMeasurements >= 3
              ? 'This device reports no exposure data — EV unavailable'
              : 'No exposure data in capture, retrying…';
        } else {
          _failedMeasurements = 0;
          _params = params;
          _ev = null; // Recomputed from the next frame.
          _status = 'Exposure locked';
        }
      });
    } catch (e) {
      _lastMeasuredAt = DateTime.now();
      if (mounted) {
        setState(() {
          _failedMeasurements++;
          _status = 'Metering failed: $e';
        });
      }
    } finally {
      _measuring = false;
      if (mounted) setState(() {});
    }
  }

  Future<ExposureParams?> _readExposure(CameraController ctrl) async {
    final bytes = await _captureStillBytes(ctrl);
    final tags = await readExifFromBytes(bytes);
    final exifLens = parseLensInfoFromExif(tags);
    if (exifLens != null) {
      final merged = mergeLensInfo(_lensInfo, exifLens);
      if (merged != null && mounted) {
        setState(() => _lensInfo = merged);
      }
    }
    return parseExposureParams(tags);
  }

  /// Centre-crop fraction for the current format + focal simulation.
  double get _simCrop {
    final lens = _lensInfo;
    if (lens == null || !lens.isUsable) return 1.0;
    return lens.cropForFormat(_simFormat, _simFocalMm, 1.0);
  }

  bool get _simLimited => _simCrop >= 0.999;

  /// Takes a still, pausing the preview analysis stream so capture stays snappy.
  Future<Uint8List> _captureStillBytes(CameraController ctrl) async {
    final wasStreaming = ctrl.value.isStreamingImages;
    if (wasStreaming) {
      await ctrl.stopImageStream();
    }

    try {
      final file = await ctrl.takePicture();
      try {
        return await file.readAsBytes();
      } finally {
        try {
          await File(file.path).delete();
        } catch (_) {
          // Temp file cleanup is best effort.
        }
      }
    } finally {
      if (wasStreaming && !ctrl.value.isStreamingImages) {
        await ctrl.startImageStream(_onFrame);
        try {
          await ctrl.setExposureMode(ExposureMode.locked);
        } on CameraException {
          // Ignore.
        }
      }
    }
  }

  /// Captures a still and saves it to the in-app album (no border stamp, no
  /// phone gallery write). Export-to-phone lives on the album detail page.
  Future<void> _captureFrame() async {
    final ctrl = _controller;
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        _saving ||
        _measuring ||
        _modalOpen) {
      return;
    }

    final shutter = _stampShutter();
    final aperture = _stampAperture();
    final iso = _meterIso;
    final filmId = _film.id;
    final filmName = _film.name;
    final formatLabel = _simFormat.label;
    final focalMm = _simFocalMm;
    // Persist the Hasselblad lens-scale EV the user sees, at this film ISO.
    final ev = _lensEv;
    final cropFraction = _simCrop;
    final cropAspectRatio = _simFormat.aspectRatio;

    setState(() {
      _saving = true;
      _setCaptureHint('Capturing…');
    });
    late final Uint8List jpeg;
    try {
      jpeg = await _captureStillBytes(ctrl);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _setCaptureHint(
            'Capture failed',
            error: true,
            clearAfter: const Duration(seconds: 3),
          );
        });
      } else {
        _saving = false;
      }
      return;
    } finally {
      if (mounted && _saving) {
        setState(() => _saving = false);
      } else if (!mounted) {
        _saving = false;
      }
    }

    if (!mounted) return;
    setState(() => _setCaptureHint('Saving…'));
    AlbumShotStore.beginBackgroundSave();
    unawaited(
      _saveCaptureToAlbum(
        jpeg: jpeg,
        shutter: shutter,
        aperture: aperture,
        iso: iso,
        filmId: filmId,
        filmName: filmName,
        formatLabel: formatLabel,
        focalMm: focalMm,
        ev: ev,
        cropFraction: cropFraction,
        cropAspectRatio: cropAspectRatio,
      ),
    );
  }

  Future<void> _saveCaptureToAlbum({
    required Uint8List jpeg,
    required String shutter,
    required String aperture,
    required int iso,
    required String filmId,
    required String filmName,
    required String formatLabel,
    required double focalMm,
    required double? ev,
    required double cropFraction,
    required double cropAspectRatio,
  }) async {
    try {
      final bytes = await cropFilmJpegInBackground(
        jpegBytes: jpeg,
        cropFraction: cropFraction,
        cropAspectRatio: cropAspectRatio,
      );
      await AlbumShotStore.add(
        jpegBytes: bytes,
        shutter: shutter,
        aperture: aperture,
        iso: iso,
        filmId: filmId,
        filmName: filmName,
        formatLabel: formatLabel,
        focalMm: focalMm,
        ev: ev,
        flash: false,
      );
      if (mounted) {
        setState(
          () => _setCaptureHint(
            'Saved',
            clearAfter: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _setCaptureHint(
            'Save failed',
            error: true,
            clearAfter: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      AlbumShotStore.endBackgroundSave();
    }
  }

  void _setCaptureHint(
    String? message, {
    bool error = false,
    Duration? clearAfter,
  }) {
    _captureHintTimer?.cancel();
    _captureHint = message;
    _captureHintError = error;
    if (message != null && clearAfter != null) {
      _captureHintTimer = Timer(clearAfter, () {
        if (!mounted) return;
        setState(() {
          _captureHint = null;
          _captureHintError = false;
        });
      });
    }
  }

  bool get _solvingShutter => _lastEdited == LastEdited.aperture;

  bool get _solvingAperture => _lastEdited == LastEdited.shutter;

  String _stampShutter() {
    if (_solvingShutter) {
      final ev = _ev;
      if (ev != null) {
        final t = ExposureMath.shutterFromEv(
          ev100: ev,
          aperture: _aperture,
          iso: _meterIso,
        );
        return ExposureMath.formatShutter(
          ExposureMath.snapShutter(
            t,
            options: _timedShutters,
            allowUnlimited: _unlimitedBulbHolds,
          ),
        );
      }
    }
    return ExposureMath.formatShutter(_shutter);
  }

  String _stampAperture() {
    if (_solvingAperture) {
      final ev = _ev;
      if (ev != null) {
        final n = ExposureMath.apertureFromEv(
          ev100: ev,
          shutterSeconds: _solveShutterSeconds,
          iso: _meterIso,
        );
        return ExposureMath.formatAperture(
          ExposureMath.snapAperture(n, options: _availableApertures),
        );
      }
    }
    return ExposureMath.formatAperture(_aperture);
  }

  /// Runs a modal, pausing camera-driven rebuilds for as long as it is open.
  Future<T?> _whileModalOpen<T>(Future<T?> Function() show) async {
    _modalOpen = true;
    try {
      return await show();
    } finally {
      _modalOpen = false;
    }
  }

  void _onFrame(CameraImage image) {
    if (!mounted || _isProcessing || _modalOpen) return;
    _isProcessing = true;
    try {
      final previewSize = _previewSize;
      if (previewSize == null) return;

      var spot = _meterPoint;
      final crop = _simCrop;
      if (crop < 1.0) {
        final mapped =
            FilmOptics.mapViewfinderToPreview(spot.dx, spot.dy, crop);
        spot = Offset(mapped.x, mapped.y);
      }

      if (_distanceStartPending) {
        _distanceStartPending = false;
        unawaited(_beginDistanceMeasure(image, spot, previewSize));
      } else if (_distanceEstimator != null && _measuringDistance) {
        final estimator = _distanceEstimator!;
        final est = estimator.processFrame(
          image: image,
          spotNormalized: spot,
          widgetSize: previewSize,
        );
        if (est != null) {
          _distanceEstimate = est;
          if (est.isUsable) {
            _subjectDistanceM = est.metres;
          }
          final locked = est.progress >= 1.0 &&
              est.confidence == DistanceConfidence.high;
          final stopped = !estimator.isRunning;
          if (locked || stopped) {
            unawaited(_finishDistanceMeasure(keepResult: est.isUsable || locked));
          }
        }
      }

      final sample = sampleSpot(
        image: image,
        spot: spot,
        widgetSize: previewSize,
        quarterTurns: _quarterTurns,
        mirror: _mirror,
        radiusInWidgetPixels: _spotRadius,
      );
      if (sample == null) return;

      _sample = sample;

      final params = _params;
      if (params != null) {
        final raw = ExposureMath.sceneEv(
              cameraEv100: params.ev100,
              linearLuminance: sample.linearLuminance,
            ) +
            _calibration;
        // Light smoothing keeps the digits readable without adding lag.
        final previous = _ev;
        _ev = previous == null ? raw : previous + (raw - previous) * 0.35;
      }

      if (!_measuringDistance) {
        _maybeAutoMeter(sample);
      }

      if (_publishClock.elapsedMilliseconds >= 80) {
        _publishClock.reset();
        setState(() {});
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _beginDistanceMeasure(
    CameraImage image,
    Offset spot,
    Size previewSize,
  ) async {
    await _distanceEstimator?.stop();
    final est = DistanceEstimator(
      quarterTurns: _quarterTurns,
      mirror: _mirror,
      focalLengthMm: _lensInfo?.focalLengthMm,
      sensorWidthMm: _lensInfo?.sensorWidthMm,
    );
    await est.start(
      spotNormalized: spot,
      widgetSize: previewSize,
      firstFrame: image,
    );
    if (!mounted) {
      await est.stop();
      return;
    }
    setState(() {
      _distanceEstimator = est;
      _distanceEstimate = est.last;
    });
  }

  void _requestDistanceMeasure() {
    if (!_isInitialized || _saving || _measuring) return;
    setState(() {
      _distanceSessionActive = true;
      _distanceStartPending = true;
      _distanceEstimate = null;
      _status = 'Measuring distance…';
    });
  }

  Future<void> _finishDistanceMeasure({required bool keepResult}) async {
    final est = _distanceEstimator;
    final reading = _distanceEstimate;
    await est?.stop();
    if (!mounted) return;
    setState(() {
      _distanceEstimator = null;
      _distanceStartPending = false;
      _distanceSessionActive = false;
      if (keepResult && reading != null && reading.isUsable) {
        _subjectDistanceM = reading.metres;
        _distanceEstimate = reading;
        _status = 'Distance ${reading.displayPrefix}'
            '${formatLength(reading.metres, useFeet: false)}';
      } else if (!keepResult) {
        _distanceEstimate = null;
        _status = 'Distance measure cancelled';
      } else {
        _status = reading?.coaching ?? 'Distance unavailable — enter manually';
      }
    });
  }

  Future<void> _cancelDistanceMeasure() =>
      _finishDistanceMeasure(keepResult: false);

  /// Re-meters when the locked exposure no longer suits the spot: once the
  /// patch clips or crushes, the tone curve stops being invertible and the
  /// reading would drift.
  void _maybeAutoMeter(SpotSample sample) {
    if (_measuring || _modalOpen || _failedMeasurements >= 3) return;
    final last = _lastMeasuredAt;
    if (last != null && DateTime.now().difference(last) < _autoMeterCooldown) {
      return;
    }
    if (_params == null || !sample.isUsable) {
      _measure(auto: true);
    }
  }

  void _onTapUp(TapUpDetails details) {
    final box = _previewKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(details.globalPosition);
    final w = box.size.width;
    final h = box.size.height;
    if (w <= 0 || h <= 0) return;
    if (local.dx < 0 || local.dy < 0 || local.dx > w || local.dy > h) return;
    final wasMeasuringDistance = _measuringDistance;
    setState(() {
      _meterPoint = Offset(
        (local.dx / w).clamp(0.0, 1.0),
        (local.dy / h).clamp(0.0, 1.0),
      );
      _ev = null;
    });
    if (wasMeasuringDistance) {
      // Retarget: stop current session and lock the new point next frame.
      unawaited(_finishDistanceMeasure(keepResult: false).then((_) {
        if (mounted) _requestDistanceMeasure();
      }));
      return;
    }
    _measure();
  }

  /// Reset the metering spot to the centre of the viewfinder and re-meter.
  void _centerMeterPoint() {
    if (_measuring || _saving) return;
    setState(() {
      _meterPoint = const Offset(0.5, 0.5);
      _ev = null;
    });
    _measure();
  }

  void _openFocalDial() {
    setState(() => _focalDialOpen = true);
    _bumpFocalDialHideTimer();
  }

  void _setFocalMm(double mm) {
    if ((_simFocalMm - mm).abs() < 0.01) return;
    setState(() => _simFocalMm = mm);
  }

  void _bumpFocalDialHideTimer() {
    _focalDialHideTimer?.cancel();
    _focalDialHideTimer = Timer(_focalDialHideDelay, () {
      if (!mounted) return;
      setState(() => _focalDialOpen = false);
    });
  }

  void _closeFocalDial() {
    _focalDialHideTimer?.cancel();
    if (_focalDialOpen) setState(() => _focalDialOpen = false);
  }

  // -------------------------------------------------------------- calculator

  String get _displayedShutter {
    if (!_solvingShutter) return ExposureMath.formatShutter(_shutter);
    final result = _compensationResult(0);
    if (result == null) return '—';
    return result.limitLabel ?? result.snappedLabel;
  }

  String get _displayedAperture {
    if (!_solvingAperture) return ExposureMath.formatAperture(_aperture);
    final result = _compensationResult(0);
    if (result == null) return '—';
    return result.limitLabel ?? result.snappedLabel;
  }

  /// Exact / snapped EC readout, plus `over`/`under` when beyond gear limits.
  ///
  /// Scale matches the Hasselblad EV dial: **+** raises working EV (less
  /// exposure → faster shutter / smaller aperture), **−** lowers it.
  _CompResult? _compensationResult(int compensationStops) {
    final ev = _ev;
    if (ev == null) return null;
    final adjusted = ev + compensationStops;
    if (_solvingShutter) {
      final seconds = ExposureMath.shutterFromEv(
        ev100: adjusted,
        aperture: _aperture,
        iso: _meterIso,
      );
      final timed = _timedShutters;
      final fastest =
          timed.isEmpty ? null : timed.reduce((a, b) => a < b ? a : b);
      final slowest =
          timed.isEmpty ? null : timed.reduce((a, b) => a > b ? a : b);
      final unlimited = _unlimitedBulbHolds;
      String? limit;
      if (fastest != null &&
          seconds > 0 &&
          !seconds.isNaN &&
          !seconds.isInfinite &&
          seconds < fastest * (1 - 1e-9)) {
        limit = 'over';
      } else if (slowest != null &&
          seconds > 0 &&
          !seconds.isNaN &&
          !seconds.isInfinite &&
          seconds > slowest * (1 + 1e-9) &&
          !unlimited) {
        limit = 'under';
      }
      return _CompResult(
        exactLabel: ExposureMath.formatShutter(seconds),
        snappedLabel: ExposureMath.formatShutter(
          ExposureMath.snapShutter(
            seconds,
            options: timed,
            allowUnlimited: unlimited,
          ),
        ),
        limitLabel: limit,
      );
    }
    final f = ExposureMath.apertureFromEv(
      ev100: adjusted,
      shutterSeconds: _solveShutterSeconds,
      iso: _meterIso,
    );
    final apertures = _availableApertures;
    final widest =
        apertures.isEmpty ? null : apertures.reduce((a, b) => a < b ? a : b);
    final smallest =
        apertures.isEmpty ? null : apertures.reduce((a, b) => a > b ? a : b);
    String? limit;
    if (f > 0 && !f.isNaN && !f.isInfinite) {
      // Biggest aperture = widest = smallest f-number; beyond → over.
      if (widest != null && f < widest * (1 - 1e-9)) {
        limit = 'over';
      } else if (smallest != null && f > smallest * (1 + 1e-9)) {
        // Smallest aperture = narrowest = largest f-number; beyond → under.
        limit = 'under';
      }
    }
    return _CompResult(
      exactLabel: ExposureMath.formatAperture(f),
      snappedLabel: ExposureMath.formatAperture(
        ExposureMath.snapAperture(f, options: apertures),
      ),
      limitLabel: limit,
    );
  }

  static String _formatCompensation(int stops) {
    if (stops == 0) return '0';
    return stops > 0 ? '+$stops' : '$stops';
  }

  void _openAlbum() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlbumPage(film: _film),
      ),
    );
  }

  void _openFlash() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FlashPage(
          iso: _meterIso,
          aperture: _aperture,
          ambientEv: _ev,
          initialDistance: _subjectDistanceM,
        ),
      ),
    );
  }

  String _evToLabel(double ev) {
    if (ev < 2) return 'Very dark';
    if (ev < 4) return 'Dim interior';
    if (ev < 6) return 'Typical interior';
    if (ev < 8) return 'Bright interior';
    if (ev < 10) return 'Overcast / shade';
    if (ev < 12) return 'Cloudy daylight';
    if (ev < 14) return 'Bright daylight';
    return 'Full sun';
  }

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _film.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              [
                _film.rollFormatLabel,
                _isoSubtitle,
                if (_film.cameraLabel != null) _film.cameraLabel!,
              ].join('  ·  '),
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _pickIso,
            icon: const Icon(Icons.edit_outlined, size: 16, color: _accent),
            label: Text(
              _isoChipLabel,
              style: const TextStyle(
                color: _accent,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          IconButton(
            tooltip: _measuringDistance ? 'Cancel measure' : 'Measure distance',
            icon: Icon(
              _measuringDistance
                  ? Icons.close
                  : Icons.straighten_outlined,
            ),
            onPressed: !_isInitialized
                ? null
                : (_measuringDistance
                    ? _cancelDistanceMeasure
                    : _requestDistanceMeasure),
          ),
          IconButton(
            tooltip: 'Flash',
            icon: const Icon(Icons.flash_on),
            onPressed: _isInitialized ? _openFlash : null,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _isInitialized ? _buildContent() : _buildLoading(),
      ),
    );
  }

  Widget _buildLoading() {
    if (_errorMsg.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                _errorMsg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _errorMsg = '';
                    _isInitialized = false;
                  });
                  _startCamera();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _accent),
          SizedBox(height: 16),
          Text(
            'Starting camera…',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    // The on-screen keyboard shrinks the body, so the controls are allowed to
    // scroll rather than overflow once they would squeeze the preview below a
    // usable size.
    const minimumPreviewHeight = 140.0;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        return Column(
          children: [
            Expanded(child: _buildPreview(_controller!)),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: max(0, constraints.maxHeight - minimumPreviewHeight),
              ),
              child: SingleChildScrollView(
                child: _buildExposurePanel(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPreview(CameraController ctrl) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final crop = _simCrop;
              final fitted = FilmOptics.fitAspect(
                maxWidth: constraints.maxWidth,
                maxHeight: constraints.maxHeight,
                aspect: _simFormat.aspectRatio,
              );
              final viewSize = Size(fitted.width, fitted.height);
              _previewSize = viewSize;

              return Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: SizedBox(
                      key: _previewKey,
                      width: viewSize.width,
                      height: viewSize.height,
                      child: GestureDetector(
                        onTapUp: _onTapUp,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRect(
                              child: Transform.scale(
                                scale: 1.0 / crop,
                                alignment: Alignment.center,
                                child: FittedBox(
                                  fit: BoxFit.cover,
                                  alignment: Alignment.center,
                                  child: SizedBox(
                                    // previewSize is sensor-oriented (usually
                                    // landscape); swap so the child matches the
                                    // portrait CameraPreview aspect. Parent
                                    // constraints stay tight — no OverflowBox —
                                    // so cover scales against the viewfinder.
                                    width: ctrl.value.previewSize?.height ??
                                        viewSize.width,
                                    height: ctrl.value.previewSize?.width ??
                                        viewSize.height,
                                    child: CameraPreview(ctrl),
                                  ),
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _FilmFramePainter(
                                  color: _accent,
                                  showThirds: true,
                                ),
                              ),
                            ),
                            CustomPaint(
                              painter: _SpotPainter(
                                point: _meterPoint,
                                radius: _spotRadius,
                                color: _accent,
                              ),
                            ),
                            if (_measuringDistance)
                              Positioned.fill(
                                child: _distanceMeasureOverlay(),
                              ),
                            Positioned(
                              top: 10,
                              left: 10,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _statusChip(),
                                  if (_subjectDistanceM != null &&
                                      !_measuringDistance) ...[
                                    const SizedBox(height: 6),
                                    _chip(
                                      'Dist ${_distanceEstimate?.displayPrefix ?? ''}'
                                      '${formatLength(_subjectDistanceM!, useFeet: false)}',
                                    ),
                                  ],
                                  if (_lensInfo != null) ...[
                                    const SizedBox(height: 6),
                                    _chip(
                                      'Lens ${_lensInfo!.focalLengthMm.toStringAsFixed(1)} mm',
                                    ),
                                  ],
                                  if (_simLimited) ...[
                                    const SizedBox(height: 6),
                                    _chip('At phone FOV limit'),
                                  ],
                                ],
                              ),
                            ),
                            if (!_focalDialOpen)
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: Material(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(10),
                                  child: IconButton(
                                    tooltip: 'Center spot',
                                    onPressed: (_measuring || _saving)
                                        ? null
                                        : _centerMeterPoint,
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.all(8),
                                    constraints: const BoxConstraints(
                                      minWidth: 40,
                                      minHeight: 40,
                                    ),
                                    icon: Icon(
                                      Icons.filter_center_focus,
                                      size: 22,
                                      color: (_measuring || _saving)
                                          ? Colors.white38
                                          : _accent,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_focalDialOpen)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: FocalArcDial(
                        lensesMm: _focalDialLensesMm,
                        valueMm: _simFocalMm,
                        format: _simFormat,
                        accent: _accent,
                        onChanged: _setFocalMm,
                        onInteraction: _bumpFocalDialHideTimer,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        _buildShutterBar(),
      ],
    );
  }

  Widget _distanceMeasureOverlay() {
    final est = _distanceEstimate;
    final progress = est?.progress ?? 0.05;
    final coaching = est?.coaching ??
        'Tap the subject, then move sideways slowly';
    final metres = est?.metres;
    final showDist = metres != null &&
        metres.isFinite &&
        (est?.sampleCount ?? 0) > 0;
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black38,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CircularProgressIndicator(
                        value: progress.clamp(0.05, 1.0),
                        color: _accent,
                        backgroundColor: Colors.white24,
                        strokeWidth: 3,
                      ),
                      Center(
                        child: Text(
                          showDist
                              ? '${est!.displayPrefix}${formatNumber(metres)}'
                              : '${(progress * 100).round()}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  coaching,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShutterBar() {
    final hint = _captureHint;
    return Container(
      color: const Color(0xFF0F0F0F),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _albumButton(),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hint != null) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Text(
                        hint,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _captureHintError
                              ? Colors.orangeAccent
                              : Colors.white70,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  _shutterButton(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shutterButton() {
    final busy = _saving || _measuring;
    return GestureDetector(
      onTap: busy ? null : _captureFrame,
      child: AnimatedOpacity(
        opacity: busy ? 0.45 : 1,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          padding: const EdgeInsets.all(2.5),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _saving ? _accent : Colors.white,
            ),
            child: _saving
                ? const Padding(
                    padding: EdgeInsets.all(6),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _albumButton() {
    return IconButton(
      tooltip: 'Album',
      onPressed: _openAlbum,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
      icon: const Icon(Icons.photo_library_outlined, size: 22, color: Colors.white70),
    );
  }

  Widget _statusChip() {
    final sample = _sample;
    final warn = sample != null && !sample.isUsable;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            warn ? Icons.warning_amber_rounded : Icons.lock_outline,
            size: 13,
            color: warn ? Colors.orangeAccent : Colors.white70,
          ),
          const SizedBox(width: 5),
          Text(
            _status,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildExposurePanel() {
    final ev100 = _ev;
    final lensEv = _lensEv;
    final params = _params;
    final sample = _sample;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _pickerTile(
                  label: 'Aperture',
                  value: _displayedAperture,
                  onTap: _pickAperture,
                  emphasize: _solvingAperture,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _pickerTile(
                  label: 'Focal',
                  value: _focalTileValue,
                  onTap: _onFocalPressed,
                  emphasize: _focalDialOpen || _selectedLens != null,
                  icon: Icons.straighten,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _pickerTile(
                  label: 'EV',
                  value: lensEv == null ? '—' : lensEv.toStringAsFixed(1),
                  onTap: () => setState(
                    () => _meterDetailsOpen = !_meterDetailsOpen,
                  ),
                  emphasize: true,
                  icon: _meterDetailsOpen
                      ? Icons.expand_less
                      : Icons.expand_more,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _pickerTile(
                  label: 'Shutter',
                  value: _displayedShutter,
                  onTap: _pickShutter,
                  emphasize: _solvingShutter,
                ),
              ),
            ],
          ),
          if (_meterDetailsOpen) ...[
            const SizedBox(height: 6),
            Text(
              _film.isTungsten && _daylight85
                  ? 'Lens EV (Hasselblad) at EI $_meterIso (daylight +85)'
                  : _film.isTungsten
                      ? 'Lens EV (Hasselblad) at ISO $_iso (tungsten)'
                      : 'Lens EV (Hasselblad) at ISO $_meterIso',
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
            if (ev100 != null)
              Text(
                _evToLabel(ev100),
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
            Text(
              params == null
                  ? 'Waiting for a measurement'
                  : 'Sensor ${params.summary}',
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                if (sample != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Color.fromARGB(255, sample.r, sample.g, sample.b),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      'R${sample.r} G${sample.g} B${sample.b}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: (sample.r + sample.g + sample.b) / 3 > 128
                            ? Colors.black87
                            : Colors.white,
                      ),
                    ),
                  ),
                const Spacer(),
                InkWell(
                  onTap: _openCalibration,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      'Cal ${_calibration >= 0 ? '+' : '−'}'
                      '${_calibration.abs().toStringAsFixed(1)}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (sample != null && params != null) ...[
              const SizedBox(height: 3),
              Text(
                'Spot ${ExposureMath.formatStops(sample.stopsFromMiddleGrey)} '
                'from mid-grey',
                style: TextStyle(
                  fontSize: 10,
                  color: sample.isUsable
                      ? Colors.white38
                      : Colors.orangeAccent,
                ),
              ),
            ],
          ],
          const SizedBox(height: 6),
          _buildExposureCompAxis(),
        ],
      ),
    );
  }

  /// Horizontal EC axis: −3…+3 EV in 1-stop steps with the solved value.
  Widget _buildExposureCompAxis() {
    const comps = [-3, -2, -1, 0, 1, 2, 3];
    final solvingLabel = _solvingShutter ? 'Shutter' : 'Aperture';
    final zero = _compensationResult(0);

    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'EC',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white54,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                solvingLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: _accent.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final comp in comps)
                Expanded(
                  child: _compTick(
                    compensation: comp,
                    result: comp == 0 ? zero : _compensationResult(comp),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static const Color _limitColor = Color(0xFFFF6E40);

  Widget _compTick({
    required int compensation,
    required _CompResult? result,
  }) {
    final isZero = compensation == 0;
    final outOfRange = result?.limitLabel != null;
    final value = result == null
        ? '—'
        : (result.limitLabel ?? result.snappedLabel);
    final exactValue = result?.exactLabel;
    final showExact = isZero &&
        exactValue != null &&
        exactValue != '—' &&
        (outOfRange || exactValue != result?.snappedLabel);
    final valueColor = outOfRange
        ? _limitColor
        : (isZero ? _accent : Colors.white70);
    final tickColor = outOfRange
        ? _limitColor
        : (isZero ? _accent : Colors.white38);
    final compColor = outOfRange
        ? _limitColor
        : (isZero ? _accent : Colors.white54);

    return Column(
      children: [
        SizedBox(
          height: 28,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (showExact)
                Text(
                  exactValue,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: outOfRange
                        ? _limitColor.withValues(alpha: 0.8)
                        : _accent.withValues(alpha: 0.75),
                    height: 1.0,
                  ),
                ),
              if (showExact) const SizedBox(height: 2),
              Text(
                value,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isZero ? 13 : 9.5,
                  fontWeight: isZero ? FontWeight.w800 : FontWeight.w600,
                  color: valueColor,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        SizedBox(
          height: 12,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Align(
                alignment: Alignment.center,
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.white12,
                ),
              ),
              Container(
                width: isZero || outOfRange ? 2 : 1.5,
                height: isZero || outOfRange ? 12 : 8,
                color: tickColor,
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _formatCompensation(compensation),
          style: TextStyle(
            fontSize: isZero ? 11 : 9.5,
            fontWeight: isZero ? FontWeight.w800 : FontWeight.w600,
            color: compColor,
            height: 1.0,
          ),
        ),
      ],
    );
  }

  Widget _pickerTile({
    required String label,
    required String value,
    VoidCallback? onTap,
    IconData icon = Icons.expand_more,
    bool emphasize = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: emphasize
              ? const Color(0xFF221C0A)
              : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: emphasize ? const Color(0x55FFB300) : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.1,
                      color: emphasize
                          ? _accent.withValues(alpha: 0.8)
                          : Colors.white54,
                    ),
                  ),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: emphasize ? 16 : 15,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      color: emphasize ? _accent : Colors.white,
                      letterSpacing: emphasize ? -0.3 : 0,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              icon,
              color: emphasize
                  ? _accent.withValues(alpha: 0.7)
                  : Colors.white38,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickIso() async {
    if (_film.isTungsten) {
      await _pickTungstenMetering();
      return;
    }
    final chosen = await _showWheelPicker<int>(
      title: 'Film ISO',
      items: ExposureMath.standardIsos,
      initial: _iso,
      labelOf: (v) => '$v',
    );
    if (chosen != null) setState(() => _iso = chosen);
  }

  Future<void> _pickTungstenMetering() async {
    final daylightEi = ExposureMath.eiWithWratten85(_iso);
    final choice = await _whileModalOpen(() {
      return showModalBottomSheet<_TungstenMeterChoice>(
        context: context,
        backgroundColor: const Color(0xFF161616),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Tungsten film',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Rated ISO $_iso under tungsten. In daylight with an 85 '
                    'filter, Kodak rates EI $daylightEi (−⅔ stop). '
                    'Daylight without 85: keep ISO $_iso (expect a cool cast).',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _tungstenMeterTile(
                    selected: !_daylight85,
                    title: 'Tungsten / unfiltered',
                    subtitle: 'Meter at ISO $_iso',
                    onTap: () => Navigator.pop(
                      ctx,
                      _TungstenMeterChoice.tungstenRated,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _tungstenMeterTile(
                    selected: _daylight85,
                    title: 'Daylight + 85 filter',
                    subtitle: 'Meter at EI $daylightEi',
                    onTap: () => Navigator.pop(
                      ctx,
                      _TungstenMeterChoice.daylight85,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(
                      ctx,
                      _TungstenMeterChoice.changeBoxSpeed,
                    ),
                    child: const Text(
                      'Change box speed…',
                      style: TextStyle(color: _accent),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    });
    if (!mounted || choice == null) return;

    switch (choice) {
      case _TungstenMeterChoice.tungstenRated:
        await _setDaylight85(false);
      case _TungstenMeterChoice.daylight85:
        await _setDaylight85(true);
      case _TungstenMeterChoice.changeBoxSpeed:
        final chosen = await _showWheelPicker<int>(
          title: 'Box / tungsten ISO',
          items: ExposureMath.standardIsos,
          initial: _iso,
          labelOf: (v) => '$v',
        );
        if (chosen != null && mounted) {
          final updated = _film.copyWith(iso: chosen);
          setState(() {
            _iso = chosen;
            _film = updated;
          });
          await FilmStockStore.upsertSelected(updated);
        }
    }
  }

  Future<void> _setDaylight85(bool value) async {
    if (!_film.isTungsten) return;
    final updated = _film.copyWith(meterDaylight85: value);
    setState(() {
      _daylight85 = value;
      _film = updated;
    });
    await FilmStockStore.upsertSelected(updated);
  }

  Widget _tungstenMeterTile({
    required bool selected,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected
          ? _accent.withValues(alpha: 0.14)
          : const Color(0xFF222222),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: selected ? _accent : Colors.white38,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: selected ? _accent : Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _focalMmLabel {
    if ((_simFocalMm - _simFocalMm.round()).abs() < 0.05) {
      return '${_simFocalMm.round()} mm';
    }
    return '${_simFocalMm.toStringAsFixed(1)} mm';
  }

  String get _focalTileValue {
    final body = _body;
    if (body != null && !body.interchangeableLenses) {
      return _focalMmLabel;
    }
    final lens = _selectedLens;
    if (lens != null) return '$_focalMmLabel · ${lens.name}';
    return '$_focalMmLabel · Free';
  }

  void _toggleFocalDial() {
    if (_focalDialOpen) {
      _closeFocalDial();
    } else {
      _openFocalDial();
    }
  }

  Future<void> _onFocalPressed() async {
    final body = _body;
    // Fixed-lens bodies only adjust the viewfinder focal simulation.
    if (body != null && !body.interchangeableLenses) {
      _toggleFocalDial();
      return;
    }
    // Interchangeable (or unknown body): pick free zoom / a catalogued lens.
    if (_availableLenses.isNotEmpty) {
      await _pickFocalLens();
      return;
    }
    await _selectFreeZoom(openDial: true);
  }

  Future<void> _pickFocalLens() async {
    final chosen = await _whileModalOpen(() {
      return showModalBottomSheet<Object>(
        context: context,
        backgroundColor: const Color(0xFF161616),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) {
          final freeSelected = _selectedLens == null;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Focal',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _film.cameraLabel ?? 'Free zoom or a lens for this body',
                    style: const TextStyle(fontSize: 13, color: Colors.white54),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: 1 + _availableLenses.length,
                      separatorBuilder: (_, _) => const Divider(
                        height: 1,
                        color: Colors.white10,
                      ),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Free zoom',
                              style: TextStyle(
                                color: freeSelected ? _accent : Colors.white,
                                fontWeight: freeSelected
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                              ),
                            ),
                            subtitle: const Text(
                              'Any focal length · full aperture range',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            trailing: freeSelected
                                ? const Icon(
                                    Icons.check,
                                    color: _accent,
                                    size: 20,
                                  )
                                : null,
                            onTap: () => Navigator.pop(ctx, _freeZoomChoice),
                          );
                        }
                        final lens = _availableLenses[index - 1];
                        final selected = _selectedLens?.id == lens.id;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${lens.brand} ${lens.name}',
                            style: TextStyle(
                              color: selected ? _accent : Colors.white,
                              fontWeight:
                                  selected ? FontWeight.w800 : FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            lens.summary,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          trailing: selected
                              ? const Icon(
                                  Icons.check,
                                  color: _accent,
                                  size: 20,
                                )
                              : null,
                          onTap: () => Navigator.pop(ctx, lens),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    });

    if (chosen == null || !mounted) return;

    if (identical(chosen, _freeZoomChoice)) {
      await _selectFreeZoom(openDial: true);
      return;
    }
    if (chosen is UserLens) {
      await _selectLens(chosen, openDial: true);
    }
  }

  Future<void> _selectFreeZoom({bool openDial = false}) async {
    final updated = _film.copyWith(clearLens: true);
    setState(() {
      _selectedLens = null;
      _film = updated;
      _clampExposureToGear();
    });
    await FilmStockStore.upsertSelected(updated);
    if (!mounted) return;
    if (openDial) _openFocalDial();
  }

  Future<void> _selectLens(UserLens chosen, {bool openDial = false}) async {
    final updated = _film.copyWith(
      lensId: chosen.id,
      lensLabel: '${chosen.brand} ${chosen.name}',
    );
    setState(() {
      _selectedLens = chosen;
      _film = updated;
      _simFocalMm = _clampFocalToLens(chosen, _simFocalMm);
      _clampExposureToGear();
    });
    await FilmStockStore.upsertSelected(updated);
    if (!mounted) return;
    // Primes are a single stop — no dial needed.
    if (openDial && chosen.isZoom && chosen.maxFocalMm != null) {
      _openFocalDial();
    } else if (openDial && !chosen.isZoom) {
      _closeFocalDial();
    }
  }

  Future<void> _pickAperture() async {
    final items = _availableApertures;
    final chosen = await _showWheelPicker<double>(
      title: 'Aperture',
      items: items,
      initial: _aperture,
      labelOf: ExposureMath.formatAperture,
    );
    if (chosen != null) {
      setState(() {
        _aperture = chosen;
        _lastEdited = LastEdited.aperture;
      });
    }
  }

  Future<void> _pickShutter() async {
    final items = _availableShutters;
    final chosen = await _showWheelPicker<double>(
      title: 'Shutter speed',
      items: items,
      initial: _shutter,
      labelOf: ExposureMath.formatShutter,
    );
    if (chosen != null) {
      setState(() {
        _shutter = chosen;
        _lastEdited = LastEdited.shutter;
      });
    }
  }

  Future<T?> _showWheelPicker<T>({
    required String title,
    required List<T> items,
    required T initial,
    required String Function(T) labelOf,
  }) {
    var index = items.indexOf(initial);
    if (index < 0 && initial is double) {
      // Match shutter/aperture floats that aren't identical by identity.
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item is double && (item - initial).abs() < 1e-12) {
          index = i;
          break;
        }
      }
    }
    if (index < 0) index = 0;

    return _whileModalOpen(
      () => showModalBottomSheet<T>(
        context: context,
        backgroundColor: const Color(0xFF161616),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => WheelDialSheet<T>(
          title: title,
          items: items,
          initialIndex: index,
          labelOf: labelOf,
          accent: _accent,
        ),
      ),
    );
  }

  Future<void> _openCalibration() async {
    var value = _calibration;
    await _whileModalOpen(() => _calibrationSheet(value));
    await CalibrationStore.save(_calibration);
  }

  Future<void> _calibrationSheet(double value) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Calibration',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Offset every reading to match a meter you trust. '
                      'Lens transmission and sensor tuning vary between phones.',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      ExposureMath.formatStops(value),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: _accent,
                      ),
                    ),
                    Slider(
                      value: value,
                      min: -CalibrationStore.maxOffset,
                      max: CalibrationStore.maxOffset,
                      divisions:
                          (CalibrationStore.maxOffset * 2 / 0.1).round(),
                      onChanged: (v) {
                        setSheetState(() => value = v);
                        setState(() {
                          _calibration = v;
                          _ev = null;
                        });
                      },
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          setSheetState(() => value = 0);
                          setState(() {
                            _calibration = 0;
                            _ev = null;
                          });
                        },
                        child: const Text('Reset'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _FilmFramePainter extends CustomPainter {
  final Color color;
  final bool showThirds;

  _FilmFramePainter({
    required this.color,
    this.showThirds = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final frame = (Offset.zero & size).deflate(1);
    canvas.drawRect(
      frame,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    if (!showThirds) return;

    final guide = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(frame.left + frame.width / 3, frame.top),
      Offset(frame.left + frame.width / 3, frame.bottom),
      guide,
    );
    canvas.drawLine(
      Offset(frame.left + 2 * frame.width / 3, frame.top),
      Offset(frame.left + 2 * frame.width / 3, frame.bottom),
      guide,
    );
    canvas.drawLine(
      Offset(frame.left, frame.top + frame.height / 3),
      Offset(frame.right, frame.top + frame.height / 3),
      guide,
    );
    canvas.drawLine(
      Offset(frame.left, frame.top + 2 * frame.height / 3),
      Offset(frame.right, frame.top + 2 * frame.height / 3),
      guide,
    );
  }

  @override
  bool shouldRepaint(covariant _FilmFramePainter old) =>
      color != old.color || showThirds != old.showThirds;
}

class _SpotPainter extends CustomPainter {
  final Offset point;
  final double radius;
  final Color color;

  _SpotPainter({
    required this.point,
    required this.radius,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = point.dx * size.width;
    final cy = point.dy * size.height;
    final center = Offset(cx, cy);

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color.withValues(alpha: 0.12),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color.withValues(alpha: 0.9)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    final tick = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const gap = 6.0;
    final outer = radius + 12;
    canvas.drawLine(
        Offset(cx, cy - radius - gap), Offset(cx, cy - outer), tick);
    canvas.drawLine(
        Offset(cx, cy + radius + gap), Offset(cx, cy + outer), tick);
    canvas.drawLine(
        Offset(cx - radius - gap, cy), Offset(cx - outer, cy), tick);
    canvas.drawLine(
        Offset(cx + radius + gap, cy), Offset(cx + outer, cy), tick);
  }

  @override
  bool shouldRepaint(covariant _SpotPainter old) =>
      point != old.point || color != old.color || radius != old.radius;
}

enum _TungstenMeterChoice {
  tungstenRated,
  daylight85,
  changeBoxSpeed,
}

/// EC tick display: exact solve, snapped gear value, optional limit label.
class _CompResult {
  const _CompResult({
    required this.exactLabel,
    required this.snappedLabel,
    this.limitLabel,
  });

  final String exactLabel;
  final String snappedLabel;

  /// `over` / `under` when the exact solve is outside camera/lens range.
  final String? limitLabel;
}
