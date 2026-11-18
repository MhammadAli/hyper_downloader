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
  return MediaInspection(
    id: 'aqz-KE-bpKQ',
    title: 'Big Buck Bunny 60fps 4K',
    uploader: 'Blender',
    durationSeconds: 635.0,
    thumbnailUrl: 'https://i.ytimg.com/vi_webp/aqz-KE-bpKQ/maxresdefault.webp',
    webpageUrl: 'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
    providerName: 'Youtube',
    formats: [
      DiscoveredFormat(
        formatId: '139',
        container: 'm4a',
        streamKind: StreamKind.audioOnly,
        resolution: 'audio only',
        acodec: 'mp4a.40.5',
        bitrateKbps: 48.8,
        fileSizeBytes: BigInt.from(3871021),
        sizeAccuracy: FileSizeAccuracy.exact,
      ),
      DiscoveredFormat(
        formatId: '396',
        container: 'mp4',
        streamKind: StreamKind.videoOnly,
        resolution: '640x360',
        width: 640,
        height: 360,
        fps: 30,
        vcodec: 'av01.0.01M.08',
        bitrateKbps: 200.5,
        fileSizeBytes: BigInt.from(15400000),
        sizeAccuracy: FileSizeAccuracy.estimated,
      ),
      DiscoveredFormat(
        formatId: '18',
        container: 'mp4',
        streamKind: StreamKind.muxedAudioVideo,
        resolution: '640x360',
        width: 640,
        height: 360,
        fps: 30,
        vcodec: 'avc1.42001E',
        acodec: 'mp4a.40.2',
        sizeAccuracy: FileSizeAccuracy.unknown,
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
      'initialize checks ping/version and sets ready status',
      build: () => MediaDownloadCubit(repository: repo),
      act: (cubit) => cubit.initialize(),
      expect: () => const [MediaDownloadState(engineStatus: 'pong (v0.1.0)')],
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'analyzeUrl validates empty URL locally',
      build: () => MediaDownloadCubit(repository: repo)..initialize(),
      act: (cubit) => cubit.analyzeUrl('   '),
      expect: () => const [
        MediaDownloadState(engineStatus: 'pong (v0.1.0)', urlInput: '   '),
        MediaDownloadState(
          engineStatus: 'pong (v0.1.0)',
          urlInput: '   ',
          inspectionStatus: InspectionStatus.failure,
          inspectionError: 'Please paste or enter a media URL to analyze.',
        ),
      ],
      verify: (_) => verifyNever(() => repo.inspectMedia(any())),
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'analyzeUrl loads genuine formats and selects non-hardcoded defaults',
      build: () {
        when(
          () => repo.inspectMedia(any()),
        ).thenAnswer((_) async => _sampleInspection());
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) =>
          cubit.analyzeUrl('https://www.youtube.com/watch?v=aqz-KE-bpKQ'),
      expect: () => [
        const MediaDownloadState(
          engineStatus: 'pong (v0.1.0)',
          urlInput: 'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
        ),
        const MediaDownloadState(
          engineStatus: 'pong (v0.1.0)',
          urlInput: 'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
          inspectionStatus: InspectionStatus.loading,
        ),
        MediaDownloadState(
          engineStatus: 'pong (v0.1.0)',
          urlInput: 'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
          inspectionStatus: InspectionStatus.loaded,
          inspection: _sampleInspection(),
          selectedSingleFormatId: '18',
          selectedVideoFormatId: '396',
          selectedAudioFormatId: '139',
        ),
      ],
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'startDownload with merged video+audio emits progress through merging to completed',
      build: () {
        when(
          () => repo.inspectMedia(any()),
        ).thenAnswer((_) async => _sampleInspection());
        when(() => repo.startDownload(any())).thenAnswer((_) async => 'job-42');
        return MediaDownloadCubit(repository: repo)..initialize();
      },
      act: (cubit) async {
        await cubit.analyzeUrl('https://www.youtube.com/watch?v=aqz-KE-bpKQ');
        cubit.setSelectionMode(SelectionMode.mergeVideoAudio);
        await cubit.startDownload();

        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-42',
            phase: DownloadPhase.downloading,
            downloadedBytes: BigInt.from(1048576),
            totalBytes: BigInt.from(15400000),
            isTotalEstimated: true,
            speedBytesPerSec: 524288.0,
            etaSeconds: BigInt.from(27),
          ),
        );
        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-42',
            phase: DownloadPhase.merging,
            downloadedBytes: BigInt.from(15400000),
            totalBytes: BigInt.from(15400000),
            isTotalEstimated: true,
            message: 'Running Merger with FFmpeg...',
          ),
        );
        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-42',
            phase: DownloadPhase.completed,
            downloadedBytes: BigInt.from(19273475),
            totalBytes: BigInt.from(19273475),
            isTotalEstimated: false,
            outputPath: r'C:\downloads\bunny.mp4',
            message: 'Download completed.',
          ),
        );
      },
      verify: (cubit) {
        final captured =
            verify(() => repo.startDownload(captureAny())).captured.single
                as StartDownloadRequest;
        expect(captured.selection.kind, DownloadSelectionKind.videoAndAudio);
        expect(captured.selection.videoFormatId, '396');
        expect(captured.selection.audioFormatId, '139');
        expect(captured.selection.mergeContainer, 'mp4');

        expect(cubit.state.latestProgress?.phase, DownloadPhase.completed);
        expect(
          cubit.state.latestProgress?.outputPath,
          r'C:\downloads\bunny.mp4',
        );
      },
    );

    blocTest<MediaDownloadCubit, MediaDownloadState>(
      'cancel and resume invoke repository with active job ID',
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
        await cubit.analyzeUrl('https://www.youtube.com/watch?v=aqz-KE-bpKQ');
        cubit.selectSingleFormat('139');
        await cubit.startDownload();

        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-99',
            phase: DownloadPhase.downloading,
            downloadedBytes: BigInt.from(512000),
            totalBytes: BigInt.from(3871021),
            isTotalEstimated: false,
            speedBytesPerSec: 256000.0,
            etaSeconds: BigInt.from(13),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.canCancel, isTrue);

        await cubit.cancelDownload();
        progressController.add(
          DownloadProgressEvent(
            jobId: 'job-99',
            phase: DownloadPhase.canceled,
            downloadedBytes: BigInt.from(512000),
            totalBytes: BigInt.from(3871021),
            isTotalEstimated: false,
            message: 'Download canceled.',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.canResume, isTrue);

        await cubit.resumeDownload();
      },
      verify: (_) {
        verify(() => repo.cancelDownload('job-99')).called(1);
        verify(() => repo.resumeDownload('job-99')).called(1);
      },
    );
  });
}
