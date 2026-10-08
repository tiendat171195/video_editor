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

    test('overlays hold the last frame, fade out and start on time', () {
      final args = buildExportArgs(
        input: 'in.mp4',
        output: 'out.mp4',
        overlays: const [
          OverlayImage(path: 'a_%03d.png', x: 10, y: 20, startMs: 1000, endMs: 4000, frameCount: 15, fadeOutMs: 250),
        ],
        slowMos: const [],
        durationMs: 10000,
        hasAudio: true,
      );
      expect(args, containsAllInOrder(['-f', 'image2', '-framerate', '30', '-start_number', '0', '-i', 'a_%03d.png']));
      final graph = args[args.indexOf('-filter_complex') + 1];
      expect(
        graph,
        '[1:v]tpad=stop_mode=clone:stop_duration=2.500,fade=t=out:st=2.750:d=0.250:alpha=1,'
        'setpts=PTS-STARTPTS+1.000/TB[on0];'
        "[0:v][on0]overlay=10:20:eof_action=pass:enable='between(t,1.000,4.000)'[vout]",
      );
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

  test('export applies output options after notes and slow motion', () {
    final args = buildExportArgs(
      input: 'in.mp4',
      output: 'out.mkv',
      overlays: const [OverlayImage(path: 'a_%03d.png', x: 0, y: 0, startMs: 0, endMs: 1000)],
      slowMos: [SlowMoSegment(startMs: 0, endMs: 1000, speed: 0.5)],
      durationMs: 2000,
      hasAudio: true,
      options: const ConvertOptions(
        container: OutputFormat.mkv,
        videoCodec: VideoCodec.copy,
        audioCodec: AudioCodec.copy,
        maxHeight: 720,
        fps: 30,
      ),
    );
    final graph = args[args.indexOf('-filter_complex') + 1];
    expect(graph, contains("concat=n=2:v=1:a=1[vcat][aout];[vcat]scale=-2:'min(720,ih)',fps=30[vout]"));
    expect(args, containsAllInOrder(['-c:v', 'libx264']), reason: 'cannot stream-copy filtered video');
    expect(args, containsAllInOrder(['-c:a', 'aac']), reason: 'cannot stream-copy re-timed audio');
  });

  test('gif export runs the palette pipeline and drops audio', () {
    final args = buildExportArgs(
      input: 'in.mp4',
      output: 'out.gif',
      overlays: const [],
      slowMos: const [],
      durationMs: 2000,
      hasAudio: true,
      options: const ConvertOptions(container: OutputFormat.gif),
    );
    final graph = args[args.indexOf('-filter_complex') + 1];
    expect(graph, startsWith('[0:v]fps=12,'));
    expect(graph, endsWith('paletteuse=dither=bayer:bayer_scale=4[vout]'));
    expect(args, isNot(contains('-c:a')));
    expect(args.sublist(args.length - 3), ['-loop', '0', 'out.gif']);
  });
}
