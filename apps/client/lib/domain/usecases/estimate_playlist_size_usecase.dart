import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/repositories/playlist_download_repository.dart';

/// Coordinates progressive playlist size estimation and cancellation.
class EstimatePlaylistSizeUseCase {
  final PlaylistDownloadRepository _repository;

  const EstimatePlaylistSizeUseCase(this._repository);

  Stream<PlaylistSizeEstimate> watchEstimates() =>
      _repository.watchPlaylistSizeEstimate();

  Future<PlaylistSizeEstimate> estimate(EstimatePlaylistSizeRequest request) =>
      _repository.estimatePlaylistSize(request);

  Future<void> cancel(String estimationId) =>
      _repository.cancelPlaylistSizeEstimation(estimationId);
}
