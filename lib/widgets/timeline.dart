import 'package:flutter/material.dart';

import '../models/annotation.dart';

/// Scrubbable timeline showing note time windows and slow-mo ranges.
///
/// Dragging is relative to where the finger went down, and gets finer the
/// further the finger moves away from the bar vertically (like precise
/// seeking in video apps): 1x near the bar, 1/4 a bit away, 1/10 far away.
class NoteTimeline extends StatefulWidget {
  const NoteTimeline({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.annotations,
    required this.slowMos,
    required this.onSeek,
    this.pendingSlowMoStartMs,
    this.selectedId,
    this.onSeekStart,
    this.onSeekEnd,
    this.onPrecisionChanged,
  });

  final int durationMs;
  final int positionMs;
  final List<Annotation> annotations;
  final List<SlowMoSegment> slowMos;
  final int? pendingSlowMoStartMs;
  final String? selectedId;
  final ValueChanged<int> onSeek;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  /// Reports the current scrub precision (1, 0.25, 0.1) while dragging.
  final ValueChanged<double>? onPrecisionChanged;

  static const height = 64.0;

  @override
  State<NoteTimeline> createState() => _NoteTimelineState();
}

class _NoteTimelineState extends State<NoteTimeline> {
  double _scrubMs = 0;
  double _precision = 1;

  double _precisionFor(double dy) {
    final away = (dy - NoteTimeline.height / 2).abs();
    if (away < 60) return 1;
    if (away < 150) return 0.25;
    return 0.1;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final d = widget.durationMs;
      int toMs(double dx) => d <= 0 ? 0 : (dx / w * d).round().clamp(0, d);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (e) => widget.onSeek(toMs(e.localPosition.dx)),
        onPanStart: (e) {
          widget.onSeekStart?.call();
          _scrubMs = toMs(e.localPosition.dx).toDouble();
          _precision = 1;
          widget.onPrecisionChanged?.call(1);
          widget.onSeek(_scrubMs.round());
        },
        onPanUpdate: (e) {
          final p = _precisionFor(e.localPosition.dy);
          if (p != _precision) {
            _precision = p;
            widget.onPrecisionChanged?.call(p);
          }
          if (d <= 0) return;
          _scrubMs = (_scrubMs + e.delta.dx / w * d * p).clamp(0, d.toDouble());
          widget.onSeek(_scrubMs.round());
        },
        onPanEnd: (_) => widget.onSeekEnd?.call(),
        onPanCancel: () => widget.onSeekEnd?.call(),
        child: CustomPaint(
          size: Size(w, NoteTimeline.height),
          painter: _TimelinePainter(
            durationMs: d,
            positionMs: widget.positionMs,
            annotations: widget.annotations,
            slowMos: widget.slowMos,
            pendingSlowMoStartMs: widget.pendingSlowMoStartMs,
            selectedId: widget.selectedId,
            trackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            playheadColor: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    });
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.durationMs,
    required this.positionMs,
    required this.annotations,
    required this.slowMos,
    required this.pendingSlowMoStartMs,
    required this.selectedId,
    required this.trackColor,
    required this.playheadColor,
  });

  final int durationMs;
  final int positionMs;
  final List<Annotation> annotations;
  final List<SlowMoSegment> slowMos;
  final int? pendingSlowMoStartMs;
  final String? selectedId;
  final Color trackColor;
  final Color playheadColor;

  static const _lanes = 3;
  static const _slowMoColor = Color(0xFFFFA726);

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs <= 0) return;
    double x(int ms) => ms / durationMs * size.width;

    // Track
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, 8, size.width, size.height - 16), const Radius.circular(6));
    canvas.drawRRect(track, Paint()..color = trackColor);

    // Played portion
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 8, x(positionMs), size.height - 16), const Radius.circular(6)),
      Paint()..color = playheadColor.withValues(alpha: 0.18),
    );

    // Slow-mo ranges along the bottom
    final slowPaint = Paint()..color = _slowMoColor;
    for (final s in slowMos) {
      canvas.drawRect(Rect.fromLTRB(x(s.startMs), size.height - 14, x(s.endMs), size.height - 8), slowPaint);
    }
    if (pendingSlowMoStartMs != null) {
      canvas.drawRect(
        Rect.fromLTRB(x(pendingSlowMoStartMs!), size.height - 14, x(positionMs), size.height - 8),
        Paint()..color = _slowMoColor.withValues(alpha: 0.5),
      );
    }

    // Notes in up to three lanes, assigned greedily by start time.
    final laneEnd = List<int>.filled(_lanes, -1);
    final sorted = [...annotations]..sort((a, b) => a.startMs.compareTo(b.startMs));
    const laneTop = 12.0;
    const laneH = 7.0;
    for (final a in sorted) {
      var lane = laneEnd.indexWhere((e) => e <= a.startMs);
      if (lane < 0) lane = _lanes - 1;
      laneEnd[lane] = a.endMs;
      final r = Rect.fromLTRB(x(a.startMs), laneTop + lane * (laneH + 2), x(a.endMs).clamp(x(a.startMs) + 3, size.width), laneTop + lane * (laneH + 2) + laneH);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = Color(a.color));
      if (a.id == selectedId) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(r.inflate(1.5), const Radius.circular(3)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = playheadColor,
        );
      }
    }

    // Playhead
    final px = x(positionMs);
    canvas.drawLine(Offset(px, 2), Offset(px, size.height - 2), Paint()
      ..color = playheadColor
      ..strokeWidth = 2.5);
    canvas.drawCircle(Offset(px, 4), 4, Paint()..color = playheadColor);
  }

  @override
  bool shouldRepaint(_TimelinePainter old) => true;
}
