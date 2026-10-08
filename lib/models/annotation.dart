import 'dart:ui';

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

  int get endMs => startMs + durationMs;

  bool isVisibleAt(int ms) => ms >= startMs && ms < endMs;

  Annotation copyWith({int? startMs, int? durationMs, String? id}) => Annotation(
        id: id ?? this.id,
        type: type,
        startMs: startMs ?? this.startMs,
        durationMs: durationMs ?? this.durationMs,
        color: color,
        points: List.of(points),
        strokeWidth: strokeWidth,
        text: text,
        fontSize: fontSize,
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
