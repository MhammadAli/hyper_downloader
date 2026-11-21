import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';

/// Android repository implementation backed by Kotlin + Chaquopy over MethodChannel/EventChannel.
class AndroidMediaDownloadRepository implements MediaDownloadRepository {
  static const MethodChannel _defaultMethodChannel = MethodChannel(
    'com.hyperdownload/media_engine',
  );
  static const EventChannel _defaultDownloadProgressChannel = EventChannel(
    'com.hyperdownload/download_progress',
  );
  static const EventChannel _defaultPlaylistProgressChannel = EventChannel(
    'com.hyperdownload/playlist_progress',
  );
  static const EventChannel _defaultSizeEstimateChannel = EventChannel(
    'com.hyperdownload/playlist_size_estimate',
  );

  final MethodChannel _methodChannel;
  final EventChannel _downloadProgressChannel;
  final EventChannel _playlistProgressChannel;
  final EventChannel _sizeEstimateChannel;

  const AndroidMediaDownloadRepository({
    MethodChannel? methodChannel,
    EventChannel? downloadProgressChannel,
    EventChannel? playlistProgressChannel,
    EventChannel? sizeEstimateChannel,
  }) : _methodChannel = methodChannel ?? _defaultMethodChannel,
       _downloadProgressChannel =
           downloadProgressChannel ?? _defaultDownloadProgressChannel,
       _playlistProgressChannel =
           playlistProgressChannel ?? _defaultPlaylistProgressChannel,
       _sizeEstimateChannel =
           sizeEstimateChannel ?? _defaultSizeEstimateChannel;

  @override
  String ping() => 'pong';

  @override
  String engineVersion() => '0.1.0-android';

  /// Executes native Python/yt-dlp/FFmpeg/FFprobe/QuickJS diagnostics via Kotlin.
  Future<Map<String, dynamic>> runDiagnostics() async {
    final raw = await _invokeString('runDiagnostics');
    return _decodeJsonObject(raw);
  }

  @override
  Future<MediaInspection> inspectMedia(String url) async {
    final raw = await _invokeString('inspectMedia', {'url': url});
    return AndroidEngineJsonCodec.mediaInspectionFromJson(
      _decodeJsonObject(raw),
    );
  }

  /// Directly inspects an explicit playlist URL via the Android engine.
  Future<PlaylistInspection> inspectPlaylist(String url) async {
    final raw = await _invokeString('inspectPlaylist', {'url': url});
    return AndroidEngineJsonCodec.playlistInspectionFromJson(
      _decodeJsonObject(raw),
    );
  }

  @override
  Future<UrlInspectionResult> inspectUrl(String url) async {
    final raw = await _invokeString('inspectUrl', {'url': url});
    return AndroidEngineJsonCodec.urlInspectionResultFromJson(
      _decodeJsonObject(raw),
    );
  }

  @override
  Future<String> startDownload(StartDownloadRequest request) async {
    final payload = jsonEncode(
      AndroidEngineJsonCodec.startDownloadRequestToJson(request),
    );
    return _invokeString('startDownload', {'requestJson': payload});
  }

  @override
  Future<void> cancelDownload(String jobId) async {
    await _invokeVoid('cancelDownload', {'jobId': jobId});
  }

  @override
  Future<String> resumeDownload(String jobId) async {
    return _invokeString('resumeDownload', {'jobId': jobId});
  }

  @override
  Stream<DownloadProgressEvent> watchDownloadProgress() {
    return _downloadProgressChannel.receiveBroadcastStream().map((raw) {
      return AndroidEngineJsonCodec.downloadProgressEventFromJson(
        _decodeJsonObject(raw as String),
      );
    });
  }

  @override
  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  ) async {
    final payload = jsonEncode(
      AndroidEngineJsonCodec.startPlaylistDownloadRequestToJson(request),
    );
    final raw = await _invokeString('startPlaylistDownload', {
      'requestJson': payload,
    });
    return AndroidEngineJsonCodec.playlistSessionSnapshotFromJson(
      _decodeJsonObject(raw),
    );
  }

  @override
  Future<void> pausePlaylistDownload(String sessionId) async {
    await _invokeVoid('pausePlaylistDownload', {'sessionId': sessionId});
  }

  @override
  Future<PlaylistSessionSnapshot> resumePlaylistDownload(
    String sessionId,
  ) async {
    final raw = await _invokeString('resumePlaylistDownload', {
      'sessionId': sessionId,
    });
    return AndroidEngineJsonCodec.playlistSessionSnapshotFromJson(
      _decodeJsonObject(raw),
    );
  }

  @override
  Future<void> cancelPlaylistDownload(String sessionId) async {
    await _invokeVoid('cancelPlaylistDownload', {'sessionId': sessionId});
  }

  @override
  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(
    String sessionId,
  ) async {
    final raw = await _invokeString('retryFailedPlaylistItems', {
      'sessionId': sessionId,
    });
    return AndroidEngineJsonCodec.playlistSessionSnapshotFromJson(
      _decodeJsonObject(raw),
    );
  }

  @override
  Future<PlaylistSessionSnapshot?> loadSavedPlaylistSession({
    required String playlistId,
    String? outputDirectory,
  }) async {
    final raw = await _invokeNullableString('loadSavedPlaylistSession', {
      'playlistId': playlistId,
      'outputDirectory': ?outputDirectory,
    });
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return AndroidEngineJsonCodec.playlistSessionSnapshotFromJson(
      _decodeJsonObject(raw),
    );
  }

  @override
  Stream<PlaylistProgressEvent> watchPlaylistProgress() {
    return _playlistProgressChannel.receiveBroadcastStream().map((raw) {
      return AndroidEngineJsonCodec.playlistProgressEventFromJson(
        _decodeJsonObject(raw as String),
      );
    });
  }

  @override
  Future<PlaylistSizeEstimate> estimatePlaylistSize(
    EstimatePlaylistSizeRequest request,
  ) async {
    final payload = jsonEncode(
      AndroidEngineJsonCodec.estimatePlaylistSizeRequestToJson(request),
    );
    final raw = await _invokeString('estimatePlaylistSize', {
      'requestJson': payload,
    });
    return AndroidEngineJsonCodec.playlistSizeEstimateFromJson(
      _decodeJsonObject(raw),
    );
  }

  @override
  Future<void> cancelPlaylistSizeEstimation(String estimationId) async {
    await _invokeVoid('cancelPlaylistSizeEstimation', {
      'estimationId': estimationId,
    });
  }

  @override
  Stream<PlaylistSizeEstimate> watchPlaylistSizeEstimate() {
    return _sizeEstimateChannel.receiveBroadcastStream().map((raw) {
      return AndroidEngineJsonCodec.playlistSizeEstimateFromJson(
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
      throw StateError('Android engine returned null for $method.');
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
      throw Exception(
        err.message?.trim().isNotEmpty == true ? err.message : err.code,
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
      throw Exception(
        err.message?.trim().isNotEmpty == true ? err.message : err.code,
      );
    }
  }

  static Map<String, dynamic> _decodeJsonObject(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw FormatException('Expected JSON object from Android engine.');
  }
}

/// Canonical JSON <-> Dart DTO serializer matching Rust `serde_json` representations.
class AndroidEngineJsonCodec {
  AndroidEngineJsonCodec._();

  static const Map<String, AudioSelectionConfidence> _confidenceByWire = {
    'ConfirmedOriginal': AudioSelectionConfidence.confirmedOriginal,
    'LikelyOriginal': AudioSelectionConfidence.likelyOriginal,
    'SingleOrUnmarked': AudioSelectionConfidence.singleOrUnmarked,
    'AmbiguousOrUnknown': AudioSelectionConfidence.ambiguousOrUnknown,
  };

  static const Map<String, DownloadPhase> _phaseByWire = {
    'Analyzing': DownloadPhase.analyzing,
    'Downloading': DownloadPhase.downloading,
    'Merging': DownloadPhase.merging,
    'Completed': DownloadPhase.completed,
    'Canceled': DownloadPhase.canceled,
    'Failed': DownloadPhase.failed,
  };

  static const Map<String, FileSizeAccuracy> _sizeAccuracyByWire = {
    'Exact': FileSizeAccuracy.exact,
    'Estimated': FileSizeAccuracy.estimated,
    'Unknown': FileSizeAccuracy.unknown,
  };

  static const Map<String, FormatSelectionStrategy> _strategyByWire = {
    'CombinedAudioVideo': FormatSelectionStrategy.combinedAudioVideo,
    'PairVideoAndAudioWithFfmpeg':
        FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
    'AudioOnlyStream': FormatSelectionStrategy.audioOnlyStream,
  };

  static const Map<String, InspectionTargetKind> _targetKindByWire = {
    'SingleVideo': InspectionTargetKind.singleVideo,
    'Playlist': InspectionTargetKind.playlist,
  };

  static const Map<String, PlaylistEntryAvailability> _availabilityByWire = {
    'Available': PlaylistEntryAvailability.available,
    'Private': PlaylistEntryAvailability.private,
    'Removed': PlaylistEntryAvailability.removed,
    'Unavailable': PlaylistEntryAvailability.unavailable,
  };

  static const Map<String, PlaylistEventKind> _playlistEventKindByWire = {
    'PlaylistStarted': PlaylistEventKind.playlistStarted,
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

  static const Map<String, PlaylistMediaMode> _mediaModeByWire = {
    'VideoWithSound': PlaylistMediaMode.videoWithSound,
    'AudioOnly': PlaylistMediaMode.audioOnly,
  };

  static const Map<String, PlaylistQualityCap> _qualityCapByWire = {
    'BestAvailable': PlaylistQualityCap.bestAvailable,
    'UpTo1080p': PlaylistQualityCap.upTo1080P,
    'UpTo720p': PlaylistQualityCap.upTo720P,
    'UpTo480p': PlaylistQualityCap.upTo480P,
  };

  static const Map<String, PlaylistSizeStatus> _sizeStatusByWire = {
    'Idle': PlaylistSizeStatus.idle,
    'Calculating': PlaylistSizeStatus.calculating,
    'Exact': PlaylistSizeStatus.exact,
    'Estimated': PlaylistSizeStatus.estimated,
    'Partial': PlaylistSizeStatus.partial,
    'Unknown': PlaylistSizeStatus.unknown,
    'Failed': PlaylistSizeStatus.failed,
    'Canceled': PlaylistSizeStatus.canceled,
  };

  static const Map<String, StreamKind> _streamKindByWire = {
    'MuxedAudioVideo': StreamKind.muxedAudioVideo,
    'VideoOnly': StreamKind.videoOnly,
    'AudioOnly': StreamKind.audioOnly,
  };

  static String encodePlaylistMediaMode(PlaylistMediaMode value) {
    return switch (value) {
      PlaylistMediaMode.videoWithSound => 'VideoWithSound',
      PlaylistMediaMode.audioOnly => 'AudioOnly',
    };
  }

  static String encodePlaylistQualityCap(PlaylistQualityCap value) {
    return switch (value) {
      PlaylistQualityCap.bestAvailable => 'BestAvailable',
      PlaylistQualityCap.upTo1080P => 'UpTo1080p',
      PlaylistQualityCap.upTo720P => 'UpTo720p',
      PlaylistQualityCap.upTo480P => 'UpTo480p',
    };
  }

  static String encodeDownloadSelectionKind(DownloadSelectionKind value) {
    return switch (value) {
      DownloadSelectionKind.single => 'Single',
      DownloadSelectionKind.videoAndAudio => 'VideoAndAudio',
    };
  }

  static String encodePlaylistEntryAvailability(
    PlaylistEntryAvailability value,
  ) {
    return switch (value) {
      PlaylistEntryAvailability.available => 'Available',
      PlaylistEntryAvailability.private => 'Private',
      PlaylistEntryAvailability.removed => 'Removed',
      PlaylistEntryAvailability.unavailable => 'Unavailable',
    };
  }

  static AudioTrackMetadata audioTrackMetadataFromJson(
    Map<String, dynamic> json,
  ) {
    return AudioTrackMetadata(
      language: _asNullableString(json['language']),
      languageDisplayName: _asNullableString(json['language_display_name']),
      isOriginal: _asNullableBool(json['is_original']),
      isDefault: _asNullableBool(json['is_default']),
      isAutoDub: _asNullableBool(json['is_auto_dub']),
      selectionConfidence: _lookupEnum(
        _confidenceByWire,
        json['selection_confidence'],
        AudioSelectionConfidence.ambiguousOrUnknown,
      ),
      statusNote: _asString(json['status_note']),
    );
  }

  static VideoQualityOption videoQualityOptionFromJson(
    Map<String, dynamic> json,
  ) {
    return VideoQualityOption(
      resolution: _asString(json['resolution']),
      height: _asNullableInt(json['height']),
      fps: _asNullableDouble(json['fps']),
      container: _asString(json['container']),
      displaySize: _asString(json['display_size']),
      fileSizeBytes: _asNullableBigInt(json['file_size_bytes']),
      sizeAccuracy: _lookupEnum(
        _sizeAccuracyByWire,
        json['size_accuracy'],
        FileSizeAccuracy.unknown,
      ),
      videoFormatId: _asString(json['video_format_id']),
      selectedAudioFormatId: _asNullableString(
        json['selected_audio_format_id'],
      ),
      audioLanguage: _optionalObject(
        json['audio_language'],
        audioTrackMetadataFromJson,
      ),
      formatSelectionStrategy: _lookupEnum(
        _strategyByWire,
        json['format_selection_strategy'],
        FormatSelectionStrategy.combinedAudioVideo,
      ),
    );
  }

  static AudioQualityOption audioQualityOptionFromJson(
    Map<String, dynamic> json,
  ) {
    return AudioQualityOption(
      qualityLabel: _asString(json['quality_label']),
      container: _asString(json['container']),
      bitrateKbps: _asNullableDouble(json['bitrate_kbps']),
      displaySize: _asString(json['display_size']),
      fileSizeBytes: _asNullableBigInt(json['file_size_bytes']),
      sizeAccuracy: _lookupEnum(
        _sizeAccuracyByWire,
        json['size_accuracy'],
        FileSizeAccuracy.unknown,
      ),
      formatId: _asString(json['format_id']),
      audioLanguage: _optionalObject(
        json['audio_language'],
        audioTrackMetadataFromJson,
      ),
    );
  }

  static DiscoveredFormat discoveredFormatFromJson(Map<String, dynamic> json) {
    return DiscoveredFormat(
      formatId: _asString(json['format_id']),
      container: _asString(json['container']),
      streamKind: _lookupEnum(
        _streamKindByWire,
        json['stream_kind'],
        StreamKind.muxedAudioVideo,
      ),
      resolution: _asString(json['resolution']),
      width: _asNullableInt(json['width']),
      height: _asNullableInt(json['height']),
      fps: _asNullableDouble(json['fps']),
      vcodec: _asNullableString(json['vcodec']),
      acodec: _asNullableString(json['acodec']),
      bitrateKbps: _asNullableDouble(json['bitrate_kbps']),
      fileSizeBytes: _asNullableBigInt(json['file_size_bytes']),
      sizeAccuracy: _lookupEnum(
        _sizeAccuracyByWire,
        json['size_accuracy'],
        FileSizeAccuracy.unknown,
      ),
      formatNote: _asNullableString(json['format_note']),
    );
  }

  static MediaInspection mediaInspectionFromJson(Map<String, dynamic> json) {
    return MediaInspection(
      id: _asString(json['id']),
      title: _asString(json['title']),
      uploader: _asNullableString(json['uploader']),
      durationSeconds: _asNullableDouble(json['duration_seconds']),
      thumbnailUrl: _asNullableString(json['thumbnail_url']),
      webpageUrl: _asString(json['webpage_url']),
      providerName: _asString(json['provider_name']),
      originalAudio: _optionalObject(
        json['original_audio'],
        audioTrackMetadataFromJson,
      ),
      videoOptions: _objectList(
        json['video_options'],
        videoQualityOptionFromJson,
      ),
      audioOptions: _objectList(
        json['audio_options'],
        audioQualityOptionFromJson,
      ),
      formats: _objectList(json['formats'], discoveredFormatFromJson),
    );
  }

  static PlaylistEntrySummary playlistEntrySummaryFromJson(
    Map<String, dynamic> json,
  ) {
    return PlaylistEntrySummary(
      orderIndex: _asInt(json['order_index']),
      videoId: _asString(json['video_id']),
      title: _asString(json['title']),
      url: _asString(json['url']),
      uploader: _asNullableString(json['uploader']),
      durationSeconds: _asNullableDouble(json['duration_seconds']),
      thumbnailUrl: _asNullableString(json['thumbnail_url']),
      availability: _lookupEnum(
        _availabilityByWire,
        json['availability'],
        PlaylistEntryAvailability.unavailable,
      ),
      availabilityReason: _asNullableString(json['availability_reason']),
    );
  }

  static PlaylistInspection playlistInspectionFromJson(
    Map<String, dynamic> json,
  ) {
    return PlaylistInspection(
      id: _asString(json['id']),
      title: _asString(json['title']),
      uploader: _asNullableString(json['uploader']),
      thumbnailUrl: _asNullableString(json['thumbnail_url']),
      webpageUrl: _asString(json['webpage_url']),
      providerName: _asString(json['provider_name']),
      totalItemCount: _asInt(json['total_item_count']),
      entries: _objectList(json['entries'], playlistEntrySummaryFromJson),
    );
  }

  static UrlInspectionResult urlInspectionResultFromJson(
    Map<String, dynamic> json,
  ) {
    return UrlInspectionResult(
      kind: _lookupEnum(
        _targetKindByWire,
        json['kind'],
        InspectionTargetKind.singleVideo,
      ),
      video: _optionalObject(json['video'], mediaInspectionFromJson),
      playlist: _optionalObject(json['playlist'], playlistInspectionFromJson),
    );
  }

  static DownloadProgressEvent downloadProgressEventFromJson(
    Map<String, dynamic> json,
  ) {
    return DownloadProgressEvent(
      jobId: _asString(json['job_id']),
      phase: _lookupEnum(_phaseByWire, json['phase'], DownloadPhase.analyzing),
      downloadedBytes: _asBigInt(json['downloaded_bytes']),
      totalBytes: _asNullableBigInt(json['total_bytes']),
      isTotalEstimated: _asBool(json['is_total_estimated']),
      speedBytesPerSec: _asNullableDouble(json['speed_bytes_per_sec']),
      etaSeconds: _asNullableBigInt(json['eta_seconds']),
      outputPath: _asNullableString(json['output_path']),
      message: _asNullableString(json['message']),
    );
  }

  static PlaylistItemState playlistItemStateFromJson(
    Map<String, dynamic> json,
  ) {
    return PlaylistItemState(
      orderIndex: _asInt(json['order_index']),
      videoId: _asString(json['video_id']),
      title: _asString(json['title']),
      url: _asString(json['url']),
      durationSeconds: _asNullableDouble(json['duration_seconds']),
      thumbnailUrl: _asNullableString(json['thumbnail_url']),
      status: _lookupEnum(
        _playlistItemStatusByWire,
        json['status'],
        PlaylistItemStatus.pending,
      ),
      selectedQuality: _asNullableString(json['selected_quality']),
      audioLanguage: _optionalObject(
        json['audio_language'],
        audioTrackMetadataFromJson,
      ),
      downloadedBytes: _asBigInt(json['downloaded_bytes']),
      totalBytes: _asNullableBigInt(json['total_bytes']),
      isTotalEstimated: _asBool(json['is_total_estimated']),
      outputPath: _asNullableString(json['output_path']),
      errorMessage: _asNullableString(json['error_message']),
    );
  }

  static PlaylistSessionSnapshot playlistSessionSnapshotFromJson(
    Map<String, dynamic> json,
  ) {
    return PlaylistSessionSnapshot(
      sessionId: _asString(json['session_id']),
      playlistId: _asString(json['playlist_id']),
      playlistTitle: _asString(json['playlist_title']),
      playlistUrl: _asString(json['playlist_url']),
      uploader: _asNullableString(json['uploader']),
      thumbnailUrl: _asNullableString(json['thumbnail_url']),
      outputDirectory: _asString(json['output_directory']),
      mediaMode: _lookupEnum(
        _mediaModeByWire,
        json['media_mode'],
        PlaylistMediaMode.videoWithSound,
      ),
      qualityCap: _lookupEnum(
        _qualityCapByWire,
        json['quality_cap'],
        PlaylistQualityCap.bestAvailable,
      ),
      isRunning: _asBool(json['is_running']),
      isPaused: _asBool(json['is_paused']),
      completedCount: _asInt(json['completed_count']),
      failedCount: _asInt(json['failed_count']),
      skippedCount: _asInt(json['skipped_count']),
      totalCount: _asInt(json['total_count']),
      items: _objectList(json['items'], playlistItemStateFromJson),
    );
  }

  static PlaylistProgressEvent playlistProgressEventFromJson(
    Map<String, dynamic> json,
  ) {
    return PlaylistProgressEvent(
      sessionId: _asString(json['session_id']),
      kind: _lookupEnum(
        _playlistEventKindByWire,
        json['kind'],
        PlaylistEventKind.playlistItemProgress,
      ),
      itemIndex: _asNullableInt(json['item_index']),
      itemStatus: _optionalEnum(_playlistItemStatusByWire, json['item_status']),
      selectedQuality: _asNullableString(json['selected_quality']),
      audioLanguage: _optionalObject(
        json['audio_language'],
        audioTrackMetadataFromJson,
      ),
      itemDownloadedBytes: _asBigInt(json['item_downloaded_bytes']),
      itemTotalBytes: _asNullableBigInt(json['item_total_bytes']),
      itemIsTotalEstimated: _asBool(json['item_is_total_estimated']),
      speedBytesPerSec: _asNullableDouble(json['speed_bytes_per_sec']),
      etaSeconds: _asNullableBigInt(json['eta_seconds']),
      outputPath: _asNullableString(json['output_path']),
      completedCount: _asInt(json['completed_count']),
      failedCount: _asInt(json['failed_count']),
      skippedCount: _asInt(json['skipped_count']),
      totalCount: _asInt(json['total_count']),
      playlistOutputDir: _asNullableString(json['playlist_output_dir']),
      message: _asNullableString(json['message']),
    );
  }

  static PlaylistItemSizeInfo playlistItemSizeInfoFromJson(
    Map<String, dynamic> json,
  ) {
    return PlaylistItemSizeInfo(
      orderIndex: _asInt(json['order_index']),
      selectedQuality: _asNullableString(json['selected_quality']),
      expectedSizeBytes: _asNullableBigInt(json['expected_size_bytes']),
      sizeAccuracy: _lookupEnum(
        _sizeAccuracyByWire,
        json['size_accuracy'],
        FileSizeAccuracy.unknown,
      ),
      displaySize: _asString(json['display_size']),
      failed: _asBool(json['failed']),
      errorMessage: _asNullableString(json['error_message']),
    );
  }

  static PlaylistSizeEstimate playlistSizeEstimateFromJson(
    Map<String, dynamic> json,
  ) {
    return PlaylistSizeEstimate(
      estimationId: _asString(json['estimation_id']),
      playlistId: _asString(json['playlist_id']),
      mediaMode: _lookupEnum(
        _mediaModeByWire,
        json['media_mode'],
        PlaylistMediaMode.videoWithSound,
      ),
      qualityCap: _lookupEnum(
        _qualityCapByWire,
        json['quality_cap'],
        PlaylistQualityCap.bestAvailable,
      ),
      status: _lookupEnum(
        _sizeStatusByWire,
        json['status'],
        PlaylistSizeStatus.idle,
      ),
      knownTotalBytes: _asBigInt(json['known_total_bytes']),
      totalEntriesCount: _asInt(json['total_entries_count']),
      unavailableCount: _asInt(json['unavailable_count']),
      eligibleCount: _asInt(json['eligible_count']),
      inspectedCount: _asInt(json['inspected_count']),
      exactCount: _asInt(json['exact_count']),
      estimatedCount: _asInt(json['estimated_count']),
      unknownCount: _asInt(json['unknown_count']),
      failedCount: _asInt(json['failed_count']),
      displaySummary: _asString(json['display_summary']),
      statusMessage: _asNullableString(json['status_message']),
      itemSizes: _objectList(json['item_sizes'], playlistItemSizeInfoFromJson),
    );
  }

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

  static Map<String, dynamic> playlistEntrySummaryToJson(
    PlaylistEntrySummary entry,
  ) {
    return {
      'order_index': entry.orderIndex,
      'video_id': entry.videoId,
      'title': entry.title,
      'url': entry.url,
      'uploader': entry.uploader,
      'duration_seconds': entry.durationSeconds,
      'thumbnail_url': entry.thumbnailUrl,
      'availability': encodePlaylistEntryAvailability(entry.availability),
      'availability_reason': entry.availabilityReason,
    };
  }

  static Map<String, dynamic> playlistInspectionToJson(
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
      'entries': playlist.entries.map(playlistEntrySummaryToJson).toList(),
    };
  }

  static Map<String, dynamic> startPlaylistDownloadRequestToJson(
    StartPlaylistDownloadRequest request,
  ) {
    return {
      'playlist': playlistInspectionToJson(request.playlist),
      'media_mode': encodePlaylistMediaMode(request.mediaMode),
      'quality_cap': encodePlaylistQualityCap(request.qualityCap),
      'output_directory': request.outputDirectory,
    };
  }

  static Map<String, dynamic> estimatePlaylistSizeRequestToJson(
    EstimatePlaylistSizeRequest request,
  ) {
    return {
      'playlist': playlistInspectionToJson(request.playlist),
      'media_mode': encodePlaylistMediaMode(request.mediaMode),
      'quality_cap': encodePlaylistQualityCap(request.qualityCap),
    };
  }

  static T _lookupEnum<T extends Enum>(
    Map<String, T> mapping,
    Object? raw,
    T fallback,
  ) {
    return _optionalEnum(mapping, raw) ?? fallback;
  }

  static T? _optionalEnum<T extends Enum>(Map<String, T> mapping, Object? raw) {
    if (raw == null) return null;
    final key = raw.toString();
    return mapping[key];
  }

  static T? _optionalObject<T>(
    Object? raw,
    T Function(Map<String, dynamic>) builder,
  ) {
    if (raw is Map<String, dynamic>) return builder(raw);
    if (raw is Map) return builder(Map<String, dynamic>.from(raw));
    return null;
  }

  static List<T> _objectList<T>(
    Object? raw,
    T Function(Map<String, dynamic>) builder,
  ) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => builder(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  static String _asString(Object? raw, [String fallback = '']) {
    if (raw == null) return fallback;
    return raw.toString();
  }

  static String? _asNullableString(Object? raw) {
    if (raw == null) return null;
    return raw.toString();
  }

  static bool _asBool(Object? raw, [bool fallback = false]) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    return fallback;
  }

  static bool? _asNullableBool(Object? raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    return null;
  }

  static int _asInt(Object? raw, [int fallback = 0]) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }

  static int? _asNullableInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static double? _asNullableDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is double) return raw;
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  static BigInt _asBigInt(Object? raw) {
    return _asNullableBigInt(raw) ?? BigInt.zero;
  }

  static BigInt? _asNullableBigInt(Object? raw) {
    if (raw == null) return null;
    if (raw is BigInt) return raw;
    if (raw is int) return BigInt.from(raw);
    if (raw is num) return BigInt.from(raw.toInt());
    if (raw is String) return BigInt.tryParse(raw);
    return null;
  }
}
