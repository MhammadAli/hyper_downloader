import 'package:hyper_download_client/domain/entities/download_entities.dart';

/// Contract for single-video / audio-only download lifecycle & progress streaming.
abstract interface class SingleDownloadRepository {
  Future<String> startDownload(StartDownloadRequest request);

  Future<void> cancelDownload(String jobId);

  Future<String> resumeDownload(String jobId);

  Stream<DownloadProgressEvent> watchDownloadProgress();
}
