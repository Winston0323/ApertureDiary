import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand_chips.dart';
import 'gear.dart';
import 'mount_picker.dart';

const Color _accent = Color(0xFFFFB300);

/// Form to add or edit a lens. Saves via [GearStore] and pops the lens.
class AddLensPage extends StatefulWidget {
  const AddLensPage({
    super.key,
    this.existing,
    this.preselectedCameraId,
  });

  final UserLens? existing;

  /// When adding from a camera detail, pre-link this body.
  final String? preselectedCameraId;

  @override
  State<AddLensPage> createState() => _AddLensPageState();
}

class _AddLensPageState extends State<AddLensPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _minFocalController;
  late final TextEditingController _maxFocalController;
  late final TextEditingController _maxApertureController;
  late final TextEditingController _minApertureController;
  late final TextEditingController _notesController;

  late String _brand;
  late bool _isZoom;
  String? _mount;
  List<UserCamera> _cameras = [];
  late Set<String> _linkedCameraIds;
  bool _loadingCameras = true;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _brand = e?.brand ?? 'Hasselblad';
    _isZoom = e?.isZoom ?? false;
    _mount = e?.mount;
    _linkedCameraIds = {
      ...?e?.cameraIds,
      if (widget.preselectedCameraId != null) widget.preselectedCameraId!,
    };
    _nameController = TextEditingController(text: e?.name ?? '');
    _minFocalController = TextEditingController(
      text: e != null ? _fmtNum(e.minFocalMm) : '',
    );
    _maxFocalController = TextEditingController(
      text: e?.maxFocalMm != null ? _fmtNum(e!.maxFocalMm!) : '',
    );
    _maxApertureController = TextEditingController(
      text: e?.maxAperture != null ? _fmtNum(e!.maxAperture!) : '',
    );
    _minApertureController = TextEditingController(
      text: e?.minAperture != null ? _fmtNum(e!.minAperture!) : '',
    );
    _notesController = TextEditingController(text: e?.notes ?? '');
    _loadCameras();
  }

  Future<void> _loadCameras() async {
    final cameras = await GearStore.loadCameras();
    if (!mounted) return;

    // From a camera card: inherit that body's mount.
    String? detectedMount = _mount;
    if (detectedMount == null || detectedMount.trim().isEmpty) {
      final seedId = widget.preselectedCameraId;
      if (seedId != null) {
        for (final cam in cameras) {
          if (cam.id == seedId) {
            final m = cam.mount?.trim();
            if (m != null && m.isNotEmpty) detectedMount = m;
            break;
          }
        }
      }
    }

    // Or from already-linked bodies if they agree on a mount.
    detectedMount ??= _detectMountFromIds(cameras, _linkedCameraIds);

    final mount = detectedMount;
    final linked = <String>{..._linkedCameraIds};
    if (mount != null && mount.isNotEmpty) {
      for (final cam in cameras) {
        if (cam.interchangeableLenses && sameLensMount(cam.mount, mount)) {
          linked.add(cam.id);
        }
      }
    }

    setState(() {
      _cameras = cameras.where((c) => c.interchangeableLenses).toList();
      _mount = mount;
      _linkedCameraIds = linked;
      _loadingCameras = false;
    });
  }

  String? _detectMountFromIds(List<UserCamera> cameras, Set<String> ids) {
    String? found;
    for (final cam in cameras) {
      if (!ids.contains(cam.id)) continue;
      final m = cam.mount?.trim();
      if (m == null || m.isEmpty) continue;
      if (found == null) {
        found = m;
      } else if (!sameLensMount(found, m)) {
        return found; // keep first if bodies disagree
      }
    }
    return found;
  }

  void _applyMount(String? mount) {
    final next = mount?.trim();
    final normalized = (next == null || next.isEmpty) ? null : next;
    final linked = <String>{};
    if (normalized != null) {
      for (final cam in _cameras) {
        if (sameLensMount(cam.mount, normalized)) {
          linked.add(cam.id);
        }
      }
    }
    setState(() {
      _mount = normalized;
      _linkedCameraIds = linked;
    });
  }

  Future<void> _pickMount() async {
    final chosen = await showMountPicker(context, current: _mount);
    if (chosen == null || !mounted) return;
    if (chosen == kClearMount) {
      _applyMount(null);
    } else {
      _applyMount(chosen);
    }
  }

  void _toggleCamera(UserCamera cam) {
    final selected = _linkedCameraIds.contains(cam.id);
    setState(() {
      if (selected) {
        _linkedCameraIds.remove(cam.id);
      } else {
        _linkedCameraIds.add(cam.id);
        final bodyMount = cam.mount?.trim();
        if (bodyMount != null && bodyMount.isNotEmpty) {
          // Selecting a body detects mount and pulls in other same-mount bodies.
          _mount = bodyMount;
          for (final other in _cameras) {
            if (sameLensMount(other.mount, bodyMount)) {
              _linkedCameraIds.add(other.id);
            }
          }
        }
      }
    });
  }

  List<UserCamera> get _compatibleCameras {
    final mount = _mount?.trim();
    if (mount == null || mount.isEmpty) return _cameras;
    return _cameras
        .where(
          (c) =>
              sameLensMount(c.mount, mount) ||
              _linkedCameraIds.contains(c.id) ||
              c.mount == null ||
              c.mount!.trim().isEmpty,
        )
        .toList();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _minFocalController.dispose();
    _maxFocalController.dispose();
    _maxApertureController.dispose();
    _minApertureController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  static String _fmtNum(double v) {
    if (v == v.roundToDouble()) return '${v.round()}';
    return v.toStringAsFixed(1);
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a lens name')),
      );
      return;
    }

    final minFocal = double.tryParse(_minFocalController.text.trim());
    if (minFocal == null || minFocal <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid focal length')),
      );
      return;
    }

    double? maxFocal;
    if (_isZoom) {
      maxFocal = double.tryParse(_maxFocalController.text.trim());
      if (maxFocal == null || maxFocal <= minFocal) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a longer zoom max focal')),
        );
        return;
      }
    }

    double? maxAperture;
    final maxRaw = _maxApertureController.text.trim();
    if (maxRaw.isNotEmpty) {
      maxAperture = double.tryParse(maxRaw);
      if (maxAperture == null || maxAperture <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid max aperture')),
        );
        return;
      }
    }

    double? minAperture;
    final minRaw = _minApertureController.text.trim();
    if (minRaw.isNotEmpty) {
      minAperture = double.tryParse(minRaw);
      if (minAperture == null || minAperture <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid smallest aperture')),
        );
        return;
      }
    }

    if (maxAperture != null &&
        minAperture != null &&
        minAperture < maxAperture) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Smallest aperture must be ≥ max aperture'),
        ),
      );
      return;
    }

    final notes = _notesController.text.trim();
    final existing = widget.existing;

    final lens = UserLens(
      id: existing?.id ?? 'lens-${DateTime.now().microsecondsSinceEpoch}',
      brand: _brand,
      name: name,
      minFocalMm: minFocal,
      maxFocalMm: maxFocal,
      maxAperture: maxAperture,
      minAperture: minAperture,
      mount: _mount,
      cameraIds: _linkedCameraIds.toList(),
      notes: notes.isEmpty ? null : notes,
      addedAt: existing?.addedAt ?? DateTime.now(),
    );

    await GearStore.upsertLens(lens);
    if (!mounted) return;
    Navigator.of(context).pop(lens);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          _editing ? 'Edit lens' : 'Add lens',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            _label('Brand'),
            const SizedBox(height: 8),
            GearBrandChips(
              selected: _brand,
              onChanged: (brand) => setState(() => _brand = brand),
            ),
            const SizedBox(height: 20),
            _label('Lens name'),
            const SizedBox(height: 8),
            _textField(
              controller: _nameController,
              hint: 'e.g. Planar 80',
              autofocus: !_editing,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 20),
            _label('Focal'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _segChip(
                    label: 'Prime',
                    selected: !_isZoom,
                    onTap: () => setState(() => _isZoom = false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _segChip(
                    label: 'Zoom',
                    selected: _isZoom,
                    onTap: () => setState(() => _isZoom = true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_isZoom)
              Row(
                children: [
                  Expanded(
                    child: _textField(
                      controller: _minFocalController,
                      hint: 'Min mm',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _textField(
                      controller: _maxFocalController,
                      hint: 'Max mm',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                ],
              )
            else
              _textField(
                controller: _minFocalController,
                hint: 'Focal mm',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
              ),
            const SizedBox(height: 20),
            _label('Aperture (optional)'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _textField(
                    controller: _maxApertureController,
                    hint: 'Max f/ e.g. 2.8',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _textField(
                    controller: _minApertureController,
                    hint: 'Min f/ e.g. 22',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _label('Mount (optional)'),
            const SizedBox(height: 8),
            _mountButton(),
            const SizedBox(height: 20),
            _label(
              _mount != null && _mount!.trim().isNotEmpty
                  ? 'Bodies with mount ${_mount!.trim()}'
                  : 'Fits cameras (optional)',
            ),
            const SizedBox(height: 8),
            if (_loadingCameras)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: CircularProgressIndicator(color: _accent),
                ),
              )
            else if (_cameras.isEmpty)
              const Text(
                'Add an interchangeable camera first to link lenses.',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              )
            else if (_compatibleCameras.isEmpty)
              Text(
                'No camera bodies with mount ${_mount!.trim()} yet.',
                style: const TextStyle(color: Colors.white38, fontSize: 13),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final cam in _compatibleCameras) _cameraChip(cam),
                ],
              ),
            const SizedBox(height: 20),
            _label('Notes (optional)'),
            const SizedBox(height: 8),
            _textField(
              controller: _notesController,
              hint: 'Serial, condition…',
              maxLines: 3,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  _editing ? 'Save lens' : 'Add lens',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.white70,
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String hint,
    bool autofocus = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      textCapitalization: TextCapitalization.words,
      inputFormatters: [
        if (maxLines == 1) LengthLimitingTextInputFormatter(48),
      ],
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF1A1A1A),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _accent),
        ),
      ),
    );
  }

  Widget _mountButton() {
    final hasMount = _mount != null && _mount!.isNotEmpty;
    return GestureDetector(
      onTap: _pickMount,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                hasMount ? _mount! : 'Select mount',
                style: TextStyle(
                  color: hasMount ? Colors.white : Colors.white38,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            const Icon(Icons.expand_more, color: Colors.white38, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _segChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? _accent : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? _accent : Colors.white12,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _cameraChip(UserCamera cam) {
    final selected = _linkedCameraIds.contains(cam.id);
    final mountLabel = cam.mount?.trim();
    return GestureDetector(
      onTap: () => _toggleCamera(cam),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _accent : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? _accent : Colors.white12,
          ),
        ),
        child: Text(
          mountLabel == null || mountLabel.isEmpty
              ? '${cam.brand} ${cam.name}'
              : '${cam.brand} ${cam.name} · $mountLabel',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }
}
