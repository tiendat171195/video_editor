/// The subset of ffprobe output the app cares about.
class MediaInfo {
  const MediaInfo({
    required this.durationMs,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.fps,
    this.videoCodec,
    this.audioCodec,
    this.hasAudio = false,
    this.bitrate,
    this.sizeBytes,
    this.format,
  });

  final int durationMs;

  /// Coded (stored) dimensions, before rotation metadata is applied.
  final int width;
  final int height;
  final int rotation;
  final double? fps;
  final String? videoCodec;
  final String? audioCodec;
  final bool hasAudio;

  /// Overall bitrate in bits per second.
  final int? bitrate;
  final int? sizeBytes;
  final String? format;

  bool get _swapped => rotation.abs() % 180 == 90;

  /// Dimensions as shown on screen (what ffmpeg filters see after autorotate).
  int get displayWidth => _swapped ? height : width;
  int get displayHeight => _swapped ? width : height;

  double get durationSec => durationMs / 1000.0;

  /// Clockwise rotation (0, 90, 180 or 270) that turns stored frames upright,
  /// i.e. what ffmpeg's autorotate would apply. ffprobe reports the display
  /// matrix angle counter-clockwise, hence the sign flip.
  int get uprightRotation {
    final r = (((-rotation) % 360) + 360) % 360;
    return ((r / 90).round() * 90) % 360;
  }

  /// Builds a [MediaInfo] from ffprobe's JSON-like property maps.
  factory MediaInfo.fromProbe({
    required Map<dynamic, dynamic>? format,
    required List<Map<dynamic, dynamic>> streams,
    int? fallbackSizeBytes,
  }) {
    Map<dynamic, dynamic>? video;
    Map<dynamic, dynamic>? audio;
    for (final s in streams) {
      final type = s['codec_type'];
      if (type == 'video' && video == null) {
        // Skip embedded cover art.
        final disp = s['disposition'];
        if (disp is Map && disp['attached_pic'] == 1) continue;
        video = s;
      } else if (type == 'audio' && audio == null) {
        audio = s;
      }
    }

    final durSec = _num(format?['duration']) ?? _num(video?['duration']) ?? 0;
    return MediaInfo(
      durationMs: (durSec * 1000).round(),
      width: _num(video?['width'])?.toInt() ?? 0,
      height: _num(video?['height'])?.toInt() ?? 0,
      rotation: _rotation(video),
      fps: _frameRate(video?['avg_frame_rate']) ?? _frameRate(video?['r_frame_rate']),
      videoCodec: video?['codec_name'] as String?,
      audioCodec: audio?['codec_name'] as String?,
      hasAudio: audio != null,
      bitrate: _num(format?['bit_rate'])?.toInt(),
      sizeBytes: _num(format?['size'])?.toInt() ?? fallbackSizeBytes,
      format: format?['format_name'] as String?,
    );
  }

  static int _rotation(Map<dynamic, dynamic>? video) {
    if (video == null) return 0;
    final sideData = video['side_data_list'];
    if (sideData is List) {
      for (final d in sideData) {
        if (d is Map && d['rotation'] != null) {
          return _num(d['rotation'])?.toInt() ?? 0;
        }
      }
    }
    final tags = video['tags'];
    if (tags is Map && tags['rotate'] != null) {
      return _num(tags['rotate'])?.toInt() ?? 0;
    }
    return 0;
  }

  static double? _frameRate(Object? v) {
    if (v is! String || !v.contains('/')) return _num(v);
    final parts = v.split('/');
    final n = double.tryParse(parts[0]);
    final d = double.tryParse(parts[1]);
    if (n == null || d == null || d == 0 || n == 0) return null;
    return n / d;
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
