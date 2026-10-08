import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/project.dart';

/// Locations and persistence for projects and exported files.
class Storage {
  const Storage._();

  static Future<Directory> _dir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$name');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// Where exported / converted / trimmed videos are written.
  static Future<Directory> outputDir() async {
    if (Platform.isAndroid) {
      // App-specific external storage is browsable over USB and needs no permission.
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dir = Directory('${ext.path}/VideoNote');
        if (!dir.existsSync()) await dir.create(recursive: true);
        return dir;
      }
    }
    return _dir('exports');
  }

  /// Scratch space for rendered overlay PNGs.
  static Future<Directory> tempDir(String name) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/$name');
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    return dir;
  }

  /// Copies a picked video into app storage so projects survive the picker's
  /// cache being cleared.
  static Future<String> importVideo(String sourcePath) async {
    final dir = await _dir('videos');
    final name = sourcePath.split(Platform.pathSeparator).last;
    final dest = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
    final src = File(sourcePath);
    final cache = (await getTemporaryDirectory()).parent.path;
    if (sourcePath.startsWith(cache)) {
      // The picker already made a private copy; move it instead of doubling storage.
      try {
        await src.rename(dest.path);
        return dest.path;
      } on FileSystemException {
        // Different filesystem: fall back to copying.
      }
    }
    await src.copy(dest.path);
    return dest.path;
  }

  static Future<String> newOutputPath(String sourcePath, String suffix, String ext) async {
    final dir = await outputDir();
    var base = sourcePath.split(Platform.pathSeparator).last;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    base = base.replaceFirst(RegExp(r'^\d{13}_'), ''); // drop our import prefix
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.\-T]'), '').substring(0, 14);
    return '${dir.path}/${base}_${suffix}_$stamp.$ext';
  }

  // ----- projects

  static Future<void> saveProject(VideoProject p) async {
    p.updatedAt = DateTime.now();
    final dir = await _dir('projects');
    final file = File('${dir.path}/${p.id}.json');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(p.toJson()));
    await tmp.rename(file.path);
  }

  static Future<List<VideoProject>> loadProjects() async {
    final dir = await _dir('projects');
    final out = <VideoProject>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        out.add(VideoProject.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // Ignore corrupt project files rather than failing the whole list.
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  // ----- folders (one level; a folder exists if listed here or used by a project)

  static Future<File> _foldersFile() async => File('${(await getApplicationDocumentsDirectory()).path}/folders.json');

  static Future<List<String>> loadFolders() async {
    final f = await _foldersFile();
    if (!f.existsSync()) return [];
    try {
      return [for (final n in jsonDecode(await f.readAsString()) as List) n as String];
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveFolders(List<String> names) async {
    final f = await _foldersFile();
    await f.writeAsString(jsonEncode(names));
  }

  static Future<void> deleteProject(VideoProject p, {bool deleteVideo = false}) async {
    final dir = await _dir('projects');
    final f = File('${dir.path}/${p.id}.json');
    if (f.existsSync()) await f.delete();
    if (deleteVideo) {
      final videos = await _dir('videos');
      final v = File(p.videoPath);
      // Only delete copies we own, never user files elsewhere.
      if (v.path.startsWith(videos.path) && v.existsSync()) await v.delete();
    }
  }
}
