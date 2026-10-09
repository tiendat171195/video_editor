// End-to-end check that a note lands on the same normalized spot in the
// exported video as in the editor, for landscape, portrait and rotated input.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_note/models/annotation.dart';
import 'package:video_note/models/media_info.dart';
import 'package:video_note/models/zoom.dart';
import 'package:video_note/services/ffmpeg_commands.dart';
import 'package:video_note/services/overlay_renderer.dart';

bool get _hasFfmpeg {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> _ff(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-hide_banner', '-loglevel', 'error', ...args]);
  expect(r.exitCode, 0, reason: '${args.join(' ')}\n${r.stderr}');
}

/// RGB of the pixel at ([x], [y]) in the frame at 0.5 s.
Future<List<int>> _pixel(String video, int x, int y) async {
  final r = await Process.run('ffmpeg', [
    '-v', 'error', '-ss', '0.5', '-i', video, '-frames:v', '1',
    '-vf', 'format=rgb24,crop=1:1:$x:$y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
  ], stdoutEncoding: null);
  return (r.stdout as List<int>).take(3).toList();
}

void main() {
  final skip = _hasFfmpeg ? false : 'ffmpeg not installed';

  /// Clockwise upright rotation, read the way the app reads it (ffprobe).
  Future<int> uprightRotationOf(String path) async {
    final r = await Process.run('ffprobe', [
      '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream_side_data=rotation', '-of', 'csv=p=0', path,
    ]);
    final raw = (r.stdout as String).trim();
    final rot = raw.isEmpty ? 0 : int.parse(raw.split('\n').first);
    return MediaInfo(durationMs: 0, width: 1, height: 1, rotation: rot).uprightRotation;
  }

  for (final c in [
    (name: 'landscape', w: 320, h: 180, rotate: 0),
    (name: 'portrait', w: 180, h: 320, rotate: 0),
    (name: 'rotated 90', w: 320, h: 180, rotate: 90),
    (name: 'rotated -90', w: 320, h: 180, rotate: -90),
    (name: 'rotated 180', w: 320, h: 180, rotate: 180),
  ]) {
    test('note position matches in export: ${c.name}', () async {
      final dir = await Directory.systemTemp.createTemp('vn_pos');
      addTearDown(() => dir.delete(recursive: true));
      final src = '${dir.path}/src.mp4';
      // Plain black video so the red note is easy to find.
      await _ff(['-y', '-f', 'lavfi', '-i', 'color=c=black:size=${c.w}x${c.h}:rate=30:duration=1',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '${dir.path}/plain.mp4']);
      await _ff(['-y', if (c.rotate != 0) ...['-display_rotation', '${c.rotate}'], '-i', '${dir.path}/plain.mp4', '-c', 'copy', src]);

      final rotation = await uprightRotationOf(src);
      // Upright frame size, as the editor computes it.
      final swap = c.rotate % 180 != 0;
      final fw = swap ? c.h : c.w;
      final fh = swap ? c.w : c.h;

      // A thick red rectangle from 25%..75% horizontally, 40%..60% vertically.
      final note = Annotation(
        id: 'r',
        type: AnnotationType.rect,
        startMs: 0,
        durationMs: 1000,
        color: 0xFFFF0000,
        strokeWidth: 0.03,
        points: const [Offset(0.25, 0.4), Offset(0.75, 0.6)],
      );
      final overlays = await renderOverlays(
        annotations: [note],
        videoWidth: fw,
        videoHeight: fh,
        outDir: dir,
        durationMs: 1000,
      );
      final out = '${dir.path}/out.mp4';
      await _ff(buildExportArgs(
        input: src,
        output: out,
        overlays: overlays,
        slowMos: const [],
        durationMs: 1000,
        hasAudio: false,
        rotation: rotation,
      ));

      // Left edge of the rectangle at (25%, 50%) is red; the centre is not.
      final edge = await _pixel(out, (fw * 0.25).round(), (fh * 0.5).round());
      final centre = await _pixel(out, (fw * 0.5).round(), (fh * 0.5).round());
      final top = await _pixel(out, (fw * 0.5).round(), (fh * 0.4).round());
      expect(edge[0], greaterThan(150), reason: 'left edge should be red, got $edge');
      expect(top[0], greaterThan(150), reason: 'top edge should be red, got $top');
      expect(centre[0], lessThan(60), reason: 'inside should be black, got $centre');
    }, skip: skip);
  }

  for (final rot in [0, 90]) {
    test('zoomed export shows exactly the chosen region (rotated $rot)', () async {
      final dir = await Directory.systemTemp.createTemp('vn_zoom');
      addTearDown(() => dir.delete(recursive: true));
      final plain = '${dir.path}/plain.mp4';
      final src = '${dir.path}/src.mp4';
      await _ff(['-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=30:duration=4',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', plain]);
      await _ff(['-y', if (rot != 0) ...['-display_rotation', '$rot'], '-i', plain, '-c', 'copy', src]);
      final rotation = await uprightRotationOf(src);
      // Upright (displayed) frame and the zoom chosen on it.
      final (uw, uh) = rotation % 180 == 90 ? (180, 320) : (320, 180);
      final view = (cx: 0.75, cy: 0.25, scale: 2.0);
      final out = '${dir.path}/out.mp4';
      await _ff(buildExportArgs(
        input: src,
        output: out,
        overlays: const [],
        slowMos: const [],
        zooms: [ZoomSegment(startMs: 1000, endMs: 3000, scale: view.scale, cx: view.cx, cy: view.cy)],
        frameWidth: uw,
        frameHeight: uh,
        fps: 30,
        durationMs: 4000,
        hasAudio: false,
        rotation: rotation,
      ));
      // Both inputs are auto-rotated here, i.e. compared as a player shows them.
      final cw = uw ~/ 2, ch = uh ~/ 2;
      final x = (uw * view.cx - cw / 2).round(), y = (uh * view.cy - ch / 2).round();
      final r = await Process.run('ffmpeg', [
        '-hide_banner', '-ss', '2', '-i', out, '-ss', '2', '-i', src,
        '-filter_complex', '[1:v]crop=$cw:$ch:$x:$y,scale=$uw:$uh[ref];[0:v][ref]psnr',
        '-frames:v', '1', '-f', 'null', '-',
      ]);
      final m = RegExp(r'average:([0-9.]+)').firstMatch(r.stderr as String);
      expect(m, isNotNull, reason: r.stderr as String);
      expect(double.parse(m!.group(1)!), greaterThan(28));
    }, skip: skip);
  }
}
