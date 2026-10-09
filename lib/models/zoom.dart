import 'dart:math' as math;

/// A time range during which the exported video is zoomed into a region.
///
/// The zoom eases in over the first [kZoomRampMs] and back out over the last,
/// so cuts in and out of the zoom are smooth.
class ZoomSegment {
  ZoomSegment({
    required this.startMs,
    required this.endMs,
    required this.scale,
    required double cx,
    required double cy,
  })  : cx = clampCenter(cx, scale),
        cy = clampCenter(cy, scale);

  int startMs;
  int endMs;

  /// Magnification, e.g. 2.0 shows half the width and height of the frame.
  double scale;

  /// Centre of the zoomed view, normalized to the frame (0..1).
  double cx;
  double cy;

  int get durationMs => endMs - startMs;

  bool contains(int ms) => ms >= startMs && ms < endMs;

  /// Keeps the zoomed view inside the frame.
  static double clampCenter(double c, double scale) {
    final half = 0.5 / math.max(scale, 1.0);
    return c.clamp(half, 1 - half).toDouble();
  }

  Map<String, dynamic> toJson() =>
      {'startMs': startMs, 'endMs': endMs, 'scale': scale, 'cx': cx, 'cy': cy};

  factory ZoomSegment.fromJson(Map<String, dynamic> json) => ZoomSegment(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        scale: (json['scale'] as num).toDouble(),
        cx: (json['cx'] as num).toDouble(),
        cy: (json['cy'] as num).toDouble(),
      );
}

/// Ease in / out duration of a zoom segment.
const kZoomRampMs = 400;

/// Ramp length for [z], shortened for very brief segments.
double zoomRampSec(ZoomSegment z) => math.min(kZoomRampMs, z.durationMs / 2) / 1000.0;

/// Zoom weight (0..1) of [z] at time [t] seconds: linear in/out ramps passed
/// through smoothstep. Mirrors [zoomWeightExpr] exactly.
double zoomWeight(ZoomSegment z, double t) {
  final r = zoomRampSec(z);
  final s = z.startMs / 1000.0;
  final e = z.endMs / 1000.0;
  if (r <= 0) return t >= s && t < e ? 1 : 0;
  final a = ((t - s) / r).clamp(0.0, 1.0);
  final b = ((e - t) / r).clamp(0.0, 1.0);
  final w = math.min(a, b);
  return w * w * (3 - 2 * w);
}

/// The view (magnification and normalized centre) at [ms]. Segments never
/// overlap, so their weights are summed.
({double scale, double cx, double cy}) zoomAt(List<ZoomSegment> zooms, int ms) {
  final t = ms / 1000.0;
  var scale = 1.0, cx = 0.5, cy = 0.5;
  for (final z in zooms) {
    final w = zoomWeight(z, t);
    if (w == 0) continue;
    scale += (z.scale - 1) * w;
    cx += (z.cx - 0.5) * w;
    cy += (z.cy - 0.5) * w;
  }
  return (scale: scale, cx: cx, cy: cy);
}
