import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final rearCamera = cameras.firstWhere(
    (c) => c.lensDirection == CameraLensDirection.back,
    orElse: () => cameras.first,
  );
  runApp(LightMeterApp(camera: rearCamera));
}

class LightMeterApp extends StatelessWidget {
  final CameraDescription camera;
  const LightMeterApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '测光仪',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
          brightness: Brightness.dark,
        ),
      ),
      home: LightMeterPage(camera: camera),
    );
  }
}

// ---- Page ----
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

  // Metering point in normalized coordinates (0..1)
  Offset _meterPoint = const Offset(0.5, 0.5);

  // Latest EV reading
  double _evValue = 0.0;

  // Latest RGB values at metering point
  int _r = 0, _g = 0, _b = 0;

  // Brightness info
  String _brightnessLabel = '--';

  // Guard to avoid concurrent frame processing
  bool _isProcessing = false;

  // ---- Zoom ----
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;

  // Used to measure the preview widget's rendered size
  final GlobalKey _previewKey = GlobalKey();

  // log(2)
  static const double _ln2 = 0.6931471805599453;

  // Calibration constant – may need per-device tuning
  static const double _calibrationK = 1200.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _startCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      ctrl.stopImageStream();
    } else if (state == AppLifecycleState.resumed) {
      ctrl.startImageStream(_onFrame);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.stopImageStream();
    _controller?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
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

      // Fetch zoom range
      _minZoom = await _controller!.getMinZoomLevel();
      _maxZoom = await _controller!.getMaxZoomLevel();
      _currentZoom = _minZoom;

      await _controller!.startImageStream(_onFrame);
      setState(() => _isInitialized = true);
    } catch (e) {
      setState(() => _errorMsg = '相机启动失败: $e');
    }
  }

  // ------------ frame callback ------------
  void _onFrame(CameraImage image) {
    if (_isProcessing || !mounted) return;
    _isProcessing = true;

    try {
      final result = _evaluatePixel(image, _meterPoint);
      setState(() {
        _evValue = result.ev;
        _r = result.r;
        _g = result.g;
        _b = result.b;
        _brightnessLabel = result.label;
      });
    } finally {
      _isProcessing = false;
    }
  }

  // ------------ EV computation ------------
  _PixelResult _evaluatePixel(CameraImage image, Offset normPt) {
    final int px =
        (normPt.dx * (image.width - 1)).round().clamp(0, image.width - 1);
    final int py =
        (normPt.dy * (image.height - 1)).round().clamp(0, image.height - 1);

    double r, g, b;

    final fmt = image.format.group;
    if (fmt == ImageFormatGroup.yuv420) {
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];

      final yIdx = py * yPlane.bytesPerRow + px;
      final uvRow = py ~/ 2;
      final uvCol = px ~/ 2;
      final uIdx = uvRow * uPlane.bytesPerRow + uvCol;
      final vIdx = uvRow * vPlane.bytesPerRow + uvCol;

      final double y = (yPlane.bytes[yIdx] & 0xFF).toDouble();
      final double u = (uPlane.bytes[uIdx] & 0xFF).toDouble();
      final double v = (vPlane.bytes[vIdx] & 0xFF).toDouble();

      r = (y + 1.402 * (v - 128)).clamp(0, 255);
      g = (y - 0.344136 * (u - 128) - 0.714136 * (v - 128)).clamp(0, 255);
      b = (y + 1.772 * (u - 128)).clamp(0, 255);
    } else if (fmt == ImageFormatGroup.bgra8888) {
      // BGRA8888 : B G R A interleaved
      final plane = image.planes[0];
      final idx = py * plane.bytesPerRow + px * 4;
      b = (plane.bytes[idx] & 0xFF).toDouble();
      g = (plane.bytes[idx + 1] & 0xFF).toDouble();
      r = (plane.bytes[idx + 2] & 0xFF).toDouble();
    } else {
      return const _PixelResult(ev: 0, r: 0, g: 0, b: 0, label: '?');
    }

    // Relative luminance (ITU-R BT.709)
    final double lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;

    // EV calculation – avoid log(0)
    final double ev = lum < 0.001
        ? -6.0
        : (log(lum * _calibrationK) / _ln2);

    final String label = _evToLabel(ev);

    return _PixelResult(
      ev: double.parse(ev.toStringAsFixed(1)),
      r: r.round(),
      g: g.round(),
      b: b.round(),
      label: label,
    );
  }

  String _evToLabel(double ev) {
    if (ev < 2) return '极暗';
    if (ev < 4) return '很暗';
    if (ev < 6) return '较暗';
    if (ev < 8) return '普通室内';
    if (ev < 10) return '明亮室内';
    if (ev < 12) return '阴天户外';
    if (ev < 14) return '薄云';
    return '晴天下';
  }

  // ------------ tap handler ------------
  void _onTapUp(TapUpDetails details) {
    final RenderBox? box =
        _previewKey.currentContext?.findRenderObject() as RenderBox?;
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
    });
  }

  // ------------ slider zoom ------------
  void _onZoomSliderChanged(double value) {
    _currentZoom = value;
    _controller?.setZoomLevel(_currentZoom);
    setState(() {});
  }

  // ------------ UI ------------
  Widget _buildVerticalZoomSlider() {
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        border: const Border(right: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Max label
          GestureDetector(
            onTap: () => _onZoomSliderChanged(_maxZoom),
            child: Text(
              '${_maxZoom.toStringAsFixed(0)}×',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
          const SizedBox(height: 6),
          // Vertical slider
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: Colors.amber,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.amber,
                  overlayColor: Colors.amber.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: _currentZoom,
                  min: _minZoom,
                  max: _maxZoom,
                  onChanged: _onZoomSliderChanged,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Min label
          GestureDetector(
            onTap: () => _onZoomSliderChanged(_minZoom),
            child: const Text(
              '1×',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
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
              Text(_errorMsg,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _errorMsg = '';
                    _isInitialized = false;
                  });
                  _startCamera();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
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
          CircularProgressIndicator(color: Colors.amber),
          SizedBox(height: 16),
          Text('正在启动相机…', style: TextStyle(color: Colors.white70, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final ctrl = _controller!;

    return Column(
      children: [
        // ---- Camera preview area (takes most of the screen) ----
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              return Row(
                children: [
                  // ---- Left side vertical zoom slider ----
                  if (_maxZoom > _minZoom) _buildVerticalZoomSlider(),

                  // ---- Preview ----
                  Expanded(
                    child: SizedBox(
                      key: _previewKey,
                      width: double.infinity,
                      height: double.infinity,
                      child: GestureDetector(
                        onTapUp: _onTapUp,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Camera preview
                            ClipRect(
                              child: FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: constraints.maxWidth,
                                  height: constraints.maxHeight,
                                  child: CameraPreview(ctrl),
                                ),
                              ),
                            ),

                            // ---- Crosshair at meter point ----
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _CrosshairPainter(
                                  point: _meterPoint,
                                  color: Colors.amber,
                                ),
                              ),
                            ),

                            // ---- Zoom indicator overlay (top-right) ----
                            Positioned(
                              top: 12,
                              right: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${_currentZoom.toStringAsFixed(1)}×',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),

        // ---- Bottom info panel ----
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            border: const Border(top: BorderSide(color: Colors.white12)),
          ),
          child: Column(
            children: [
              // EV big number
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text('EV ',
                      style: TextStyle(
                          fontSize: 22,
                          color: Colors.white54,
                          fontWeight: FontWeight.w300)),
                  Text(
                    _evValue.toStringAsFixed(1),
                    style: const TextStyle(
                        fontSize: 48,
                        color: Colors.amber,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Brightness label
              Text(
                _brightnessLabel,
                style: const TextStyle(
                    fontSize: 14, color: Colors.white54, letterSpacing: 1),
              ),
              const SizedBox(height: 10),
              // RGB chip
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Color.fromARGB(255, _r, _g, _b),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  'R:$_r  G:$_g  B:$_b',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: (_r + _g + _b) / 3 > 128
                        ? Colors.black87
                        : Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Hint
              const Text(
                '点击画面任意位置选取测光点',
                style: TextStyle(fontSize: 12, color: Colors.white30),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Simple data class ----
class _PixelResult {
  final double ev;
  final int r, g, b;
  final String label;
  const _PixelResult({
    required this.ev,
    required this.r,
    required this.g,
    required this.b,
    required this.label,
  });
}

// ---- Crosshair painter ----
class _CrosshairPainter extends CustomPainter {
  final Offset point; // normalized (0..1)
  final Color color;

  _CrosshairPainter({required this.point, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = point.dx * size.width;
    final cy = point.dy * size.height;

    final paint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const double crossLen = 24;
    const double gap = 6;

    // Draw 4 lines forming a broken cross
    canvas.drawLine(Offset(cx, cy - gap), Offset(cx, cy - crossLen), paint);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, cy + crossLen), paint);
    canvas.drawLine(Offset(cx - gap, cy), Offset(cx - crossLen, cy), paint);
    canvas.drawLine(Offset(cx + gap, cy), Offset(cx + crossLen, cy), paint);

    // Circle around
    final circlePaint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(cx, cy), 20, circlePaint);
  }

  @override
  bool shouldRepaint(covariant _CrosshairPainter oldDelegate) =>
      point != oldDelegate.point || color != oldDelegate.color;
}
