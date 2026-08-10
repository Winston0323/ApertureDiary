import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_picker.dart';
import 'film_format.dart';
import 'film_stock.dart';

const Color _accent = Color(0xFFFFB300);

/// Bottom sheet to edit a timeline film's name, format, and time.
Future<FilmStock?> showEditFilmSheet(
  BuildContext context, {
  required FilmStock film,
}) {
  return showModalBottomSheet<FilmStock>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF161616),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _EditFilmSheet(film: film),
  );
}

class _EditFilmSheet extends StatefulWidget {
  const _EditFilmSheet({required this.film});

  final FilmStock film;

  @override
  State<_EditFilmSheet> createState() => _EditFilmSheetState();
}

class _EditFilmSheetState extends State<_EditFilmSheet> {
  late final TextEditingController _nameController;
  late FilmType _type;
  late FilmFormat _frameFormat;
  late DateTime _when;
  String? _cameraId;
  String? _cameraLabel;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.film.name);
    _type = widget.film.type;
    _frameFormat = widget.film.frameFormat;
    _when = widget.film.timelineAt.toLocal();
    _cameraId = widget.film.cameraId;
    _cameraLabel = widget.film.cameraLabel;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _accent,
              onPrimary: Colors.black,
              surface: Color(0xFF1A1A1A),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _when = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _when.hour,
        _when.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _accent,
              onPrimary: Colors.black,
              surface: Color(0xFF1A1A1A),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _when = DateTime(
        _when.year,
        _when.month,
        _when.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  Future<void> _pickCamera() async {
    final pick = await showCameraPicker(
      context,
      title: 'Which camera?',
      subtitle: widget.film.name,
      type: _type,
      frameFormat: _frameFormat,
      selectedCameraId: _cameraId,
    );
    if (pick == null || !mounted) return;
    setState(() {
      if (pick.camera == null) {
        _cameraId = null;
        _cameraLabel = null;
      } else {
        _cameraId = pick.camera!.id;
        _cameraLabel = cameraDisplayName(pick.camera!);
      }
    });
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a film name')),
      );
      return;
    }
    Navigator.of(context).pop(
      widget.film.copyWith(
        name: name,
        type: _type,
        frameFormat: _frameFormat,
        addedAt: _when,
        cameraId: _cameraId,
        cameraLabel: _cameraLabel,
        clearCamera: _cameraId == null,
      ),
    );
  }

  String get _dateLabel {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[_when.month - 1]} ${_when.day}, ${_when.year}';
  }

  String get _timeLabel {
    final h = _when.hour.toString().padLeft(2, '0');
    final m = _when.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Edit film',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: _save,
                child: const Text(
                  'Save',
                  style: TextStyle(
                    color: _accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Name',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            textCapitalization: TextCapitalization.words,
            inputFormatters: [LengthLimitingTextInputFormatter(48)],
            decoration: InputDecoration(
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
          ),
          const SizedBox(height: 16),
          const Text(
            'Format',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _typeChip(FilmType.thirtyFive)),
              const SizedBox(width: 10),
              Expanded(child: _typeChip(FilmType.oneTwenty)),
              const SizedBox(width: 10),
              Expanded(child: _typeChip(FilmType.instax)),
            ],
          ),
          if (_type == FilmType.oneTwenty) ...[
            const SizedBox(height: 16),
            const Text(
              'Frame size',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _frameChip(FilmFormat.sixFourFive)),
                const SizedBox(width: 10),
                Expanded(child: _frameChip(FilmFormat.sixBySix)),
              ],
            ),
          ],
          if (_type == FilmType.instax) ...[
            const SizedBox(height: 16),
            const Text(
              'Instax size',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _frameChip(FilmFormat.instaxMini)),
                const SizedBox(width: 10),
                Expanded(child: _frameChip(FilmFormat.instaxSquare)),
              ],
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Camera',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          _pickerButton(
            label: _cameraLabel ?? 'Select camera',
            icon: Icons.camera_alt_outlined,
            onTap: _pickCamera,
            muted: _cameraLabel == null,
          ),
          const SizedBox(height: 16),
          const Text(
            'Time',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _pickerButton(
                  label: _dateLabel,
                  icon: Icons.calendar_today_outlined,
                  onTap: _pickDate,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _pickerButton(
                  label: _timeLabel,
                  icon: Icons.schedule_outlined,
                  onTap: _pickTime,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _typeChip(FilmType type) {
    final selected = _type == type;
    return GestureDetector(
      onTap: () => setState(() {
        _type = type;
        if (type == FilmType.thirtyFive) {
          _frameFormat = FilmFormat.thirtyFive;
        } else if (type == FilmType.instax) {
          if (!_frameFormat.isInstax) {
            _frameFormat = FilmFormat.instaxMini;
          }
        } else if (_frameFormat != FilmFormat.sixFourFive &&
            _frameFormat != FilmFormat.sixBySix) {
          _frameFormat = FilmFormat.sixBySix;
        }
      }),
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              selected ? _accent.withValues(alpha: 0.9) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? _accent : Colors.white12),
        ),
        child: Text(
          type.label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  Widget _frameChip(FilmFormat format) {
    final selected = _frameFormat == format;
    return GestureDetector(
      onTap: () => setState(() => _frameFormat = format),
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              selected ? _accent.withValues(alpha: 0.9) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? _accent : Colors.white12),
        ),
        child: Text(
          format.label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  Widget _pickerButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    bool muted = false,
  }) {
    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: Colors.white54),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: muted ? Colors.white38 : Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              const Icon(Icons.expand_more, color: Colors.white38, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
