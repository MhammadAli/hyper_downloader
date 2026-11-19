import 'package:hyper_download_client/core/bridge/api.dart' as bridge_api;
import 'package:hyper_download_client/core/bridge/models.dart';

/// Engine operations required by the HyperDownload media & playlist workflow.
abstract class MediaDownloadRepository {
  String ping();

  String engineVersion();

  Future<MediaInspection> inspectMedia(String url);

  Future<UrlInspectionResult> inspectUrl(String url);

  Future<String> startDownload(StartDownloadRequest request);

  Future<void> cancelDownload(String jobId);

  Future<String> resumeDownload(String jobId);

  Stream<DownloadProgressEvent> watchDownloadProgress();

  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  );

  Future<void> pausePlaylistDownload(String sessionId);

  Future<PlaylistSessionSnapshot> resumePlaylistDownload(String sessionId);

  Future<void> cancelPlaylistDownload(String sessionId);

  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(String sessionId);

  Future<PlaylistSessionSnapshot?> loadSavedPlaylistSession({
    required String playlistId,
    String? outputDirectory,
  });

  Stream<PlaylistProgressEvent> watchPlaylistProgress();

  Future<PlaylistSizeEstimate> estimatePlaylistSize(
    EstimatePlaylistSizeRequest request,
  );

  Future<void> cancelPlaylistSizeEstimation(String estimationId);

  Stream<PlaylistSizeEstimate> watchPlaylistSizeEstimate();
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
  Future<UrlInspectionResult> inspectUrl(String url) =>
      bridge_api.inspectUrl(url: url);

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

  @override
  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  ) => bridge_api.startPlaylistDownload(request: request);

  @override
  Future<void> pausePlaylistDownload(String sessionId) =>
      bridge_api.pausePlaylistDownload(sessionId: sessionId);

  @override
  Future<PlaylistSessionSnapshot> resumePlaylistDownload(String sessionId) =>
      bridge_api.resumePlaylistDownload(sessionId: sessionId);

  @override
  Future<void> cancelPlaylistDownload(String sessionId) =>
      bridge_api.cancelPlaylistDownload(sessionId: sessionId);

  @override
  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(String sessionId) =>
      bridge_api.retryFailedPlaylistItems(sessionId: sessionId);

  @override
  Future<PlaylistSessionSnapshot?> loadSavedPlaylistSession({
    required String playlistId,
    String? outputDirectory,
  }) => bridge_api.loadSavedPlaylistSession(
    playlistId: playlistId,
    outputDirectory: outputDirectory,
  );

  @override
  Stream<PlaylistProgressEvent> watchPlaylistProgress() =>
      bridge_api.subscribePlaylistProgress();

  @override
  Future<PlaylistSizeEstimate> estimatePlaylistSize(
    EstimatePlaylistSizeRequest request,
  ) => bridge_api.estimatePlaylistSize(request: request);

  @override
  Future<void> cancelPlaylistSizeEstimation(String estimationId) =>
      bridge_api.cancelPlaylistSizeEstimation(estimationId: estimationId);

  @override
  Stream<PlaylistSizeEstimate> watchPlaylistSizeEstimate() =>
      bridge_api.subscribePlaylistSizeEstimate();
}
