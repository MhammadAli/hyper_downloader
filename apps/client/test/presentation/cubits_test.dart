import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/core/platform/platform_intent_service.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';
import 'package:hyper_download_client/domain/repositories/media_inspection_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_download_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_session_repository.dart';
import 'package:hyper_download_client/domain/repositories/single_download_repository.dart';
import 'package:hyper_download_client/domain/usecases/estimate_playlist_size_usecase.dart';
import 'package:hyper_download_client/domain/usecases/inspect_url_usecase.dart';
import 'package:hyper_download_client/domain/usecases/manage_playlist_download_usecase.dart';
import 'package:hyper_download_client/domain/usecases/manage_single_download_usecase.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_state.dart';

class FakeInspectionRepository implements MediaInspectionRepository {
  Future<UrlInspectionResult> Function(String url)? onInspectUrl;
  final Set<String> audioOnlyKeys = {};

  @override
  Future<UrlInspectionResult> inspectUrl(String url) async {
    if (onInspectUrl != null) return onInspectUrl!(url);
    throw UnimplementedError();
  }

  @override
  Future<MediaInspection> inspectMedia(String url) => throw UnimplementedError();

  @override
  Future<PlaylistInspection> inspectPlaylist(String url) =>
      throw UnimplementedError();

  @override
  bool isRegisteredAudioOnlyFormat(String url, String formatId) =>
      audioOnlyKeys.contains('$url::$formatId');
}

class FakeSessionRepository implements PlaylistSessionRepository {
  PlaylistSessionSnapshot? saved;

  @override
  Future<PlaylistSessionSnapshot?> loadSavedSession({
    required String playlistId,
    String? outputDirectory,
  }) async => saved;

  @override
  Future<void> saveSession({
    required String playlistDirectory,
    required PlaylistSessionSnapshot snapshot,
  }) async {
    saved = snapshot;
  }
}

class FakeSingleDownloadRepository implements SingleDownloadRepository {
  final StreamController<DownloadProgressEvent> controller =
      StreamController<DownloadProgressEvent>.broadcast();
  StartDownloadRequest? lastRequest;
  String? lastCanceledJobId;
  String? lastResumedJobId;

  @override
  Future<String> startDownload(StartDownloadRequest request) async {
    lastRequest = request;
    return 'job-1';
  }

  @override
  Future<void> cancelDownload(String jobId) async {
    lastCanceledJobId = jobId;
    controller.add(
      DownloadProgressEvent(
        jobId: jobId,
        phase: DownloadPhase.canceled,
        downloadedBytes: 5000,
        totalBytes: 10000,
        isTotalEstimated: false,
      ),
    );
  }

  @override
  Future<String> resumeDownload(String jobId) async {
    lastResumedJobId = jobId;
    return jobId;
  }

  @override
  Stream<DownloadProgressEvent> watchDownloadProgress() => controller.stream;
}

class FakePlaylistDownloadRepository implements PlaylistDownloadRepository {
  final StreamController<PlaylistProgressEvent> progressController =
      StreamController<PlaylistProgressEvent>.broadcast();
  final StreamController<PlaylistSizeEstimate> sizeController =
      StreamController<PlaylistSizeEstimate>.broadcast();

  StartPlaylistDownloadRequest? lastStartRequest;
  String? pausedSessionId;
  String? resumedSessionId;
  String? canceledSessionId;
  String? retriedSessionId;
  String? canceledEstimationId;
  PlaylistSessionSnapshot? snapshotToReturn;
  PlaylistSizeEstimate? sizeEstimateToReturn;
  int _estSeq = 0;

  @override
  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  ) async {
    lastStartRequest = request;
    return snapshotToReturn!;
  }

  @override
  Future<void> pausePlaylistDownload(String sessionId) async {
    pausedSessionId = sessionId;
  }

  @override
  Future<PlaylistSessionSnapshot> resumePlaylistDownload(
    String sessionId,
  ) async {
    resumedSessionId = sessionId;
    return snapshotToReturn!;
  }

  @override
  Future<void> cancelPlaylistDownload(String sessionId) async {
    canceledSessionId = sessionId;
  }

  @override
  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(
    String sessionId,
  ) async {
    retriedSessionId = sessionId;
    return snapshotToReturn!;
  }

  @override
  Stream<PlaylistProgressEvent> watchPlaylistProgress() =>
      progressController.stream;

  @override
  Future<PlaylistSizeEstimate> estimatePlaylistSize(
    EstimatePlaylistSizeRequest request,
  ) async {
    final base = sizeEstimateToReturn!;
    final id = 'est-${++_estSeq}';
    return PlaylistSizeEstimate(
      estimationId: id,
      playlistId: base.playlistId,
      mediaMode: base.mediaMode,
      qualityCap: base.qualityCap,
      status: base.status,
      knownTotalBytes: base.knownTotalBytes,
      totalEntriesCount: base.totalEntriesCount,
      unavailableCount: base.unavailableCount,
      eligibleCount: base.eligibleCount,
      inspectedCount: base.inspectedCount,
      exactCount: base.exactCount,
      estimatedCount: base.estimatedCount,
      unknownCount: base.unknownCount,
      failedCount: base.failedCount,
      displaySummary: base.displaySummary,
      statusMessage: base.statusMessage,
      itemSizes: base.itemSizes,
    );
  }

  @override
  Future<void> cancelPlaylistSizeEstimation(String estimationId) async {
    canceledEstimationId = estimationId;
  }

  @override
  Stream<PlaylistSizeEstimate> watchPlaylistSizeEstimate() =>
      sizeController.stream;
}

MediaInspection sampleMedia() => const MediaInspection(
  id: 'vid1',
  title: 'Sample Video',
  uploader: 'Creator',
  durationSeconds: 180,
  webpageUrl: 'https://www.youtube.com/watch?v=vid1',
  providerName: 'YouTube',
  videoOptions: [
    VideoQualityOption(
      resolution: '1080p',
      height: 1080,
      container: 'mp4',
      displaySize: '100 MB',
      fileSizeBytes: 104857600,
      sizeAccuracy: FileSizeAccuracy.exact,
      videoFormatId: '137',
      selectedAudioFormatId: '140',
      formatSelectionStrategy:
          FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
    ),
  ],
  audioOptions: [
    AudioQualityOption(
      qualityLabel: '128 kbps',
      container: 'm4a',
      bitrateKbps: 128,
      displaySize: '5 MB',
      fileSizeBytes: 5242880,
      sizeAccuracy: FileSizeAccuracy.exact,
      formatId: '140',
    ),
  ],
  formats: [],
);

void main() {
  group('UrlInspectorCubit', () {
    test('inspects single video and enriches playlist with saved session', () async {
      final inspectRepo = FakeInspectionRepository();
      final sessionRepo = FakeSessionRepository();
      final intentSvc = PlatformIntentService(
        getInitialSharedUrl: () async => null,
        sharedUrls: const Stream.empty(),
      );

      inspectRepo.onInspectUrl = (url) async => UrlInspectionResult(
        kind: InspectionTargetKind.singleVideo,
        video: sampleMedia(),
      );

      final cubit = UrlInspectorCubit(
        inspectUrlUseCase: InspectUrlUseCase(
          inspectionRepository: inspectRepo,
          sessionRepository: sessionRepo,
        ),
        platformRegistry: const PlatformRegistry(),
        intentService: intentSvc,
      );
      addTearDown(cubit.close);

      cubit.initialize();
      await cubit.analyzeUrl('https://www.youtube.com/watch?v=vid1');

      expect(cubit.state.inspectionStatus, InspectionStatus.loaded);
      expect(cubit.state.targetKind, InspectionTargetKind.singleVideo);
      expect(cubit.state.lastResult?.video?.title, 'Sample Video');
    });

    test('sets failure status on InvalidUrlException and supports cancel', () async {
      final inspectRepo = FakeInspectionRepository();
      final completer = Completer<UrlInspectionResult>();
      inspectRepo.onInspectUrl = (url) {
        if (url.contains('instagram.com')) return completer.future;
        throw const InvalidUrlException('Invalid URL format.');
      };

      final cubit = UrlInspectorCubit(
        inspectUrlUseCase: InspectUrlUseCase(
          inspectionRepository: inspectRepo,
          sessionRepository: FakeSessionRepository(),
        ),
        platformRegistry: const PlatformRegistry(),
        intentService: PlatformIntentService(
          getInitialSharedUrl: () async => null,
          sharedUrls: const Stream.empty(),
        ),
      );
      addTearDown(cubit.close);

      await cubit.analyzeUrl('not a valid url');
      expect(cubit.state.inspectionStatus, InspectionStatus.failure);
      expect(cubit.state.inspectionError, isNotEmpty);

      final pending = cubit.analyzeUrl('https://www.instagram.com/reel/C8x123/');
      expect(cubit.state.isAnalyzing, isTrue);
      expect(cubit.state.analysisStatusText, contains('Instagram'));
      cubit.cancelAnalysis();
      expect(cubit.state.isAnalyzing, isFalse);

      completer.completeError(const ProcessExecutionException('late'));
      await pending;
      expect(cubit.state.inspectionStatus, InspectionStatus.initial);
    });
  });

  group('SingleDownloadCubit', () {
    test('starts, pauses, resumes, and tracks progress with int bytes', () async {
      final repo = FakeSingleDownloadRepository();
      final cubit = SingleDownloadCubit(ManageSingleDownloadUseCase(repo));
      addTearDown(() async {
        await cubit.close();
        await repo.controller.close();
      });

      cubit.initialize();
      cubit.loadInspection(sampleMedia());
      expect(cubit.state.selectedVideoFormatId, '137');

      await cubit.startDownload();
      expect(cubit.state.activeJobId, 'job-1');
      expect(repo.lastRequest?.selection.kind, DownloadSelectionKind.videoAndAudio);

      repo.controller.add(
        const DownloadProgressEvent(
          jobId: 'job-1',
          phase: DownloadPhase.downloading,
          downloadedBytes: 5000,
          totalBytes: 10000,
          isTotalEstimated: false,
          speedBytesPerSec: 1000,
          etaSeconds: 5,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.canPause, isTrue);

      await cubit.pauseDownload();
      await Future<void>.delayed(Duration.zero);
      expect(repo.lastCanceledJobId, 'job-1');
      expect(cubit.state.isPaused, isTrue);

      await cubit.resumeDownload();
      expect(repo.lastResumedJobId, 'job-1');
      expect(cubit.state.isPaused, isFalse);
    });
  });

  group('PlaylistDownloadCubit', () {
    test('manages playlist size estimation and batch download progress', () async {
      final repo = FakePlaylistDownloadRepository();
      const playlist = PlaylistInspection(
        id: 'PL1',
        title: 'Clean List',
        webpageUrl: 'https://www.youtube.com/playlist?list=PL1',
        providerName: 'YouTube',
        totalItemCount: 1,
        entries: [
          PlaylistEntrySummary(
            orderIndex: 1,
            videoId: 'v1',
            title: 'Ep 1',
            url: 'https://www.youtube.com/watch?v=v1',
            availability: PlaylistEntryAvailability.available,
          ),
        ],
      );
      repo.snapshotToReturn = const PlaylistSessionSnapshot(
        sessionId: 'ps-1',
        playlistId: 'PL1',
        playlistTitle: 'Clean List',
        playlistUrl: 'https://www.youtube.com/playlist?list=PL1',
        outputDirectory: r'C:\Downloads\Clean List',
        mediaMode: PlaylistMediaMode.videoWithSound,
        qualityCap: PlaylistQualityCap.bestAvailable,
        isRunning: true,
        isPaused: false,
        completedCount: 0,
        failedCount: 0,
        skippedCount: 0,
        totalCount: 1,
        items: [
          PlaylistItemState(
            orderIndex: 1,
            videoId: 'v1',
            title: 'Ep 1',
            url: 'https://www.youtube.com/watch?v=v1',
            status: PlaylistItemStatus.pending,
            downloadedBytes: 0,
            isTotalEstimated: false,
          ),
        ],
      );
      repo.sizeEstimateToReturn = const PlaylistSizeEstimate(
        estimationId: 'est-1',
        playlistId: 'PL1',
        mediaMode: PlaylistMediaMode.videoWithSound,
        qualityCap: PlaylistQualityCap.bestAvailable,
        status: PlaylistSizeStatus.calculating,
        knownTotalBytes: 0,
        totalEntriesCount: 1,
        unavailableCount: 0,
        eligibleCount: 1,
        inspectedCount: 0,
        exactCount: 0,
        estimatedCount: 0,
        unknownCount: 0,
        failedCount: 0,
        displaySummary: 'Calculating...',
        itemSizes: [],
      );

      final cubit = PlaylistDownloadCubit(
        managePlaylistUseCase: ManagePlaylistDownloadUseCase(repo),
        estimateSizeUseCase: EstimatePlaylistSizeUseCase(repo),
      );
      addTearDown(() async {
        await cubit.close();
        await repo.progressController.close();
        await repo.sizeController.close();
      });

      cubit.initialize();
      await cubit.loadPlaylist(playlist);

      await cubit.estimatePlaylistSize();
      expect(cubit.state.isCalculatingPlaylistSize, isTrue);
      final activeEstId = cubit.state.playlistSizeEstimate!.estimationId;

      repo.sizeController.add(
        PlaylistSizeEstimate(
          estimationId: activeEstId,
          playlistId: 'PL1',
          mediaMode: PlaylistMediaMode.videoWithSound,
          qualityCap: PlaylistQualityCap.bestAvailable,
          status: PlaylistSizeStatus.exact,
          knownTotalBytes: 2048,
          totalEntriesCount: 1,
          unavailableCount: 0,
          eligibleCount: 1,
          inspectedCount: 1,
          exactCount: 1,
          estimatedCount: 0,
          unknownCount: 0,
          failedCount: 0,
          displaySummary: '2.0 KB exact',
          itemSizes: [],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.playlistSizeEstimate?.status, PlaylistSizeStatus.exact);

      await cubit.startPlaylistDownload();
      expect(cubit.state.playlistSession?.sessionId, 'ps-1');
    });
  });
}
