// Runs the generated ffmpeg commands against a real ffmpeg binary, when one is
// installed on the host, to catch invalid filter graphs or option combos.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_note/models/annotation.dart';
import 'package:video_note/services/ffmpeg_commands.dart';

bool get _hasFfmpeg {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  final skip = _hasFfmpeg ? false : 'ffmpeg not installed';
  late Directory dir;
  late String src;
  late String png;

  Future<void> ff(List<String> args) async {
    final r = await Process.run('ffmpeg', ['-hide_banner', '-loglevel', 'error', ...args]);
    expect(r.exitCode, 0, reason: '${args.join(' ')}\n${r.stderr}');
  }

  Future<double> durationOf(String path) async {
    final r = await Process.run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path]);
    return double.parse((r.stdout as String).trim());
  }

  setUpAll(() async {
    if (skip != false) return;
    dir = await Directory.systemTemp.createTemp('vn_ff');
    src = '${dir.path}/src.mp4';
    png = '${dir.path}/note.png';
    await ff(['-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=30:duration=4',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4', '-c:v', 'libx264', '-g', '15', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', src]);
    await ff(['-y', '-f', 'lavfi', '-i', 'color=c=red@0.5:size=60x40,format=rgba', '-frames:v', '1', png]);
  });

  tearDownAll(() async {
    if (skip == false) await dir.delete(recursive: true);
  });

  test('trim fast + accurate', () async {
    for (final accurate in [false, true]) {
      final out = '${dir.path}/trim_$accurate.mp4';
      await ff(buildTrimArgs(input: src, output: out, startMs: 1000, endMs: 3000, accurate: accurate));
      expect(await durationOf(out), closeTo(2.0, 0.6));
    }
  }, skip: skip);

  test('convert variants', () async {
    final cases = <String, ConvertOptions>{
      'h264.mp4': const ConvertOptions(fps: 15, maxHeight: 120),
      'h265.mp4': const ConvertOptions(videoCodec: VideoCodec.h265, quality: Quality.low),
      'vp9.webm': const ConvertOptions(container: OutputFormat.webm, videoCodec: VideoCodec.vp9, audioCodec: AudioCodec.opus),
      'mpeg4.mkv': const ConvertOptions(container: OutputFormat.mkv, videoCodec: VideoCodec.mpeg4, audioCodec: AudioCodec.mp3),
      'copy.mkv': const ConvertOptions(container: OutputFormat.mkv, videoCodec: VideoCodec.copy, audioCodec: AudioCodec.copy),
      'target.mp4': const ConvertOptions(targetSizeMb: 0.2),
      'mute.mov': const ConvertOptions(container: OutputFormat.mov, audioCodec: AudioCodec.none),
      'anim.gif': const ConvertOptions(container: OutputFormat.gif, fps: 10, maxHeight: 120),
    };
    for (final e in cases.entries) {
      final out = '${dir.path}/conv_${e.key}';
      await ff(buildConvertArgs(input: src, output: out, o: e.value, durationMs: 4000, sourceHasAudio: true));
      expect(File(out).lengthSync(), greaterThan(0), reason: e.key);
    }
  }, skip: skip);

  test('export with overlays and slow motion', () async {
    final out = '${dir.path}/export.mp4';
    final slow = [SlowMoSegment(startMs: 1000, endMs: 2000, speed: 0.25)];
    await ff(buildExportArgs(
      input: src,
      output: out,
      overlays: [
        OverlayImage(path: png, x: 10, y: 10, startMs: 0, endMs: 1500),
        OverlayImage(path: png, x: 200, y: 150, startMs: 2000, endMs: 4000),
      ],
      slowMos: slow,
      durationMs: 4000,
      hasAudio: true,
    ));
    expect(await durationOf(out), closeTo(exportedDurationMs(slow, 4000) / 1000, 0.3));
  }, skip: skip);

  test('export overlays only, no audio', () async {
    final silent = '${dir.path}/silent.mp4';
    await ff(['-y', '-i', src, '-an', '-c:v', 'copy', silent]);
    final out = '${dir.path}/export2.mp4';
    await ff(buildExportArgs(
      input: silent,
      output: out,
      overlays: [OverlayImage(path: png, x: 0, y: 0, startMs: 500, endMs: 1000)],
      slowMos: const [],
      durationMs: 4000,
      hasAudio: false,
    ));
    expect(await durationOf(out), closeTo(4.0, 0.3));
  }, skip: skip);
}
