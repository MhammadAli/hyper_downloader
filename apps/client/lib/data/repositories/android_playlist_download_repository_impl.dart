import 'package:hyper_download_client/data/datasources/android/android_method_channel_datasource.dart';
import 'package:hyper_download_client/data/services/playlist_size_estimator.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/repositories/playlist_download_repository.dart';

/// Android implementation of [PlaylistDownloadRepository]: delegates background
/// batch transfers to Kotlin ForegroundService/Chaquopy while running progressive
/// playlist size estimation in shared pure Dart.
class AndroidPlaylistDownloadRepositoryImpl
    implements PlaylistDownloadRepository {
  final AndroidMethodChannelDataSource _dataSource;
  final PlaylistSizeEstimator _sizeEstimator;

  const AndroidPlaylistDownloadRepositoryImpl({
    required this._dataSource,
    required this._sizeEstimator,
  });

  @override
  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  ) => _dataSource.startPlaylistDownload(request);

  @override
  Future<void> pausePlaylistDownload(String sessionId) =>
      _dataSource.pausePlaylistDownload(sessionId);

  @override
  Future<PlaylistSessionSnapshot> resumePlaylistDownload(String sessionId) =>
      _dataSource.resumePlaylistDownload(sessionId);

  @override
  Future<void> cancelPlaylistDownload(String sessionId) =>
      _dataSource.cancelPlaylistDownload(sessionId);

  @override
  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(String sessionId) =>
      _dataSource.retryFailedPlaylistItems(sessionId);

  @override
  Stream<PlaylistProgressEvent> watchPlaylistProgress() =>
      _dataSource.watchPlaylistProgress();

  @override
  Future<PlaylistSizeEstimate> estimatePlaylistSize(
    EstimatePlaylistSizeRequest request,
  ) => _sizeEstimator.estimate(request);

  @override
  Future<void> cancelPlaylistSizeEstimation(String estimationId) =>
      _sizeEstimator.cancelEstimation(estimationId);

  @override
  Stream<PlaylistSizeEstimate> watchPlaylistSizeEstimate() =>
      _sizeEstimator.watchEstimates();
}
