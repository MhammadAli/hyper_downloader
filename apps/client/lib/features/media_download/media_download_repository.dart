import 'package:hyper_download_client/core/bridge/api.dart' as bridge_api;
import 'package:hyper_download_client/core/bridge/models.dart';

/// Engine operations required by the Phase 2B media download workflow.
abstract class MediaDownloadRepository {
  String ping();

  String engineVersion();

  Future<MediaInspection> inspectMedia(String url);

  Future<String> startDownload(StartDownloadRequest request);

  Future<void> cancelDownload(String jobId);

  Future<String> resumeDownload(String jobId);

  Stream<DownloadProgressEvent> watchDownloadProgress();
}

/// Production FFI repository backed by `flutter_rust_bridge` v2 bindings.
class FrbMediaDownloadRepository implements MediaDownloadRepository {
  const FrbMediaDownloadRepository();

  @override
  String ping() => bridge_api.ping();

  @override
  String engineVersion() => bridge_api.engineVersion();

  @override
  Future<MediaInspection> inspectMedia(String url) =>
      bridge_api.inspectMedia(url: url);

  @override
  Future<String> startDownload(StartDownloadRequest request) =>
      bridge_api.startDownload(request: request);

  @override
  Future<void> cancelDownload(String jobId) =>
      bridge_api.cancelDownload(jobId: jobId);

  @override
  Future<String> resumeDownload(String jobId) =>
      bridge_api.resumeDownload(jobId: jobId);

  @override
  Stream<DownloadProgressEvent> watchDownloadProgress() =>
      bridge_api.subscribeDownloadProgress();
}
