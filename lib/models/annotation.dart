import 'dart:ui';

import 'package:characters/characters.dart';

/// Length of the fade at the end of a note's visibility window.
const kFadeOutMs = 250;

/// Default reveal (draw-on / typewriter) animation length for a new note.
int defaultRevealMs(AnnotationType type, {String text = '', int? drawnMs}) => switch (type) {
      AnnotationType.pen => (drawnMs ?? 600).clamp(300, 1500),
      AnnotationType.text => (text.characters.length * 45).clamp(300, 1500),
      _ => 500,
    };

/// Kinds of time-bound notes that can be placed on top of a video.
enum AnnotationType { pen, ellipse, rect, arrow, text }

/// A note drawn on the video that is visible from [startMs] for [durationMs].
///
/// All geometry is stored normalized to the video frame (0..1 on both axes),
/// so the same annotation renders identically on the phone preview and on
/// the full-resolution export.
class Annotation {
  Annotation({
    required this.id,
    required this.type,
    required this.startMs,
    required this.durationMs,
    required this.color,
    required this.points,
    this.strokeWidth = 0.008,
    this.text = '',
    this.fontSize = 0.05,
    this.revealMs = 0,
  });

  final String id;
  final AnnotationType type;
  int startMs;
  int durationMs;

  /// ARGB32 color value.
  int color;

  /// Stroke width as a fraction of the video width.
  double strokeWidth;

  /// Normalized points. Pen: the whole path. Shapes: [start, end].
  /// Text: [anchor] (top-left of the text box).
  final List<Offset> points;

  String text;

  /// Font size as a fraction of the video height.
  double fontSize;

  /// Duration of the appear animation (stroke drawn on / text typed out).
  /// 0 shows the note instantly.
  int revealMs;

  int get endMs => startMs + durationMs;

  bool isVisibleAt(int ms) => ms >= startMs && ms < endMs;

  /// Fraction (0..1) of the appear animation completed at [ms].
  double revealAt(int ms) {
    final r = revealMs.clamp(0, durationMs);
    if (r <= 0) return 1;
    return ((ms - startMs) / r).clamp(0.0, 1.0);
  }

  /// Fade-out length, shortened for very brief notes.
  int get fadeOutMs => durationMs >= 3 * kFadeOutMs ? kFadeOutMs : 0;

  /// Opacity at [ms], fading out over the last [fadeOutMs].
  double opacityAt(int ms) {
    final f = fadeOutMs;
    if (f == 0) return 1;
    return ((endMs - ms) / f).clamp(0.0, 1.0);
  }

  /// Moves every point by [delta] (normalized units). The delta is clamped
  /// so the note as a whole stays inside the frame without being distorted.
  void translate(Offset delta) {
    if (points.isEmpty) return;
    var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    final d = Offset(delta.dx.clamp(-minX, 1 - maxX), delta.dy.clamp(-minY, 1 - maxY));
    for (var i = 0; i < points.length; i++) {
      points[i] += d;
    }
  }

  Annotation copyWith({int? startMs, int? durationMs, String? id, int? revealMs}) => Annotation(
        id: id ?? this.id,
        type: type,
        startMs: startMs ?? this.startMs,
        durationMs: durationMs ?? this.durationMs,
        color: color,
        points: List.of(points),
        strokeWidth: strokeWidth,
        text: text,
        fontSize: fontSize,
        revealMs: revealMs ?? this.revealMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'startMs': startMs,
        'durationMs': durationMs,
        'color': color,
        'strokeWidth': strokeWidth,
        'points': [
          for (final p in points) [_round(p.dx), _round(p.dy)]
        ],
        'text': text,
        'fontSize': fontSize,
        'revealMs': revealMs,
      };

  factory Annotation.fromJson(Map<String, dynamic> json) => Annotation(
        id: json['id'] as String,
        type: AnnotationType.values.byName(json['type'] as String),
        startMs: json['startMs'] as int,
        durationMs: json['durationMs'] as int,
        color: json['color'] as int,
        strokeWidth: (json['strokeWidth'] as num).toDouble(),
        points: [
          for (final p in json['points'] as List)
            Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())
        ],
        text: json['text'] as String? ?? '',
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 0.05,
        revealMs: json['revealMs'] as int? ?? 0,
      );

  static double _round(double v) => (v * 10000).roundToDouble() / 10000;
}

/// A time range of the source video that should play back slower.
class SlowMoSegment {
  SlowMoSegment({required this.startMs, required this.endMs, required this.speed});

  int startMs;
  int endMs;

  /// Playback rate inside the segment, e.g. 0.5 for half speed.
  double speed;

  int get durationMs => endMs - startMs;

  bool contains(int ms) => ms >= startMs && ms < endMs;

  Map<String, dynamic> toJson() => {'startMs': startMs, 'endMs': endMs, 'speed': speed};

  factory SlowMoSegment.fromJson(Map<String, dynamic> json) => SlowMoSegment(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        speed: (json['speed'] as num).toDouble(),
      );
}
