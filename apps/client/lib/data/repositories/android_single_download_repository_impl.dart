import 'package:hyper_download_client/data/datasources/android/android_method_channel_datasource.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';
import 'package:hyper_download_client/domain/repositories/single_download_repository.dart';

/// Android implementation of [SingleDownloadRepository] delegating active
/// downloads to Kotlin ForegroundService/Chaquopy so transfers survive backgrounding.
class AndroidSingleDownloadRepositoryImpl implements SingleDownloadRepository {
  final AndroidMethodChannelDataSource _dataSource;
  final PlatformRegistry _platformRegistry;

  const AndroidSingleDownloadRepositoryImpl(
    this._dataSource, {
    this._platformRegistry = const PlatformRegistry(),
  });

  @override
  Future<String> startDownload(StartDownloadRequest request) {
    final classified = _platformRegistry.classifyAndNormalize(request.url);
    final normalizedRequest = StartDownloadRequest(
      url: classified.normalizedUrl,
      title: request.title,
      selection: request.selection,
      outputDirectory: request.outputDirectory,
    );
    return _dataSource.startDownload(normalizedRequest);
  }

  @override
  Future<void> cancelDownload(String jobId) =>
      _dataSource.cancelDownload(jobId);

  @override
  Future<String> resumeDownload(String jobId) =>
      _dataSource.resumeDownload(jobId);

  @override
  Stream<DownloadProgressEvent> watchDownloadProgress() =>
      _dataSource.watchDownloadProgress();
}
