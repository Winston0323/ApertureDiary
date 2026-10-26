import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'exposure.dart';
import 'reference_exposure.dart';

/// Asks for what a trusted camera's display shows for the metered light:
/// f-number, shutter speed and ISO.
class ReferenceExposureDialog extends StatefulWidget {
  const ReferenceExposureDialog({
    super.key,
    required this.initialIso,
    this.initial,
  });

  /// ISO to start from, normally the film speed shown on the meter.
  final int initialIso;

  /// The previous entry, so a repeat measurement is one tap.
  final ReferenceExposure? initial;

  @override
  State<ReferenceExposureDialog> createState() =>
      _ReferenceExposureDialogState();
}

class _ReferenceExposureDialogState extends State<ReferenceExposureDialog> {
  late final TextEditingController _aperture = TextEditingController(
    text: widget.initial == null
        ? ''
        : _trim(widget.initial!.aperture),
  );
  late final TextEditingController _shutter = TextEditingController(
    text: widget.initial == null
        ? ''
        : _shutterText(widget.initial!.shutterSeconds),
  );
  late final TextEditingController _iso = TextEditingController(
    text: (widget.initial?.iso ?? widget.initialIso).round().toString(),
  );

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  static String _shutterText(double seconds) {
    if (seconds >= 1) return _trim(seconds);
    final denom = 1 / seconds;
    if ((denom - denom.round()).abs() < 0.05) return '1/${denom.round()}';
    return seconds.toStringAsFixed(3);
  }

  @override
  void dispose() {
    _aperture.dispose();
    _shutter.dispose();
    _iso.dispose();
    super.dispose();
  }

  ReferenceExposure? get _parsed {
    final n = ReferenceExposure.parseAperture(_aperture.text);
    final t = ReferenceExposure.parseShutter(_shutter.text);
    final s = ReferenceExposure.parseIso(_iso.text);
    if (n == null || t == null || s == null) return null;
    final ref = ReferenceExposure(aperture: n, shutterSeconds: t, iso: s);
    return ref.isValid ? ref : null;
  }

  String? get _problem {
    if (_aperture.text.trim().isEmpty ||
        _shutter.text.trim().isEmpty ||
        _iso.text.trim().isEmpty) {
      return null;
    }
    if (ReferenceExposure.parseAperture(_aperture.text) == null) {
      return 'Aperture: enter an f-number such as 5.6';
    }
    if (ReferenceExposure.parseShutter(_shutter.text) == null) {
      return 'Shutter: use 1/125, 0.5 or 2 — not a bare 125';
    }
    if (ReferenceExposure.parseIso(_iso.text) == null) {
      return 'ISO: enter a number such as 400';
    }
    return null;
  }

  void _submit() {
    final ref = _parsed;
    if (ref == null) return;
    Navigator.of(context).pop(ref);
  }

  @override
  Widget build(BuildContext context) {
    final ref = _parsed;
    final problem = _problem;

    return AlertDialog(
      backgroundColor: const Color(0xFF161616),
      title: const Text('Match to your camera', style: TextStyle(fontSize: 16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Aim the phone at an evenly lit mid-tone (a grey card or grey '
              'wall). Meter the same surface with your camera in aperture '
              'priority, spot metering, exposure compensation 0, then enter '
              'what its display shows.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _field(
                    controller: _aperture,
                    label: 'f/',
                    hint: '5.6',
                    autofocus: true,
                    keyboard: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    allow: RegExp(r'[0-9.,fF/]'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _field(
                    controller: _shutter,
                    label: 'Shutter',
                    hint: '1/125',
                    keyboard: TextInputType.text,
                    allow: RegExp(r'[0-9./,"]'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _field(
                    controller: _iso,
                    label: 'ISO',
                    hint: '400',
                    keyboard: TextInputType.number,
                    allow: RegExp(r'[0-9]'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (problem != null)
              Text(
                problem,
                style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
              )
            else if (ref != null)
              Text(
                'Scene ${ExposureMath.formatAperture(ref.aperture)} · '
                '${ExposureMath.formatShutter(ref.shutterSeconds)} · '
                'ISO ${ref.iso.round()}  =  EV₁₀₀ ${ref.ev100.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 12, color: Color(0xFFFFB300)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: ref == null ? null : _submit,
          child: const Text('Calibrate'),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required TextInputType keyboard,
    required RegExp allow,
    bool autofocus = false,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: keyboard,
      inputFormatters: [FilteringTextInputFormatter.allow(allow)],
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24),
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    );
  }
}
