import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;

import 'package:camera/camera.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ae_sweep.dart';
import 'album_page.dart';
import 'album_shot.dart';
import 'calibration.dart';
import 'capture_metadata.dart';
import 'color_temperature.dart';
import 'distance_estimator.dart';
import 'exposure.dart';
import 'film_format.dart';
import 'film_frame.dart';
import 'film_stock.dart';
import 'flash_page.dart';
import 'frame_counter.dart';
import 'focal_arc_dial.dart';
import 'gear.dart';
import 'home_page.dart';
import 'lens_info.dart';
import 'live_meter.dart';
import 'meter_debug.dart';
import 'metering.dart';
import 'multi_spot.dart';
import 'nd_filter.dart';
import 'number_input_dialog.dart';
import 'raw_white_point.dart';
import 'reference_exposure.dart';
import 'shoot_checklist_page.dart';
import 'reference_exposure_dialog.dart';
import 'tone_curve.dart';
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

  /// Ceiling on the first exposure settle, used only by the still-capture
  /// fallback. Live readings need no settle: they update every frame.
  static const Duration _aeSettleDelay = Duration(milliseconds: 900);

  static const Duration _autoMeterCooldown = Duration(seconds: 2);

  /// How stale capture metadata may be before a still capture is used instead.
  ///
  /// Updates arrive at about 10 Hz. Pairing a frame with exposure from more
  /// than ~2 metadata ticks ago describes a different picture, so this is tight.
  static const Duration _metadataFreshness = Duration(milliseconds: 250);

  ExposureParams? _params;
  SpotSample? _sample;

  /// Derives a reading from every frame, and learns the device's response
  /// slope from ordinary use.
  final LiveMeter _liveMeter = LiveMeter();

  /// The most recent live reading, kept for the status line and diagnostics.
  LiveReading? _reading;

  /// Scene brightness as EV₁₀₀ (ISO-normalized). Display uses Hasselblad
  /// lens EV via [_lensEv].
  double? _ev;
  double _calibration = 0.0;

  /// Measured encoded-luminance → true-linear mapping for this device.
  ///
  /// When present it replaces the sRGB inversion, which a real phone pipeline
  /// departs from by whole stops away from mid grey.
  ToneCurve? _toneCurve;

  /// Smoothed correlated colour temperature (Kelvin) of the metered patch.
  double? _cctKelvin;

  /// Full colour reading behind [_cctKelvin], including how far off the
  /// black-body locus it sits.
  ColorTemperature? _cct;

  /// Correction for the camera's white balance, once measured against a light
  /// of known temperature.
  WhiteBalanceReference? _wbReference;

  /// Per-frame exposure and colour metadata from the camera's own capture
  /// result. Empty on platforms that cannot supply it, in which case metering
  /// falls back to reading a still capture's EXIF.
  final CaptureMetadataStream _captureMetadata = CaptureMetadataStream();

  /// The sensor's DNG calibration, needed to turn a raw white point into a
  /// temperature. Null where the sensor publishes none.
  SensorColorCalibration? _colorCalibration;

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
  /// When true, freeze the current EV (and WB-driven EI) until unlocked.
  bool _exposureLocked = false;
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

  // ------------------------------------------------------------- diagnostics
  /// Live readout of every metering intermediate. Off by default; turned on
  /// from the calibration sheet to attribute an EV error to its source.
  bool _debugOverlayOpen = false;

  /// Scene EV₁₀₀ before calibration and smoothing, kept for the debug readout.
  double? _rawSceneEv;

  /// Active "match to a reference meter" run, fed by [_onFrame].
  EvCalibrationRun? _calibrationRun;

  /// What the reference camera showed last time, to prefill a repeat match.
  ReferenceExposure? _lastReference;

  /// Neutral density filter on the lens. The meter reads the scene without it,
  /// so only the solved shutter / aperture change, never the EV reading.
  NdFilter _nd = NdFilter.none;

  /// Multi-spot view: lowest, 25 %, centre, 75 % and highest EV in the frame,
  /// drawn on the video feed.
  /// Frame of the loaded roll. The checklist advances it.
  int _frameCount = FrameCount.min;

  bool _multiSpotEnabled = false;
  MultiSpotResult? _multiSpot;

  /// Whole-frame analysis is far heavier than one spot, so it runs a few times
  /// a second rather than on every frame.
  final Stopwatch _multiSpotClock = Stopwatch()..start();
  static const int _multiSpotIntervalMs = 200;

  /// Geometry / pixel format of the last analysed preview frame.
  int? _frameWidth;
  int? _frameHeight;
  String? _frameFormat;

  /// True when the patch sits outside the range the pipeline is described
  /// over, so the shown EV is stale rather than current.
  bool _readingOutOfRange = false;

  /// Last reference EV typed in, so repeat samples at one light level do not
  /// have to be re-entered.
  double? _lastReferenceEv;

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
      return ExposureMath.eiForTungstenScene(
        tungstenIso: _iso,
        sceneKelvin: _cctKelvin,
      );
    }
    return _iso;
  }

  String get _isoChipLabel {
    if (_film.isTungsten && _daylight85 && _meterIso != _iso) {
      return 'EI $_meterIso';
    }
    return _film.isTungsten ? 'ISO $_iso T' : 'ISO $_iso';
  }

  UserCamera? _body;
  List<UserLens> _availableLenses = [];
  UserLens? _selectedLens;

  /// Focal-length viewfinder simulation — format is locked by the loaded roll.
  FilmFormat get _simFormat => _film.frameFormat;

  /// Outer viewfinder FOV. 645 rolls show the 6×6 square FOV with a 645 gate.
  FilmFormat get _viewfinderFormat =>
      _simFormat == FilmFormat.sixFourFive
          ? FilmFormat.sixBySix
          : _simFormat;

  bool get _is645InSixBySix => _simFormat == FilmFormat.sixFourFive;

  /// 645 gate height inside a 6×6 opening (same width, shorter gate).
  static double get _gate645HeightFrac =>
      FilmFormat.sixFourFive.heightMm / FilmFormat.sixBySix.heightMm;

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
    _loadToneCurve();
    _loadWhiteBalance();
    _loadGear();
    _loadFrameCount();
    _captureMetadata.start();
    _startCamera();
  }

  Future<void> _loadFrameCount() async {
    final count = await FrameCounterStore.load(widget.film.id);
    if (!mounted) return;
    setState(() => _frameCount = count);
  }

  Future<void> _loadWhiteBalance() async {
    final reference = await WhiteBalanceStore.load();
    if (mounted && reference != null) {
      setState(() => _wbReference = reference);
    }
  }

  Future<void> _loadToneCurve() async {
    final curve = await ToneCurveStore.load();
    if (mounted && curve != null) {
      setState(() => _toneCurve = curve);
    }
  }

  /// Reads the scene from the current frame.
  ///
  /// Auto-exposure is aimed at the metered spot, so it drives that spot towards
  /// mid grey by itself and the capture metadata reports what it settled on.
  /// The reading is therefore the exposure plus a small trim for wherever the
  /// patch actually landed — and the slope for that trim is measured from this
  /// device's own response, so no tone curve is assumed.
  ///
  /// Without capture metadata there is nothing to read per frame, so this uses
  /// the exposure from the last still capture instead.
  LiveReading? _readLive(SpotSample sample) {
    final metadata = _captureMetadata.latest;
    if (metadata != null &&
        metadata.hasExposure &&
        metadata.age < _metadataFreshness) {
      return _liveMeter.read(
        metadata: metadata,
        sample: sample,
        curve: _toneCurve,
      );
    }

    final params = _params;
    if (params == null) return null;
    return _liveMeter.readFromParams(
      params: params,
      sample: sample,
      curve: _toneCurve,
    );
  }

  /// EV₁₀₀ the camera's current exposure corresponds to, from the frame's own
  /// metadata where it is fresh, else the last still capture.
  double? _cameraEv100Now() {
    final metadata = _captureMetadata.latest;
    if (metadata != null &&
        metadata.hasExposure &&
        metadata.age < _metadataFreshness) {
      return metadata.ev100;
    }
    return _params?.ev100;
  }

  /// Samples the whole frame and picks the five spots.
  void _updateMultiSpot(CameraImage image, Size previewSize, double crop) {
    if (_multiSpotClock.elapsedMilliseconds < _multiSpotIntervalMs) return;
    _multiSpotClock.reset();

    final cameraEv = _cameraEv100Now();
    if (cameraEv == null || !cameraEv.isFinite) return;

    // The focal simulation crops the preview about its centre; the same
    // mapping the single spot uses.
    Offset toPreview(Offset p) {
      if (crop >= 1.0) return p;
      final m = FilmOptics.mapViewfinderToPreview(p.dx, p.dy, crop);
      return Offset(m.x, m.y);
    }

    final cells = sampleLumaGridFromImage(
      image: image,
      widgetSize: previewSize,
      quarterTurns: _quarterTurns,
      mirror: _mirror,
      toPreview: toPreview,
      radiusScale: crop.clamp(0.05, 1.0).toDouble(),
    );
    // The centre uses the same patch definition as the main spot, so the two
    // agree whenever the spot is left in the middle.
    final centre = sampleSpot(
      image: image,
      spot: toPreview(const Offset(0.5, 0.5)),
      widgetSize: previewSize,
      quarterTurns: _quarterTurns,
      mirror: _mirror,
      radiusInWidgetPixels: _spotRadius,
    );
    if (cells == null || centre == null) return;

    final result = MultiSpotAnalyzer.analyze(
      cells: cells,
      center: LumaCell(x: 0.5, y: 0.5, encoded: centre.encodedLuminance),
      evaluate: (encoded) => _liveMeter.readEncoded(
        cameraEv100: cameraEv,
        encoded: encoded,
        curve: _toneCurve,
      ),
      previous: _multiSpot,
    );
    if (result != null) _multiSpot = result;
  }

  void _toggleMultiSpot() {
    setState(() {
      _multiSpotEnabled = !_multiSpotEnabled;
      _multiSpot = null;
      _setCaptureHint(
        _multiSpotEnabled ? 'Multi-spot on' : 'Multi-spot off',
        clearAfter: const Duration(seconds: 2),
      );
    });
  }

  /// A spot's value on the same scale as the EV tile: Hasselblad lens EV at
  /// the working ISO, with the calibration offset applied.
  String _multiSpotValue(MultiSpotPoint p) {
    final lensEv = ExposureMath.lensEvFromEv100(
      ev100: p.ev100 + _calibration,
      iso: _meterIso,
    );
    return '${p.prefix}${lensEv.toStringAsFixed(1)}';
  }

  Widget _multiSpotLegend(MultiSpotResult result) {
    // One slim row, shadows to highlights, left to right. The markers on the
    // frame already carry their own values; this is just the key.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < result.points.length; i++) ...[
            if (i > 0) const SizedBox(width: 9),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  result.points[i].role.label,
                  style: const TextStyle(color: Colors.white54, fontSize: 9),
                ),
                Text(
                  _multiSpotValue(result.points[i]),
                  style: TextStyle(
                    color: _multiSpotColor(result.points[i].role),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Colour-coded cold → hot: shadows blue, highlights red.
  Color _multiSpotColor(MultiSpotRole role) {
    switch (role) {
      case MultiSpotRole.lowest:
        return const Color(0xFF5C8DFF);
      case MultiSpotRole.quarter:
        return const Color(0xFF2DD4BF);
      case MultiSpotRole.center:
        return Colors.white;
      case MultiSpotRole.threeQuarter:
        return const Color(0xFFFF9F43);
      case MultiSpotRole.highest:
        return const Color(0xFFFF5252);
    }
  }

  /// Colour temperature of the current scene.
  ///
  /// Prefers the sensor's raw white point. Auto white balance exists to divide
  /// the illuminant's colour out — measured on this device as gains of 1.85 on
  /// red and 1.74 on blue, close to a stop — so a white wall under tungsten
  /// renders neutral and, judged from rendered pixels, reads as daylight. The
  /// raw white point is stated before that correction, so it still describes
  /// the light rather than the leftovers.
  ///
  /// Falls back to the rendered patch where the raw point or the sensor
  /// calibration is unavailable, which is what [WhiteBalanceReference] exists
  /// to make usable.
  ColorTemperature? _resolveColorTemperature(SpotSample sample) {
    final calibration = _colorCalibration;
    final neutral = _captureMetadata.latest;
    if (calibration != null &&
        neutral != null &&
        neutral.neutralColorPoint != null &&
        neutral.age < _metadataFreshness) {
      final resolved = RawWhitePointSolver.solve(
        neutral: neutral.neutralColorPoint!,
        calibration: calibration,
      );
      if (resolved != null) return resolved;
    }

    return sample.colorTemperature(
      curve: _toneCurve,
      reference: _wbReference,
    );
  }

  /// Status line describing the live reading.
  ///
  /// Describes the state of the reading rather than the progress of a
  /// measurement: there are no longer any steps to count, because the value
  /// updates on every frame.
  String get _liveStatus {
    if (_exposureLocked) return 'AE-L';

    final reading = _reading;
    if (reading == null) return 'Metering…';

    switch (reading.quality) {
      case LiveReadingQuality.unusable:
        return reading.encodedLuminance > LiveMeter.target
            ? 'Spot too bright — re-aim'
            : 'Spot too dark — re-aim';
      case LiveReadingQuality.fair:
        return 'Live · approximate';
      case LiveReadingQuality.good:
        return reading.aeConverged ? 'Live' : 'Live · settling';
    }
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
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Out of sight: give the camera back rather than just pausing frames.
        unawaited(_releaseCamera());
      case AppLifecycleState.resumed:
        unawaited(_resumeCamera());
      case AppLifecycleState.inactive:
        // Transient (permission prompt, notification shade, app switcher).
        // Closing the camera here would flicker, so only the analysis stops.
        final ctrl = _controller;
        if (ctrl != null &&
            ctrl.value.isInitialized &&
            ctrl.value.isStreamingImages) {
          unawaited(ctrl.stopImageStream());
        }
    }
  }

  @override
  void dispose() {
    _wantCamera = false;
    _focalDialHideTimer?.cancel();
    _captureHintTimer?.cancel();
    unawaited(_distanceEstimator?.stop());
    _distanceEstimator = null;
    unawaited(_captureMetadata.dispose());
    WidgetsBinding.instance.removeObserver(this);
    final ctrl = _controller;
    if (ctrl != null) {
      if (ctrl.value.isStreamingImages) ctrl.stopImageStream();
      ctrl.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------- camera lifecycle
  //
  // The camera is only held while it is actually in use: it is closed when the
  // app leaves the foreground and while the album or flash page covers this
  // one, and reopened on return. Opening and closing are serialised so a quick
  // background/foreground cannot overlap a start with a teardown.

  /// Whether the camera should currently be open. Set synchronously; the
  /// queued operations act on it when their turn comes.
  bool _wantCamera = true;
  Future<void> _cameraQueue = Future<void>.value();
  bool _cameraStartedOnce = false;

  Future<void> _enqueueCameraOp(Future<void> Function() op) {
    final next = _cameraQueue.then((_) => op()).catchError((Object _) {});
    _cameraQueue = next;
    return next;
  }

  Future<void> _startCamera() {
    _wantCamera = true;
    return _enqueueCameraOp(_startCameraNow);
  }

  /// True while the album or flash page covers this one, so coming back to
  /// the foreground must not reopen a camera nobody can see.
  bool _routeCovered = false;

  Future<void> _resumeCamera() {
    if (_routeCovered) return Future<void>.value();
    if (_wantCamera && _controller != null) {
      // Never released (e.g. only went inactive): just restart the analysis.
      final ctrl = _controller!;
      if (ctrl.value.isInitialized && !ctrl.value.isStreamingImages) {
        unawaited(ctrl.startImageStream(_onFrame));
      }
      return Future<void>.value();
    }
    return _startCamera();
  }

  Future<void> _releaseCamera() {
    _wantCamera = false;
    return _enqueueCameraOp(_stopCameraNow);
  }

  Future<void> _startCameraNow() async {
    if (!_wantCamera || !mounted || _controller != null) return;

    final controller = CameraController(
      widget.camera,
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    _controller = controller;

    try {
      await controller.initialize();
      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      // Keep optical zoom at its native wide end — framing is done by the
      // format / focal simulation instead.
      if (_maxZoom > _minZoom) {
        await controller.setZoomLevel(_minZoom);
      }
      // Released (or the page closed) while opening: the queued teardown
      // closes it, or the widget's own dispose does.
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.startImageStream(_onFrame);

      final firstStart = !_cameraStartedOnce;
      _cameraStartedOnce = true;
      if (firstStart) {
        await _loadLensInfo();
        unawaited(_probeCaptureMetadata());
      }
      if (!mounted) return;
      setState(() {
        _isInitialized = true;
        _status = 'Metering…';
      });

      if (!firstStart) {
        // A fresh camera forgets what it was told: restore the lock, or aim
        // auto-exposure back at the metering spot.
        if (_exposureLocked) {
          try {
            await controller.setExposureMode(ExposureMode.locked);
          } on CameraException {
            // The held reading still stands.
          }
        } else {
          unawaited(_aimExposure());
        }
      }
    } catch (e) {
      // Don't keep a half-open camera: the Retry button needs a clean slate.
      if (identical(_controller, controller)) _controller = null;
      try {
        await controller.dispose();
      } catch (_) {
        // Nothing more to release.
      }
      if (mounted && _wantCamera) {
        setState(() => _errorMsg = 'Camera failed to start:\n$e');
      }
    }
  }

  Future<void> _stopCameraNow() async {
    // A newer request to have the camera open wins.
    if (_wantCamera) return;

    // Let a capture or still metering finish rather than cut it off.
    for (var i = 0; i < 30 && (_saving || _measuring) && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_wantCamera) return;
    if (_measuringDistance) await _cancelDistanceMeasure();

    final ctrl = _controller;
    if (ctrl == null) return;
    _controller = null;

    if (mounted) {
      setState(() {
        _isInitialized = false;
        _errorMsg = '';
      });
      // Let the preview leave the tree before its controller goes. There may
      // be no frame at all while backgrounded, so don't wait on one forever.
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }

    try {
      if (ctrl.value.isStreamingImages) await ctrl.stopImageStream();
    } catch (_) {
      // Closing anyway.
    }
    try {
      await ctrl.dispose();
    } catch (_) {
      // Already gone.
    }
  }

  /// Pushes [route] with the camera closed underneath it, reopening it when
  /// the route is popped.
  Future<void> _pushWithoutCamera(Route<void> route) async {
    _routeCovered = true;
    await _releaseCamera();
    if (!mounted) return;
    await Navigator.of(context).push(route);
    _routeCovered = false;
    if (mounted) await _resumeCamera();
  }

  Future<void> _loadLensInfo() async {
    final platform = await readLensInfoFromPlatform(
      cameraName: widget.camera.name,
    );
    if (!mounted) return;
    if (platform != null) {
      setState(() => _lensInfo = platform);
    }
    unawaited(_dumpColorCapabilities());
    unawaited(_loadColorCalibration());
  }

  /// Loads the sensor's DNG calibration, which is what makes the raw white
  /// point interpretable as a temperature.
  Future<void> _loadColorCalibration() async {
    final calibration = await readSensorColorCalibration(
      cameraName: widget.camera.name,
    );
    if (mounted && calibration != null) {
      setState(() => _colorCalibration = calibration);
    }
  }

  /// Records whether the forked plugin is actually delivering capture
  /// metadata, and what it contains.
  ///
  /// Everything downstream is designed to work without it, so a silent absence
  /// would be indistinguishable from success. This makes the answer explicit.
  Future<void> _probeCaptureMetadata() async {
    // Give the analyzer time to produce frames and the stream to attach.
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted) return;

    final metadata = _captureMetadata.latest;
    final status = await CaptureMetadataStream.probeStatus();
    if (!mounted) return;

    final lines = <String>[
      '# ApertureDiary capture metadata probe',
      '# recorded: ${DateTime.now().toIso8601String()}',
      '# available: ${metadata != null}',
      // The authoritative answer to "is the forked plugin running?". A null
      // status means the probe channel does not exist, so it is not.
      '# fork_active: ${status != null}',
      'field,value',
    ];

    if (status == null) {
      lines.add(
        'note,"Probe channel absent — the running plugin is not the fork. '
        'Check that dependency_overrides points at packages/ and that the '
        'build was not served from cache."',
      );
    } else {
      for (final entry in status.entries) {
        lines.add('probe_${entry.key},"${entry.value}"');
      }
    }

    if (metadata == null) {
      lines.add(
        'note,"No metadata events received."',
      );
    } else {
      void put(String key, Object? value) {
        if (value == null) return;
        final text = value is List ? value.join(' ') : '$value';
        lines.add('$key,"$text"');
      }

      put('exposureTimeSeconds', metadata.exposureTimeSeconds);
      put('iso', metadata.iso);
      put('postRawSensitivityBoost', metadata.postRawSensitivityBoost);
      put('effectiveIso', metadata.effectiveIso);
      put('aperture', metadata.aperture);
      put('focalLengthMm', metadata.focalLengthMm);
      put('ev100', metadata.ev100);
      put('aeState', metadata.aeState);
      put('aeConverged', metadata.aeConverged);
      put('aeExposureCompensation', metadata.aeExposureCompensation);
      put('neutralColorPoint', metadata.neutralColorPoint);
      put('awbState', metadata.awbState);
      put('awbConverged', metadata.awbConverged);
      put('awbMode', metadata.awbMode);
      put('colorCorrectionGains', metadata.colorCorrectionGains);
      put('hasExposure', metadata.hasExposure);

      // The comparison that justifies the fork: the still-capture EXIF the app
      // used to rely on, against the preview frame's own numbers.
      final exif = _params;
      if (exif != null) {
        put('exif_ev100', exif.ev100);
        final live = metadata.ev100;
        if (live != null) {
          put('ev100_difference_stops', live - exif.ev100);
        }
      }
    }

    await DiagnosticsExport.write(
      'capture_metadata_${DiagnosticsExport.timestampSlug()}.csv',
      '${lines.join('\n')}\n',
    );
  }

  /// Records what colour control this camera allows, once per launch.
  ///
  /// Whether white balance can be measured rather than referenced is a property
  /// of the hardware, not of the app, so the answer belongs in a file next to
  /// the other diagnostics rather than in a log line that scrolls away.
  Future<void> _dumpColorCapabilities() async {
    final caps = await readColorCapabilities(cameraName: widget.camera.name);
    if (caps == null) return;

    final lines = <String>[
      '# ApertureDiary camera colour capabilities',
      '# recorded: ${DateTime.now().toIso8601String()}',
      '# camera: ${widget.camera.name}',
      'key,value',
    ];
    final keys = caps.keys.toList()..sort();
    for (final key in keys) {
      final value = caps[key];
      final text = value is List ? value.join(' ') : '$value';
      lines.add('$key,"$text"');
    }

    await DiagnosticsExport.write(
      'color_caps_${DiagnosticsExport.timestampSlug()}.csv',
      '${lines.join('\n')}\n',
    );
  }

  // ---------------------------------------------------------------- metering

  /// Points auto-exposure at the metered spot.
  ///
  /// There is no measurement cycle any more. Aiming auto-exposure at the spot
  /// makes the camera drive that spot towards mid grey on its own, and the
  /// capture metadata reports the exposure it settles on, so [_onFrame] has a
  /// reading available on every frame.
  ///
  /// An earlier version stepped exposure compensation itself and waited for
  /// each step, taking seconds to arrive where auto-exposure had already got to
  /// unaided. All that is needed here is to tell it where to look.
  Future<void> _aimExposure() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (_exposureLocked) return;

    try {
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setExposurePoint(_meterPoint);
    } on CameraException {
      // Device may not support a metering point; AE average will do, and the
      // reading still describes whatever it settled on.
    }
  }

  /// Fallback measurement for devices without capture metadata.
  ///
  /// Without per-frame exposure there is nothing to read continuously, so a
  /// still capture is still required. Kept for iOS and for Android builds
  /// running the unforked plugin.
  Future<void> _measureFromStill({bool auto = false}) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _measuring) return;
    if (_modalOpen) return;

    setState(() {
      _measuring = true;
      _status = auto ? 'Re-metering…' : 'Metering…';
    });

    try {
      await _aimExposure();
      await Future<void>.delayed(_aeSettleDelay);

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
          _status = _exposureLocked ? 'AE-L' : 'Metered';
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

  /// Re-aims the meter, reading live where the platform allows it.
  Future<void> _measure({bool auto = false}) async {
    if (_captureMetadata.isAvailable) {
      _lastMeasuredAt = DateTime.now();
      await _aimExposure();
      return;
    }
    await _measureFromStill(auto: auto);
  }

  /// Reads the exposure the camera is holding.
  ///
  /// Prefers the preview frame's own capture metadata, which avoids taking a
  /// photograph — the still pipeline is slow, interrupts the analysis stream,
  /// and on a device measured here agreed with the preview to 0.0001 EV anyway,
  /// so the photograph bought nothing.
  ///
  /// Falls back to a still capture's EXIF where that metadata is unavailable:
  /// iOS, and any Android build without the forked plugin.
  Future<ExposureParams?> _readExposure(CameraController ctrl) async {
    final live = _captureMetadata.latest;
    if (live != null && live.hasExposure && live.age < _metadataFreshness) {
      final focal = live.focalLengthMm;
      if (focal != null && focal > 0) {
        final merged = mergeLensInfo(
          _lensInfo,
          LensInfo(focalLengthMm: focal),
        );
        if (merged != null && mounted) {
          setState(() => _lensInfo = merged);
        }
      }
      return ExposureParams(
        aperture: live.aperture!,
        shutterSeconds: live.exposureTimeSeconds!,
        iso: live.effectiveIso!,
      );
    }

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

  /// Centre-crop fraction for the viewfinder FOV + focal simulation.
  double get _simCrop {
    final lens = _lensInfo;
    if (lens == null || !lens.isUsable) return 1.0;
    return lens.cropForFormat(_viewfinderFormat, _simFocalMm, 1.0);
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
    // 645 is framed inside a 6×6 FOV square; capture matches that gate.
    final cropAspectRatio = _viewfinderFormat.aspectRatio;
    final insetWidthFrac = _is645InSixBySix ? 1.0 : null;
    final insetHeightFrac = _is645InSixBySix ? _gate645HeightFrac : null;

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
        insetWidthFrac: insetWidthFrac,
        insetHeightFrac: insetHeightFrac,
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
    double? insetWidthFrac,
    double? insetHeightFrac,
  }) async {
    try {
      final bytes = await cropFilmJpegInBackground(
        jpegBytes: jpeg,
        cropFraction: cropFraction,
        cropAspectRatio: cropAspectRatio,
        insetWidthFrac: insetWidthFrac,
        insetHeightFrac: insetHeightFrac,
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
          ev100: _nd.adjustEv100(ev),
          aperture: _aperture,
          iso: _meterIso,
        );
        return ExposureMath.formatShutter(
          ExposureMath.snapShutter(
            t,
            options: _timedShutters,
            allowUnlimited: true,
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
          ev100: _nd.adjustEv100(ev),
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
      _frameWidth = image.width;
      _frameHeight = image.height;
      _frameFormat = image.format.group.name;

      if (_multiSpotEnabled && !_measuringDistance) {
        _updateMultiSpot(image, previewSize, crop);
      }

      // Read the scene live. With capture metadata every frame carries the
      // exposure the camera used for it, so there is nothing to wait for.
      if (!_exposureLocked || _ev == null) {
        final reading = _readLive(sample);
        if (reading != null &&
            reading.quality != LiveReadingQuality.unusable) {
          _reading = reading;
          _rawSceneEv = reading.sceneEv100;
          // Calibration learns only from settled frames. "Fair" counts too: a
          // phone that renders mid-tones brighter than sRGB never reaches
          // "good", and the run's own spread check rejects an unsteady one.
          if (_calibrationRun != null && reading.aeConverged) {
            _calibrationRun!.add(reading.sceneEv100);
          }
          _readingOutOfRange = false;
          _ev = LiveMeter.smooth(
            _ev,
            reading.sceneEv100 + _calibration,
            reading,
          );
        } else if (reading != null) {
          // Crushed or clipped: hold the last good number rather than show one
          // that is wrong by stops.
          _reading = reading;
          _readingOutOfRange = true;
        }
      }

      final cct = _resolveColorTemperature(sample);
      if (cct != null && (!_exposureLocked || _cctKelvin == null)) {
        _cct = cct;
        final previous = _cctKelvin;
        _cctKelvin = previous == null
            ? cct.kelvin
            : previous + (cct.kelvin - previous) * 0.35;
      }

      if (!_measuringDistance && !_exposureLocked) {
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

  /// Re-meters when the patch has drifted too far from where the loop left it.
  ///
  /// The reading is only as good as the residual is small, so once panning has
  /// carried the patch well off mid grey, re-closing the loop beats stretching
  /// the local slope further than it holds.
  void _maybeAutoMeter(SpotSample sample) {
    if (_exposureLocked || _measuring || _modalOpen || _failedMeasurements >= 3) {
      return;
    }
    final last = _lastMeasuredAt;
    if (last != null && DateTime.now().difference(last) < _autoMeterCooldown) {
      return;
    }
    if (_params == null || _readingOutOfRange || !sample.isUsable) {
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
      _cctKelvin = null;
      _cct = null;
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
      _cctKelvin = null;
      _cct = null;
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
    return result.snappedLabel;
  }

  String get _displayedAperture {
    if (!_solvingAperture) return ExposureMath.formatAperture(_aperture);
    final result = _compensationResult(0);
    if (result == null) return '—';
    return result.snappedLabel;
  }

  /// Exact / snapped EC readout, plus `over`/`under` when beyond gear limits.
  ///
  /// Photographic EC: **+** is more exposure (longer shutter / wider
  /// aperture), **−** is less.
  _CompResult? _compensationResult(int compensationStops) {
    final ev = _ev;
    if (ev == null) return null;
    // Compensation and the filter both cut what reaches the film, so they add.
    final adjusted = _nd.adjustEv100(
      ExposureMath.ev100WithCompensation(ev, compensationStops),
    );
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
        // Past the marked timed range — still show the hold time; the
        // photographer needs 8″ / 2′ in the dark, not the word “under”.
        limit = 'hold';
      }
      return _CompResult(
        exactLabel: ExposureMath.formatShutter(seconds),
        snappedLabel: ExposureMath.formatShutter(
          ExposureMath.snapShutter(
            seconds,
            options: timed,
            allowUnlimited: true,
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
    unawaited(
      _pushWithoutCamera(
        MaterialPageRoute<void>(
          builder: (_) => AlbumPage(film: _film),
        ),
      ),
    );
  }

  void _openChecklist() {
    unawaited(() async {
      await _pushWithoutCamera(
        MaterialPageRoute<void>(
          builder: (_) => ShootChecklistPage(filmId: widget.film.id),
        ),
      );
      await _loadFrameCount();
    }());
  }

  void _openFlash() {
    unawaited(
      _pushWithoutCamera(
        MaterialPageRoute<void>(
          builder: (_) => FlashPage(
            iso: _meterIso,
            aperture: _aperture,
            ambientEv: _ev,
            initialDistance: _subjectDistanceM,
          ),
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

  String get _whiteBalanceLabel {
    final k = _cctKelvin;
    if (k == null) return 'WB —';
    final rounded = (k / 50).round() * 50;
    // A tilde marks a reading well off the black-body locus, where the number
    // is indicative rather than measured.
    final approx = _cct?.confidence == CctConfidence.low ? '~' : '';
    return '$approx${rounded}K';
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
        toolbarHeight: 64,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _film.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            if (_film.cameraLabel != null)
              Text(
                _film.cameraLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: Text(
                    _film.rollFormatLabel,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _pickIso,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: _accent,
                  ),
                  label: Text(
                    _isoChipLabel,
                    style: const TextStyle(
                      color: _accent,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: _measuringDistance
                      ? 'Cancel measure'
                      : 'Measure distance',
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
          ),
        ),
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
                aspect: _viewfinderFormat.aspectRatio,
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
                        onVerticalDragEnd: (details) {
                          final speed = details.primaryVelocity ?? 0;
                          if (speed > 700 && !_measuringDistance) {
                            _openChecklist();
                          }
                        },
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
                                  // 645: square 6×6 FOV with real 645 gate.
                                  gateHeightFrac:
                                      _is645InSixBySix ? _gate645HeightFrac : null,
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
                            if (_multiSpotEnabled &&
                                _multiSpot != null &&
                                !_measuringDistance)
                              IgnorePointer(
                                child: CustomPaint(
                                  painter: _MultiSpotPainter(
                                    points: _multiSpot!.points,
                                    labels: [
                                      for (final p in _multiSpot!.points)
                                        _multiSpotValue(p),
                                    ],
                                    colorOf: _multiSpotColor,
                                  ),
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
                                  _chip(_whiteBalanceLabel),
                                  const SizedBox(height: 6),
                                  _statusChip(),
                                  if (_subjectDistanceM != null &&
                                      !_measuringDistance) ...[
                                    const SizedBox(height: 6),
                                    _chip(
                                      'Dist ${_distanceEstimate?.displayPrefix ?? ''}'
                                      '${formatLength(_subjectDistanceM!, useFeet: false)}',
                                    ),
                                  ],
                                  if (_simLimited) ...[
                                    const SizedBox(height: 6),
                                    _chip('At phone FOV limit'),
                                  ],
                                ],
                              ),
                            ),
                            if (_debugOverlayOpen)
                              Positioned(
                                top: 10,
                                right: 10,
                                // Swallow taps: the overlay sits inside the
                                // preview's tap target, and hitting it must
                                // not move the metering spot.
                                child: GestureDetector(
                                  onTapUp: (_) {},
                                  behavior: HitTestBehavior.opaque,
                                  child: MeterDebugOverlay(
                                    info: _debugInfo,
                                    onLogSample: () =>
                                        unawaited(_logMeterSample()),
                                    onOpenLog: () => unawaited(_openMeterLog()),
                                    onClose: () => setState(
                                      () => _debugOverlayOpen = false,
                                    ),
                                  ),
                                ),
                              ),
                            if (_multiSpotEnabled &&
                                _multiSpot != null &&
                                !_measuringDistance)
                              Positioned(
                                bottom: 8,
                                left: 8,
                                child: IgnorePointer(
                                  child: _multiSpotLegend(_multiSpot!),
                                ),
                              ),
                            if (!_focalDialOpen)
                              Positioned(
                                bottom: 8,
                                right: 56,
                                child: Material(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(10),
                                  child: IconButton(
                                    tooltip: 'Multi-spot',
                                    onPressed: _saving ? null : _toggleMultiSpot,
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.all(8),
                                    constraints: const BoxConstraints(
                                      minWidth: 40,
                                      minHeight: 40,
                                    ),
                                    icon: Icon(
                                      Icons.blur_on,
                                      size: 22,
                                      color: _multiSpotEnabled
                                          ? _accent
                                          : Colors.white70,
                                    ),
                                  ),
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
          Expanded(
            child: Row(
              children: [
                _albumButton(),
                if (hint != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hint,
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
                ],
              ],
            ),
          ),
          _shutterButton(),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _checklistButton(),
                  const SizedBox(width: 6),
                  _exposureLockButton(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _checklistButton() {
    return GestureDetector(
      onTap: _openChecklist,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white54, width: 1.5),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist, size: 15, color: Colors.white70),
            SizedBox(width: 4),
            Text(
              'Step',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _exposureLockButton() {
    final locked = _exposureLocked;
    return GestureDetector(
      onTap: (_saving || _measuring) ? null : _toggleExposureLock,
      child: AnimatedOpacity(
        opacity: (_saving || _measuring) ? 0.45 : 1,
        duration: const Duration(milliseconds: 150),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: locked ? _accent : Colors.white54,
              width: 1.5,
            ),
            color: locked ? _accent.withValues(alpha: 0.18) : Colors.transparent,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                locked ? Icons.lock : Icons.lock_open,
                size: 15,
                color: locked ? _accent : Colors.white70,
              ),
              const SizedBox(width: 4),
              Text(
                'AE-L',
                style: TextStyle(
                  color: locked ? _accent : Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleExposureLock() async {
    if (_saving || _measuring) return;
    if (_exposureLocked) {
      setState(() {
        _exposureLocked = false;
        _status = 'Live meter';
      });
      return;
    }
    if (_ev == null) {
      await _measure();
      if (!mounted || _ev == null && _params == null) return;
    }
    if (!mounted) return;
    setState(() {
      _exposureLocked = true;
      _status = 'AE-L';
    });
    final ctrl = _controller;
    if (ctrl != null && ctrl.value.isInitialized) {
      try {
        await ctrl.setExposureMode(ExposureMode.locked);
      } on CameraException {
        // Reading is still held in [_ev] even if the camera cannot lock AE.
      }
    }
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
    return InkWell(
      onTap: _openAlbum,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.photo_library_outlined,
              size: 22,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Text(
              '$_frameCount',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip() {
    final warn = _readingOutOfRange;
    // Prefer the live status where a reading exists; _status is only used for
    // the still-capture fallback and for errors.
    final live = _captureMetadata.isAvailable || _reading != null;
    final text = warn
        ? _liveStatus
        : live
            ? _liveStatus
            : _status;

    final IconData icon;
    if (warn) {
      icon = Icons.warning_amber_rounded;
    } else if (_exposureLocked) {
      icon = Icons.lock_outline;
    } else {
      // Live readings are continuous, so a static lock icon would misdescribe
      // them.
      icon = Icons.sensors;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 13,
            color: warn ? Colors.orangeAccent : Colors.white70,
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: warn ? Colors.orangeAccent : Colors.white70,
              fontSize: 11,
            ),
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
              _film.isTungsten && _daylight85 && _meterIso != _iso
                  ? 'Lens EV (Hasselblad) at EI $_meterIso (85 / WB)'
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
              const SizedBox(width: 6),
              const Text(
                '+ more light',
                style: TextStyle(fontSize: 10, color: Colors.white38),
              ),
              const Spacer(),
              InkWell(
                key: const ValueKey('nd-chip'),
                onTap: _pickNd,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _nd.isNone ? Colors.white24 : _accent,
                    ),
                    color: _nd.isNone
                        ? Colors.transparent
                        : _accent.withValues(alpha: 0.16),
                  ),
                  child: Text(
                    _nd.isNone ? 'ND off' : _nd.label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: _nd.isNone ? Colors.white54 : _accent,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
    final value = result == null ? '—' : result.snappedLabel;
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
    final daylightEi = ExposureMath.eiForTungstenScene(
      tungstenIso: _iso,
      sceneKelvin: ExposureMath.daylightBalanceKelvin,
    );
    final tungstenEi = ExposureMath.eiForTungstenScene(
      tungstenIso: _iso,
      sceneKelvin: ExposureMath.tungstenBalanceKelvin,
    );
    final mixedEi = ExposureMath.eiForTungstenScene(
      tungstenIso: _iso,
      sceneKelvin: 4000,
    );
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
                    '5219 / 500T: meter a third slower than box, then add '
                    '85-filter loss as Kelvin rises. '
                    '3200 K → EI $tungstenEi, 4000 K → EI $mixedEi, '
                    '5500 K → EI $daylightEi. '
                    'Unfiltered daylight: keep ISO $_iso (cool cast).',
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
                    subtitle: 'Always ISO $_iso, ignore Kelvin',
                    onTap: () => Navigator.pop(
                      ctx,
                      _TungstenMeterChoice.tungstenRated,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _tungstenMeterTile(
                    selected: _daylight85,
                    title: '85 filter (follows WB)',
                    subtitle: _cctKelvin == null
                        ? 'EI $daylightEi at daylight until WB locks'
                        : 'Now EI $_meterIso at ${_whiteBalanceLabel}',
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

  Future<void> _pickNd() async {
    final chosen = await _showWheelPicker<NdFilter>(
      title: 'ND filter',
      items: NdFilter.presets,
      initial: _nd,
      labelOf: (f) => f.label,
    );
    if (chosen != null && chosen != _nd) {
      setState(() {
        _nd = chosen;
        _setCaptureHint(
          chosen.isNone ? 'ND off' : '${chosen.name}: +${chosen.stopsLabel}',
          clearAfter: const Duration(seconds: 2),
        );
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

  // ------------------------------------------------------------- diagnostics

  /// Matches the live meter to a trusted reference meter.
  ///
  /// The user aims at a surface, types the lens-scale EV their reference meter
  /// reads for the same light, and the app averages the live video readings
  /// over a second or two. The result replaces the calibration offset — the
  /// metering pipeline itself is untouched.
  Future<void> _calibrateToReference() async {
    if (_exposureLocked) {
      setState(
        () => _setCaptureHint(
          'Unlock exposure (AE-L) to calibrate',
          error: true,
          clearAfter: const Duration(seconds: 3),
        ),
      );
      return;
    }
    if (_sample == null || _reading == null) {
      setState(
        () => _setCaptureHint(
          'Nothing metered yet',
          error: true,
          clearAfter: const Duration(seconds: 2),
        ),
      );
      return;
    }

    final reference = await _whileModalOpen(
      () => showDialog<ReferenceExposure>(
        context: context,
        builder: (_) => ReferenceExposureDialog(
          initialIso: _meterIso,
          initial: _lastReference,
        ),
      ),
    );
    if (reference == null || !reference.isValid || !mounted) return;
    _lastReference = reference;

    final run = EvCalibrationRun();
    _calibrationRun = run;
    setState(
      () => _setCaptureHint(
        'Calibrating — hold steady',
        clearAfter: const Duration(seconds: 6),
      ),
    );

    // Frames arrive continuously; wait for enough settled ones, but not
    // forever if the patch never settles.
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (mounted && !run.isFull && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    _calibrationRun = null;
    if (!mounted) return;

    final result = run.solve(reference.ev100);

    switch (result.status) {
      case EvCalibrationStatus.ok:
        final offset = result.offset!;
        await CalibrationStore.save(offset);
        if (!mounted) return;
        setState(() {
          _calibration = offset;
          _ev = null;
          _setCaptureHint(
            'Calibrated ${ExposureMath.formatStops(offset)} '
            '(±${result.spread!.toStringAsFixed(2)}, ${result.samples} frames)',
            clearAfter: const Duration(seconds: 4),
          );
        });
      case EvCalibrationStatus.tooFewSamples:
        setState(
          () => _setCaptureHint(
            'Spot never settled — aim at a mid-tone and retry',
            error: true,
            clearAfter: const Duration(seconds: 4),
          ),
        );
      case EvCalibrationStatus.unstable:
        setState(
          () => _setCaptureHint(
            'Readings drifted ±${result.spread!.toStringAsFixed(2)} EV — '
            'hold steady under constant light',
            error: true,
            clearAfter: const Duration(seconds: 4),
          ),
        );
      case EvCalibrationStatus.outOfRange:
        setState(
          () => _setCaptureHint(
            'Off by ${ExposureMath.formatStops(result.offset!)} — '
            'check the reference EV and film speed',
            error: true,
            clearAfter: const Duration(seconds: 5),
          ),
        );
    }
  }

  /// Measures the camera's white-balance bias against a light the user names.
  ///
  /// Auto white balance has already divided the illuminant's colour out, and
  /// the plugin exposes no way to read what it divided by. One reading of a
  /// neutral surface under a known light pins that unknown down for good.
  Future<void> _setWhiteBalanceReference() async {
    final sample = _sample;
    if (sample == null) {
      setState(
        () => _setCaptureHint(
          'Nothing metered yet',
          error: true,
          clearAfter: const Duration(seconds: 2),
        ),
      );
      return;
    }

    final kelvin = await _whileModalOpen(
      () => showDialog<double>(
        context: context,
        builder: (_) => NumberInputDialog(
          title: 'Reference light (K)',
          helper: 'Aim at a white or grey surface lit only by a light whose '
              'temperature you know: 2850 tungsten, 3200 studio, 5500 '
              'daylight, 6500 overcast.',
          initialText:
              _wbReference?.referenceKelvin.round().toString() ?? '5500',
        ),
      ),
    );

    if (kelvin == null || !mounted) return;

    final reference = WhiteBalanceReference.fromNeutralPatch(
      r: sample.r,
      g: sample.g,
      b: sample.b,
      kelvin: kelvin,
      curve: _toneCurve,
    );

    if (reference == null) {
      setState(
        () => _setCaptureHint(
          'Patch is not neutral enough to reference',
          error: true,
          clearAfter: const Duration(seconds: 3),
        ),
      );
      return;
    }

    await WhiteBalanceStore.save(reference);
    if (!mounted) return;
    setState(() {
      _wbReference = reference;
      // Recompute from the next frame under the new reference.
      _cctKelvin = null;
      _cct = null;
      _setCaptureHint(
        'WB referenced to ${kelvin.round()}K',
        clearAfter: const Duration(seconds: 2),
      );
    });
  }

  Future<void> _clearWhiteBalanceReference() async {
    await WhiteBalanceStore.clear();
    if (!mounted) return;
    setState(() {
      _wbReference = null;
      _cctKelvin = null;
      _cct = null;
    });
  }

  /// Snapshot of every intermediate the current reading was derived from.
  MeterDebugInfo get _debugInfo => MeterDebugInfo(
        params: _params,
        sample: _sample,
        rawSceneEv: _rawSceneEv,
        calibration: _calibration,
        smoothedEv100: _ev,
        lensEv: _lensEv,
        meterIso: _meterIso,
        cctKelvin: _cctKelvin,
        frameWidth: _frameWidth,
        frameHeight: _frameHeight,
        frameFormat: _frameFormat,
        exposureLocked: _exposureLocked,
        measuredAt: _lastMeasuredAt,
        aeSettleMs: _aeSettleDelay.inMilliseconds,
        toneCurveRange: _toneCurve == null
            ? null
            : '${_toneCurve!.minEncoded.toStringAsFixed(2)}–'
                '${_toneCurve!.maxEncoded.toStringAsFixed(2)}',
        readingOutOfRange: _readingOutOfRange,
        servoResidual: _reading == null
            ? null
            : _reading!.encodedLuminance - LiveMeter.target,
        servoSlope: _reading?.slope,
        servoCorrection: _reading?.correctionStops,
        servoErrorBound: _reading?.estimatedErrorStops,
        servoIterations: null,
        servoOutcome: _reading?.quality.name,
        duv: _cct?.duv,
        cctConfidence: _cct?.confidence.name,
        wbReferenceKelvin: _wbReference?.referenceKelvin,
        cctSource: _colorCalibration != null &&
                _captureMetadata.latest?.neutralColorPoint != null
            ? 'raw white point'
            : 'rendered pixels',
        exposureSource: _captureMetadata.latest?.hasExposure == true
            ? 'preview frame'
            : 'still EXIF',
      );

  /// Asks for the trusted meter's lens-scale EV, then appends one CSV row.
  ///
  /// The reference is entered per sample rather than assumed, because the
  /// whole point of the log is to compare against something external.
  Future<void> _logMeterSample() async {
    if (_ev == null || _params == null) {
      setState(
        () => _setCaptureHint(
          'Nothing measured yet',
          error: true,
          clearAfter: const Duration(seconds: 2),
        ),
      );
      return;
    }

    final snapshot = _debugInfo;
    final entered = await _whileModalOpen(
      () => showDialog<double>(
        context: context,
        builder: (_) => NumberInputDialog(
          title: 'Reference EV',
          helper: 'Lens-scale EV from the meter you trust '
              '(at ISO ${snapshot.meterIso}). Leave blank to log unpaired.',
          initialText: _lastReferenceEv?.toStringAsFixed(1) ?? '',
        ),
      ),
    );

    if (entered != null && entered.isFinite) {
      _lastReferenceEv = entered;
    }

    await MeterLogStore.append(
      snapshot.toCsvRow(referenceEv: entered),
    );

    if (!mounted) return;
    final count = await MeterLogStore.count();
    if (!mounted) return;
    setState(
      () => _setCaptureHint(
        'Logged · $count samples',
        clearAfter: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openMeterLog() async {    await _whileModalOpen(
      () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF161616),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => const MeterLogSheet(),
      ),
    );
  }

  Future<void> _openAeSweep() async {
    await _whileModalOpen(
      () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF161616),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => AeSweepSheet(
          run: _runAeSweep,
          accent: _accent,
          onCurveApplied: (curve) {
            if (!mounted) return;
            setState(() {
              _toneCurve = curve;
              // Recompute from the next frame under the new curve.
              _ev = null;
            });
          },
        ),
      ),
    );
  }

  /// Steps AE across its compensation range on a static scene, recording what
  /// the camera exposed at and how the preview rendered the patch each time.
  ///
  /// The scene does not change, so every rung describes the same light and
  /// should report the same EV. Any spread is error, and needs no external
  /// reference to measure — which is the point: it works without a grey card
  /// or a second meter.
  Future<AeSweepResult?> _runAeSweep(
    void Function(AeSweepProgress) onProgress,
  ) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return null;

    final double minOffset;
    final double maxOffset;
    try {
      minOffset = await ctrl.getMinExposureOffset();
      maxOffset = await ctrl.getMaxExposureOffset();
    } on CameraException {
      return null;
    }

    // A device with no compensation range cannot be swept.
    if (!(maxOffset - minOffset).isFinite || maxOffset - minOffset < 0.5) {
      return null;
    }

    // Sample the range at one-stop-ish intervals, capped so a full sweep stays
    // under about a minute.
    const maxRungs = 7;
    final span = maxOffset - minOffset;
    final rungs = min(maxRungs, max(3, span.round() + 1));
    final targets = List<double>.generate(
      rungs,
      (i) => minOffset + span * i / (rungs - 1),
    );

    final previousMeasuring = _measuring;
    _measuring = true; // Hold off automatic re-metering for the duration.
    final points = <AeSweepPoint>[];

    try {
      for (var i = 0; i < targets.length; i++) {
        if (!mounted) break;
        final target = targets[i];

        onProgress(
          AeSweepProgress(
            done: i,
            total: targets.length,
            message: 'Rung ${i + 1} of ${targets.length} · '
                '${target >= 0 ? '+' : '−'}${target.abs().toStringAsFixed(1)} EV',
          ),
        );

        try {
          await ctrl.setExposureMode(ExposureMode.auto);
          await ctrl.setExposurePoint(_meterPoint);
          await ctrl.setExposureOffset(target);
        } on CameraException {
          continue;
        }

        await Future<void>.delayed(_aeSettleDelay);

        try {
          await ctrl.setExposureMode(ExposureMode.locked);
        } on CameraException {
          // Not fatal — the still and the patch are still read back to back.
        }

        final params = await _readExposure(ctrl);
        if (params == null) continue;

        // Sample after the still, so the patch reflects the same locked
        // exposure the EXIF describes.
        final sample = await _sampleCurrentPatch();
        if (sample == null) continue;

        points.add(
          AeSweepPoint(
            requestedOffset: target,
            params: params,
            sample: sample,
          ),
        );
      }
    } finally {
      _measuring = previousMeasuring;
      try {
        await ctrl.setExposureOffset(0);
        await ctrl.setExposureMode(ExposureMode.auto);
      } on CameraException {
        // Best effort restore.
      }
      // The sweep invalidated the working reading; take a fresh one.
      if (mounted) {
        setState(() {
          _params = null;
          _ev = null;
        });
        unawaited(_measure(auto: true));
      }
    }

    onProgress(
      AeSweepProgress(
        done: targets.length,
        total: targets.length,
        message: 'Done',
      ),
    );

    return AeSweepResult(points: points);
  }

  /// Waits for the next analysed preview frame and returns its patch.
  Future<SpotSample?> _sampleCurrentPatch() async {
    // _onFrame refreshes _sample continuously; give it a couple of frames to
    // publish one taken under the exposure just locked in.
    final before = _sample;
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final current = _sample;
      if (current != null && !identical(current, before)) return current;
    }
    return _sample;
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
                      'Phones report ISO on their own scale, so every reading '
                      'can be a constant stop or so off. Match to your camera '
                      'to correct it, or nudge the offset by hand.',
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
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          unawaited(_calibrateToReference());
                        },
                        icon: const Icon(Icons.straighten, size: 16),
                        label: const Text('Match to my camera'),
                      ),
                    ),
                    const Divider(height: 20, color: Colors.white12),
                    const Text(
                      'White balance reference',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _wbReference == null
                          ? 'Auto white balance has already removed most of '
                              'the light\'s colour, and Android gives no way '
                              'to read what it removed. Meter a white or grey '
                              'surface under a light you know, name its '
                              'temperature, and every later reading is '
                              'anchored to it.'
                          : 'Anchored to '
                              '${_wbReference!.referenceKelvin.round()}K, '
                              'correcting '
                              '${_wbReference!.strengthStops.toStringAsFixed(2)}'
                              ' stops of channel gain.',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            unawaited(_setWhiteBalanceReference());
                          },
                          icon: const Icon(Icons.wb_incandescent_outlined,
                              size: 16),
                          label: Text(
                            _wbReference == null
                                ? 'Set reference'
                                : 'Re-measure',
                          ),
                        ),
                        if (_wbReference != null) ...[
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              setSheetState(() {});
                              unawaited(_clearWhiteBalanceReference());
                            },
                            child: const Text('Clear'),
                          ),
                        ],
                      ],
                    ),
                    const Divider(height: 20, color: Colors.white12),
                    const Text(
                      'Diagnostics',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'A single offset only corrects a constant error. Run the '
                      'AE sweep to find out whether this phone\'s error is '
                      'constant — it needs no grey card and no reference '
                      'meter, only a still scene.',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          unawaited(_openAeSweep());
                        },
                        icon: const Icon(Icons.compare_arrows, size: 16),
                        label: const Text('AE consistency sweep'),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _debugOverlayOpen,
                      activeThumbColor: _accent,
                      title: const Text(
                        'Live meter readout',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: const Text(
                        'Show EXIF, patch luminance and tone-curve warnings',
                        style: TextStyle(fontSize: 11, color: Colors.white38),
                      ),
                      onChanged: (v) {
                        setSheetState(() {});
                        setState(() => _debugOverlayOpen = v);
                      },
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          unawaited(_openMeterLog());
                        },
                        icon: const Icon(Icons.list_alt, size: 16),
                        label: const Text('Metering log'),
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

  /// When set (e.g. 645 in a 6×6 square), draw this centred gate height
  /// fraction with mask bars outside it. Width stays full.
  final double? gateHeightFrac;

  _FilmFramePainter({
    required this.color,
    this.showThirds = true,
    this.gateHeightFrac,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final outer = (Offset.zero & size).deflate(1);
    final gateFrac = gateHeightFrac;

    late final Rect frame;
    if (gateFrac != null && gateFrac > 0 && gateFrac < 1) {
      final gateH = size.height * gateFrac.clamp(0.05, 1.0);
      final top = (size.height - gateH) / 2;
      frame = Rect.fromLTWH(1, top, size.width - 2, gateH);

      // Dim the 6×6 areas outside the real 645 gate.
      final mask = Paint()..color = Colors.black.withValues(alpha: 0.45);
      canvas.drawRect(Rect.fromLTRB(0, 0, size.width, frame.top), mask);
      canvas.drawRect(
        Rect.fromLTRB(0, frame.bottom, size.width, size.height),
        mask,
      );

      // Outer 6×6 outline.
      canvas.drawRect(
        outer,
        Paint()
          ..color = Colors.white24
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    } else {
      frame = outer;
    }

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
      color != old.color ||
      showThirds != old.showThirds ||
      gateHeightFrac != old.gateHeightFrac;
}

/// Draws the multi-spot markers: a colour-coded ring per spot with its value
/// beside it. Labels are pushed apart so spots that land close together stay
/// readable.
class _MultiSpotPainter extends CustomPainter {
  _MultiSpotPainter({
    required this.points,
    required this.labels,
    required this.colorOf,
  });

  final List<MultiSpotPoint> points;
  final List<String> labels;
  final Color Function(MultiSpotRole) colorOf;

  @override
  void paint(Canvas canvas, Size size) {
    final placed = <Rect>[];

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final color = colorOf(p.role);
      final c = Offset(p.x * size.width, p.y * size.height);

      canvas.drawCircle(
        c,
        9,
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      );
      canvas.drawCircle(
        c,
        7,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
      canvas.drawCircle(c, 2.5, Paint()..color = color);

      final text = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final w = text.width + 10;
      final h = text.height + 4;
      var left = c.dx + 13;
      if (left + w > size.width - 2) left = c.dx - 13 - w;
      var rect = Rect.fromLTWH(left, c.dy - h / 2, w, h);

      // Nudge down past any label already drawn here.
      for (var guard = 0;
          guard < 8 && placed.any((r) => r.overlaps(rect));
          guard++) {
        rect = rect.shift(Offset(0, h + 2));
      }
      if (rect.bottom > size.height - 2) {
        rect = rect.shift(Offset(0, size.height - 2 - rect.bottom));
      }
      if (rect.top < 2) rect = rect.shift(Offset(0, 2 - rect.top));
      placed.add(rect);

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(5)),
        Paint()..color = Colors.black.withValues(alpha: 0.62),
      );
      text.paint(canvas, Offset(rect.left + 5, rect.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _MultiSpotPainter old) =>
      !identical(points, old.points) || !listEquals(labels, old.labels);
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

  /// `over` / `hold` when the exact solve is outside camera/lens range.
  final String? limitLabel;
}
