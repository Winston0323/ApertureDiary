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
import 'exposure.dart';
import 'film_format.dart';
import 'film_frame.dart';
import 'film_stock.dart';
import 'flash_page.dart';
import 'home_page.dart';
import 'lens_info.dart';
import 'metering.dart';
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
          onOpenMeter: (film) {
            Navigator.of(context).push(
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
  double? _ev;
  double _calibration = 0.0;

  /// RGB / calibration row; collapsed unless the user expands it.
  bool _meterDetailsOpen = false;

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

  /// Last factor the user set by hand. The opposite is what we solve for.
  LastEdited _lastEdited = LastEdited.aperture;
  /// Starts from the loaded film; editable only on this page.
  late int _iso = widget.film.iso;
  double _aperture = 2.8;
  double _shutter = 1 / 125;

  /// Focal-length viewfinder simulation, limited by the loaded film's roll size.
  late FilmFormat _simFormat = widget.film.frameFormat;
  late double _simFocalMm = _simFormat.defaultFocalMm;
  LensInfo? _lensInfo;

  List<FilmFormat> get _allowedFormats => widget.film.allowedFormats;

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

  /// Format used for the viewfinder window / phone FOV crop.
  ///
  /// 645 is shown inside a 6×6 feed with an FOV gate overlay.
  FilmFormat get _viewfinderFormat =>
      _simFormat == FilmFormat.sixFourFive
          ? FilmFormat.sixBySix
          : _simFormat;

  /// Centre-crop fraction for the current format simulation.
  double get _simCrop {
    final lens = _lensInfo;
    if (lens == null || !lens.isUsable) return 1.0;
    return lens.cropForFormat(_viewfinderFormat, _simFocalMm, 1.0);
  }

  bool get _simLimited => _simCrop >= 0.999;

  /// Physical gate of [_simFormat] inside [_viewfinderFormat], when nested.
  ///
  /// 645 uses the full 6×6 width with a shorter height (645 aspect), so the
  /// orange FOV border matches the square feed width.
  ({double width, double height})? get _fovGateFractions {
    if (_simFormat == FilmFormat.sixFourFive &&
        _viewfinderFormat == FilmFormat.sixBySix) {
      return (
        width: 1.0,
        height: FilmFormat.sixFourFive.heightMm / FilmFormat.sixFourFive.widthMm,
      );
    }
    if (_simFormat == _viewfinderFormat) return null;
    return _simFormat.fractionsInside(_viewfinderFormat);
  }

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
    final iso = _iso;
    final filmId = widget.film.id;
    final filmName = widget.film.name;
    final formatLabel = _simFormat.label;
    final focalMm = _simFocalMm;
    final ev = _ev;
    final cropFraction = _simCrop;
    final cropAspectRatio = _viewfinderFormat.aspectRatio;
    final gate = _fovGateFractions;

    setState(() => _saving = true);
    late final Uint8List jpeg;
    try {
      jpeg = await _captureStillBytes(ctrl);
    } catch (e) {
      if (mounted) _toast('Could not capture: $e');
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      } else {
        _saving = false;
      }
    }

    if (!mounted) return;
    _toast('Saving to album…');
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
        insetWidthFrac: gate?.width,
        insetHeightFrac: gate?.height,
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
      if (mounted) _toast('Saved to album');
    } catch (e) {
      if (mounted) _toast('Could not save: $e');
    } finally {
      AlbumShotStore.endBackgroundSave();
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
          iso: _iso,
        );
        return ExposureMath.formatShutter(ExposureMath.snapShutter(t));
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
      final crop = _simCrop;
      if (crop < 1.0) {
        final mapped =
            FilmOptics.mapViewfinderToPreview(spot.dx, spot.dy, crop);
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

  Future<void> _onFocalSliderChanged(double index) async {
    final lenses = _simFormat.standardLensesMm;
    if (lenses.isEmpty) return;
    final i = index.round().clamp(0, lenses.length - 1);
    setState(() => _simFocalMm = lenses[i]);
  }

  // -------------------------------------------------------------- calculator

  String get _displayedShutter {
    if (!_solvingShutter) return ExposureMath.formatShutter(_shutter);
    final ev = _ev;
    if (ev == null) return '—';
    final exact =
        ExposureMath.shutterFromEv(ev100: ev, aperture: _aperture, iso: _iso);
    return ExposureMath.formatShutter(ExposureMath.snapShutter(exact));
  }

  String get _displayedAperture {
    if (!_solvingAperture) return ExposureMath.formatAperture(_aperture);
    final ev = _ev;
    if (ev == null) return '—';
    final exact = ExposureMath.apertureFromEv(
      ev100: ev,
      shutterSeconds: _shutter,
      iso: _iso,
    );
    return ExposureMath.formatAperture(ExposureMath.snapAperture(exact));
  }

  /// Solved shutter or aperture at a given exposure-compensation stop.
  ///
  /// +EC means more exposure, so the calculator uses EV − EC.
  String _valueAtCompensation(int compensationStops, {bool exact = false}) {
    final ev = _ev;
    if (ev == null) return '—';
    final adjusted = ev - compensationStops;
    if (_solvingShutter) {
      final seconds = ExposureMath.shutterFromEv(
        ev100: adjusted,
        aperture: _aperture,
        iso: _iso,
      );
      return ExposureMath.formatShutter(
        exact ? seconds : ExposureMath.snapShutter(seconds),
      );
    }
    final f = ExposureMath.apertureFromEv(
      ev100: adjusted,
      shutterSeconds: _shutter,
      iso: _iso,
    );
    return ExposureMath.formatAperture(
      exact ? f : ExposureMath.snapAperture(f),
    );
  }

  static String _formatCompensation(int stops) {
    if (stops == 0) return '0';
    return stops > 0 ? '+$stops' : '$stops';
  }

  void _openAlbum() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlbumPage(film: widget.film),
      ),
    );
  }

  void _openFlash() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FlashPage(
          iso: _iso,
          aperture: _aperture,
          ambientEv: _ev,
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
              widget.film.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              '${widget.film.rollFormatLabel}  ·  ISO $_iso',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _pickIso,
            icon: const Icon(Icons.edit_outlined, size: 16, color: _accent),
            label: Text(
              'ISO $_iso',
              style: const TextStyle(
                color: _accent,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
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
        _buildFormatBar(),
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final crop = _simCrop;
              final viewFormat = _viewfinderFormat;
              final gate = _fovGateFractions;
              final fitted = FilmOptics.fitAspect(
                maxWidth: constraints.maxWidth,
                maxHeight: constraints.maxHeight,
                aspect: viewFormat.aspectRatio,
              );
              final viewSize = Size(fitted.width, fitted.height);
              _previewSize = viewSize;

              return Center(
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
                            child: OverflowBox(
                              alignment: Alignment.center,
                              child: FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: ctrl.value.previewSize?.height ??
                                      viewSize.width,
                                  height: ctrl.value.previewSize?.width ??
                                      viewSize.height,
                                  child: CameraPreview(ctrl),
                                ),
                              ),
                            ),
                          ),
                        ),
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _FilmFramePainter(
                              color: _accent,
                              showThirds: true,
                              gateWidthFrac: gate?.width,
                              gateHeightFrac: gate?.height,
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
                          top: 10,
                          left: 10,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _statusChip(),
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
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        _buildShutterBar(),
        _buildFocalSlider(),
      ],
    );
  }

  Widget _buildShutterBar() {
    return Container(
      color: const Color(0xFF0F0F0F),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Expanded(
            child: Text(
              'Tap to meter',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
              ),
            ),
          ),
          _shutterButton(),
          const SizedBox(width: 8),
          _meterButton(),
          const SizedBox(width: 6),
          _albumButton(),
        ],
      ),
    );
  }

  Widget _buildFormatBar() {
    final formats = _allowedFormats;
    // Each roll locks one frame; chip still shows so the gate is obvious.
    return Container(
      height: 34,
      color: const Color(0xFF0F0F0F),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          for (final format in formats) ...[
            _formatChip(format),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _formatChip(FilmFormat format) {
    final selected = _simFormat == format;
    return GestureDetector(
      onTap: () {
        setState(() {
          final switching = _simFormat != format;
          _simFormat = format;
          if (switching) {
            _simFocalMm = format.defaultFocalMm;
            _meterPoint = const Offset(0.5, 0.5);
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              selected ? _accent.withValues(alpha: 0.9) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected ? _accent : Colors.white12,
          ),
        ),
        child: Text(
          format.label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /// Horizontal focal-length dial under the shutter controls.
  Widget _buildFocalSlider() {
    final lenses = _simFormat.standardLensesMm;
    final last = lenses.length - 1;
    var index = lenses.indexWhere((m) => (m - _simFocalMm).abs() < 0.01);
    if (index < 0) index = lenses.indexOf(_simFormat.defaultFocalMm);
    if (index < 0) index = 0;

    return Container(
      color: const Color(0xFF0F0F0F),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${lenses.first.round()}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white54,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                activeTrackColor: _accent,
                inactiveTrackColor: Colors.white12,
                thumbColor: _accent,
                overlayColor: _accent.withValues(alpha: 0.2),
                activeTickMarkColor: _accent,
                inactiveTickMarkColor: Colors.white38,
                tickMarkShape: const RoundSliderTickMarkShape(
                  tickMarkRadius: 2,
                ),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 6.5,
                ),
                overlayShape: const RoundSliderOverlayShape(
                  overlayRadius: 12,
                ),
              ),
              child: Slider(
                value: index.toDouble().clamp(0, last.toDouble()),
                min: 0,
                max: last.toDouble(),
                divisions: last,
                label: '${lenses[index].round()} mm',
                onChanged: _onFocalSliderChanged,
              ),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text(
              '${lenses.last.round()}',
              textAlign: TextAlign.center,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white54,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 58,
            child: Text(
              '${_simFocalMm.round()} mm',
              textAlign: TextAlign.end,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: _accent,
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

  Widget _meterButton() {
    return FilledButton.icon(
      onPressed: (_measuring || _saving) ? null : () => _measure(),
      style: FilledButton.styleFrom(
        backgroundColor: _accent,
        foregroundColor: Colors.black,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: _measuring
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.black,
              ),
            )
          : const Icon(Icons.center_focus_strong, size: 14),
      label: Text(
        _measuring ? 'Metering' : 'Meter',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _albumButton() {
    return IconButton(
      tooltip: 'Album',
      onPressed: (_measuring || _saving) ? null : _openAlbum,
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
    final ev = _ev;
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
                  label: 'EV',
                  value: ev == null ? '—' : ev.toStringAsFixed(1),
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
              const SizedBox(width: 6),
              Expanded(
                child: _pickerTile(
                  label: 'Aperture',
                  value: _displayedAperture,
                  onTap: _pickAperture,
                  emphasize: _solvingAperture,
                ),
              ),
            ],
          ),
          if (_meterDetailsOpen) ...[
            const SizedBox(height: 6),
            if (ev != null)
              Text(
                _evToLabel(ev),
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
    final exactAtZero =
        _ev == null ? null : _valueAtCompensation(0, exact: true);

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
                    value: _valueAtCompensation(comp),
                    exactValue: comp == 0 ? exactAtZero : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _compTick({
    required int compensation,
    required String value,
    String? exactValue,
  }) {
    final isZero = compensation == 0;
    final showExact =
        isZero && exactValue != null && exactValue != '—' && exactValue != value;

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
                    color: _accent.withValues(alpha: 0.75),
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
                  color: isZero ? _accent : Colors.white70,
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
                width: isZero ? 2 : 1.5,
                height: isZero ? 12 : 8,
                color: isZero ? _accent : Colors.white38,
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
            color: isZero ? _accent : Colors.white54,
            height: 1.0,
          ),
        ),
      ],
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
    if (chosen != null) {
      setState(() {
        _aperture = chosen;
        _lastEdited = LastEdited.aperture;
      });
    }
  }

  Future<void> _pickShutter() async {
    final chosen = await _showWheelPicker<double>(
      title: 'Shutter speed',
      items: ExposureMath.standardShutters,
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

  /// Optional FOV gate inside the viewfinder (e.g. 645 inside 6×6).
  final double? gateWidthFrac;
  final double? gateHeightFrac;

  _FilmFramePainter({
    required this.color,
    this.showThirds = true,
    this.gateWidthFrac,
    this.gateHeightFrac,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Offset.zero & size;
    final hasGate = gateWidthFrac != null &&
        gateHeightFrac != null &&
        (gateWidthFrac! < 0.999 || gateHeightFrac! < 0.999);

    late final Rect frame;
    if (hasGate) {
      final gw = size.width * gateWidthFrac!.clamp(0.05, 1.0);
      final gh = size.height * gateHeightFrac!.clamp(0.05, 1.0);
      frame = Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: gw,
        height: gh,
      );

      // Dim area outside the FOV gate.
      final dim = Path()
        ..addRect(outer)
        ..addRect(frame)
        ..fillType = PathFillType.evenOdd;
      canvas.drawPath(
        dim,
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      );

      // Quiet outer square edge.
      canvas.drawRect(
        outer.deflate(1),
        Paint()
          ..color = Colors.white24
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );

      // Highlighted FOV border.
      canvas.drawRect(
        frame.deflate(0.5),
        Paint()
          ..color = color.withValues(alpha: 0.95)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke,
      );
    } else {
      frame = outer.deflate(1);
      canvas.drawRect(
        frame,
        Paint()
          ..color = color.withValues(alpha: 0.85)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }

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
      gateWidthFrac != old.gateWidthFrac ||
      gateHeightFrac != old.gateHeightFrac;
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
