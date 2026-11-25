import 'dart:convert';
import 'dart:io';

import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

/// Atomic JSON local datasource for `.hyperdl_playlist_session.json` manifests.
/// Uses the canonical snake_case schema so existing saved manifests remain compatible.
class JsonPlaylistSessionLocalDataSource {
  static const String manifestFilename = '.hyperdl_playlist_session.json';

  const JsonPlaylistSessionLocalDataSource();

  Future<void> saveManifestAtomic(
    Directory playlistDir,
    PlaylistSessionSnapshot snapshot,
  ) async {
    await playlistDir.create(recursive: true);
    final sep = Platform.pathSeparator;
    final target = File('${playlistDir.path}$sep$manifestFilename');
    final temp = File('${playlistDir.path}$sep$manifestFilename.tmp');
    const encoder = JsonEncoder.withIndent('  ');
    final jsonText = encoder.convert(snapshotToJson(snapshot));
    await temp.writeAsString(jsonText, flush: true);
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (_) {}
    }
    await temp.rename(target.path);
  }

  Future<PlaylistSessionSnapshot?> loadSavedSession(
    List<Directory> searchBaseDirs,
    String playlistId,
  ) async {
    for (final baseDir in searchBaseDirs) {
      if (!await baseDir.exists()) continue;
      await for (final entity in baseDir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final manifestFile = File(
          '${entity.path}${Platform.pathSeparator}$manifestFilename',
        );
        if (!await manifestFile.exists()) continue;
        try {
          final raw = await manifestFile.readAsString();
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final snapshot = snapshotFromJson(Map<String, dynamic>.from(decoded));
          if (snapshot.playlistId != playlistId) continue;
          return reconcileRecoveredSnapshot(snapshot);
        } catch (_) {
          continue;
        }
      }
    }
    return null;
  }

  PlaylistSessionSnapshot reconcileRecoveredSnapshot(
    PlaylistSessionSnapshot snapshot,
  ) {
    final reconciledItems = snapshot.items
        .map((item) {
          switch (item.status) {
            case PlaylistItemStatus.analyzing:
            case PlaylistItemStatus.ready:
            case PlaylistItemStatus.downloading:
            case PlaylistItemStatus.merging:
              return item.copyWith(status: PlaylistItemStatus.pending);
            case PlaylistItemStatus.completed:
              final path = item.outputPath;
              final existsNonEmpty =
                  path != null &&
                  path.isNotEmpty &&
                  File(path).existsSync() &&
                  File(path).lengthSync() > 0;
              if (!existsNonEmpty) {
                return item.copyWith(
                  status: PlaylistItemStatus.pending,
                  outputPath: null,
                  downloadedBytes: 0,
                );
              }
              return item;
            case PlaylistItemStatus.pending:
            case PlaylistItemStatus.failed:
            case PlaylistItemStatus.skipped:
            case PlaylistItemStatus.canceled:
              return item;
          }
        })
        .toList(growable: false);

    return snapshot
        .copyWith(isRunning: false, items: reconciledItems)
        .withRecomputedCounters();
  }

  static Map<String, dynamic> snapshotToJson(
    PlaylistSessionSnapshot snapshot,
  ) {
    return {
      'session_id': snapshot.sessionId,
      'playlist_id': snapshot.playlistId,
      'playlist_title': snapshot.playlistTitle,
      'playlist_url': snapshot.playlistUrl,
      'uploader': snapshot.uploader,
      'thumbnail_url': snapshot.thumbnailUrl,
      'output_directory': snapshot.outputDirectory,
      'media_mode': encodeMediaMode(snapshot.mediaMode),
      'quality_cap': encodeQualityCap(snapshot.qualityCap),
      'is_running': snapshot.isRunning,
      'is_paused': snapshot.isPaused,
      'completed_count': snapshot.completedCount,
      'failed_count': snapshot.failedCount,
      'skipped_count': snapshot.skippedCount,
      'total_count': snapshot.totalCount,
      'items': snapshot.items.map(itemToJson).toList(growable: false),
    };
  }

  static PlaylistSessionSnapshot snapshotFromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map((m) => itemFromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
        : const <PlaylistItemState>[];

    return PlaylistSessionSnapshot(
      sessionId: _asStr(json['session_id']),
      playlistId: _asStr(json['playlist_id']),
      playlistTitle: _asStr(json['playlist_title']),
      playlistUrl: _asStr(json['playlist_url']),
      uploader: _asNullableStr(json['uploader']),
      thumbnailUrl: _asNullableStr(json['thumbnail_url']),
      outputDirectory: _asStr(json['output_directory']),
      mediaMode: decodeMediaMode(json['media_mode']),
      qualityCap: decodeQualityCap(json['quality_cap']),
      isRunning: json['is_running'] == true,
      isPaused: json['is_paused'] == true,
      completedCount: _asInt(json['completed_count']),
      failedCount: _asInt(json['failed_count']),
      skippedCount: _asInt(json['skipped_count']),
      totalCount: _asInt(json['total_count']),
      items: items,
    );
  }

  static Map<String, dynamic> itemToJson(PlaylistItemState item) {
    return {
      'order_index': item.orderIndex,
      'video_id': item.videoId,
      'title': item.title,
      'url': item.url,
      'duration_seconds': item.durationSeconds,
      'thumbnail_url': item.thumbnailUrl,
      'status': encodeItemStatus(item.status),
      'selected_quality': item.selectedQuality,
      'audio_language': item.audioLanguage != null
          ? audioMetadataToJson(item.audioLanguage!)
          : null,
      'downloaded_bytes': item.downloadedBytes,
      'total_bytes': item.totalBytes,
      'is_total_estimated': item.isTotalEstimated,
      'output_path': item.outputPath,
      'error_message': item.errorMessage,
    };
  }

  static PlaylistItemState itemFromJson(Map<String, dynamic> json) {
    final audioObj = json['audio_language'];
    return PlaylistItemState(
      orderIndex: _asInt(json['order_index']),
      videoId: _asStr(json['video_id']),
      title: _asStr(json['title']),
      url: _asStr(json['url']),
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
      thumbnailUrl: _asNullableStr(json['thumbnail_url']),
      status: decodeItemStatus(json['status']),
      selectedQuality: _asNullableStr(json['selected_quality']),
      audioLanguage: audioObj is Map
          ? audioMetadataFromJson(Map<String, dynamic>.from(audioObj))
          : null,
      downloadedBytes: _asInt(json['downloaded_bytes']),
      totalBytes: json['total_bytes'] == null
          ? null
          : _asInt(json['total_bytes']),
      isTotalEstimated: json['is_total_estimated'] == true,
      outputPath: _asNullableStr(json['output_path']),
      errorMessage: _asNullableStr(json['error_message']),
    );
  }

  static Map<String, dynamic> audioMetadataToJson(AudioTrackMetadata meta) {
    return {
      'language': meta.language,
      'language_display_name': meta.languageDisplayName,
      'is_original': meta.isOriginal,
      'is_default': meta.isDefault,
      'is_auto_dub': meta.isAutoDub,
      'selection_confidence': encodeConfidence(meta.selectionConfidence),
      'status_note': meta.statusNote,
    };
  }

  static AudioTrackMetadata audioMetadataFromJson(Map<String, dynamic> json) {
    return AudioTrackMetadata(
      language: _asNullableStr(json['language']),
      languageDisplayName: _asNullableStr(json['language_display_name']),
      isOriginal: json['is_original'] as bool?,
      isDefault: json['is_default'] as bool?,
      isAutoDub: json['is_auto_dub'] as bool?,
      selectionConfidence: decodeConfidence(json['selection_confidence']),
      statusNote: _asStr(json['status_note']),
    );
  }

  static String encodeMediaMode(PlaylistMediaMode mode) => switch (mode) {
    PlaylistMediaMode.videoWithSound => 'VideoWithSound',
    PlaylistMediaMode.audioOnly => 'AudioOnly',
  };

  static PlaylistMediaMode decodeMediaMode(Object? raw) =>
      raw == 'AudioOnly'
      ? PlaylistMediaMode.audioOnly
      : PlaylistMediaMode.videoWithSound;

  static String encodeQualityCap(PlaylistQualityCap cap) => switch (cap) {
    PlaylistQualityCap.bestAvailable => 'BestAvailable',
    PlaylistQualityCap.upTo1080p => 'UpTo1080p',
    PlaylistQualityCap.upTo720p => 'UpTo720p',
    PlaylistQualityCap.upTo480p => 'UpTo480p',
  };

  static PlaylistQualityCap decodeQualityCap(Object? raw) => switch (raw) {
    'UpTo1080p' => PlaylistQualityCap.upTo1080p,
    'UpTo720p' => PlaylistQualityCap.upTo720p,
    'UpTo480p' => PlaylistQualityCap.upTo480p,
    _ => PlaylistQualityCap.bestAvailable,
  };

  static String encodeItemStatus(PlaylistItemStatus status) => switch (status) {
    PlaylistItemStatus.pending => 'Pending',
    PlaylistItemStatus.analyzing => 'Analyzing',
    PlaylistItemStatus.ready => 'Ready',
    PlaylistItemStatus.downloading => 'Downloading',
    PlaylistItemStatus.merging => 'Merging',
    PlaylistItemStatus.completed => 'Completed',
    PlaylistItemStatus.failed => 'Failed',
    PlaylistItemStatus.skipped => 'Skipped',
    PlaylistItemStatus.canceled => 'Canceled',
  };

  static PlaylistItemStatus decodeItemStatus(Object? raw) => switch (raw) {
    'Analyzing' => PlaylistItemStatus.analyzing,
    'Ready' => PlaylistItemStatus.ready,
    'Downloading' => PlaylistItemStatus.downloading,
    'Merging' => PlaylistItemStatus.merging,
    'Completed' => PlaylistItemStatus.completed,
    'Failed' => PlaylistItemStatus.failed,
    'Skipped' => PlaylistItemStatus.skipped,
    'Canceled' => PlaylistItemStatus.canceled,
    _ => PlaylistItemStatus.pending,
  };

  static String encodeConfidence(AudioSelectionConfidence c) => switch (c) {
    AudioSelectionConfidence.confirmedOriginal => 'ConfirmedOriginal',
    AudioSelectionConfidence.likelyOriginal => 'LikelyOriginal',
    AudioSelectionConfidence.singleOrUnmarked => 'SingleOrUnmarked',
    AudioSelectionConfidence.ambiguousOrUnknown => 'AmbiguousOrUnknown',
  };

  static AudioSelectionConfidence decodeConfidence(Object? raw) => switch (raw) {
    'ConfirmedOriginal' => AudioSelectionConfidence.confirmedOriginal,
    'LikelyOriginal' => AudioSelectionConfidence.likelyOriginal,
    'SingleOrUnmarked' => AudioSelectionConfidence.singleOrUnmarked,
    _ => AudioSelectionConfidence.ambiguousOrUnknown,
  };

  static String _asStr(Object? raw) => raw == null ? '' : raw.toString();

  static String? _asNullableStr(Object? raw) => raw?.toString();

  static int _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }
}
