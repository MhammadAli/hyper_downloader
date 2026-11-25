import 'package:flutter/services.dart';
import 'package:hyper_download_client/domain/repositories/file_launcher_repository.dart';

/// Android implementation of [FileLauncherRepository] delegating open, Downloads view,
/// and system share actions to Kotlin `AndroidMediaStoreExporter` over MethodChannel.
class AndroidFileLauncherDataSource implements FileLauncherRepository {
  static const MethodChannel _defaultMethodChannel = MethodChannel(
    'com.hyperdownload/media_engine',
  );

  final MethodChannel _methodChannel;

  const AndroidFileLauncherDataSource({MethodChannel? methodChannel})
    : _methodChannel = methodChannel ?? _defaultMethodChannel;

  @override
  Future<bool> openFile(String path) async {
    return (await _methodChannel.invokeMethod<bool>('openFile', {
          'path': path,
        })) ??
        false;
  }

  @override
  Future<bool> revealInFolder(String path) async {
    return (await _methodChannel.invokeMethod<bool>('revealInFolder', {
          'path': path,
        })) ??
        false;
  }

  @override
  Future<bool> shareFile(String path) async {
    return (await _methodChannel.invokeMethod<bool>('shareFile', {
          'path': path,
        })) ??
        false;
  }
}
