import 'dart:async';
import 'dart:io';

import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/data/datasources/windows/win32_process_tree.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_tool_paths.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_yt_dlp_datasource.dart';
import 'package:hyper_download_client/data/parsers/yt_dlp_progress_parser.dart';
import 'package:hyper_download_client/data/repositories/media_inspection_repository_impl.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/platforms/media_platform.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';
import 'package:hyper_download_client/domain/repositories/single_download_repository.dart';

class _ActiveSingleJob {
  final String jobId;
  final StartDownloadRequest request;
  final String outputTemplate;
  bool isRunning = true;
  bool cancelRequested = false;
  final Completer<void> cancelSignal = Completer<void>();
  ProcessTreeHandle? processHandle;
  final Completer<void> done = Completer<void>();

  _ActiveSingleJob({
    required this.jobId,
    required this.request,
    required this.outputTemplate,
  });
}

/// Windows implementation of [SingleDownloadRepository] managing a single active
/// `yt-dlp.exe` transfer with Win32 Job Object cancel & `--continue` resume.
class WindowsSingleDownloadRepositoryImpl implements SingleDownloadRepository {
  static const Duration _metaCachedFirstByteTimeout = Duration(seconds: 45);
  static const Duration _metaLiveFirstByteTimeout = Duration(seconds: 110);
  static const Duration _cancelWaitTimeout = Duration(seconds: 5);

  final WindowsYtDlpDataSource _ytDlpDataSource;
  final MediaInspectionRepositoryImpl _inspectionRepository;
  final PlatformRegistry _platformRegistry;
  final StreamController<DownloadProgressEvent> _progressController =
      StreamController<DownloadProgressEvent>.broadcast();

  _ActiveSingleJob? _activeJob;
  int _jobSeq = 0;

  WindowsSingleDownloadRepositoryImpl({
    required this._ytDlpDataSource,
    required this._inspectionRepository,
    PlatformRegistry? platformRegistry,
  }) : _platformRegistry = platformRegistry ?? const PlatformRegistry();

  @override
  Stream<DownloadProgressEvent> watchDownloadProgress() =>
      _progressController.stream;

  @override
  Future<String> startDownload(StartDownloadRequest request) async {
    final existing = _activeJob;
    if (existing != null && existing.isRunning) {
      throw const DownloadBusyException(
        'Another download is already running. Cancel or finish it first.',
      );
    }

    final classified = _platformRegistry.classifyAndNormalize(request.url);
    final originalUrl = request.url;
    final normalizedRequest = StartDownloadRequest(
      url: classified.normalizedUrl,
      title: request.title,
      selection: request.selection,
      outputDirectory: request.outputDirectory,
    );

    final paths = _ytDlpDataSource.resolveToolPaths();
    final customDir = normalizedRequest.outputDirectory?.trim();
    final isAudioOnly = _requestIsAudioOnly(normalizedRequest, originalUrl);
    final outputDir = (customDir != null && customDir.isNotEmpty)
        ? Directory(customDir)
        : WindowsToolPaths.mediaSubfolder(
            Directory(paths.defaultOutputDir),
            isAudioOnly: isAudioOnly,
          );
    await outputDir.create(recursive: true);

    final outputTemplate = _ytDlpDataSource.resolveOutputTemplateForNewJob(
      outputDir,
      normalizedRequest,
      shortcode: classified.shortcode,
    );

    final args = _ytDlpDataSource.buildDownloadArgs(
      paths,
      normalizedRequest,
      classified.normalizedUrl,
      outputTemplate,
    );

    final jobId = 'job-${++_jobSeq}-${DateTime.now().microsecondsSinceEpoch}';
    _launchJob(
      jobId: jobId,
      request: normalizedRequest,
      outputTemplate: outputTemplate,
      paths: paths,
      args: args,
      platformId: classified.platformId,
    );
    return jobId;
  }

  @override
  Future<void> cancelDownload(String jobId) async {
    final active = _activeJob;
    if (active == null || active.jobId != jobId) {
      throw JobNotFoundException('Download job not found: $jobId');
    }
    if (!active.isRunning) {
      throw ParseException("Download job '$jobId' is not currently running.");
    }
    active.cancelRequested = true;
    if (!active.cancelSignal.isCompleted) {
      active.cancelSignal.complete();
    }
    final handle = active.processHandle;
    if (handle != null) {
      await handle.terminate();
    }
    await active.done.future.timeout(_cancelWaitTimeout, onTimeout: () {});
  }

  @override
  Future<String> resumeDownload(String jobId) async {
    final active = _activeJob;
    if (active == null || active.jobId != jobId) {
      throw JobNotFoundException('Download job not found: $jobId');
    }
    if (active.isRunning) {
      throw DownloadBusyException("Download job '$jobId' is already running.");
    }

    final classified = _platformRegistry.classifyAndNormalize(
      active.request.url,
    );
    final paths = _ytDlpDataSource.resolveToolPaths();
    final args = _ytDlpDataSource.buildDownloadArgs(
      paths,
      active.request,
      classified.normalizedUrl,
      active.outputTemplate,
    );

    _launchJob(
      jobId: jobId,
      request: active.request,
      outputTemplate: active.outputTemplate,
      paths: paths,
      args: args,
      platformId: classified.platformId,
    );
    return jobId;
  }

  bool _requestIsAudioOnly(StartDownloadRequest request, String originalUrl) {
    if (request.selection.kind == DownloadSelectionKind.videoAndAudio) {
      return false;
    }
    final fid = request.selection.formatId?.trim();
    if (fid == null || fid.isEmpty) return false;
    return _inspectionRepository.isRegisteredAudioOnlyFormat(
          request.url,
          fid,
        ) ||
        _inspectionRepository.isRegisteredAudioOnlyFormat(originalUrl, fid);
  }

  void _launchJob({
    required String jobId,
    required StartDownloadRequest request,
    required String outputTemplate,
    required WindowsToolPaths paths,
    required List<String> args,
    required MediaPlatformId platformId,
  }) {
    final job = _ActiveSingleJob(
      jobId: jobId,
      request: request,
      outputTemplate: outputTemplate,
    );
    _activeJob = job;

    final isMetaPlatform =
        platformId == MediaPlatformId.instagram ||
        platformId == MediaPlatformId.facebook;
    final hasCachedMetaInfo =
        isMetaPlatform &&
        _inspectionRepository.getCachedRawJson(
              request.url,
              isShortLivedCdn: true,
            ) !=
            null;

    final strategy = _platformRegistry.strategyForId(platformId);
    final initialMsg = (isMetaPlatform && !hasCachedMetaInfo)
        ? 'Connecting to ${strategy.displayName}...'
        : 'Preparing download...';
    _emitAnalyzingStage(jobId, initialMsg);

    unawaited(_runWorker(job, paths, args, platformId));
  }

  Future<void> _runWorker(
    _ActiveSingleJob job,
    WindowsToolPaths paths,
    List<String> args,
    MediaPlatformId platformId,
  ) async {
    final jobStarted = DateTime.now();
    final isMetaPlatform =
        platformId == MediaPlatformId.instagram ||
        platformId == MediaPlatformId.facebook;
    final strategy = _platformRegistry.strategyForId(platformId);

    YtDlpDownloadAttemptResult? outcome;
    try {
      outcome = isMetaPlatform
          ? await _executeMetaDownload(job, paths, args, platformId)
          : await _executeStandardDownload(job, paths, args);
    } catch (err) {
      job.isRunning = false;
      _progressController.add(
        DownloadProgressEvent(
          jobId: job.jobId,
          phase: DownloadPhase.failed,
          downloadedBytes: 0,
          isTotalEstimated: false,
          message: 'Failed to launch yt-dlp: $err',
        ),
      );
      if (!job.done.isCompleted) job.done.complete();
      return;
    }

    if (job.cancelRequested) {
      await _ytDlpDataSource.cleanupTempMuxArtifacts(
        job.outputTemplate,
        jobStarted,
      );
    }
    job.isRunning = false;

    final DownloadProgressEvent finalEvent;
    if (job.cancelRequested) {
      finalEvent = DownloadProgressEvent(
        jobId: job.jobId,
        phase: DownloadPhase.canceled,
        downloadedBytes: outcome.lastDownloaded,
        totalBytes: outcome.lastTotal,
        isTotalEstimated: outcome.lastEstimated,
        outputPath: outcome.recordedOutputPath ?? outcome.detectedOutputPath,
        message: 'Download canceled. Partial data preserved for resume.',
      );
    } else if (outcome.launchError != null) {
      finalEvent = DownloadProgressEvent(
        jobId: job.jobId,
        phase: DownloadPhase.failed,
        downloadedBytes: outcome.lastDownloaded,
        totalBytes: outcome.lastTotal,
        isTotalEstimated: outcome.lastEstimated,
        outputPath: outcome.detectedOutputPath,
        message: 'Failed to launch yt-dlp: ${outcome.launchError}',
      );
    } else if (outcome.timedOut) {
      finalEvent = DownloadProgressEvent(
        jobId: job.jobId,
        phase: DownloadPhase.failed,
        downloadedBytes: outcome.lastDownloaded,
        totalBytes: outcome.lastTotal,
        isTotalEstimated: outcome.lastEstimated,
        outputPath: outcome.detectedOutputPath,
        message: isMetaPlatform
            ? strategy.classifyError(outcome.stderrText)
            : 'Timed out before media transfer started.',
      );
    } else if (outcome.succeeded) {
      final finalPath =
          outcome.recordedOutputPath ?? outcome.detectedOutputPath;
      int? diskBytes;
      if (finalPath != null && finalPath.isNotEmpty) {
        final file = File(finalPath);
        if (await file.exists()) {
          diskBytes = await file.length();
        }
      }
      if (finalPath == null || diskBytes == null || diskBytes == 0) {
        finalEvent = DownloadProgressEvent(
          jobId: job.jobId,
          phase: DownloadPhase.failed,
          downloadedBytes: outcome.lastDownloaded,
          totalBytes: outcome.lastTotal,
          isTotalEstimated: outcome.lastEstimated,
          outputPath: finalPath,
          message:
              'Download finished, but the output file is missing or empty.',
        );
      } else {
        finalEvent = DownloadProgressEvent(
          jobId: job.jobId,
          phase: DownloadPhase.completed,
          downloadedBytes: diskBytes,
          totalBytes: diskBytes,
          isTotalEstimated: false,
          etaSeconds: 0,
          outputPath: finalPath,
          message: 'Download completed.',
        );
      }
    } else {
      final msg = isMetaPlatform
          ? strategy.classifyError(outcome.stderrText)
          : (outcome.stderrText.trim().isEmpty
                ? 'yt-dlp exited with code ${outcome.exitCode}'
                : outcome.stderrText.trim());
      finalEvent = DownloadProgressEvent(
        jobId: job.jobId,
        phase: DownloadPhase.failed,
        downloadedBytes: outcome.lastDownloaded,
        totalBytes: outcome.lastTotal,
        isTotalEstimated: outcome.lastEstimated,
        outputPath: outcome.detectedOutputPath,
        message: msg,
      );
    }

    _progressController.add(finalEvent);
    if (!job.done.isCompleted) job.done.complete();
  }

  Future<YtDlpDownloadAttemptResult> _executeMetaDownload(
    _ActiveSingleJob job,
    WindowsToolPaths paths,
    List<String> args,
    MediaPlatformId platformId,
  ) async {
    final strategy = _platformRegistry.strategyForId(platformId);
    final cachedJson = _inspectionRepository.getCachedRawJson(
      job.request.url,
      isShortLivedCdn: true,
    );

    if (cachedJson != null) {
      final sep = Platform.pathSeparator;
      final infoFile = File(
        '${Directory.systemTemp.path}${sep}hyperdl_info_${job.jobId}.json',
      );
      try {
        await infoFile.writeAsString(cachedJson, flush: true);
        final cachedArgs = _ytDlpDataSource.buildDownloadArgsFromInfoJson(
          paths,
          job.request,
          job.outputTemplate,
          infoFile.path,
          useMetaNetworkArgs: true,
        );
        final res = await _runTrackedAttempt(
          job,
          paths,
          cachedArgs,
          firstByteTimeout: _metaCachedFirstByteTimeout,
        );
        if (res.succeeded || job.cancelRequested || res.lastDownloaded > 0) {
          return res;
        }
        _inspectionRepository.evictCachedRawJson(job.request.url);
      } finally {
        try {
          if (await infoFile.exists()) await infoFile.delete();
        } catch (_) {}
      }
    }

    if (job.cancelRequested) {
      return const YtDlpDownloadAttemptResult(
        stderrText: '',
        lastDownloaded: 0,
        lastEstimated: false,
        timedOut: false,
      );
    }

    _emitAnalyzingStage(job.jobId, 'Connecting to ${strategy.displayName}...');
    final liveArgs = _ytDlpDataSource.buildInstagramNetworkArgs(args);
    final firstLive = await _runTrackedAttempt(
      job,
      paths,
      liveArgs,
      firstByteTimeout: _metaLiveFirstByteTimeout,
    );

    if (!firstLive.succeeded &&
        !job.cancelRequested &&
        firstLive.lastDownloaded == 0 &&
        !firstLive.timedOut &&
        strategy.isTransientError(firstLive.stderrText)) {
      _emitAnalyzingStage(
        job.jobId,
        'Retrying connection to ${strategy.displayName}...',
      );
      await Future.any([
        Future<void>.delayed(const Duration(milliseconds: 1500)),
        job.cancelSignal.future,
      ]);
      if (!job.cancelRequested) {
        return _runTrackedAttempt(
          job,
          paths,
          liveArgs,
          firstByteTimeout: _metaLiveFirstByteTimeout,
        );
      }
    }

    return firstLive;
  }

  Future<YtDlpDownloadAttemptResult> _executeStandardDownload(
    _ActiveSingleJob job,
    WindowsToolPaths paths,
    List<String> args,
  ) async {
    final cachedJson = _inspectionRepository.getCachedRawJson(job.request.url);
    if (cachedJson != null) {
      final sep = Platform.pathSeparator;
      final infoFile = File(
        '${Directory.systemTemp.path}${sep}hyperdl_info_${job.jobId}.json',
      );
      try {
        await infoFile.writeAsString(cachedJson, flush: true);
        final cachedArgs = _ytDlpDataSource.buildDownloadArgsFromInfoJson(
          paths,
          job.request,
          job.outputTemplate,
          infoFile.path,
          isInstagram: false,
        );
        final res = await _runTrackedAttempt(job, paths, cachedArgs);
        if (res.succeeded || job.cancelRequested) {
          return res;
        }
        _inspectionRepository.evictCachedRawJson(job.request.url);
        _emitAnalyzingStage(
          job.jobId,
          'Cached analysis expired, refreshing video metadata...',
        );
      } finally {
        try {
          if (await infoFile.exists()) await infoFile.delete();
        } catch (_) {}
      }
    }

    if (job.cancelRequested) {
      return const YtDlpDownloadAttemptResult(
        stderrText: '',
        lastDownloaded: 0,
        lastEstimated: false,
        timedOut: false,
      );
    }

    return _runTrackedAttempt(job, paths, args);
  }

  Future<YtDlpDownloadAttemptResult> _runTrackedAttempt(
    _ActiveSingleJob job,
    WindowsToolPaths paths,
    List<String> args, {
    Duration? firstByteTimeout,
  }) {
    var lastDownloaded = 0;
    int? lastTotal;
    var lastEstimated = false;
    String? detectedPath;
    var receivedFirstByte = false;
    String? lastStageMsg;

    return _ytDlpDataSource.runDownloadAttempt(
      jobId: job.jobId,
      paths: paths,
      args: args,
      isCancelRequested: () => job.cancelRequested,
      cancelSignal: job.cancelSignal.future,
      onProcessAttached: (handle) {
        job.processHandle = handle;
      },
      onProcessDetached: () {
        job.processHandle = null;
      },
      firstByteTimeout: firstByteTimeout,
      onParsedLine: (parsed) {
        switch (parsed) {
          case ParsedStageStatus(:final message):
            if (!receivedFirstByte && lastStageMsg != message) {
              lastStageMsg = message;
              _emitAnalyzingStage(job.jobId, message);
            }
          case ParsedDownloadProgress(
            :final status,
            :final downloadedBytes,
            :final totalBytes,
            :final isTotalEstimated,
            :final speedBytesPerSec,
            :final etaSeconds,
          ):
            if (totalBytes != null) {
              lastTotal = totalBytes;
              lastEstimated = isTotalEstimated;
            }
            if (downloadedBytes == 0 && status != 'finished') {
              if (!receivedFirstByte &&
                  lastStageMsg != 'Connecting to media server...') {
                lastStageMsg = 'Connecting to media server...';
                _progressController.add(
                  DownloadProgressEvent(
                    jobId: job.jobId,
                    phase: DownloadPhase.analyzing,
                    downloadedBytes: 0,
                    totalBytes: lastTotal,
                    isTotalEstimated: lastEstimated,
                    outputPath: detectedPath,
                    message: 'Connecting to media server...',
                  ),
                );
              }
              return;
            }
            final effectiveDownloaded = downloadedBytes > 0
                ? downloadedBytes
                : (lastTotal ?? lastDownloaded);
            receivedFirstByte = true;
            lastDownloaded = effectiveDownloaded;
            _progressController.add(
              DownloadProgressEvent(
                jobId: job.jobId,
                phase: DownloadPhase.downloading,
                downloadedBytes: effectiveDownloaded,
                totalBytes: lastTotal,
                isTotalEstimated: lastEstimated,
                speedBytesPerSec: speedBytesPerSec,
                etaSeconds: etaSeconds,
                outputPath: detectedPath,
                message: status == 'finished'
                    ? 'Stream finished, finalizing...'
                    : null,
              ),
            );
          case ParsedPostprocessProgress(:final postprocessor):
            _progressController.add(
              DownloadProgressEvent(
                jobId: job.jobId,
                phase: DownloadPhase.merging,
                downloadedBytes: lastDownloaded,
                totalBytes: lastTotal,
                isTotalEstimated: lastEstimated,
                outputPath: detectedPath,
                message: 'Running $postprocessor with FFmpeg...',
              ),
            );
          case ParsedOutputPathDetected(:final path):
            detectedPath = path;
            if (!receivedFirstByte && lastStageMsg != 'Starting download...') {
              lastStageMsg = 'Starting download...';
              _emitAnalyzingStage(job.jobId, 'Starting download...');
            }
          case ParsedOtherLine():
            break;
        }
      },
    );
  }

  void _emitAnalyzingStage(String jobId, String message) {
    _progressController.add(
      DownloadProgressEvent(
        jobId: jobId,
        phase: DownloadPhase.analyzing,
        downloadedBytes: 0,
        isTotalEstimated: false,
        message: message,
      ),
    );
  }

  Future<void> dispose() async {
    await _progressController.close();
  }
}
