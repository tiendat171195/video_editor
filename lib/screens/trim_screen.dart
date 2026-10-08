import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/media_info.dart';
import '../models/project.dart';
import '../services/ffmpeg_commands.dart';
import '../services/storage.dart';
import '../util/format.dart';
import '../widgets/job_runner.dart';
import 'editor_screen.dart';

class TrimScreen extends StatefulWidget {
  const TrimScreen({super.key, required this.project, this.info, this.initialPositionMs = 0});
  final VideoProject project;
  final MediaInfo? info;
  final int initialPositionMs;

  @override
  State<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends State<TrimScreen> {
  VideoPlayerController? _ctrl;
  RangeValues _range = const RangeValues(0, 1);
  bool _accurate = true;
  bool _keepNotes = true;
  Timer? _loopTimer;

  int get _durationMs => _ctrl?.value.duration.inMilliseconds ?? 1;
  int get _startMs => _range.start.round();
  int get _endMs => _range.end.round();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ctrl = VideoPlayerController.file(File(widget.project.videoPath));
    await ctrl.initialize();
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    final d = ctrl.value.duration.inMilliseconds.toDouble();
    setState(() {
      _ctrl = ctrl;
      _range = RangeValues(0, d);
    });
    await ctrl.seekTo(Duration(milliseconds: widget.initialPositionMs));
    ctrl.addListener(() => mounted ? setState(() {}) : null);
    // Keep preview playback inside the selected range.
    _loopTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final v = ctrl.value;
      if (v.isPlaying && v.position.inMilliseconds >= _endMs) {
        ctrl.pause();
        ctrl.seekTo(Duration(milliseconds: _startMs));
      }
    });
  }

  @override
  void dispose() {
    _loopTimer?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  void _setRange(RangeValues r, {bool seekToStart = true}) {
    if (r.end - r.start < 100) return;
    final startChanged = r.start != _range.start;
    setState(() => _range = r);
    _ctrl?.seekTo(Duration(milliseconds: (startChanged || !seekToStart ? r.start : r.end).round()));
  }

  void _nudge({required bool start, required int deltaMs}) {
    final d = _durationMs.toDouble();
    if (start) {
      _setRange(RangeValues((_range.start + deltaMs).clamp(0, _range.end - 100), _range.end));
    } else {
      _setRange(RangeValues(_range.start, (_range.end + deltaMs).clamp(_range.start + 100, d)), seekToStart: false);
    }
  }

  Future<void> _run() async {
    final p = widget.project;
    final ext = _accurate ? 'mp4' : _sourceExt(p.videoPath);
    final out = await Storage.newOutputPath(p.videoPath, 'cut', ext);
    final args = buildTrimArgs(input: p.videoPath, output: out, startMs: _startMs, endMs: _endMs, accurate: _accurate);
    await _ctrl?.pause();
    if (!mounted) return;
    final path = await runJobWithProgress(
      context,
      title: 'Đang cắt video…',
      args: args,
      outputPath: out,
      outputDurationMs: _endMs - _startMs,
    );
    if (path == null || !mounted) return;
    // Notes only line up exactly with a frame-accurate cut.
    final carry = _keepNotes && _accurate && p.hasEdits ? p.retimedForTrim(_startMs, _endMs) : null;
    await showResultSheet(
      context,
      path: path,
      sourceSizeBytes: widget.info?.sizeBytes,
      onOpenInEditor: () {
        final project = projectForOutput(path, annotations: carry?.annotations, slowMos: carry?.slowMos);
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => EditorScreen(project: project)));
      },
    );
  }

  static String _sourceExt(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot > 0 ? path.substring(dot + 1).toLowerCase() : '';
    return const {'mp4', 'mov', 'mkv', 'webm', 'm4v', '3gp', 'avi', 'ts'}.contains(ext) ? ext : 'mp4';
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Cắt video')),
      body: ctrl == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Container(
                    color: Colors.black,
                    height: MediaQuery.sizeOf(context).height * 0.38,
                    alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: () {
                        if (ctrl.value.isPlaying) {
                          ctrl.pause();
                        } else {
                          final pos = ctrl.value.position.inMilliseconds;
                          if (pos < _startMs || pos >= _endMs - 50) ctrl.seekTo(Duration(milliseconds: _startMs));
                          ctrl.play();
                        }
                      },
                      child: AspectRatio(
                        aspectRatio: ctrl.value.aspectRatio,
                        child: Stack(fit: StackFit.expand, children: [
                          VideoPlayer(ctrl),
                          if (!ctrl.value.isPlaying)
                            const Center(child: Icon(Icons.play_circle_fill, size: 56, color: Colors.white70)),
                        ]),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(children: [
                      Text('Vị trí: ${formatMs(ctrl.value.position.inMilliseconds, tenths: true)}'),
                      const Spacer(),
                      Text('Độ dài: ${formatMs(_endMs - _startMs, tenths: true)}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ]),
                  ),
                  RangeSlider(
                    min: 0,
                    max: _durationMs.toDouble(),
                    values: _range,
                    labels: RangeLabels(formatMs(_startMs, tenths: true), formatMs(_endMs, tenths: true)),
                    onChanged: (r) => _setRange(r),
                  ),
                  _edgeRow(
                    label: 'Đầu',
                    ms: _startMs,
                    onMinus: () => _nudge(start: true, deltaMs: -100),
                    onPlus: () => _nudge(start: true, deltaMs: 100),
                    onSetHere: () => _setRange(RangeValues(
                        ctrl.value.position.inMilliseconds.toDouble().clamp(0, _range.end - 100), _range.end)),
                  ),
                  _edgeRow(
                    label: 'Cuối',
                    ms: _endMs,
                    onMinus: () => _nudge(start: false, deltaMs: -100),
                    onPlus: () => _nudge(start: false, deltaMs: 100),
                    onSetHere: () => _setRange(
                        RangeValues(_range.start,
                            ctrl.value.position.inMilliseconds.toDouble().clamp(_range.start + 100, _durationMs.toDouble())),
                        seekToStart: false),
                  ),
                  const Divider(),
                  RadioGroup<bool>(
                    groupValue: _accurate,
                    onChanged: (v) => setState(() => _accurate = v!),
                    child: const Column(children: [
                      RadioListTile<bool>(
                        value: true,
                        title: Text('Chính xác từng khung hình'),
                        subtitle: Text('Encode lại (H.264/AAC). Chậm hơn, giữ được note.'),
                      ),
                      RadioListTile<bool>(
                        value: false,
                        title: Text('Nhanh (không encode lại)'),
                        subtitle: Text('Giữ nguyên chất lượng, gần như tức thì; điểm cắt có thể lệch về keyframe gần nhất.'),
                      ),
                    ]),
                  ),
                  if (widget.project.hasEdits)
                    SwitchListTile(
                      value: _keepNotes && _accurate,
                      onChanged: _accurate ? (v) => setState(() => _keepNotes = v) : null,
                      title: const Text('Mang theo note & slow-mo sang video mới'),
                      subtitle: const Text('Chỉ áp dụng cho chế độ chính xác'),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.content_cut),
                      label: const Text('Cắt video'),
                      onPressed: _run,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _edgeRow({
    required String label,
    required int ms,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
    required VoidCallback onSetHere,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        SizedBox(width: 40, child: Text(label)),
        IconButton(icon: const Icon(Icons.remove), tooltip: '-0.1s', onPressed: onMinus),
        Text(formatMs(ms, tenths: true), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        IconButton(icon: const Icon(Icons.add), tooltip: '+0.1s', onPressed: onPlus),
        const Spacer(),
        TextButton.icon(icon: const Icon(Icons.my_location, size: 18), label: const Text('Đặt tại vị trí'), onPressed: onSetHere),
      ]),
    );
  }
}
