String formatMs(int ms, {bool tenths = false}) {
  if (ms < 0) ms = 0;
  final totalSec = ms ~/ 1000;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  var out = h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  if (tenths) out += '.${(ms % 1000) ~/ 100}';
  return out;
}

String formatBytes(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String formatSpeed(double s) => s == s.roundToDouble() ? '${s.toInt()}x' : '${s}x';
