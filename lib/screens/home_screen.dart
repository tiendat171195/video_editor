import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';
import '../services/storage.dart';
import '../util/format.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<VideoProject>? _projects;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await Storage.loadProjects();
    if (mounted) setState(() => _projects = list);
  }

  Future<void> _pickVideo() async {
    final files = await FilePicker.pickFiles(type: FileType.video);
    if (files.isEmpty || !mounted) return;
    setState(() => _importing = true);
    try {
      final f = files.first;
      var src = f.path;
      if (src == null) {
        // Not on local disk (e.g. a content URI): stream it into the cache first.
        final tmp = File('${(await getTemporaryDirectory()).path}/${f.name}');
        await tmp.openWrite().addStream(f.xFile.openRead());
        src = tmp.path;
      }
      final path = await Storage.importVideo(src);
      final project = projectForOutput(path)..name = f.name;
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

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    return Scaffold(
      appBar: AppBar(title: const Text('Video Note')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _pickVideo,
        icon: _importing
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.video_library_outlined),
        label: Text(_importing ? 'Đang mở…' : 'Mở video'),
      ),
      body: projects == null
          ? const Center(child: CircularProgressIndicator())
          : projects.isEmpty
              ? const _Empty()
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: projects.length,
                    itemBuilder: (_, i) {
                      final p = projects[i];
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
                        onDismissed: (_) => setState(() => projects.removeAt(i)),
                        child: ListTile(
                          leading: CircleAvatar(child: Icon(missing ? Icons.error_outline : Icons.movie_outlined)),
                          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            missing
                                ? 'Không còn file video'
                                : '${formatMs(p.durationMs)} · ${p.annotations.length} note · ${p.slowMos.length} slow-mo · '
                                    '${_date(p.updatedAt)}',
                          ),
                          onTap: missing ? null : () => _open(p),
                        ),
                      );
                    },
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
