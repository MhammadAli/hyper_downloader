import 'package:equatable/equatable.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';

/// Availability state reported for a playlist entry during flat enumeration.
enum PlaylistEntryAvailability { available, private, removed, unavailable }

/// Metadata summary for one entry inside an enumerated playlist.
class PlaylistEntrySummary extends Equatable {
  final int orderIndex;
  final String videoId;
  final String title;
  final String url;
  final String? uploader;
  final double? durationSeconds;
  final String? thumbnailUrl;
  final PlaylistEntryAvailability availability;
  final String? availabilityReason;

  const PlaylistEntrySummary({
    required this.orderIndex,
    required this.videoId,
    required this.title,
    required this.url,
    this.uploader,
    this.durationSeconds,
    this.thumbnailUrl,
    required this.availability,
    this.availabilityReason,
  });

  @override
  List<Object?> get props => [
    orderIndex,
    videoId,
    title,
    url,
    uploader,
    durationSeconds,
    thumbnailUrl,
    availability,
    availabilityReason,
  ];
}

/// Complete playlist inspection metadata and ordered entry list.
class PlaylistInspection extends Equatable {
  final String id;
  final String title;
  final String? uploader;
  final String? thumbnailUrl;
  final String webpageUrl;
  final String providerName;
  final int totalItemCount;
  final List<PlaylistEntrySummary> entries;

  const PlaylistInspection({
    required this.id,
    required this.title,
    this.uploader,
    this.thumbnailUrl,
    required this.webpageUrl,
    required this.providerName,
    required this.totalItemCount,
    required this.entries,
  });

  @override
  List<Object?> get props => [
    id,
    title,
    uploader,
    thumbnailUrl,
    webpageUrl,
    providerName,
    totalItemCount,
    entries,
  ];
}

/// Output mode selected for a playlist download batch.
enum PlaylistMediaMode { videoWithSound, audioOnly }

/// Upper quality cap applied per playlist item without fabricating unavailable streams.
enum PlaylistQualityCap { bestAvailable, upTo1080p, upTo720p, upTo480p }

/// Lifecycle state tracked for each individual playlist item.
enum PlaylistItemStatus {
  pending,
  analyzing,
  ready,
  downloading,
  merging,
  completed,
  failed,
  skipped,
  canceled,
}

const Object _unset = Object();

/// Per-item runtime and persisted status inside a playlist session.
class PlaylistItemState extends Equatable {
  final int orderIndex;
  final String videoId;
  final String title;
  final String url;
  final double? durationSeconds;
  final String? thumbnailUrl;
  final PlaylistItemStatus status;
  final String? selectedQuality;
  final AudioTrackMetadata? audioLanguage;
  final int downloadedBytes;
  final int? totalBytes;
  final bool isTotalEstimated;
  final String? outputPath;
  final String? errorMessage;

  const PlaylistItemState({
    required this.orderIndex,
    required this.videoId,
    required this.title,
    required this.url,
    this.durationSeconds,
    this.thumbnailUrl,
    required this.status,
    this.selectedQuality,
    this.audioLanguage,
    required this.downloadedBytes,
    this.totalBytes,
    required this.isTotalEstimated,
    this.outputPath,
    this.errorMessage,
  });

  PlaylistItemState copyWith({
    PlaylistItemStatus? status,
    Object? selectedQuality = _unset,
    Object? audioLanguage = _unset,
    int? downloadedBytes,
    Object? totalBytes = _unset,
    bool? isTotalEstimated,
    Object? outputPath = _unset,
    Object? errorMessage = _unset,
  }) {
    return PlaylistItemState(
      orderIndex: orderIndex,
      videoId: videoId,
      title: title,
      url: url,
      durationSeconds: durationSeconds,
      thumbnailUrl: thumbnailUrl,
      status: status ?? this.status,
      selectedQuality: identical(selectedQuality, _unset)
          ? this.selectedQuality
          : selectedQuality as String?,
      audioLanguage: identical(audioLanguage, _unset)
          ? this.audioLanguage
          : audioLanguage as AudioTrackMetadata?,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: identical(totalBytes, _unset)
          ? this.totalBytes
          : totalBytes as int?,
      isTotalEstimated: isTotalEstimated ?? this.isTotalEstimated,
      outputPath: identical(outputPath, _unset)
          ? this.outputPath
          : outputPath as String?,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  @override
  List<Object?> get props => [
    orderIndex,
    videoId,
    title,
    url,
    durationSeconds,
    thumbnailUrl,
    status,
    selectedQuality,
    audioLanguage,
    downloadedBytes,
    totalBytes,
    isTotalEstimated,
    outputPath,
    errorMessage,
  ];
}

/// Lightweight persistent manifest & UI snapshot for a playlist download session.
class PlaylistSessionSnapshot extends Equatable {
  final String sessionId;
  final String playlistId;
  final String playlistTitle;
  final String playlistUrl;
  final String? uploader;
  final String? thumbnailUrl;
  final String outputDirectory;
  final PlaylistMediaMode mediaMode;
  final PlaylistQualityCap qualityCap;
  final bool isRunning;
  final bool isPaused;
  final int completedCount;
  final int failedCount;
  final int skippedCount;
  final int totalCount;
  final List<PlaylistItemState> items;

  const PlaylistSessionSnapshot({
    required this.sessionId,
    required this.playlistId,
    required this.playlistTitle,
    required this.playlistUrl,
    this.uploader,
    this.thumbnailUrl,
    required this.outputDirectory,
    required this.mediaMode,
    required this.qualityCap,
    required this.isRunning,
    required this.isPaused,
    required this.completedCount,
    required this.failedCount,
    required this.skippedCount,
    required this.totalCount,
    required this.items,
  });

  PlaylistSessionSnapshot copyWith({
    String? outputDirectory,
    bool? isRunning,
    bool? isPaused,
    int? completedCount,
    int? failedCount,
    int? skippedCount,
    int? totalCount,
    List<PlaylistItemState>? items,
  }) {
    final nextItems = items ?? this.items;
    return PlaylistSessionSnapshot(
      sessionId: sessionId,
      playlistId: playlistId,
      playlistTitle: playlistTitle,
      playlistUrl: playlistUrl,
      uploader: uploader,
      thumbnailUrl: thumbnailUrl,
      outputDirectory: outputDirectory ?? this.outputDirectory,
      mediaMode: mediaMode,
      qualityCap: qualityCap,
      isRunning: isRunning ?? this.isRunning,
      isPaused: isPaused ?? this.isPaused,
      completedCount: completedCount ?? this.completedCount,
      failedCount: failedCount ?? this.failedCount,
      skippedCount: skippedCount ?? this.skippedCount,
      totalCount: totalCount ?? nextItems.length,
      items: nextItems,
    );
  }

  /// Recomputes [completedCount], [failedCount], [skippedCount], and [totalCount] from [items].
  PlaylistSessionSnapshot withRecomputedCounters() {
    var completed = 0;
    var failed = 0;
    var skipped = 0;
    for (final item in items) {
      switch (item.status) {
        case PlaylistItemStatus.completed:
          completed++;
        case PlaylistItemStatus.failed:
          failed++;
        case PlaylistItemStatus.skipped:
          skipped++;
        case PlaylistItemStatus.pending:
        case PlaylistItemStatus.analyzing:
        case PlaylistItemStatus.ready:
        case PlaylistItemStatus.downloading:
        case PlaylistItemStatus.merging:
        case PlaylistItemStatus.canceled:
          break;
      }
    }
    return copyWith(
      completedCount: completed,
      failedCount: failed,
      skippedCount: skipped,
      totalCount: items.length,
    );
  }

  @override
  List<Object?> get props => [
    sessionId,
    playlistId,
    playlistTitle,
    playlistUrl,
    uploader,
    thumbnailUrl,
    outputDirectory,
    mediaMode,
    qualityCap,
    isRunning,
    isPaused,
    completedCount,
    failedCount,
    skippedCount,
    totalCount,
    items,
  ];
}

/// Request payload to start downloading a previously inspected playlist.
class StartPlaylistDownloadRequest extends Equatable {
  final PlaylistInspection playlist;
  final PlaylistMediaMode mediaMode;
  final PlaylistQualityCap qualityCap;
  final String? outputDirectory;

  const StartPlaylistDownloadRequest({
    required this.playlist,
    required this.mediaMode,
    required this.qualityCap,
    this.outputDirectory,
  });

  @override
  List<Object?> get props => [playlist, mediaMode, qualityCap, outputDirectory];
}

/// Event discriminator for structured playlist batch progress reporting.
enum PlaylistEventKind {
  playlistStarted,
  playlistItemStarted,
  playlistItemProgress,
  playlistItemMerging,
  playlistItemCompleted,
  playlistItemFailed,
  playlistItemSkipped,
  playlistPaused,
  playlistCanceled,
  playlistCompleted,
}

/// Incremental playlist batch and active-item progress streamed to the UI.
class PlaylistProgressEvent extends Equatable {
  final String sessionId;
  final PlaylistEventKind kind;
  final int? itemIndex;
  final PlaylistItemStatus? itemStatus;
  final String? selectedQuality;
  final AudioTrackMetadata? audioLanguage;
  final int itemDownloadedBytes;
  final int? itemTotalBytes;
  final bool itemIsTotalEstimated;
  final double? speedBytesPerSec;
  final int? etaSeconds;
  final String? outputPath;
  final int completedCount;
  final int failedCount;
  final int skippedCount;
  final int totalCount;
  final String? playlistOutputDir;
  final String? message;

  const PlaylistProgressEvent({
    required this.sessionId,
    required this.kind,
    this.itemIndex,
    this.itemStatus,
    this.selectedQuality,
    this.audioLanguage,
    required this.itemDownloadedBytes,
    this.itemTotalBytes,
    required this.itemIsTotalEstimated,
    this.speedBytesPerSec,
    this.etaSeconds,
    this.outputPath,
    required this.completedCount,
    required this.failedCount,
    required this.skippedCount,
    required this.totalCount,
    this.playlistOutputDir,
    this.message,
  });

  @override
  List<Object?> get props => [
    sessionId,
    kind,
    itemIndex,
    itemStatus,
    selectedQuality,
    audioLanguage,
    itemDownloadedBytes,
    itemTotalBytes,
    itemIsTotalEstimated,
    speedBytesPerSec,
    etaSeconds,
    outputPath,
    completedCount,
    failedCount,
    skippedCount,
    totalCount,
    playlistOutputDir,
    message,
  ];
}

/// Truthful aggregation state for pre-download playlist total size estimation.
enum PlaylistSizeStatus {
  idle,
  calculating,
  exact,
  estimated,
  partial,
  unknown,
  failed,
  canceled,
}

/// Resolved per-item quality and expected size metadata prior to download.
class PlaylistItemSizeInfo extends Equatable {
  final int orderIndex;
  final String? selectedQuality;
  final int? expectedSizeBytes;
  final FileSizeAccuracy sizeAccuracy;
  final String displaySize;
  final bool failed;
  final String? errorMessage;

  const PlaylistItemSizeInfo({
    required this.orderIndex,
    this.selectedQuality,
    this.expectedSizeBytes,
    required this.sizeAccuracy,
    required this.displaySize,
    required this.failed,
    this.errorMessage,
  });

  @override
  List<Object?> get props => [
    orderIndex,
    selectedQuality,
    expectedSizeBytes,
    sizeAccuracy,
    displaySize,
    failed,
    errorMessage,
  ];
}

/// Aggregate playlist size estimate synchronized with selected mode & quality cap.
class PlaylistSizeEstimate extends Equatable {
  final String estimationId;
  final String playlistId;
  final PlaylistMediaMode mediaMode;
  final PlaylistQualityCap qualityCap;
  final PlaylistSizeStatus status;
  final int knownTotalBytes;
  final int totalEntriesCount;
  final int unavailableCount;
  final int eligibleCount;
  final int inspectedCount;
  final int exactCount;
  final int estimatedCount;
  final int unknownCount;
  final int failedCount;
  final String displaySummary;
  final String? statusMessage;
  final List<PlaylistItemSizeInfo> itemSizes;

  const PlaylistSizeEstimate({
    required this.estimationId,
    required this.playlistId,
    required this.mediaMode,
    required this.qualityCap,
    required this.status,
    required this.knownTotalBytes,
    required this.totalEntriesCount,
    required this.unavailableCount,
    required this.eligibleCount,
    required this.inspectedCount,
    required this.exactCount,
    required this.estimatedCount,
    required this.unknownCount,
    required this.failedCount,
    required this.displaySummary,
    this.statusMessage,
    required this.itemSizes,
  });

  @override
  List<Object?> get props => [
    estimationId,
    playlistId,
    mediaMode,
    qualityCap,
    status,
    knownTotalBytes,
    totalEntriesCount,
    unavailableCount,
    eligibleCount,
    inspectedCount,
    exactCount,
    estimatedCount,
    unknownCount,
    failedCount,
    displaySummary,
    statusMessage,
    itemSizes,
  ];
}

/// Request payload to calculate/recalculate expected playlist size for a mode & cap.
class EstimatePlaylistSizeRequest extends Equatable {
  final PlaylistInspection playlist;
  final PlaylistMediaMode mediaMode;
  final PlaylistQualityCap qualityCap;

  const EstimatePlaylistSizeRequest({
    required this.playlist,
    required this.mediaMode,
    required this.qualityCap,
  });

  @override
  List<Object?> get props => [playlist, mediaMode, qualityCap];
}

/// Concrete format selection resolved for one playlist item after applying the requested cap.
class ResolvedPlaylistSelection extends Equatable {
  final DownloadFormatSelection selection;
  final String qualityLabel;
  final String container;
  final AudioTrackMetadata? audioLanguage;
  final int? expectedSizeBytes;
  final FileSizeAccuracy sizeAccuracy;

  const ResolvedPlaylistSelection({
    required this.selection,
    required this.qualityLabel,
    required this.container,
    this.audioLanguage,
    this.expectedSizeBytes,
    required this.sizeAccuracy,
  });

  @override
  List<Object?> get props => [
    selection,
    qualityLabel,
    container,
    audioLanguage,
    expectedSizeBytes,
    sizeAccuracy,
  ];
}
