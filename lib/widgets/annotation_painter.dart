import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/annotation.dart';

/// Draws annotations onto a canvas whose size equals the video frame.
///
/// The same code paints the live preview and the full-resolution PNGs used
/// for export, so what you see is what gets burned into the video.
class AnnotationRenderer {
  const AnnotationRenderer._();

  static Offset _px(Offset n, Size s) => Offset(n.dx * s.width, n.dy * s.height);

  static double strokePx(Annotation a, Size s) => math.max(1.5, a.strokeWidth * s.width);

  /// Paints [a] fully drawn, or as it looks at [atMs] when given (partly
  /// revealed while its appear animation runs, fading near its end).
  static void paint(Canvas canvas, Size size, Annotation a, {double opacity = 1, int? atMs}) {
    if (atMs != null) {
      paintFrame(canvas, size, a, progress: a.revealAt(atMs), opacity: opacity * a.opacityAt(atMs));
    } else {
      paintFrame(canvas, size, a, progress: 1, opacity: opacity);
    }
  }

  /// Paints [a] with its appear animation at [progress] (0..1).
  static void paintFrame(Canvas canvas, Size size, Annotation a, {required double progress, double opacity = 1}) {
    if (opacity <= 0) return;
    final color = Color(a.color).withValues(alpha: Color(a.color).a * opacity);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokePx(a, size)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (a.type == AnnotationType.text) {
      _text(canvas, size, a, color, opacity, progress);
      return;
    }
    if (a.type != AnnotationType.pen && a.points.length < 2) return;
    final from = _px(a.points.first, size);
    final to = _px(a.points.last, size);

    switch (a.type) {
      case AnnotationType.pen:
        canvas.drawPath(_partial(_smoothPath([for (final p in a.points) _px(p, size)]), progress), stroke);
      case AnnotationType.ellipse:
        // Circle drawn on clockwise from the top-left, like a hand circling.
        final path = Path()..addArc(Rect.fromPoints(from, to), -math.pi * 0.75, math.pi * 2 * progress);
        canvas.drawPath(path, stroke);
      case AnnotationType.rect:
        final path = Path()
          ..addRRect(RRect.fromRectAndRadius(Rect.fromPoints(from, to), Radius.circular(stroke.strokeWidth)));
        canvas.drawPath(_partial(path, progress), stroke);
      case AnnotationType.arrow:
        // Shaft grows over the first 80%, then the head pops in.
        final shaft = (progress / 0.8).clamp(0.0, 1.0);
        canvas.drawLine(from, Offset.lerp(from, to, shaft)!, stroke);
        final head = ((progress - 0.8) / 0.2).clamp(0.0, 1.0);
        if (head > 0) _arrowHead(canvas, from, to, stroke, head);
      case AnnotationType.text:
        break;
    }
  }

  /// The first [t] (0..1) of [path] by length.
  static Path _partial(Path path, double t) {
    if (t >= 1) return path;
    final metrics = path.computeMetrics().toList();
    final total = metrics.fold<double>(0, (sum, m) => sum + m.length);
    var remaining = total * t;
    final out = Path();
    for (final m in metrics) {
      if (remaining <= 0) break;
      out.addPath(m.extractPath(0, math.min(remaining, m.length)), Offset.zero);
      remaining -= m.length;
    }
    return out;
  }

  static Path _smoothPath(List<Offset> pts) {
    final path = Path();
    if (pts.isEmpty) return path;
    path.moveTo(pts.first.dx, pts.first.dy);
    if (pts.length == 1) {
      path.lineTo(pts.first.dx + 0.1, pts.first.dy);
      return path;
    }
    for (var i = 1; i < pts.length - 1; i++) {
      final mid = (pts[i] + pts[i + 1]) / 2;
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  static double _headLen(double strokeWidth) => strokeWidth * 4 + 8;

  static void _arrowHead(Canvas canvas, Offset from, Offset to, Paint paint, double scale) {
    final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
    final len = _headLen(paint.strokeWidth) * scale;
    for (final d in [math.pi * 0.83, -math.pi * 0.83]) {
      canvas.drawLine(to, to + Offset(math.cos(angle + d), math.sin(angle + d)) * len, paint);
    }
  }

  static const _textPadH = 0.5; // in font-size units
  static const _textPadV = 0.25;

  static TextPainter textPainter(Annotation a, Size size, Color color, {String? text}) {
    final fontPx = math.max(10.0, a.fontSize * size.height);
    return TextPainter(
      text: TextSpan(
        text: text ?? a.text,
        style: TextStyle(color: color, fontSize: fontPx, fontWeight: FontWeight.w600, height: 1.2),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.9);
  }

  /// Rectangle (in pixels) covered by a text note, kept inside the frame.
  static Rect textBox(Annotation a, Size size, TextPainter tp) {
    final fontPx = math.max(10.0, a.fontSize * size.height);
    final w = tp.width + fontPx * _textPadH * 2;
    final h = tp.height + fontPx * _textPadV * 2;
    final anchor = _px(a.points.first, size);
    final left = anchor.dx.clamp(0.0, math.max(0.0, size.width - w)).toDouble();
    final top = anchor.dy.clamp(0.0, math.max(0.0, size.height - h)).toDouble();
    return Rect.fromLTWH(left, top, w, h);
  }

  static void _text(Canvas canvas, Size size, Annotation a, Color color, double opacity, double progress) {
    if (a.text.isEmpty || a.points.isEmpty) return;
    // The box is laid out for the full text so it doesn't grow while typing.
    final full = textPainter(a, size, color);
    final box = textBox(a, size, full);
    final fontPx = math.max(10.0, a.fontSize * size.height);

    // Box pops in over the first 25%, then the text types out.
    final pop = Curves.easeOutBack.transform((progress / 0.25).clamp(0.0, 1.0));
    final boxAlpha = (progress / 0.25).clamp(0.0, 1.0);
    canvas.save();
    if (pop < 1) {
      final c = box.center;
      canvas.translate(c.dx, c.dy);
      canvas.scale(0.85 + 0.15 * pop);
      canvas.translate(-c.dx, -c.dy);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, Radius.circular(fontPx * 0.3)),
      Paint()..color = Colors.black.withValues(alpha: 0.55 * opacity * boxAlpha),
    );
    final typed = ((progress - 0.15) / 0.85).clamp(0.0, 1.0);
    final chars = a.text.characters;
    final shown = (chars.length * typed).ceil();
    if (shown > 0) {
      final tp = shown >= chars.length ? full : textPainter(a, size, color, text: chars.take(shown).toString());
      tp.paint(canvas, box.topLeft + Offset(fontPx * _textPadH, fontPx * _textPadV));
    }
    canvas.restore();
  }

  /// Pixel bounds of everything [paint] draws for [a], used to crop export PNGs.
  static Rect bounds(Annotation a, Size size) {
    if (a.type == AnnotationType.text) {
      return textBox(a, size, textPainter(a, size, Color(a.color)));
    }
    final pts = [for (final p in a.points) _px(p, size)];
    if (pts.isEmpty) return Rect.zero;
    var r = Rect.fromPoints(pts.first, pts.first);
    for (final p in pts) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    final sw = strokePx(a, size);
    final pad = sw + (a.type == AnnotationType.arrow ? _headLen(sw) : 0) + 2;
    return r.inflate(pad);
  }
}

/// Paints every note visible at [positionMs] plus the one being drawn.
class AnnotationPainter extends CustomPainter {
  AnnotationPainter({
    required this.annotations,
    required this.positionMs,
    this.draft,
    this.selected,
    this.moving = false,
  });

  final List<Annotation> annotations;
  final int positionMs;
  final Annotation? draft;

  /// The selected note gets a frame. When it isn't visible at [positionMs]
  /// it is drawn as a faint ghost so it can still be moved or re-timed.
  final Annotation? selected;

  /// While the selected note is dragged it is drawn fully, without animation.
  final bool moving;

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in annotations) {
      if (identical(a, selected)) continue;
      AnnotationRenderer.paint(canvas, size, a, atMs: positionMs);
    }
    final sel = selected;
    if (sel != null) {
      final visible = sel.isVisibleAt(positionMs);
      if (moving) {
        AnnotationRenderer.paint(canvas, size, sel);
      } else if (visible) {
        AnnotationRenderer.paint(canvas, size, sel, atMs: positionMs);
      } else {
        AnnotationRenderer.paint(canvas, size, sel, opacity: 0.35);
      }
      final r = RRect.fromRectAndRadius(AnnotationRenderer.bounds(sel, size).inflate(4), const Radius.circular(4));
      canvas.drawRRect(r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = Colors.black45);
      canvas.drawRRect(r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = visible || moving ? Colors.white : Colors.white54);
    }
    if (draft != null) AnnotationRenderer.paint(canvas, size, draft!, opacity: 0.85);
  }

  // Drafts are mutated in place while drawing and the list is cheap to
  // paint, so always repaint.
  @override
  bool shouldRepaint(AnnotationPainter old) => true;
}
