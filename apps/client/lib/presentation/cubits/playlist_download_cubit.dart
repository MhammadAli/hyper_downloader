import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/usecases/estimate_playlist_size_usecase.dart';
import 'package:hyper_download_client/domain/usecases/manage_playlist_download_usecase.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_state.dart';

/// Coordinates playlist mode/quality cap selection, progressive size estimation,
/// and sequential playlist batch downloads.
class PlaylistDownloadCubit extends Cubit<PlaylistDownloadState> {
  final ManagePlaylistDownloadUseCase _managePlaylistUseCase;
  final EstimatePlaylistSizeUseCase _estimateSizeUseCase;

  StreamSubscription<PlaylistProgressEvent>? _playlistProgressSubscription;
  StreamSubscription<PlaylistSizeEstimate>? _sizeEstimateSubscription;
  final List<PlaylistProgressEvent> _pendingPlaylistEvents = [];
  final Set<String> _canceledSizeEstimationIds = {};
  int _sizeEstimateRequestSeq = 0;

  PlaylistDownloadCubit({
    required this._managePlaylistUseCase,
    required this._estimateSizeUseCase,
  }) : super(const PlaylistDownloadState());

  void initialize() {
    _playlistProgressSubscription?.cancel();
    _playlistProgressSubscription = _managePlaylistUseCase
        .watchProgress()
        .listen(
          _onPlaylistProgressEvent,
          onError: (Object error) {
            emit(
              state.copyWith(
                playlistError: 'Playlist progress stream error: $error',
              ),
            );
          },
        );

    _sizeEstimateSubscription?.cancel();
    _sizeEstimateSubscription = _estimateSizeUseCase.watchEstimates().listen(
      _onPlaylistSizeEstimate,
      onError: (_) {
        // Non-fatal: size card handles unavailable/partial status cleanly.
      },
    );
  }

  Future<void> loadPlaylist(
    PlaylistInspection playlist, {
    PlaylistSessionSnapshot? savedSession,
  }) async {
    _pendingPlaylistEvents.clear();
    await _cancelActiveSizeEstimation(updateEstimateState: false);
    if (isClosed) return;

    emit(
      PlaylistDownloadState(
        playlistInspection: playlist,
        playlistSession: savedSession,
        playlistMediaMode:
            savedSession?.mediaMode ?? PlaylistMediaMode.videoWithSound,
        playlistQualityCap:
            savedSession?.qualityCap ?? PlaylistQualityCap.bestAvailable,
        playlistStatusMessage: savedSession != null
            ? 'Loaded previous session progress.'
            : null,
      ),
    );
    unawaited(estimatePlaylistSize());
  }

  Future<void> clear() async {
    _pendingPlaylistEvents.clear();
    await _cancelActiveSizeEstimation(updateEstimateState: false);
    if (isClosed) return;
    emit(const PlaylistDownloadState());
  }

  void setPlaylistMediaMode(PlaylistMediaMode mode) {
    if (state.isPlaylistRunning || mode == state.playlistMediaMode) return;
    emit(state.copyWith(playlistMediaMode: mode));
    if (state.hasPlaylist) {
      unawaited(estimatePlaylistSize());
    }
  }

  void setPlaylistQualityCap(PlaylistQualityCap cap) {
    if (state.isPlaylistRunning || cap == state.playlistQualityCap) return;
    emit(state.copyWith(playlistQualityCap: cap));
    if (state.hasPlaylist) {
      unawaited(estimatePlaylistSize());
    }
  }

  Future<void> estimatePlaylistSize() async {
    final playlist = state.playlistInspection;
    if (playlist == null) return;

    final seq = ++_sizeEstimateRequestSeq;
    final mode = state.playlistMediaMode;
    final cap = state.playlistQualityCap;
    emit(state.copyWith(activeSizeEstimationId: null));

    try {
      final result = await _estimateSizeUseCase.estimate(
        EstimatePlaylistSizeRequest(
          playlist: playlist,
          mediaMode: mode,
          qualityCap: cap,
        ),
      );
      if (isClosed || seq != _sizeEstimateRequestSeq) {
        if (result.status == PlaylistSizeStatus.calculating &&
            result.estimationId.isNotEmpty) {
          _canceledSizeEstimationIds.add(result.estimationId);
          unawaited(
            _estimateSizeUseCase
                .cancel(result.estimationId)
                .catchError((_) {}),
          );
        }
        return;
      }
      final existing = state.playlistSizeEstimate;
      if (existing != null &&
          existing.estimationId == result.estimationId &&
          existing.status != PlaylistSizeStatus.calculating &&
          result.status == PlaylistSizeStatus.calculating) {
        return;
      }
      emit(
        state.copyWith(
          playlistSizeEstimate: result,
          activeSizeEstimationId: result.estimationId,
        ),
      );
    } catch (err) {
      if (isClosed || seq != _sizeEstimateRequestSeq) return;
      final unavailableCount = playlist.entries
          .where((e) => e.availability != PlaylistEntryAvailability.available)
          .length;
      final eligibleCount = playlist.entries.length - unavailableCount;
      emit(
        state.copyWith(
          activeSizeEstimationId: null,
          playlistSizeEstimate: PlaylistSizeEstimate(
            estimationId: 'err-$seq',
            playlistId: playlist.id,
            mediaMode: mode,
            qualityCap: cap,
            status: PlaylistSizeStatus.failed,
            knownTotalBytes: 0,
            totalEntriesCount: playlist.entries.length,
            unavailableCount: unavailableCount,
            eligibleCount: eligibleCount,
            inspectedCount: 0,
            exactCount: 0,
            estimatedCount: 0,
            unknownCount: 0,
            failedCount: eligibleCount,
            displaySummary: 'Some video sizes could not be determined',
            statusMessage: err.toString().trim(),
            itemSizes: const [],
          ),
        ),
      );
    }
  }

  Future<void> cancelPlaylistSizeEstimation() =>
      _cancelActiveSizeEstimation();

  Future<void> _cancelActiveSizeEstimation({
    bool updateEstimateState = true,
  }) async {
    _sizeEstimateRequestSeq++;
    final current = state.playlistSizeEstimate;
    final activeId = current?.status == PlaylistSizeStatus.calculating
        ? current?.estimationId
        : state.activeSizeEstimationId;
    if (activeId != null && activeId.isNotEmpty) {
      _canceledSizeEstimationIds.add(activeId);
    }
    if (updateEstimateState &&
        current != null &&
        current.status == PlaylistSizeStatus.calculating) {
      emit(
        state.copyWith(
          activeSizeEstimationId: null,
          playlistSizeEstimate: _canceledSizeEstimateFrom(current),
        ),
      );
    } else if (state.activeSizeEstimationId != null) {
      emit(state.copyWith(activeSizeEstimationId: null));
    }
    if (activeId == null || activeId.isEmpty) return;
    try {
      await _estimateSizeUseCase.cancel(activeId);
    } catch (_) {
      // Best-effort cancellation.
    }
  }

  void _onPlaylistSizeEstimate(PlaylistSizeEstimate estimate) {
    if (_canceledSizeEstimationIds.contains(estimate.estimationId)) return;
    if (!state.hasPlaylist ||
        state.playlistInspection?.id != estimate.playlistId ||
        estimate.mediaMode != state.playlistMediaMode ||
        estimate.qualityCap != state.playlistQualityCap) {
      return;
    }
    final expectedId = state.activeSizeEstimationId;
    if (expectedId != null && expectedId != estimate.estimationId) return;

    emit(
      state.copyWith(
        playlistSizeEstimate: estimate,
        activeSizeEstimationId: estimate.estimationId,
      ),
    );
  }

  Future<void> startPlaylistDownload() async {
    final playlist = state.playlistInspection;
    if (!state.canStartPlaylist || playlist == null) return;

    await _cancelActiveSizeEstimation();
    _pendingPlaylistEvents.clear();
    emit(
      state.copyWith(
        isStartingPlaylist: true,
        playlistError: null,
        activePlaylistItemIndex: null,
        activePlaylistSpeedBytesPerSec: null,
        activePlaylistEtaSeconds: null,
        playlistStatusMessage: 'Starting playlist download...',
      ),
    );

    try {
      final snapshot = await _managePlaylistUseCase.start(
        StartPlaylistDownloadRequest(
          playlist: playlist,
          mediaMode: state.playlistMediaMode,
          qualityCap: state.playlistQualityCap,
        ),
      );
      if (isClosed) return;
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistSession: snapshot,
          playlistError: null,
        ),
      );
      _flushPendingPlaylistEvents();
    } catch (err) {
      _pendingPlaylistEvents.clear();
      if (isClosed) return;
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistError: err.toString().trim(),
        ),
      );
    }
  }

  Future<void> pausePlaylistDownload() async {
    final session = state.playlistSession;
    if (session == null || !state.canPausePlaylist) return;
    try {
      await _managePlaylistUseCase.pause(session.sessionId);
    } catch (err) {
      if (isClosed) return;
      emit(state.copyWith(playlistError: err.toString().trim()));
    }
  }

  Future<void> resumePlaylistDownload() async {
    final session = state.playlistSession;
    if (session == null || !state.canResumePlaylist) return;

    emit(
      state.copyWith(
        isStartingPlaylist: true,
        playlistError: null,
        playlistStatusMessage: 'Resuming playlist download...',
      ),
    );
    try {
      final resumed = await _managePlaylistUseCase.resume(session.sessionId);
      if (isClosed) return;
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistSession: resumed,
          playlistError: null,
        ),
      );
      _flushPendingPlaylistEvents();
    } catch (err) {
      if (isClosed) return;
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistError: err.toString().trim(),
        ),
      );
    }
  }

  Future<void> cancelPlaylistDownload() async {
    final session = state.playlistSession;
    if (session == null || !state.canCancelPlaylist) return;
    try {
      await _managePlaylistUseCase.cancel(session.sessionId);
    } catch (err) {
      if (isClosed) return;
      emit(state.copyWith(playlistError: err.toString().trim()));
    }
  }

  Future<void> retryFailedPlaylistItems() async {
    final session = state.playlistSession;
    if (session == null || !state.canRetryFailedPlaylist) return;

    emit(
      state.copyWith(
        isStartingPlaylist: true,
        playlistError: null,
        playlistStatusMessage: 'Retrying failed items...',
      ),
    );
    try {
      final retried = await _managePlaylistUseCase.retryFailed(
        session.sessionId,
      );
      if (isClosed) return;
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistSession: retried,
          playlistError: null,
        ),
      );
      _flushPendingPlaylistEvents();
    } catch (err) {
      if (isClosed) return;
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistError: err.toString().trim(),
        ),
      );
    }
  }

  void _flushPendingPlaylistEvents() {
    if (_pendingPlaylistEvents.isEmpty) return;
    final queued = List<PlaylistProgressEvent>.from(_pendingPlaylistEvents);
    _pendingPlaylistEvents.clear();
    for (final event in queued) {
      _applyPlaylistProgressEvent(event);
    }
  }

  void _onPlaylistProgressEvent(PlaylistProgressEvent event) {
    if (state.playlistSession == null) {
      if (state.isStartingPlaylist) {
        _pendingPlaylistEvents.add(event);
      }
      return;
    }
    _applyPlaylistProgressEvent(event);
  }

  void _applyPlaylistProgressEvent(PlaylistProgressEvent event) {
    final currentSession = state.playlistSession;
    if (currentSession == null ||
        currentSession.sessionId != event.sessionId) {
      return;
    }

    final updatedItems = currentSession.items
        .map((item) {
          if (event.itemIndex == null || item.orderIndex != event.itemIndex) {
            return item;
          }

          final nextStatus = switch (event.kind) {
            PlaylistEventKind.playlistItemStarted =>
              event.itemStatus ?? PlaylistItemStatus.analyzing,
            PlaylistEventKind.playlistItemProgress =>
              event.itemStatus ?? PlaylistItemStatus.downloading,
            PlaylistEventKind.playlistItemMerging =>
              event.itemStatus ?? PlaylistItemStatus.merging,
            PlaylistEventKind.playlistItemCompleted =>
              PlaylistItemStatus.completed,
            PlaylistEventKind.playlistItemFailed => PlaylistItemStatus.failed,
            PlaylistEventKind.playlistItemSkipped => PlaylistItemStatus.skipped,
            PlaylistEventKind.playlistPaused ||
            PlaylistEventKind.playlistCanceled =>
              event.itemStatus ?? PlaylistItemStatus.canceled,
            PlaylistEventKind.playlistStarted ||
            PlaylistEventKind.playlistCompleted =>
              event.itemStatus ?? item.status,
          };

          final clearError =
              nextStatus == PlaylistItemStatus.analyzing ||
              nextStatus == PlaylistItemStatus.downloading ||
              nextStatus == PlaylistItemStatus.merging ||
              nextStatus == PlaylistItemStatus.completed;

          final nextDownloaded = event.itemDownloadedBytes > 0
              ? event.itemDownloadedBytes
              : (nextStatus == PlaylistItemStatus.completed &&
                    event.itemTotalBytes != null)
              ? event.itemTotalBytes!
              : item.downloadedBytes;

          return PlaylistItemState(
            orderIndex: item.orderIndex,
            videoId: item.videoId,
            title: item.title,
            url: item.url,
            durationSeconds: item.durationSeconds,
            thumbnailUrl: item.thumbnailUrl,
            status: nextStatus,
            selectedQuality: event.selectedQuality ?? item.selectedQuality,
            audioLanguage: event.audioLanguage ?? item.audioLanguage,
            downloadedBytes: nextDownloaded,
            totalBytes: event.itemTotalBytes ?? item.totalBytes,
            isTotalEstimated: event.itemIsTotalEstimated,
            outputPath: event.outputPath ?? item.outputPath,
            errorMessage: clearError
                ? null
                : (event.message ?? item.errorMessage),
          );
        })
        .toList(growable: false);

    final (bool nextIsRunning, bool nextIsPaused) = switch (event.kind) {
      PlaylistEventKind.playlistPaused => (false, true),
      PlaylistEventKind.playlistCanceled ||
      PlaylistEventKind.playlistCompleted => (false, false),
      PlaylistEventKind.playlistStarted ||
      PlaylistEventKind.playlistItemStarted ||
      PlaylistEventKind.playlistItemProgress ||
      PlaylistEventKind.playlistItemMerging ||
      PlaylistEventKind.playlistItemCompleted ||
      PlaylistEventKind.playlistItemFailed ||
      PlaylistEventKind.playlistItemSkipped => (true, false),
    };

    final updatedSnapshot = PlaylistSessionSnapshot(
      sessionId: currentSession.sessionId,
      playlistId: currentSession.playlistId,
      playlistTitle: currentSession.playlistTitle,
      playlistUrl: currentSession.playlistUrl,
      uploader: currentSession.uploader,
      thumbnailUrl: currentSession.thumbnailUrl,
      outputDirectory:
          event.playlistOutputDir ?? currentSession.outputDirectory,
      mediaMode: currentSession.mediaMode,
      qualityCap: currentSession.qualityCap,
      isRunning: nextIsRunning,
      isPaused: nextIsPaused,
      completedCount: event.completedCount,
      failedCount: event.failedCount,
      skippedCount: event.skippedCount,
      totalCount: event.totalCount > 0
          ? event.totalCount
          : currentSession.totalCount,
      items: updatedItems,
    );

    final (int? nextIdx, double? nextSpeed, int? nextEta) = switch (event.kind) {
      PlaylistEventKind.playlistItemProgress => (
        event.itemIndex,
        event.speedBytesPerSec,
        event.etaSeconds,
      ),
      PlaylistEventKind.playlistItemStarted ||
      PlaylistEventKind.playlistItemMerging ||
      PlaylistEventKind.playlistItemCompleted ||
      PlaylistEventKind.playlistItemFailed ||
      PlaylistEventKind.playlistItemSkipped => (event.itemIndex, null, null),
      PlaylistEventKind.playlistPaused ||
      PlaylistEventKind.playlistCanceled ||
      PlaylistEventKind.playlistCompleted => (null, null, null),
      PlaylistEventKind.playlistStarted => (
        state.activePlaylistItemIndex,
        state.activePlaylistSpeedBytesPerSec,
        state.activePlaylistEtaSeconds,
      ),
    };

    emit(
      state.copyWith(
        playlistSession: updatedSnapshot,
        isStartingPlaylist: false,
        activePlaylistItemIndex: nextIdx,
        activePlaylistSpeedBytesPerSec: nextSpeed,
        activePlaylistEtaSeconds: nextEta,
        playlistStatusMessage: event.message ?? state.playlistStatusMessage,
      ),
    );
  }

  static PlaylistSizeEstimate _canceledSizeEstimateFrom(
    PlaylistSizeEstimate current,
  ) {
    final summary = current.knownTotalBytes > 0
        ? 'At least ${ByteFormatter.formatBytesHuman(current.knownTotalBytes)} · canceled'
        : 'Size calculation canceled';
    return PlaylistSizeEstimate(
      estimationId: current.estimationId,
      playlistId: current.playlistId,
      mediaMode: current.mediaMode,
      qualityCap: current.qualityCap,
      status: PlaylistSizeStatus.canceled,
      knownTotalBytes: current.knownTotalBytes,
      totalEntriesCount: current.totalEntriesCount,
      unavailableCount: current.unavailableCount,
      eligibleCount: current.eligibleCount,
      inspectedCount: current.inspectedCount,
      exactCount: current.exactCount,
      estimatedCount: current.estimatedCount,
      unknownCount: current.unknownCount,
      failedCount: current.failedCount,
      displaySummary: summary,
      statusMessage:
          'Canceled after inspecting ${current.inspectedCount} of ${current.eligibleCount} videos.',
      itemSizes: current.itemSizes,
    );
  }

  @override
  Future<void> close() async {
    await _playlistProgressSubscription?.cancel();
    await _sizeEstimateSubscription?.cancel();
    return super.close();
  }
}
