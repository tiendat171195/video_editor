import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../models/annotation.dart';
import '../widgets/annotation_painter.dart';
import 'ffmpeg_commands.dart';

/// Renders each note to a transparent PNG cropped to its bounds, ready to be
/// overlaid by ffmpeg. Text is drawn by Flutter, so any script (including
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

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.translate(-left.toDouble(), -top.toDouble());
    AnnotationRenderer.paint(canvas, frame, a);
    final image = await recorder.endRecording().toImage(w, h);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) continue;

    final file = File('${outDir.path}/note_$i.png');
    await file.writeAsBytes(bytes.buffer.asUint8List());
    out.add(OverlayImage(
      path: file.path,
      x: left,
      y: top,
      startMs: a.startMs,
      endMs: a.endMs.clamp(a.startMs, durationMs),
    ));
  }
  return out;
}
