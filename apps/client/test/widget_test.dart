import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/bridge/api.dart';
import 'package:hyper_download_client/core/bridge/frb_generated.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/desktop_file_launcher.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/main.dart';

class FakeDesktopFileLauncher implements DesktopFileLauncher {
  String? lastOpenedFile;
  String? lastRevealedFile;

  @override
  Future<bool> openFile(String path) async {
    lastOpenedFile = path;
    return true;
  }

  @override
  Future<bool> revealInFolder(String path) async {
    lastRevealedFile = path;
    return true;
  }
}

class FakeMediaDownloadRepository implements MediaDownloadRepository {
  final StreamController<DownloadProgressEvent> progressController =
      StreamController<DownloadProgressEvent>.broadcast();

  StartDownloadRequest? lastStartRequest;
  String? lastCanceledJobId;
  String? lastResumedJobId;
  bool shouldFailInspection = false;
  bool returnMissingAudio = false;
  String sampleTitle = 'Multi-Audio Test Presentation';

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
      title: sampleTitle,
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
    'HyperDownloadApp initializes cleanly from Rust Debug DLL without pong badge',
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

      expect(find.text('HyperDownload'), findsOneWidget);
      expect(find.textContaining('pong'), findsNothing);
      expect(find.byKey(const Key('error_banner')), findsNothing);
      final scaffoldCtx = tester.element(find.byType(Scaffold));
      expect(Theme.of(scaffoldCtx).brightness, Brightness.dark);

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

  group('Phase 2C Refined Desktop MediaDownloadScreen UI', () {
    late FakeMediaDownloadRepository fakeRepo;
    late FakeDesktopFileLauncher fakeLauncher;

    setUp(() {
      fakeRepo = FakeMediaDownloadRepository();
      fakeLauncher = FakeDesktopFileLauncher();
    });

    tearDown(() async {
      await fakeRepo.dispose();
    });

    testWidgets(
      'supports Video with Sound default, Pause -> Resume, Audio Only, and Open Folder / File actions',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          HyperDownloadApp(repository: fakeRepo, fileLauncher: fakeLauncher),
        );
        await tester.pump();

        expect(find.textContaining('pong'), findsNothing);

        await tester.enterText(
          find.byKey(const Key('url_input_field')),
          'https://www.youtube.com/shorts/aqz-KE-bpKQ',
        );
        await tester.tap(find.byKey(const Key('analyze_url_button')));
        await tester.pumpAndSettle();

        expect(find.text('Multi-Audio Test Presentation'), findsOneWidget);
        expect(
          find.text('Audio included automatically · Original: English (US)'),
          findsOneWidget,
        );
        expect(find.text('Video with Sound'), findsOneWidget);
        expect(find.text('Audio Only'), findsOneWidget);
        expect(find.text('1080p'), findsOneWidget);
        expect(find.text('50 fps'), findsOneWidget);
        expect(find.text('142.34 MB (Exact)'), findsOneWidget);

        // Raw format IDs and codec details must stay hidden.
        expect(find.textContaining('299'), findsNothing);
        expect(find.textContaining('140-19'), findsNothing);
        expect(find.textContaining('avc1'), findsNothing);

        // Start download.
        await tester.ensureVisible(
          find.byKey(const Key('start_download_button')),
        );
        await tester.tap(find.byKey(const Key('start_download_button')));
        await tester.pump();

        // Stream live progress -> test Pause -> Paused -> Resume.
        fakeRepo.progressController.add(
          DownloadProgressEvent(
            jobId: 'fake-job-1',
            phase: DownloadPhase.downloading,
            downloadedBytes: BigInt.from(74627200),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
            speedBytesPerSec: 2097152.0,
            etaSeconds: BigInt.from(35),
          ),
        );
        await tester.pump();

        expect(find.text('Downloading'), findsOneWidget);
        expect(find.text('50%'), findsOneWidget);
        expect(find.text('Transferred: 71.17 MB / 142.34 MB'), findsOneWidget);

        await tester.tap(find.byKey(const Key('pause_download_button')));
        await tester.pump();
        expect(fakeRepo.lastCanceledJobId, 'fake-job-1');

        fakeRepo.progressController.add(
          DownloadProgressEvent(
            jobId: 'fake-job-1',
            phase: DownloadPhase.canceled,
            downloadedBytes: BigInt.from(74627200),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
          ),
        );
        await tester.pump();

        expect(find.text('Paused'), findsOneWidget);

        await tester.tap(find.byKey(const Key('resume_download_button')));
        await tester.pump();
        expect(fakeRepo.lastResumedJobId, 'fake-job-1');

        // Complete download and verify Open Folder / Open File actions.
        const savedPath =
            r'F:\Downloads\شفرة أمريكا - [TsT1ntGyj4Q] [299+140-19].mp4';
        fakeRepo.progressController.add(
          DownloadProgressEvent(
            jobId: 'fake-job-1',
            phase: DownloadPhase.completed,
            downloadedBytes: BigInt.from(149254400),
            totalBytes: BigInt.from(149254400),
            isTotalEstimated: false,
            outputPath: savedPath,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Completed'), findsOneWidget);
        expect(find.byKey(const Key('completed_file_panel')), findsOneWidget);

        await tester.ensureVisible(find.byKey(const Key('open_folder_button')));
        await tester.tap(find.byKey(const Key('open_folder_button')));
        await tester.pump();
        expect(fakeLauncher.lastRevealedFile, savedPath);

        await tester.tap(find.byKey(const Key('open_file_button')));
        await tester.pump();
        expect(fakeLauncher.lastOpenedFile, savedPath);

        // Switch to Audio Only mode cleanly.
        await tester.ensureVisible(find.text('Audio Only'));
        await tester.tap(find.text('Audio Only'));
        await tester.pumpAndSettle();

        expect(find.text('Standard Quality (129 kbps)'), findsOneWidget);
        expect(find.text('M4A'), findsOneWidget);
        expect(find.text('22.34 MB (Exact)'), findsOneWidget);
      },
    );

    testWidgets(
      'renders long Arabic titles and narrow resized windows without overflow',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(460, 760);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        fakeRepo.sampleTitle =
            'شفرة أمريكا: لماذا يرتعب الأمريكي من الإجازة أو المرض - وهم الحلم الأمريكي الطويل جدا للاختبار';

        await tester.pumpWidget(
          HyperDownloadApp(repository: fakeRepo, fileLauncher: fakeLauncher),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('url_input_field')),
          'https://www.youtube.com/watch?v=TsT1ntGyj4Q',
        );
        await tester.tap(find.byKey(const Key('analyze_url_button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('شفرة أمريكا'), findsOneWidget);
      },
    );

    testWidgets(
      'displays clear unavailable message when audio track is missing',
      (WidgetTester tester) async {
        fakeRepo.returnMissingAudio = true;
        await tester.pumpWidget(
          HyperDownloadApp(repository: fakeRepo, fileLauncher: fakeLauncher),
        );
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
      await tester.pumpWidget(
        HyperDownloadApp(repository: fakeRepo, fileLauncher: fakeLauncher),
      );
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
