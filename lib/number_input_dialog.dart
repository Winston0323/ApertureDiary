import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Numeric entry dialog that owns its own [TextEditingController].
///
/// The controller has to belong to the dialog rather than to the caller: a
/// caller that disposes it as soon as `showDialog` completes tears it down
/// while the field is still mounted for the closing animation.
class NumberInputDialog extends StatefulWidget {
  const NumberInputDialog({
    super.key,
    required this.title,
    required this.helper,
    required this.initialText,
  });

  final String title;
  final String helper;
  final String initialText;

  @override
  State<NumberInputDialog> createState() => _NumberInputDialogState();
}

class _NumberInputDialogState extends State<NumberInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(parseNumber(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF161616),
      title: Text(widget.title, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          helperText: widget.helper,
          helperStyle: const TextStyle(color: Colors.white38),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: const Text('Set')),
      ],
    );
  }
}

/// Parses user-entered text, tolerating a comma as the decimal separator.
double? parseNumber(String text) {
  final normalized = text.trim().replaceAll(',', '.');
  if (normalized.isEmpty) return null;
  return double.tryParse(normalized);
}
