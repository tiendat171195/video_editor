import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_note/models/annotation.dart';
import 'package:video_note/services/overlay_renderer.dart';

void main() {
  test('renders cropped PNGs positioned inside the frame', () async {
    final dir = await Directory.systemTemp.createTemp('vn_ov');
    addTearDown(() => dir.delete(recursive: true));
    final overlays = await renderOverlays(
      annotations: [
        Annotation(
          id: 'e',
          type: AnnotationType.ellipse,
          startMs: 1000,
          durationMs: 3000,
          color: 0xFFFF0000,
          points: const [Offset(0.25, 0.25), Offset(0.5, 0.5)],
          revealMs: 500,
        ),
        Annotation(
          id: 't',
          type: AnnotationType.text,
          startMs: 0,
          durationMs: 99999,
          color: 0xFFFFFFFF,
          points: const [Offset(0.95, 0.95)], // gets pushed back inside the frame
          text: 'Chú ý',
        ),
      ],
      videoWidth: 640,
      videoHeight: 360,
      outDir: dir,
      durationMs: 5000,
    );
    expect(overlays, hasLength(2));
    final ellipse = overlays[0];
    expect(ellipse.x, inInclusiveRange(140, 160));
    expect(ellipse.y, inInclusiveRange(70, 90));
    expect(ellipse.endMs, 4000);
    final text = overlays[1];
    expect(text.endMs, 5000, reason: 'clamped to video duration');
    expect(text.x, lessThan(640));
    expect(text.y, lessThan(360));
    expect(ellipse.frameCount, 16, reason: '500ms at 30fps plus the final frame');
    expect(ellipse.fadeOutMs, 250);
    expect(text.frameCount, 1, reason: 'no reveal animation');
    for (final o in overlays) {
      for (var f = 0; f < o.frameCount; f++) {
        final bytes = File(o.path.replaceFirst('%03d', f.toString().padLeft(3, '0'))).readAsBytesSync();
        expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
      }
    }
  });
}
