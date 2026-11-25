import 'package:hyper_download_client/domain/entities/media_entities.dart';

/// Shared human-readable formatting helpers for bytes, speeds, durations, and paths.
abstract final class ByteFormatter {
  static const double _kb = 1024.0;
  static const double _mb = 1024.0 * 1024.0;
  static const double _gb = 1024.0 * 1024.0 * 1024.0;

  static String formatBytesHuman(int bytes) {
    final val = bytes.toDouble();
    if (val < _kb) return '$bytes B';
    if (val < _mb) return '${(val / _kb).toStringAsFixed(1)} KB';
    if (val < _gb) return '${(val / _mb).toStringAsFixed(2)} MB';
    return '${(val / _gb).toStringAsFixed(2)} GB';
  }

  static String formatDisplaySize(int? bytes, FileSizeAccuracy accuracy) {
    if (bytes == null) return 'Unknown size';
    return switch (accuracy) {
      FileSizeAccuracy.exact => '${formatBytesHuman(bytes)} (Exact)',
      FileSizeAccuracy.estimated => '~${formatBytesHuman(bytes)} (Estimated)',
      FileSizeAccuracy.unknown => 'Unknown size',
    };
  }

  static String formatTransferBytes(
    int downloaded,
    int? total,
    bool isEstimated,
  ) {
    final down = formatBytesHuman(downloaded);
    if (total == null || total <= 0) return down;
    final prefix = isEstimated ? '~' : '';
    return '$down / $prefix${formatBytesHuman(total)}';
  }

  static String formatSpeed(double? speedBytesPerSec) {
    if (speedBytesPerSec == null || speedBytesPerSec <= 0) return '--';
    if (speedBytesPerSec < _kb) {
      return '${speedBytesPerSec.toStringAsFixed(0)} B/s';
    }
    if (speedBytesPerSec < _mb) {
      return '${(speedBytesPerSec / _kb).toStringAsFixed(1)} KB/s';
    }
    return '${(speedBytesPerSec / _mb).toStringAsFixed(2)} MB/s';
  }

  static String formatDuration(int totalSeconds) {
    final clamped = totalSeconds < 0 ? 0 : totalSeconds;
    final hours = clamped ~/ 3600;
    final minutes = (clamped % 3600) ~/ 60;
    final seconds = clamped % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static String formatEta(int? etaSeconds) {
    if (etaSeconds == null) return '--';
    return formatDuration(etaSeconds);
  }

  static String formatDisplayPath(String path) {
    const androidPublicPrefix = '/storage/emulated/0/';
    if (path.startsWith(androidPublicPrefix)) {
      return path.substring(androidPublicPrefix.length);
    }
    return path;
  }

  static String fileBaseName(String fullPath) {
    final normalized = fullPath.replaceAll('\\', '/');
    final parts = normalized.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isNotEmpty ? parts.last : fullPath;
  }

  static String folderTail(String fullPath) => fileBaseName(fullPath);
}
