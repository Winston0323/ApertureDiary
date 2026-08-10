import 'package:flutter/material.dart';

import 'add_camera_page.dart';
import 'film_format.dart';
import 'film_stock.dart';
import 'gear.dart';

const Color _accent = Color(0xFFFFB300);

/// Result of [showCameraPicker]. [camera] is null when the user chose "No camera".
class CameraPick {
  const CameraPick(this.camera);
  const CameraPick.none() : camera = null;

  final UserCamera? camera;

  bool get hasCamera => camera != null;
}

/// Whether [camera] can shoot film of [type] (135 vs 120).
bool cameraFitsFilmType(UserCamera camera, FilmType type) {
  return camera.filmType == type;
}

/// Whether [camera] can shoot [type] / [frameFormat].
bool cameraFitsFilm(
  UserCamera camera, {
  required FilmType type,
  required FilmFormat frameFormat,
}) {
  if (!cameraFitsFilmType(camera, type)) return false;
  if (type == FilmType.thirtyFive) return true;
  if (type == FilmType.instax) return camera.format == frameFormat;
  if (camera.changeableBack) return true;
  return camera.format == frameFormat;
}

String cameraDisplayName(UserCamera camera) => '${camera.brand} ${camera.name}';

/// Ask which body this roll is loaded in.
///
/// When [type] is null, every saved camera is listed (camera-first flow).
/// Returns null if dismissed; [CameraPick.none] if skipped; otherwise a camera.
Future<CameraPick?> showCameraPicker(
  BuildContext context, {
  String title = 'Which camera?',
  String? subtitle,
  FilmType? type,
  FilmFormat? frameFormat,
  String? selectedCameraId,
  bool allowNone = true,
}) {
  return showModalBottomSheet<CameraPick>(
    context: context,
    backgroundColor: const Color(0xFF161616),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _CameraPickerSheet(
      title: title,
      subtitle: subtitle,
      type: type,
      frameFormat: frameFormat,
      selectedCameraId: selectedCameraId,
      allowNone: allowNone,
    ),
  );
}

class _CameraPickerSheet extends StatefulWidget {
  const _CameraPickerSheet({
    required this.title,
    this.subtitle,
    this.type,
    this.frameFormat,
    this.selectedCameraId,
    this.allowNone = true,
  });

  final String title;
  final String? subtitle;
  final FilmType? type;
  final FilmFormat? frameFormat;
  final String? selectedCameraId;
  final bool allowNone;

  @override
  State<_CameraPickerSheet> createState() => _CameraPickerSheetState();
}

class _CameraPickerSheetState extends State<_CameraPickerSheet> {
  List<UserCamera> _cameras = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await GearStore.loadCameras();
    final matching = widget.type == null
        ? all
        : all.where((c) => cameraFitsFilmType(c, widget.type!)).toList();
    if (!mounted) return;
    setState(() {
      _cameras = matching;
      _loading = false;
    });
  }

  Future<void> _addCamera() async {
    final created = await Navigator.of(context).push<UserCamera>(
      MaterialPageRoute(builder: (_) => const AddCameraPage()),
    );
    if (created == null || !mounted) return;
    if (widget.type == null || cameraFitsFilmType(created, widget.type!)) {
      Navigator.of(context).pop(CameraPick(created));
      return;
    }
    await _load();
  }

  String get _subtitle {
    if (widget.subtitle != null) return widget.subtitle!;
    if (widget.type == null) return 'Then pick the film for this body';
    if (widget.type == FilmType.thirtyFive) return '135';
    if (widget.type == FilmType.instax) {
      final f = widget.frameFormat;
      return f == null ? 'Instax' : 'Instax ${f.label}';
    }
    if (widget.frameFormat != null) {
      return '120 ${widget.frameFormat!.label}';
    }
    return '120';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _subtitle,
              style: const TextStyle(fontSize: 13, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: CircularProgressIndicator(color: _accent),
                ),
              )
            else ...[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                ),
                child: _cameras.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'No cameras yet. Add a body first.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _cameras.length,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          color: Colors.white10,
                        ),
                        itemBuilder: (context, index) {
                          final cam = _cameras[index];
                          final selected = widget.selectedCameraId == cam.id;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              cameraDisplayName(cam),
                              style: TextStyle(
                                color: selected ? _accent : Colors.white,
                                fontWeight: selected
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                            subtitle: Text(
                              cam.summary,
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
                            onTap: () =>
                                Navigator.of(context).pop(CameraPick(cam)),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _addCamera,
                  icon: const Icon(Icons.add, color: _accent),
                  label: const Text(
                    'Add camera',
                    style: TextStyle(
                      color: _accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: _accent),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              if (widget.allowNone) ...[
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(const CameraPick.none()),
                  child: const Text(
                    'No camera',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Attach a camera pick onto a [FilmStock] (or clear it).
///
/// Fixed-frame bodies also set [FilmStock.frameFormat] to match the body.
FilmStock filmWithCamera(FilmStock film, CameraPick pick) {
  final cam = pick.camera;
  if (cam == null) {
    return film.copyWith(clearCamera: true);
  }
  final nextFormat = (!cam.changeableBack && cam.filmType == film.type)
      ? cam.format
      : film.frameFormat;
  return film.copyWith(
    cameraId: cam.id,
    cameraLabel: cameraDisplayName(cam),
    frameFormat: nextFormat,
  );
}
