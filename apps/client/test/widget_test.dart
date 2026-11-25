import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_desktop_file_launcher.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/repositories/file_launcher_repository.dart';
import 'package:hyper_download_client/domain/repositories/media_inspection_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_download_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_session_repository.dart';
import 'package:hyper_download_client/domain/repositories/single_download_repository.dart';
import 'package:hyper_download_client/main.dart';

class _TestInspectionRepo implements MediaInspectionRepository {
  Future<UrlInspectionResult> Function(String url)? onInspectUrl;

  @override
  Future<UrlInspectionResult> inspectUrl(String url) async {
    if (onInspectUrl != null) return onInspectUrl!(url);
    throw const InvalidUrlException('Unconfigured inspection stub');
  }

  @override
  Future<MediaInspection> inspectMedia(String url) => throw UnimplementedError();

  @override
  Future<PlaylistInspection> inspectPlaylist(String url) =>
      throw UnimplementedError();

  @override
  bool isRegisteredAudioOnlyFormat(String url, String formatId) => false;
}

class _TestSessionRepo implements PlaylistSessionRepository {
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

class _TestSingleDownloadRepo implements SingleDownloadRepository {
  final StreamController<DownloadProgressEvent> controller =
      StreamController<DownloadProgressEvent>.broadcast();
  StartDownloadRequest? lastRequest;
  String? canceledJobId;
  String? resumedJobId;

  @override
  Future<String> startDownload(StartDownloadRequest request) async {
    lastRequest = request;
    return 'dl-1';
  }

  @override
  Future<void> cancelDownload(String jobId) async {
    canceledJobId = jobId;
    controller.add(
      DownloadProgressEvent(
        jobId: jobId,
        phase: DownloadPhase.canceled,
        downloadedBytes: 52428800,
        totalBytes: 104857600,
        isTotalEstimated: false,
      ),
    );
  }

  @override
  Future<String> resumeDownload(String jobId) async {
    resumedJobId = jobId;
    return jobId;
  }

  @override
  Stream<DownloadProgressEvent> watchDownloadProgress() => controller.stream;
}

class _TestPlaylistDownloadRepo implements PlaylistDownloadRepository {
  final StreamController<PlaylistProgressEvent> progressController =
      StreamController<PlaylistProgressEvent>.broadcast();
  final StreamController<PlaylistSizeEstimate> sizeController =
      StreamController<PlaylistSizeEstimate>.broadcast();

  StartPlaylistDownloadRequest? lastRequest;
  PlaylistSessionSnapshot? snapshotToReturn;
  PlaylistSizeEstimate? estimateToReturn;
  String? pausedSessionId;
  String? resumedSessionId;

  @override
  Future<PlaylistSessionSnapshot> startPlaylistDownload(
    StartPlaylistDownloadRequest request,
  ) async {
    lastRequest = request;
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
  Future<void> cancelPlaylistDownload(String sessionId) async {}

  @override
  Future<PlaylistSessionSnapshot> retryFailedPlaylistItems(
    String sessionId,
  ) async => snapshotToReturn!;

  @override
  Stream<PlaylistProgressEvent> watchPlaylistProgress() =>
      progressController.stream;

  @override
  Future<PlaylistSizeEstimate> estimatePlaylistSize(
    EstimatePlaylistSizeRequest request,
  ) async => estimateToReturn!;

  @override
  Future<void> cancelPlaylistSizeEstimation(String estimationId) async {}

  @override
  Stream<PlaylistSizeEstimate> watchPlaylistSizeEstimate() =>
      sizeController.stream;
}

class _TestFileLauncher implements FileLauncherRepository {
  String? openedPath;
  String? revealedPath;

  @override
  Future<bool> openFile(String path) async {
    openedPath = path;
    return true;
  }

  @override
  Future<bool> revealInFolder(String path) async {
    revealedPath = path;
    return true;
  }

  @override
  Future<bool> shareFile(String path) async => true;
}

MediaInspection _videoInspection({
  String id = 'vid1',
  String title = 'Flutter Clean Architecture Demo',
  String provider = 'YouTube',
  bool silent = false,
}) {
  return MediaInspection(
    id: id,
    title: title,
    uploader: 'Hyper Channel',
    durationSeconds: 185,
    webpageUrl: 'https://www.youtube.com/watch?v=$id',
    providerName: provider,
    videoOptions: [
      VideoQualityOption(
        resolution: '1080p',
        height: 1080,
        container: 'mp4',
        displaySize: '120.0 MB',
        fileSizeBytes: 125829120,
        sizeAccuracy: FileSizeAccuracy.exact,
        videoFormatId: '137',
        selectedAudioFormatId: silent ? null : '140',
        formatSelectionStrategy: silent
            ? FormatSelectionStrategy.combinedAudioVideo
            : FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
      ),
    ],
    audioOptions: silent
        ? const []
        : const [
            AudioQualityOption(
              qualityLabel: '128 kbps',
              container: 'm4a',
              bitrateKbps: 128,
              displaySize: '5.0 MB',
              fileSizeBytes: 5242880,
              sizeAccuracy: FileSizeAccuracy.exact,
              formatId: '140',
            ),
          ],
    formats: const [],
  );
}

void main() {
  testWidgets('single video analyze, download, pause, resume, and complete', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final inspectRepo = _TestInspectionRepo();
    final sessionRepo = _TestSessionRepo();
    final singleRepo = _TestSingleDownloadRepo();
    final playlistRepo = _TestPlaylistDownloadRepo();
    final launcher = _TestFileLauncher();
    addTearDown(() async {
      await singleRepo.controller.close();
      await playlistRepo.progressController.close();
      await playlistRepo.sizeController.close();
    });

    inspectRepo.onInspectUrl = (_) async => UrlInspectionResult(
      kind: InspectionTargetKind.singleVideo,
      video: _videoInspection(),
    );

    await tester.pumpWidget(
      HyperDownloadApp(
        inspectionRepository: inspectRepo,
        playlistSessionRepository: sessionRepo,
        singleDownloadRepository: singleRepo,
        playlistDownloadRepository: playlistRepo,
        fileLauncher: launcher,
        getInitialSharedUrl: () async => null,
        sharedUrls: const Stream.empty(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('url_input_field')),
      'https://www.youtube.com/watch?v=vid1',
    );
    await tester.tap(find.byKey(const Key('analyze_url_button')));
    await tester.pumpAndSettle();

    expect(find.text('Flutter Clean Architecture Demo'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start_download_button')));
    await tester.pump();
    expect(singleRepo.lastRequest, isNotNull);

    singleRepo.controller.add(
      const DownloadProgressEvent(
        jobId: 'dl-1',
        phase: DownloadPhase.downloading,
        downloadedBytes: 52428800,
        totalBytes: 104857600,
        isTotalEstimated: false,
        speedBytesPerSec: 2097152,
        etaSeconds: 25,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('download_progress_bar')), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pause_download_button')));
    await tester.pump();
    expect(singleRepo.canceledJobId, 'dl-1');

    await tester.tap(find.byKey(const Key('resume_download_button')));
    await tester.pump();
    expect(singleRepo.resumedJobId, 'dl-1');

    singleRepo.controller.add(
      const DownloadProgressEvent(
        jobId: 'dl-1',
        phase: DownloadPhase.completed,
        downloadedBytes: 104857600,
        totalBytes: 104857600,
        isTotalEstimated: false,
        outputPath: r'C:\Downloads\Demo.mp4',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('100%'), findsOneWidget);
    expect(find.text('Download Again'), findsOneWidget);
  });

  testWidgets('narrow 460px Arabic RTL layout and error banner render cleanly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(460, 840));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final inspectRepo = _TestInspectionRepo();
    final sessionRepo = _TestSessionRepo();
    final singleRepo = _TestSingleDownloadRepo();
    final playlistRepo = _TestPlaylistDownloadRepo();
    final launcher = _TestFileLauncher();
    addTearDown(() async {
      await singleRepo.controller.close();
      await playlistRepo.progressController.close();
      await playlistRepo.sizeController.close();
    });

    inspectRepo.onInspectUrl = (url) async {
      if (url.contains('bad')) {
        throw const InvalidUrlException('Invalid media link provided.');
      }
      return UrlInspectionResult(
        kind: InspectionTargetKind.singleVideo,
        video: _videoInspection(
          id: 'rtl1',
          title: 'شرح معمارية التطبيقات النظيفة بالكامل',
          silent: true,
        ),
      );
    };

    await tester.pumpWidget(
      HyperDownloadApp(
        inspectionRepository: inspectRepo,
        playlistSessionRepository: sessionRepo,
        singleDownloadRepository: singleRepo,
        playlistDownloadRepository: playlistRepo,
        fileLauncher: launcher,
        getInitialSharedUrl: () async => null,
        sharedUrls: const Stream.empty(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('url_input_field')),
      'https://bad.example.com/x',
    );
    await tester.tap(find.byKey(const Key('analyze_url_button')));
    await tester.pumpAndSettle();
    expect(find.text('Invalid media link provided.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('url_input_field')),
      'https://www.youtube.com/watch?v=rtl1',
    );
    await tester.tap(find.byKey(const Key('analyze_url_button')));
    await tester.pumpAndSettle();

    expect(
      find.text('شرح معمارية التطبيقات النظيفة بالكامل'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Instagram loading state can cancel and warm-start shared URL works', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final inspectRepo = _TestInspectionRepo();
    final sessionRepo = _TestSessionRepo();
    final singleRepo = _TestSingleDownloadRepo();
    final playlistRepo = _TestPlaylistDownloadRepo();
    final launcher = _TestFileLauncher();
    final sharedController = StreamController<String>.broadcast();
    final completer = Completer<UrlInspectionResult>();

    addTearDown(() async {
      await sharedController.close();
      await singleRepo.controller.close();
      await playlistRepo.progressController.close();
      await playlistRepo.sizeController.close();
    });

    inspectRepo.onInspectUrl = (url) {
      if (url.contains('instagram.com')) return completer.future;
      return Future.value(
        UrlInspectionResult(
          kind: InspectionTargetKind.singleVideo,
          video: _videoInspection(id: 'shared1', title: 'Shared Video'),
        ),
      );
    };

    await tester.pumpWidget(
      HyperDownloadApp(
        inspectionRepository: inspectRepo,
        playlistSessionRepository: sessionRepo,
        singleDownloadRepository: singleRepo,
        playlistDownloadRepository: playlistRepo,
        fileLauncher: launcher,
        getInitialSharedUrl: () async => null,
        sharedUrls: sharedController.stream,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('url_input_field')),
      'https://www.instagram.com/reel/C8x123/',
    );
    await tester.tap(find.byKey(const Key('analyze_url_button')));
    await tester.pump();

    expect(find.byKey(const Key('analysis_status_text')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel_analysis_button')));
    await tester.pump();
    completer.completeError(const ProcessExecutionException('canceled'));
    await tester.pumpAndSettle();

    sharedController.add('https://www.youtube.com/watch?v=shared1');
    await tester.pumpAndSettle();
    expect(find.text('Shared Video'), findsOneWidget);
  });

  testWidgets('playlist inspection triggers size estimation and batch download', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final inspectRepo = _TestInspectionRepo();
    final sessionRepo = _TestSessionRepo();
    final singleRepo = _TestSingleDownloadRepo();
    final playlistRepo = _TestPlaylistDownloadRepo();
    final launcher = _TestFileLauncher();
    addTearDown(() async {
      await singleRepo.controller.close();
      await playlistRepo.progressController.close();
      await playlistRepo.sizeController.close();
    });

    const playlist = PlaylistInspection(
      id: 'PL_UI',
      title: 'Architecture Series',
      webpageUrl: 'https://www.youtube.com/playlist?list=PL_UI',
      providerName: 'YouTube',
      totalItemCount: 1,
      entries: [
        PlaylistEntrySummary(
          orderIndex: 1,
          videoId: 'v1',
          title: 'Part 1 - Domain',
          url: 'https://www.youtube.com/watch?v=v1',
          availability: PlaylistEntryAvailability.available,
        ),
      ],
    );

    playlistRepo.estimateToReturn = const PlaylistSizeEstimate(
      estimationId: 'est-ui',
      playlistId: 'PL_UI',
      mediaMode: PlaylistMediaMode.videoWithSound,
      qualityCap: PlaylistQualityCap.bestAvailable,
      status: PlaylistSizeStatus.exact,
      knownTotalBytes: 10485760,
      totalEntriesCount: 1,
      unavailableCount: 0,
      eligibleCount: 1,
      inspectedCount: 1,
      exactCount: 1,
      estimatedCount: 0,
      unknownCount: 0,
      failedCount: 0,
      displaySummary: '10.0 MB exact across 1 item',
      itemSizes: [],
    );

    playlistRepo.snapshotToReturn = const PlaylistSessionSnapshot(
      sessionId: 'sess-ui',
      playlistId: 'PL_UI',
      playlistTitle: 'Architecture Series',
      playlistUrl: 'https://www.youtube.com/playlist?list=PL_UI',
      outputDirectory: r'C:\Downloads\Architecture Series',
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
          title: 'Part 1 - Domain',
          url: 'https://www.youtube.com/watch?v=v1',
          status: PlaylistItemStatus.pending,
          downloadedBytes: 0,
          isTotalEstimated: false,
        ),
      ],
    );

    inspectRepo.onInspectUrl = (_) async => const UrlInspectionResult(
      kind: InspectionTargetKind.playlist,
      playlist: playlist,
    );

    await tester.pumpWidget(
      HyperDownloadApp(
        inspectionRepository: inspectRepo,
        playlistSessionRepository: sessionRepo,
        singleDownloadRepository: singleRepo,
        playlistDownloadRepository: playlistRepo,
        fileLauncher: launcher,
        getInitialSharedUrl: () async => null,
        sharedUrls: const Stream.empty(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('url_input_field')),
      'https://www.youtube.com/playlist?list=PL_UI',
    );
    await tester.tap(find.byKey(const Key('analyze_url_button')));
    await tester.pumpAndSettle();

    expect(find.text('Architecture Series'), findsOneWidget);
    expect(find.byKey(const Key('playlist_size_summary_card')), findsOneWidget);
    expect(find.text('10.0 MB exact across 1 item'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start_playlist_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('playlist_overall_progress')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pause_playlist_button')));
    await tester.pump();
    expect(playlistRepo.pausedSessionId, 'sess-ui');
  });

  if (Platform.isWindows) {
    test('Win32 PIDL helper handles existing and missing paths cleanly', () async {
      final tempDir = await Directory.systemTemp.createTemp('hyperdl_pidl_');
      addTearDown(() => tempDir.delete(recursive: true));
      final existing = File('${tempDir.path}\\sample.txt');
      await existing.writeAsString('ok');

      expect(canCreateShellItemIdListForFile(existing.path), isTrue);
      expect(
        canCreateShellItemIdListForFile('${tempDir.path}\\missing.txt'),
        isFalse,
      );
    });
  }
}
