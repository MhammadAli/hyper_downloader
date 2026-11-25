import 'dart:async';
import 'dart:io';

import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/core/utils/filename_sanitizer.dart';
import 'package:hyper_download_client/data/datasources/local/json_playlist_session_local_datasource.dart';
import 'package:hyper_download_client/data/datasources/windows/win32_process_tree.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_tool_paths.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_yt_dlp_datasource.dart';
import 'package:hyper_download_client/data/parsers/yt_dlp_progress_parser.dart';
import 'package:hyper_download_client/data/repositories/media_inspection_repository_impl.dart';
import 'package:hyper_download_client/data/services/playlist_size_estimator.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/repositories/playlist_download_repository.dart';
import 'package:hyper_download_client/domain/services/media_option_synthesizer.dart';

enum _StopMode { pause, cancel }

class _ActivePlaylistRuntime {
  PlaylistSessionSnapshot snapshot;
  final List<String> itemStems;
  _StopMode? stopMode;
  final Completer<void> stopSignal = Completer<void>();
  ProcessTreeHandle? processHandle;
  final Completer<void> done = Completer<void>();

  _ActivePlaylistRuntime({
    required this.snapshot,
    required this.itemStems,
  });
}

/// Windows implementation of [PlaylistDownloadRepository] orchestrating sequential
/// playlist batch downloads, atomic `.hyperdl_playlist_session.json` manifests,
/// pause/resume/cancel/retry, and progressive size estimation.
class WindowsPlaylistDownloadRepositoryImpl
    implements PlaylistDownloadRepository {
  static const Duration _stopWaitTimeout = Duration(seconds: 5);

  final WindowsYtDlpDataSource _ytDlpDataSource;
  final MediaInspectionRepositoryImpl _inspectionRepository;
  final JsonPlaylistSessionLocalDataSource _localDataSource;
  final PlaylistSizeEstimator _sizeEstimator;
  final MediaOptionSynthesizer _synthesizer;
  final StreamController<PlaylistProgressEvent> _progressController =
      StreamController<PlaylistProgressEvent>.broadcast();

  _ActivePlaylistRuntime? _runtime;
  int _sessionSeq = 0;

  WindowsPlaylistDownloadRepositoryImpl({
    required this._ytDlpDataSource,
    required this._inspectionRepository,
    required this._localDataSource,
    required this._sizeEstimator,
    this._synthesizer = const MediaOptionSynthesizer(),
  });

  @override
  Stream<PlaylistProgressEvent> watchPlaylistProgress() =>
      _progressController.stream;

  @override
  Stream<PlaylistSizeEstimate> watchPlaylistSizeEstimate() =>
      _sizeEstimator.watchEstimates();

  @override
  Future<PlaylistSizeEstimate> estimatePlaylistSize(
    EstimatePlaylistSizeRequest request,
  ) => _sizeEstimator.estimate(request);

  @override
  Future<void> cancelPlaylistSizeEstimation(String estimationId) =>
      _sizeEstimator.cancelEstimation(estimationId);

  @override
  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  ) async {
    if (request.playlist.entries.isEmpty) {
      throw const ParseException('Playlist contains zero entries to download.');
    }
    if (_runtime?.snapshot.isRunning == true) {
      throw const DownloadBusyException(
        'Another playlist download is already in progress. Pause or cancel it first.',
      );
    }

    final paths = _ytDlpDataSource.resolveToolPaths();
    final customDir = request.outputDirectory?.trim();
    final baseDir = (customDir != null && customDir.isNotEmpty)
        ? Directory(customDir)
        : WindowsToolPaths.mediaSubfolder(
            Directory(paths.defaultOutputDir),
            isAudioOnly: request.mediaMode == PlaylistMediaMode.audioOnly,
          );

    final folderName = FilenameSanitizer.playlistFolderName(
      request.playlist.title,
      request.playlist.id,
    );
    final playlistDir = Directory(
      '${baseDir.path}${Platform.pathSeparator}$folderName',
    );
    await playlistDir.create(recursive: true);

    final previousManifest = await _localDataSource.loadSavedSession(
      [baseDir],
      request.playlist.id,
    );
    final snapshot = _buildInitialSnapshot(
      request,
      playlistDir.path,
      previousManifest,
    );
    final stems = _computeStemsForItems(snapshot.items);
    await _localDataSource.saveManifestAtomic(playlistDir, snapshot);

    return _launchRuntime(snapshot, stems, paths);
  }

  @override
  Future<void> pausePlaylistDownload(String sessionId) =>
      _requestStop(sessionId, _StopMode.pause);

  @override
  Future<void> cancelPlaylistDownload(String sessionId) =>
      _requestStop(sessionId, _StopMode.cancel);

  @override
  Future<PlaylistSessionSnapshot> resumePlaylistDownload(
    String sessionId,
  ) async {
    var runtime = _runtime;
    if (runtime == null || runtime.snapshot.sessionId != sessionId) {
      throw JobNotFoundException('Playlist session not found: $sessionId');
    }
    if (runtime.snapshot.isRunning) {
      throw DownloadBusyException(
        "Playlist session '$sessionId' is already running.",
      );
    }

    final paths = _ytDlpDataSource.resolveToolPaths();
    final updatedItems = runtime.snapshot.items
        .map(
          (item) => item.status == PlaylistItemStatus.canceled
              ? item.copyWith(
                  status: PlaylistItemStatus.pending,
                  errorMessage: null,
                )
              : item,
        )
        .toList(growable: false);

    final updated = _localDataSource.reconcileRecoveredSnapshot(
      runtime.snapshot.copyWith(isPaused: false, items: updatedItems),
    );
    await _localDataSource.saveManifestAtomic(
      Directory(updated.outputDirectory),
      updated,
    );
    return _launchRuntime(updated, runtime.itemStems, paths);
  }

  @override
  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(
    String sessionId,
  ) async {
    final runtime = _runtime;
    if (runtime == null || runtime.snapshot.sessionId != sessionId) {
      throw JobNotFoundException('Playlist session not found: $sessionId');
    }
    if (runtime.snapshot.isRunning) {
      throw DownloadBusyException(
        "Playlist session '$sessionId' is already running.",
      );
    }

    var failedCount = 0;
    final updatedItems = runtime.snapshot.items
        .map((item) {
          if (item.status == PlaylistItemStatus.failed) {
            failedCount++;
            return item.copyWith(
              status: PlaylistItemStatus.pending,
              errorMessage: null,
              downloadedBytes: 0,
              totalBytes: null,
            );
          }
          return item;
        })
        .toList(growable: false);

    if (failedCount == 0) {
      throw const ParseException(
        'There are no failed playlist items to retry.',
      );
    }

    final paths = _ytDlpDataSource.resolveToolPaths();
    final updated = runtime.snapshot
        .copyWith(isPaused: false, items: updatedItems)
        .withRecomputedCounters();
    await _localDataSource.saveManifestAtomic(
      Directory(updated.outputDirectory),
      updated,
    );
    return _launchRuntime(updated, runtime.itemStems, paths);
  }

  Future<void> _requestStop(String sessionId, _StopMode mode) async {
    final runtime = _runtime;
    if (runtime == null || runtime.snapshot.sessionId != sessionId) {
      throw JobNotFoundException('Playlist session not found: $sessionId');
    }
    if (!runtime.snapshot.isRunning) {
      throw ParseException(
        "Playlist session '$sessionId' is not currently running.",
      );
    }
    runtime.stopMode = mode;
    if (!runtime.stopSignal.isCompleted) {
      runtime.stopSignal.complete();
    }
    final handle = runtime.processHandle;
    if (handle != null) {
      await handle.terminate();
    }
    await runtime.done.future.timeout(_stopWaitTimeout, onTimeout: () {});
  }

  PlaylistSessionSnapshot _launchRuntime(
    PlaylistSessionSnapshot snapshot,
    List<String> stems,
    WindowsToolPaths paths,
  ) {
    final runningSnap = snapshot.copyWith(isRunning: true, isPaused: false);
    final runtime = _ActivePlaylistRuntime(
      snapshot: runningSnap,
      itemStems: stems,
    );
    _runtime = runtime;

    _progressController.add(
      _makeBatchEvent(
        runningSnap,
        PlaylistEventKind.playlistStarted,
        "Starting playlist '${runningSnap.playlistTitle}' (${runningSnap.totalCount} items)...",
      ),
    );

    unawaited(_runPlaylistWorker(runtime, paths));
    return runningSnap;
  }

  Future<void> _runPlaylistWorker(
    _ActivePlaylistRuntime runtime,
    WindowsToolPaths paths,
  ) async {
    _StopMode? stoppedBy;

    for (var idx = 0; idx < runtime.snapshot.items.length; idx++) {
      if (runtime.stopMode != null) {
        stoppedBy = runtime.stopMode;
        break;
      }

      final item = runtime.snapshot.items[idx];
      if (item.status == PlaylistItemStatus.completed) continue;
      if (item.status == PlaylistItemStatus.skipped) {
        _progressController.add(
          _makeItemEvent(
            runtime.snapshot,
            PlaylistEventKind.playlistItemSkipped,
            idx,
            PlaylistItemStatus.skipped,
            audioLanguage: item.audioLanguage,
            message: item.errorMessage,
          ),
        );
        continue;
      }
      if (item.status != PlaylistItemStatus.pending) continue;

      _updateItem(runtime, idx, status: PlaylistItemStatus.analyzing);
      await _localDataSource.saveManifestAtomic(
        Directory(runtime.snapshot.outputDirectory),
        runtime.snapshot,
      );
      _progressController.add(
        _makeItemEvent(
          runtime.snapshot,
          PlaylistEventKind.playlistItemStarted,
          idx,
          PlaylistItemStatus.analyzing,
          message: "Analyzing '${item.title}'...",
        ),
      );

      final MediaInspection inspection;
      try {
        inspection = await _inspectionRepository.inspectMedia(item.url);
      } catch (err) {
        if (runtime.stopMode != null) {
          _revertInterruptedItem(runtime, idx, runtime.stopMode!);
          stoppedBy = runtime.stopMode;
          break;
        }
        await _recordItemFailure(runtime, idx, err.toString());
        continue;
      }

      if (runtime.stopMode != null) {
        _revertInterruptedItem(runtime, idx, runtime.stopMode!);
        stoppedBy = runtime.stopMode;
        break;
      }

      final ResolvedPlaylistSelection resolved;
      try {
        resolved = _synthesizer.selectPlaylistItemOption(
          inspection,
          runtime.snapshot.mediaMode,
          runtime.snapshot.qualityCap,
        );
      } catch (err) {
        await _recordItemFailure(runtime, idx, err.toString());
        continue;
      }

      _updateItem(
        runtime,
        idx,
        status: PlaylistItemStatus.downloading,
        selectedQuality: resolved.qualityLabel,
        audioLanguage: resolved.audioLanguage,
      );

      final stem = runtime.itemStems[idx];
      final sep = Platform.pathSeparator;
      final outputTemplate =
          '${runtime.snapshot.outputDirectory}$sep$stem.%(ext)s';
      final dlRequest = StartDownloadRequest(
        url: inspection.webpageUrl.isEmpty ? item.url : inspection.webpageUrl,
        title: inspection.title,
        selection: resolved.selection,
        outputDirectory: runtime.snapshot.outputDirectory,
      );

      try {
        final finalPath = await _downloadItemWithRetry(
          runtime: runtime,
          paths: paths,
          request: dlRequest,
          outputTemplate: outputTemplate,
          itemIndex: idx,
          qualityLabel: resolved.qualityLabel,
          audioLanguage: resolved.audioLanguage,
        );

        if (runtime.stopMode != null) {
          _revertInterruptedItem(runtime, idx, runtime.stopMode!);
          stoppedBy = runtime.stopMode;
          break;
        }

        final file = File(finalPath);
        final diskBytes = await file.exists() ? await file.length() : 0;
        await _recordItemCompleted(runtime, idx, finalPath, diskBytes);
      } catch (err) {
        if (runtime.stopMode != null) {
          _revertInterruptedItem(runtime, idx, runtime.stopMode!);
          stoppedBy = runtime.stopMode;
          break;
        }
        await _recordItemFailure(runtime, idx, err.toString());
      }
    }

    runtime.snapshot = runtime.snapshot
        .copyWith(
          isRunning: false,
          isPaused: stoppedBy == _StopMode.pause,
        )
        .withRecomputedCounters();
    runtime.stopMode = null;

    await _localDataSource.saveManifestAtomic(
      Directory(runtime.snapshot.outputDirectory),
      runtime.snapshot,
    );

    final (PlaylistEventKind kind, String msg) = switch (stoppedBy) {
      _StopMode.pause => (
        PlaylistEventKind.playlistPaused,
        'Playlist paused. Completed files preserved; click Resume to continue.',
      ),
      _StopMode.cancel => (
        PlaylistEventKind.playlistCanceled,
        'Playlist canceled. Completed files preserved on disk.',
      ),
      null => (
        PlaylistEventKind.playlistCompleted,
        'Playlist finished: ${runtime.snapshot.completedCount} completed, '
            '${runtime.snapshot.failedCount} failed, '
            '${runtime.snapshot.skippedCount} skipped.',
      ),
    };
    _progressController.add(_makeBatchEvent(runtime.snapshot, kind, msg));
    if (!runtime.done.isCompleted) runtime.done.complete();
  }

  Future<String> _downloadItemWithRetry({
    required _ActivePlaylistRuntime runtime,
    required WindowsToolPaths paths,
    required StartDownloadRequest request,
    required String outputTemplate,
    required int itemIndex,
    required String qualityLabel,
    required AudioTrackMetadata? audioLanguage,
  }) async {
    Future<YtDlpDownloadAttemptResult> runOnce(List<String> args) {
      var lastDownloaded = 0;
      int? lastTotal;
      var lastEstimated = false;
      final jobId = '${runtime.snapshot.sessionId}_$itemIndex';
      return _ytDlpDataSource.runDownloadAttempt(
        jobId: jobId,
        paths: paths,
        args: args,
        isCancelRequested: () => runtime.stopMode != null,
        cancelSignal: runtime.stopSignal.future,
        onProcessAttached: (h) => runtime.processHandle = h,
        onProcessDetached: () => runtime.processHandle = null,
        onParsedLine: (parsed) {
          switch (parsed) {
            case ParsedDownloadProgress(
              :final status,
              :final downloadedBytes,
              :final totalBytes,
              :final isTotalEstimated,
              :final speedBytesPerSec,
              :final etaSeconds,
            ):
              lastDownloaded = downloadedBytes;
              if (totalBytes != null) {
                lastTotal = totalBytes;
                lastEstimated = isTotalEstimated;
              }
              _progressController.add(
                PlaylistProgressEvent(
                  sessionId: runtime.snapshot.sessionId,
                  kind: PlaylistEventKind.playlistItemProgress,
                  itemIndex: itemIndex,
                  itemStatus: PlaylistItemStatus.downloading,
                  selectedQuality: qualityLabel,
                  audioLanguage: audioLanguage,
                  itemDownloadedBytes: downloadedBytes,
                  itemTotalBytes: lastTotal,
                  itemIsTotalEstimated: lastEstimated,
                  speedBytesPerSec: speedBytesPerSec,
                  etaSeconds: etaSeconds,
                  completedCount: runtime.snapshot.completedCount,
                  failedCount: runtime.snapshot.failedCount,
                  skippedCount: runtime.snapshot.skippedCount,
                  totalCount: runtime.snapshot.totalCount,
                  playlistOutputDir: runtime.snapshot.outputDirectory,
                  message: status == 'finished'
                      ? 'Stream downloaded, preparing next step...'
                      : null,
                ),
              );
            case ParsedPostprocessProgress(:final postprocessor):
              _progressController.add(
                PlaylistProgressEvent(
                  sessionId: runtime.snapshot.sessionId,
                  kind: PlaylistEventKind.playlistItemMerging,
                  itemIndex: itemIndex,
                  itemStatus: PlaylistItemStatus.merging,
                  selectedQuality: qualityLabel,
                  audioLanguage: audioLanguage,
                  itemDownloadedBytes: lastDownloaded,
                  itemTotalBytes: lastTotal,
                  itemIsTotalEstimated: lastEstimated,
                  completedCount: runtime.snapshot.completedCount,
                  failedCount: runtime.snapshot.failedCount,
                  skippedCount: runtime.snapshot.skippedCount,
                  totalCount: runtime.snapshot.totalCount,
                  playlistOutputDir: runtime.snapshot.outputDirectory,
                  message: 'Running $postprocessor with FFmpeg...',
                ),
              );
            case ParsedStageStatus() ||
                ParsedOutputPathDetected() ||
                ParsedOtherLine():
              break;
          }
        },
      );
    }

    final liveArgs = _ytDlpDataSource.buildDownloadArgs(
      paths,
      request,
      request.url,
      outputTemplate,
    );

    YtDlpDownloadAttemptResult attempt;
    final cachedJson = _inspectionRepository.getCachedRawJson(request.url);
    if (cachedJson != null) {
      final sep = Platform.pathSeparator;
      final infoFile = File(
        '${Directory.systemTemp.path}${sep}hyperdl_pl_info_${runtime.snapshot.sessionId}_$itemIndex.json',
      );
      try {
        await infoFile.writeAsString(cachedJson, flush: true);
        final cachedArgs = _ytDlpDataSource.buildDownloadArgsFromInfoJson(
          paths,
          request,
          outputTemplate,
          infoFile.path,
          isInstagram: false,
        );
        attempt = await runOnce(cachedArgs);
        if (!attempt.succeeded && runtime.stopMode == null) {
          _inspectionRepository.evictCachedRawJson(request.url);
          attempt = await runOnce(liveArgs);
        }
      } finally {
        try {
          if (await infoFile.exists()) await infoFile.delete();
        } catch (_) {}
      }
    } else {
      attempt = await runOnce(liveArgs);
    }

    if (!attempt.succeeded &&
        runtime.stopMode == null &&
        attempt.stderrText.contains('HTTP Error 403')) {
      await Future.any([
        Future<void>.delayed(const Duration(milliseconds: 1500)),
        runtime.stopSignal.future,
      ]);
      if (runtime.stopMode != null) {
        throw const ProcessExecutionException('Stopped by user');
      }
      attempt = await runOnce(liveArgs);
    }

    if (!attempt.succeeded) {
      throw ProcessExecutionException(
        attempt.stderrText.trim().isEmpty
            ? 'yt-dlp exited with code ${attempt.exitCode}'
            : attempt.stderrText.trim(),
        exitCode: attempt.exitCode,
      );
    }

    final finalPath = attempt.recordedOutputPath ?? attempt.detectedOutputPath;
    if (finalPath == null || finalPath.isEmpty) {
      throw const ParseException(
        'Download exited cleanly but final file path could not be determined.',
      );
    }
    return finalPath;
  }

  void _updateItem(
    _ActivePlaylistRuntime runtime,
    int idx, {
    required PlaylistItemStatus status,
    String? selectedQuality,
    AudioTrackMetadata? audioLanguage,
  }) {
    final items = List<PlaylistItemState>.from(runtime.snapshot.items);
    items[idx] = items[idx].copyWith(
      status: status,
      selectedQuality: selectedQuality ?? items[idx].selectedQuality,
      audioLanguage: audioLanguage ?? items[idx].audioLanguage,
      errorMessage: null,
    );
    runtime.snapshot = runtime.snapshot
        .copyWith(items: items)
        .withRecomputedCounters();
  }

  Future<void> _recordItemCompleted(
    _ActivePlaylistRuntime runtime,
    int idx,
    String outputPath,
    int diskBytes,
  ) async {
    final items = List<PlaylistItemState>.from(runtime.snapshot.items);
    final updated = items[idx].copyWith(
      status: PlaylistItemStatus.completed,
      outputPath: outputPath,
      downloadedBytes: diskBytes,
      totalBytes: diskBytes,
      isTotalEstimated: false,
      errorMessage: null,
    );
    items[idx] = updated;
    runtime.snapshot = runtime.snapshot
        .copyWith(items: items)
        .withRecomputedCounters();

    await _localDataSource.saveManifestAtomic(
      Directory(runtime.snapshot.outputDirectory),
      runtime.snapshot,
    );
    _progressController.add(
      PlaylistProgressEvent(
        sessionId: runtime.snapshot.sessionId,
        kind: PlaylistEventKind.playlistItemCompleted,
        itemIndex: idx,
        itemStatus: PlaylistItemStatus.completed,
        selectedQuality: updated.selectedQuality,
        audioLanguage: updated.audioLanguage,
        itemDownloadedBytes: diskBytes,
        itemTotalBytes: diskBytes,
        itemIsTotalEstimated: false,
        outputPath: outputPath,
        completedCount: runtime.snapshot.completedCount,
        failedCount: runtime.snapshot.failedCount,
        skippedCount: runtime.snapshot.skippedCount,
        totalCount: runtime.snapshot.totalCount,
        playlistOutputDir: runtime.snapshot.outputDirectory,
        message: 'Item completed.',
      ),
    );
  }

  Future<void> _recordItemFailure(
    _ActivePlaylistRuntime runtime,
    int idx,
    String errorMsg,
  ) async {
    final items = List<PlaylistItemState>.from(runtime.snapshot.items);
    final updated = items[idx].copyWith(
      status: PlaylistItemStatus.failed,
      errorMessage: errorMsg,
    );
    items[idx] = updated;
    runtime.snapshot = runtime.snapshot
        .copyWith(items: items)
        .withRecomputedCounters();

    await _localDataSource.saveManifestAtomic(
      Directory(runtime.snapshot.outputDirectory),
      runtime.snapshot,
    );
    _progressController.add(
      _makeItemEvent(
        runtime.snapshot,
        PlaylistEventKind.playlistItemFailed,
        idx,
        PlaylistItemStatus.failed,
        selectedQuality: updated.selectedQuality,
        audioLanguage: updated.audioLanguage,
        message: errorMsg,
      ),
    );
  }

  void _revertInterruptedItem(
    _ActivePlaylistRuntime runtime,
    int activeIdx,
    _StopMode mode,
  ) {
    final items = List<PlaylistItemState>.from(runtime.snapshot.items);
    items[activeIdx] = items[activeIdx].copyWith(
      status: mode == _StopMode.pause
          ? PlaylistItemStatus.pending
          : PlaylistItemStatus.canceled,
    );
    if (mode == _StopMode.cancel) {
      for (var i = activeIdx + 1; i < items.length; i++) {
        if (items[i].status == PlaylistItemStatus.pending) {
          items[i] = items[i].copyWith(status: PlaylistItemStatus.canceled);
        }
      }
    }
    runtime.snapshot = runtime.snapshot
        .copyWith(items: items)
        .withRecomputedCounters();
  }

  PlaylistSessionSnapshot _buildInitialSnapshot(
    StartPlaylistDownloadRequest request,
    String playlistDir,
    PlaylistSessionSnapshot? previousManifest,
  ) {
    final reuseCompleted =
        previousManifest != null &&
        previousManifest.mediaMode == request.mediaMode &&
        previousManifest.qualityCap == request.qualityCap;

    final items = request.playlist.entries
        .map((entry) {
          if (entry.availability != PlaylistEntryAvailability.available) {
            return PlaylistItemState(
              orderIndex: entry.orderIndex,
              videoId: entry.videoId,
              title: entry.title,
              url: entry.url,
              durationSeconds: entry.durationSeconds,
              thumbnailUrl: entry.thumbnailUrl,
              status: PlaylistItemStatus.skipped,
              downloadedBytes: 0,
              isTotalEstimated: false,
              errorMessage: entry.availabilityReason,
            );
          }

          if (reuseCompleted) {
            for (final prev in previousManifest.items) {
              if (prev.videoId == entry.videoId &&
                  prev.orderIndex == entry.orderIndex &&
                  prev.status == PlaylistItemStatus.completed) {
                final path = prev.outputPath;
                if (path != null &&
                    path.isNotEmpty &&
                    File(path).existsSync() &&
                    File(path).lengthSync() > 0) {
                  return prev;
                }
              }
            }
          }

          return PlaylistItemState(
            orderIndex: entry.orderIndex,
            videoId: entry.videoId,
            title: entry.title,
            url: entry.url,
            durationSeconds: entry.durationSeconds,
            thumbnailUrl: entry.thumbnailUrl,
            status: PlaylistItemStatus.pending,
            downloadedBytes: 0,
            isTotalEstimated: false,
          );
        })
        .toList(growable: false);

    return PlaylistSessionSnapshot(
      sessionId: 'pl-${++_sessionSeq}-${DateTime.now().microsecondsSinceEpoch}',
      playlistId: request.playlist.id,
      playlistTitle: request.playlist.title,
      playlistUrl: request.playlist.webpageUrl,
      uploader: request.playlist.uploader,
      thumbnailUrl: request.playlist.thumbnailUrl,
      outputDirectory: playlistDir,
      mediaMode: request.mediaMode,
      qualityCap: request.qualityCap,
      isRunning: false,
      isPaused: false,
      completedCount: 0,
      failedCount: 0,
      skippedCount: 0,
      totalCount: items.length,
      items: items,
    ).withRecomputedCounters();
  }

  List<String> _computeStemsForItems(List<PlaylistItemState> items) {
    return FilenameSanitizer.computeStemsForItems(
      items
          .map((i) => (orderIndex: i.orderIndex, title: i.title))
          .toList(growable: false),
    );
  }

  PlaylistProgressEvent _makeBatchEvent(
    PlaylistSessionSnapshot snap,
    PlaylistEventKind kind,
    String message,
  ) {
    return PlaylistProgressEvent(
      sessionId: snap.sessionId,
      kind: kind,
      itemDownloadedBytes: 0,
      itemIsTotalEstimated: false,
      completedCount: snap.completedCount,
      failedCount: snap.failedCount,
      skippedCount: snap.skippedCount,
      totalCount: snap.totalCount,
      playlistOutputDir: snap.outputDirectory,
      message: message,
    );
  }

  PlaylistProgressEvent _makeItemEvent(
    PlaylistSessionSnapshot snap,
    PlaylistEventKind kind,
    int itemIndex,
    PlaylistItemStatus itemStatus, {
    String? selectedQuality,
    AudioTrackMetadata? audioLanguage,
    String? message,
  }) {
    return PlaylistProgressEvent(
      sessionId: snap.sessionId,
      kind: kind,
      itemIndex: itemIndex,
      itemStatus: itemStatus,
      selectedQuality: selectedQuality,
      audioLanguage: audioLanguage,
      itemDownloadedBytes: 0,
      itemIsTotalEstimated: false,
      completedCount: snap.completedCount,
      failedCount: snap.failedCount,
      skippedCount: snap.skippedCount,
      totalCount: snap.totalCount,
      playlistOutputDir: snap.outputDirectory,
      message: message,
    );
  }

  Future<void> dispose() async {
    await _progressController.close();
  }
}
