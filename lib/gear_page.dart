import 'package:flutter/material.dart';

import 'add_back_page.dart';
import 'add_camera_page.dart';
import 'add_lens_page.dart';
import 'gear.dart';

const Color _accent = Color(0xFFFFB300);

/// Catalog of user cameras, lenses, and film backs.
class GearPage extends StatefulWidget {
  const GearPage({super.key});

  @override
  State<GearPage> createState() => _GearPageState();
}

class _GearPageState extends State<GearPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<UserCamera> _cameras = [];
  List<UserLens> _lenses = [];
  List<UserBack> _backs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
    GearStore.revision.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    GearStore.revision.removeListener(_reload);
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final cameras = await GearStore.loadCameras();
    final lenses = await GearStore.loadLenses();
    final backs = await GearStore.loadBacks();
    if (!mounted) return;
    setState(() {
      _cameras = cameras;
      _lenses = lenses;
      _backs = backs;
      _loading = false;
    });
  }

  Future<void> _addCamera() async {
    await Navigator.of(context).push<UserCamera>(
      MaterialPageRoute(builder: (_) => const AddCameraPage()),
    );
    await _reload();
  }

  Future<void> _editCamera(UserCamera camera) async {
    await Navigator.of(context).push<UserCamera>(
      MaterialPageRoute(builder: (_) => AddCameraPage(existing: camera)),
    );
    await _reload();
  }

  Future<void> _addLens({String? cameraId}) async {
    await Navigator.of(context).push<UserLens>(
      MaterialPageRoute(
        builder: (_) => AddLensPage(preselectedCameraId: cameraId),
      ),
    );
    await _reload();
  }

  Future<void> _editLens(UserLens lens) async {
    await Navigator.of(context).push<UserLens>(
      MaterialPageRoute(builder: (_) => AddLensPage(existing: lens)),
    );
    await _reload();
  }

  Future<void> _addBack({String? cameraId}) async {
    await Navigator.of(context).push<UserBack>(
      MaterialPageRoute(
        builder: (_) => AddBackPage(preselectedCameraId: cameraId),
      ),
    );
    await _reload();
  }

  Future<void> _editBack(UserBack back) async {
    await Navigator.of(context).push<UserBack>(
      MaterialPageRoute(builder: (_) => AddBackPage(existing: back)),
    );
    await _reload();
  }

  Future<void> _confirmDeleteCamera(UserCamera camera) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Delete camera?', style: TextStyle(color: Colors.white)),
        content: Text(
          '${camera.brand} ${camera.name} will be removed.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await GearStore.removeCamera(camera.id);
      await _reload();
    }
  }

  Future<void> _confirmDeleteLens(UserLens lens) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Delete lens?', style: TextStyle(color: Colors.white)),
        content: Text(
          '${lens.brand} ${lens.name} will be removed.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await GearStore.removeLens(lens.id);
      await _reload();
    }
  }

  Future<void> _confirmDeleteBack(UserBack back) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Delete back?', style: TextStyle(color: Colors.white)),
        content: Text(
          '${back.brand} ${back.name} will be removed.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await GearStore.removeBack(back.id);
      await _reload();
    }
  }

  List<UserLens> _lensesFor(UserCamera camera) {
    return lensesForCamera(camera, _lenses);
  }

  List<UserBack> _backsFor(UserCamera camera) {
    return backsForCamera(camera, _backs);
  }

  String get _fabLabel {
    switch (_tabs.index) {
      case 1:
        return 'Add lens';
      case 2:
        return 'Add back';
      default:
        return 'Add camera';
    }
  }

  VoidCallback get _fabAction {
    switch (_tabs.index) {
      case 1:
        return _addLens;
      case 2:
        return _addBack;
      default:
        return _addCamera;
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
          'Cameras',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: _accent,
          labelColor: _accent,
          unselectedLabelColor: Colors.white54,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'Bodies (${_cameras.length})'),
            Tab(text: 'Lenses (${_lenses.length})'),
            Tab(text: 'Backs (${_backs.length})'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _fabAction,
        backgroundColor: _accent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: Text(
          _fabLabel,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : TabBarView(
              controller: _tabs,
              children: [
                _buildCamerasTab(),
                _buildLensesTab(),
                _buildBacksTab(),
              ],
            ),
    );
  }

  Widget _buildCamerasTab() {
    if (_cameras.isEmpty) {
      return _empty(
        icon: Icons.camera_alt_outlined,
        title: 'No cameras yet',
        subtitle: 'Add bodies you shoot with — brand, mount or fixed lens.',
        actionLabel: 'Add camera',
        onAction: _addCamera,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      itemCount: _cameras.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final cam = _cameras[index];
        final linked = _lensesFor(cam);
        final backs = _backsFor(cam);
        return Material(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _editCamera(cam),
            onLongPress: () => _confirmDeleteCamera(cam),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${cam.brand} ${cam.name}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _confirmDeleteCamera(cam),
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.white38,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    cam.summary,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  if (cam.notes != null && cam.notes!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      cam.notes!,
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                  if (cam.changeableBack) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          backs.isEmpty
                              ? 'No film backs yet'
                              : '${backs.length} film back${backs.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => _addBack(cameraId: cam.id),
                          icon: const Icon(Icons.add, size: 16, color: _accent),
                          label: const Text(
                            'Add back',
                            style: TextStyle(
                              color: _accent,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    if (backs.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final back in backs)
                            GestureDetector(
                              onTap: () => _editBack(back),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1E1E),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Text(
                                  '${back.name}  ·  ${back.summary}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                  if (cam.interchangeableLenses) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          linked.isEmpty
                              ? (cam.mount == null || cam.mount!.trim().isEmpty
                                  ? 'Set a mount to find lenses'
                                  : 'No lenses for mount ${cam.mount}')
                              : '${linked.length} available lens${linked.length == 1 ? '' : 'es'}'
                                  '${cam.mount != null && cam.mount!.trim().isNotEmpty ? ' · ${cam.mount}' : ''}',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => _addLens(cameraId: cam.id),
                          icon: const Icon(Icons.add, size: 16, color: _accent),
                          label: const Text(
                            'Add lens',
                            style: TextStyle(
                              color: _accent,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    if (linked.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final lens in linked)
                            GestureDetector(
                              onTap: () => _editLens(lens),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1E1E),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Text(
                                  '${lens.name}  ·  ${lens.summary}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLensesTab() {
    if (_lenses.isEmpty) {
      return _empty(
        icon: Icons.camera_outlined,
        title: 'No lenses yet',
        subtitle: 'Add primes and zooms, and link them to your cameras.',
        actionLabel: 'Add lens',
        onAction: _addLens,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      itemCount: _lenses.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final lens = _lenses[index];
        final linkedNames = camerasForLens(lens, _cameras)
            .map((c) => '${c.brand} ${c.name}')
            .toList();
        return Material(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _editLens(lens),
            onLongPress: () => _confirmDeleteLens(lens),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${lens.brand} ${lens.name}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          lens.summary,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                        if (linkedNames.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Fits: ${linkedNames.join(', ')}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ] else if (lens.mount != null &&
                            lens.mount!.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'No bodies with mount ${lens.mount}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: () => _confirmDeleteLens(lens),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.white38,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBacksTab() {
    if (_backs.isEmpty) {
      return _empty(
        icon: Icons.view_agenda_outlined,
        title: 'No film backs yet',
        subtitle:
            'For bodies with a changeable back, add 645 and 6×6 backs separately.',
        actionLabel: 'Add back',
        onAction: _addBack,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      itemCount: _backs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final back = _backs[index];
        final linkedNames = camerasForBack(back, _cameras)
            .map((c) => '${c.brand} ${c.name}')
            .toList();
        return Material(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _editBack(back),
            onLongPress: () => _confirmDeleteBack(back),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${back.brand} ${back.name}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          back.summary,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                        if (linkedNames.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Fits: ${linkedNames.join(', ')}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 6),
                          const Text(
                            'Not linked to a body yet',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: () => _confirmDeleteBack(back),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.white38,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _empty({
    required IconData icon,
    required String title,
    required String subtitle,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
