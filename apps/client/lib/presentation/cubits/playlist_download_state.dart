import 'package:equatable/equatable.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

const Object _unset = Object();

class PlaylistDownloadState extends Equatable {
  final PlaylistInspection? playlistInspection;
  final PlaylistSessionSnapshot? playlistSession;
  final PlaylistMediaMode playlistMediaMode;
  final PlaylistQualityCap playlistQualityCap;
  final bool isStartingPlaylist;
  final String? playlistError;
  final int? activePlaylistItemIndex;
  final double? activePlaylistSpeedBytesPerSec;
  final int? activePlaylistEtaSeconds;
  final String? playlistStatusMessage;
  final PlaylistSizeEstimate? playlistSizeEstimate;
  final String? activeSizeEstimationId;

  const PlaylistDownloadState({
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

  bool get hasPlaylist => playlistInspection != null;

  bool get isPlaylistRunning =>
      isStartingPlaylist || (playlistSession?.isRunning ?? false);

  bool get isPlaylistPaused => playlistSession?.isPaused ?? false;

  bool get canStartPlaylist => hasPlaylist && !isPlaylistRunning;

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

  PlaylistDownloadState copyWith({
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
    return PlaylistDownloadState(
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
          : activePlaylistEtaSeconds as int?,
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
    playlistInspection,
    playlistSession,
    playlistMediaMode,
    playlistQualityCap,
    isStartingPlaylist,
    playlistError,
    activePlaylistItemIndex,
    activePlaylistSpeedBytesPerSec,
    activePlaylistEtaSeconds,
    playlistStatusMessage,
    playlistSizeEstimate,
    activeSizeEstimationId,
  ];
}
