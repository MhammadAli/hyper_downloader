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

  @override
  String ping() => 'pong';

  @override
  String engineVersion() => '0.1.0';

  @override
  Future<MediaInspection> inspectMedia(String url) async {
    if (shouldFailInspection) {
      throw Exception('Simulated extraction failure');
    }
    return MediaInspection(
      id: 'aqz-KE-bpKQ',
      title: 'Big Buck Bunny 60fps 4K',
      uploader: 'Blender',
      durationSeconds: 635.0,
      thumbnailUrl: null,
      webpageUrl: url,
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

  group('Phase 2B MediaDownloadScreen UI', () {
    late FakeMediaDownloadRepository fakeRepo;

    setUp(() {
      fakeRepo = FakeMediaDownloadRepository();
    });

    tearDown(() async {
      await fakeRepo.dispose();
    });

    testWidgets(
      'inspects URL, displays genuine formats & sizes, downloads, cancels, and resumes',
      (WidgetTester tester) async {
        await tester.pumpWidget(HyperDownloadApp(repository: fakeRepo));
        await tester.pump();

        // Enter URL and tap Analyze.
        await tester.enterText(
          find.byKey(const Key('url_input_field')),
          'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
        );
        await tester.tap(find.byKey(const Key('analyze_url_button')));
        await tester.pumpAndSettle();

        // Verify metadata and genuine dynamic format details.
        expect(find.text('Big Buck Bunny 60fps 4K'), findsOneWidget);
        expect(find.text('Blender'), findsOneWidget);
        expect(find.text('Youtube'), findsOneWidget);
        expect(find.text('10:35'), findsOneWidget);

        expect(find.text('ID 139'), findsOneWidget);
        expect(find.text('3.69 MB (Exact)'), findsOneWidget);
        expect(find.text('ID 396'), findsOneWidget);
        expect(find.text('~14.69 MB (Estimated)'), findsOneWidget);
        expect(find.text('ID 18'), findsOneWidget);
        expect(find.text('Unknown size'), findsOneWidget);

        // Switch to Merge Video + Audio mode and verify FFmpeg pair selection.
        await tester.tap(find.text('Merge Video + Audio (FFmpeg)'));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('video_format_list')), findsOneWidget);
        expect(find.byKey(const Key('audio_format_list')), findsOneWidget);

        await tester.ensureVisible(
          find.byKey(const Key('start_download_button')),
        );
        await tester.tap(find.byKey(const Key('start_download_button')));
        await tester.pump();

        expect(
          fakeRepo.lastStartRequest?.selection.kind,
          DownloadSelectionKind.videoAndAudio,
        );
        expect(fakeRepo.lastStartRequest?.selection.videoFormatId, '396');
        expect(fakeRepo.lastStartRequest?.selection.audioFormatId, '139');

        // Stream live downloading metrics.
        fakeRepo.progressController.add(
          DownloadProgressEvent(
            jobId: 'fake-job-1',
            phase: DownloadPhase.downloading,
            downloadedBytes: BigInt.from(1048576),
            totalBytes: BigInt.from(15400000),
            isTotalEstimated: true,
            speedBytesPerSec: 1048576.0,
            etaSeconds: BigInt.from(14),
          ),
        );
        await tester.pump();

        expect(find.text('Downloading'), findsOneWidget);
        expect(find.text('Transferred: 1.00 MB / ~14.69 MB'), findsOneWidget);
        expect(find.text('Speed: 1.00 MB/s'), findsOneWidget);
        expect(find.text('ETA: 00:14'), findsOneWidget);

        // Cancel active download and confirm Resume becomes active after Canceled event.
        await tester.tap(find.byKey(const Key('cancel_download_button')));
        await tester.pump();
        expect(fakeRepo.lastCanceledJobId, 'fake-job-1');

        fakeRepo.progressController.add(
          DownloadProgressEvent(
            jobId: 'fake-job-1',
            phase: DownloadPhase.canceled,
            downloadedBytes: BigInt.from(1048576),
            totalBytes: BigInt.from(15400000),
            isTotalEstimated: true,
            message: 'Download canceled.',
          ),
        );
        await tester.pump();

        expect(find.text('Canceled'), findsOneWidget);

        await tester.tap(find.byKey(const Key('resume_download_button')));
        await tester.pump();
        expect(fakeRepo.lastResumedJobId, 'fake-job-1');
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
