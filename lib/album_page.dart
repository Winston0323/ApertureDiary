import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import 'album_shot.dart';
import 'film_frame.dart';
import 'film_stock.dart';
import 'scan_pair_page.dart';
import 'shot_thumb.dart';

const Color _accent = Color(0xFFFFB300);

/// Newest → oldest timeline of frames saved from the light meter.
///
/// When [film] is set, only shots from that roll are shown.
class AlbumPage extends StatefulWidget {
  const AlbumPage({super.key, this.film});

  /// Current meter roll — album is scoped to this film when provided.
  final FilmStock? film;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  List<AlbumShot> _shots = [];
  bool _loading = true;
  bool _selectMode = false;
  bool _busy = false;
  int _pendingSaves = 0;
  final Set<String> _selectedIds = {};

  bool get _allSelected =>
      _shots.isNotEmpty && _shots.every((s) => _selectedIds.contains(s.id));

  List<AlbumShot> get _selectedShots =>
      _shots.where((s) => _selectedIds.contains(s.id)).toList();

  @override
  void initState() {
    super.initState();
    _pendingSaves = AlbumShotStore.pendingSaves.value;
    AlbumShotStore.revision.addListener(_onAlbumChanged);
    AlbumShotStore.pendingSaves.addListener(_onPendingChanged);
    _load();
  }

  @override
  void dispose() {
    AlbumShotStore.revision.removeListener(_onAlbumChanged);
    AlbumShotStore.pendingSaves.removeListener(_onPendingChanged);
    super.dispose();
  }

  void _onAlbumChanged() {
    if (!mounted) return;
    _load();
  }

  void _onPendingChanged() {
    if (!mounted) return;
    setState(() => _pendingSaves = AlbumShotStore.pendingSaves.value);
  }

  Future<void> _load() async {
    final shots = await AlbumShotStore.load();
    if (!mounted) return;
    final film = widget.film;
    final filtered = film == null
        ? shots
        : shots.where((s) => _belongsToFilm(s, film)).toList();
    setState(() {
      _shots = filtered;
      _loading = false;
      _selectedIds.removeWhere((id) => !_shots.any((s) => s.id == id));
      if (_shots.isEmpty) _selectMode = false;
    });
  }

  bool _belongsToFilm(AlbumShot shot, FilmStock film) {
    if (shot.filmId == film.id) return true;
    // Legacy shots saved before filmId was recorded.
    return shot.filmId == null &&
        shot.filmName == film.name &&
        shot.iso == film.iso;
  }

  void _enterSelectMode(AlbumShot shot) {
    setState(() {
      _selectMode = true;
      _selectedIds
        ..clear()
        ..add(shot.id);
    });
  }

  void _exitSelectMode() {
    if (!_selectMode) return;
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _setSelectAll(bool select) {
    setState(() {
      if (select) {
        _selectedIds
          ..clear()
          ..addAll(_shots.map((s) => s.id));
      } else {
        _selectedIds.clear();
      }
    });
  }

  void _toggleShotSelected(AlbumShot shot) {
    setState(() {
      if (_selectedIds.contains(shot.id)) {
        _selectedIds.remove(shot.id);
      } else {
        _selectedIds.add(shot.id);
      }
    });
  }

  void _toggleDaySelected(String dayKey) {
    final dayShots =
        _shots.where((s) => _dayKey(s.takenAt) == dayKey).toList();
    if (dayShots.isEmpty) return;
    final allSelected = dayShots.every((s) => _selectedIds.contains(s.id));
    setState(() {
      if (allSelected) {
        for (final s in dayShots) {
          _selectedIds.remove(s.id);
        }
      } else {
        for (final s in dayShots) {
          _selectedIds.add(s.id);
        }
      }
    });
  }

  bool _dayFullySelected(String dayKey) {
    final dayShots =
        _shots.where((s) => _dayKey(s.takenAt) == dayKey).toList();
    return dayShots.isNotEmpty &&
        dayShots.every((s) => _selectedIds.contains(s.id));
  }

  void _onShotTap(AlbumShot shot) {
    if (_selectMode) {
      _toggleShotSelected(shot);
      return;
    }
    _openShot(shot);
  }

  Future<void> _openShot(AlbumShot shot) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => AlbumDetailPage(shot: shot)),
    );
    if (!mounted) return;
    await _load();
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _importScans() async {
    if (_busy || widget.film == null || _shots.isEmpty) return;
    setState(() => _busy = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickMultiImage(imageQuality: 95);
      if (!mounted) return;
      if (picked.isEmpty) return;

      final files = <File>[];
      for (final x in picked) {
        files.add(File(x.path));
      }

      final oldestFirst = [..._shots]
        ..sort((a, b) => a.takenAt.compareTo(b.takenAt));

      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ScanPairPage(
            shotsOldestFirst: oldestFirst,
            scanFiles: files,
          ),
        ),
      );
      if (!mounted) return;
      await _load();
      if (saved == true) _toast('Scans paired');
    } catch (e) {
      if (mounted) _toast('Could not import: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedShots;
    if (selected.isEmpty || _busy) return;
    final count = selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(count == 1 ? 'Delete frame' : 'Delete frames'),
        content: Text(
          count == 1
              ? 'Remove this frame from the album?'
              : 'Remove $count frames from the album?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      for (final shot in selected) {
        await AlbumShotStore.remove(shot);
      }
      _exitSelectMode();
      await _load();
      if (mounted) _toast(count == 1 ? 'Deleted' : 'Deleted $count frames');
    } catch (e) {
      if (mounted) _toast('Could not delete: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSelectedToPhone() async {
    final selected = _selectedShots;
    if (selected.isEmpty || _busy) return;

    var printInfo = false;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      selected.length == 1
                          ? 'Save to phone'
                          : 'Save ${selected.length} to phone',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: printInfo,
                      onChanged: (v) =>
                          setSheetState(() => printInfo = v ?? false),
                      activeColor: _accent,
                      checkColor: Colors.black,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text(
                        'Print exposure info on border',
                        style: TextStyle(fontSize: 14, color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text(
                        'Save to phone',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    _toast('Saving…');
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (mounted) _toast('Allow photo access to save to phone');
          return;
        }
      }

      var ok = 0;
      for (final shot in selected) {
        await exportAlbumShotToPhone(shot, printInfo: printInfo);
        ok++;
      }
      if (!mounted) return;
      _exitSelectMode();
      _toast(ok == 1 ? 'Saved to phone' : 'Saved $ok to phone');
    } on GalException catch (e) {
      if (mounted) _toast(e.type.message);
    } catch (e) {
      if (mounted) _toast('Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectMode) _exitSelectMode();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0A0A0A),
          foregroundColor: Colors.white,
          elevation: 0,
          title: Text(
            _selectMode ? 'Select frames' : 'Album',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          actions: [
            if (_selectMode)
              TextButton(
                onPressed: _busy ? null : _exitSelectMode,
                child: const Text(
                  'Done',
                  style: TextStyle(
                    color: _accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              )
            else if (widget.film != null && _shots.isNotEmpty)
              IconButton(
                tooltip: 'Import scans',
                onPressed: _busy ? null : _importScans,
                icon: const Icon(Icons.add_photo_alternate_outlined),
              ),
          ],
        ),
        bottomNavigationBar: _selectMode ? _buildSelectBar() : null,
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: _accent))
              : _shots.isEmpty && _pendingSaves == 0
                  ? _buildEmpty()
                  : _buildTimeline(),
        ),
      ),
    );
  }

  Widget _buildSelectBar() {
    final count = _selectedIds.length;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: const BoxDecoration(
          color: Color(0xFF0F0F0F),
          border: Border(top: BorderSide(color: Colors.white12)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckboxListTile(
              value: _allSelected,
              onChanged: _busy ? null : (v) => _setSelectAll(v ?? false),
              activeColor: _accent,
              checkColor: Colors.black,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: const Text(
                'Select all',
                style: TextStyle(fontSize: 14, color: Colors.white70),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: count == 0 || _busy ? null : _saveSelectedToPhone,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _accent,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(
                      count == 0 ? 'Save to phone' : 'Save $count',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: count == 0 || _busy ? null : _deleteSelected,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFF2A2A2A),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(
                      count == 0 ? 'Delete' : 'Delete $count',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 48, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'No frames yet',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tap the shutter on the light meter to save a frame here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeline() {
    final entries = <_AlbumEntry>[];
    String? lastDayKey;

    for (final shot in _shots) {
      final dayKey = _dayKey(shot.takenAt);
      if (dayKey != lastDayKey) {
        entries.add(
          _AlbumEntry.header(
            label: _formatDayLabel(shot.takenAt),
            dayKey: dayKey,
          ),
        );
        lastDayKey = dayKey;
      }
      entries.add(_AlbumEntry.shot(shot));
    }

    final pendingHeader = _pendingSaves > 0 ? 1 : 0;

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(12, 8, 12, _selectMode ? 16 : 24),
      itemCount: entries.length + pendingHeader,
      itemBuilder: (context, index) {
        if (_pendingSaves > 0 && index == 0) {
          return _buildSavingBanner();
        }
        final entry = entries[index - pendingHeader];
        if (entry.isHeader) {
          final dayKey = entry.dayKey!;
          final daySelected = _dayFullySelected(dayKey);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              0,
              index - pendingHeader == 0 && _pendingSaves == 0 ? 4 : 18,
              4,
              8,
            ),
            child: Row(
              children: [
                if (_selectMode) ...[
                  SizedBox(
                    width: 42,
                    child: Checkbox(
                      value: daySelected,
                      onChanged:
                          _busy ? null : (_) => _toggleDaySelected(dayKey),
                      activeColor: _accent,
                      checkColor: Colors.black,
                      side: const BorderSide(color: Colors.white38),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: GestureDetector(
                    onTap: _selectMode && !_busy
                        ? () => _toggleDaySelected(dayKey)
                        : null,
                    child: Text(
                      entry.header!,
                      style: TextStyle(
                        color: _selectMode && daySelected
                            ? _accent
                            : Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final shot = entry.shot!;
        final selected = _selectedIds.contains(shot.id);
        return _buildShotTile(shot, selected: selected);
      },
    );
  }

  Widget _buildSavingBanner() {
    final label = _pendingSaves == 1
        ? 'Saving frame…'
        : 'Saving $_pendingSaves frames…';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF221C0A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x55FFB300)),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: _accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShotTile(AlbumShot shot, {required bool selected}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 42,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _selectMode
                  ? Checkbox(
                      value: selected,
                      onChanged:
                          _busy ? null : (_) => _toggleShotSelected(shot),
                      activeColor: _accent,
                      checkColor: Colors.black,
                      side: const BorderSide(color: Colors.white38),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    )
                  : Text(
                      _formatTime(shot.takenAt),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Material(
              color: _selectMode && selected
                  ? const Color(0xFF221C0A)
                  : const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _busy ? null : () => _onShotTap(shot),
                onLongPress:
                    _busy || _selectMode ? null : () => _enterSelectMode(shot),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ShotThumbStack(
                        shot: shot,
                        height: 100,
                        borderRadius: 8,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        shot.filmName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    if (shot.hasScan) ...[
                                      const SizedBox(width: 6),
                                      const ScanChip(),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${shot.shutter}  ·  ${shot.aperture}'
                                  '${shot.flash ? '  ·  Flash' : ''}',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                                if (shot.formatLabel != null ||
                                    _selectMode) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    _selectMode
                                        ? _formatTime(shot.takenAt)
                                        : [
                                            shot.formatLabel,
                                            if (shot.focalMm != null)
                                              '${shot.focalMm!.round()} mm',
                                            'ISO ${shot.iso}',
                                          ].join('  ·  '),
                                    style: TextStyle(
                                      color:
                                          selected ? _accent : Colors.white38,
                                      fontSize: 11,
                                      fontWeight: _selectMode
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (!_selectMode)
                            const Padding(
                              padding: EdgeInsets.only(left: 4, top: 2),
                              child: Icon(
                                Icons.chevron_right,
                                color: Colors.white24,
                                size: 20,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-frame view with exposure details and a flash checkbox.
class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({super.key, required this.shot});

  final AlbumShot shot;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  late AlbumShot _shot;
  bool _exporting = false;
  bool _scanBusy = false;
  late bool _viewScan;

  @override
  void initState() {
    super.initState();
    _shot = widget.shot;
    _viewScan = _shot.hasScan;
  }

  Future<void> _setFlash(bool value) async {
    final updated = _shot.copyWith(flash: value);
    setState(() => _shot = updated);
    await AlbumShotStore.update(updated);
  }

  Future<void> _addOrReplaceScan() async {
    if (_scanBusy || _exporting) return;
    setState(() => _scanBusy = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 95,
      );
      if (picked == null || !mounted) return;
      final bytes = await File(picked.path).readAsBytes();
      final updated = await AlbumShotStore.setScan(
        shotId: _shot.id,
        jpegBytes: bytes,
      );
      if (!mounted) return;
      if (updated != null) {
        final wasReplace = _shot.hasScan;
        setState(() {
          _shot = updated;
          _viewScan = true;
        });
        _toast(wasReplace ? 'Scan updated' : 'Scan added');
      }
    } catch (e) {
      if (mounted) _toast('Could not import scan: $e');
    } finally {
      if (mounted) setState(() => _scanBusy = false);
    }
  }

  Future<void> _removeScan() async {
    if (_scanBusy || _exporting || !_shot.hasScan) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Remove scan'),
        content: const Text('Detach the scanned image from this frame?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _scanBusy = true);
    try {
      final updated = await AlbumShotStore.clearScan(_shot.id);
      if (!mounted) return;
      if (updated != null) {
        setState(() {
          _shot = updated;
          _viewScan = false;
        });
        _toast('Scan removed');
      }
    } catch (e) {
      if (mounted) _toast('Could not remove scan: $e');
    } finally {
      if (mounted) setState(() => _scanBusy = false);
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openSaveToPhoneSheet() async {
    if (_exporting) return;
    var printInfo = false;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Save to phone',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_shot.shutter}  ·  ${_shot.aperture}  ·  ISO ${_shot.iso}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: printInfo,
                      onChanged: (v) =>
                          setSheetState(() => printInfo = v ?? false),
                      activeColor: _accent,
                      checkColor: Colors.black,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text(
                        'Print exposure info on border',
                        style: TextStyle(fontSize: 14, color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text(
                        'Save to phone',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    if (confirmed != true || !mounted) return;
    await _saveToPhone(printInfo: printInfo);
  }

  Future<void> _saveToPhone({required bool printInfo}) async {
    setState(() => _exporting = true);
    _toast('Saving…');
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (mounted) _toast('Allow photo access to save to phone');
          return;
        }
      }

      await exportAlbumShotToPhone(_shot, printInfo: printInfo);
      if (mounted) _toast('Saved to phone');
    } on GalException catch (e) {
      if (mounted) _toast(e.type.message);
    } catch (e) {
      if (mounted) _toast('Could not save: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Delete frame'),
        content: const Text('Remove this frame from the album?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AlbumShotStore.remove(_shot);
    if (!mounted) return;
    Navigator.of(context).pop();
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
          _formatDayLabel(_shot.takenAt),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          PopupMenuButton<String>(
            enabled: !_exporting && !_scanBusy,
            color: const Color(0xFF1A1A1A),
            onSelected: (value) async {
              if (value == 'add_scan' || value == 'replace_scan') {
                await _addOrReplaceScan();
              } else if (value == 'remove_scan') {
                await _removeScan();
              } else if (value == 'delete') {
                await _delete();
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: _shot.hasScan ? 'replace_scan' : 'add_scan',
                child: Text(_shot.hasScan ? 'Replace scan' : 'Add scan'),
              ),
              if (_shot.hasScan)
                const PopupMenuItem(
                  value: 'remove_scan',
                  child: Text('Remove scan'),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'delete',
                child: Text(
                  'Delete frame',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_shot.hasScan)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('Meter'),
                        icon: Icon(Icons.camera_outlined, size: 16),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('Scan'),
                        icon: Icon(Icons.photo_outlined, size: 16),
                      ),
                    ],
                    selected: {_viewScan},
                    onSelectionChanged: (next) {
                      setState(() => _viewScan = next.first);
                    },
                    style: ButtonStyle(
                      backgroundColor:
                          WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return _accent.withValues(alpha: 0.2);
                        }
                        return const Color(0xFF1A1A1A);
                      }),
                      foregroundColor:
                          WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return _accent;
                        }
                        return Colors.white70;
                      }),
                      side: WidgetStateProperty.all(
                        const BorderSide(color: Colors.white12),
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: _viewerImage(
                  path: _viewScan &&
                          _shot.hasScan &&
                          _shot.scanImagePath != null
                      ? _shot.scanImagePath!
                      : _shot.imagePath,
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              decoration: const BoxDecoration(
                color: Color(0xFF121212),
                border: Border(top: BorderSide(color: Colors.white12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _shot.filmName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      _formatTime(_shot.takenAt),
                      if (_shot.formatLabel != null) _shot.formatLabel!,
                      if (_shot.focalMm != null)
                        '${_shot.focalMm!.round()} mm',
                      if (_shot.ev != null)
                        'EV ${_shot.ev!.toStringAsFixed(1)}',
                      if (_shot.hasScan) 'Scan',
                    ].join('  ·  '),
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _infoTile(label: 'Shutter', value: _shot.shutter),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child:
                            _infoTile(label: 'Aperture', value: _shot.aperture),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _infoTile(label: 'ISO', value: '${_shot.iso}'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: _shot.flash,
                    onChanged: _exporting || _scanBusy
                        ? null
                        : (v) => _setFlash(v ?? false),
                    activeColor: _accent,
                    checkColor: Colors.black,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: const Text(
                      'Flash used',
                      style: TextStyle(fontSize: 14, color: Colors.white70),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _exporting || _scanBusy
                        ? null
                        : _openSaveToPhoneSheet,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: const Color(0xFF2A2A2A),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: _exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.download_outlined, size: 18),
                    label: Text(
                      _exporting ? 'Saving…' : 'Save to phone',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewerImage({required String path}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: const Color(0xFF111111),
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white24,
                  size: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoTile({required String label, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Colors.white54),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumEntry {
  const _AlbumEntry._({this.header, this.dayKey, this.shot});

  factory _AlbumEntry.header({
    required String label,
    required String dayKey,
  }) =>
      _AlbumEntry._(header: label, dayKey: dayKey);

  factory _AlbumEntry.shot(AlbumShot shot) => _AlbumEntry._(shot: shot);

  final String? header;
  final String? dayKey;
  final AlbumShot? shot;

  bool get isHeader => header != null;
}

/// Writes [shot] to the phone gallery, optionally with an exposure border.
Future<void> exportAlbumShotToPhone(
  AlbumShot shot, {
  required bool printInfo,
}) async {
  final source = await File(shot.imagePath).readAsBytes();
  final Uint8List bytes;
  if (printInfo) {
    bytes = await exportFilmFrame(
      jpegBytes: source,
      caption: FilmFrameCaption(
        shutter: shot.shutter,
        aperture: shot.aperture,
        iso: '${shot.iso}',
        ev: shot.ev == null ? null : 'EV ${shot.ev!.toStringAsFixed(1)}',
        extra: [
          shot.filmName,
          if (shot.formatLabel != null) shot.formatLabel!,
          if (shot.focalMm != null) '${shot.focalMm!.round()} mm',
          if (shot.flash) 'Flash',
        ].join('  ·  '),
      ),
      printInfo: true,
    );
  } else {
    bytes = source;
  }

  final name = 'aperture_diary_${DateTime.now().millisecondsSinceEpoch}';
  await Gal.putImageBytes(bytes, name: name, album: 'ApertureDiary');
}

String _dayKey(DateTime dt) {
  final local = dt.toLocal();
  return '${local.year}-${local.month}-${local.day}';
}

String _formatDayLabel(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;

  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';

  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final month = months[local.month - 1];
  if (local.year == now.year) return '$month ${local.day}';
  return '$month ${local.day}, ${local.year}';
}

String _formatTime(DateTime dt) {
  final local = dt.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}
