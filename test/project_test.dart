import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_note/models/annotation.dart';
import 'package:video_note/models/media_info.dart';
import 'package:video_note/models/project.dart';

Annotation note(int start, int dur) => Annotation(
      id: '$start',
      type: AnnotationType.text,
      startMs: start,
      durationMs: dur,
      color: 0xFFFF0000,
      points: const [Offset(0.1, 0.2)],
      text: 'Xin chào',
    );

void main() {
  test('json round trip', () {
    final p = VideoProject(id: 'p', videoPath: '/v.mp4', name: 'v', durationMs: 5000)
      ..annotations.add(note(100, 3000))
      ..slowMos.add(SlowMoSegment(startMs: 1000, endMs: 2000, speed: 0.5));
    final back = VideoProject.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.annotations.single.text, 'Xin chào');
    expect(back.annotations.single.points.single, const Offset(0.1, 0.2));
    expect(back.slowMos.single.speed, 0.5);
  });

  test('addSlowMo clips and splits overlapping segments', () {
    final p = VideoProject(id: 'p', videoPath: '/v.mp4', name: 'v');
    p.addSlowMo(SlowMoSegment(startMs: 0, endMs: 10000, speed: 0.5));
    p.addSlowMo(SlowMoSegment(startMs: 3000, endMs: 5000, speed: 0.25));
    expect(p.slowMos.map((s) => [s.startMs, s.endMs, s.speed]).toList(), [
      [0, 3000, 0.5],
      [3000, 5000, 0.25],
      [5000, 10000, 0.5],
    ]);
  });

  test('retimedForTrim shifts and clips', () {
    final p = VideoProject(id: 'p', videoPath: '/v.mp4', name: 'v')
      ..annotations.addAll([note(500, 1000), note(2500, 2000), note(9000, 500)])
      ..slowMos.add(SlowMoSegment(startMs: 1000, endMs: 4000, speed: 0.5));
    final r = p.retimedForTrim(2000, 4000);
    expect(r.annotations.map((a) => [a.startMs, a.durationMs]).toList(), [
      [500, 1500],
    ]);
    expect(r.slowMos.map((s) => [s.startMs, s.endMs]).toList(), [
      [0, 2000],
    ]);
  });

  test('media info swaps dimensions for rotated video', () {
    final info = MediaInfo.fromProbe(
      format: {'duration': '12.5', 'size': '1000', 'bit_rate': '640'},
      streams: [
        {
          'codec_type': 'video',
          'codec_name': 'h264',
          'width': 1920,
          'height': 1080,
          'avg_frame_rate': '30000/1001',
          'side_data_list': [
            {'rotation': -90}
          ],
        },
        {'codec_type': 'audio', 'codec_name': 'aac'},
      ],
    );
    expect(info.durationMs, 12500);
    expect(info.displayWidth, 1080);
    expect(info.displayHeight, 1920);
    expect(info.fps!, closeTo(29.97, 0.01));
    expect(info.hasAudio, isTrue);
  });
}
