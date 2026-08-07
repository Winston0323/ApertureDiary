import 'package:flutter/material.dart';

import 'add_film_page.dart';
import 'film_format.dart';
import 'film_icon.dart';
import 'film_stock.dart';

const Color _accent = Color(0xFFFFB300);

/// Catalog of popular stocks. Returns the chosen [FilmStock] via [Navigator.pop].
class FilmSelectPage extends StatefulWidget {
  const FilmSelectPage({super.key});

  @override
  State<FilmSelectPage> createState() => _FilmSelectPageState();
}

class _FilmSelectPageState extends State<FilmSelectPage> {
  FilmType? _formatFilter; // null = all
  FilmCategory? _categoryFilter; // null = all

  List<FilmCatalogEntry> get _visibleFilms {
    return PopularFilms.catalog.where((f) {
      if (_formatFilter != null && !f.offers(_formatFilter!)) return false;
      if (_categoryFilter != null && f.category != _categoryFilter) return false;
      return true;
    }).toList();
  }

  Future<void> _select(FilmCatalogEntry entry) async {
    final formats = _formatFilter == null
        ? entry.formats
        : entry.formats.where((f) => f == _formatFilter).toList();

    FilmType? type;
    if (formats.length == 1) {
      type = formats.first;
    } else {
      type = await showModalBottomSheet<FilmType>(
        context: context,
        backgroundColor: const Color(0xFF161616),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  entry.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Choose format',
                  style: TextStyle(fontSize: 13, color: Colors.white54),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    for (var i = 0; i < formats.length; i++) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx, formats[i]),
                          style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: Text(
                            formats[i].label,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (type == null || !mounted) return;

    FilmFormat? frameFormat;
    if (type == FilmType.thirtyFive) {
      frameFormat = FilmFormat.thirtyFive;
    } else {
      frameFormat = await _pick120FrameFormat(entry.name);
      if (frameFormat == null || !mounted) return;
    }

    Navigator.of(context).pop(entry.toStock(type, frameFormat: frameFormat));
  }

  /// 120 rolls shoot either 645 or 6×6 — pick once when loading the film.
  Future<FilmFormat?> _pick120FrameFormat(String filmName) {
    const options = [FilmFormat.sixFourFive, FilmFormat.sixBySix];
    return showModalBottomSheet<FilmFormat>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                filmName,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Choose frame size',
                style: TextStyle(fontSize: 13, color: Colors.white54),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (var i = 0; i < options.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, options[i]),
                        style: FilledButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(
                          options[i].label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAddFilm() async {
    final film = await Navigator.of(context).push<FilmStock>(
      MaterialPageRoute(builder: (_) => const AddFilmPage()),
    );
    if (film == null || !mounted) return;
    Navigator.of(context).pop(film);
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
          'Select film',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildFormatBar(),
            _buildCategoryBar(),
            Expanded(child: _buildFilmList()),
          ],
        ),
      ),
    );
  }

  Widget _buildFormatBar() {
    return Container(
      height: 44,
      color: const Color(0xFF0F0F0F),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        children: [
          _chip(
            selected: _formatFilter == null,
            label: 'All',
            onTap: () => setState(() => _formatFilter = null),
          ),
          const SizedBox(width: 8),
          _chip(
            selected: _formatFilter == FilmType.thirtyFive,
            label: '135',
            onTap: () => setState(() => _formatFilter = FilmType.thirtyFive),
          ),
          const SizedBox(width: 8),
          _chip(
            selected: _formatFilter == FilmType.oneTwenty,
            label: '120',
            onTap: () => setState(() => _formatFilter = FilmType.oneTwenty),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBar() {
    return Container(
      height: 44,
      color: const Color(0xFF0A0A0A),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
        children: [
          _chip(
            selected: _categoryFilter == null,
            label: 'All types',
            onTap: () => setState(() => _categoryFilter = null),
          ),
          for (final category in FilmCategory.values) ...[
            const SizedBox(width: 8),
            _chip(
              selected: _categoryFilter == category,
              label: category.label,
              onTap: () => setState(() => _categoryFilter = category),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip({
    required bool selected,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              selected ? _accent.withValues(alpha: 0.9) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? _accent : Colors.white12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildFilmList() {
    final entries = <_ListEntry>[_ListEntry.custom()];
    final films = _visibleFilms;

    if (_categoryFilter != null) {
      for (final film in films) {
        entries.add(_ListEntry.film(film));
      }
    } else {
      FilmCategory? lastCategory;
      for (final film in films) {
        if (film.category != lastCategory) {
          entries.add(_ListEntry.header(film.category.label));
          lastCategory = film.category;
        }
        entries.add(_ListEntry.film(film));
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.isCustom) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _CustomFilmTile(onTap: _openAddFilm),
          );
        }
        if (entry.isHeader) {
          return Padding(
            padding: EdgeInsets.fromLTRB(4, index <= 1 ? 8 : 16, 4, 8),
            child: Text(
              entry.header!,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _CatalogFilmTile(
            entry: entry.film!,
            formatFilter: _formatFilter,
            onTap: () => _select(entry.film!),
          ),
        );
      },
    );
  }
}

class _ListEntry {
  const _ListEntry._({this.header, this.film, this.isCustom = false});

  factory _ListEntry.custom() => const _ListEntry._(isCustom: true);
  factory _ListEntry.header(String label) => _ListEntry._(header: label);
  factory _ListEntry.film(FilmCatalogEntry film) => _ListEntry._(film: film);

  final String? header;
  final FilmCatalogEntry? film;
  final bool isCustom;

  bool get isHeader => header != null;
}

class _CustomFilmTile extends StatelessWidget {
  const _CustomFilmTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF221C0A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x55FFB300)),
                ),
                child: const Icon(Icons.edit, color: _accent, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Custom film',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Enter name, format, and ISO',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogFilmTile extends StatelessWidget {
  const _CatalogFilmTile({
    required this.entry,
    required this.onTap,
    this.formatFilter,
  });

  final FilmCatalogEntry entry;
  final FilmType? formatFilter;
  final VoidCallback onTap;

  String get _formatsLabel {
    final formats = formatFilter == null
        ? entry.formats
        : entry.formats.where((f) => f == formatFilter).toList();
    return formats.map((f) => f.label).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              FilmIcon(asset: entry.iconAsset, fallbackLabel: 'ISO'),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
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
                      'ISO ${entry.iso}  ·  $_formatsLabel',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.add, color: Colors.white24, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
