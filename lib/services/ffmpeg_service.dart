import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../models/media_info.dart';

/// Result of an ffmpeg run.
class FfmpegResult {
  const FfmpegResult({required this.success, required this.cancelled, this.logs});
  final bool success;
  final bool cancelled;
  final String? logs;

  /// The last few log lines, which usually hold the actual error.
  String get errorSummary {
    final lines = (logs ?? '').trim().split('\n');
    return lines.skip(lines.length > 12 ? lines.length - 12 : 0).join('\n');
  }
}

/// A running ffmpeg job that reports progress in 0..1 and can be cancelled.
class FfmpegJob {
  FfmpegJob._(this.progress, this.result, this._cancel);

  final Stream<double> progress;
  final Future<FfmpegResult> result;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

class FfmpegService {
  const FfmpegService._();

  static Future<MediaInfo?> probe(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    if (info == null) return null;
    final streams = [
      for (final s in info.getStreams()) s.getAllProperties() ?? const {},
    ];
    int? size;
    try {
      size = await File(path).length();
    } catch (_) {}
    return MediaInfo.fromProbe(
      format: info.getFormatProperties(),
      streams: streams,
      fallbackSizeBytes: size,
    );
  }

  /// Starts ffmpeg with [args]. [outputDurationMs] is used to turn ffmpeg's
  /// "time=" statistics into a progress fraction.
  static Future<FfmpegJob> run(List<String> args, {required int outputDurationMs}) async {
    final progress = StreamController<double>.broadcast();
    final done = Completer<FfmpegResult>();

    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final code = await session.getReturnCode();
        final logs = await session.getAllLogsAsString();
        if (!progress.isClosed) {
          if (ReturnCode.isSuccess(code)) progress.add(1);
          await progress.close();
        }
        done.complete(FfmpegResult(
          success: ReturnCode.isSuccess(code),
          cancelled: ReturnCode.isCancel(code),
          logs: logs,
        ));
      },
      null,
      (stats) {
        if (outputDurationMs <= 0 || progress.isClosed) return;
        final p = stats.getTime() / outputDurationMs;
        progress.add(p.clamp(0.0, 0.99));
      },
    );

    return FfmpegJob._(
      progress.stream,
      done.future,
      () => FFmpegKit.cancel(session.getSessionId()),
    );
  }
}
