// End-to-end check that a note lands on the same normalized spot in the
// exported video as in the editor, for landscape, portrait and rotated input.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_note/models/annotation.dart';
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

  for (final c in [
    (name: 'landscape', w: 320, h: 180, rotate: 0),
    (name: 'portrait', w: 180, h: 320, rotate: 0),
    (name: 'rotated 90', w: 320, h: 180, rotate: 90),
  ]) {
    test('note position matches in export: ${c.name}', () async {
      final dir = await Directory.systemTemp.createTemp('vn_pos');
      addTearDown(() => dir.delete(recursive: true));
      final src = '${dir.path}/src.mp4';
      // Plain black video so the red note is easy to find.
      await _ff(['-y', '-f', 'lavfi', '-i', 'color=c=black:size=${c.w}x${c.h}:rate=30:duration=1',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '${dir.path}/plain.mp4']);
      await _ff(['-y', if (c.rotate != 0) ...['-display_rotation', '${c.rotate}'], '-i', '${dir.path}/plain.mp4', '-c', 'copy', src]);

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
}
