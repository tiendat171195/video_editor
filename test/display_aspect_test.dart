import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_note/screens/editor_screen.dart';
import 'package:video_player/video_player.dart';

void main() {
  VideoPlayerValue value(double w, double h, int rotation) => VideoPlayerValue(
        duration: const Duration(seconds: 1),
        size: Size(w, h),
        isInitialized: true,
        rotationCorrection: rotation,
      );

  test('portrait phone video reported unrotated is shown portrait', () {
    expect(displayAspectRatio(value(1920, 1080, 90)), closeTo(1080 / 1920, 1e-9));
    expect(displayAspectRatio(value(1920, 1080, 270)), closeTo(1080 / 1920, 1e-9));
  });

  test('already-rotated or unrotated sizes are used as is', () {
    expect(displayAspectRatio(value(1080, 1920, 0)), closeTo(1080 / 1920, 1e-9));
    expect(displayAspectRatio(value(1920, 1080, 180)), closeTo(1920 / 1080, 1e-9));
  });
}
