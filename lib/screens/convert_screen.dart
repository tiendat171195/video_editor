import 'package:flutter/material.dart';

import '../models/media_info.dart';
import '../models/project.dart';
import '../services/ffmpeg_commands.dart';
import '../services/ffmpeg_service.dart';
import '../services/storage.dart';
import '../util/format.dart';
import '../widgets/job_runner.dart';
import 'editor_screen.dart';

/// Change container, codecs, frame rate, resolution and size.
class ConvertScreen extends StatefulWidget {
  const ConvertScreen({super.key, required this.project, this.info});
  final VideoProject project;
  final MediaInfo? info;

  @override
  State<ConvertScreen> createState() => _ConvertScreenState();
}

enum _SizeMode { quality, target }

class _ConvertScreenState extends State<ConvertScreen> {
  MediaInfo? _info;
  OutputFormat _format = OutputFormat.mp4;
  VideoCodec _vcodec = VideoCodec.h264;
  AudioCodec _acodec = AudioCodec.aac;
  Quality _quality = Quality.medium;
  _SizeMode _sizeMode = _SizeMode.quality;
  double _targetMb = 20;
  double? _fps;
  int? _maxHeight;
  int _audioKbps = 128;
  bool _fast = true;

  static const _fpsOptions = <double?>[null, 60, 30, 25, 24, 15, 10];
  static const _heightOptions = <int?>[null, 2160, 1440, 1080, 720, 480, 360];

  @override
  void initState() {
    super.initState();
    _info = widget.info;
    if (_info == null) {
      FfmpegService.probe(widget.project.videoPath).then((i) {
        if (mounted) setState(() => _setInfo(i));
      });
    } else {
      _setInfo(_info);
    }
  }

  void _setInfo(MediaInfo? i) {
    _info = i;
    if (i?.sizeBytes != null) {
      // Default target: half the original, rounded.
      _targetMb = (i!.sizeBytes! / 1024 / 1024 / 2).clamp(1, 2000).roundToDouble();
    }
  }

  void _setFormat(OutputFormat f) {
    setState(() {
      _format = f;
      final vs = videoCodecsFor(f);
      if (vs.isNotEmpty && !vs.contains(_vcodec)) _vcodec = vs.first;
      final as = audioCodecsFor(f);
      if (!as.contains(_acodec)) _acodec = as.first;
      if (f == OutputFormat.gif) {
        _fps ??= 12;
        _maxHeight ??= 480;
      }
    });
  }

  bool get _isGif => _format == OutputFormat.gif;
  bool get _videoCopy => !_isGif && _vcodec == VideoCodec.copy;

  ConvertOptions get _options => ConvertOptions(
        container: _format,
        videoCodec: _vcodec,
        audioCodec: _acodec,
        quality: _quality,
        targetSizeMb: _sizeMode == _SizeMode.target ? _targetMb : null,
        fps: _fps,
        maxHeight: _maxHeight,
        audioKbps: _audioKbps,
        fastEncode: _fast,
      );

  Future<void> _run() async {
    final p = widget.project;
    final info = _info;
    final duration = info?.durationMs ?? p.durationMs;
    final out = await Storage.newOutputPath(p.videoPath, 'conv', _format.ext);
    final args = buildConvertArgs(
      input: p.videoPath,
      output: out,
      o: _options,
      durationMs: duration,
      sourceHasAudio: info?.hasAudio ?? true,
    );
    if (!mounted) return;
    final path = await runJobWithProgress(
      context,
      title: 'Đang chuyển đổi…',
      args: args,
      outputPath: out,
      outputDurationMs: duration,
    );
    if (path == null || !mounted) return;
    await showResultSheet(
      context,
      path: path,
      sourceSizeBytes: info?.sizeBytes,
      onOpenInEditor: _isGif
          ? null
          : () {
              // Timing is unchanged by conversion, so the notes still line up.
              final project = projectForOutput(
                path,
                annotations: [for (final a in p.annotations) a.copyWith(id: newId())],
                slowMos: [for (final s in p.slowMos) s],
              );
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => EditorScreen(project: project)));
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = _info;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chuyển đổi / Nén')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: i == null
                  ? const Text('Đang đọc thông tin video…')
                  : Text(
                      'Gốc: ${i.displayWidth}×${i.displayHeight} · ${i.fps?.toStringAsFixed(i.fps! % 1 == 0 ? 0 : 2) ?? '?'} fps · '
                      '${i.videoCodec ?? '?'}/${i.audioCodec ?? 'không audio'} · ${formatBytes(i.sizeBytes)} · ${formatMs(i.durationMs)}',
                      style: text.bodySmall,
                    ),
            ),
          ),
          const SizedBox(height: 12),
          _section('Định dạng'),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final f in OutputFormat.values)
              ChoiceChip(label: Text(f.label), selected: _format == f, onSelected: (_) => _setFormat(f)),
          ]),
          if (!_isGif) ...[
            _section('Video codec'),
            DropdownButtonFormField<VideoCodec>(
              key: ValueKey('v$_format$_vcodec'),
              initialValue: _vcodec,
              items: [for (final c in videoCodecsFor(_format)) DropdownMenuItem(value: c, child: Text(c.label))],
              onChanged: (c) => setState(() => _vcodec = c!),
            ),
          ],
          if (!_videoCopy) ...[
            _section('Dung lượng / chất lượng'),
            if (!_isGif)
              SegmentedButton<_SizeMode>(
                segments: const [
                  ButtonSegment(value: _SizeMode.quality, label: Text('Theo chất lượng')),
                  ButtonSegment(value: _SizeMode.target, label: Text('Theo dung lượng')),
                ],
                selected: {_sizeMode},
                onSelectionChanged: (s) => setState(() => _sizeMode = s.first),
              ),
            const SizedBox(height: 8),
            if (_isGif || _sizeMode == _SizeMode.quality) ...[
              if (!_isGif)
                Wrap(spacing: 8, children: [
                  for (final q in Quality.values)
                    ChoiceChip(label: Text(q.label), selected: _quality == q, onSelected: (_) => setState(() => _quality = q)),
                ]),
            ] else ...[
              Text('Dung lượng mục tiêu: ${_targetMb.toStringAsFixed(0)} MB'
                  '${i?.sizeBytes != null ? '  (gốc ${formatBytes(i!.sizeBytes)})' : ''}'),
              Slider(
                min: 1,
                max: _targetMax,
                value: _targetMb.clamp(1, _targetMax),
                onChanged: (v) => setState(() => _targetMb = v.roundToDouble()),
              ),
              if (i != null)
                Text(
                  'Bitrate video ≈ ${bitrateForTargetSize(targetMb: _targetMb, durationMs: i.durationMs, audioKbps: _acodec == AudioCodec.none ? 0 : _audioKbps)} kbps',
                  style: text.bodySmall,
                ),
            ],
            _section('Độ phân giải (chiều cao tối đa)'),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final h in _heightOptions)
                ChoiceChip(
                  label: Text(h == null ? 'Giữ nguyên' : '${h}p'),
                  selected: _maxHeight == h,
                  onSelected: (_) => setState(() => _maxHeight = h),
                ),
            ]),
            _section('FPS'),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final f in _fpsOptions)
                ChoiceChip(
                  label: Text(f == null ? 'Giữ nguyên' : f.toStringAsFixed(0)),
                  selected: _fps == f,
                  onSelected: (_) => setState(() => _fps = f),
                ),
            ]),
          ],
          if (!_isGif) ...[
            _section('Âm thanh'),
            DropdownButtonFormField<AudioCodec>(
              key: ValueKey('a$_format$_acodec'),
              initialValue: _acodec,
              items: [for (final c in audioCodecsFor(_format)) DropdownMenuItem(value: c, child: Text(c.label))],
              onChanged: (c) => setState(() => _acodec = c!),
            ),
            if (_acodec != AudioCodec.none && _acodec != AudioCodec.copy)
              Wrap(spacing: 8, children: [
                for (final k in [64, 96, 128, 192, 256])
                  ChoiceChip(label: Text('$k kbps'), selected: _audioKbps == k, onSelected: (_) => setState(() => _audioKbps = k)),
              ]),
          ],
          if (!_videoCopy && !_isGif)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _fast,
              onChanged: (v) => setState(() => _fast = v),
              title: const Text('Encode nhanh'),
              subtitle: const Text('Tắt để file nhỏ hơn một chút nhưng chậm hơn nhiều'),
            ),
          if (_videoCopy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Video được copy nguyên vẹn: chỉ đổi định dạng file (remux), rất nhanh. '
                  'Độ phân giải/FPS/dung lượng không đổi.', style: text.bodySmall),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(icon: const Icon(Icons.play_arrow), label: const Text('Bắt đầu chuyển đổi'), onPressed: _run),
        ],
      ),
    );
  }

  double get _targetMax {
    final src = _info?.sizeBytes;
    if (src == null) return 500;
    return (src / 1024 / 1024).clamp(2, 4000).ceilToDouble();
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );
}
