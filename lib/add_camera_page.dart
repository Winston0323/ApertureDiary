import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand_chips.dart';
import 'exposure.dart';
import 'film_format.dart';
import 'film_stock.dart';
import 'gear.dart';
import 'mount_picker.dart';
import 'wheel_dial.dart';

const Color _accent = Color(0xFFFFB300);

/// Form to add or edit a film camera. Saves via [GearStore] and pops the camera.
class AddCameraPage extends StatefulWidget {
  const AddCameraPage({super.key, this.existing});

  final UserCamera? existing;

  @override
  State<AddCameraPage> createState() => _AddCameraPageState();
}

class _AddCameraPageState extends State<AddCameraPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _focalController;
  late final TextEditingController _maxApertureController;
  late final TextEditingController _minApertureController;
  late final TextEditingController _notesController;

  late String _brand;
  late bool _interchangeable;
  late bool _changeableBack;
  late FilmType _filmType;
  late FilmFormat _format;
  String? _mount;
  late double _fastestShutter;
  late double _slowestShutter;
  late bool _hasBulb;
  List<UserLens> _lenses = [];

  bool get _editing => widget.existing != null;

  List<UserLens> get _matchingLenses {
    final mount = _mount?.trim();
    if (mount == null || mount.isEmpty) return const [];
    return _lenses.where((l) => sameLensMount(l.mount, mount)).toList();
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _brand = e?.brand ?? 'Hasselblad';
    _interchangeable = e?.interchangeableLenses ?? true;
    _changeableBack = e?.changeableBack ?? false;
    _format = e?.format ?? FilmFormat.sixBySix;
    _filmType = e?.filmType ?? FilmType.oneTwenty;
    _mount = e?.mount;
    _fastestShutter = e?.fastestShutter ?? 1 / 500;
    _slowestShutter = e?.slowestShutter ?? 1.0;
    _hasBulb = e?.hasBulb ?? true;
    _nameController = TextEditingController(text: e?.name ?? '');
    _focalController = TextEditingController(
      text: e?.fixedFocalMm != null ? _fmtNum(e!.fixedFocalMm!) : '',
    );
    _maxApertureController = TextEditingController(
      text: e?.fixedMaxAperture != null ? _fmtNum(e!.fixedMaxAperture!) : '',
    );
    _minApertureController = TextEditingController(
      text: e?.fixedMinAperture != null ? _fmtNum(e!.fixedMinAperture!) : '',
    );
    _notesController = TextEditingController(text: e?.notes ?? '');
    _loadLenses();
  }

  Future<void> _pickShutter({required bool fastest}) async {
    final items = ExposureMath.standardShutters;
    final current = fastest ? _fastestShutter : _slowestShutter;
    var initial = items.indexWhere((s) => (s - current).abs() < 1e-12);
    if (initial < 0) {
      initial = items.indexOf(ExposureMath.snapShutter(current));
    }
    if (initial < 0) initial = 0;

    final chosen = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => WheelDialSheet<double>(
        title: fastest ? 'Fastest shutter' : 'Slowest shutter',
        items: items,
        initialIndex: initial,
        labelOf: ExposureMath.formatShutter,
        accent: _accent,
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      if (fastest) {
        _fastestShutter = chosen;
        if (_slowestShutter < _fastestShutter) {
          _slowestShutter = _fastestShutter;
        }
      } else {
        _slowestShutter = chosen;
        if (_fastestShutter > _slowestShutter) {
          _fastestShutter = _slowestShutter;
        }
      }
    });
  }

  void _setFilmType(FilmType type) {
    setState(() {
      _filmType = type;
      if (type == FilmType.thirtyFive) {
        _format = FilmFormat.thirtyFive;
        _changeableBack = false;
      } else if (_format != FilmFormat.sixFourFive &&
          _format != FilmFormat.sixBySix) {
        _format = FilmFormat.sixBySix;
      }
    });
  }

  void _setChangeableBack(bool value) {
    setState(() {
      _changeableBack = value;
      if (value) {
        _filmType = FilmType.oneTwenty;
        // Placeholder until a back is attached; frame size lives on backs.
        if (_format == FilmFormat.thirtyFive) {
          _format = FilmFormat.sixBySix;
        }
      }
    });
  }

  Future<void> _loadLenses() async {
    final lenses = await GearStore.loadLenses();
    if (!mounted) return;
    setState(() => _lenses = lenses);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _focalController.dispose();
    _maxApertureController.dispose();
    _minApertureController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickMount() async {
    final chosen = await showMountPicker(context, current: _mount);
    if (chosen == null || !mounted) return;
    setState(() {
      _mount = chosen == kClearMount ? null : chosen;
    });
  }

  static String _fmtNum(double v) {
    if (v == v.roundToDouble()) return '${v.round()}';
    return v.toStringAsFixed(1);
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a camera name')),
      );
      return;
    }

    double? focal;
    double? maxAperture;
    double? minAperture;
    if (!_interchangeable) {
      final fRaw = _focalController.text.trim();
      final maxRaw = _maxApertureController.text.trim();
      final minRaw = _minApertureController.text.trim();
      if (fRaw.isNotEmpty) {
        focal = double.tryParse(fRaw);
        if (focal == null || focal <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter a valid focal length')),
          );
          return;
        }
      }
      if (maxRaw.isNotEmpty) {
        maxAperture = double.tryParse(maxRaw);
        if (maxAperture == null || maxAperture <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter a valid max aperture')),
          );
          return;
        }
      }
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
    }

    final notes = _notesController.text.trim();
    final existing = widget.existing;

    final camera = UserCamera(
      id: existing?.id ?? 'cam-${DateTime.now().microsecondsSinceEpoch}',
      brand: _brand,
      name: name,
      interchangeableLenses: _interchangeable,
      changeableBack: _filmType == FilmType.oneTwenty && _changeableBack,
      format: _format,
      mount: _interchangeable ? _mount : null,
      fixedFocalMm: _interchangeable ? null : focal,
      fixedMaxAperture: _interchangeable ? null : maxAperture,
      fixedMinAperture: _interchangeable ? null : minAperture,
      fastestShutter: _fastestShutter,
      slowestShutter: _slowestShutter,
      hasBulb: _hasBulb,
      notes: notes.isEmpty ? null : notes,
      addedAt: existing?.addedAt ?? DateTime.now(),
    );

    await GearStore.upsertCamera(camera);
    if (!mounted) return;
    Navigator.of(context).pop(camera);
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
          _editing ? 'Edit camera' : 'Add camera',
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
            _label('Camera name'),
            const SizedBox(height: 8),
            _textField(
              controller: _nameController,
              hint: 'e.g. 500CM',
              autofocus: !_editing,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 20),
            _label('Format'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _segChip(
                    label: FilmType.thirtyFive.label,
                    selected: _filmType == FilmType.thirtyFive,
                    onTap: () => _setFilmType(FilmType.thirtyFive),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _segChip(
                    label: FilmType.oneTwenty.label,
                    selected: _filmType == FilmType.oneTwenty,
                    onTap: () => _setFilmType(FilmType.oneTwenty),
                  ),
                ),
              ],
            ),
            if (_filmType == FilmType.oneTwenty) ...[
              const SizedBox(height: 12),
              _label('Film back'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _segChip(
                      label: 'Fixed frame',
                      selected: !_changeableBack,
                      onTap: () => _setChangeableBack(false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _segChip(
                      label: 'Changeable',
                      selected: _changeableBack,
                      onTap: () => _setChangeableBack(true),
                    ),
                  ),
                ],
              ),
              if (!_changeableBack) ...[
                const SizedBox(height: 12),
                _label('Frame size'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _segChip(
                        label: FilmFormat.sixFourFive.label,
                        selected: _format == FilmFormat.sixFourFive,
                        onTap: () =>
                            setState(() => _format = FilmFormat.sixFourFive),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _segChip(
                        label: FilmFormat.sixBySix.label,
                        selected: _format == FilmFormat.sixBySix,
                        onTap: () =>
                            setState(() => _format = FilmFormat.sixBySix),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 10),
                const Text(
                  'Add 645 and 6×6 backs separately — this body can use both.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ],
            const SizedBox(height: 20),
            _label('Lens type'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _segChip(
                    label: 'Interchangeable',
                    selected: _interchangeable,
                    onTap: () => setState(() => _interchangeable = true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _segChip(
                    label: 'Fixed lens',
                    selected: !_interchangeable,
                    onTap: () => setState(() => _interchangeable = false),
                  ),
                ),
              ],
            ),
            if (_interchangeable) ...[
              const SizedBox(height: 20),
              _label('Mount (optional)'),
              const SizedBox(height: 8),
              _mountButton(),
              if (_mount != null && _mount!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _matchingLenses.isEmpty
                      ? 'No lenses with mount ${_mount!.trim()} yet'
                      : '${_matchingLenses.length} available lens${_matchingLenses.length == 1 ? '' : 'es'} for ${_mount!.trim()}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                if (_matchingLenses.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final lens in _matchingLenses)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Text(
                            '${lens.brand} ${lens.name}  ·  ${lens.summary}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ] else ...[
              const SizedBox(height: 20),
              _label('Fixed lens (optional)'),
              const SizedBox(height: 8),
              _textField(
                controller: _focalController,
                hint: 'Focal mm',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 10),
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
            ],
            const SizedBox(height: 20),
            _label('Shutter range'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _pickerButton(
                    label: ExposureMath.formatShutter(_fastestShutter),
                    hint: 'Fastest',
                    onTap: () => _pickShutter(fastest: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _pickerButton(
                    label: ExposureMath.formatShutter(_slowestShutter),
                    hint: 'Slowest',
                    onTap: () => _pickShutter(fastest: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Bulb (B)',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              subtitle: const Text(
                'Slowest is a reference — with B, speeds longer than 1″ stay available',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              value: _hasBulb,
              activeThumbColor: Colors.black,
              activeTrackColor: _accent,
              onChanged: (v) => setState(() => _hasBulb = v),
            ),
            const SizedBox(height: 12),
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
                  _editing ? 'Save camera' : 'Add camera',
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
    return _pickerButton(
      label: hasMount ? _mount! : 'Select mount',
      hint: '',
      onTap: _pickMount,
      muted: !hasMount,
    );
  }

  Widget _pickerButton({
    required String label,
    required String hint,
    required VoidCallback onTap,
    bool muted = false,
  }) {
    return GestureDetector(
      onTap: onTap,
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hint.isNotEmpty)
                    Text(
                      hint,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    label,
                    style: TextStyle(
                      color: muted ? Colors.white38 : Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ],
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
}
