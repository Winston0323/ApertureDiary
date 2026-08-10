import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gear.dart';

const Color _accent = Color(0xFFFFB300);

/// Brand chip row with memorized customs + presets and an Add brand action.
class GearBrandChips extends StatefulWidget {
  const GearBrandChips({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final String selected;
  final ValueChanged<String> onChanged;

  @override
  State<GearBrandChips> createState() => _GearBrandChipsState();
}

class _GearBrandChipsState extends State<GearBrandChips> {
  List<String> _brands = List<String>.from(kPresetCameraBrands);
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final brands = await GearStore.loadBrandOptions();
    if (!mounted) return;
    setState(() {
      _brands = brands;
      _loading = false;
    });
  }

  Future<void> _addBrand() async {
    final created = await showDialog<String>(
      context: context,
      builder: (_) => const _AddBrandDialog(),
    );
    if (created == null || !mounted) return;
    await GearStore.rememberBrand(created);
    if (!mounted) return;
    await _reload();
    widget.onChanged(normalizeCameraBrand(created));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          height: 24,
          width: 24,
          child: CircularProgressIndicator(color: _accent, strokeWidth: 2),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final brand in _brands) _chip(brand),
        _addChip(),
      ],
    );
  }

  Widget _chip(String brand) {
    final selected =
        widget.selected.toLowerCase() == brand.toLowerCase();
    return GestureDetector(
      onTap: () => widget.onChanged(brand),
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
          brand,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _addChip() {
    return GestureDetector(
      onTap: _addBrand,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _accent.withValues(alpha: 0.7)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 16, color: _accent),
            SizedBox(width: 4),
            Text(
              'Add brand',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddBrandDialog extends StatefulWidget {
  const _AddBrandDialog();

  @override
  State<_AddBrandDialog> createState() => _AddBrandDialogState();
}

class _AddBrandDialogState extends State<_AddBrandDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF161616),
      title: const Text(
        'Add brand',
        style: TextStyle(fontSize: 16, color: Colors.white),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white, fontSize: 18),
        textCapitalization: TextCapitalization.words,
        inputFormatters: [LengthLimitingTextInputFormatter(32)],
        decoration: const InputDecoration(
          hintText: 'e.g. Bronica, Yashica',
          hintStyle: TextStyle(color: Colors.white38),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Add', style: TextStyle(color: _accent)),
        ),
      ],
    );
  }
}
