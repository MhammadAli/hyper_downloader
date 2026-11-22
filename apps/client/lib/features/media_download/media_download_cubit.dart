import 'dart:async';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/features/media_download/media_download_state.dart';

/// Coordinates URL analysis, simplified quality selection, single-job & playlist downloads.
class MediaDownloadCubit extends Cubit<MediaDownloadState> {
  final MediaDownloadRepository _repository;
  final Future<String?> Function()? getInitialSharedUrl;
  final Stream<String>? sharedUrls;
  final bool allowInstagramReels;
  StreamSubscription<DownloadProgressEvent>? _progressSubscription;
  StreamSubscription<PlaylistProgressEvent>? _playlistProgressSubscription;
  StreamSubscription<PlaylistSizeEstimate>? _sizeEstimateSubscription;
  StreamSubscription<String>? _sharedUrlSubscription;
  final List<PlaylistProgressEvent> _pendingPlaylistEvents = [];
  int _sizeEstimateRequestSeq = 0;
  int _inspectionRequestSeq = 0;
  bool _pauseRequested = false;

  MediaDownloadCubit({
    required this._repository,
    this.getInitialSharedUrl,
    this.sharedUrls,
    bool? allowInstagramReels,
  }) : allowInstagramReels = allowInstagramReels ?? !Platform.isAndroid,
       super(const MediaDownloadState());

  /// Returns `true` when [rawUrl] points to an `instagram.com` host.
  static bool isInstagramUrl(String rawUrl) {
    final host = Uri.tryParse(rawUrl.trim())?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    final clean = host.endsWith('.')
        ? host.substring(0, host.length - 1)
        : host;
    return clean == 'instagram.com' || clean.endsWith('.instagram.com');
  }

  /// Checks Rust FFI connectivity and subscribes to live progress events.
  void initialize() {
    try {
      final pong = _repository.ping();
      final version = _repository.engineVersion();
      if (pong == 'pong' && version.isNotEmpty) {
        emit(state.copyWith(isEngineReady: true, engineError: null));
      } else {
        emit(
          state.copyWith(
            isEngineReady: false,
            engineError: 'Unexpected download engine response: $pong',
          ),
        );
      }
    } catch (err) {
      emit(
        state.copyWith(
          isEngineReady: false,
          engineError:
              'Download engine unavailable: ${_cleanErrorMessage(err)}',
        ),
      );
    }

    _progressSubscription?.cancel();
    _progressSubscription = _repository.watchDownloadProgress().listen(
      _onProgressEvent,
      onError: (Object error) {
        emit(state.copyWith(downloadError: 'Progress stream error: $error'));
      },
    );

    _playlistProgressSubscription?.cancel();
    _playlistProgressSubscription = _repository.watchPlaylistProgress().listen(
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
    _sizeEstimateSubscription = _repository.watchPlaylistSizeEstimate().listen(
      _onPlaylistSizeEstimate,
      onError: (_) {
        // Non-fatal: size summary card displays partial or unavailable status cleanly.
      },
    );

    _sharedUrlSubscription?.cancel();
    final sharedStream = sharedUrls;
    if (sharedStream != null) {
      _sharedUrlSubscription = sharedStream.listen(_handleIncomingSharedUrl);
    }
    final initialFetcher = getInitialSharedUrl;
    if (initialFetcher != null) {
      unawaited(_consumeInitialSharedUrl(initialFetcher));
    }
  }

  Future<void> _consumeInitialSharedUrl(
    Future<String?> Function() fetcher,
  ) async {
    try {
      final url = await fetcher();
      _handleIncomingSharedUrl(url);
    } catch (_) {
      // Ignore startup shared-intent read failures so manual paste still works.
    }
  }

  void _handleIncomingSharedUrl(String? rawUrl) {
    final cleaned = rawUrl?.trim() ?? '';
    if (cleaned.isEmpty) {
      return;
    }
    unawaited(analyzeUrl(cleaned));
  }

  void updateUrl(String url) {
    emit(state.copyWith(urlInput: url));
  }

  Future<void> analyzeUrl([String? overrideUrl]) async {
    final targetUrl = (overrideUrl ?? state.urlInput).trim();
    if (overrideUrl != null) {
      emit(state.copyWith(urlInput: overrideUrl));
    }

    if (targetUrl.isEmpty) {
      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.failure,
          inspectionError: 'Please paste or enter a media URL to analyze.',
        ),
      );
      return;
    }

    if (!allowInstagramReels && isInstagramUrl(targetUrl)) {
      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.failure,
          inspectionError:
              'Instagram Reels downloads are currently supported on Windows only.',
        ),
      );
      return;
    }

    final seq = ++_inspectionRequestSeq;
    emit(
      state.copyWith(
        urlInput: targetUrl,
        inspectionStatus: InspectionStatus.loading,
        inspectionError: null,
        downloadError: null,
        playlistError: null,
      ),
    );

    try {
      final inspected = await _repository.inspectUrl(targetUrl);
      if (isClosed || seq != _inspectionRequestSeq) {
        return;
      }
      if (inspected.kind == InspectionTargetKind.playlist &&
          inspected.playlist != null) {
        final playlist = inspected.playlist!;
        PlaylistSessionSnapshot? savedSession;
        try {
          savedSession = await _repository.loadSavedPlaylistSession(
            playlistId: playlist.id,
          );
        } catch (_) {
          // Saved manifest loading is best-effort only.
        }
        if (isClosed || seq != _inspectionRequestSeq) {
          return;
        }
        _pendingPlaylistEvents.clear();
        await _cancelActiveSizeEstimation();
        if (isClosed || seq != _inspectionRequestSeq) {
          return;
        }
        emit(
          state.copyWith(
            inspectionStatus: InspectionStatus.loaded,
            targetKind: InspectionTargetKind.playlist,
            inspection: null,
            inspectionError: null,
            selectedVideoFormatId: null,
            selectedAudioOptionFormatId: null,
            activeJobId: null,
            isStartingDownload: false,
            isPaused: false,
            latestProgress: null,
            downloadError: null,
            playlistInspection: playlist,
            playlistSession: savedSession,
            playlistMediaMode:
                savedSession?.mediaMode ?? PlaylistMediaMode.videoWithSound,
            playlistQualityCap:
                savedSession?.qualityCap ?? PlaylistQualityCap.bestAvailable,
            isStartingPlaylist: false,
            playlistError: null,
            activePlaylistItemIndex: null,
            activePlaylistSpeedBytesPerSec: null,
            activePlaylistEtaSeconds: null,
            playlistStatusMessage: savedSession != null
                ? 'Loaded previous session progress.'
                : null,
            playlistSizeEstimate: null,
            activeSizeEstimationId: null,
          ),
        );
        unawaited(estimatePlaylistSize());
        return;
      }

      final video = inspected.video;
      if (video == null) {
        emit(
          state.copyWith(
            inspectionStatus: InspectionStatus.failure,
            inspectionError: 'No inspectable video or playlist was returned.',
          ),
        );
        return;
      }

      await _cancelActiveSizeEstimation();
      if (isClosed || seq != _inspectionRequestSeq) {
        return;
      }
      final defaultVideoId = video.videoOptions.isNotEmpty
          ? video.videoOptions.first.videoFormatId
          : null;
      final defaultAudioId = video.audioOptions.isNotEmpty
          ? video.audioOptions.first.formatId
          : null;

      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.loaded,
          targetKind: InspectionTargetKind.singleVideo,
          inspection: video,
          inspectionError: null,
          mediaMode: DownloadMediaMode.videoWithSound,
          selectedVideoFormatId: defaultVideoId,
          selectedAudioOptionFormatId: defaultAudioId,
          activeJobId: null,
          isStartingDownload: false,
          isPaused: false,
          latestProgress: null,
          downloadError: null,
          playlistInspection: null,
          playlistSession: null,
          isStartingPlaylist: false,
          playlistError: null,
          activePlaylistItemIndex: null,
          activePlaylistSpeedBytesPerSec: null,
          activePlaylistEtaSeconds: null,
          playlistStatusMessage: null,
          playlistSizeEstimate: null,
          activeSizeEstimationId: null,
        ),
      );
    } catch (err) {
      if (isClosed || seq != _inspectionRequestSeq) {
        return;
      }
      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.failure,
          inspectionError: _cleanErrorMessage(err),
        ),
      );
    }
  }

  void cancelAnalysis() {
    if (state.inspectionStatus != InspectionStatus.loading) {
      return;
    }
    _inspectionRequestSeq++;
    emit(
      state.copyWith(
        inspectionStatus:
            (state.inspection != null || state.playlistInspection != null)
            ? InspectionStatus.loaded
            : InspectionStatus.initial,
        inspectionError: null,
      ),
    );
  }

  void setMediaMode(DownloadMediaMode mode) {
    if (mode == DownloadMediaMode.audioOnly && state.audioOptions.isEmpty) {
      return;
    }
    emit(state.copyWith(mediaMode: mode));
  }

  void selectVideoQuality(String videoFormatId) {
    emit(state.copyWith(selectedVideoFormatId: videoFormatId));
  }

  void selectAudioQuality(String formatId) {
    emit(state.copyWith(selectedAudioOptionFormatId: formatId));
  }

  Future<void> startDownload() async {
    final inspection = state.inspection;
    if (!state.canStartDownload || inspection == null) {
      return;
    }

    final DownloadFormatSelection selection;
    if (state.mediaMode == DownloadMediaMode.videoWithSound) {
      final chosen = state.selectedVideoOption!;
      if (chosen.formatSelectionStrategy ==
          FormatSelectionStrategy.combinedAudioVideo) {
        selection = DownloadFormatSelection(
          kind: DownloadSelectionKind.single,
          formatId: chosen.videoFormatId,
        );
      } else {
        selection = DownloadFormatSelection(
          kind: DownloadSelectionKind.videoAndAudio,
          videoFormatId: chosen.videoFormatId,
          audioFormatId: chosen.selectedAudioFormatId,
          mergeContainer: chosen.container,
        );
      }
    } else {
      final chosenAudio = state.selectedAudioOption!;
      selection = DownloadFormatSelection(
        kind: DownloadSelectionKind.single,
        formatId: chosenAudio.formatId,
      );
    }

    final targetUrl = inspection.webpageUrl.isNotEmpty
        ? inspection.webpageUrl
        : state.urlInput.trim();

    final request = StartDownloadRequest(
      url: targetUrl,
      title: inspection.title,
      selection: selection,
    );

    _pauseRequested = false;
    emit(
      state.copyWith(
        isStartingDownload: true,
        isPaused: false,
        activeJobId: null,
        latestProgress: null,
        downloadError: null,
      ),
    );

    try {
      final jobId = await _repository.startDownload(request);
      emit(state.copyWith(activeJobId: jobId, isStartingDownload: false));
    } catch (err) {
      emit(
        state.copyWith(
          isStartingDownload: false,
          downloadError: _cleanErrorMessage(err),
        ),
      );
    }
  }

  Future<void> pauseDownload() async {
    final jobId = state.activeJobId;
    if (jobId == null || !state.canPause) return;

    _pauseRequested = true;
    try {
      await _repository.cancelDownload(jobId);
    } catch (err) {
      _pauseRequested = false;
      emit(state.copyWith(downloadError: _cleanErrorMessage(err)));
    }
  }

  Future<void> cancelDownload() async {
    final jobId = state.activeJobId;
    if (jobId == null || !state.canCancel) return;

    _pauseRequested = false;
    try {
      await _repository.cancelDownload(jobId);
    } catch (err) {
      emit(state.copyWith(downloadError: _cleanErrorMessage(err)));
    }
  }

  Future<void> resumeDownload() async {
    final jobId = state.activeJobId;
    if (jobId == null || !state.canResume) return;

    _pauseRequested = false;
    emit(
      state.copyWith(
        isStartingDownload: true,
        isPaused: false,
        downloadError: null,
      ),
    );
    try {
      final resumedJobId = await _repository.resumeDownload(jobId);
      emit(
        state.copyWith(activeJobId: resumedJobId, isStartingDownload: false),
      );
    } catch (err) {
      emit(
        state.copyWith(
          isStartingDownload: false,
          downloadError: _cleanErrorMessage(err),
        ),
      );
    }
  }

  void setPlaylistMediaMode(PlaylistMediaMode mode) {
    if (state.isPlaylistRunning) return;
    if (mode == state.playlistMediaMode) return;
    emit(state.copyWith(playlistMediaMode: mode));
    if (state.isPlaylistTarget) {
      unawaited(estimatePlaylistSize());
    }
  }

  void setPlaylistQualityCap(PlaylistQualityCap cap) {
    if (state.isPlaylistRunning) return;
    if (cap == state.playlistQualityCap) return;
    emit(state.copyWith(playlistQualityCap: cap));
    if (state.isPlaylistTarget) {
      unawaited(estimatePlaylistSize());
    }
  }

  Future<void> estimatePlaylistSize() async {
    final playlist = state.playlistInspection;
    if (!state.isPlaylistTarget || playlist == null) return;

    final seq = ++_sizeEstimateRequestSeq;
    final mode = state.playlistMediaMode;
    final cap = state.playlistQualityCap;
    emit(state.copyWith(activeSizeEstimationId: null));

    try {
      final result = await _repository.estimatePlaylistSize(
        EstimatePlaylistSizeRequest(
          playlist: playlist,
          mediaMode: mode,
          qualityCap: cap,
        ),
      );
      if (isClosed || seq != _sizeEstimateRequestSeq) return;
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
            knownTotalBytes: BigInt.zero,
            totalEntriesCount: playlist.entries.length,
            unavailableCount: unavailableCount,
            eligibleCount: eligibleCount,
            inspectedCount: 0,
            exactCount: 0,
            estimatedCount: 0,
            unknownCount: 0,
            failedCount: eligibleCount,
            displaySummary: 'Some video sizes could not be determined',
            statusMessage: _cleanErrorMessage(err),
            itemSizes: const [],
          ),
        ),
      );
    }
  }

  Future<void> cancelPlaylistSizeEstimation() async {
    await _cancelActiveSizeEstimation();
  }

  Future<void> _cancelActiveSizeEstimation() async {
    _sizeEstimateRequestSeq++;
    final activeId =
        state.playlistSizeEstimate?.status == PlaylistSizeStatus.calculating
        ? state.playlistSizeEstimate?.estimationId
        : state.activeSizeEstimationId;
    if (activeId == null || activeId.isEmpty) return;
    try {
      await _repository.cancelPlaylistSizeEstimation(activeId);
    } catch (_) {
      // Cancellation is best-effort.
    }
  }

  void _onPlaylistSizeEstimate(PlaylistSizeEstimate estimate) {
    if (!state.isPlaylistTarget ||
        state.playlistInspection?.id != estimate.playlistId ||
        estimate.mediaMode != state.playlistMediaMode ||
        estimate.qualityCap != state.playlistQualityCap) {
      return;
    }
    final expectedId = state.activeSizeEstimationId;
    if (expectedId != null && expectedId != estimate.estimationId) {
      return;
    }
    emit(
      state.copyWith(
        playlistSizeEstimate: estimate,
        activeSizeEstimationId: estimate.estimationId,
      ),
    );
  }

  Future<void> startPlaylistDownload() async {
    final playlist = state.playlistInspection;
    if (!state.canStartPlaylist || playlist == null) {
      return;
    }

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
      final snapshot = await _repository.startPlaylistDownload(
        StartPlaylistDownloadRequest(
          playlist: playlist,
          mediaMode: state.playlistMediaMode,
          qualityCap: state.playlistQualityCap,
        ),
      );
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
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistError: _cleanErrorMessage(err),
        ),
      );
    }
  }

  Future<void> pausePlaylistDownload() async {
    final session = state.playlistSession;
    if (session == null || !state.canPausePlaylist) return;

    try {
      await _repository.pausePlaylistDownload(session.sessionId);
    } catch (err) {
      emit(state.copyWith(playlistError: _cleanErrorMessage(err)));
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
      final resumed = await _repository.resumePlaylistDownload(
        session.sessionId,
      );
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistSession: resumed,
          playlistError: null,
        ),
      );
      _flushPendingPlaylistEvents();
    } catch (err) {
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistError: _cleanErrorMessage(err),
        ),
      );
    }
  }

  Future<void> cancelPlaylistDownload() async {
    final session = state.playlistSession;
    if (session == null || !state.canCancelPlaylist) return;

    try {
      await _repository.cancelPlaylistDownload(session.sessionId);
    } catch (err) {
      emit(state.copyWith(playlistError: _cleanErrorMessage(err)));
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
      final retried = await _repository.retryFailedPlaylistItems(
        session.sessionId,
      );
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistSession: retried,
          playlistError: null,
        ),
      );
      _flushPendingPlaylistEvents();
    } catch (err) {
      emit(
        state.copyWith(
          isStartingPlaylist: false,
          playlistError: _cleanErrorMessage(err),
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
    final currentSession = state.playlistSession;
    if (currentSession == null) {
      if (state.isStartingPlaylist) {
        _pendingPlaylistEvents.add(event);
      }
      return;
    }
    _applyPlaylistProgressEvent(event);
  }

  void _applyPlaylistProgressEvent(PlaylistProgressEvent event) {
    final currentSession = state.playlistSession;
    if (currentSession == null || currentSession.sessionId != event.sessionId) {
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

          final nextDownloaded = event.itemDownloadedBytes > BigInt.zero
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

    final (nextIsRunning, nextIsPaused) = switch (event.kind) {
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

    final Object? nextActiveIndex;
    final Object? nextSpeed;
    final Object? nextEta;

    switch (event.kind) {
      case PlaylistEventKind.playlistItemStarted:
        nextActiveIndex = event.itemIndex;
        nextSpeed = null;
        nextEta = null;
      case PlaylistEventKind.playlistItemProgress:
        nextActiveIndex = event.itemIndex;
        nextSpeed = event.speedBytesPerSec;
        nextEta = event.etaSeconds;
      case PlaylistEventKind.playlistItemMerging:
        nextActiveIndex = event.itemIndex;
        nextSpeed = null;
        nextEta = null;
      case PlaylistEventKind.playlistItemCompleted:
      case PlaylistEventKind.playlistItemFailed:
      case PlaylistEventKind.playlistItemSkipped:
        nextActiveIndex = event.itemIndex;
        nextSpeed = null;
        nextEta = null;
      case PlaylistEventKind.playlistPaused:
      case PlaylistEventKind.playlistCanceled:
      case PlaylistEventKind.playlistCompleted:
        nextActiveIndex = null;
        nextSpeed = null;
        nextEta = null;
      case PlaylistEventKind.playlistStarted:
        nextActiveIndex = state.activePlaylistItemIndex;
        nextSpeed = state.activePlaylistSpeedBytesPerSec;
        nextEta = state.activePlaylistEtaSeconds;
    }

    emit(
      state.copyWith(
        playlistSession: updatedSnapshot,
        isStartingPlaylist: false,
        activePlaylistItemIndex: nextActiveIndex,
        activePlaylistSpeedBytesPerSec: nextSpeed,
        activePlaylistEtaSeconds: nextEta,
        playlistStatusMessage: event.message ?? state.playlistStatusMessage,
      ),
    );
  }

  void _onProgressEvent(DownloadProgressEvent event) {
    final activeId = state.activeJobId;
    if (activeId != null && event.jobId != activeId) {
      return;
    }
    if (activeId == null && !state.isStartingDownload) {
      return;
    }

    final isPauseEvent =
        event.phase == DownloadPhase.canceled && _pauseRequested;
    if (event.phase != DownloadPhase.canceled) {
      _pauseRequested = false;
    }

    final effectiveEvent = isPauseEvent
        ? DownloadProgressEvent(
            jobId: event.jobId,
            phase: event.phase,
            downloadedBytes: event.downloadedBytes,
            totalBytes: event.totalBytes,
            isTotalEstimated: event.isTotalEstimated,
            speedBytesPerSec: null,
            etaSeconds: null,
            outputPath: event.outputPath,
            message: 'Download paused. Click Resume to continue.',
          )
        : event;

    emit(
      state.copyWith(
        activeJobId: activeId ?? event.jobId,
        isPaused: isPauseEvent,
        latestProgress: effectiveEvent,
        downloadError: event.phase == DownloadPhase.failed
            ? (event.message ?? 'Download failed.')
            : null,
      ),
    );
  }

  String _cleanErrorMessage(Object error) {
    final text = error.toString().trim();
    if (text.startsWith('AnyhowException(') && text.endsWith(')')) {
      return text.substring('AnyhowException('.length, text.length - 1);
    }
    return text;
  }

  @override
  Future<void> close() async {
    await _progressSubscription?.cancel();
    await _playlistProgressSubscription?.cancel();
    await _sizeEstimateSubscription?.cancel();
    await _sharedUrlSubscription?.cancel();
    return super.close();
  }
}
