import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'exposure.dart';
import 'film_format.dart';
import 'film_stock.dart';
import 'wheel_dial.dart';

const Color _accent = Color(0xFFFFB300);

/// Form to define a custom film. Returns a [FilmStock] via [Navigator.pop].
class AddFilmPage extends StatefulWidget {
  const AddFilmPage({super.key});

  @override
  State<AddFilmPage> createState() => _AddFilmPageState();
}

class _AddFilmPageState extends State<AddFilmPage> {
  final TextEditingController _nameController = TextEditingController();
  FilmType _type = FilmType.thirtyFive;
  FilmFormat _frameFormat = FilmFormat.thirtyFive;
  FilmCategory _category = FilmCategory.colorNegative;
  FilmBrand _brand = FilmBrand.other;
  int _iso = 400;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a film name')),
      );
      return;
    }

    Navigator.of(context).pop(
      FilmStock(
        id: 'custom-${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        type: _type,
        frameFormat: _frameFormat,
        iso: _iso,
        brand: _brand,
        category: _category,
        isCustom: true,
      ),
    );
  }

  Future<void> _pickIso() async {
    final items = ExposureMath.standardIsos;
    var initial = items.indexOf(_iso);
    if (initial < 0) initial = items.indexOf(400);
    if (initial < 0) initial = 0;

    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => WheelDialSheet<int>(
        title: 'ISO',
        items: items,
        initialIndex: initial,
        labelOf: (v) => '$v',
        accent: _accent,
      ),
    );
    if (chosen != null && mounted) {
      setState(() => _iso = chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Add film',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            const Text(
              'Film name',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              inputFormatters: [LengthLimitingTextInputFormatter(48)],
              decoration: InputDecoration(
                hintText: 'e.g. Fomapan 100',
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
            ),
            const SizedBox(height: 20),
            const Text(
              'Brand',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final brand in FilmBrand.values) _brandChip(brand),
              ],
            ),
            const SizedBox(height: 20),
            const Text(
              'Type',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final category in FilmCategory.values)
                  _categoryChip(category),
              ],
            ),
            const SizedBox(height: 20),
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
              const SizedBox(height: 20),
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
              const SizedBox(height: 20),
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
            const SizedBox(height: 20),
            const Text(
              'ISO',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 8),
            _isoButton(),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Add film',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brandChip(FilmBrand brand) {
    final selected = _brand == brand;
    return GestureDetector(
      onTap: () => setState(() => _brand = brand),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? brand.color.withValues(alpha: 0.9)
              : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? brand.color : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: selected ? Colors.black : brand.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              brand.label,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white70,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryChip(FilmCategory category) {
    final selected = _category == category;
    return GestureDetector(
      onTap: () => setState(() => _category = category),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color:
              selected ? _accent.withValues(alpha: 0.9) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? _accent : Colors.white12),
        ),
        child: Text(
          category.label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
            fontSize: 13,
          ),
        ),
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

  Widget _isoButton() {
    return GestureDetector(
      onTap: _pickIso,
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
                'ISO $_iso',
                style: const TextStyle(
                  color: Colors.white,
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
}
