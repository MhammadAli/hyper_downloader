import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/media_download_cubit.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/features/media_download/media_download_state.dart';
import 'package:mocktail/mocktail.dart';

class MockMediaDownloadRepository extends Mock
    implements MediaDownloadRepository {}

MediaInspection _sampleInspection() {
  const audioMeta = AudioTrackMetadata(
    language: 'en-US',
    languageDisplayName: 'English (US)',
    isOriginal: true,
    isDefault: true,
    isAutoDub: false,
    selectionConfidence: AudioSelectionConfidence.confirmedOriginal,
    statusNote: 'Audio included automatically · Original: English (US)',
  );

  return MediaInspection(
    id: 'TsT1ntGyj4Q',
    title: 'Sample Multi-Audio Video',
    uploader: 'Test Creator',
    durationSeconds: 1448.0,
    thumbnailUrl: 'https://i.ytimg.com/vi/TsT1ntGyj4Q/hqdefault.jpg',
    webpageUrl: 'https://www.youtube.com/watch?v=TsT1ntGyj4Q',
    providerName: 'Youtube',
    originalAudio: audioMeta,
    videoOptions: [
      VideoQualityOption(
        resolution: '1080p',
        height: 1080,
        fps: 50,
        container: 'mp4',
        displaySize: '142.34 MB (Exact)',
        fileSizeBytes: BigInt.from(149254400),
        sizeAccuracy: FileSizeAccuracy.exact,
        videoFormatId: '299',
        selectedAudioFormatId: '140-19',
        audioLanguage: audioMeta,
        formatSelectionStrategy:
            FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
      ),
      VideoQualityOption(
        resolution: '360p',
        height: 360,
        fps: 30,
        container: 'mp4',
        displaySize: '~24.50 MB (Estimated)',
        fileSizeBytes: BigInt.from(25690112),
        sizeAccuracy: FileSizeAccuracy.estimated,
        videoFormatId: '18',
        selectedAudioFormatId: null,
        audioLanguage: audioMeta,
        formatSelectionStrategy: FormatSelectionStrategy.combinedAudioVideo,
      ),
    ],
    audioOptions: [
      AudioQualityOption(
        qualityLabel: 'Standard Quality (129 kbps)',
        container: 'm4a',
        bitrateKbps: 129.5,
        displaySize: '22.34 MB (Exact)',
        fileSizeBytes: BigInt.from(23427071),
        sizeAccuracy: FileSizeAccuracy.exact,
        formatId: '140-19',
        audioLanguage: audioMeta,
      ),
    ],
    formats: const [],
  );
}

PlaylistInspection _samplePlaylistInspection({
  String id = 'PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
  String title = 'Blender HQ',
}) {
  return PlaylistInspection(
    id: id,
    title: title,
    uploader: 'Blender',
    thumbnailUrl: 'https://i.ytimg.com/vi/abc/hqdefault.jpg',
    webpageUrl: 'https://www.youtube.com/playlist?list=$id',
    providerName: 'Youtube',
    totalItemCount: 3,
    entries: const [
      PlaylistEntrySummary(
        orderIndex: 0,
        videoId: 'vid0',
        title: 'First Talk',
        url: 'https://www.youtube.com/watch?v=vid0',
        uploader: 'Blender',
        durationSeconds: 120.0,
        availability: PlaylistEntryAvailability.available,
      ),
      PlaylistEntrySummary(
        orderIndex: 1,
        videoId: 'priv1',
        title: '[Private video]',
        url: 'https://www.youtube.com/watch?v=priv1',
        availability: PlaylistEntryAvailability.private,
        availabilityReason: 'Video is private.',
      ),
      PlaylistEntrySummary(
        orderIndex: 2,
        videoId: 'vid2',
        title: 'Third Talk',
        url: 'https://www.youtube.com/watch?v=vid2',
        uploader: 'Blender',
        durationSeconds: 95.0,
        availability: PlaylistEntryAvailability.available,
      ),
    ],
  );
}

PlaylistSessionSnapshot _samplePlaylistSnapshot({
  String sessionId = 'pl-session-1',
  PlaylistMediaMode mediaMode = PlaylistMediaMode.videoWithSound,
  PlaylistQualityCap qualityCap = PlaylistQualityCap.bestAvailable,
  bool isRunning = true,
  bool isPaused = false,
  int completedCount = 0,
  int failedCount = 0,
  int skippedCount = 1,
  List<PlaylistItemState>? items,
}) {
  return PlaylistSessionSnapshot(
    sessionId: sessionId,
    playlistId: 'PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
    playlistTitle: 'Blender HQ',
    playlistUrl:
        'https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
    uploader: 'Blender',
    outputDirectory:
        r'F:\Downloads\Blender HQ [PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB]',
    mediaMode: mediaMode,
    qualityCap: qualityCap,
    isRunning: isRunning,
    isPaused: isPaused,
    completedCount: completedCount,
    failedCount: failedCount,
    skippedCount: skippedCount,
    totalCount: 3,
    items:
        items ??
        [
          PlaylistItemState(
            orderIndex: 0,
            videoId: 'vid0',
            title: 'First Talk',
            url: 'https://www.youtube.com/watch?v=vid0',
            durationSeconds: 120.0,
            status: PlaylistItemStatus.pending,
            downloadedBytes: BigInt.zero,
            isTotalEstimated: false,
          ),
          PlaylistItemState(
            orderIndex: 1,
            videoId: 'priv1',
            title: '[Private video]',
            url: 'https://www.youtube.com/watch?v=priv1',
            status: PlaylistItemStatus.skipped,
            downloadedBytes: BigInt.zero,
            isTotalEstimated: false,
            errorMessage: 'Skipped: Video is private.',
          ),
          PlaylistItemState(
            orderIndex: 2,
            videoId: 'vid2',
            title: 'Third Talk',
            url: 'https://www.youtube.com/watch?v=vid2',
            durationSeconds: 95.0,
            status: PlaylistItemStatus.pending,
            downloadedBytes: BigInt.zero,
            isTotalEstimated: false,
          ),
        ],
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const StartDownloadRequest(
        url: 'https://example.com',
        selection: DownloadFormatSelection(kind: DownloadSelectionKind.single),
      ),
    );
    registerFallbackValue(
      StartPlaylistDownloadRequest(
        playlist: _samplePlaylistInspection(),
        mediaMode: PlaylistMediaMode.videoWithSound,
        qualityCap: PlaylistQualityCap.bestAvailable,
      ),
    );
    registerFallbackValue(
      EstimatePlaylistSizeRequest(
        playlist: _samplePlaylistInspection(),
        mediaMode: PlaylistMediaMode.videoWithSound,
        qualityCap: PlaylistQualityCap.bestAvailable,
      ),
    );
  });

  group('MediaDownloadCubit', () {
    late MockMediaDownloadRepository repo;
    late StreamController<DownloadProgressEvent> progressController;
    late StreamController<PlaylistProgressEvent> playlistProgressController;
    late StreamController<PlaylistSizeEstimate> sizeEstimateController;
    late StreamController<String> sharedUrlController;

    setUp(() {
      repo = MockMediaDownloadRepository();
      progressController = StreamController<DownloadProgressEvent>.broadcast();
      playlistProgressController =
          StreamController<PlaylistProgressEvent>.broadcast();
      sizeEstimateController =
          StreamController<PlaylistSizeEstimate>.broadcast();
      sharedUrlController = StreamController<String>.broadcast();

      when(() => repo.ping()).thenReturn('pong');
      when(() => repo.engineVersion()).thenReturn('0.1.0');
      when(
        () => repo.watchDownloadProgress(),
      ).thenAnswer((_) => progressController.stream);
      when(
        () => repo.watchPlaylistProgress(),
      ).thenAnswer((_) => playlistProgressController.stream);
      when(
        () => repo.watchPlaylistSizeEstimate(),
      ).thenAnswer((_) => sizeEstimateController.stream);
      when(
        () => repo.loadSavedPlaylistSession(
          playlistId: any(named: 'playlistId'),
          outputDirectory: any(named: 'outputDirectory'),
        ),
      ).thenAnswer((_) async => null);
      when(() => repo.estimatePlaylistSize(any())).thenAnswer((
        invocation,
      ) async {
        final req =
            invocation.positionalArguments.first as EstimatePlaylistSizeRequest;
        return PlaylistSizeEstimate(
          estimationId:
              'est-default-${req.mediaMode.name}-${req.qualityCap.name}',
          playlistId: req.playlist.id,
          mediaMode: req.mediaMode,
          qualityCap: req.qualityCap,
          status: PlaylistSizeStatus.estimated,
          knownTotalBytes: BigInt.from(15728640),
          totalEntriesCount: req.playlist.entries.length,
          unavailableCount: 1,
          eligibleCount: 2,
          inspectedCount: 2,
          exactCount: 0,
          estimatedCount: 2,
          unknownCount: 0,
          failedCount: 0,
          displaySummary: '~15.00 MB (Estimated)',
          statusMessage: '2 accessible video(s) (0 exact, 2 estimated/merged).',
          itemSizes: const [],
        );
      });
      when(
        () => repo.cancelPlaylistSizeEstimation(any()),
      ).thenAnswer((_) async {});
    });

    tearDown(() async {
      await progressController.close();
      await playlistProgressController.close();
      await sizeEstimateController.close();
      await sharedUrlController.close();
    });

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'initialize marks engine ready quietly when ping succeeds',
      build: () => MediaDownloadCubit(repository: repo),
      act: (cubit) => cubit.initialize(),
      expect: () => const [
        MediaDownloadState(isEngineReady: true, engineError: null),
      ],
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'analyzeUrl validates empty URL locally',
      build: () => MediaDownloadCubit(repository: repo)..initialize(),
      act: (cubit) => cubit.analyzeUrl('   '),
      expect: () => const [
        MediaDownloadState(isEngineReady: true, urlInput: '   '),
        MediaDownloadState(
          isEngineReady: true,
          urlInput: '   ',
          inspectionStatus: InspectionStatus.failure,
          inspectionError: 'Please paste or enter a media URL to analyze.',
        ),
      ],
      verify: (_) => verifyNever(() => repo.inspectUrl(any())),
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'analyzeUrl defaults to Video with Sound and selects top discovered option',
      build: () {
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.singleVideo,
            video: _sampleInspection(),
          ),
        );
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) =>
          cubit.analyzeUrl('https://www.youtube.com/watch?v=TsT1ntGyj4Q'),
      expect: () => [
        const MediaDownloadState(
          isEngineReady: true,
          urlInput: 'https://www.youtube.com/watch?v=TsT1ntGyj4Q',
        ),
        const MediaDownloadState(
          isEngineReady: true,
          urlInput: 'https://www.youtube.com/watch?v=TsT1ntGyj4Q',
          inspectionStatus: InspectionStatus.loading,
        ),
        MediaDownloadState(
          isEngineReady: true,
          urlInput: 'https://www.youtube.com/watch?v=TsT1ntGyj4Q',
          inspectionStatus: InspectionStatus.loaded,
          targetKind: InspectionTargetKind.singleVideo,
          inspection: _sampleInspection(),
          mediaMode: DownloadMediaMode.videoWithSound,
          selectedVideoFormatId: '299',
          selectedAudioOptionFormatId: '140-19',
        ),
      ],
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'startDownload internally pairs paired option with FFmpeg and emits completion',
      build: () {
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.singleVideo,
            video: _sampleInspection(),
          ),
        );
        when(() => repo.startDownload(any())).thenAnswer((_) async => 'job-42');
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) async {
        await cubit.analyzeUrl('https://www.youtube.com/watch?v=TsT1ntGyj4Q');
        await cubit.startDownload();

        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-42',
            phase: DownloadPhase.downloading,
            downloadedBytes: BigInt.from(1048576),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
            speedBytesPerSec: 524288.0,
            etaSeconds: BigInt.from(27),
          ),
        );
        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-42',
            phase: DownloadPhase.merging,
            downloadedBytes: BigInt.from(149254400),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
            message: 'Running Merger with FFmpeg...',
          ),
        );
        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-42',
            phase: DownloadPhase.completed,
            downloadedBytes: BigInt.from(149254400),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
            outputPath: r'C:\downloads\video.mp4',
            message: 'Download completed.',
          ),
        );
      },
      verify: (cubit) {
        final captured =
            verify(() => repo.startDownload(captureAny())).captured.single
                as StartDownloadRequest;
        expect(captured.selection.kind, DownloadSelectionKind.videoAndAudio);
        expect(captured.selection.videoFormatId, '299');
        expect(captured.selection.audioFormatId, '140-19');
        expect(captured.selection.mergeContainer, 'mp4');
        expect(cubit.state.latestProgress?.phase, DownloadPhase.completed);
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'uses single format internally for combined options and Audio Only mode',
      build: () {
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.singleVideo,
            video: _sampleInspection(),
          ),
        );
        when(() => repo.startDownload(any())).thenAnswer((_) async => 'job-77');
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) async {
        await cubit.analyzeUrl('https://www.youtube.com/watch?v=TsT1ntGyj4Q');
        cubit.selectVideoQuality('18');
        await cubit.startDownload();
        cubit.setMediaMode(DownloadMediaMode.audioOnly);
        await cubit.startDownload();
      },
      verify: (_) {
        final requests = verify(
          () => repo.startDownload(captureAny()),
        ).captured.cast<StartDownloadRequest>();
        expect(requests.length, 2);
        expect(requests[0].selection.kind, DownloadSelectionKind.single);
        expect(requests[0].selection.formatId, '18');
        expect(requests[1].selection.kind, DownloadSelectionKind.single);
        expect(requests[1].selection.formatId, '140-19');
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'pause marks state paused cleanly and resume clears paused state',
      build: () {
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.singleVideo,
            video: _sampleInspection(),
          ),
        );
        when(() => repo.startDownload(any())).thenAnswer((_) async => 'job-99');
        when(() => repo.cancelDownload('job-99')).thenAnswer((_) async {});
        when(
          () => repo.resumeDownload('job-99'),
        ).thenAnswer((_) async => 'job-99');
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) async {
        await cubit.analyzeUrl('https://www.youtube.com/watch?v=TsT1ntGyj4Q');
        await cubit.startDownload();

        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-99',
            phase: DownloadPhase.downloading,
            downloadedBytes: BigInt.from(512000),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
            speedBytesPerSec: 256000.0,
            etaSeconds: BigInt.from(13),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.canPause, isTrue);

        await cubit.pauseDownload();
        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-99',
            phase: DownloadPhase.canceled,
            downloadedBytes: BigInt.from(512000),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.isPaused, isTrue);
        expect(cubit.state.canResume, isTrue);

        await cubit.resumeDownload();
        expect(cubit.state.isPaused, isFalse);
      },
      verify: (_) {
        verify(() => repo.cancelDownload('job-99')).called(1);
        verify(() => repo.resumeDownload('job-99')).called(1);
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'cancelDownload keeps isPaused false',
      build: () {
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.singleVideo,
            video: _sampleInspection(),
          ),
        );
        when(() => repo.startDownload(any())).thenAnswer((_) async => 'job-88');
        when(() => repo.cancelDownload('job-88')).thenAnswer((_) async {});
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) async {
        await cubit.analyzeUrl('https://www.youtube.com/watch?v=TsT1ntGyj4Q');
        await cubit.startDownload();
        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-88',
            phase: DownloadPhase.downloading,
            downloadedBytes: BigInt.from(1000),
            totalBytes: BigInt.from(10000),
            isTotalEstimated: false,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await cubit.cancelDownload();
        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-88',
            phase: DownloadPhase.canceled,
            downloadedBytes: BigInt.from(1000),
            totalBytes: BigInt.from(10000),
            isTotalEstimated: false,
            message: 'Download canceled.',
          ),
        );
      },
      verify: (cubit) {
        expect(cubit.state.isPaused, isFalse);
        expect(cubit.state.latestProgress?.phase, DownloadPhase.canceled);
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'analyzeUrl detects playlist target and hydrates saved session preferences',
      build: () {
        final playlist = _samplePlaylistInspection();
        final saved = _samplePlaylistSnapshot(
          mediaMode: PlaylistMediaMode.audioOnly,
          qualityCap: PlaylistQualityCap.upTo720P,
          isRunning: false,
          isPaused: true,
        );
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.playlist,
            playlist: playlist,
          ),
        );
        when(
          () => repo.loadSavedPlaylistSession(
            playlistId: playlist.id,
            outputDirectory: any(named: 'outputDirectory'),
          ),
        ).thenAnswer((_) async => saved);
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) => cubit.analyzeUrl(
        'https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
      ),
      verify: (cubit) {
        expect(cubit.state.isPlaylistTarget, isTrue);
        expect(cubit.state.playlistInspection?.entries.length, 3);
        expect(cubit.state.playlistSession?.isPaused, isTrue);
        expect(cubit.state.playlistMediaMode, PlaylistMediaMode.audioOnly);
        expect(cubit.state.playlistQualityCap, PlaylistQualityCap.upTo720P);
        expect(cubit.state.canResumePlaylist, isTrue);
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'playlist workflow applies quality cap, streams item lifecycle + failure isolation, and supports pause/resume/cancel/retry',
      build: () {
        final playlist = _samplePlaylistInspection();
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.playlist,
            playlist: playlist,
          ),
        );
        when(() => repo.startPlaylistDownload(any())).thenAnswer(
          (_) async =>
              _samplePlaylistSnapshot(qualityCap: PlaylistQualityCap.upTo720P),
        );
        when(
          () => repo.pausePlaylistDownload('pl-session-1'),
        ).thenAnswer((_) async {});
        when(() => repo.resumePlaylistDownload('pl-session-1')).thenAnswer(
          (_) async => _samplePlaylistSnapshot(
            qualityCap: PlaylistQualityCap.upTo720P,
            isRunning: true,
            isPaused: false,
          ),
        );
        when(
          () => repo.cancelPlaylistDownload('pl-session-1'),
        ).thenAnswer((_) async {});
        when(() => repo.retryFailedPlaylistItems('pl-session-1')).thenAnswer(
          (_) async => _samplePlaylistSnapshot(
            qualityCap: PlaylistQualityCap.upTo720P,
            isRunning: true,
            isPaused: false,
            completedCount: 1,
            failedCount: 0,
            skippedCount: 1,
            items: [
              PlaylistItemState(
                orderIndex: 0,
                videoId: 'vid0',
                title: 'First Talk',
                url: 'https://www.youtube.com/watch?v=vid0',
                durationSeconds: 120.0,
                status: PlaylistItemStatus.completed,
                selectedQuality: '720p MP4',
                downloadedBytes: BigInt.from(10485760),
                totalBytes: BigInt.from(10485760),
                isTotalEstimated: false,
                outputPath: r'F:\Downloads\Blender HQ\001 - First Talk.mp4',
              ),
              PlaylistItemState(
                orderIndex: 1,
                videoId: 'priv1',
                title: '[Private video]',
                url: 'https://www.youtube.com/watch?v=priv1',
                status: PlaylistItemStatus.skipped,
                downloadedBytes: BigInt.zero,
                isTotalEstimated: false,
                errorMessage: 'Skipped: Video is private.',
              ),
              PlaylistItemState(
                orderIndex: 2,
                videoId: 'vid2',
                title: 'Third Talk',
                url: 'https://www.youtube.com/watch?v=vid2',
                durationSeconds: 95.0,
                status: PlaylistItemStatus.pending,
                downloadedBytes: BigInt.zero,
                isTotalEstimated: false,
              ),
            ],
          ),
        );
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) async {
        await cubit.analyzeUrl(
          'https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
        );
        cubit.setPlaylistQualityCap(PlaylistQualityCap.upTo720P);
        cubit.setPlaylistMediaMode(PlaylistMediaMode.videoWithSound);
        await cubit.startPlaylistDownload();

        playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-1',
            kind: PlaylistEventKind.playlistStarted,
            itemDownloadedBytes: BigInt.zero,
            itemIsTotalEstimated: false,
            completedCount: 0,
            failedCount: 0,
            skippedCount: 1,
            totalCount: 3,
            message: 'Playlist download started.',
          ),
        );
        playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-1',
            kind: PlaylistEventKind.playlistItemStarted,
            itemIndex: 0,
            itemStatus: PlaylistItemStatus.analyzing,
            selectedQuality: '720p MP4',
            itemDownloadedBytes: BigInt.zero,
            itemIsTotalEstimated: false,
            completedCount: 0,
            failedCount: 0,
            skippedCount: 1,
            totalCount: 3,
          ),
        );
        playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-1',
            kind: PlaylistEventKind.playlistItemProgress,
            itemIndex: 0,
            itemStatus: PlaylistItemStatus.downloading,
            selectedQuality: '720p MP4',
            itemDownloadedBytes: BigInt.from(5242880),
            itemTotalBytes: BigInt.from(10485760),
            itemIsTotalEstimated: false,
            speedBytesPerSec: 1048576.0,
            etaSeconds: BigInt.from(5),
            completedCount: 0,
            failedCount: 0,
            skippedCount: 1,
            totalCount: 3,
          ),
        );
        playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-1',
            kind: PlaylistEventKind.playlistItemMerging,
            itemIndex: 0,
            itemStatus: PlaylistItemStatus.merging,
            selectedQuality: '720p MP4',
            itemDownloadedBytes: BigInt.from(10485760),
            itemTotalBytes: BigInt.from(10485760),
            itemIsTotalEstimated: false,
            completedCount: 0,
            failedCount: 0,
            skippedCount: 1,
            totalCount: 3,
            message: 'Merging with FFmpeg...',
          ),
        );
        playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-1',
            kind: PlaylistEventKind.playlistItemCompleted,
            itemIndex: 0,
            itemStatus: PlaylistItemStatus.completed,
            selectedQuality: '720p MP4',
            itemDownloadedBytes: BigInt.from(10485760),
            itemTotalBytes: BigInt.from(10485760),
            itemIsTotalEstimated: false,
            outputPath: r'F:\Downloads\Blender HQ\001 - First Talk.mp4',
            completedCount: 1,
            failedCount: 0,
            skippedCount: 1,
            totalCount: 3,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.canPausePlaylist, isTrue);

        await cubit.pausePlaylistDownload();
        playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-1',
            kind: PlaylistEventKind.playlistPaused,
            itemIndex: 2,
            itemStatus: PlaylistItemStatus.canceled,
            itemDownloadedBytes: BigInt.zero,
            itemIsTotalEstimated: false,
            completedCount: 1,
            failedCount: 0,
            skippedCount: 1,
            totalCount: 3,
            message: 'Playlist paused.',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.isPlaylistPaused, isTrue);
        expect(cubit.state.canResumePlaylist, isTrue);

        await cubit.resumePlaylistDownload();
        playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-1',
            kind: PlaylistEventKind.playlistItemFailed,
            itemIndex: 2,
            itemStatus: PlaylistItemStatus.failed,
            itemDownloadedBytes: BigInt.zero,
            itemIsTotalEstimated: false,
            completedCount: 1,
            failedCount: 1,
            skippedCount: 1,
            totalCount: 3,
            message: 'Temporary failure',
          ),
        );
        playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-1',
            kind: PlaylistEventKind.playlistCompleted,
            itemDownloadedBytes: BigInt.zero,
            itemIsTotalEstimated: false,
            completedCount: 1,
            failedCount: 1,
            skippedCount: 1,
            totalCount: 3,
            message: 'Finished with 1 failed.',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.canRetryFailedPlaylist, isTrue);

        await cubit.retryFailedPlaylistItems();
        await cubit.cancelPlaylistDownload();
      },
      verify: (cubit) {
        final captured =
            verify(
                  () => repo.startPlaylistDownload(captureAny()),
                ).captured.single
                as StartPlaylistDownloadRequest;
        expect(captured.qualityCap, PlaylistQualityCap.upTo720P);
        expect(captured.mediaMode, PlaylistMediaMode.videoWithSound);
        verify(() => repo.pausePlaylistDownload('pl-session-1')).called(1);
        verify(() => repo.resumePlaylistDownload('pl-session-1')).called(1);
        verify(() => repo.retryFailedPlaylistItems('pl-session-1')).called(1);
        verify(() => repo.cancelPlaylistDownload('pl-session-1')).called(1);
        expect(
          cubit.state.playlistSession?.items[0].status,
          PlaylistItemStatus.completed,
        );
        expect(
          cubit.state.playlistSession?.items[0].outputPath,
          r'F:\Downloads\Blender HQ\001 - First Talk.mp4',
        );
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'dynamically recalculates playlist size on cap/mode changes and supports cancellation',
      build: () {
        final playlist = _samplePlaylistInspection();
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.playlist,
            playlist: playlist,
          ),
        );
        when(() => repo.estimatePlaylistSize(any())).thenAnswer((
          invocation,
        ) async {
          final req =
              invocation.positionalArguments.first
                  as EstimatePlaylistSizeRequest;
          if (req.mediaMode == PlaylistMediaMode.audioOnly) {
            return PlaylistSizeEstimate(
              estimationId: 'est-audio',
              playlistId: playlist.id,
              mediaMode: req.mediaMode,
              qualityCap: req.qualityCap,
              status: PlaylistSizeStatus.exact,
              knownTotalBytes: BigInt.from(4194304),
              totalEntriesCount: 3,
              unavailableCount: 1,
              eligibleCount: 2,
              inspectedCount: 2,
              exactCount: 2,
              estimatedCount: 0,
              unknownCount: 0,
              failedCount: 0,
              displaySummary: '4.00 MB (Exact)',
              itemSizes: const [],
            );
          }
          if (req.qualityCap == PlaylistQualityCap.upTo480P) {
            return PlaylistSizeEstimate(
              estimationId: 'est-480',
              playlistId: playlist.id,
              mediaMode: req.mediaMode,
              qualityCap: req.qualityCap,
              status: PlaylistSizeStatus.estimated,
              knownTotalBytes: BigInt.from(20971520),
              totalEntriesCount: 3,
              unavailableCount: 1,
              eligibleCount: 2,
              inspectedCount: 2,
              exactCount: 0,
              estimatedCount: 2,
              unknownCount: 0,
              failedCount: 0,
              displaySummary: '~20.00 MB (Estimated)',
              itemSizes: const [],
            );
          }
          return PlaylistSizeEstimate(
            estimationId: 'est-best',
            playlistId: playlist.id,
            mediaMode: req.mediaMode,
            qualityCap: req.qualityCap,
            status: PlaylistSizeStatus.calculating,
            knownTotalBytes: BigInt.zero,
            totalEntriesCount: 3,
            unavailableCount: 1,
            eligibleCount: 2,
            inspectedCount: 0,
            exactCount: 0,
            estimatedCount: 0,
            unknownCount: 0,
            failedCount: 0,
            displaySummary: 'Calculating playlist size...',
            statusMessage: 'Calculating sizes: 0 / 2 videos',
            itemSizes: const [],
          );
        });
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) async {
        await cubit.analyzeUrl(
          'https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.isCalculatingPlaylistSize, isTrue);

        await cubit.cancelPlaylistSizeEstimation();
        verify(() => repo.cancelPlaylistSizeEstimation('est-best')).called(1);

        cubit.setPlaylistQualityCap(PlaylistQualityCap.upTo480P);
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.playlistSizeEstimate?.displaySummary,
          '~20.00 MB (Estimated)',
        );

        cubit.setPlaylistMediaMode(PlaylistMediaMode.audioOnly);
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.playlistSizeEstimate?.status,
          PlaylistSizeStatus.exact,
        );
        expect(
          cubit.state.playlistSizeEstimate?.displaySummary,
          '4.00 MB (Exact)',
        );
      },
      verify: (_) {
        verify(() => repo.estimatePlaylistSize(any())).called(3);
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'auto-inspects initial cold-start shared URL when engine initializes',
      build: () {
        final video = _sampleInspection();
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.singleVideo,
            video: video,
          ),
        );
        return MediaDownloadCubit(
          repository: repo,
          getInitialSharedUrl: () async =>
              'https://www.youtube.com/watch?v=TsT1ntGyj4Q',
        );
      },
      act: (cubit) async {
        cubit.initialize();
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        verify(
          () => repo.inspectUrl('https://www.youtube.com/watch?v=TsT1ntGyj4Q'),
        ).called(1);
        expect(
          cubit.state.urlInput,
          'https://www.youtube.com/watch?v=TsT1ntGyj4Q',
        );
        expect(cubit.state.inspectionStatus, InspectionStatus.loaded);
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'auto-inspects warm-start shared playlist URL pushed over sharedUrls stream',
      build: () {
        final playlist = _samplePlaylistInspection();
        when(() => repo.inspectUrl(any())).thenAnswer(
          (_) async => UrlInspectionResult(
            kind: InspectionTargetKind.playlist,
            playlist: playlist,
          ),
        );
        return MediaDownloadCubit(
          repository: repo,
          sharedUrls: sharedUrlController.stream,
        );
      },
      act: (cubit) async {
        cubit.initialize();
        sharedUrlController.add(
          'https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        verify(
          () => repo.inspectUrl(
            'https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
          ),
        ).called(1);
        expect(cubit.state.targetKind, InspectionTargetKind.playlist);
        expect(
          cubit.state.playlistInspection?.id,
          'PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
        );
      },
    );
  });
}
