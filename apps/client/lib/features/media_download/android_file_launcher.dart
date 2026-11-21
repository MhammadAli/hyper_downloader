import 'package:flutter/services.dart';
import 'package:hyper_download_client/features/media_download/desktop_file_launcher.dart';

/// Android implementation of [DesktopFileLauncher] delegating open, Downloads view,
/// and system share actions to [AndroidMediaStoreExporter] over MethodChannel.
class AndroidFileLauncher implements DesktopFileLauncher {
  static const MethodChannel _defaultMethodChannel = MethodChannel(
    'com.hyperdownload/media_engine',
  );

  final MethodChannel _methodChannel;

  const AndroidFileLauncher({MethodChannel? methodChannel})
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

  /// Launches an Android share chooser (`ACTION_SEND`) for a completed download.
  Future<bool> shareFile(String path) async {
    return (await _methodChannel.invokeMethod<bool>('shareFile', {
          'path': path,
        })) ??
        false;
  }
}
