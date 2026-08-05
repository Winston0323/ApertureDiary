import 'dart:io';
import 'dart:math' show max, min;

import 'package:camera/camera.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import 'calibration.dart';
import 'exposure.dart';
import 'film_frame.dart';
import 'flash.dart';
import 'flash_scale.dart';
import 'lens_info.dart';
import 'metering.dart';
import 'number_input_dialog.dart';
import 'six_by_six.dart';
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
  runApp(LightMeterApp(camera: rear));
}

const Color _accent = Color(0xFFFFB300);

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
  segmentedButtonTheme: SegmentedButtonThemeData(
    style: ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.black;
        return Colors.white70;
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return _accent;
        return const Color(0xFF1E1E1E);
      }),
    ),
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

class LightMeterApp extends StatelessWidget {
  final CameraDescription camera;
  const LightMeterApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Light Meter',
      debugShowCheckedModeBanner: false,
      theme: _darkTheme,
      home: LightMeterPage(camera: camera),
    );
  }
}

class LightMeterPage extends StatefulWidget {
  final CameraDescription camera;
  const LightMeterPage({super.key, required this.camera});

  @override
  State<LightMeterPage> createState() => _LightMeterPageState();
}

class _LightMeterPageState extends State<LightMeterPage>
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
  double? _ev;
  double _calibration = 0.0;

  bool _measuring = false;
  bool _saving = false;
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
  double _currentZoom = 1.0;

  CalcMode _calcMode = CalcMode.shutter;
  int _iso = 400;
  double _aperture = 2.8;
  double _shutter = 1 / 125;

  /// Guide number at ISO 100 and flash-to-subject distance, both in metres.
  /// Stored metric and converted for display so the unit toggle cannot change
  /// what was entered.
  double _guideNumber = 36.0;
  double _distance = 3.0;
  bool _useFeet = false;

  /// 6×6 focal-length viewfinder simulation.
  bool _sixBySixEnabled = false;
  double _simFocalMm = SixBySix.defaultFocalMm;
  LensInfo? _lensInfo;

  final GlobalKey _previewKey = GlobalKey();

  int get _quarterTurns => (widget.camera.sensorOrientation ~/ 90) % 4;

  bool get _mirror =>
      widget.camera.lensDirection == CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCalibration();
    _startCamera();
  }

  Future<void> _loadCalibration() async {
    final value = await CalibrationStore.load();
    if (mounted && value != 0.0) {
      setState(() => _calibration = value);
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
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );

    try {
      await _controller!.initialize();
      _minZoom = await _controller!.getMinZoomLevel();
      _maxZoom = await _controller!.getMaxZoomLevel();
      _currentZoom = _minZoom;
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

  /// Centre-crop fraction for the current 6×6 simulation, or null when off.
  double? get _sixBySixCrop {
    if (!_sixBySixEnabled) return null;
    final lens = _lensInfo;
    if (lens == null || !lens.isUsable) return 1.0;
    return lens.cropForSixBySix(_simFocalMm, _currentZoom);
  }

  bool get _sixBySixLimited {
    final crop = _sixBySixCrop;
    return _sixBySixEnabled && crop != null && crop >= 0.999;
  }

  /// Takes a still, stopping the analysis stream when the platform requires it.
  Future<Uint8List> _captureStillBytes(CameraController ctrl) async {
    XFile file;
    var restartStream = false;
    try {
      file = await ctrl.takePicture();
    } on CameraException {
      if (!ctrl.value.isStreamingImages) rethrow;
      await ctrl.stopImageStream();
      restartStream = true;
      file = await ctrl.takePicture();
    }

    try {
      return await file.readAsBytes();
    } finally {
      try {
        await File(file.path).delete();
      } catch (_) {
        // Temp file cleanup is best effort.
      }
      if (restartStream && !ctrl.value.isStreamingImages) {
        await ctrl.startImageStream(_onFrame);
        try {
          await ctrl.setExposureMode(ExposureMode.locked);
        } on CameraException {
          // Ignore.
        }
      }
    }
  }

  /// Captures the current frame, stamps film settings, and saves to the album.
  Future<void> _saveFrame() async {
    final ctrl = _controller;
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        _saving ||
        _measuring ||
        _modalOpen) {
      return;
    }

    setState(() {
      _saving = true;
      _status = 'Saving…';
    });

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (mounted) {
            setState(() => _status = 'Gallery permission denied');
            _toast('Allow photo access to save frames');
          }
          return;
        }
      }

      final jpeg = await _captureStillBytes(ctrl);
      final stamped = await stampFilmFrame(
        jpegBytes: jpeg,
        caption: _filmCaption(),
        cropFraction: _sixBySixCrop,
      );

      final name =
          'light_meter_${DateTime.now().millisecondsSinceEpoch}';
      await Gal.putImageBytes(stamped, name: name, album: 'Light Meter');

      if (!mounted) return;
      setState(() => _status = 'Saved to album');
      _toast('Saved to Light Meter album');
    } on GalException catch (e) {
      if (mounted) {
        setState(() => _status = 'Save failed');
        _toast(e.type.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Save failed');
        _toast('Could not save: $e');
      }
    } finally {
      _saving = false;
      if (mounted) setState(() {});
    }
  }

  FilmFrameCaption _filmCaption() {
    final shutter = _stampShutter();
    final aperture = _stampAperture();
    final ev = _ev;
    final extras = <String>[];
    if (_calcMode == CalcMode.flash) {
      final power = _recommendedPower;
      extras.add(
        power == null
            ? 'Flash out of reach'
            : 'Flash ${FlashMath.formatPower(power)}',
      );
    }
    if (_sixBySixEnabled) {
      extras.add('6×6 ${SixBySix.formatFocal(_simFocalMm)}');
    }

    return FilmFrameCaption(
      shutter: shutter,
      aperture: aperture,
      iso: '$_iso',
      ev: ev == null ? null : 'EV ${ev.toStringAsFixed(1)}',
      extra: extras.isEmpty ? null : extras.join('  ·  '),
    );
  }

  String _stampShutter() {
    if (_calcMode == CalcMode.shutter) {
      final ev = _ev;
      if (ev != null) {
        final t = ExposureMath.shutterFromEv(
          ev100: ev,
          aperture: _aperture,
          iso: _iso,
        );
        return ExposureMath.formatShutter(ExposureMath.snapShutter(t));
      }
    }
    if (_calcMode == CalcMode.flash) {
      final ev = _ev;
      if (ev != null) {
        final t = ExposureMath.shutterFromEv(
          ev100: ev,
          aperture: _aperture,
          iso: _iso,
        );
        return ExposureMath.formatShutter(ExposureMath.snapShutter(t));
      }
      return 'flash';
    }
    return ExposureMath.formatShutter(_shutter);
  }

  String _stampAperture() {
    if (_calcMode == CalcMode.aperture) {
      final ev = _ev;
      if (ev != null) {
        final n = ExposureMath.apertureFromEv(
          ev100: ev,
          shutterSeconds: _shutter,
          iso: _iso,
        );
        return ExposureMath.formatAperture(ExposureMath.snapAperture(n));
      }
    }
    return ExposureMath.formatAperture(_aperture);
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
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
      final crop = _sixBySixCrop;
      if (crop != null && crop < 1.0) {
        final mapped =
            SixBySix.mapViewfinderToPreview(spot.dx, spot.dy, crop);
        spot = Offset(mapped.x, mapped.y);
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

      _maybeAutoMeter(sample);

      if (_publishClock.elapsedMilliseconds >= 80) {
        _publishClock.reset();
        setState(() {});
      }
    } finally {
      _isProcessing = false;
    }
  }

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
    setState(() {
      _meterPoint = Offset(
        (local.dx / w).clamp(0.0, 1.0),
        (local.dy / h).clamp(0.0, 1.0),
      );
      _ev = null;
    });
    _measure();
  }

  Future<void> _onZoomChanged(double value) async {
    setState(() => _currentZoom = value);
    await _controller?.setZoomLevel(value);
  }

  // -------------------------------------------------------------- calculator

  _CalcResult get _calcResult {
    switch (_calcMode) {
      case CalcMode.shutter:
        return _shutterResult();
      case CalcMode.aperture:
        return _apertureResult();
      case CalcMode.flash:
        return _flashResult();
    }
  }

  _CalcResult _shutterResult() {
    final ev = _ev;
    if (ev == null) {
      return const _CalcResult(
        title: 'Suggested shutter',
        value: '—',
        detail: 'Meter a point first',
      );
    }
    final exact =
        ExposureMath.shutterFromEv(ev100: ev, aperture: _aperture, iso: _iso);
    return _CalcResult(
      title: 'Suggested shutter',
      value: ExposureMath.formatShutter(ExposureMath.snapShutter(exact)),
      detail: 'exact ${ExposureMath.formatShutter(exact)}  ·  '
          '${ExposureMath.formatAperture(_aperture)}  ·  ISO $_iso',
    );
  }

  _CalcResult _apertureResult() {
    final ev = _ev;
    if (ev == null) {
      return const _CalcResult(
        title: 'Suggested aperture',
        value: '—',
        detail: 'Meter a point first',
      );
    }
    final exact = ExposureMath.apertureFromEv(
      ev100: ev,
      shutterSeconds: _shutter,
      iso: _iso,
    );
    return _CalcResult(
      title: 'Suggested aperture',
      value: ExposureMath.formatAperture(ExposureMath.snapAperture(exact)),
      detail: 'exact ${ExposureMath.formatAperture(exact)}  ·  '
          '${ExposureMath.formatShutter(_shutter)}  ·  ISO $_iso',
    );
  }

  _CalcResult _flashResult() {
    final exact = FlashMath.powerFraction(
      guideNumberIso100: _guideNumber,
      iso: _iso,
      aperture: _aperture,
      distance: _distance,
    );
    if (!exact.isFinite) {
      return const _CalcResult(
        title: 'Flash power',
        value: '—',
        detail: 'Enter a guide number and a distance',
      );
    }

    final fullPowerReach = FlashMath.distanceAtPower(
      guideNumberIso100: _guideNumber,
      iso: _iso,
      aperture: _aperture,
      fraction: 1,
    );
    final workingGn = FlashMath.guideNumberAtIso(
      guideNumberIso100: _guideNumber,
      iso: _iso,
    );
    final reachNote = 'Full power reaches ${_formatLength(fullPowerReach)} at '
        '${ExposureMath.formatAperture(_aperture)}  ·  '
        'GN ${formatNumber(_convertLength(workingGn))} at ISO $_iso';

    if (exact > 1) {
      final short = FlashMath.stopsBeyondFullPower(exact);
      final needed = FlashMath.apertureAtPower(
        guideNumberIso100: _guideNumber,
        iso: _iso,
        distance: _distance,
        fraction: 1,
      );
      return _CalcResult(
        title: 'Flash power',
        value: '1/1',
        detail: reachNote,
        warning: 'Out of reach by ${short.toStringAsFixed(1)} stops — open to '
            '${ExposureMath.formatAperture(needed)}, move closer, or use '
            'faster film',
      );
    }

    final snapped = FlashMath.snapPower(exact);
    final error = FlashMath.snapErrorStops(exact: exact, snapped: snapped);

    String? warning;
    if (exact < FlashMath.weakestPower) {
      final weakestReach = FlashMath.distanceAtPower(
        guideNumberIso100: _guideNumber,
        iso: _iso,
        aperture: _aperture,
        fraction: FlashMath.weakestPower,
      );
      warning = 'Less light needed than 1/128 gives — stop down or move back '
          'past ${_formatLength(weakestReach)}';
    }

    return _CalcResult(
      title: 'Flash power',
      value: FlashMath.formatPower(snapped),
      detail: 'exact ${FlashMath.formatPowerPercent(exact)}  ·  '
          'rounding ${ExposureMath.formatStops(error)}',
      note: reachNote,
      warning: warning,
    );
  }

  /// Shutter that would expose the ambient light the same way, so you can see
  /// whether the background will register alongside the flash.
  String? get _ambientShutterNote {
    final ev = _ev;
    if (ev == null) return null;
    final t =
        ExposureMath.shutterFromEv(ev100: ev, aperture: _aperture, iso: _iso);
    return 'Ambient alone needs '
        '${ExposureMath.formatShutter(ExposureMath.snapShutter(t))} — stay at '
        'or below your sync speed to keep it dark';
  }

  double _convertLength(double metres) =>
      convertLength(metres, useFeet: _useFeet);

  String _formatLength(double metres) =>
      formatLength(metres, useFeet: _useFeet);

  /// The setting the scale should mark, or null when the subject is out of
  /// reach at full power.
  double? get _recommendedPower {
    final exact = FlashMath.powerFraction(
      guideNumberIso100: _guideNumber,
      iso: _iso,
      aperture: _aperture,
      distance: _distance,
    );
    if (!exact.isFinite || exact > 1) return null;
    return FlashMath.snapPower(exact);
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
      body: SafeArea(
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
    // The on-screen keyboard shrinks the body, and flash mode adds a row, so
    // the controls are allowed to scroll rather than overflow once they would
    // squeeze the preview below a usable size.
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
                child: Column(
                  children: [
                    _buildMeterReadout(),
                    _buildExposurePanel(),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPreview(CameraController ctrl) {
    return Row(
      children: [
        if (_maxZoom > _minZoom) _buildZoomSlider(),
        Expanded(
          child: Column(
            children: [
              if (_sixBySixEnabled) _buildFocalBar(),
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final crop = _sixBySixCrop ?? 1.0;
                    final side = min(constraints.maxWidth, constraints.maxHeight);
                    // Square viewfinder when simulating 6×6; otherwise full area.
                    final viewW = _sixBySixEnabled ? side : constraints.maxWidth;
                    final viewH = _sixBySixEnabled ? side : constraints.maxHeight;
                    _previewSize = Size(viewW, viewH);

                    return Center(
                      child: SizedBox(
                        key: _previewKey,
                        width: viewW,
                        height: viewH,
                        child: GestureDetector(
                          onTapUp: _onTapUp,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRect(
                                child: Transform.scale(
                                  scale: _sixBySixEnabled ? (1.0 / crop) : 1.0,
                                  child: OverflowBox(
                                    alignment: Alignment.center,
                                    child: FittedBox(
                                      fit: BoxFit.cover,
                                      child: SizedBox(
                                        width: ctrl.value.previewSize?.height ??
                                            viewW,
                                        height: ctrl.value.previewSize?.width ??
                                            viewH,
                                        child: CameraPreview(ctrl),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (_sixBySixEnabled)
                                IgnorePointer(
                                  child: CustomPaint(
                                    painter: _SixBySixFramePainter(
                                      color: _accent,
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
                              Positioned(
                                top: 12,
                                right: 12,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    _chip('${_currentZoom.toStringAsFixed(1)}×'),
                                    if (_sixBySixEnabled) ...[
                                      const SizedBox(height: 6),
                                      _chip(SixBySix.formatFocal(_simFocalMm)),
                                    ],
                                  ],
                                ),
                              ),
                              Positioned(
                                top: 12,
                                left: 12,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _statusChip(),
                                    const SizedBox(height: 6),
                                    _sixBySixToggle(),
                                    if (_sixBySixEnabled &&
                                        _lensInfo != null) ...[
                                      const SizedBox(height: 6),
                                      _chip(
                                        'Lens ${_lensInfo!.focalLengthMm.toStringAsFixed(1)} mm',
                                      ),
                                    ],
                                    if (_sixBySixLimited) ...[
                                      const SizedBox(height: 6),
                                      _chip('At phone FOV limit'),
                                    ],
                                  ],
                                ),
                              ),
                              Positioned(
                                bottom: 12,
                                right: 12,
                                child: _meterButton(),
                              ),
                              Positioned(
                                bottom: 12,
                                left: 0,
                                right: 0,
                                child: Center(child: _shutterButton()),
                              ),
                              const Positioned(
                                left: 12,
                                bottom: 78,
                                child: Text(
                                  'Tap a point to meter it',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                    shadows: [
                                      Shadow(
                                        blurRadius: 4,
                                        color: Colors.black,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sixBySixToggle() {
    return GestureDetector(
      onTap: () {
        setState(() {
          _sixBySixEnabled = !_sixBySixEnabled;
          // Reset the spot to centre when entering the square finder.
          if (_sixBySixEnabled) {
            _meterPoint = const Offset(0.5, 0.5);
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _sixBySixEnabled
              ? _accent.withValues(alpha: 0.9)
              : Colors.black54,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _sixBySixEnabled ? _accent : Colors.white24,
          ),
        ),
        child: Text(
          '6×6',
          style: TextStyle(
            color: _sixBySixEnabled ? Colors.black : Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildFocalBar() {
    return Container(
      height: 52,
      color: const Color(0xFF0F0F0F),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: SixBySix.standardLensesMm.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final mm = SixBySix.standardLensesMm[i];
          final selected = (mm - _simFocalMm).abs() < 0.01;
          return GestureDetector(
            onTap: () => setState(() => _simFocalMm = mm),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? _accent.withValues(alpha: 0.2)
                    : const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? _accent : Colors.white12,
                ),
              ),
              child: Text(
                '${mm.round()}',
                style: TextStyle(
                  color: selected ? _accent : Colors.white70,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _shutterButton() {
    final busy = _saving || _measuring;
    return GestureDetector(
      onTap: busy ? null : _saveFrame,
      child: AnimatedOpacity(
        opacity: busy ? 0.45 : 1,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.all(4),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _saving ? _accent : Colors.white,
            ),
            child: _saving
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.black,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _meterButton() {
    return FilledButton.icon(
      onPressed: (_measuring || _saving) ? null : () => _measure(),
      style: FilledButton.styleFrom(
        backgroundColor: _accent,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
      icon: _measuring
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.black,
              ),
            )
          : const Icon(Icons.center_focus_strong, size: 18),
      label: Text(_measuring ? 'Metering' : 'Meter'),
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

  Widget _buildZoomSlider() {
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: 16),
      color: const Color(0xFF0F0F0F),
      child: Column(
        children: [
          Text(
            '${_maxZoom.toStringAsFixed(0)}×',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: Slider(
                value: _currentZoom.clamp(_minZoom, _maxZoom),
                min: _minZoom,
                max: _maxZoom,
                onChanged: _onZoomChanged,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text('1×',
              style: TextStyle(fontSize: 11, color: Colors.white54)),
        ],
      ),
    );
  }

  Widget _buildMeterReadout() {
    final ev = _ev;
    final params = _params;
    final sample = _sample;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text(
                      'EV ',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.white54,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    Text(
                      ev == null ? '—' : ev.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 40,
                        color: _accent,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (ev != null)
                      Text(
                        _evToLabel(ev),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  params == null
                      ? 'Waiting for a measurement'
                      : 'Sensor ${params.summary}',
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
                if (sample != null && params != null)
                  Text(
                    'Spot ${ExposureMath.formatStops(sample.stopsFromMiddleGrey)} '
                    'from mid-grey',
                    style: TextStyle(
                      fontSize: 11,
                      color: sample.isUsable
                          ? Colors.white38
                          : Colors.orangeAccent,
                    ),
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (sample != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Color.fromARGB(255, sample.r, sample.g, sample.b),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Text(
                    'R${sample.r} G${sample.g} B${sample.b}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: (sample.r + sample.g + sample.b) / 3 > 128
                          ? Colors.black87
                          : Colors.white,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              InkWell(
                onTap: _openCalibration,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(
                    'Cal ${_calibration >= 0 ? '+' : '−'}'
                    '${_calibration.abs().toStringAsFixed(1)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildExposurePanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      color: const Color(0xFF0A0A0A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<CalcMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: CalcMode.shutter, label: Text('Shutter')),
              ButtonSegment(value: CalcMode.aperture, label: Text('Aperture')),
              ButtonSegment(value: CalcMode.flash, label: Text('Flash')),
            ],
            selected: {_calcMode},
            onSelectionChanged: (s) => setState(() => _calcMode = s.first),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _pickerTile(
                  label: 'Film ISO',
                  value: '$_iso',
                  onTap: _pickIso,
                  emphasize: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _calcMode == CalcMode.aperture
                    ? _pickerTile(
                        label: 'Shutter',
                        value: ExposureMath.formatShutter(_shutter),
                        onTap: _pickShutter,
                        emphasize: true,
                      )
                    : _pickerTile(
                        label: 'Aperture',
                        value: ExposureMath.formatAperture(_aperture),
                        onTap: _pickAperture,
                        emphasize: true,
                      ),
              ),
            ],
          ),
          if (_calcMode == CalcMode.flash) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _pickerTile(
                    label: 'Guide no. (ISO 100)',
                    value: formatNumber(_convertLength(_guideNumber)),
                    onTap: _promptGuideNumber,
                    icon: Icons.edit_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _pickerTile(
                    label: 'Distance',
                    value: _formatLength(_distance),
                    onTap: _promptDistance,
                    icon: Icons.edit_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 72,
                  child: _pickerTile(
                    label: 'Unit',
                    value: _useFeet ? 'ft' : 'm',
                    onTap: () => setState(() => _useFeet = !_useFeet),
                    icon: Icons.swap_horiz,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          _buildResultCard(_calcResult),
          if (_calcMode == CalcMode.flash) ...[
            const SizedBox(height: 12),
            FlashRangeScale(
              guideNumberIso100: _guideNumber,
              iso: _iso,
              aperture: _aperture,
              useFeet: _useFeet,
              highlightedPower: _recommendedPower,
              subjectDistance: _distance,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResultCard(_CalcResult result) {
    final ambient =
        _calcMode == CalcMode.flash ? _ambientShutterNote : null;
    const noteStyle = TextStyle(fontSize: 10.5, color: Colors.white38);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33FFB300)),
      ),
      child: Column(
        children: [
          Text(
            result.title,
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          Text(
            result.value,
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: _accent,
              letterSpacing: -0.5,
              height: 1.1,
            ),
          ),
          Text(result.detail, style: noteStyle, textAlign: TextAlign.center),
          if (result.note != null)
            Text(result.note!, style: noteStyle, textAlign: TextAlign.center),
          if (ambient != null)
            Text(ambient, style: noteStyle, textAlign: TextAlign.center),
          if (result.warning != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      result.warning!,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Colors.orangeAccent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _pickerTile({
    required String label,
    required String value,
    required VoidCallback onTap,
    IconData icon = Icons.expand_more,
    bool emphasize = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: emphasize
              ? const Color(0xFF221C0A)
              : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: emphasize ? const Color(0x55FFB300) : Colors.white12,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: emphasize ? _accent.withValues(alpha: 0.75) : Colors.white54,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: emphasize ? 22 : 19,
                      fontWeight: FontWeight.w700,
                      color: emphasize ? _accent : Colors.white,
                      letterSpacing: emphasize ? -0.4 : 0,
                    ),
                  ),
                ),
                Icon(
                  icon,
                  color: emphasize ? _accent.withValues(alpha: 0.7) : Colors.white38,
                  size: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptGuideNumber() async {
    final entered = await _promptNumber(
      title: 'Guide number',
      helper: 'As rated at ISO 100, in ${_useFeet ? 'feet' : 'metres'}',
      initial: _convertLength(_guideNumber),
      lowest: 1,
      highest: 300,
    );
    if (entered == null) return;
    setState(() {
      _guideNumber = toMetres(entered, useFeet: _useFeet);
    });
  }

  Future<void> _promptDistance() async {
    final entered = await _promptNumber(
      title: 'Flash to subject',
      helper: _useFeet ? 'In feet' : 'In metres',
      initial: _convertLength(_distance),
      lowest: 0.1,
      highest: 300,
    );
    if (entered == null) return;
    setState(() {
      _distance = toMetres(entered, useFeet: _useFeet);
    });
  }

  Future<double?> _promptNumber({
    required String title,
    required String helper,
    required double initial,
    required double lowest,
    required double highest,
  }) async {
    final entered = await _whileModalOpen(
      () => showDialog<double>(
        context: context,
        builder: (ctx) => NumberInputDialog(
          title: title,
          helper: helper,
          initialText: formatNumber(initial),
        ),
      ),
    );
    if (entered == null || !entered.isFinite || entered <= 0) return null;
    return entered.clamp(lowest, highest);
  }

  Future<void> _pickIso() async {
    final chosen = await _showWheelPicker<int>(
      title: 'Film ISO',
      items: ExposureMath.standardIsos,
      initial: _iso,
      labelOf: (v) => '$v',
    );
    if (chosen != null) setState(() => _iso = chosen);
  }

  Future<void> _pickAperture() async {
    final chosen = await _showWheelPicker<double>(
      title: 'Aperture',
      items: ExposureMath.standardApertures,
      initial: _aperture,
      labelOf: ExposureMath.formatAperture,
    );
    if (chosen != null) setState(() => _aperture = chosen);
  }

  Future<void> _pickShutter() async {
    final chosen = await _showWheelPicker<double>(
      title: 'Shutter speed',
      items: ExposureMath.standardShutters,
      initial: _shutter,
      labelOf: ExposureMath.formatShutter,
    );
    if (chosen != null) setState(() => _shutter = chosen);
  }

  Future<T?> _showWheelPicker<T>({
    required String title,
    required List<T> items,
    required T initial,
    required String Function(T) labelOf,
  }) {
    var index = items.indexOf(initial);
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

/// One computed answer for the calculator panel.
@immutable
class _CalcResult {
  final String title;
  final String value;
  final String detail;
  final String? note;
  final String? warning;

  const _CalcResult({
    required this.title,
    required this.value,
    required this.detail,
    this.note,
    this.warning,
  });
}

/// Draws the metered patch: a ring the size of the area actually sampled,
/// plus a broken crosshair for precise aim.
class _SixBySixFramePainter extends CustomPainter {
  final Color color;

  _SixBySixFramePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final border = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect.deflate(1), border);

    // Light rule-of-thirds guides inside the square finder.
    final guide = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      guide,
    );
    canvas.drawLine(
      Offset(2 * size.width / 3, 0),
      Offset(2 * size.width / 3, size.height),
      guide,
    );
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      guide,
    );
    canvas.drawLine(
      Offset(0, 2 * size.height / 3),
      Offset(size.width, 2 * size.height / 3),
      guide,
    );
  }

  @override
  bool shouldRepaint(covariant _SixBySixFramePainter old) => color != old.color;
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
