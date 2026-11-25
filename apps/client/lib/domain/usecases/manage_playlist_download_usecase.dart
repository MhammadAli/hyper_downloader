import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/repositories/playlist_download_repository.dart';

/// Coordinates starting, pausing, resuming, canceling, retrying, and watching
/// sequential playlist batch downloads.
class ManagePlaylistDownloadUseCase {
  final PlaylistDownloadRepository _repository;

  const ManagePlaylistDownloadUseCase(this._repository);

  Stream<PlaylistProgressEvent> watchProgress() =>
      _repository.watchPlaylistProgress();

  Future<PlaylistSessionSnapshot> start(StartPlaylistDownloadRequest request) =>
      _repository.startPlaylistDownload(request);

  Future<void> pause(String sessionId) =>
      _repository.pausePlaylistDownload(sessionId);

  Future<PlaylistSessionSnapshot> resume(String sessionId) =>
      _repository.resumePlaylistDownload(sessionId);

  Future<void> cancel(String sessionId) =>
      _repository.cancelPlaylistDownload(sessionId);

  Future<PlaylistSessionSnapshot> retryFailed(String sessionId) =>
      _repository.retryFailedPlaylistItems(sessionId);
}
