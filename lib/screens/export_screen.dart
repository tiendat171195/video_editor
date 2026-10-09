import 'package:flutter/material.dart';

import '../models/annotation.dart';
import '../models/media_info.dart';
import '../models/project.dart';
import '../models/zoom.dart';
import '../services/ffmpeg_commands.dart';
import '../services/overlay_renderer.dart';
import '../services/storage.dart';
import '../util/format.dart';
import '../widgets/job_runner.dart';
import 'editor_screen.dart';

/// Quick choices that set all the format options at once.
enum _Preset {
  original('Chất lượng gốc', 'MP4 · giữ độ phân giải', Icons.high_quality_outlined),
  share('Gửi nhanh', 'MP4 · 720p', Icons.send_outlined),
  light('Siêu nhẹ', 'MP4 · 480p · 30fps', Icons.compress),
  size('Theo dung lượng', 'Chọn số MB tối đa', Icons.sd_storage_outlined),
  gif('GIF', 'Ảnh động 480p', Icons.gif_box_outlined),
  custom('Tuỳ chỉnh', 'Thiết lập bên dưới', Icons.tune);

  const _Preset(this.label, this.hint, this.icon);
  final String label;
  final String hint;
  final IconData icon;
}

/// One place to export: burn in notes / slow-mo and pick the output format,
/// codec, resolution, frame rate and size in the same step.
class ExportScreen extends StatefulWidget {
  const ExportScreen({
    super.key,
    required this.project,
    required this.info,
    required this.frameWidth,
    required this.frameHeight,
    required this.durationMs,
  });

  final VideoProject project;
  final MediaInfo? info;

  /// Upright size of the video frame in pixels (rotation already applied).
  final int frameWidth;
  final int frameHeight;
  final int durationMs;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  _Preset _preset = _Preset.original;
  late bool _withNotes = widget.project.hasEdits;
  bool _advanced = false;

  OutputFormat _format = OutputFormat.mp4;
  VideoCodec _vcodec = VideoCodec.h264;
  AudioCodec _acodec = AudioCodec.aac;
  Quality _quality = Quality.high;
  bool _bySize = false;
  double _targetMb = 25;
  double? _fps;
  int? _maxHeight;
  int _audioKbps = 160;
  bool _fast = true;

  static const _fpsOptions = <double?>[null, 60, 30, 25, 24, 15, 10];
  static const _heightOptions = <int?>[null, 2160, 1440, 1080, 720, 480, 360];

  VideoProject get _p => widget.project;
  bool get _burnIn => _withNotes && _p.hasEdits;
  bool get _isGif => _format == OutputFormat.gif;
  int get _outMs => _burnIn ? exportedDurationMs(_p.slowMos, widget.durationMs) : widget.durationMs;

  List<VideoCodec> get _videoCodecs =>
      [for (final c in videoCodecsFor(_format)) if (!(_burnIn && c == VideoCodec.copy)) c];

  @override
  void initState() {
    super.initState();
    final src = widget.info?.sizeBytes;
    if (src != null) _targetMb = (src / 1024 / 1024 / 2).clamp(1, 2000).roundToDouble();
  }

  void _apply(_Preset p) {
    setState(() {
      _preset = p;
      _format = p == _Preset.gif ? OutputFormat.gif : OutputFormat.mp4;
      _vcodec = VideoCodec.h264;
      _acodec = p == _Preset.gif ? AudioCodec.none : AudioCodec.aac;
      _bySize = p == _Preset.size;
      _fast = true;
      switch (p) {
        case _Preset.original:
          _setBasics(Quality.high, null, null, 160);
        case _Preset.share:
          _setBasics(Quality.medium, 720, null, 128);
        case _Preset.light:
          _setBasics(Quality.low, 480, 30, 96);
        case _Preset.size:
          _setBasics(Quality.medium, null, null, 128);
        case _Preset.gif:
          _setBasics(Quality.medium, 480, 12, 128);
        case _Preset.custom:
          _advanced = true;
      }
    });
  }

  void _setBasics(Quality q, int? maxHeight, double? fps, int audioKbps) {
    _quality = q;
    _maxHeight = maxHeight;
    _fps = fps;
    _audioKbps = audioKbps;
  }

  /// Any manual change in the advanced section makes the preset "custom".
  void _custom(VoidCallback f) => setState(() {
        f();
        _preset = _Preset.custom;
      });

  void _setFormat(OutputFormat f) => _custom(() {
        _format = f;
        final vs = _videoCodecs;
        if (vs.isNotEmpty && !vs.contains(_vcodec)) _vcodec = vs.first;
        final as = audioCodecsFor(f);
        if (!as.contains(_acodec)) _acodec = as.first;
        if (f == OutputFormat.gif) {
          _fps ??= 12;
          _maxHeight ??= 480;
        }
      });

  ConvertOptions get _options => ConvertOptions(
        container: _format,
        videoCodec: _burnIn && _vcodec == VideoCodec.copy ? VideoCodec.h264 : _vcodec,
        audioCodec: _acodec,
        quality: _quality,
        targetSizeMb: _bySize && !_isGif ? _targetMb : null,
        fps: _fps,
        maxHeight: _maxHeight,
        audioKbps: _audioKbps,
        fastEncode: _fast,
      );

  Future<void> _run() async {
    final hasAudio = widget.info?.hasAudio ?? true;
    final rotation = widget.info?.uprightRotation ?? 0;
    final out = await Storage.newOutputPath(_p.videoPath, _burnIn ? 'note' : 'conv', _format.ext);
    List<String> args;
    if (_burnIn) {
      final dir = await Storage.tempDir('overlays');
      final overlays = await renderOverlays(
        annotations: _p.annotations,
        videoWidth: widget.frameWidth,
        videoHeight: widget.frameHeight,
        outDir: dir,
        durationMs: widget.durationMs,
      );
      args = buildExportArgs(
        input: _p.videoPath,
        output: out,
        overlays: overlays,
        slowMos: _p.slowMos,
        durationMs: widget.durationMs,
        hasAudio: hasAudio,
        options: _options,
        zooms: _p.zooms,
        frameWidth: widget.frameWidth,
        frameHeight: widget.frameHeight,
        fps: widget.info?.fps ?? 30,
        rotation: rotation,
      );
    } else {
      args = buildConvertArgs(
        input: _p.videoPath,
        output: out,
        o: _options,
        durationMs: widget.durationMs,
        sourceHasAudio: hasAudio,
        rotation: rotation,
      );
    }
    if (!mounted) return;
    final path = await runJobWithProgress(
      context,
      title: _burnIn ? 'Đang xuất video kèm note…' : 'Đang xuất video…',
      args: args,
      outputPath: out,
      outputDurationMs: _outMs,
    );
    if (path == null || !mounted) return;
    // Notes that weren't burned in still line up with the new file.
    final carry = !_burnIn && !_isGif;
    await showResultSheet(
      context,
      path: path,
      sourceSizeBytes: widget.info?.sizeBytes,
      onOpenInEditor: _isGif
          ? null
          : () {
              final project = projectForOutput(
                path,
                folder: _p.folder,
                annotations: carry ? [for (final a in _p.annotations) a.copyWith(id: newId())] : null,
                slowMos: carry ? [for (final s in _p.slowMos) SlowMoSegment.fromJson(s.toJson())] : null,
                zooms: carry ? [for (final z in _p.zooms) ZoomSegment.fromJson(z.toJson())] : null,
              );
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => EditorScreen(project: project)));
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Xuất video')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.movie_creation_outlined),
            label: Text(_burnIn ? 'Xuất video kèm note' : 'Xuất video'),
            onPressed: _run,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (i != null)
            Text(
              'Gốc: ${widget.frameWidth}×${widget.frameHeight} · ${i.fps?.toStringAsFixed(i.fps! % 1 == 0 ? 0 : 2) ?? '?'} fps · '
              '${formatBytes(i.sizeBytes)} · ${formatMs(widget.durationMs)}',
              style: text.bodySmall,
            ),
          if (_p.hasEdits)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _withNotes,
              onChanged: (v) => setState(() {
                _withNotes = v;
                if (!_videoCodecs.contains(_vcodec)) _vcodec = VideoCodec.h264;
              }),
              title: const Text('Kèm note, slow-mo & zoom'),
              subtitle: Text('${_p.annotations.length} note · ${_p.slowMos.length} slow-mo · ${_p.zooms.length} zoom'
                  '${_burnIn && _p.slowMos.isNotEmpty ? ' · dài ${formatMs(_outMs)}' : ''}'),
            ),
          const SizedBox(height: 8),
          Text('Định dạng', style: text.titleSmall),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.6,
            children: [for (final p in _Preset.values) _presetCard(p)],
          ),
          if (_bySize && !_isGif) ...[
            const SizedBox(height: 16),
            Text('Dung lượng tối đa: ${_targetMb.toStringAsFixed(0)} MB'
                '${i?.sizeBytes != null ? '  (gốc ${formatBytes(i!.sizeBytes)})' : ''}'),
            Slider(
              min: 1,
              max: _targetMax,
              value: _targetMb.clamp(1, _targetMax),
              onChanged: (v) => setState(() => _targetMb = v.roundToDouble()),
            ),
          ],
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              key: ValueKey('adv$_advanced'),
              initiallyExpanded: _advanced,
              onExpansionChanged: (v) => _advanced = v,
              title: const Text('Tuỳ chỉnh nâng cao'),
              subtitle: Text(_summary, style: text.bodySmall),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: _advancedOptions(text),
            ),
          ),
        ],
      ),
    );
  }

  String get _summary {
    final parts = <String>[
      _format.label,
      if (!_isGif) _options.videoCodec.label.split(' ').first,
      _maxHeight == null ? 'giữ độ phân giải' : '${_maxHeight}p',
      _fps == null ? 'giữ fps' : '${_fps!.toStringAsFixed(0)}fps',
      if (!_isGif) (_bySize ? '≤${_targetMb.toStringAsFixed(0)}MB' : 'chất lượng ${_quality.label.toLowerCase()}'),
    ];
    return parts.join(' · ');
  }

  Widget _presetCard(_Preset p) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _preset == p;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _apply(p),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Icon(p.icon, color: selected ? scheme.onPrimaryContainer : null),
            const SizedBox(width: 10),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.label, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(p.hint, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _advancedOptions(TextTheme text) {
    Widget section(String t) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Text(t, style: text.titleSmall),
        );
    final videoCopy = !_isGif && _vcodec == VideoCodec.copy;
    return [
      section('Định dạng file'),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final f in OutputFormat.values)
          ChoiceChip(label: Text(f.label), selected: _format == f, onSelected: (_) => _setFormat(f)),
      ]),
      if (!_isGif) ...[
        section('Video codec'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final c in _videoCodecs)
            ChoiceChip(label: Text(c.label), selected: _vcodec == c, onSelected: (_) => _custom(() => _vcodec = c)),
        ]),
      ],
      if (!videoCopy) ...[
        if (!_isGif) ...[
          section('Dung lượng / chất lượng'),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final q in Quality.values)
              ChoiceChip(
                label: Text(q.label),
                selected: !_bySize && _quality == q,
                onSelected: (_) => _custom(() {
                  _quality = q;
                  _bySize = false;
                }),
              ),
            ChoiceChip(label: const Text('Theo MB'), selected: _bySize, onSelected: (_) => _custom(() => _bySize = true)),
          ]),
        ],
        section('Độ phân giải (chiều cao tối đa)'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final h in _heightOptions)
            ChoiceChip(
              label: Text(h == null ? 'Giữ nguyên' : '${h}p'),
              selected: _maxHeight == h,
              onSelected: (_) => _custom(() => _maxHeight = h),
            ),
        ]),
        section('FPS'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final f in _fpsOptions)
            ChoiceChip(
              label: Text(f == null ? 'Giữ nguyên' : f.toStringAsFixed(0)),
              selected: _fps == f,
              onSelected: (_) => _custom(() => _fps = f),
            ),
        ]),
      ],
      if (!_isGif) ...[
        section('Âm thanh'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final c in audioCodecsFor(_format))
            ChoiceChip(label: Text(c.label), selected: _acodec == c, onSelected: (_) => _custom(() => _acodec = c)),
        ]),
        if (_acodec != AudioCodec.none && _acodec != AudioCodec.copy)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 8, children: [
              for (final k in [64, 96, 128, 160, 192, 256])
                ChoiceChip(label: Text('$k kbps'), selected: _audioKbps == k, onSelected: (_) => _custom(() => _audioKbps = k)),
            ]),
          ),
      ],
      if (!videoCopy && !_isGif)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _fast,
          onChanged: (v) => _custom(() => _fast = v),
          title: const Text('Encode nhanh'),
          subtitle: const Text('Tắt để file nhỏ hơn một chút nhưng chậm hơn nhiều'),
        ),
      if (videoCopy)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Video được copy nguyên vẹn: chỉ đổi định dạng file (remux), rất nhanh.', style: text.bodySmall),
        ),
    ];
  }

  double get _targetMax {
    final src = widget.info?.sizeBytes;
    if (src == null) return 500;
    return (src / 1024 / 1024).clamp(2, 4000).ceilToDouble();
  }
}
