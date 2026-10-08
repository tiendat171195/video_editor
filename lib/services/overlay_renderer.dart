import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../models/annotation.dart';
import '../widgets/annotation_painter.dart';
import 'ffmpeg_commands.dart';

/// Renders each note to a transparent PNG sequence cropped to its bounds:
/// one frame per 1/[kOverlayFps]s of its appear animation, the last frame
/// fully drawn. ffmpeg then holds that frame and fades it out. Text is drawn by Flutter, so any script (including
/// Vietnamese diacritics) works without bundling fonts into ffmpeg.
Future<List<OverlayImage>> renderOverlays({
  required List<Annotation> annotations,
  required int videoWidth,
  required int videoHeight,
  required Directory outDir,
  required int durationMs,
}) async {
  final frame = Size(videoWidth.toDouble(), videoHeight.toDouble());
  final full = Offset.zero & frame;
  final out = <OverlayImage>[];

  for (var i = 0; i < annotations.length; i++) {
    final a = annotations[i];
    if (a.startMs >= durationMs) continue;
    final r = AnnotationRenderer.bounds(a, frame).intersect(full);
    if (r.isEmpty || r.width < 1 || r.height < 1) continue;

    final left = r.left.floor();
    final top = r.top.floor();
    final w = (r.right.ceil() - left).clamp(1, videoWidth);
    final h = (r.bottom.ceil() - top).clamp(1, videoHeight);

    final visibleMs = a.endMs.clamp(a.startMs, durationMs) - a.startMs;
    final revealMs = a.revealMs.clamp(0, visibleMs);
    final frames = revealMs <= 0 ? 1 : (revealMs * kOverlayFps / 1000).ceil() + 1;
    var ok = true;
    for (var f = 0; f < frames; f++) {
      final progress = frames == 1 ? 1.0 : (f * 1000 / kOverlayFps / revealMs).clamp(0.0, 1.0);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.translate(-left.toDouble(), -top.toDouble());
      AnnotationRenderer.paintFrame(canvas, frame, a, progress: f == frames - 1 ? 1 : progress);
      final image = await recorder.endRecording().toImage(w, h);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) {
        ok = false;
        break;
      }
      final name = 'note_${i}_${f.toString().padLeft(3, '0')}.png';
      await File('${outDir.path}/$name').writeAsBytes(bytes.buffer.asUint8List());
    }
    if (!ok) continue;

    out.add(OverlayImage(
      path: '${outDir.path}/note_${i}_%03d.png',
      x: left,
      y: top,
      startMs: a.startMs,
      endMs: a.startMs + visibleMs,
      frameCount: frames,
      fadeOutMs: a.fadeOutMs.clamp(0, visibleMs ~/ 3),
    ));
  }
  return out;
}
