# Video Note

App ghi chú trực tiếp (real-time) trên video, viết bằng **Flutter**: chạy Android hiện tại, iOS dùng chung code sau này.

## Tính năng

**Ghi chú khi video đang phát**
- Vẽ tự do / khoanh vùng, khoanh tròn, khung chữ nhật, mũi tên
- Gõ note chữ: chọn **T** rồi chạm vào video. Video tự dừng trong lúc gõ và phát tiếp khi xong.
- **Hiệu ứng xuất hiện** (bật/tắt bằng chip "Hiệu ứng"): nét vẽ và hình hiện dần theo nét, chữ hiện kiểu gõ phím. Note mờ dần khi hết thời gian. Chỉnh độ dài hiệu ứng cho từng note trong màn Sửa. Video xuất ra có hiệu ứng y hệt.
- Thời gian hiện: 1–10 giây, hoặc **"Đến khi bấm ẩn"**: note hiện mãi, bạn tua tới chỗ cần ẩn rồi bấm **Ẩn tại đây**.
- Công cụ ✋:
  - Chạm vào note để chọn, kéo để **di chuyển** (cả chữ lẫn hình)
  - Thanh chọn có các nút **Ẩn tại đây**, **Hiện từ đây**, Sửa, Xoá. Note đã chọn vẫn hiện mờ khi tua ra ngoài khoảng thời gian của nó.
  - Kéo vào chỗ trống trên video để tua
- **Zoom vào video xuất ra**: chụm 2 ngón để phóng to vùng cần xem (tới 6x), bấm **Zoom video** để bắt đầu đoạn zoom (video tự phát), bấm **Dừng zoom** để kết thúc. Zoom vào và ra mượt (~0,4s). Khi xem lại, đoạn zoom tự hiện đúng như video xuất ra, note phóng to theo hình. Đoạn zoom hiện màu xanh trên timeline và có trong danh sách để xoá. Nếu chỉ chụm 2 ngón mà không bấm Zoom video thì chỉ là phóng to khi xem (để vẽ chi tiết), không ảnh hưởng video xuất ra.
- Hoàn tác / làm lại trên thanh trên cùng, áp dụng cho mọi thao tác. Xuất video và Cắt video nằm trong nút ⋮.
- **Tua mượt**: app trích sẵn khung hình độ phân giải thấp ở chế độ nền, nên khi kéo thanh tiến trình, hình chạy theo ngón tay ngay lập tức. Kéo ngón tay xa thanh lên phía trên để tua chậm hơn (×¼, ×⅒). Có nút tiến/lùi từng khung hình.
- Timeline hiển thị các note (thanh màu) và đoạn slow-mo (màu cam).

**Project & thư mục**: đặt tên khi mở video, đổi tên (bấm vào tiêu đề trong editor hoặc menu ⋮ ở màn chính), tạo thư mục và chuyển project vào đó. Video tạo ra từ một project (cắt, chuyển đổi, xuất) được lưu vào cùng thư mục.

**Slow motion**
- Bấm **Slow-mo** khi đang phát để bắt đầu đánh dấu, bấm lần nữa để kết thúc đoạn. Chọn tốc độ 0.75x / 0.5x / 0.25x / 0.125x.
- Khi xem lại, đoạn đã đánh dấu tự phát chậm. Khi xuất, đoạn đó được kéo dài thật, âm thanh giữ nguyên cao độ (`atempo`).
- Tốc độ phát chung (0.25x–2x) để xem chậm mà không cần đánh dấu.

**Xuất video** (menu ⋮ → Xuất video): đây là màn duy nhất để xuất, gồm cả đổi định dạng và nén.
- Bật/tắt **Kèm note & slow-mo**. Note được vẽ bằng Flutter rồi ghép vào video, nên chữ tiếng Việt có dấu hiển thị đúng và hiệu ứng giống hệt bản xem trước.
- Chọn nhanh một mẫu: **Chất lượng gốc**, **Gửi nhanh** (720p), **Siêu nhẹ** (480p, 30fps), **Theo dung lượng** (chọn số MB tối đa), **GIF**.
- **Tuỳ chỉnh nâng cao**:
  - Định dạng: MP4, MOV, MKV, WebM, GIF
  - Codec: H.264, H.265, VP9, MPEG-4, hoặc giữ nguyên (chỉ khi không kèm note)
  - Độ phân giải, FPS
  - Âm thanh: AAC, Opus, MP3, giữ nguyên, bỏ âm thanh; chọn được bitrate
  - Encode nhanh / chậm (file nhỏ hơn)
- Video có metadata xoay (quay dọc trên điện thoại) được xuất ra đúng chiều, note nằm đúng vị trí.

**Cắt video** (✂️)
- *Chính xác*: encode lại, cắt đúng từng khung hình, có thể mang note và slow-mo sang video mới.
- *Nhanh*: không encode lại, gần như tức thì, nhưng điểm cắt bị kéo về keyframe gần nhất.

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
    scrub_frames.dart      # trích khung hình low-res để tua mượt
    ffmpeg_service.dart    # chạy FFmpegKit, tiến độ, huỷ
    overlay_renderer.dart  # vẽ note thành PNG để ghép vào video
    storage.dart           # lưu project, thư mục xuất
  screens/
    home_screen.dart       # danh sách project, mở video
    editor_screen.dart     # player + vẽ/gõ note real-time + slow-mo + timeline
    trim_screen.dart
    export_screen.dart     # xuất video: note + định dạng/codec/nén
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

### Cài APK & ký bản build
- Mỗi lần push, GitHub Actions build APK arm64 và đăng lên **Releases** (`build-N`). Mở trang Releases trên điện thoại, tải `video-note-arm64.apk` rồi cài.
- Bản release được ký bằng key cố định lưu trong GitHub Secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Nhờ vậy bản mới cài đè lên bản cũ mà không mất dữ liệu. Thiếu secrets thì build vẫn chạy nhưng ký bằng debug key tạm, nên không cài đè được.
- `versionCode` lấy theo số lần chạy CI, nên bản sau luôn mới hơn bản trước.

### iOS (sau này)
Thư mục `ios/` đã có sẵn. Info.plist đã khai báo quyền thư viện ảnh. Trên máy Mac:
1. Deployment target đã là iOS 15.0, đủ cho FFmpegKit (yêu cầu ≥ 14.0). Nếu Podfile được tạo ra, đặt `platform :ios, '15.0'`.
2. `cd ios && pod install`, rồi `flutter build ios`

## Ghi chú kỹ thuật
- FFmpeg dùng [`ffmpeg_kit_flutter_new`](https://pub.dev/packages/ffmpeg_kit_flutter_new), bản Full GPL có x264/x265/libvpx/opus/lame. Gói này có giấy phép **GPL-3.0**, nên nếu phát hành app đóng nguồn thì cần đổi sang gói không GPL (ví dụ `ffmpeg_kit_flutter_new_https`) và dùng encoder phần cứng hoặc VP9/MPEG-4.
- Slow-mo khi xuất giãn timestamp chứ không nội suy khung hình, nên đoạn 0.25x của video 30fps sẽ trông như ~7.5fps. Quay ở 120/240fps sẽ cho slow-mo mượt.
- Encode chạy bằng CPU (`veryfast`). Video dài hoặc 4K có thể mất vài phút.
