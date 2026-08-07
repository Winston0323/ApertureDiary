import 'dart:io';

import 'package:flutter/material.dart';

import 'album_shot.dart';
import 'edit_film_sheet.dart';
import 'film_format.dart';
import 'film_icon.dart';
import 'film_page.dart';
import 'film_stock.dart';

const Color _accent = Color(0xFFFFB300);

/// Home: the user's selected film rolls as a newest → oldest timeline.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onOpenMeter});

  final void Function(FilmStock film) onOpenMeter;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<FilmStock> _films = [];
  List<AlbumShot> _shots = [];
  bool _loading = true;

  /// Edit mode: checkboxes on every film; Edit when exactly one is selected.
  bool _editMode = false;

  final Set<String> _selectedIds = {};

  FilmStock? get _singleSelected {
    if (_selectedIds.length != 1) return null;
    final id = _selectedIds.first;
    for (final f in _films) {
      if (f.id == id) return f;
    }
    return null;
  }

  bool get _allSelected =>
      _films.isNotEmpty && _films.every((f) => _selectedIds.contains(f.id));

  @override
  void initState() {
    super.initState();
    AlbumShotStore.revision.addListener(_onAlbumChanged);
    _load();
  }

  @override
  void dispose() {
    AlbumShotStore.revision.removeListener(_onAlbumChanged);
    super.dispose();
  }

  void _onAlbumChanged() {
    if (!mounted) return;
    _loadShots();
  }

  Future<void> _load() async {
    final films = await FilmStockStore.loadSelected();
    final shots = await AlbumShotStore.load();
    if (!mounted) return;
    setState(() {
      _films = films;
      _shots = shots;
      _loading = false;
    });
  }

  Future<void> _loadShots() async {
    final shots = await AlbumShotStore.load();
    if (!mounted) return;
    setState(() => _shots = shots);
  }

  List<AlbumShot> _previewsFor(FilmStock film) {
    return _shots
        .where(
          (s) =>
              s.filmId == film.id ||
              (s.filmId == null &&
                  s.filmName == film.name &&
                  s.iso == film.iso),
        )
        .toList();
  }

  void _sortTimeline() {
    _films.sort((a, b) => b.timelineAt.compareTo(a.timelineAt));
  }

  void _enterEditMode(FilmStock film) {
    setState(() {
      _editMode = true;
      _selectedIds
        ..clear()
        ..add(film.id);
    });
  }

  void _exitEditMode() {
    if (!_editMode) return;
    setState(() {
      _editMode = false;
      _selectedIds.clear();
    });
  }

  void _setSelectAll(bool select) {
    setState(() {
      if (select) {
        _selectedIds
          ..clear()
          ..addAll(_films.map((f) => f.id));
      } else {
        _selectedIds.clear();
      }
    });
  }

  void _toggleFilmSelected(FilmStock film) {
    setState(() {
      if (_selectedIds.contains(film.id)) {
        _selectedIds.remove(film.id);
      } else {
        _selectedIds.add(film.id);
      }
    });
  }

  void _toggleDaySelected(String dayKey) {
    final dayFilms =
        _films.where((f) => _dayKey(f.timelineAt) == dayKey).toList();
    if (dayFilms.isEmpty) return;
    final allSelected = dayFilms.every((f) => _selectedIds.contains(f.id));
    setState(() {
      if (allSelected) {
        for (final f in dayFilms) {
          _selectedIds.remove(f.id);
        }
      } else {
        for (final f in dayFilms) {
          _selectedIds.add(f.id);
        }
      }
    });
  }

  bool _dayFullySelected(String dayKey) {
    final dayFilms =
        _films.where((f) => _dayKey(f.timelineAt) == dayKey).toList();
    return dayFilms.isNotEmpty &&
        dayFilms.every((f) => _selectedIds.contains(f.id));
  }

  Future<void> _openSelectFilm() async {
    _exitEditMode();
    final selected = await Navigator.of(context).push<FilmStock>(
      MaterialPageRoute(builder: (_) => const FilmSelectPage()),
    );
    if (selected == null || !mounted) return;

    final roll = selected.asNewRoll();
    setState(() {
      _films = [roll, ..._films];
      _sortTimeline();
    });
    await FilmStockStore.saveSelected(_films);
  }

  Future<void> _editSelected() async {
    final film = _singleSelected;
    if (film == null) return;
    final updated = await showEditFilmSheet(context, film: film);
    if (updated == null || !mounted) return;

    setState(() {
      _films = [
        for (final f in _films) f.id == updated.id ? updated : f,
      ];
      _sortTimeline();
      _editMode = false;
      _selectedIds.clear();
    });
    await FilmStockStore.saveSelected(_films);
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(count == 1 ? 'Delete film' : 'Delete films'),
        content: Text(
          count == 1
              ? 'Delete this film from the timeline?'
              : 'Delete $count films from the timeline?',
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

    setState(() {
      _films = _films.where((f) => !_selectedIds.contains(f.id)).toList();
      _editMode = false;
      _selectedIds.clear();
    });
    await FilmStockStore.saveSelected(_films);
  }

  void _onFilmTap(FilmStock film) {
    if (!_editMode) {
      widget.onOpenMeter(film);
      return;
    }
    _toggleFilmSelected(film);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_editMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editMode) _exitEditMode();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0A0A0A),
          foregroundColor: Colors.white,
          elevation: 0,
          title: Text(
            _editMode ? 'Edit film' : 'ApertureDiary',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          actions: [
            if (_editMode)
              TextButton(
                onPressed: _exitEditMode,
                child: const Text(
                  'Done',
                  style: TextStyle(
                    color: _accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
        floatingActionButton: _editMode
            ? null
            : FloatingActionButton.extended(
                onPressed: _openSelectFilm,
                backgroundColor: _accent,
                foregroundColor: Colors.black,
                icon: const Icon(Icons.add),
                label: const Text(
                  'Select film',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
        bottomNavigationBar: _editMode ? _buildEditBar() : null,
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: _accent))
              : _films.isEmpty
                  ? _buildEmpty()
                  : _buildTimeline(),
        ),
      ),
    );
  }

  Widget _buildEditBar() {
    final single = _singleSelected;
    final canDelete = _selectedIds.isNotEmpty;

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
              onChanged: (v) => _setSelectAll(v ?? false),
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
                if (single != null) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _editSelected,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _accent,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text(
                        'Edit',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canDelete ? _deleteSelected : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFF2A2A2A),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(
                      _selectedIds.isEmpty
                          ? 'Delete'
                          : _selectedIds.length == 1
                              ? 'Delete'
                              : 'Delete ${_selectedIds.length}',
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_roll_outlined, size: 48, color: Colors.white24),
            const SizedBox(height: 16),
            const Text(
              'No films yet',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Select a film to add it here, then tap it to meter.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeline() {
    final entries = <_TimelineEntry>[];
    String? lastDayKey;

    for (final film in _films) {
      final dayKey = _dayKey(film.timelineAt);
      if (dayKey != lastDayKey) {
        entries.add(
          _TimelineEntry.header(
            label: _formatDayLabel(film.timelineAt),
            dayKey: dayKey,
          ),
        );
        lastDayKey = dayKey;
      }
      entries.add(_TimelineEntry.film(film));
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(12, 8, 12, _editMode ? 16 : 88),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.isHeader) {
          final dayKey = entry.dayKey!;
          final daySelected = _dayFullySelected(dayKey);
          return Padding(
            padding: EdgeInsets.fromLTRB(0, index == 0 ? 4 : 18, 4, 8),
            child: Row(
              children: [
                if (_editMode) ...[
                  SizedBox(
                    width: 42,
                    child: Checkbox(
                      value: daySelected,
                      onChanged: (_) => _toggleDaySelected(dayKey),
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
                    onTap: _editMode ? () => _toggleDaySelected(dayKey) : null,
                    child: Text(
                      entry.header!,
                      style: TextStyle(
                        color: _editMode && daySelected
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

        final film = entry.film!;
        return _TimelineFilmTile(
          film: film,
          previews: _previewsFor(film),
          editMode: _editMode,
          selected: _selectedIds.contains(film.id),
          onTap: () => _onFilmTap(film),
          onLongPress: () => _enterEditMode(film),
          onToggleSelect: () => _toggleFilmSelected(film),
        );
      },
    );
  }
}

class _TimelineEntry {
  const _TimelineEntry._({this.header, this.dayKey, this.film});

  factory _TimelineEntry.header({
    required String label,
    required String dayKey,
  }) =>
      _TimelineEntry._(header: label, dayKey: dayKey);

  factory _TimelineEntry.film(FilmStock film) =>
      _TimelineEntry._(film: film);

  final String? header;
  final String? dayKey;
  final FilmStock? film;

  bool get isHeader => header != null;
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

class _TimelineFilmTile extends StatelessWidget {
  const _TimelineFilmTile({
    required this.film,
    required this.previews,
    required this.editMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleSelect,
  });

  final FilmStock film;
  final List<AlbumShot> previews;
  final bool editMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final highlight = editMode && selected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (editMode)
                SizedBox(
                  width: 42,
                  child: Checkbox(
                    value: selected,
                    onChanged: (_) => onToggleSelect(),
                    activeColor: _accent,
                    checkColor: Colors.black,
                    side: const BorderSide(color: Colors.white38),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              Text(
                _formatTime(film.timelineAt),
                style: TextStyle(
                  color: highlight ? _accent : Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Material(
            color: highlight ? const Color(0xFF221C0A) : const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: editMode ? null : onLongPress,
              borderRadius: BorderRadius.circular(12),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: film.brand.color),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 64,
                              height: 64,
                              child: FilmIcon.fill(
                                asset: film.iconAsset,
                                fallbackLabel: film.brand.label,
                                formatLabel: film.rollFormatLabel,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    film.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    [
                                      film.brand.label,
                                      'ISO ${film.iso}',
                                      if (film.category != null)
                                        film.category!.label,
                                      if (film.isCustom) 'Custom',
                                    ].join('  ·  '),
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (previews.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      height: 56,
                                      child: ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: previews.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(width: 6),
                                        itemBuilder: (context, index) {
                                          final shot = previews[index];
                                          return _FilmPreviewThumb(
                                            shot: shot,
                                            fallbackAspect: film
                                                .type.defaultFormat.aspectRatio,
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilmPreviewThumb extends StatelessWidget {
  const _FilmPreviewThumb({
    required this.shot,
    required this.fallbackAspect,
  });

  final AlbumShot shot;
  final double fallbackAspect;

  double get _aspect {
    final label = shot.formatLabel;
    if (label != null) {
      for (final format in FilmFormat.all) {
        if (format.label == label) return format.aspectRatio;
      }
    }
    return fallbackAspect;
  }

  @override
  Widget build(BuildContext context) {
    const height = 56.0;
    final width = height * _aspect;
    final scanPath = shot.scanImagePath;
    final useScan = shot.hasScan &&
        scanPath != null &&
        File(scanPath).existsSync();
    final path = useScan ? scanPath : shot.imagePath;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        File(path),
        width: width,
        height: height,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => Container(
          width: width,
          height: height,
          color: const Color(0xFF2A2A2A),
          alignment: Alignment.center,
          child: const Icon(
            Icons.broken_image_outlined,
            color: Colors.white24,
            size: 18,
          ),
        ),
      ),
    );
  }
}
