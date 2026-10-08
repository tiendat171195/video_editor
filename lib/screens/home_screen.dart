import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';
import '../services/storage.dart';
import '../util/format.dart';
import 'editor_screen.dart';

/// Projects grouped into (single-level) folders.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<VideoProject>? _projects;
  List<String> _folders = [];

  /// Folder being browsed; null = top level.
  String? _folder;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await Storage.loadProjects();
    final saved = await Storage.loadFolders();
    // Folders referenced by projects always show, even if the list file lost them.
    final all = {...saved, for (final p in list) if (p.folder != null) p.folder!}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (mounted) {
      setState(() {
        _projects = list;
        _folders = all;
        if (_folder != null && !_folders.contains(_folder)) _folder = null;
      });
    }
  }

  // ------------------------------------------------------------------ import

  Future<void> _pickVideo() async {
    final files = await FilePicker.pickFiles(type: FileType.video);
    if (files.isEmpty || !mounted) return;
    final f = files.first;
    final defaultName = f.name.contains('.') ? f.name.substring(0, f.name.lastIndexOf('.')) : f.name;
    final name = await _prompt(title: 'Tên project', initial: defaultName, action: 'Mở');
    if (name == null || !mounted) return;

    setState(() => _importing = true);
    try {
      var src = f.path;
      if (src == null) {
        // Not on local disk (e.g. a content URI): stream it into the cache first.
        final tmp = File('${(await getTemporaryDirectory()).path}/${f.name}');
        await tmp.openWrite().addStream(f.xFile.openRead());
        src = tmp.path;
      }
      final path = await Storage.importVideo(src);
      final project = projectForOutput(path, folder: _folder)..name = name.trim().isEmpty ? defaultName : name.trim();
      await Storage.saveProject(project);
      if (!mounted) return;
      await openEditor(context, project);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Không mở được video: $e')));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
      _reload();
    }
  }

  Future<void> _open(VideoProject p) async {
    await openEditor(context, p);
    _reload();
  }

  // ------------------------------------------------------------------ projects

  Future<void> _renameProject(VideoProject p) async {
    final name = await _prompt(title: 'Đổi tên project', initial: p.name);
    if (name == null || name.trim().isEmpty) return;
    p.name = name.trim();
    await Storage.saveProject(p);
    _reload();
  }

  Future<void> _moveProject(VideoProject p) async {
    const newFolder = '\u0000new';
    const root = '\u0000root';
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text('Chuyển "${p.name}" tới', style: Theme.of(ctx).textTheme.titleMedium)),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Ngoài cùng (không thư mục)'),
            selected: p.folder == null,
            onTap: () => Navigator.pop(ctx, root),
          ),
          for (final f in _folders)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(f),
              selected: p.folder == f,
              onTap: () => Navigator.pop(ctx, f),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Thư mục mới…'),
            onTap: () => Navigator.pop(ctx, newFolder),
          ),
        ]),
      ),
    );
    if (choice == null) return;
    String? target;
    if (choice == newFolder) {
      target = await _createFolder();
      if (target == null) return;
    } else if (choice != root) {
      target = choice;
    }
    p.folder = target;
    await Storage.saveProject(p);
    _reload();
  }

  Future<bool> _confirmDelete(VideoProject p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá project?'),
        content: Text('"${p.name}" cùng toàn bộ note sẽ bị xoá. Các video đã xuất không bị ảnh hưởng.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) await Storage.deleteProject(p, deleteVideo: true);
    return ok == true;
  }

  // ------------------------------------------------------------------ folders

  /// Prompts for a new folder name; returns it, or null if cancelled.
  Future<String?> _createFolder() async {
    final name = (await _prompt(title: 'Thư mục mới', action: 'Tạo'))?.trim();
    if (name == null || name.isEmpty) return null;
    if (!_folders.contains(name)) {
      _folders = [..._folders, name];
      await Storage.saveFolders(_folders);
    }
    await _reload();
    return name;
  }

  Future<void> _renameFolder(String old) async {
    final name = (await _prompt(title: 'Đổi tên thư mục', initial: old))?.trim();
    if (name == null || name.isEmpty || name == old) return;
    for (final p in _projects ?? const <VideoProject>[]) {
      if (p.folder == old) {
        p.folder = name;
        await Storage.saveProject(p);
      }
    }
    await Storage.saveFolders({for (final f in _folders) f == old ? name : f}.toList());
    if (_folder == old) _folder = name;
    _reload();
  }

  Future<void> _deleteFolder(String name) async {
    final inside = (_projects ?? const <VideoProject>[]).where((p) => p.folder == name).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Xoá thư mục "$name"?'),
        content: Text(inside.isEmpty
            ? 'Thư mục đang trống.'
            : '${inside.length} project bên trong sẽ được chuyển ra ngoài, không bị xoá.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá thư mục')),
        ],
      ),
    );
    if (ok != true) return;
    for (final p in inside) {
      p.folder = null;
      await Storage.saveProject(p);
    }
    await Storage.saveFolders(_folders.where((f) => f != name).toList());
    if (_folder == name) _folder = null;
    _reload();
  }

  Future<String?> _prompt({required String title, String initial = '', String action = 'Lưu'}) {
    final ctrl = TextEditingController(text: initial)..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(action)),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    final inFolder = _folder != null;
    final shown = projects?.where((p) => p.folder == _folder).toList();
    final folders = inFolder ? const <String>[] : _folders;

    return PopScope(
      canPop: !inFolder,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _folder = null);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: inFolder ? BackButton(onPressed: () => setState(() => _folder = null)) : null,
          title: Text(_folder ?? 'Video Note'),
          actions: [
            if (inFolder)
              PopupMenuButton<String>(
                onSelected: (v) => v == 'rename' ? _renameFolder(_folder!) : _deleteFolder(_folder!),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Đổi tên thư mục')),
                  PopupMenuItem(value: 'delete', child: Text('Xoá thư mục')),
                ],
              )
            else
              IconButton(tooltip: 'Thư mục mới', icon: const Icon(Icons.create_new_folder_outlined), onPressed: _createFolder),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _importing ? null : _pickVideo,
          icon: _importing
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.video_library_outlined),
          label: Text(_importing ? 'Đang mở…' : 'Mở video'),
        ),
        body: shown == null
            ? const Center(child: CircularProgressIndicator())
            : shown.isEmpty && folders.isEmpty
                ? (inFolder ? const Center(child: Text('Thư mục trống. Bấm "Mở video" để thêm.')) : const _Empty())
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 96),
                      children: [
                        for (final f in folders) _folderTile(f, projects!),
                        if (folders.isNotEmpty && shown.isNotEmpty) const Divider(height: 1),
                        for (final p in shown) _projectTile(p),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _folderTile(String name, List<VideoProject> all) {
    final count = all.where((p) => p.folder == name).length;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.folder)),
      title: Text(name),
      subtitle: Text('$count project'),
      onTap: () => setState(() => _folder = name),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'rename' ? _renameFolder(name) : _deleteFolder(name),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
          PopupMenuItem(value: 'delete', child: Text('Xoá thư mục')),
        ],
      ),
    );
  }

  Widget _projectTile(VideoProject p) {
    final missing = !File(p.videoPath).existsSync();
    return Dismissible(
      key: ValueKey(p.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline),
      ),
      confirmDismiss: (_) => _confirmDelete(p),
      onDismissed: (_) => setState(() => _projects?.remove(p)),
      child: ListTile(
        leading: CircleAvatar(child: Icon(missing ? Icons.error_outline : Icons.movie_outlined)),
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          missing
              ? 'Không còn file video'
              : '${formatMs(p.durationMs)} · ${p.annotations.length} note · ${p.slowMos.length} slow-mo · ${_date(p.updatedAt)}',
        ),
        onTap: missing ? null : () => _open(p),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'rename':
                await _renameProject(p);
              case 'move':
                await _moveProject(p);
              case 'delete':
                if (await _confirmDelete(p)) _reload();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Đổi tên'))),
            PopupMenuItem(value: 'move', child: ListTile(leading: Icon(Icons.drive_file_move_outlined), title: Text('Chuyển thư mục'))),
            PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Xoá'))),
          ],
        ),
      ),
    );
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.edit_note, size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text('Ghi chú trực tiếp trên video', style: t.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Mở một video, bấm phát rồi khoanh vùng, vẽ mũi tên, gõ note hoặc đánh dấu đoạn slow-motion ngay khi đang xem. '
            'Sau đó xuất video có note, cắt, hoặc chuyển đổi định dạng / nén dung lượng.',
            style: t.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }
}
