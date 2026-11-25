import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

/// Contract for playlist batch downloading and progressive playlist size estimation.
abstract interface class PlaylistDownloadRepository {
  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  );

  Future<void> pausePlaylistDownload(String sessionId);

  Future<PlaylistSessionSnapshot> resumePlaylistDownload(String sessionId);

  Future<void> cancelPlaylistDownload(String sessionId);

  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(String sessionId);

  Stream<PlaylistProgressEvent> watchPlaylistProgress();

  Future<PlaylistSizeEstimate> estimatePlaylistSize(
    EstimatePlaylistSizeRequest request,
  );

  Future<void> cancelPlaylistSizeEstimation(String estimationId);

  Stream<PlaylistSizeEstimate> watchPlaylistSizeEstimate();
}
