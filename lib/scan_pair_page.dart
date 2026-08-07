import 'dart:io';
import 'dart:math' as math;

import 'package:animated_reorderable_list/animated_reorderable_list.dart';
import 'package:flutter/material.dart';

import 'album_shot.dart';
import 'film_format.dart';

const Color _accent = Color(0xFFFFB300);

class _ScanEntry {
  _ScanEntry({required this.id, this.file});

  final String id;
  final File? file;
}

/// Pair imported scan files with meter shots (oldest → newest frame order).
///
/// Left column = fixed meter frames. Right column = scans reordered with
/// [AnimatedReorderableListView]. Pairing is by row index.
class ScanPairPage extends StatefulWidget {
  const ScanPairPage({
    super.key,
    required this.shotsOldestFirst,
    required this.scanFiles,
  });

  final List<AlbumShot> shotsOldestFirst;
  final List<File> scanFiles;

  @override
  State<ScanPairPage> createState() => _ScanPairPageState();
}

class _ScanPairPageState extends State<ScanPairPage> {
  late List<_ScanEntry> _scans;
  bool _saving = false;
  bool _syncingScroll = false;

  final ScrollController _meterScroll = ScrollController();
  final ScrollController _arrowScroll = ScrollController();
  final ScrollController _scanScroll = ScrollController();

  static const double _rowExtent = 112;
  static const double _arrowWidth = 32;
  static const double _hPad = 12;
  static const double _vPadTop = 12;
  static const double _vPadBottom = 24;

  @override
  void initState() {
    super.initState();
    final n = math.max(
      widget.shotsOldestFirst.length,
      widget.scanFiles.length,
    );
    _scans = List<_ScanEntry>.generate(n, (i) {
      final file = i < widget.scanFiles.length ? widget.scanFiles[i] : null;
      return _ScanEntry(
        id: file != null ? 'file-${file.path}' : 'empty-$i',
        file: file,
      );
    });
    _meterScroll.addListener(() => _syncFrom(_meterScroll));
    _arrowScroll.addListener(() => _syncFrom(_arrowScroll));
    _scanScroll.addListener(() => _syncFrom(_scanScroll));
  }

  @override
  void dispose() {
    _meterScroll.dispose();
    _arrowScroll.dispose();
    _scanScroll.dispose();
    super.dispose();
  }

  void _syncFrom(ScrollController source) {
    if (_syncingScroll || !source.hasClients) return;
    _syncingScroll = true;
    final offset = source.offset;
    for (final c in [_meterScroll, _arrowScroll, _scanScroll]) {
      if (identical(c, source) || !c.hasClients) continue;
      final target = offset.clamp(
        c.position.minScrollExtent,
        c.position.maxScrollExtent,
      );
      if ((c.offset - target).abs() > 0.5) c.jumpTo(target);
    }
    _syncingScroll = false;
  }

  List<_ScanEntry> get _emptySlots =>
      _scans.where((s) => s.file == null).toList(growable: false);

  double _aspectForShot(AlbumShot? shot) {
    final label = shot?.formatLabel;
    if (label != null) {
      for (final format in FilmFormat.all) {
        if (format.label == label) return format.aspectRatio;
      }
    }
    return 3 / 2;
  }

  /// Aspect for a row: prefer that row's meter shot format.
  double _aspectForRow(int index) {
    final shots = widget.shotsOldestFirst;
    if (index < shots.length) return _aspectForShot(shots[index]);
    if (shots.isNotEmpty) return _aspectForShot(shots.first);
    return 3 / 2;
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _scans.removeAt(oldIndex);
      _scans.insert(newIndex, item);
    });
  }

  Future<void> _confirm() async {
    if (_saving) return;
    final shots = widget.shotsOldestFirst;
    final pairs = <({AlbumShot shot, File file})>[];
    final limit = math.min(shots.length, _scans.length);
    for (var i = 0; i < limit; i++) {
      final file = _scans[i].file;
      if (file == null) continue;
      pairs.add((shot: shots[i], file: file));
    }
    if (pairs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pair at least one scan to a frame'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      for (final pair in pairs) {
        final bytes = await pair.file.readAsBytes();
        await AlbumShotStore.setScan(shotId: pair.shot.id, jpegBytes: bytes);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save scans: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _proxyDecorator(Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(animation.value);
        return Material(
          elevation: 2 + 6 * t,
          color: Colors.transparent,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(12),
          child: Transform.scale(
            scale: 1 + 0.04 * t,
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shots = widget.shotsOldestFirst;
    final rowCount = _scans.length;
    final empties = _emptySlots;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Pair scans',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _confirm,
            child: Text(
              _saving ? 'Saving…' : 'Done',
              style: const TextStyle(
                color: _accent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Text(
                'Long-press a scan and drag to reorder. Each row pairs with '
                'the meter frame on the left.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(_hPad, 0, _hPad, 8),
              child: const Row(
                children: [
                  Expanded(
                    child: Text(
                      'Meter',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(width: _arrowWidth),
                  Expanded(
                    child: Text(
                      'Scan',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView.builder(
                      controller: _meterScroll,
                      padding: const EdgeInsets.fromLTRB(
                        _hPad,
                        _vPadTop,
                        0,
                        _vPadBottom,
                      ),
                      itemCount: rowCount,
                      itemExtent: _rowExtent,
                      itemBuilder: (context, index) {
                        final shot =
                            index < shots.length ? shots[index] : null;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _Thumb(
                            path: shot?.imagePath,
                            aspectRatio: _aspectForRow(index),
                            emptyIcon: Icons.photo_outlined,
                            badge: '${index + 1}',
                            fit: BoxFit.cover,
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    width: _arrowWidth,
                    child: ListView.builder(
                      controller: _arrowScroll,
                      padding: const EdgeInsets.fromLTRB(
                        0,
                        _vPadTop,
                        0,
                        _vPadBottom,
                      ),
                      itemCount: rowCount,
                      itemExtent: _rowExtent,
                      itemBuilder: (context, index) {
                        return const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Center(
                            child: Icon(
                              Icons.arrow_forward,
                              color: Colors.white38,
                              size: 18,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: AnimatedReorderableListView(
                      items: _scans,
                      controller: _scanScroll,
                      padding: const EdgeInsets.fromLTRB(
                        0,
                        _vPadTop,
                        _hPad,
                        _vPadBottom,
                      ),
                      isSameItem: (a, b) => a.id == b.id,
                      longPressDraggable: true,
                      dragStartDelay: const Duration(milliseconds: 180),
                      enableSwap: true,
                      nonDraggableItems: empties,
                      proxyDecorator: _proxyDecorator,
                      onReorder: _saving ? (_, _) {} : _onReorder,
                      itemBuilder: (context, index) {
                        final entry = _scans[index];
                        return SizedBox(
                          key: ValueKey(entry.id),
                          height: _rowExtent,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _Thumb(
                              path: entry.file?.path,
                              aspectRatio: _aspectForRow(index),
                              emptyIcon: Icons.add_photo_alternate_outlined,
                              showDragHint: entry.file != null,
                              fit: BoxFit.contain,
                            ),
                          ),
                        );
                      },
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
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.path,
    required this.emptyIcon,
    required this.aspectRatio,
    this.fit = BoxFit.cover,
    this.showDragHint = false,
    this.badge,
  });

  final String? path;
  final IconData emptyIcon;
  final double aspectRatio;
  final BoxFit fit;
  final bool showDragHint;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final aspect = aspectRatio <= 0 ? 1.0 : aspectRatio;
        var width = maxW;
        var height = width / aspect;
        if (height > maxH) {
          height = maxH;
          width = height * aspect;
        }
        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (path == null)
                      Center(
                        child: Icon(emptyIcon, color: Colors.white24, size: 28),
                      )
                    else
                      Image.file(
                        File(path!),
                        fit: fit,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (_, _, _) => const Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white24,
                            size: 28,
                          ),
                        ),
                      ),
                    if (badge != null)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xCC0A0A0A),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge!,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    if (showDragHint)
                      const Positioned(
                        right: 6,
                        bottom: 6,
                        child: Icon(
                          Icons.drag_handle,
                          color: Colors.white54,
                          size: 18,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
