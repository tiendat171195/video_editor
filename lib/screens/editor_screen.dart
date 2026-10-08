import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../models/annotation.dart';
import '../models/media_info.dart';
import '../models/project.dart';
import '../services/ffmpeg_commands.dart';
import '../services/ffmpeg_service.dart';
import '../services/overlay_renderer.dart';
import '../services/scrub_frames.dart';
import '../services/storage.dart';
import '../util/format.dart';
import '../widgets/annotation_painter.dart';
import '../widgets/job_runner.dart';
import '../widgets/timeline.dart';
import 'convert_screen.dart';
import 'trim_screen.dart';

enum Tool { hand, pen, ellipse, rect, arrow, text }

const kNoteColors = <Color>[
  Color(0xFFFF3B30),
  Color(0xFFFFCC00),
  Color(0xFF34C759),
  Color(0xFF00C7FF),
  Color(0xFF5856D6),
  Color(0xFFFF2D92),
  Color(0xFFFFFFFF),
  Color(0xFF000000),
];

const kSpeeds = <double>[0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

int _idCounter = 0;
String newId() => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

/// Opens [project] in a new editor route.
Future<void> openEditor(BuildContext context, VideoProject project) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorScreen(project: project)));

/// Creates a project for a freshly produced video, optionally carrying notes.
VideoProject projectForOutput(String path,
    {List<Annotation>? annotations, List<SlowMoSegment>? slowMos, String? folder}) {
  return VideoProject(
    id: newId(),
    videoPath: path,
    name: path.split('/').last,
    folder: folder,
    annotations: annotations,
    slowMos: slowMos,
  );
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.project});
  final VideoProject project;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  VideoProject get _p => widget.project;

  VideoPlayerController? _ctrl;
  MediaInfo? _info;
  String? _loadError;

  // Smooth playback clock: video_player reports position every ~100ms, so
  // extrapolate between reports to keep notes and the playhead fluid.
  late final Ticker _ticker;
  final _clock = Stopwatch()..start();
  final _pos = ValueNotifier<int>(0);
  int _reportedMs = 0;
  int _reportedAt = 0;
  bool _seeking = false;
  int? _pendingSeek;
  bool _wasPlayingBeforeScrub = false;

  // Scrubbing: show pre-extracted low-res frames under the finger while the
  // real (slower) seeks catch up.
  ScrubFrames? _frames;
  final _showScrubFrame = ValueNotifier<bool>(false);
  bool _scrubbing = false;
  double? _scrubPrecision;
  double _jogMs = 0;

  // Speed
  double _baseSpeed = 1.0;
  double _appliedSpeed = 1.0;
  double _slowMoSpeed = 0.5;
  int? _slowMoStartMs;

  // Drawing
  Tool _tool = Tool.hand;
  Color _color = kNoteColors.first;
  int _sizeLevel = 1; // 0 thin, 1 medium, 2 thick
  int _noteDurationMs = 3000;
  bool _manualHide = false; // notes stay until "Ẩn tại đây" is pressed
  bool _animate = true;
  bool _pauseWhileDrawing = false;
  Annotation? _draft;
  int _draftWallStart = 0;
  bool _resumeAfterDraw = false;

  // Selection / moving
  String? _selectedId;
  bool _moving = false;

  // Pinch zoom of the preview (view only; notes stay in video coordinates).
  double _zoom = 1;
  Offset _zoomOffset = Offset.zero;
  bool _pinching = false;
  double _pinchStartZoom = 1;
  Offset _pinchStartOffset = Offset.zero;
  Offset _pinchStartFocal = Offset.zero;
  bool _oneFingerActive = false;
  bool _panningView = false;
  int _lastCommitAt = -100000;

  // Undo / redo as JSON snapshots of notes + slow-mo ranges.
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  Timer? _saveTimer;

  static const _strokeLevels = [0.005, 0.008, 0.014];
  static const _fontLevels = [0.04, 0.055, 0.075];

  bool get _isPlaying => _ctrl?.value.isPlaying ?? false;

  Annotation? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final a in _p.annotations) {
      if (a.id == id) return a;
    }
    return null;
  }
  int get _durationMs => _ctrl?.value.duration.inMilliseconds ?? _p.durationMs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick);
    _init();
  }

  Future<void> _init() async {
    final file = File(_p.videoPath);
    if (!file.existsSync()) {
      setState(() => _loadError = 'Không tìm thấy file video:\n${_p.videoPath}');
      return;
    }
    final ctrl = VideoPlayerController.file(file);
    try {
      await ctrl.initialize();
    } catch (e) {
      await ctrl.dispose();
      if (mounted) setState(() => _loadError = 'Không mở được video: $e');
      return;
    }
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    ctrl.addListener(_onVideoValue);
    setState(() => _ctrl = ctrl);
    _p.durationMs = ctrl.value.duration.inMilliseconds;
    _ticker.start();

    final info = await FfmpegService.probe(_p.videoPath);
    if (mounted) setState(() => _info = info);

    final frames = await ScrubFrames.start(
      videoPath: _p.videoPath,
      cacheKey: _p.id,
      durationMs: _p.durationMs,
    );
    if (mounted) {
      _frames = frames;
    } else {
      await frames.cancel();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _ctrl?.pause();
      _saveNow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _ctrl?.removeListener(_onVideoValue);
    _ctrl?.dispose();
    _saveTimer?.cancel();
    _saveNow();
    _frames?.cancel();
    _pos.dispose();
    _showScrubFrame.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ clock

  void _onVideoValue() {
    final v = _ctrl!.value;
    if (!_seeking) {
      _reportedMs = v.position.inMilliseconds;
      _reportedAt = _clock.elapsedMilliseconds;
    }
    if (v.isCompleted && _slowMoStartMs != null) _finishSlowMo();
    if (mounted) setState(() {}); // play/pause icon etc.
  }

  void _onTick(Duration _) {
    final ctrl = _ctrl;
    if (ctrl == null || _seeking) return;
    var ms = _reportedMs;
    if (ctrl.value.isPlaying) {
      ms += ((_clock.elapsedMilliseconds - _reportedAt) * _appliedSpeed).round();
    }
    ms = ms.clamp(0, _durationMs);
    if (ms != _pos.value) _pos.value = ms;

    // Preview slow-mo ranges by changing the playback rate.
    final desired = _slowMoStartMs != null ? _slowMoSpeed : (_p.slowMoAt(ms)?.speed ?? _baseSpeed);
    if (desired != _appliedSpeed && ctrl.value.isPlaying) {
      _reportedMs = ms;
      _reportedAt = _clock.elapsedMilliseconds;
      _appliedSpeed = desired;
      ctrl.setPlaybackSpeed(desired);
    }
  }

  Future<void> _seekTo(int ms) async {
    ms = ms.clamp(0, _durationMs);
    _pos.value = ms;
    if (_seeking) {
      _pendingSeek = ms;
      return;
    }
    _seeking = true;
    await _ctrl?.seekTo(Duration(milliseconds: ms));
    _reportedMs = ms;
    _reportedAt = _clock.elapsedMilliseconds;
    _seeking = false;
    final pending = _pendingSeek;
    _pendingSeek = null;
    if (pending != null && pending != ms) await _seekTo(pending);
  }

  Future<void> _togglePlay() async {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    if (ctrl.value.isPlaying) {
      await ctrl.pause();
      if (_slowMoStartMs != null) _finishSlowMo();
    } else {
      if (_pos.value >= _durationMs - 50) await _seekTo(0);
      await ctrl.play();
    }
  }

  void _stepFrame(int dir) {
    _ctrl?.pause();
    final fps = _info?.fps ?? 30;
    _seekTo(_pos.value + (dir * 1000 / fps).round());
  }

  void _scrubStart() {
    _wasPlayingBeforeScrub = _isPlaying;
    _ctrl?.pause();
    _scrubbing = true;
    _showScrubFrame.value = true;
  }

  Future<void> _scrubEnd() async {
    if (!_scrubbing) return;
    _scrubbing = false;
    setState(() => _scrubPrecision = null);
    final target = _pos.value;
    while (_seeking) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    await _seekTo(target);
    // Give the video texture a moment to show the new frame before
    // removing the preview image on top of it.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!_scrubbing && mounted) _showScrubFrame.value = false;
    if (_wasPlayingBeforeScrub && !_scrubbing) _ctrl?.play();
  }

  // ------------------------------------------------------------------ edits

  void _changed() {
    setState(() {});
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveNow);
  }

  String _snapshot() => jsonEncode({
        'a': [for (final a in _p.annotations) a.toJson()],
        's': [for (final s in _p.slowMos) s.toJson()],
      });

  void _restore(String snap) {
    final m = jsonDecode(snap) as Map<String, dynamic>;
    _p.annotations
      ..clear()
      ..addAll([for (final a in m['a'] as List) Annotation.fromJson(Map<String, dynamic>.from(a as Map))]);
    _p.slowMos
      ..clear()
      ..addAll([for (final s in m['s'] as List) SlowMoSegment.fromJson(Map<String, dynamic>.from(s as Map))]);
    if (_selected == null) _selectedId = null;
    _changed();
  }

  /// Call before every edit so it can be undone.
  void _checkpoint() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > 100) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undoLast() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    _restore(_undoStack.removeLast());
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    _restore(_redoStack.removeLast());
  }

  /// Visibility length for a new note starting at [startMs].
  int _newNoteDuration(int startMs, {int extra = 0}) =>
      _manualHide ? math.max(_durationMs - startMs, 500) : _noteDurationMs + extra;

  void _select(Annotation? a) => setState(() => _selectedId = a?.id);

  void _hideSelectedHere() {
    final a = _selected;
    if (a == null) return;
    final pos = _pos.value;
    if (pos <= a.startMs + 100) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tua tới sau thời điểm note xuất hiện rồi bấm "Ẩn tại đây"')));
      return;
    }
    _checkpoint();
    a.durationMs = pos - a.startMs;
    _selectedId = null;
    _changed();
  }

  void _showSelectedFromHere() {
    final a = _selected;
    if (a == null) return;
    final pos = _pos.value;
    final end = a.endMs;
    _checkpoint();
    a.startMs = pos;
    a.durationMs = end > pos + 500 ? end - pos : _newNoteDuration(pos);
    _changed();
  }

  void _deleteSelected() {
    final a = _selected;
    if (a == null) return;
    _checkpoint();
    _p.annotations.remove(a);
    _selectedId = null;
    _changed();
  }

  void _saveNow() => Storage.saveProject(_p);

  Offset _norm(Offset local, Size size) =>
      Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));

  AnnotationType? get _toolType => switch (_tool) {
        Tool.pen => AnnotationType.pen,
        Tool.ellipse => AnnotationType.ellipse,
        Tool.rect => AnnotationType.rect,
        Tool.arrow => AnnotationType.arrow,
        Tool.text => AnnotationType.text,
        Tool.hand => null,
      };

  void _onPanStart(Offset local, Size size) {
    final type = _toolType;
    if (type == null || type == AnnotationType.text) return;
    if (_pauseWhileDrawing && _isPlaying) {
      _resumeAfterDraw = true;
      _ctrl!.pause();
    }
    final p = _norm(local, size);
    _draftWallStart = _clock.elapsedMilliseconds;
    setState(() {
      _draft = Annotation(
        id: newId(),
        type: type,
        startMs: _pos.value,
        durationMs: _noteDurationMs,
        color: _color.toARGB32(),
        strokeWidth: _strokeLevels[_sizeLevel],
        points: type == AnnotationType.pen ? [p] : [p, p],
        revealMs: _animate ? defaultRevealMs(type) : 0,
      );
    });
  }

  void _onPanUpdate(Offset local, Size size) {
    final draft = _draft;
    if (draft == null) return;
    final p = _norm(local, size);
    setState(() {
      if (draft.type == AnnotationType.pen) {
        draft.points.add(p);
      } else {
        draft.points[1] = p;
      }
    });
  }

  void _onPanEnd(Size size) {
    final draft = _draft;
    if (draft == null) return;
    _draft = null;
    final first = draft.points.first;
    final last = draft.points.last;
    final tooSmall = draft.type != AnnotationType.pen &&
        ((first.dx - last.dx) * size.width).abs() < 8 &&
        ((first.dy - last.dy) * size.height).abs() < 8;
    if (!tooSmall) {
      // Time spent drawing while the video ran counts towards visibility, so
      // the note stays up for the chosen duration after you lift your finger.
      final wallMs = _clock.elapsedMilliseconds - _draftWallStart;
      final drawnFor = _isPlaying ? (wallMs * _appliedSpeed).round() : 0;
      draft.durationMs = _newNoteDuration(draft.startMs, extra: drawnFor);
      if (_animate && draft.type == AnnotationType.pen) {
        draft.revealMs = defaultRevealMs(AnnotationType.pen, drawnMs: wallMs);
      }
      _checkpoint();
      _p.annotations.add(draft);
      _lastCommitAt = _clock.elapsedMilliseconds;
      if (_manualHide) _selectedId = draft.id;
      _changed();
    } else {
      setState(() {});
    }
    if (_resumeAfterDraw) {
      _resumeAfterDraw = false;
      _ctrl?.play();
    }
  }

  Future<void> _addTextAt(Offset local, Size size) async {
    final wasPlaying = _isPlaying;
    final at = _pos.value;
    if (wasPlaying) await _ctrl!.pause();
    if (!mounted) return;
    final text = await _promptText(context, title: 'Ghi chú tại ${formatMs(at, tenths: true)}');
    if (text != null && text.trim().isNotEmpty) {
      final a = Annotation(
        id: newId(),
        type: AnnotationType.text,
        startMs: at,
        durationMs: _newNoteDuration(at),
        color: _color.toARGB32(),
        points: [_norm(local, size)],
        text: text.trim(),
        fontSize: _fontLevels[_sizeLevel],
        revealMs: _animate ? defaultRevealMs(AnnotationType.text, text: text.trim()) : 0,
      );
      _checkpoint();
      _p.annotations.add(a);
      if (_manualHide) _selectedId = a.id;
      _changed();
    }
    if (wasPlaying) await _ctrl?.play();
  }


  void _toggleSlowMo() {
    if (_slowMoStartMs == null) {
      setState(() => _slowMoStartMs = _pos.value);
      if (!_isPlaying) _ctrl?.play();
    } else {
      _finishSlowMo();
    }
  }

  void _finishSlowMo() {
    final start = _slowMoStartMs;
    if (start == null) return;
    final end = _pos.value;
    _slowMoStartMs = null;
    if (end - start >= 200) {
      _checkpoint();
      _p.addSlowMo(SlowMoSegment(startMs: start, endMs: end, speed: _slowMoSpeed));
      _changed();
    } else {
      setState(() {});
    }
  }

  Annotation? _hitTest(Offset local, Size size) {
    // The selected note wins, even when only its ghost is shown.
    final sel = _selected;
    if (sel != null && AnnotationRenderer.bounds(sel, size).inflate(12).contains(local)) return sel;
    final visible = _p.visibleAt(_pos.value).reversed;
    for (final a in visible) {
      if (AnnotationRenderer.bounds(a, size).inflate(8).contains(local)) return a;
    }
    return null;
  }

  // Hand tool: tap selects a note (or plays/pauses), dragging a note moves
  // it, dragging elsewhere scrubs the video.
  void _handTap(Offset local, Size size) {
    final hit = _hitTest(local, size);
    if (hit != null) {
      _select(_selectedId == hit.id ? null : hit);
    } else if (_selectedId != null) {
      _select(null);
    } else {
      _togglePlay();
    }
  }

  void _handPanStart(Offset local, Size size) {
    final hit = _hitTest(local, size);
    if (hit != null) {
      _ctrl?.pause();
      _checkpoint();
      setState(() {
        _selectedId = hit.id;
        _moving = true;
      });
    } else {
      _scrubStart();
      _jogMs = _pos.value.toDouble();
    }
  }

  /// [delta] is in video-local pixels (already divided by the zoom factor).
  void _handPanUpdate(Offset delta, Size size) {
    if (_moving) {
      _selected?.translate(Offset(delta.dx / size.width, delta.dy / size.height));
      setState(() {});
    } else if (_scrubbing) {
      // Jog: a full swipe across the video moves ~8 seconds.
      _jogMs = (_jogMs + delta.dx * _zoom / size.width * 8000).clamp(0, _durationMs.toDouble());
      _seekTo(_jogMs.round());
    }
  }

  void _handPanEnd() {
    if (_moving) {
      setState(() => _moving = false);
      _changed();
    } else {
      _scrubEnd();
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> _export() async {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    if (!_p.hasEdits) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chưa có note hay slow-mo nào để xuất')));
      return;
    }
    await ctrl.pause();
    final info = _info ?? await FfmpegService.probe(_p.videoPath);
    final w = info?.displayWidth ?? ctrl.value.size.width.round();
    final h = info?.displayHeight ?? ctrl.value.size.height.round();
    if (w <= 0 || h <= 0 || !mounted) return;

    final dir = await Storage.tempDir('overlays');
    final overlays = await renderOverlays(
      annotations: _p.annotations,
      videoWidth: w,
      videoHeight: h,
      outDir: dir,
      durationMs: _durationMs,
    );
    final out = await Storage.newOutputPath(_p.videoPath, 'note', 'mp4');
    final args = buildExportArgs(
      input: _p.videoPath,
      output: out,
      overlays: overlays,
      slowMos: _p.slowMos,
      durationMs: _durationMs,
      hasAudio: info?.hasAudio ?? true,
    );
    if (!mounted) return;
    final path = await runJobWithProgress(
      context,
      title: 'Đang xuất video kèm note…',
      args: args,
      outputPath: out,
      outputDurationMs: exportedDurationMs(_p.slowMos, _durationMs),
    );
    if (path == null || !mounted) return;
    await showResultSheet(
      context,
      path: path,
      sourceSizeBytes: info?.sizeBytes,
      onOpenInEditor: () => openEditor(context, projectForOutput(path, folder: _p.folder)),
    );
  }

  Future<void> _openTrim() async {
    await _ctrl?.pause();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TrimScreen(project: _p, info: _info, initialPositionMs: _pos.value),
    ));
  }

  Future<void> _openConvert() async {
    await _ctrl?.pause();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConvertScreen(project: _p, info: _info),
    ));
  }

  Future<void> _rename() async {
    final name = await _promptText(context, title: 'Đổi tên project', initial: _p.name, action: 'Lưu');
    if (name == null || name.trim().isEmpty) return;
    _p.name = name.trim();
    _changed();
  }

  void _showInfo() {
    final i = _info;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Thông tin video'),
        content: i == null
            ? const Text('Không đọc được thông tin.')
            : Text([
                'Độ phân giải: ${i.displayWidth}×${i.displayHeight}${i.rotation != 0 ? ' (xoay ${i.rotation}°)' : ''}',
                'Thời lượng: ${formatMs(i.durationMs, tenths: true)}',
                'FPS: ${i.fps?.toStringAsFixed(2) ?? '—'}',
                'Video codec: ${i.videoCodec ?? '—'}',
                'Audio codec: ${i.audioCodec ?? 'không có'}',
                'Bitrate: ${i.bitrate != null ? '${(i.bitrate! / 1000).round()} kbps' : '—'}',
                'Dung lượng: ${formatBytes(i.sizeBytes)}',
                'Định dạng: ${i.format ?? '—'}',
              ].join('\n')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
      ),
    );
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _rename,
          child: Text(_p.name, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          IconButton(tooltip: 'Hoàn tác', icon: const Icon(Icons.undo), onPressed: _undoStack.isEmpty ? null : _undoLast),
          IconButton(tooltip: 'Làm lại', icon: const Icon(Icons.redo), onPressed: _redoStack.isEmpty ? null : _redo),
          PopupMenuButton<String>(
            enabled: ctrl != null,
            onSelected: (v) => switch (v) {
              'export' => _export(),
              'trim' => _openTrim(),
              'convert' => _openConvert(),
              _ => _showInfo(),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.movie_creation_outlined), title: Text('Xuất video kèm note'))),
              PopupMenuItem(value: 'trim', child: ListTile(leading: Icon(Icons.content_cut), title: Text('Cắt video'))),
              PopupMenuItem(value: 'convert', child: ListTile(leading: Icon(Icons.tune), title: Text('Chuyển đổi / nén'))),
              PopupMenuItem(value: 'info', child: ListTile(leading: Icon(Icons.info_outline), title: Text('Thông tin video'))),
            ],
          ),
        ],
      ),
      body: _loadError != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_loadError!, textAlign: TextAlign.center)))
          : ctrl == null
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      Expanded(child: _buildVideo(ctrl)),
                      _buildTransport(),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: ValueListenableBuilder<int>(
                          valueListenable: _pos,
                          builder: (_, pos, _) => NoteTimeline(
                            durationMs: _durationMs,
                            positionMs: pos,
                            annotations: _p.annotations,
                            slowMos: _p.slowMos,
                            pendingSlowMoStartMs: _slowMoStartMs,
                            selectedId: _selectedId,
                            onSeekStart: _scrubStart,
                            onSeek: _seekTo,
                            onSeekEnd: _scrubEnd,
                            onPrecisionChanged: (p) => setState(() => _scrubPrecision = p),
                          ),
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 150),
                        child: _selected != null ? _buildSelectionBar() : _buildTools(),
                      ),
                    ],
                  ),
                ),
    );
  }

  Offset _toVideo(Offset screen) => (screen - _zoomOffset) / _zoom;

  Offset _clampOffset(Offset o, Size size) => Offset(
        o.dx.clamp(size.width - size.width * _zoom, 0.0),
        o.dy.clamp(size.height - size.height * _zoom, 0.0),
      );

  void _resetZoom() => setState(() {
        _zoom = 1;
        _zoomOffset = Offset.zero;
      });

  void _gestureStart(ScaleStartDetails d, Size size) {
    if (d.pointerCount >= 2) {
      // A second finger turns the gesture into pinch-zoom: drop anything a
      // single finger had just started.
      if (_oneFingerActive) _oneFingerEnd(size, cancel: true);
      if (_clock.elapsedMilliseconds - _lastCommitAt < 350) _undoLast();
      _pinching = true;
      _pinchStartZoom = _zoom;
      _pinchStartOffset = _zoomOffset;
      _pinchStartFocal = d.localFocalPoint;
      return;
    }
    _pinching = false;
    _oneFingerActive = true;
    final local = _toVideo(d.localFocalPoint);
    // When zoomed in, a one-finger drag on empty space pans the view.
    _panningView = _zoom > 1 &&
        (_tool == Tool.text || (_tool == Tool.hand && _hitTest(local, size) == null));
    if (_panningView) return;
    if (_tool == Tool.hand) {
      _handPanStart(local, size);
    } else if (_tool != Tool.text) {
      _onPanStart(local, size);
    }
  }

  void _gestureUpdate(ScaleUpdateDetails d, Size size) {
    if (_pinching) {
      if (d.pointerCount < 2) return;
      final z = (_pinchStartZoom * d.scale).clamp(1.0, 6.0);
      // Keep the video point under the starting focal point under the fingers.
      final videoPt = (_pinchStartFocal - _pinchStartOffset) / _pinchStartZoom;
      setState(() {
        _zoom = z;
        _zoomOffset = _clampOffset(d.localFocalPoint - videoPt * z, size);
      });
      return;
    }
    if (!_oneFingerActive) return;
    if (_panningView) {
      setState(() => _zoomOffset = _clampOffset(_zoomOffset + d.focalPointDelta, size));
      return;
    }
    if (_tool == Tool.hand) {
      _handPanUpdate(d.focalPointDelta / _zoom, size);
    } else if (_tool != Tool.text) {
      _onPanUpdate(_toVideo(d.localFocalPoint), size);
    }
  }

  void _gestureEnd(Size size) {
    if (_pinching) {
      _pinching = false;
      if (_zoom < 1.05) _resetZoom();
      return;
    }
    _oneFingerEnd(size);
  }

  void _oneFingerEnd(Size size, {bool cancel = false}) {
    if (!_oneFingerActive) return;
    _oneFingerActive = false;
    if (_panningView) {
      _panningView = false;
      return;
    }
    if (_tool == Tool.hand) {
      _handPanEnd();
    } else if (cancel) {
      setState(() => _draft = null);
    } else {
      _onPanEnd(size);
    }
  }

  Widget _buildVideo(VideoPlayerController ctrl) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: AspectRatio(
        aspectRatio: ctrl.value.aspectRatio,
        child: LayoutBuilder(builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          final hand = _tool == Tool.hand;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: hand
                ? (d) => _handTap(_toVideo(d.localPosition), size)
                : _tool == Tool.text
                    ? (d) => _addTextAt(_toVideo(d.localPosition), size)
                    : null,
            onLongPressStart: hand
                ? (d) {
                    final hit = _hitTest(_toVideo(d.localPosition), size);
                    if (hit != null) _editAnnotation(hit);
                  }
                : null,
            onScaleStart: (d) => _gestureStart(d, size),
            onScaleUpdate: (d) => _gestureUpdate(d, size),
            onScaleEnd: (_) => _gestureEnd(size),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(
                  child: Transform(
                    transform: Matrix4.identity()
                      ..translateByDouble(_zoomOffset.dx, _zoomOffset.dy, 0, 1)
                      ..scaleByDouble(_zoom, _zoom, 1, 1),
                    child: Stack(fit: StackFit.expand, children: [
                      VideoPlayer(ctrl),
                      _buildScrubFrame(),
                      ValueListenableBuilder<int>(
                        valueListenable: _pos,
                        builder: (_, pos, _) => CustomPaint(
                          painter: AnnotationPainter(
                            annotations: _p.visibleAt(pos),
                            positionMs: pos,
                            draft: _draft,
                            selected: _selected,
                            moving: _moving,
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
                if (_zoom > 1)
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: _resetZoom,
                      child: _Badge(color: Colors.white, icon: Icons.zoom_out_map, label: '${_zoom.toStringAsFixed(1)}x · chạm để về 1x'),
                    ),
                  ),
                if (_scrubPrecision != null && _scrubPrecision! < 1)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _Badge(
                      color: Colors.lightBlueAccent,
                      icon: Icons.tune,
                      label: 'Tua chậm ×${_scrubPrecision == 0.25 ? '¼' : '⅒'}',
                    ),
                  ),
                if (_slowMoStartMs != null || _appliedSpeed != 1.0)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _Badge(
                      color: _slowMoStartMs != null ? Colors.red : Colors.orange,
                      icon: _slowMoStartMs != null ? Icons.fiber_manual_record : Icons.slow_motion_video,
                      label: _slowMoStartMs != null ? 'Đang ghi slow-mo ${formatSpeed(_slowMoSpeed)}' : formatSpeed(_appliedSpeed),
                    ),
                  ),
                if (!_isPlaying && hand && _selectedId == null && !_scrubbing && !_moving)
                  const IgnorePointer(child: Center(child: Icon(Icons.play_circle_fill, size: 64, color: Colors.white54))),
              ],
            ),
          );
        }),
      ),
    );
  }

  /// Low-res cached frame shown on top of the player while scrubbing.
  Widget _buildScrubFrame() {
    return ValueListenableBuilder<bool>(
      valueListenable: _showScrubFrame,
      builder: (_, show, _) {
        if (!show) return const SizedBox.shrink();
        return ValueListenableBuilder<int>(
          valueListenable: _pos,
          builder: (_, pos, _) {
            final f = _frames?.frameAt(pos);
            if (f == null) return const SizedBox.shrink();
            return Image.file(f, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.low);
          },
        );
      },
    );
  }

  /// Actions for the selected note, shown in place of the tool rows.
  Widget _buildSelectionBar() {
    final a = _selected!;
    return Container(
      key: const ValueKey('selection'),
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_iconFor(a.type), color: Color(a.color), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _pos,
              builder: (_, _, _) => Text(
                '${a.type == AnnotationType.text ? '"${a.text}"' : _labelFor(a.type)} · '
                '${formatMs(a.startMs, tenths: true)} → ${formatMs(a.endMs, tenths: true)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          IconButton(tooltip: 'Bỏ chọn', icon: const Icon(Icons.close), onPressed: () => _select(null)),
        ]),
        Text('Kéo note trên video để di chuyển. Tua tới chỗ cần ẩn rồi bấm "Ẩn tại đây".',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          FilledButton.icon(
            icon: const Icon(Icons.visibility_off_outlined, size: 18),
            label: const Text('Ẩn tại đây'),
            onPressed: _hideSelectedHere,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('Hiện từ đây'),
            onPressed: _showSelectedFromHere,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Sửa'),
            onPressed: () => _editAnnotation(a),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Xoá'),
            onPressed: _deleteSelected,
          ),
        ]),
      ]),
    );
  }

  Widget _buildTransport() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow), onPressed: _togglePlay),
          IconButton(tooltip: 'Lùi 1 khung hình', icon: const Icon(Icons.chevron_left), onPressed: () => _stepFrame(-1)),
          IconButton(tooltip: 'Tiến 1 khung hình', icon: const Icon(Icons.chevron_right), onPressed: () => _stepFrame(1)),
          IconButton(tooltip: 'Lùi 5s', icon: const Icon(Icons.replay_5), onPressed: () => _seekTo(_pos.value - 5000)),
          IconButton(tooltip: 'Tiến 5s', icon: const Icon(Icons.forward_5), onPressed: () => _seekTo(_pos.value + 5000)),
          const Spacer(),
          ValueListenableBuilder<int>(
            valueListenable: _pos,
            builder: (_, pos, _) => Text(
              '${formatMs(pos, tenths: true)} / ${formatMs(_durationMs)}',
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          PopupMenuButton<double>(
            tooltip: 'Tốc độ phát',
            initialValue: _baseSpeed,
            onSelected: (s) => setState(() => _baseSpeed = s),
            itemBuilder: (_) => [for (final s in kSpeeds) PopupMenuItem(value: s, child: Text(formatSpeed(s)))],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(formatSpeed(_baseSpeed), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolButton(Tool t, IconData icon, String tip) {
    final selected = _tool == t;
    return IconButton(
      tooltip: tip,
      isSelected: selected,
      style: selected ? IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primaryContainer) : null,
      icon: Icon(icon),
      onPressed: () => setState(() => _tool = t),
    );
  }

  Widget _buildTools() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            _toolButton(Tool.hand, Icons.pan_tool_alt_outlined, 'Xem / chọn note (nhấn giữ để sửa)'),
            _toolButton(Tool.pen, Icons.gesture, 'Vẽ tự do / khoanh vùng'),
            _toolButton(Tool.ellipse, Icons.circle_outlined, 'Khoanh tròn'),
            _toolButton(Tool.rect, Icons.crop_square, 'Khung chữ nhật'),
            _toolButton(Tool.arrow, Icons.north_east, 'Mũi tên'),
            _toolButton(Tool.text, Icons.text_fields, 'Chạm vào video để gõ note'),
            const SizedBox(width: 4),
            _ColorButton(color: _color, onPick: (c) => setState(() => _color = c)),
            IconButton(
              tooltip: 'Độ dày nét / cỡ chữ',
              icon: Icon(Icons.line_weight, size: 18.0 + _sizeLevel * 4),
              onPressed: () => setState(() => _sizeLevel = (_sizeLevel + 1) % 3),
            ),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(children: [
            PopupMenuButton<int>(
              tooltip: 'Thời gian note hiển thị',
              onSelected: (v) => setState(() {
                _manualHide = v < 0;
                if (v > 0) _noteDurationMs = v;
              }),
              itemBuilder: (_) => [
                for (final s in [1, 2, 3, 5, 8, 10]) PopupMenuItem(value: s * 1000, child: Text('Hiện $s giây')),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: -1,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Đến khi bấm ẩn'),
                    subtitle: Text('Note hiện mãi, tua tới chỗ cần ẩn rồi bấm "Ẩn tại đây"'),
                  ),
                ),
              ],
              child: Chip(
                avatar: const Icon(Icons.timer_outlined, size: 18),
                label: Text(_manualHide ? 'Đến khi ẩn' : '${_noteDurationMs ~/ 1000}s'),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              avatar: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Hiệu ứng'),
              tooltip: 'Nét vẽ hiện dần, chữ hiện kiểu gõ phím',
              selected: _animate,
              showCheckmark: false,
              onSelected: (v) => setState(() => _animate = v),
            ),
            const SizedBox(width: 8),
            FilterChip(
              avatar: const Icon(Icons.pause_circle_outline, size: 18),
              label: const Text('Dừng khi vẽ'),
              selected: _pauseWhileDrawing,
              showCheckmark: false,
              onSelected: (v) => setState(() => _pauseWhileDrawing = v),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onLongPress: _pickSlowMoSpeed,
              child: FilterChip(
                avatar: Icon(_slowMoStartMs != null ? Icons.stop_circle : Icons.slow_motion_video,
                    size: 18, color: _slowMoStartMs != null ? Colors.red : null),
                label: Text(_slowMoStartMs != null ? 'Dừng slow-mo' : 'Slow-mo ${formatSpeed(_slowMoSpeed)}'),
                selected: _slowMoStartMs != null,
                selectedColor: scheme.errorContainer,
                showCheckmark: false,
                onSelected: (_) => _toggleSlowMo(),
              ),
            ),
            IconButton(tooltip: 'Tốc độ slow-mo', icon: const Icon(Icons.expand_more), onPressed: _pickSlowMoSpeed),
            Badge(
              isLabelVisible: _p.annotations.isNotEmpty || _p.slowMos.isNotEmpty,
              label: Text('${_p.annotations.length + _p.slowMos.length}'),
              child: IconButton(tooltip: 'Danh sách note', icon: const Icon(Icons.list_alt), onPressed: _showNotesList),
            ),
          ]),
        ),
      ],
    );
  }

  Future<void> _pickSlowMoSpeed() async {
    final s = await showModalBottomSheet<double>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<double>(
          groupValue: _slowMoSpeed,
          onChanged: (v) => Navigator.pop(ctx, v),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const ListTile(title: Text('Tốc độ slow-mo')),
            for (final s in [0.75, 0.5, 0.25, 0.125])
              RadioListTile<double>(
                value: s,
                title: Text('${formatSpeed(s)}  (chậm ${(1 / s).toStringAsFixed(s == 0.75 ? 1 : 0)} lần)'),
              ),
          ]),
        ),
      ),
    );
    if (s != null) setState(() => _slowMoSpeed = s);
  }

  // ------------------------------------------------------------------ notes list / edit

  Future<void> _showNotesList() async {
    await _ctrl?.pause();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final notes = [..._p.annotations]..sort((a, b) => a.startMs.compareTo(b.startMs));
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (_, scroll) => ListView(
            controller: scroll,
            children: [
              ListTile(title: Text('Note (${notes.length})', style: Theme.of(ctx).textTheme.titleMedium)),
              if (notes.isEmpty) const ListTile(subtitle: Text('Chọn công cụ vẽ hoặc T rồi thao tác trên video khi đang phát.')),
              for (final a in notes)
                ListTile(
                  leading: Icon(_iconFor(a.type), color: Color(a.color)),
                  title: Text(a.type == AnnotationType.text ? a.text : _labelFor(a.type), maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${formatMs(a.startMs, tenths: true)} → ${formatMs(a.endMs, tenths: true)}'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _seekTo(a.startMs + 1);
                    _select(a);
                  },
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        await _editAnnotation(a);
                        setSheet(() {});
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        _checkpoint();
                        _p.annotations.remove(a);
                        if (_selectedId == a.id) _selectedId = null;
                        _changed();
                        setSheet(() {});
                      },
                    ),
                  ]),
                ),
              const Divider(),
              ListTile(title: Text('Slow-mo (${_p.slowMos.length})', style: Theme.of(ctx).textTheme.titleMedium)),
              if (_p.slowMos.isEmpty) const ListTile(subtitle: Text('Bấm "Slow-mo" khi đang phát để bắt đầu, bấm lại để kết thúc đoạn.')),
              for (final s in _p.slowMos)
                ListTile(
                  leading: const Icon(Icons.slow_motion_video, color: Colors.orange),
                  title: Text(formatSpeed(s.speed)),
                  subtitle: Text('${formatMs(s.startMs, tenths: true)} → ${formatMs(s.endMs, tenths: true)}'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _seekTo(s.startMs);
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      _checkpoint();
                      _p.slowMos.remove(s);
                      _changed();
                      setSheet(() {});
                    },
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        );
      }),
    );
  }

  Future<void> _editAnnotation(Annotation a) async {
    final previousSelection = _selectedId;
    setState(() => _selectedId = a.id);
    await _ctrl?.pause();
    var checkpointed = false;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void update(VoidCallback f) {
          if (!checkpointed) {
            _checkpoint();
            checkpointed = true;
          }
          f();
          _changed();
          setSheet(() {});
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(_iconFor(a.type), color: Color(a.color)),
                const SizedBox(width: 8),
                Expanded(child: Text(_labelFor(a.type), style: Theme.of(ctx).textTheme.titleMedium)),
                if (a.type == AnnotationType.text)
                  TextButton.icon(
                    icon: const Icon(Icons.edit),
                    label: const Text('Sửa chữ'),
                    onPressed: () async {
                      final t = await _promptText(ctx, title: 'Sửa note', initial: a.text);
                      if (t != null && t.trim().isNotEmpty) update(() => a.text = t.trim());
                    },
                  ),
              ]),
              const SizedBox(height: 8),
              Text('Bắt đầu: ${formatMs(a.startMs, tenths: true)}'),
              Row(children: [
                OutlinedButton(onPressed: () => update(() => a.startMs = (a.startMs - 500).clamp(0, _durationMs)), child: const Text('-0.5s')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => update(() => a.startMs = (a.startMs + 500).clamp(0, _durationMs)), child: const Text('+0.5s')),
                const SizedBox(width: 8),
                TextButton(onPressed: () => update(() => a.startMs = _pos.value), child: const Text('= vị trí hiện tại')),
              ]),
              const SizedBox(height: 8),
              Text('Kết thúc: ${formatMs(a.endMs, tenths: true)}  (hiện ${(a.durationMs / 1000).toStringAsFixed(1)}s)'),
              Row(children: [
                OutlinedButton(
                    onPressed: () => update(() => a.durationMs = math.max(300, a.durationMs - 500)), child: const Text('-0.5s')),
                const SizedBox(width: 8),
                OutlinedButton(
                    onPressed: () => update(() => a.durationMs = math.min(_durationMs - a.startMs, a.durationMs + 500)),
                    child: const Text('+0.5s')),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _pos.value > a.startMs + 100 ? () => update(() => a.durationMs = _pos.value - a.startMs) : null,
                  child: const Text('Ẩn tại vị trí hiện tại'),
                ),
              ]),
              const SizedBox(height: 8),
              Text(a.revealMs == 0
                  ? 'Hiệu ứng xuất hiện: tắt'
                  : 'Hiệu ứng xuất hiện: ${(a.revealMs / 1000).toStringAsFixed(1)}s'),
              Slider(
                min: 0,
                max: 2000,
                divisions: 20,
                value: a.revealMs.clamp(0, 2000).toDouble(),
                onChanged: (v) => update(() => a.revealMs = v.round()),
              ),
              Wrap(spacing: 8, children: [
                for (final c in kNoteColors)
                  GestureDetector(
                    onTap: () => update(() => a.color = c.toARGB32()),
                    child: _ColorDot(color: c, selected: a.color == c.toARGB32()),
                  ),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Xoá note'),
                  onPressed: () {
                    if (!checkpointed) _checkpoint();
                    _p.annotations.remove(a);
                    _changed();
                    Navigator.pop(ctx);
                  },
                ),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Xong')),
              ]),
            ]),
          ),
        );
      }),
    );
    if (mounted) {
      setState(() => _selectedId = _p.annotations.any((x) => x.id == previousSelection) ? previousSelection : null);
    }
  }

  static IconData _iconFor(AnnotationType t) => switch (t) {
        AnnotationType.pen => Icons.gesture,
        AnnotationType.ellipse => Icons.circle_outlined,
        AnnotationType.rect => Icons.crop_square,
        AnnotationType.arrow => Icons.north_east,
        AnnotationType.text => Icons.text_fields,
      };

  static String _labelFor(AnnotationType t) => switch (t) {
        AnnotationType.pen => 'Nét vẽ',
        AnnotationType.ellipse => 'Khoanh tròn',
        AnnotationType.rect => 'Khung',
        AnnotationType.arrow => 'Mũi tên',
        AnnotationType.text => 'Ghi chú chữ',
      };
}

Future<String?> _promptText(BuildContext context, {required String title, String initial = '', String action = 'Thêm'}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        minLines: 1,
        maxLines: 4,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Nhập…'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Huỷ')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(action)),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, required this.icon, required this.label});
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ]),
      );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, this.selected = false});
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Colors.grey,
            width: selected ? 3 : 1,
          ),
        ),
      );
}

class _ColorButton extends StatelessWidget {
  const _ColorButton({required this.color, required this.onPick});
  final Color color;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) => PopupMenuButton<Color>(
        tooltip: 'Màu',
        onSelected: onPick,
        itemBuilder: (_) => [
          PopupMenuItem<Color>(
            enabled: false,
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in kNoteColors)
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    onPick(c);
                  },
                  child: _ColorDot(color: c, selected: c == color),
                ),
            ]),
          ),
        ],
        child: Padding(padding: const EdgeInsets.all(8), child: _ColorDot(color: color, selected: true)),
      );
}
