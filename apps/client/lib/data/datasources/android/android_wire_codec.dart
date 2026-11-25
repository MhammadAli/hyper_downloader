import 'package:hyper_download_client/data/datasources/local/json_playlist_session_local_datasource.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

/// Canonical JSON <-> Domain entity wire codec for Android `MethodChannel` and
/// `EventChannel` messages (only active transfer commands, snapshots, and events).
abstract final class AndroidWireCodec {
  static const Map<String, DownloadPhase> _phaseByWire = {
    'Analyzing': DownloadPhase.analyzing,
    'Downloading': DownloadPhase.downloading,
    'Merging': DownloadPhase.merging,
    'Completed': DownloadPhase.completed,
    'Canceled': DownloadPhase.canceled,
    'Failed': DownloadPhase.failed,
  };

  static const Map<String, PlaylistEventKind> _playlistEventKindByWire = {
    'PlaylistStarted': PlaylistEventKind.playlistStarted,
    'PlaylistBatchStarted': PlaylistEventKind.playlistStarted,
    'PlaylistItemStarted': PlaylistEventKind.playlistItemStarted,
    'PlaylistItemProgress': PlaylistEventKind.playlistItemProgress,
    'PlaylistItemMerging': PlaylistEventKind.playlistItemMerging,
    'PlaylistItemCompleted': PlaylistEventKind.playlistItemCompleted,
    'PlaylistItemFailed': PlaylistEventKind.playlistItemFailed,
    'PlaylistItemSkipped': PlaylistEventKind.playlistItemSkipped,
    'PlaylistPaused': PlaylistEventKind.playlistPaused,
    'PlaylistCanceled': PlaylistEventKind.playlistCanceled,
    'PlaylistCompleted': PlaylistEventKind.playlistCompleted,
  };

  static const Map<String, PlaylistItemStatus> _playlistItemStatusByWire = {
    'Pending': PlaylistItemStatus.pending,
    'Analyzing': PlaylistItemStatus.analyzing,
    'Ready': PlaylistItemStatus.ready,
    'Downloading': PlaylistItemStatus.downloading,
    'Merging': PlaylistItemStatus.merging,
    'Completed': PlaylistItemStatus.completed,
    'Failed': PlaylistItemStatus.failed,
    'Skipped': PlaylistItemStatus.skipped,
    'Canceled': PlaylistItemStatus.canceled,
  };

  static String encodeDownloadSelectionKind(DownloadSelectionKind value) =>
      switch (value) {
        DownloadSelectionKind.single => 'Single',
        DownloadSelectionKind.videoAndAudio => 'VideoAndAudio',
      };

  static String encodePlaylistEntryAvailability(
    PlaylistEntryAvailability value,
  ) => switch (value) {
    PlaylistEntryAvailability.available => 'Available',
    PlaylistEntryAvailability.private => 'Private',
    PlaylistEntryAvailability.removed => 'Removed',
    PlaylistEntryAvailability.unavailable => 'Unavailable',
  };

  static Map<String, dynamic> startDownloadRequestToJson(
    StartDownloadRequest request,
  ) {
    return {
      'url': request.url,
      'title': request.title,
      'selection': {
        'kind': encodeDownloadSelectionKind(request.selection.kind),
        'format_id': request.selection.formatId,
        'video_format_id': request.selection.videoFormatId,
        'audio_format_id': request.selection.audioFormatId,
        'merge_container': request.selection.mergeContainer,
      },
      'output_directory': request.outputDirectory,
    };
  }

  static Map<String, dynamic> startPlaylistDownloadRequestToJson(
    StartPlaylistDownloadRequest request,
  ) {
    return {
      'playlist': _playlistInspectionToJson(request.playlist),
      'media_mode': JsonPlaylistSessionLocalDataSource.encodeMediaMode(
        request.mediaMode,
      ),
      'quality_cap': JsonPlaylistSessionLocalDataSource.encodeQualityCap(
        request.qualityCap,
      ),
      'output_directory': request.outputDirectory,
    };
  }

  static Map<String, dynamic> _playlistInspectionToJson(
    PlaylistInspection playlist,
  ) {
    return {
      'id': playlist.id,
      'title': playlist.title,
      'uploader': playlist.uploader,
      'thumbnail_url': playlist.thumbnailUrl,
      'webpage_url': playlist.webpageUrl,
      'provider_name': playlist.providerName,
      'total_item_count': playlist.totalItemCount,
      'entries': playlist.entries
          .map(
            (e) => {
              'order_index': e.orderIndex,
              'video_id': e.videoId,
              'title': e.title,
              'url': e.url,
              'uploader': e.uploader,
              'duration_seconds': e.durationSeconds,
              'thumbnail_url': e.thumbnailUrl,
              'availability': encodePlaylistEntryAvailability(e.availability),
              'availability_reason': e.availabilityReason,
            },
          )
          .toList(growable: false),
    };
  }

  static DownloadProgressEvent downloadProgressEventFromJson(
    Map<String, dynamic> json,
  ) {
    return DownloadProgressEvent(
      jobId: _asStr(json['job_id']),
      phase: _phaseByWire[json['phase']?.toString()] ?? DownloadPhase.analyzing,
      downloadedBytes: _asInt(json['downloaded_bytes']),
      totalBytes: _asNullableInt(json['total_bytes']),
      isTotalEstimated: json['is_total_estimated'] == true,
      speedBytesPerSec: (json['speed_bytes_per_sec'] as num?)?.toDouble(),
      etaSeconds: _asNullableInt(json['eta_seconds']),
      outputPath: _asNullableStr(json['output_path']),
      message: _asNullableStr(json['message']),
    );
  }

  static PlaylistSessionSnapshot playlistSessionSnapshotFromJson(
    Map<String, dynamic> json,
  ) => JsonPlaylistSessionLocalDataSource.snapshotFromJson(json);

  static PlaylistProgressEvent playlistProgressEventFromJson(
    Map<String, dynamic> json,
  ) {
    final audioObj = json['audio_language'];
    return PlaylistProgressEvent(
      sessionId: _asStr(json['session_id']),
      kind:
          _playlistEventKindByWire[json['kind']?.toString()] ??
          PlaylistEventKind.playlistItemProgress,
      itemIndex: _asNullableInt(json['item_index']),
      itemStatus: json['item_status'] == null
          ? null
          : _playlistItemStatusByWire[json['item_status'].toString()],
      selectedQuality: _asNullableStr(json['selected_quality']),
      audioLanguage: audioObj is Map
          ? JsonPlaylistSessionLocalDataSource.audioMetadataFromJson(
              Map<String, dynamic>.from(audioObj),
            )
          : null,
      itemDownloadedBytes: _asInt(json['item_downloaded_bytes']),
      itemTotalBytes: _asNullableInt(json['item_total_bytes']),
      itemIsTotalEstimated: json['item_is_total_estimated'] == true,
      speedBytesPerSec: (json['speed_bytes_per_sec'] as num?)?.toDouble(),
      etaSeconds: _asNullableInt(json['eta_seconds']),
      outputPath: _asNullableStr(json['output_path']),
      completedCount: _asInt(json['completed_count']),
      failedCount: _asInt(json['failed_count']),
      skippedCount: _asInt(json['skipped_count']),
      totalCount: _asInt(json['total_count']),
      playlistOutputDir: _asNullableStr(json['playlist_output_dir']),
      message: _asNullableStr(json['message']),
    );
  }

  static String _asStr(Object? raw) => raw == null ? '' : raw.toString();

  static String? _asNullableStr(Object? raw) => raw?.toString();

  static int _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  static int? _asNullableInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }
}
