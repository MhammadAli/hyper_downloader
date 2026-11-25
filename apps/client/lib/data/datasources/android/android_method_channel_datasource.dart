import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/data/datasources/android/android_wire_codec.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

/// Thin MethodChannel / EventChannel datasource bridging Dart to Kotlin/Chaquopy
/// on Android for raw `yt-dlp` extraction, ForegroundService transfers, and MediaStore.
class AndroidMethodChannelDataSource {
  static const MethodChannel _defaultMethodChannel = MethodChannel(
    'com.hyperdownload/media_engine',
  );
  static const EventChannel _defaultDownloadProgressChannel = EventChannel(
    'com.hyperdownload/download_progress',
  );
  static const EventChannel _defaultPlaylistProgressChannel = EventChannel(
    'com.hyperdownload/playlist_progress',
  );

  final MethodChannel _methodChannel;
  final EventChannel _downloadProgressChannel;
  final EventChannel _playlistProgressChannel;

  const AndroidMethodChannelDataSource({
    MethodChannel? methodChannel,
    EventChannel? downloadProgressChannel,
    EventChannel? playlistProgressChannel,
  }) : _methodChannel = methodChannel ?? _defaultMethodChannel,
       _downloadProgressChannel =
           downloadProgressChannel ?? _defaultDownloadProgressChannel,
       _playlistProgressChannel =
           playlistProgressChannel ?? _defaultPlaylistProgressChannel;

  Future<String> extractRawInfo({
    required String url,
    required bool isPlaylist,
    required bool isInstagram,
    bool isFacebook = false,
  }) {
    return _invokeString('extractRawInfo', {
      'url': url,
      'isPlaylist': isPlaylist,
      'isInstagram': isInstagram,
      'isFacebook': isFacebook,
    });
  }

  Future<String> startDownload(StartDownloadRequest request) {
    final payload = jsonEncode(
      AndroidWireCodec.startDownloadRequestToJson(request),
    );
    return _invokeString('startDownload', {'requestJson': payload});
  }

  Future<void> cancelDownload(String jobId) =>
      _invokeVoid('cancelDownload', {'jobId': jobId});

  Future<String> resumeDownload(String jobId) =>
      _invokeString('resumeDownload', {'jobId': jobId});

  Stream<DownloadProgressEvent> watchDownloadProgress() {
    return _downloadProgressChannel.receiveBroadcastStream().map((raw) {
      return AndroidWireCodec.downloadProgressEventFromJson(
        _decodeJsonObject(raw as String),
      );
    });
  }

  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  ) async {
    final payload = jsonEncode(
      AndroidWireCodec.startPlaylistDownloadRequestToJson(request),
    );
    final raw = await _invokeString('startPlaylistDownload', {
      'requestJson': payload,
    });
    return AndroidWireCodec.playlistSessionSnapshotFromJson(
      _decodeJsonObject(raw),
    );
  }

  Future<void> pausePlaylistDownload(String sessionId) =>
      _invokeVoid('pausePlaylistDownload', {'sessionId': sessionId});

  Future<PlaylistSessionSnapshot> resumePlaylistDownload(
    String sessionId,
  ) async {
    final raw = await _invokeString('resumePlaylistDownload', {
      'sessionId': sessionId,
    });
    return AndroidWireCodec.playlistSessionSnapshotFromJson(
      _decodeJsonObject(raw),
    );
  }

  Future<void> cancelPlaylistDownload(String sessionId) =>
      _invokeVoid('cancelPlaylistDownload', {'sessionId': sessionId});

  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(
    String sessionId,
  ) async {
    final raw = await _invokeString('retryFailedPlaylistItems', {
      'sessionId': sessionId,
    });
    return AndroidWireCodec.playlistSessionSnapshotFromJson(
      _decodeJsonObject(raw),
    );
  }

  Future<PlaylistSessionSnapshot?> loadSavedPlaylistSession({
    required String playlistId,
    String? outputDirectory,
  }) async {
    final raw = await _invokeNullableString('loadSavedPlaylistSession', {
      'playlistId': playlistId,
      'outputDirectory': ?outputDirectory,
    });
    if (raw == null || raw.trim().isEmpty) return null;
    return AndroidWireCodec.playlistSessionSnapshotFromJson(
      _decodeJsonObject(raw),
    );
  }

  Stream<PlaylistProgressEvent> watchPlaylistProgress() {
    return _playlistProgressChannel.receiveBroadcastStream().map((raw) {
      return AndroidWireCodec.playlistProgressEventFromJson(
        _decodeJsonObject(raw as String),
      );
    });
  }

  Future<String> _invokeString(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    final value = await _invokeNullableString(method, arguments);
    if (value == null) {
      throw ProcessExecutionException('Android engine returned null for $method.');
    }
    return value;
  }

  Future<String?> _invokeNullableString(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      return await _methodChannel.invokeMethod<String>(method, arguments);
    } on PlatformException catch (err) {
      final msg = err.message?.trim();
      throw ProcessExecutionException(
        (msg != null && msg.isNotEmpty) ? msg : err.code,
      );
    }
  }

  Future<void> _invokeVoid(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      await _methodChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (err) {
      final msg = err.message?.trim();
      throw ProcessExecutionException(
        (msg != null && msg.isNotEmpty) ? msg : err.code,
      );
    }
  }

  static Map<String, dynamic> _decodeJsonObject(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const ParseException('Expected JSON object from Android engine.');
  }
}
