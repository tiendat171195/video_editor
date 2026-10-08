import 'package:flutter_test/flutter_test.dart';
import 'package:video_note/models/annotation.dart';
import 'package:video_note/services/ffmpeg_commands.dart';

void main() {
  group('trim', () {
    test('fast trim stream-copies with duration', () {
      final args = buildTrimArgs(input: 'in.mp4', output: 'out.mp4', startMs: 1500, endMs: 4000, accurate: false);
      expect(args.sublist(0, 7), ['-y', '-ss', '1.500', '-i', 'in.mp4', '-t', '2.500']);
      expect(args, containsAllInOrder(['-c', 'copy']));
      expect(args.last, 'out.mp4');
    });

    test('accurate trim re-encodes', () {
      final args = buildTrimArgs(input: 'in.mp4', output: 'out.mp4', startMs: 0, endMs: 1000, accurate: true);
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, isNot(contains('copy')));
    });
  });

  group('convert', () {
    test('target size computes bitrate', () {
      // 10 MB over 80 s ≈ 1024 kbps total; minus 128 audio and overhead.
      final kbps = bitrateForTargetSize(targetMb: 10, durationMs: 80000, audioKbps: 128);
      expect(kbps, inInclusiveRange(850, 900));
    });

    test('h265 in mp4 gets hvc1 tag and scale/fps filters', () {
      final args = buildConvertArgs(
        input: 'in.mov',
        output: 'out.mp4',
        o: const ConvertOptions(videoCodec: VideoCodec.h265, fps: 30, maxHeight: 720),
        durationMs: 10000,
        sourceHasAudio: true,
      );
      expect(args, containsAllInOrder(['-c:v', 'libx265']));
      expect(args, containsAllInOrder(['-tag:v', 'hvc1']));
      expect(args[args.indexOf('-vf') + 1], "scale=-2:'min(720,ih)',fps=30");
    });

    test('no audio source drops audio', () {
      final args = buildConvertArgs(
        input: 'in.mp4',
        output: 'out.webm',
        o: const ConvertOptions(container: OutputFormat.webm, videoCodec: VideoCodec.vp9, audioCodec: AudioCodec.opus),
        durationMs: 10000,
        sourceHasAudio: false,
      );
      expect(args, contains('-an'));
      expect(args, isNot(contains('libopus')));
    });

    test('codec lists respect container', () {
      expect(videoCodecsFor(OutputFormat.webm), [VideoCodec.vp9]);
      expect(audioCodecsFor(OutputFormat.mp4), isNot(contains(AudioCodec.opus)));
    });
  });

  group('export', () {
    test('speed ranges fill gaps and clamp', () {
      final r = speedRanges([
        SlowMoSegment(startMs: 2000, endMs: 3000, speed: 0.5),
        SlowMoSegment(startMs: 8000, endMs: 12000, speed: 0.25),
      ], 10000);
      expect(r.map((e) => [e.startMs, e.endMs, e.speed]).toList(), [
        [0, 2000, 1.0],
        [2000, 3000, 0.5],
        [3000, 8000, 1.0],
        [8000, 10000, 0.25],
      ]);
      expect(exportedDurationMs([SlowMoSegment(startMs: 2000, endMs: 3000, speed: 0.5)], 10000), 11000);
    });

    test('atempo chains below 0.5', () {
      expect(atempoChain(1), 'anull');
      expect(atempoChain(0.5), 'atempo=0.5');
      expect(atempoChain(0.25), 'atempo=0.5,atempo=0.5');
      expect(atempoChain(0.125), 'atempo=0.5,atempo=0.5,atempo=0.5');
      expect(atempoChain(0.75), 'atempo=0.75');
    });

    test('overlays only', () {
      final args = buildExportArgs(
        input: 'in.mp4',
        output: 'out.mp4',
        overlays: const [OverlayImage(path: 'a.png', x: 10, y: 20, startMs: 1000, endMs: 4000)],
        slowMos: const [],
        durationMs: 10000,
        hasAudio: true,
      );
      final graph = args[args.indexOf('-filter_complex') + 1];
      expect(graph, "[0:v][1:v]overlay=10:20:eof_action=repeat:enable='between(t,1.000,4.000)'[vout]");
      expect(args, containsAllInOrder(['-map', '[vout]', '-map', '0:a:0']));
    });

    test('slow motion splits and concatenates', () {
      final args = buildExportArgs(
        input: 'in.mp4',
        output: 'out.mp4',
        overlays: const [],
        slowMos: [SlowMoSegment(startMs: 1000, endMs: 2000, speed: 0.5)],
        durationMs: 3000,
        hasAudio: true,
      );
      final graph = args[args.indexOf('-filter_complex') + 1];
      expect(graph, contains('[0:v]split=3[vs0][vs1][vs2]'));
      expect(graph, contains('setpts=(PTS-STARTPTS)/0.5'));
      expect(graph, contains('concat=n=3:v=1:a=1[vout][aout]'));
      expect(args, containsAllInOrder(['-map', '[vout]', '-map', '[aout]']));
    });
  });
}
