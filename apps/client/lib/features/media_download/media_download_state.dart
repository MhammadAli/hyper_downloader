import 'package:equatable/equatable.dart';
import 'package:hyper_download_client/core/bridge/models.dart';

/// Simplified IDM-style download modes shown in the UI.
enum DownloadMediaMode { videoWithSound, audioOnly }

/// URL inspection lifecycle status.
enum InspectionStatus { initial, loading, loaded, failure }

const Object _unset = Object();

/// Immutable UI and engine state for IDM-style media & playlist inspection and downloading.
class MediaDownloadState extends Equatable {
  final bool isEngineReady;
  final String? engineError;
  final String urlInput;
  final InspectionStatus inspectionStatus;
  final InspectionTargetKind? targetKind;
  final MediaInspection? inspection;
  final String? inspectionError;
  final DownloadMediaMode mediaMode;
  final String? selectedVideoFormatId;
  final String? selectedAudioOptionFormatId;
  final String? activeJobId;
  final bool isStartingDownload;
  final bool isPaused;
  final DownloadProgressEvent? latestProgress;
  final String? downloadError;

  // Playlist state fields.
  final PlaylistInspection? playlistInspection;
  final PlaylistSessionSnapshot? playlistSession;
  final PlaylistMediaMode playlistMediaMode;
  final PlaylistQualityCap playlistQualityCap;
  final bool isStartingPlaylist;
  final String? playlistError;
  final int? activePlaylistItemIndex;
  final double? activePlaylistSpeedBytesPerSec;
  final BigInt? activePlaylistEtaSeconds;
  final String? playlistStatusMessage;
  final PlaylistSizeEstimate? playlistSizeEstimate;
  final String? activeSizeEstimationId;

  const MediaDownloadState({
    this.isEngineReady = false,
    this.engineError,
    this.urlInput = '',
    this.inspectionStatus = InspectionStatus.initial,
    this.targetKind,
    this.inspection,
    this.inspectionError,
    this.mediaMode = DownloadMediaMode.videoWithSound,
    this.selectedVideoFormatId,
    this.selectedAudioOptionFormatId,
    this.activeJobId,
    this.isStartingDownload = false,
    this.isPaused = false,
    this.latestProgress,
    this.downloadError,
    this.playlistInspection,
    this.playlistSession,
    this.playlistMediaMode = PlaylistMediaMode.videoWithSound,
    this.playlistQualityCap = PlaylistQualityCap.bestAvailable,
    this.isStartingPlaylist = false,
    this.playlistError,
    this.activePlaylistItemIndex,
    this.activePlaylistSpeedBytesPerSec,
    this.activePlaylistEtaSeconds,
    this.playlistStatusMessage,
    this.playlistSizeEstimate,
    this.activeSizeEstimationId,
  });

  bool get isSingleVideoTarget =>
      targetKind == InspectionTargetKind.singleVideo ||
      (targetKind == null && inspection != null);

  bool get isPlaylistTarget =>
      targetKind == InspectionTargetKind.playlist && playlistInspection != null;

  bool get isPlaylistRunning =>
      isStartingPlaylist || (playlistSession?.isRunning ?? false);

  bool get isPlaylistPaused => playlistSession?.isPaused ?? false;

  bool get canStartPlaylist => isPlaylistTarget && !isPlaylistRunning;

  bool get canPausePlaylist =>
      playlistSession != null &&
      playlistSession!.isRunning &&
      !playlistSession!.isPaused;

  bool get canResumePlaylist =>
      playlistSession != null &&
      !isStartingPlaylist &&
      (playlistSession!.isPaused ||
          (!playlistSession!.isRunning &&
              playlistSession!.items.any(
                (i) =>
                    i.status == PlaylistItemStatus.pending ||
                    i.status == PlaylistItemStatus.canceled,
              )));

  bool get canCancelPlaylist =>
      playlistSession != null &&
      (playlistSession!.isRunning || playlistSession!.isPaused);

  bool get canRetryFailedPlaylist =>
      playlistSession != null &&
      !isPlaylistRunning &&
      playlistSession!.failedCount > 0;

  bool get isCalculatingPlaylistSize =>
      playlistSizeEstimate?.status == PlaylistSizeStatus.calculating;

  bool get canCancelPlaylistSize =>
      isCalculatingPlaylistSize &&
      (playlistSizeEstimate?.estimationId.isNotEmpty ?? false);

  PlaylistItemSizeInfo? sizeInfoForItem(int orderIndex) {
    final items = playlistSizeEstimate?.itemSizes;
    if (items == null) return null;
    for (final info in items) {
      if (info.orderIndex == orderIndex) return info;
    }
    return null;
  }

  PlaylistItemState? get activePlaylistItem {
    final session = playlistSession;
    if (session == null) return null;
    final idx = activePlaylistItemIndex;
    if (idx != null) {
      for (final item in session.items) {
        if (item.orderIndex == idx) return item;
      }
    }
    for (final item in session.items) {
      if (item.status == PlaylistItemStatus.analyzing ||
          item.status == PlaylistItemStatus.downloading ||
          item.status == PlaylistItemStatus.merging) {
        return item;
      }
    }
    return null;
  }

  List<VideoQualityOption> get videoOptions =>
      inspection?.videoOptions ?? const [];

  List<AudioQualityOption> get audioOptions =>
      inspection?.audioOptions ?? const [];

  AudioTrackMetadata? get originalAudio => inspection?.originalAudio;

  VideoQualityOption? get selectedVideoOption {
    final key = selectedVideoFormatId;
    if (key == null) return null;
    for (final option in videoOptions) {
      if (option.videoFormatId == key) return option;
    }
    return null;
  }

  AudioQualityOption? get selectedAudioOption {
    final key = selectedAudioOptionFormatId;
    if (key == null) return null;
    for (final option in audioOptions) {
      if (option.formatId == key) return option;
    }
    return null;
  }

  DownloadPhase? get currentPhase => latestProgress?.phase;

  bool get isDownloadActive {
    if (isStartingDownload) return true;
    final phase = currentPhase;
    return phase == DownloadPhase.analyzing ||
        phase == DownloadPhase.downloading ||
        phase == DownloadPhase.merging;
  }

  bool get canStartDownload {
    if (isDownloadActive || inspection == null) return false;
    return switch (mediaMode) {
      DownloadMediaMode.videoWithSound => selectedVideoOption != null,
      DownloadMediaMode.audioOnly => selectedAudioOption != null,
    };
  }

  bool get canPause {
    if (activeJobId == null) return false;
    final phase = currentPhase;
    return isStartingDownload ||
        phase == DownloadPhase.analyzing ||
        phase == DownloadPhase.downloading;
  }

  bool get canCancel {
    if (activeJobId == null) return false;
    final phase = currentPhase;
    return isStartingDownload ||
        phase == DownloadPhase.analyzing ||
        phase == DownloadPhase.downloading ||
        phase == DownloadPhase.merging;
  }

  bool get canResume {
    if (activeJobId == null || isStartingDownload) return false;
    final phase = currentPhase;
    return isPaused ||
        phase == DownloadPhase.canceled ||
        phase == DownloadPhase.failed;
  }

  MediaDownloadState copyWith({
    bool? isEngineReady,
    Object? engineError = _unset,
    String? urlInput,
    InspectionStatus? inspectionStatus,
    Object? targetKind = _unset,
    Object? inspection = _unset,
    Object? inspectionError = _unset,
    DownloadMediaMode? mediaMode,
    Object? selectedVideoFormatId = _unset,
    Object? selectedAudioOptionFormatId = _unset,
    Object? activeJobId = _unset,
    bool? isStartingDownload,
    bool? isPaused,
    Object? latestProgress = _unset,
    Object? downloadError = _unset,
    Object? playlistInspection = _unset,
    Object? playlistSession = _unset,
    PlaylistMediaMode? playlistMediaMode,
    PlaylistQualityCap? playlistQualityCap,
    bool? isStartingPlaylist,
    Object? playlistError = _unset,
    Object? activePlaylistItemIndex = _unset,
    Object? activePlaylistSpeedBytesPerSec = _unset,
    Object? activePlaylistEtaSeconds = _unset,
    Object? playlistStatusMessage = _unset,
    Object? playlistSizeEstimate = _unset,
    Object? activeSizeEstimationId = _unset,
  }) {
    return MediaDownloadState(
      isEngineReady: isEngineReady ?? this.isEngineReady,
      engineError: identical(engineError, _unset)
          ? this.engineError
          : engineError as String?,
      urlInput: urlInput ?? this.urlInput,
      inspectionStatus: inspectionStatus ?? this.inspectionStatus,
      targetKind: identical(targetKind, _unset)
          ? this.targetKind
          : targetKind as InspectionTargetKind?,
      inspection: identical(inspection, _unset)
          ? this.inspection
          : inspection as MediaInspection?,
      inspectionError: identical(inspectionError, _unset)
          ? this.inspectionError
          : inspectionError as String?,
      mediaMode: mediaMode ?? this.mediaMode,
      selectedVideoFormatId: identical(selectedVideoFormatId, _unset)
          ? this.selectedVideoFormatId
          : selectedVideoFormatId as String?,
      selectedAudioOptionFormatId:
          identical(selectedAudioOptionFormatId, _unset)
          ? this.selectedAudioOptionFormatId
          : selectedAudioOptionFormatId as String?,
      activeJobId: identical(activeJobId, _unset)
          ? this.activeJobId
          : activeJobId as String?,
      isStartingDownload: isStartingDownload ?? this.isStartingDownload,
      isPaused: isPaused ?? this.isPaused,
      latestProgress: identical(latestProgress, _unset)
          ? this.latestProgress
          : latestProgress as DownloadProgressEvent?,
      downloadError: identical(downloadError, _unset)
          ? this.downloadError
          : downloadError as String?,
      playlistInspection: identical(playlistInspection, _unset)
          ? this.playlistInspection
          : playlistInspection as PlaylistInspection?,
      playlistSession: identical(playlistSession, _unset)
          ? this.playlistSession
          : playlistSession as PlaylistSessionSnapshot?,
      playlistMediaMode: playlistMediaMode ?? this.playlistMediaMode,
      playlistQualityCap: playlistQualityCap ?? this.playlistQualityCap,
      isStartingPlaylist: isStartingPlaylist ?? this.isStartingPlaylist,
      playlistError: identical(playlistError, _unset)
          ? this.playlistError
          : playlistError as String?,
      activePlaylistItemIndex: identical(activePlaylistItemIndex, _unset)
          ? this.activePlaylistItemIndex
          : activePlaylistItemIndex as int?,
      activePlaylistSpeedBytesPerSec:
          identical(activePlaylistSpeedBytesPerSec, _unset)
          ? this.activePlaylistSpeedBytesPerSec
          : activePlaylistSpeedBytesPerSec as double?,
      activePlaylistEtaSeconds: identical(activePlaylistEtaSeconds, _unset)
          ? this.activePlaylistEtaSeconds
          : activePlaylistEtaSeconds as BigInt?,
      playlistStatusMessage: identical(playlistStatusMessage, _unset)
          ? this.playlistStatusMessage
          : playlistStatusMessage as String?,
      playlistSizeEstimate: identical(playlistSizeEstimate, _unset)
          ? this.playlistSizeEstimate
          : playlistSizeEstimate as PlaylistSizeEstimate?,
      activeSizeEstimationId: identical(activeSizeEstimationId, _unset)
          ? this.activeSizeEstimationId
          : activeSizeEstimationId as String?,
    );
  }

  @override
  List<Object?> get props => [
    isEngineReady,
    engineError,
    urlInput,
    inspectionStatus,
    targetKind,
    inspection?.id,
    inspection?.title,
    inspection?.uploader,
    inspection?.durationSeconds,
    inspection?.thumbnailUrl,
    inspection?.webpageUrl,
    inspection?.providerName,
    inspection?.originalAudio,
    inspection?.videoOptions,
    inspection?.audioOptions,
    inspection?.formats,
    inspectionError,
    mediaMode,
    selectedVideoFormatId,
    selectedAudioOptionFormatId,
    activeJobId,
    isStartingDownload,
    isPaused,
    latestProgress,
    downloadError,
    playlistInspection?.id,
    playlistInspection?.title,
    playlistInspection?.uploader,
    playlistInspection?.thumbnailUrl,
    playlistInspection?.webpageUrl,
    playlistInspection?.providerName,
    playlistInspection?.totalItemCount,
    playlistInspection?.entries,
    playlistSession?.sessionId,
    playlistSession?.playlistId,
    playlistSession?.playlistTitle,
    playlistSession?.playlistUrl,
    playlistSession?.uploader,
    playlistSession?.thumbnailUrl,
    playlistSession?.outputDirectory,
    playlistSession?.mediaMode,
    playlistSession?.qualityCap,
    playlistSession?.isRunning,
    playlistSession?.isPaused,
    playlistSession?.completedCount,
    playlistSession?.failedCount,
    playlistSession?.skippedCount,
    playlistSession?.totalCount,
    playlistSession?.items,
    playlistMediaMode,
    playlistQualityCap,
    isStartingPlaylist,
    playlistError,
    activePlaylistItemIndex,
    activePlaylistSpeedBytesPerSec,
    activePlaylistEtaSeconds,
    playlistStatusMessage,
    playlistSizeEstimate?.estimationId,
    playlistSizeEstimate?.playlistId,
    playlistSizeEstimate?.mediaMode,
    playlistSizeEstimate?.qualityCap,
    playlistSizeEstimate?.status,
    playlistSizeEstimate?.knownTotalBytes,
    playlistSizeEstimate?.totalEntriesCount,
    playlistSizeEstimate?.unavailableCount,
    playlistSizeEstimate?.eligibleCount,
    playlistSizeEstimate?.inspectedCount,
    playlistSizeEstimate?.exactCount,
    playlistSizeEstimate?.estimatedCount,
    playlistSizeEstimate?.unknownCount,
    playlistSizeEstimate?.failedCount,
    playlistSizeEstimate?.displaySummary,
    playlistSizeEstimate?.statusMessage,
    playlistSizeEstimate?.itemSizes,
    activeSizeEstimationId,
  ];
}
