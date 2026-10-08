# Video Note

App ghi chú trực tiếp (real-time) trên video, viết bằng **Flutter**: chạy Android hiện tại, iOS dùng chung code sau này.

## Tính năng

**Ghi chú khi video đang phát**
- Vẽ tự do / khoanh vùng, khoanh tròn, khung chữ nhật, mũi tên
- Gõ note chữ: chọn **T** rồi chạm vào video. Video tự dừng trong lúc gõ và phát tiếp khi xong.
- Mỗi note chỉ hiện trong vài giây (1–10s, chỉnh được). Note được gắn với thời điểm bạn bắt đầu vẽ.
- Có thể bật **"Dừng khi vẽ"** nếu muốn video tự dừng lúc đang vẽ.
- Chọn màu và độ dày nét / cỡ chữ. Có hoàn tác.
- Danh sách note: chạm để nhảy tới, sửa thời điểm, thời lượng, màu, nội dung, hoặc xoá. Ở công cụ ✋, nhấn giữ một note trên video để sửa nhanh.
- Timeline hiển thị các note (thanh màu) và đoạn slow-mo (màu cam). Kéo trên timeline để tua.

**Slow motion**
- Bấm **Slow-mo** khi đang phát để bắt đầu đánh dấu, bấm lần nữa để kết thúc đoạn. Chọn tốc độ 0.75x / 0.5x / 0.25x / 0.125x.
- Khi xem lại, đoạn đã đánh dấu tự phát chậm. Khi xuất, đoạn đó được kéo dài thật, âm thanh giữ nguyên cao độ (`atempo`).
- Tốc độ phát chung (0.25x–2x) để xem chậm mà không cần đánh dấu.

**Xuất video kèm note** (🎬): note được vẽ bằng Flutter thành PNG rồi FFmpeg ghép vào đúng khoảng thời gian, nên chữ tiếng Việt có dấu hiển thị đúng và kết quả giống hệt bản xem trước.

**Cắt video** (✂️)
- *Chính xác*: encode lại, cắt đúng từng khung hình, có thể mang note và slow-mo sang video mới.
- *Nhanh*: không encode lại, gần như tức thì, nhưng điểm cắt bị kéo về keyframe gần nhất.

**Chuyển đổi / nén** (⚙️)
- Định dạng: MP4, MOV, MKV, WebM, GIF
- Video codec: H.264, H.265/HEVC, VP9, MPEG-4, hoặc giữ nguyên (chỉ remux)
- Audio: AAC, Opus, MP3, giữ nguyên, hoặc bỏ âm thanh; chọn được bitrate
- FPS: giữ nguyên, 60, 30, 25, 24, 15, 10
- Độ phân giải: giữ nguyên, hoặc 2160p xuống 360p (chỉ thu nhỏ, không phóng to)
- Dung lượng: chọn theo mức chất lượng (CRF) hoặc **theo dung lượng mục tiêu (MB)**. Khi chọn theo MB, app tự tính bitrate.

File kết quả được lưu ở `Android/data/com.tiendat.video_note/files/VideoNote/`. Từ đó có thể lưu vào thư viện ảnh, chia sẻ, hoặc mở trong editor. Project và note được tự động lưu.

## Cấu trúc code

```
lib/
  main.dart
  models/
    annotation.dart        # Annotation (note theo thời gian), SlowMoSegment
    project.dart           # VideoProject: note + slow-mo, JSON, cắt lại thời gian khi trim
    media_info.dart        # kết quả ffprobe (kích thước, xoay, fps, codec…)
  services/
    ffmpeg_commands.dart   # dựng lệnh FFmpeg (thuần Dart, có unit test)
    ffmpeg_service.dart    # chạy FFmpegKit, tiến độ, huỷ
    overlay_renderer.dart  # vẽ note thành PNG để ghép vào video
    storage.dart           # lưu project, thư mục xuất
  screens/
    home_screen.dart       # danh sách project, mở video
    editor_screen.dart     # player + vẽ/gõ note real-time + slow-mo + timeline
    trim_screen.dart
    convert_screen.dart
  widgets/
    annotation_painter.dart  # dùng chung cho preview và export
    timeline.dart
    job_runner.dart          # dialog tiến độ + sheet kết quả
```

Tọa độ note được lưu theo tỉ lệ 0..1 của khung hình, nên hiển thị đúng ở mọi kích thước màn hình và độ phân giải khi xuất.

## Build

Yêu cầu: Flutter 3.47+ và Android SDK. minSdk là 24.

```bash
flutter pub get
flutter test                                   # có ffmpeg trên máy thì chạy thêm test lệnh thật
flutter run                                    # chạy trên máy thật / emulator
flutter build apk --release --split-per-abi    # APK arm64 ~64 MB
```

GitHub Actions (`.github/workflows/android.yml`) chạy analyze, test, build APK arm64 rồi đính kèm làm artifact.

### iOS (sau này)
Thư mục `ios/` đã có sẵn. Info.plist đã khai báo quyền thư viện ảnh. Trên máy Mac:
1. Deployment target đã là iOS 15.0, đủ cho FFmpegKit (yêu cầu ≥ 14.0). Nếu Podfile được tạo ra, đặt `platform :ios, '15.0'`.
2. `cd ios && pod install`, rồi `flutter build ios`

## Ghi chú kỹ thuật
- FFmpeg dùng [`ffmpeg_kit_flutter_new`](https://pub.dev/packages/ffmpeg_kit_flutter_new), bản Full GPL có x264/x265/libvpx/opus/lame. Gói này có giấy phép **GPL-3.0**, nên nếu phát hành app đóng nguồn thì cần đổi sang gói không GPL (ví dụ `ffmpeg_kit_flutter_new_https`) và dùng encoder phần cứng hoặc VP9/MPEG-4.
- Slow-mo khi xuất giãn timestamp chứ không nội suy khung hình, nên đoạn 0.25x của video 30fps sẽ trông như ~7.5fps. Quay ở 120/240fps sẽ cho slow-mo mượt.
- Encode chạy bằng CPU (`veryfast`). Video dài hoặc 4K có thể mất vài phút.
