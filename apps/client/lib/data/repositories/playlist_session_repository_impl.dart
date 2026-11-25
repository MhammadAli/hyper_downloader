import 'dart:io';

import 'package:hyper_download_client/data/datasources/android/android_method_channel_datasource.dart';
import 'package:hyper_download_client/data/datasources/local/json_playlist_session_local_datasource.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_tool_paths.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/repositories/playlist_session_repository.dart';

/// Persists and restores playlist session manifests cleanly behind [PlaylistSessionRepository].
class PlaylistSessionRepositoryImpl implements PlaylistSessionRepository {
  final JsonPlaylistSessionLocalDataSource _localDataSource;
  final AndroidMethodChannelDataSource? _androidDataSource;
  final bool _isAndroid;

  PlaylistSessionRepositoryImpl({
    required this._localDataSource,
    this._androidDataSource,
    bool? isAndroidOverride,
  }) : _isAndroid = isAndroidOverride ?? Platform.isAndroid;

  @override
  Future<PlaylistSessionSnapshot?> loadSavedSession({
    required String playlistId,
    String? outputDirectory,
  }) async {
    if (_isAndroid) {
      return _androidDataSource!.loadSavedPlaylistSession(
        playlistId: playlistId,
        outputDirectory: outputDirectory,
      );
    }

    final custom = outputDirectory?.trim();
    final hasCustom = custom != null && custom.isNotEmpty;
    final baseDir = hasCustom
        ? Directory(custom)
        : Directory(WindowsToolPaths.resolve().defaultOutputDir);

    final searchDirs = <Directory>[
      if (!hasCustom) ...[
        WindowsToolPaths.mediaSubfolder(baseDir, isAudioOnly: false),
        WindowsToolPaths.mediaSubfolder(baseDir, isAudioOnly: true),
      ],
      baseDir,
    ];

    return _localDataSource.loadSavedSession(searchDirs, playlistId);
  }

  @override
  Future<void> saveSession({
    required String playlistDirectory,
    required PlaylistSessionSnapshot snapshot,
  }) async {
    if (_isAndroid) return;
    await _localDataSource.saveManifestAtomic(
      Directory(playlistDirectory),
      snapshot,
    );
  }
}
