import 'dart:math' as math;

import '../models/annotation.dart';

/// Pure builders for ffmpeg argument lists. Kept free of Flutter/plugin
/// imports so they can be unit tested on the host.

String fmtSec(int ms) => (ms / 1000.0).toStringAsFixed(3);

// ---------------------------------------------------------------------------
// Trim
// ---------------------------------------------------------------------------

/// Cuts [startMs, endMs) out of [input].
///
/// [accurate] = false copies streams without re-encoding: very fast and
/// lossless, but the cut snaps to the previous keyframe. [accurate] = true
/// re-encodes to H.264/AAC for a frame-exact cut.
List<String> buildTrimArgs({
  required String input,
  required String output,
  required int startMs,
  required int endMs,
  required bool accurate,
}) {
  final args = <String>[
    '-y',
    '-ss', fmtSec(startMs),
    '-i', input,
    '-t', fmtSec(endMs - startMs),
    '-map', '0:v:0?',
    '-map', '0:a:0?',
  ];
  if (accurate) {
    args.addAll([
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '160k',
      '-movflags', '+faststart',
    ]);
  } else {
    args.addAll(['-c', 'copy', '-avoid_negative_ts', 'make_zero']);
  }
  args.add(output);
  return args;
}

// ---------------------------------------------------------------------------
// Convert / compress
// ---------------------------------------------------------------------------

enum OutputFormat {
  mp4('mp4', 'MP4'),
  mov('mov', 'MOV'),
  mkv('mkv', 'MKV'),
  webm('webm', 'WebM'),
  gif('gif', 'GIF (ảnh động)');

  const OutputFormat(this.ext, this.label);
  final String ext;
  final String label;
}

enum VideoCodec {
  h264('H.264 (AVC)'),
  h265('H.265 (HEVC)'),
  vp9('VP9'),
  mpeg4('MPEG-4 Part 2'),
  copy('Giữ nguyên (không encode)');

  const VideoCodec(this.label);
  final String label;
}

enum AudioCodec {
  aac('AAC'),
  opus('Opus'),
  mp3('MP3'),
  copy('Giữ nguyên'),
  none('Bỏ âm thanh');

  const AudioCodec(this.label);
  final String label;
}

enum Quality {
  high('Cao'),
  medium('Trung bình'),
  low('Thấp (file nhỏ)');

  const Quality(this.label);
  final String label;
}

List<VideoCodec> videoCodecsFor(OutputFormat c) => switch (c) {
      OutputFormat.mp4 || OutputFormat.mov => [VideoCodec.h264, VideoCodec.h265, VideoCodec.mpeg4, VideoCodec.copy],
      OutputFormat.mkv => VideoCodec.values,
      OutputFormat.webm => [VideoCodec.vp9],
      OutputFormat.gif => const [],
    };

List<AudioCodec> audioCodecsFor(OutputFormat c) => switch (c) {
      OutputFormat.mp4 || OutputFormat.mov => [AudioCodec.aac, AudioCodec.mp3, AudioCodec.copy, AudioCodec.none],
      OutputFormat.mkv => AudioCodec.values,
      OutputFormat.webm => [AudioCodec.opus, AudioCodec.none],
      OutputFormat.gif => const [AudioCodec.none],
    };

class ConvertOptions {
  const ConvertOptions({
    this.container = OutputFormat.mp4,
    this.videoCodec = VideoCodec.h264,
    this.audioCodec = AudioCodec.aac,
    this.quality = Quality.medium,
    this.targetSizeMb,
    this.fps,
    this.maxHeight,
    this.audioKbps = 128,
    this.fastEncode = true,
  });

  final OutputFormat container;
  final VideoCodec videoCodec;
  final AudioCodec audioCodec;
  final Quality quality;

  /// When set, the video bitrate is derived so the output lands near this size.
  final double? targetSizeMb;

  /// Output frame rate; null keeps the source rate.
  final double? fps;

  /// Downscale so the height is at most this (keeps aspect). Null keeps size.
  final int? maxHeight;
  final int audioKbps;

  /// Faster presets: lower CPU time on the phone at a small size cost.
  final bool fastEncode;

  bool get reencodesVideo => container == OutputFormat.gif || videoCodec != VideoCodec.copy;
}

/// Video bitrate (kbit/s) that makes a [durationMs] clip roughly
/// [targetMb] megabytes, after reserving room for audio and muxing overhead.
int bitrateForTargetSize({required double targetMb, required int durationMs, required int audioKbps}) {
  final seconds = math.max(durationMs / 1000.0, 0.1);
  final totalKbps = targetMb * 8 * 1024 / seconds * 0.97; // ~3% container overhead
  return math.max((totalKbps - audioKbps).floor(), 64);
}

int _crf(VideoCodec codec, Quality q) => switch (codec) {
      VideoCodec.h264 => const {Quality.high: 19, Quality.medium: 23, Quality.low: 28}[q]!,
      VideoCodec.h265 => const {Quality.high: 22, Quality.medium: 27, Quality.low: 31}[q]!,
      VideoCodec.vp9 => const {Quality.high: 28, Quality.medium: 34, Quality.low: 40}[q]!,
      VideoCodec.mpeg4 => const {Quality.high: 3, Quality.medium: 6, Quality.low: 10}[q]!,
      VideoCodec.copy => 0,
    };

String _scaleFilter(int maxHeight) =>
    // Only shrink, never upscale; keep width even for yuv420p encoders.
    "scale=-2:'min($maxHeight,ih)'";

List<String> buildConvertArgs({
  required String input,
  required String output,
  required ConvertOptions o,
  required int durationMs,
  required bool sourceHasAudio,
}) {
  final args = <String>['-y', '-i', input];

  if (o.container == OutputFormat.gif) {
    final fps = o.fps ?? 12;
    final h = o.maxHeight ?? 480;
    args.addAll([
      '-filter_complex',
      "[0:v]fps=${_num(fps)},scale=-2:'min($h,ih)':flags=lanczos,split[a][b];"
          '[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4',
      '-loop', '0',
      output,
    ]);
    return args;
  }

  args.addAll(['-map', '0:v:0?']);
  final keepAudio = sourceHasAudio && o.audioCodec != AudioCodec.none;
  if (keepAudio) args.addAll(['-map', '0:a:0?']);

  // ----- video
  if (o.videoCodec == VideoCodec.copy) {
    args.addAll(['-c:v', 'copy']);
  } else {
    final filters = <String>[
      if (o.maxHeight != null) _scaleFilter(o.maxHeight!),
      if (o.fps != null) 'fps=${_num(o.fps!)}',
    ];
    if (filters.isNotEmpty) args.addAll(['-vf', filters.join(',')]);

    final target = o.targetSizeMb == null
        ? null
        : bitrateForTargetSize(
            targetMb: o.targetSizeMb!,
            durationMs: durationMs,
            audioKbps: keepAudio ? o.audioKbps : 0,
          );

    args.addAll(_videoCodecArgs(o, target));
  }

  // ----- audio
  args.addAll(keepAudio ? _audioCodecArgs(o.audioCodec, o.audioKbps) : ['-an']);
  args.addAll(_containerArgs(o));
  args.add(output);
  return args;
}

/// Encoder arguments for [o]'s video codec; [targetKbps] switches from
/// constant quality to a bitrate aimed at a file size.
List<String> _videoCodecArgs(ConvertOptions o, int? targetKbps) {
  final codec = o.videoCodec == VideoCodec.copy ? VideoCodec.h264 : o.videoCodec;
  final args = <String>[];
  switch (codec) {
    case VideoCodec.h264 || VideoCodec.copy:
      args.addAll(['-c:v', 'libx264', '-preset', o.fastEncode ? 'veryfast' : 'medium']);
    case VideoCodec.h265:
      args.addAll(['-c:v', 'libx265', '-preset', o.fastEncode ? 'veryfast' : 'medium']);
      if (o.container == OutputFormat.mp4 || o.container == OutputFormat.mov) {
        args.addAll(['-tag:v', 'hvc1']); // plays in QuickTime / iOS Photos
      }
    case VideoCodec.vp9:
      args.addAll([
        '-c:v', 'libvpx-vp9', '-row-mt', '1',
        '-deadline', o.fastEncode ? 'realtime' : 'good',
        '-cpu-used', o.fastEncode ? '8' : '4',
      ]);
    case VideoCodec.mpeg4:
      args.addAll(['-c:v', 'mpeg4']);
  }
  if (targetKbps != null) {
    args.addAll(['-b:v', '${targetKbps}k', '-maxrate', '${(targetKbps * 1.5).round()}k', '-bufsize', '${targetKbps * 2}k']);
  } else if (codec == VideoCodec.mpeg4) {
    args.addAll(['-q:v', '${_crf(codec, o.quality)}']);
  } else {
    args.addAll(['-crf', '${_crf(codec, o.quality)}']);
    if (codec == VideoCodec.vp9) args.addAll(['-b:v', '0']);
  }
  args.addAll(['-pix_fmt', 'yuv420p']);
  return args;
}

List<String> _audioCodecArgs(AudioCodec codec, int kbps) => switch (codec) {
      AudioCodec.aac => ['-c:a', 'aac', '-b:a', '${kbps}k'],
      AudioCodec.opus => ['-c:a', 'libopus', '-b:a', '${kbps}k'],
      AudioCodec.mp3 => ['-c:a', 'libmp3lame', '-b:a', '${kbps}k'],
      AudioCodec.copy => ['-c:a', 'copy'],
      AudioCodec.none => ['-an'],
    };

List<String> _containerArgs(ConvertOptions o) =>
    o.container == OutputFormat.mp4 || o.container == OutputFormat.mov ? ['-movflags', '+faststart'] : const [];

String _num(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
}

// ---------------------------------------------------------------------------
// Export with burned-in notes and slow motion
// ---------------------------------------------------------------------------

/// Frame rate used to render note appear animations for export.
const kOverlayFps = 30;

/// One note pre-rendered as a PNG sequence ([path] holds a `%03d` pattern,
/// frames numbered from 0), placed at ([x], [y]) in video pixels.
///
/// The frames play the appear animation; the last frame is then held until
/// [endMs], fading out over the final [fadeOutMs].
class OverlayImage {
  const OverlayImage({
    required this.path,
    required this.x,
    required this.y,
    required this.startMs,
    required this.endMs,
    this.frameCount = 1,
    this.fadeOutMs = 0,
  });

  final String path;
  final int x;
  final int y;
  final int startMs;
  final int endMs;
  final int frameCount;
  final int fadeOutMs;
}

/// One contiguous range of the output timeline played at [speed].
class SpeedRange {
  const SpeedRange(this.startMs, this.endMs, this.speed);
  final int startMs;
  final int endMs;
  final double speed;

  @override
  String toString() => 'SpeedRange($startMs-$endMs @$speed)';
}

/// Splits [0, durationMs) into consecutive ranges, filling the gaps between
/// slow-mo segments with normal-speed ranges.
List<SpeedRange> speedRanges(List<SlowMoSegment> slowMos, int durationMs) {
  final sorted = [...slowMos]..sort((a, b) => a.startMs.compareTo(b.startMs));
  final out = <SpeedRange>[];
  var cursor = 0;
  for (final s in sorted) {
    final start = s.startMs.clamp(cursor, durationMs);
    final end = s.endMs.clamp(start, durationMs);
    if (end - start < 50) continue; // ignore slivers
    if (start > cursor) out.add(SpeedRange(cursor, start, 1.0));
    out.add(SpeedRange(start, end, s.speed));
    cursor = end;
  }
  if (cursor < durationMs) out.add(SpeedRange(cursor, durationMs, 1.0));
  return out;
}

/// atempo only accepts factors in [0.5, 100], so chain it for slower speeds.
String atempoChain(double speed) {
  final parts = <String>[];
  var remaining = speed;
  while (remaining < 0.5) {
    parts.add('atempo=0.5');
    remaining /= 0.5;
  }
  if ((remaining - 1.0).abs() > 1e-6) parts.add('atempo=${_num(remaining)}');
  return parts.isEmpty ? 'anull' : parts.join(',');
}

/// Builds the export command: overlays every note PNG during its time window
/// (on the source timeline), then re-times slow-mo ranges and concatenates.
List<String> buildExportArgs({
  required String input,
  required String output,
  required List<OverlayImage> overlays,
  required List<SlowMoSegment> slowMos,
  required int durationMs,
  required bool hasAudio,
  ConvertOptions options = const ConvertOptions(quality: Quality.high),
}) {
  final o = options;
  final gif = o.container == OutputFormat.gif;
  final wantAudio = hasAudio && !gif && o.audioCodec != AudioCodec.none;
  final args = <String>['-y', '-i', input];
  for (final o in overlays) {
    args.addAll(['-f', 'image2', '-framerate', '$kOverlayFps', '-start_number', '0', '-i', o.path]);
  }

  final graph = <String>[];
  var v = '0:v';
  for (var i = 0; i < overlays.length; i++) {
    final o = overlays[i];
    // Hold the last animation frame for the rest of the window, fade it out,
    // then shift the clip to start at the note's time.
    final visibleMs = o.endMs - o.startMs;
    final animMs = (o.frameCount * 1000 / kOverlayFps).round();
    final holdMs = visibleMs - animMs;
    final chain = <String>[
      if (holdMs > 0) 'tpad=stop_mode=clone:stop_duration=${fmtSec(holdMs)}',
      if (o.fadeOutMs > 0) 'fade=t=out:st=${fmtSec(visibleMs - o.fadeOutMs)}:d=${fmtSec(o.fadeOutMs)}:alpha=1',
      'setpts=PTS-STARTPTS+${fmtSec(o.startMs)}/TB',
    ];
    graph.add('[${i + 1}:v]${chain.join(',')}[on$i]');
    final next = 'ov$i';
    graph.add("[$v][on$i]overlay=${o.x}:${o.y}:eof_action=pass:"
        "enable='between(t,${fmtSec(o.startMs)},${fmtSec(o.endMs)})'[$next]");
    v = next;
  }

  final ranges = speedRanges(slowMos, durationMs);
  final needsRetime = ranges.any((r) => r.speed != 1.0);

  String? aOut = wantAudio ? '0:a' : null;
  if (needsRetime) {
    final n = ranges.length;
    graph.add('[$v]split=$n${[for (var i = 0; i < n; i++) '[vs$i]'].join()}');
    if (wantAudio) {
      graph.add('[0:a]asplit=$n${[for (var i = 0; i < n; i++) '[as$i]'].join()}');
    }
    final concatInputs = StringBuffer();
    for (var i = 0; i < n; i++) {
      final r = ranges[i];
      final pts = r.speed == 1.0 ? 'PTS-STARTPTS' : '(PTS-STARTPTS)/${_num(r.speed)}';
      graph.add('[vs$i]trim=start=${fmtSec(r.startMs)}:end=${fmtSec(r.endMs)},setpts=$pts[vc$i]');
      concatInputs.write('[vc$i]');
      if (wantAudio) {
        graph.add('[as$i]atrim=start=${fmtSec(r.startMs)}:end=${fmtSec(r.endMs)},'
            'asetpts=PTS-STARTPTS,${atempoChain(r.speed)}[ac$i]');
        concatInputs.write('[ac$i]');
      }
    }
    graph.add('${concatInputs}concat=n=$n:v=1:a=${wantAudio ? 1 : 0}[vcat]${wantAudio ? '[aout]' : ''}');
    v = 'vcat';
    if (wantAudio) aOut = 'aout';
  }

  // Output format: resize / frame rate, or the GIF palette pipeline.
  if (gif) {
    final fps = o.fps ?? 12;
    final h = o.maxHeight ?? 480;
    graph.add("[$v]fps=${_num(fps)},scale=-2:'min($h,ih)':flags=lanczos,split[ga][gb];"
        '[ga]palettegen=stats_mode=diff[gp];[gb][gp]paletteuse=dither=bayer:bayer_scale=4[vout]');
  } else {
    final post = [
      if (o.maxHeight != null) _scaleFilter(o.maxHeight!),
      if (o.fps != null) 'fps=${_num(o.fps!)}',
    ];
    if (post.isNotEmpty) {
      graph.add('[$v]${post.join(',')}[vout]');
    } else if (graph.isEmpty) {
      graph.add('[0:v]null[vout]');
    } else {
      // Rename the final label instead of adding a no-op filter.
      graph[graph.length - 1] = graph.last.replaceFirst('[$v]', '[vout]');
    }
  }

  args.addAll(['-filter_complex', graph.join(';'), '-map', '[vout]']);
  if (gif) {
    args.addAll(['-loop', '0', output]);
    return args;
  }
  if (aOut != null) args.addAll(['-map', aOut == '0:a' ? '0:a:0' : '[$aOut]']);

  final outMs = exportedDurationMs(slowMos, durationMs);
  final target = o.targetSizeMb == null
      ? null
      : bitrateForTargetSize(targetMb: o.targetSizeMb!, durationMs: outMs, audioKbps: aOut != null ? o.audioKbps : 0);
  args.addAll(_videoCodecArgs(o, target));
  if (aOut == null) {
    args.add('-an');
  } else {
    // Filtered (re-timed) audio can't be stream-copied.
    final codec = o.audioCodec == AudioCodec.copy && aOut != '0:a'
        ? (o.container == OutputFormat.webm ? AudioCodec.opus : AudioCodec.aac)
        : o.audioCodec;
    args.addAll(_audioCodecArgs(codec, o.audioKbps));
  }
  args.addAll(_containerArgs(o));
  args.add(output);
  return args;
}

/// Duration of the exported clip once slow-mo ranges are stretched.
int exportedDurationMs(List<SlowMoSegment> slowMos, int durationMs) {
  var total = 0.0;
  for (final r in speedRanges(slowMos, durationMs)) {
    total += (r.endMs - r.startMs) / r.speed;
  }
  return total.round();
}
