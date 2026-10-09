import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'ffmpeg_commands.dart';
import 'ffmpeg_service.dart';

/// Low-resolution JPEG frames of a video, extracted in the background, so
/// scrubbing can show the frame under the finger instantly instead of
/// waiting for the player to finish each (slow, keyframe-bound) seek.
class ScrubFrames {
  ScrubFrames._(this._dir, this.fps);

  final Directory _dir;

  /// Frames per second of video time that were extracted.
  final double fps;
  FfmpegJob? _job;
  bool _done = false;

  /// At most this many frames are extracted, so long videos get a lower rate.
  static const _maxFrames = 2400;
  static const _height = 270;

  static Future<ScrubFrames> start({
    required String videoPath,
    required String cacheKey,
    required int durationMs,
    int rotation = 0,
  }) async {
    final secs = durationMs / 1000.0;
    final fps = secs <= 0 ? 10.0 : (_maxFrames / secs).clamp(2.0, 15.0).floorToDouble();
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/scrub3_${cacheKey}_r$rotation');
    final frames = ScrubFrames._(dir, fps);
    final marker = File('${dir.path}/done_${fps.toInt()}');
    if (marker.existsSync()) {
      frames._done = true;
      return frames;
    }
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    // Rotate explicitly (see ffmpeg_commands.dart) so frames come out upright
    // whatever this ffmpeg build's autorotate default is.
    final up = uprightFilter(rotation);
    frames._job = await FfmpegService.run([
      '-y', '-noautorotate', '-i', videoPath, '-an', '-sn',
      '-vf', '${up.isEmpty ? '' : '$up,'}fps=${fps.toInt()},scale=-2:$_height',
      '-q:v', '6',
      '${dir.path}/f_%05d.jpg',
    ], outputDurationMs: durationMs);
    frames._job!.result.then((r) {
      if (r.success) {
        marker.createSync();
        frames._done = true;
      }
    });
    return frames;
  }

  bool get isDone => _done;

  File _file(int index) => File('${_dir.path}/f_${index.toString().padLeft(5, '0')}.jpg');

  /// The extracted frame nearest to [ms], or null if it isn't available yet.
  File? frameAt(int ms) {
    // ffmpeg numbers from 1; frame n covers [(n-1)/fps, n/fps).
    final index = (ms * fps / 1000).floor() + 1;
    final f = _file(index);
    // While extracting, the newest file may still be half written.
    if (f.existsSync() && (_done || _file(index + 1).existsSync())) return f;
    // Near the very end the last frame may be missing; step back a little.
    for (var i = index - 1; i >= index - 3 && i >= 1; i--) {
      final g = _file(i);
      if (g.existsSync()) return _done ? g : null;
    }
    return null;
  }

  Future<void> cancel() async {
    if (!_done) await _job?.cancel();
  }
}
