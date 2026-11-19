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
  final StreamController<PlaylistProgressEvent> playlistProgressController =
      StreamController<PlaylistProgressEvent>.broadcast();

  StartDownloadRequest? lastStartRequest;
  String? lastCanceledJobId;
  String? lastResumedJobId;
  StartPlaylistDownloadRequest? lastPlaylistRequest;
  String? lastPausedPlaylistId;
  String? lastResumedPlaylistId;
  String? lastCanceledPlaylistId;
  String? lastRetriedPlaylistId;
  bool shouldFailInspection = false;
  bool returnMissingAudio = false;
  String sampleTitle = 'Multi-Audio Test Presentation';
  String samplePlaylistTitle = 'Blender HQ Tutorials';
  String samplePlaylistFirstItemTitle = 'Episode One';

  @override
  String ping() => 'pong';

  @override
  String engineVersion() => '0.1.0';

  @override
  Future<UrlInspectionResult> inspectUrl(String url) async {
    if (shouldFailInspection) {
      throw Exception('Simulated extraction failure');
    }

    if (url.contains('playlist?list=')) {
      return UrlInspectionResult(
        kind: InspectionTargetKind.playlist,
        playlist: PlaylistInspection(
          id: 'PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
          title: samplePlaylistTitle,
          uploader: 'Blender Foundation',
          thumbnailUrl: null,
          webpageUrl: url,
          providerName: 'Youtube',
          totalItemCount: 3,
          entries: [
            PlaylistEntrySummary(
              orderIndex: 0,
              videoId: 'vid0',
              title: samplePlaylistFirstItemTitle,
              url: 'https://www.youtube.com/watch?v=vid0',
              uploader: 'Blender Foundation',
              durationSeconds: 95.0,
              availability: PlaylistEntryAvailability.available,
            ),
            const PlaylistEntrySummary(
              orderIndex: 1,
              videoId: 'priv1',
              title: '[Private video]',
              url: 'https://www.youtube.com/watch?v=priv1',
              availability: PlaylistEntryAvailability.private,
              availabilityReason: 'Private video is inaccessible.',
            ),
            const PlaylistEntrySummary(
              orderIndex: 2,
              videoId: 'vid2',
              title: 'Episode Two',
              url: 'https://www.youtube.com/watch?v=vid2',
              uploader: 'Blender Foundation',
              durationSeconds: 140.0,
              availability: PlaylistEntryAvailability.available,
            ),
          ],
        ),
      );
    }

    final single = await inspectMedia(url);
    return UrlInspectionResult(
      kind: InspectionTargetKind.singleVideo,
      video: single,
    );
  }

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

  @override
  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  ) async {
    lastPlaylistRequest = request;
    return PlaylistSessionSnapshot(
      sessionId: 'pl-session-fake',
      playlistId: request.playlist.id,
      playlistTitle: request.playlist.title,
      playlistUrl: request.playlist.webpageUrl,
      uploader: request.playlist.uploader,
      thumbnailUrl: request.playlist.thumbnailUrl,
      outputDirectory:
          r'F:\Downloads\Blender HQ Tutorials [PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB]',
      mediaMode: request.mediaMode,
      qualityCap: request.qualityCap,
      isRunning: true,
      isPaused: false,
      completedCount: 0,
      failedCount: 0,
      skippedCount: 1,
      totalCount: request.playlist.totalItemCount,
      items: request.playlist.entries
          .map(
            (e) => PlaylistItemState(
              orderIndex: e.orderIndex,
              videoId: e.videoId,
              title: e.title,
              url: e.url,
              durationSeconds: e.durationSeconds,
              status: e.availability == PlaylistEntryAvailability.available
                  ? PlaylistItemStatus.pending
                  : PlaylistItemStatus.skipped,
              downloadedBytes: BigInt.zero,
              isTotalEstimated: false,
              errorMessage: e.availabilityReason,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<void> pausePlaylistDownload(String sessionId) async {
    lastPausedPlaylistId = sessionId;
  }

  @override
  Future<PlaylistSessionSnapshot> resumePlaylistDownload(
    String sessionId,
  ) async {
    lastResumedPlaylistId = sessionId;
    return startPlaylistDownload(lastPlaylistRequest!);
  }

  @override
  Future<void> cancelPlaylistDownload(String sessionId) async {
    lastCanceledPlaylistId = sessionId;
  }

  @override
  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(
    String sessionId,
  ) async {
    lastRetriedPlaylistId = sessionId;
    return startPlaylistDownload(lastPlaylistRequest!);
  }

  @override
  Future<PlaylistSessionSnapshot?> loadSavedPlaylistSession({
    required String playlistId,
    String? outputDirectory,
  }) async => null;

  @override
  Stream<PlaylistProgressEvent> watchPlaylistProgress() =>
      playlistProgressController.stream;

  Future<void> dispose() async {
    await progressController.close();
    await playlistProgressController.close();
  }
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

    testWidgets(
      'supports full playlist workflow: mode, quality caps, skipped items, live progress without overall ETA, failure retry, pause/resume/cancel, and folder actions',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          HyperDownloadApp(repository: fakeRepo, fileLauncher: fakeLauncher),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('url_input_field')),
          'https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
        );
        await tester.tap(find.byKey(const Key('analyze_url_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('playlist_header_card')), findsOneWidget);
        expect(find.text('Blender HQ Tutorials'), findsOneWidget);
        expect(find.text('3 items'), findsOneWidget);
        expect(find.text('1 unavailable'), findsOneWidget);
        expect(find.text('Skipped'), findsOneWidget);
        expect(find.byKey(const Key('playlist_items_card')), findsOneWidget);

        // Verify default mode & quality cap chips, toggle Audio Only and back.
        expect(find.text('Best Available'), findsOneWidget);
        expect(find.text('Up to 1080p'), findsOneWidget);
        expect(find.text('Up to 720p'), findsOneWidget);
        expect(find.text('Up to 480p'), findsOneWidget);

        await tester.tap(find.text('Audio Only'));
        await tester.pumpAndSettle();
        expect(find.text('Up to 720p'), findsNothing);

        await tester.tap(find.text('Video with Sound'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Up to 720p'));
        await tester.pump();

        // Start playlist download.
        await tester.ensureVisible(
          find.byKey(const Key('start_playlist_button')),
        );
        await tester.tap(find.byKey(const Key('start_playlist_button')));
        await tester.pumpAndSettle();

        expect(
          fakeRepo.lastPlaylistRequest?.qualityCap,
          PlaylistQualityCap.upTo720P,
        );
        expect(
          find.byKey(const Key('playlist_overall_progress')),
          findsOneWidget,
        );
        expect(find.text('0 / 3 completed'), findsOneWidget);

        // Active item progress & completion (no raw format IDs, no overall playlist ETA).
        const item0Path =
            r'F:\Downloads\Blender HQ Tutorials [PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB]\001 - Episode One.mp4';
        fakeRepo.playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-fake',
            kind: PlaylistEventKind.playlistItemProgress,
            itemIndex: 0,
            itemStatus: PlaylistItemStatus.downloading,
            selectedQuality: '720p MP4',
            audioLanguage: const AudioTrackMetadata(
              language: 'en',
              languageDisplayName: 'English',
              isOriginal: true,
              isDefault: true,
              isAutoDub: false,
              selectionConfidence: AudioSelectionConfidence.confirmedOriginal,
              statusNote: 'Audio included automatically · Original: English',
            ),
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
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('playlist_active_item_panel')),
          findsOneWidget,
        );
        expect(find.text('Quality: 720p MP4'), findsOneWidget);
        expect(find.text('Item ETA: 00:05'), findsOneWidget);
        expect(find.textContaining('Overall ETA'), findsNothing);
        expect(find.textContaining('140-19'), findsNothing);

        // Pause -> Resume controls.
        await tester.tap(find.byKey(const Key('pause_playlist_button')));
        await tester.pump();
        expect(fakeRepo.lastPausedPlaylistId, 'pl-session-fake');

        fakeRepo.playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-fake',
            kind: PlaylistEventKind.playlistPaused,
            itemIndex: 0,
            itemStatus: PlaylistItemStatus.canceled,
            itemDownloadedBytes: BigInt.from(5242880),
            itemTotalBytes: BigInt.from(10485760),
            itemIsTotalEstimated: false,
            completedCount: 0,
            failedCount: 0,
            skippedCount: 1,
            totalCount: 3,
            message: 'Playlist paused.',
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('resume_playlist_button')));
        await tester.pump();
        expect(fakeRepo.lastResumedPlaylistId, 'pl-session-fake');

        // Item 0 completes; Item 2 fails -> Retry Failed becomes enabled.
        fakeRepo.playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-fake',
            kind: PlaylistEventKind.playlistItemCompleted,
            itemIndex: 0,
            itemStatus: PlaylistItemStatus.completed,
            selectedQuality: '720p MP4',
            itemDownloadedBytes: BigInt.from(10485760),
            itemTotalBytes: BigInt.from(10485760),
            itemIsTotalEstimated: false,
            outputPath: item0Path,
            completedCount: 1,
            failedCount: 0,
            skippedCount: 1,
            totalCount: 3,
          ),
        );
        fakeRepo.playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-fake',
            kind: PlaylistEventKind.playlistItemFailed,
            itemIndex: 2,
            itemStatus: PlaylistItemStatus.failed,
            itemDownloadedBytes: BigInt.zero,
            itemIsTotalEstimated: false,
            completedCount: 1,
            failedCount: 1,
            skippedCount: 1,
            totalCount: 3,
            message: 'Network timeout',
          ),
        );
        fakeRepo.playlistProgressController.add(
          PlaylistProgressEvent(
            sessionId: 'pl-session-fake',
            kind: PlaylistEventKind.playlistCompleted,
            itemDownloadedBytes: BigInt.zero,
            itemIsTotalEstimated: false,
            completedCount: 1,
            failedCount: 1,
            skippedCount: 1,
            totalCount: 3,
            message: 'Batch finished with 1 failed.',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('1 / 3 completed'), findsOneWidget);
        expect(find.text('1 failed'), findsOneWidget);
        expect(find.text('Network timeout'), findsOneWidget);

        // Reveal overall playlist folder & item folder.
        await tester.ensureVisible(
          find.byKey(const Key('playlist_open_folder_button')),
        );
        await tester.tap(find.byKey(const Key('playlist_open_folder_button')));
        await tester.pump();
        expect(
          fakeLauncher.lastRevealedFile,
          r'F:\Downloads\Blender HQ Tutorials [PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB]',
        );

        await tester.ensureVisible(
          find.byKey(const Key('playlist_item_folder_0')),
        );
        await tester.tap(find.byKey(const Key('playlist_item_folder_0')));
        await tester.pump();
        expect(fakeLauncher.lastRevealedFile, item0Path);

        // Trigger Retry Failed -> then Cancel.
        await tester.ensureVisible(
          find.byKey(const Key('retry_failed_playlist_button')),
        );
        await tester.tap(find.byKey(const Key('retry_failed_playlist_button')));
        await tester.pumpAndSettle();
        expect(fakeRepo.lastRetriedPlaylistId, 'pl-session-fake');

        await tester.tap(find.byKey(const Key('cancel_playlist_button')));
        await tester.pump();
        expect(fakeRepo.lastCanceledPlaylistId, 'pl-session-fake');
      },
    );

    testWidgets(
      'renders long Arabic RTL playlist and item titles in narrow 460px windows without overflow',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(460, 760);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        fakeRepo.samplePlaylistTitle =
            'قائمة تشغيل تعليمية شاملة باللغة العربية لتعلم البرمجة وتطوير التطبيقات الحديثة خطوة بخطوة';
        fakeRepo.samplePlaylistFirstItemTitle =
            'الدرس الأول: شرح كامل ومفصل لكيفية التعامل مع قوائم التشغيل الطويلة باللغة العربية دون أي مشاكل';

        await tester.pumpWidget(
          HyperDownloadApp(repository: fakeRepo, fileLauncher: fakeLauncher),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('url_input_field')),
          'https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB',
        );
        await tester.tap(find.byKey(const Key('analyze_url_button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('قائمة تشغيل تعليمية'), findsOneWidget);
        expect(find.textContaining('الدرس الأول'), findsOneWidget);
      },
    );
  });
}
