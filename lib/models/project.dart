import 'annotation.dart';
import 'zoom.dart';

/// A video together with the notes and slow-motion ranges placed on it.
class VideoProject {
  VideoProject({
    required this.id,
    required this.videoPath,
    required this.name,
    this.durationMs = 0,
    this.folder,
    List<Annotation>? annotations,
    List<SlowMoSegment>? slowMos,
    List<ZoomSegment>? zooms,
    DateTime? updatedAt,
  })  : annotations = annotations ?? [],
        slowMos = slowMos ?? [],
        zooms = zooms ?? [],
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String videoPath;
  String name;
  int durationMs;

  /// Name of the folder the project is filed under; null = top level.
  String? folder;
  final List<Annotation> annotations;
  final List<SlowMoSegment> slowMos;
  final List<ZoomSegment> zooms;
  DateTime updatedAt;

  bool get hasEdits => annotations.isNotEmpty || slowMos.isNotEmpty || zooms.isNotEmpty;

  ZoomSegment? zoomSegmentAt(int ms) {
    for (final z in zooms) {
      if (z.contains(ms)) return z;
    }
    return null;
  }

  /// Adds a zoom range; overlapping ranges are clipped or split.
  void addZoom(ZoomSegment seg) {
    if (seg.endMs <= seg.startMs) return;
    final result = <ZoomSegment>[];
    for (final z in zooms) {
      if (z.endMs <= seg.startMs || z.startMs >= seg.endMs) {
        result.add(z);
        continue;
      }
      if (z.startMs < seg.startMs) {
        result.add(ZoomSegment(startMs: z.startMs, endMs: seg.startMs, scale: z.scale, cx: z.cx, cy: z.cy));
      }
      if (z.endMs > seg.endMs) {
        result.add(ZoomSegment(startMs: seg.endMs, endMs: z.endMs, scale: z.scale, cx: z.cx, cy: z.cy));
      }
    }
    result.add(seg);
    result.sort((a, b) => a.startMs.compareTo(b.startMs));
    zooms
      ..clear()
      ..addAll(result);
  }

  List<Annotation> visibleAt(int ms) =>
      [for (final a in annotations) if (a.isVisibleAt(ms)) a];

  SlowMoSegment? slowMoAt(int ms) {
    for (final s in slowMos) {
      if (s.contains(ms)) return s;
    }
    return null;
  }

  /// Adds a slow-motion range; any existing ranges it overlaps are clipped
  /// (or split) so that segments never overlap.
  void addSlowMo(SlowMoSegment seg) {
    if (seg.endMs <= seg.startMs) return;
    final result = <SlowMoSegment>[];
    for (final s in slowMos) {
      if (s.endMs <= seg.startMs || s.startMs >= seg.endMs) {
        result.add(s);
        continue;
      }
      if (s.startMs < seg.startMs) {
        result.add(SlowMoSegment(startMs: s.startMs, endMs: seg.startMs, speed: s.speed));
      }
      if (s.endMs > seg.endMs) {
        result.add(SlowMoSegment(startMs: seg.endMs, endMs: s.endMs, speed: s.speed));
      }
    }
    result.add(seg);
    result.sort((a, b) => a.startMs.compareTo(b.startMs));
    slowMos
      ..clear()
      ..addAll(result);
  }

  /// Notes and slow-mo ranges re-timed for a clip cut out of this video
  /// between [startMs] and [endMs]. Items outside the range are dropped,
  /// items crossing an edge are clipped.
  ({List<Annotation> annotations, List<SlowMoSegment> slowMos, List<ZoomSegment> zooms}) retimedForTrim(
      int startMs, int endMs) {
    final anns = <Annotation>[];
    for (final a in annotations) {
      final s = a.startMs.clamp(startMs, endMs);
      final e = a.endMs.clamp(startMs, endMs);
      if (e - s <= 0) continue;
      anns.add(a.copyWith(startMs: s - startMs, durationMs: e - s));
    }
    final segs = <SlowMoSegment>[];
    for (final m in slowMos) {
      final s = m.startMs.clamp(startMs, endMs);
      final e = m.endMs.clamp(startMs, endMs);
      if (e - s <= 0) continue;
      segs.add(SlowMoSegment(startMs: s - startMs, endMs: e - startMs, speed: m.speed));
    }
    final zs = <ZoomSegment>[];
    for (final z in zooms) {
      final s = z.startMs.clamp(startMs, endMs);
      final e = z.endMs.clamp(startMs, endMs);
      if (e - s <= 0) continue;
      zs.add(ZoomSegment(startMs: s - startMs, endMs: e - startMs, scale: z.scale, cx: z.cx, cy: z.cy));
    }
    return (annotations: anns, slowMos: segs, zooms: zs);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'videoPath': videoPath,
        'name': name,
        'durationMs': durationMs,
        if (folder != null) 'folder': folder,
        'updatedAt': updatedAt.toIso8601String(),
        'annotations': [for (final a in annotations) a.toJson()],
        'slowMos': [for (final s in slowMos) s.toJson()],
        'zooms': [for (final z in zooms) z.toJson()],
      };

  factory VideoProject.fromJson(Map<String, dynamic> json) => VideoProject(
        id: json['id'] as String,
        videoPath: json['videoPath'] as String,
        name: json['name'] as String,
        durationMs: json['durationMs'] as int? ?? 0,
        folder: json['folder'] as String?,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
        annotations: [
          for (final a in json['annotations'] as List? ?? const [])
            Annotation.fromJson(Map<String, dynamic>.from(a as Map))
        ],
        slowMos: [
          for (final s in json['slowMos'] as List? ?? const [])
            SlowMoSegment.fromJson(Map<String, dynamic>.from(s as Map))
        ],
        zooms: [
          for (final z in json['zooms'] as List? ?? const [])
            ZoomSegment.fromJson(Map<String, dynamic>.from(z as Map))
        ],
      );
}
