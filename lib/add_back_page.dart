import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand_chips.dart';
import 'film_format.dart';
import 'gear.dart';

const Color _accent = Color(0xFFFFB300);

/// Form to add or edit a film back. Saves via [GearStore] and pops the back.
class AddBackPage extends StatefulWidget {
  const AddBackPage({
    super.key,
    this.existing,
    this.preselectedCameraId,
  });

  final UserBack? existing;

  /// When adding from a camera card, pre-link this body.
  final String? preselectedCameraId;

  @override
  State<AddBackPage> createState() => _AddBackPageState();
}

class _AddBackPageState extends State<AddBackPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _notesController;

  late String _brand;
  late FilmFormat _format;
  List<UserCamera> _cameras = [];
  late Set<String> _linkedCameraIds;
  bool _loadingCameras = true;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _brand = e?.brand ?? 'Hasselblad';
    _format = e?.format ?? FilmFormat.sixBySix;
    _linkedCameraIds = {
      ...?e?.cameraIds,
      if (widget.preselectedCameraId != null) widget.preselectedCameraId!,
    };
    _nameController = TextEditingController(text: e?.name ?? '');
    _notesController = TextEditingController(text: e?.notes ?? '');
    _loadCameras();
  }

  Future<void> _loadCameras() async {
    final cameras = await GearStore.loadCameras();
    if (!mounted) return;

    final changeable = cameras.where((c) => c.changeableBack).toList();

    // Prefer brand from the preselected body.
    var brand = _brand;
    final seedId = widget.preselectedCameraId;
    if (!_editing && seedId != null) {
      for (final cam in changeable) {
        if (cam.id == seedId) {
          brand = cam.brand;
          break;
        }
      }
    }

    // Auto-link other changeable bodies of the same brand when seeded.
    final linked = <String>{..._linkedCameraIds};
    if (!_editing && seedId != null) {
      for (final cam in changeable) {
        if (cam.brand == brand) linked.add(cam.id);
      }
    }

    setState(() {
      _cameras = changeable;
      _brand = brand;
      _linkedCameraIds = linked;
      _loadingCameras = false;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a back name')),
      );
      return;
    }

    final notes = _notesController.text.trim();
    final existing = widget.existing;

    final back = UserBack(
      id: existing?.id ?? 'back-${DateTime.now().microsecondsSinceEpoch}',
      brand: _brand,
      name: name,
      format: _format,
      cameraIds: _linkedCameraIds.toList(),
      notes: notes.isEmpty ? null : notes,
      addedAt: existing?.addedAt ?? DateTime.now(),
    );

    await GearStore.upsertBack(back);
    if (!mounted) return;
    Navigator.of(context).pop(back);
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
          _editing ? 'Edit back' : 'Add back',
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
            _label('Back name'),
            const SizedBox(height: 8),
            _textField(
              controller: _nameController,
              hint: 'e.g. A12, A16',
              autofocus: !_editing,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 20),
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
                    onTap: () => setState(() => _format = FilmFormat.sixBySix),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _label('Fits cameras'),
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
                'Add a camera with a changeable back first.',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final cam in _cameras) _cameraChip(cam),
                ],
              ),
            const SizedBox(height: 20),
            _label('Notes (optional)'),
            const SizedBox(height: 8),
            _textField(
              controller: _notesController,
              hint: 'Serial, film type loaded…',
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
                  _editing ? 'Save back' : 'Add back',
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
    TextInputAction? textInputAction,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      maxLines: maxLines,
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
    return GestureDetector(
      onTap: () {
        setState(() {
          if (selected) {
            _linkedCameraIds.remove(cam.id);
          } else {
            _linkedCameraIds.add(cam.id);
          }
        });
      },
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
          '${cam.brand} ${cam.name}',
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
