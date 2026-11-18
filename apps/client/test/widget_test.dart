import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/bridge/api.dart';
import 'package:hyper_download_client/core/bridge/frb_generated.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/main.dart';

class FakeMediaDownloadRepository implements MediaDownloadRepository {
  final StreamController<DownloadProgressEvent> progressController =
      StreamController<DownloadProgressEvent>.broadcast();

  StartDownloadRequest? lastStartRequest;
  String? lastCanceledJobId;
  String? lastResumedJobId;
  bool shouldFailInspection = false;
  bool returnMissingAudio = false;

  @override
  String ping() => 'pong';

  @override
  String engineVersion() => '0.1.0';

  @override
  Future<MediaInspection> inspectMedia(String url) async {
    if (shouldFailInspection) {
      throw Exception('Simulated extraction failure');
    }

    if (returnMissingAudio) {
      return MediaInspection(
        id: 'silent-1',
        title: 'Silent Test Video',
        uploader: 'Creator',
        durationSeconds: 120.0,
        thumbnailUrl: null,
        webpageUrl: url,
        providerName: 'Youtube',
        originalAudio: null,
        videoOptions: const [],
        audioOptions: const [],
        formats: const [],
      );
    }

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
      title: 'Multi-Audio Test Presentation',
      uploader: 'Channel Author',
      durationSeconds: 1448.0,
      thumbnailUrl: null,
      webpageUrl: url,
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

  @override
  Future<String> startDownload(StartDownloadRequest request) async {
    lastStartRequest = request;
    return 'fake-job-1';
  }

  @override
  Future<void> cancelDownload(String jobId) async {
    lastCanceledJobId = jobId;
  }

  @override
  Future<String> resumeDownload(String jobId) async {
    lastResumedJobId = jobId;
    return jobId;
  }

  @override
  Stream<DownloadProgressEvent> watchDownloadProgress() =>
      progressController.stream;

  Future<void> dispose() => progressController.close();
}

void main() {
  test(
    'Flutter-to-Rust Debug DLL responds to ping and engineVersion',
    () async {
      final debugDll = File('../../rust/target/debug/engine_ffi.dll');
      expect(debugDll.existsSync(), isTrue);

      await RustLib.init(
        externalLibrary: ExternalLibrary.open(debugDll.absolute.path),
      );

      expect(ping(), 'pong');
      expect(engineVersion(), '0.1.0');

      RustLib.dispose();
    },
  );

  testWidgets(
    'HyperDownloadApp renders ping and engineVersion from Rust Debug DLL',
    (WidgetTester tester) async {
      final debugDll = File('../../rust/target/debug/engine_ffi.dll');
      expect(debugDll.existsSync(), isTrue);

      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(debugDll.absolute.path),
        );
      });

      await tester.pumpWidget(const HyperDownloadApp());
      await tester.pump();

      expect(find.text('Rust: pong (v0.1.0)'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      RustLib.dispose();
    },
  );

  test(
    'Flutter-to-Rust Release DLL responds to ping and engineVersion',
    () async {
      final releaseDll = File('../../rust/target/release/engine_ffi.dll');
      expect(releaseDll.existsSync(), isTrue);

      await RustLib.init(
        externalLibrary: ExternalLibrary.open(releaseDll.absolute.path),
      );

      expect(ping(), 'pong');
      expect(engineVersion(), '0.1.0');

      RustLib.dispose();
    },
  );

  group('Simplified IDM-Style MediaDownloadScreen UI', () {
    late FakeMediaDownloadRepository fakeRepo;

    setUp(() {
      fakeRepo = FakeMediaDownloadRepository();
    });

    tearDown(() async {
      await fakeRepo.dispose();
    });

    testWidgets(
      'shows clean Video with Sound cards without raw format IDs, switches to Audio Only, downloads, cancels, and resumes',
      (WidgetTester tester) async {
        await tester.pumpWidget(HyperDownloadApp(repository: fakeRepo));
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('url_input_field')),
          'https://www.youtube.com/watch?v=TsT1ntGyj4Q',
        );
        await tester.tap(find.byKey(const Key('analyze_url_button')));
        await tester.pumpAndSettle();

        // Metadata + concise original audio note.
        expect(find.text('Multi-Audio Test Presentation'), findsOneWidget);
        expect(
          find.text('Audio included automatically · Original: English (US)'),
          findsOneWidget,
        );

        // Default mode is Video with Sound showing clean quality cards.
        expect(find.text('Video with Sound'), findsOneWidget);
        expect(find.text('Audio Only'), findsOneWidget);
        expect(find.text('1080p'), findsOneWidget);
        expect(find.text('50 fps'), findsOneWidget);
        expect(find.text('142.34 MB (Exact)'), findsOneWidget);
        expect(find.text('360p'), findsOneWidget);
        expect(find.text('~24.50 MB (Estimated)'), findsOneWidget);

        // Technical format IDs, codec strings, and separate dub lists must be hidden.
        expect(find.textContaining('299'), findsNothing);
        expect(find.textContaining('140-19'), findsNothing);
        expect(find.textContaining('avc1'), findsNothing);

        // Start download of selected 1080p quality (internally triggers paired video+audio MP4 merge).
        await tester.ensureVisible(
          find.byKey(const Key('start_download_button')),
        );
        await tester.tap(find.byKey(const Key('start_download_button')));
        await tester.pump();

        expect(
          fakeRepo.lastStartRequest?.selection.kind,
          DownloadSelectionKind.videoAndAudio,
        );
        expect(fakeRepo.lastStartRequest?.selection.videoFormatId, '299');
        expect(fakeRepo.lastStartRequest?.selection.audioFormatId, '140-19');
        expect(fakeRepo.lastStartRequest?.selection.mergeContainer, 'mp4');

        // Live progress metrics, cancel, and resume.
        fakeRepo.progressController.add(
          DownloadProgressEvent(
            jobId: 'fake-job-1',
            phase: DownloadPhase.downloading,
            downloadedBytes: BigInt.from(1048576),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
            speedBytesPerSec: 1048576.0,
            etaSeconds: BigInt.from(14),
          ),
        );
        await tester.pump();

        expect(find.text('Downloading'), findsOneWidget);
        expect(find.text('Transferred: 1.00 MB / 142.34 MB'), findsOneWidget);

        await tester.tap(find.byKey(const Key('cancel_download_button')));
        await tester.pump();
        expect(fakeRepo.lastCanceledJobId, 'fake-job-1');

        fakeRepo.progressController.add(
          DownloadProgressEvent(
            jobId: 'fake-job-1',
            phase: DownloadPhase.canceled,
            downloadedBytes: BigInt.from(1048576),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
          ),
        );
        await tester.pump();

        expect(find.text('Canceled'), findsOneWidget);
        await tester.tap(find.byKey(const Key('resume_download_button')));
        await tester.pump();
        expect(fakeRepo.lastResumedJobId, 'fake-job-1');

        // Switch to Audio Only mode and verify curated original-track audio cards.
        fakeRepo.progressController.add(
          DownloadProgressEvent(
            jobId: 'fake-job-1',
            phase: DownloadPhase.completed,
            downloadedBytes: BigInt.from(149254400),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
          ),
        );
        await tester.pump();

        await tester.ensureVisible(find.text('Audio Only'));
        await tester.tap(find.text('Audio Only'));
        await tester.pumpAndSettle();

        expect(find.text('Standard Quality (129 kbps)'), findsOneWidget);
        expect(find.text('M4A'), findsOneWidget);
        expect(find.text('22.34 MB (Exact)'), findsOneWidget);
      },
    );

    testWidgets(
      'displays clear unavailable message when audio track is missing',
      (WidgetTester tester) async {
        fakeRepo.returnMissingAudio = true;
        await tester.pumpWidget(HyperDownloadApp(repository: fakeRepo));
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('url_input_field')),
          'https://example.com/silent',
        );
        await tester.tap(find.byKey(const Key('analyze_url_button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('empty_video_options_message')),
          findsOneWidget,
        );
      },
    );

    testWidgets('shows error banner when URL analysis fails', (
      WidgetTester tester,
    ) async {
      fakeRepo.shouldFailInspection = true;
      await tester.pumpWidget(HyperDownloadApp(repository: fakeRepo));
      await tester.pump();

      await tester.enterText(
        find.byKey(const Key('url_input_field')),
        'https://www.youtube.com/watch?v=invalid',
      );
      await tester.tap(find.byKey(const Key('analyze_url_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('error_banner')), findsOneWidget);
      expect(
        find.textContaining('Simulated extraction failure'),
        findsOneWidget,
      );
    });
  });
}
