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

  static void paint(Canvas canvas, Size size, Annotation a, {double opacity = 1}) {
    final color = Color(a.color).withValues(alpha: Color(a.color).a * opacity);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokePx(a, size)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (a.type) {
      case AnnotationType.pen:
        canvas.drawPath(_smoothPath([for (final p in a.points) _px(p, size)]), stroke);
      case AnnotationType.ellipse:
        if (a.points.length < 2) return;
        canvas.drawOval(Rect.fromPoints(_px(a.points.first, size), _px(a.points.last, size)), stroke);
      case AnnotationType.rect:
        if (a.points.length < 2) return;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromPoints(_px(a.points.first, size), _px(a.points.last, size)),
            Radius.circular(stroke.strokeWidth),
          ),
          stroke,
        );
      case AnnotationType.arrow:
        if (a.points.length < 2) return;
        _arrow(canvas, _px(a.points.first, size), _px(a.points.last, size), stroke);
      case AnnotationType.text:
        _text(canvas, size, a, color, opacity);
    }
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

  static void _arrow(Canvas canvas, Offset from, Offset to, Paint paint) {
    canvas.drawLine(from, to, paint);
    final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
    final len = _headLen(paint.strokeWidth);
    for (final d in [math.pi * 0.83, -math.pi * 0.83]) {
      canvas.drawLine(to, to + Offset(math.cos(angle + d), math.sin(angle + d)) * len, paint);
    }
  }

  static const _textPadH = 0.5; // in font-size units
  static const _textPadV = 0.25;

  static TextPainter textPainter(Annotation a, Size size, Color color) {
    final fontPx = math.max(10.0, a.fontSize * size.height);
    return TextPainter(
      text: TextSpan(
        text: a.text,
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

  static void _text(Canvas canvas, Size size, Annotation a, Color color, double opacity) {
    if (a.text.isEmpty || a.points.isEmpty) return;
    final tp = textPainter(a, size, color);
    final box = textBox(a, size, tp);
    final fontPx = math.max(10.0, a.fontSize * size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, Radius.circular(fontPx * 0.3)),
      Paint()..color = Colors.black.withValues(alpha: 0.55 * opacity),
    );
    tp.paint(canvas, box.topLeft + Offset(fontPx * _textPadH, fontPx * _textPadV));
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

/// Paints every note visible at the current time plus the one being drawn.
class AnnotationPainter extends CustomPainter {
  AnnotationPainter({required this.annotations, this.draft, this.highlightId});

  final List<Annotation> annotations;
  final Annotation? draft;
  final String? highlightId;

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in annotations) {
      AnnotationRenderer.paint(canvas, size, a);
      if (a.id == highlightId) {
        canvas.drawRect(
          AnnotationRenderer.bounds(a, size),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.white70,
        );
      }
    }
    if (draft != null) AnnotationRenderer.paint(canvas, size, draft!, opacity: 0.85);
  }

  // Drafts are mutated in place while drawing and the list is cheap to
  // paint, so always repaint.
  @override
  bool shouldRepaint(AnnotationPainter old) => true;
}
