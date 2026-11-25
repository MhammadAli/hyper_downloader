import 'package:hyper_download_client/data/datasources/android/android_method_channel_datasource.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/repositories/single_download_repository.dart';

/// Android implementation of [SingleDownloadRepository] delegating active
/// downloads to Kotlin ForegroundService/Chaquopy so transfers survive backgrounding.
class AndroidSingleDownloadRepositoryImpl implements SingleDownloadRepository {
  final AndroidMethodChannelDataSource _dataSource;

  const AndroidSingleDownloadRepositoryImpl(this._dataSource);

  @override
  Future<String> startDownload(StartDownloadRequest request) =>
      _dataSource.startDownload(request);

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
