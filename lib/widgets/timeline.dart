import 'package:flutter/material.dart';

import '../models/annotation.dart';

/// Scrubbable timeline showing note time windows and slow-mo ranges.
class NoteTimeline extends StatelessWidget {
  const NoteTimeline({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.annotations,
    required this.slowMos,
    required this.onSeek,
    this.pendingSlowMoStartMs,
    this.onSeekStart,
    this.onSeekEnd,
  });

  final int durationMs;
  final int positionMs;
  final List<Annotation> annotations;
  final List<SlowMoSegment> slowMos;
  final int? pendingSlowMoStartMs;
  final ValueChanged<int> onSeek;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      int toMs(double dx) => durationMs <= 0 ? 0 : (dx / c.maxWidth * durationMs).round().clamp(0, durationMs);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => onSeek(toMs(d.localPosition.dx)),
        onHorizontalDragStart: (d) {
          onSeekStart?.call();
          onSeek(toMs(d.localPosition.dx));
        },
        onHorizontalDragUpdate: (d) => onSeek(toMs(d.localPosition.dx)),
        onHorizontalDragEnd: (_) => onSeekEnd?.call(),
        child: CustomPaint(
          size: Size(c.maxWidth, 56),
          painter: _TimelinePainter(
            durationMs: durationMs,
            positionMs: positionMs,
            annotations: annotations,
            slowMos: slowMos,
            pendingSlowMoStartMs: pendingSlowMoStartMs,
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
    required this.trackColor,
    required this.playheadColor,
  });

  final int durationMs;
  final int positionMs;
  final List<Annotation> annotations;
  final List<SlowMoSegment> slowMos;
  final int? pendingSlowMoStartMs;
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
