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
              _SaveToGalleryButton(path: path, isVideo: isVideo),
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

enum _SaveState { idle, saving, saved, failed }

/// Saves to the gallery and shows the outcome on the button itself: a
/// SnackBar would be hidden behind the bottom sheet.
class _SaveToGalleryButton extends StatefulWidget {
  const _SaveToGalleryButton({required this.path, required this.isVideo});
  final String path;
  final bool isVideo;

  @override
  State<_SaveToGalleryButton> createState() => _SaveToGalleryButtonState();
}

class _SaveToGalleryButtonState extends State<_SaveToGalleryButton> {
  _SaveState _state = _SaveState.idle;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _state = _SaveState.saving;
      _error = null;
    });
    try {
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        throw const _SaveError('Chưa được cấp quyền truy cập thư viện ảnh');
      }
      if (widget.isVideo) {
        await Gal.putVideo(widget.path, album: 'Video Note');
      } else {
        await Gal.putImage(widget.path, album: 'Video Note');
      }
      if (mounted) setState(() => _state = _SaveState.saved);
    } catch (e) {
      final msg = switch (e) {
        _SaveError(:final message) => message,
        GalException(:final type) => type.message,
        _ => '$e',
      };
      if (mounted) {
        setState(() {
          _state = _SaveState.failed;
          _error = msg;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = switch (_state) {
      _SaveState.idle => FilledButton.icon(
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Lưu vào thư viện ảnh'),
          onPressed: _save,
        ),
      _SaveState.saving => FilledButton.icon(
          icon: const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          label: const Text('Đang lưu…'),
          onPressed: null,
        ),
      _SaveState.saved => FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.green.shade600,
            disabledBackgroundColor: Colors.green.shade600,
            disabledForegroundColor: Colors.white,
          ),
          icon: const Icon(Icons.check_circle),
          label: const Text('Đã lưu vào thư viện ảnh'),
          onPressed: null,
        ),
      _SaveState.failed => FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
          icon: const Icon(Icons.refresh),
          label: const Text('Lưu thất bại, thử lại'),
          onPressed: _save,
        ),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      button,
      if (_state == _SaveState.saved)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Xem trong Thư viện (Gallery), album "Video Note".',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        ),
      if (_state == _SaveState.failed && _error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error, fontSize: 12)),
        ),
    ]);
  }
}

class _SaveError implements Exception {
  const _SaveError(this.message);
  final String message;
}
