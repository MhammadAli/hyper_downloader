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

void main() {
  setUpAll(() {
    registerFallbackValue(
      const StartDownloadRequest(
        url: 'https://example.com',
        selection: DownloadFormatSelection(kind: DownloadSelectionKind.single),
      ),
    );
  });

  group('MediaDownloadCubit', () {
    late MockMediaDownloadRepository repo;
    late StreamController<DownloadProgressEvent> progressController;

    setUp(() {
      repo = MockMediaDownloadRepository();
      progressController = StreamController<DownloadProgressEvent>.broadcast();

      when(() => repo.ping()).thenReturn('pong');
      when(() => repo.engineVersion()).thenReturn('0.1.0');
      when(
        () => repo.watchDownloadProgress(),
      ).thenAnswer((_) => progressController.stream);
    });

    tearDown(() async {
      await progressController.close();
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
      verify: (_) => verifyNever(() => repo.inspectMedia(any())),
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'analyzeUrl defaults to Video with Sound and selects top discovered option',
      build: () {
        when(
          () => repo.inspectMedia(any()),
        ).thenAnswer((_) async => _sampleInspection());
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
        when(
          () => repo.inspectMedia(any()),
        ).thenAnswer((_) async => _sampleInspection());
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
        when(
          () => repo.inspectMedia(any()),
        ).thenAnswer((_) async => _sampleInspection());
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
        when(
          () => repo.inspectMedia(any()),
        ).thenAnswer((_) async => _sampleInspection());
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
        when(
          () => repo.inspectMedia(any()),
        ).thenAnswer((_) async => _sampleInspection());
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
  });
}
