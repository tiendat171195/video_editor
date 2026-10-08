import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../services/ffmpeg_service.dart';
import '../util/format.dart';

/// Runs an ffmpeg job behind a modal progress dialog.
/// Returns the output path on success, null on failure or cancel.
Future<String?> runJobWithProgress(
  BuildContext context, {
  required String title,
  required List<String> args,
  required String outputPath,
  required int outputDurationMs,
}) async {
  final job = await FfmpegService.run(args, outputDurationMs: outputDurationMs);
  if (!context.mounted) {
    await job.cancel();
    return null;
  }

  final result = await showDialog<FfmpegResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProgressDialog(title: title, job: job),
  );
  if (result == null || !context.mounted) return null;

  if (result.success) return outputPath;

  final out = File(outputPath);
  if (out.existsSync()) await out.delete();
  if (!result.cancelled && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xử lý thất bại'),
        content: SingleChildScrollView(
          child: SelectableText(result.errorSummary, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
      ),
    );
  }
  return null;
}

class _ProgressDialog extends StatefulWidget {
  const _ProgressDialog({required this.title, required this.job});
  final String title;
  final FfmpegJob job;

  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  double _progress = 0;
  bool _cancelling = false;
  late final StreamSubscription<double> _sub;
  final _watch = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    _sub = widget.job.progress.listen((p) => setState(() => _progress = p));
    widget.job.result.then((r) {
      if (mounted) Navigator.pop(context, r);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  String get _eta {
    if (_progress < 0.03) return '';
    final total = _watch.elapsedMilliseconds / _progress;
    return ' · còn ~${formatMs((total - _watch.elapsedMilliseconds).round())}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            const SizedBox(height: 12),
            Text('${(_progress * 100).toStringAsFixed(0)}%$_eta'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    widget.job.cancel();
                  },
            child: Text(_cancelling ? 'Đang huỷ…' : 'Huỷ'),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet shown after a successful job: save, share, or open.
Future<void> showResultSheet(
  BuildContext context, {
  required String path,
  int? sourceSizeBytes,
  VoidCallback? onOpenInEditor,
}) {
  final size = File(path).lengthSync();
  final isVideo = !path.toLowerCase().endsWith('.gif');
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final ratio = sourceSizeBytes != null && sourceSizeBytes > 0
          ? ' (${(size / sourceSizeBytes * 100).toStringAsFixed(0)}% so với gốc)'
          : '';
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Hoàn tất', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('${path.split('/').last}\n${formatBytes(size)}$ratio', style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Lưu vào thư viện ảnh'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(ctx);
                  try {
                    if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
                      messenger.showSnackBar(const SnackBar(content: Text('Chưa được cấp quyền thư viện ảnh')));
                      return;
                    }
                    if (isVideo) {
                      await Gal.putVideo(path, album: 'Video Note');
                    } else {
                      await Gal.putImage(path, album: 'Video Note');
                    }
                    messenger.showSnackBar(const SnackBar(content: Text('Đã lưu vào thư viện')));
                  } on GalException catch (e) {
                    messenger.showSnackBar(SnackBar(content: Text('Không lưu được: ${e.type.message}')));
                  }
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.share_outlined),
                label: const Text('Chia sẻ'),
                onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(path)])),
              ),
              if (onOpenInEditor != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Mở video mới trong editor'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    onOpenInEditor();
                  },
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
