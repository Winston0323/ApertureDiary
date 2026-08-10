import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gear.dart';

const Color _accent = Color(0xFFFFB300);

/// Sentinel: user cleared the mount selection.
const String kClearMount = '__clear_mount__';

/// Opens a sheet of previous lens mounts plus "Add lens mount".
///
/// Returns the chosen mount string, [kClearMount] if cleared, or null if dismissed.
Future<String?> showMountPicker(
  BuildContext context, {
  String? current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF161616),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _MountPickerSheet(current: current),
  );
}

class _MountPickerSheet extends StatefulWidget {
  const _MountPickerSheet({this.current});

  final String? current;

  @override
  State<_MountPickerSheet> createState() => _MountPickerSheetState();
}

class _MountPickerSheetState extends State<_MountPickerSheet> {
  List<String> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final history = await GearStore.loadMountHistory();
    if (!mounted) return;
    setState(() {
      _history = history;
      _loading = false;
    });
  }

  Future<void> _addMount() async {
    final created = await showDialog<String>(
      context: context,
      builder: (_) => const _AddMountDialog(),
    );
    if (created == null || !mounted) return;
    await GearStore.rememberMount(created);
    if (!mounted) return;
    Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Lens mount',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Pick a previous mount or add a new one',
              style: TextStyle(fontSize: 13, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: CircularProgressIndicator(color: _accent),
                ),
              )
            else ...[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                ),
                child: _history.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'No mounts yet',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _history.length,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          color: Colors.white10,
                        ),
                        itemBuilder: (context, index) {
                          final mount = _history[index];
                          final selected = widget.current == mount;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              mount,
                              style: TextStyle(
                                color: selected ? _accent : Colors.white,
                                fontWeight: selected
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                            trailing: selected
                                ? const Icon(Icons.check, color: _accent, size: 20)
                                : null,
                            onTap: () => Navigator.of(context).pop(mount),
                          );
                        },
                      ),
              ),
              if (widget.current != null && widget.current!.isNotEmpty) ...[
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(kClearMount),
                  child: const Text(
                    'Clear mount',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _addMount,
                  icon: const Icon(Icons.add, color: _accent),
                  label: const Text(
                    'Add lens mount',
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
            ],
          ],
        ),
      ),
    );
  }
}

class _AddMountDialog extends StatefulWidget {
  const _AddMountDialog();

  @override
  State<_AddMountDialog> createState() => _AddMountDialogState();
}

class _AddMountDialogState extends State<_AddMountDialog> {
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
        'Add lens mount',
        style: TextStyle(fontSize: 16, color: Colors.white),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white, fontSize: 18),
        textCapitalization: TextCapitalization.characters,
        inputFormatters: [LengthLimitingTextInputFormatter(24)],
        decoration: const InputDecoration(
          hintText: 'e.g. V, F, M, XCD',
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
