import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/data/datasources/android/android_file_launcher_datasource.dart';
import 'package:hyper_download_client/data/datasources/android/android_method_channel_datasource.dart';
import 'package:hyper_download_client/data/datasources/android/android_wire_codec.dart';
import 'package:hyper_download_client/data/repositories/android_single_download_repository_impl.dart';
import 'package:hyper_download_client/data/repositories/media_inspection_repository_impl.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannelName = 'com.hyperdownload/media_engine_test';
  const methodChannel = MethodChannel(methodChannelName);
  const downloadChannel = EventChannel('com.hyperdownload/download_progress_test');
  const playlistChannel = EventChannel('com.hyperdownload/playlist_progress_test');

  final dataSource = AndroidMethodChannelDataSource(
    methodChannel: methodChannel,
    downloadProgressChannel: downloadChannel,
    playlistProgressChannel: playlistChannel,
  );
  final fileLauncher = AndroidFileLauncherDataSource(
    methodChannel: methodChannel,
  );

  final recordedCalls = <MethodCall>[];

  tearDown(() {
    recordedCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  group('AndroidMethodChannelDataSource & AndroidWireCodec', () {
    test('invokes extractRawInfo with expected wire payload', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            recordedCalls.add(call);
            return '{"id":"reel1","formats":[]}';
          });

      final raw = await dataSource.extractRawInfo(
        url: 'https://www.instagram.com/reel/reel1/',
        isPlaylist: false,
        isInstagram: true,
      );

      expect(raw, '{"id":"reel1","formats":[]}');
      expect(recordedCalls.single.method, 'extractRawInfo');
      expect(recordedCalls.single.arguments, {
        'url': 'https://www.instagram.com/reel/reel1/',
        'isPlaylist': false,
        'isInstagram': true,
        'isFacebook': false,
      });
    });

    test('invokes extractRawInfo with isFacebook: true when requested', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            recordedCalls.add(call);
            return '{"id":"4595374484059655","formats":[]}';
          });

      await dataSource.extractRawInfo(
        url: 'https://www.facebook.com/reel/4595374484059655/',
        isPlaylist: false,
        isInstagram: false,
        isFacebook: true,
      );

      expect(recordedCalls.single.method, 'extractRawInfo');
      expect(recordedCalls.single.arguments, {
        'url': 'https://www.facebook.com/reel/4595374484059655/',
        'isPlaylist': false,
        'isInstagram': false,
        'isFacebook': true,
      });
    });

    test('encodes StartDownloadRequest and wraps PlatformException cleanly', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            recordedCalls.add(call);
            if (call.method == 'startDownload') {
              return 'android-job-42';
            }
            throw PlatformException(code: 'ERR', message: 'Engine failure');
          });

      final jobId = await dataSource.startDownload(
        const StartDownloadRequest(
          url: 'https://www.youtube.com/watch?v=abc',
          title: 'Demo',
          selection: DownloadFormatSelection.videoAndAudio(
            videoFormatId: '137',
            audioFormatId: '140',
          ),
        ),
      );

      expect(jobId, 'android-job-42');
      final sentJson =
          jsonDecode(
                (recordedCalls.single.arguments as Map)['requestJson'] as String,
              )
              as Map<String, dynamic>;
      expect(sentJson['selection']['kind'], 'VideoAndAudio');
      expect(sentJson['selection']['video_format_id'], '137');

      await expectLater(
        () => dataSource.cancelDownload('android-job-42'),
        throwsA(isA<ProcessExecutionException>()),
      );
    });

    test('decodes DownloadProgressEvent and PlaylistProgressEvent with int bytes', () {
      final singleEvent = AndroidWireCodec.downloadProgressEventFromJson({
        'job_id': 'j1',
        'phase': 'Downloading',
        'downloaded_bytes': 1024,
        'total_bytes': 4096,
        'is_total_estimated': false,
        'speed_bytes_per_sec': 512.0,
        'eta_seconds': 6,
      });
      expect(singleEvent.phase, DownloadPhase.downloading);
      expect(singleEvent.downloadedBytes, 1024);
      expect(singleEvent.totalBytes, 4096);
      expect(singleEvent.etaSeconds, 6);

      final playlistEvent = AndroidWireCodec.playlistProgressEventFromJson({
        'session_id': 's1',
        'kind': 'PlaylistItemCompleted',
        'item_index': 2,
        'item_status': 'Completed',
        'item_downloaded_bytes': 8192,
        'item_total_bytes': 8192,
        'item_is_total_estimated': false,
        'completed_count': 2,
        'failed_count': 0,
        'skipped_count': 0,
        'total_count': 5,
      });
      expect(playlistEvent.kind, PlaylistEventKind.playlistItemCompleted);
      expect(playlistEvent.itemStatus, PlaylistItemStatus.completed);
      expect(playlistEvent.completedCount, 2);
    });

    test('AndroidFileLauncherDataSource delegates open/reveal/share methods', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            recordedCalls.add(call);
            return true;
          });

      expect(await fileLauncher.openFile('/storage/emulated/0/a.mp4'), isTrue);
      expect(await fileLauncher.revealInFolder('/storage/emulated/0/a.mp4'), isTrue);
      expect(await fileLauncher.shareFile('/storage/emulated/0/a.mp4'), isTrue);
      expect(
        recordedCalls.map((c) => c.method).toList(),
        ['openFile', 'revealInFolder', 'shareFile'],
      );
    });

    test('MediaInspectionRepositoryImpl & AndroidSingleDownloadRepositoryImpl normalize Facebook URLs', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            recordedCalls.add(call);
            if (call.method == 'extractRawInfo') {
              return jsonEncode({
                'id': '4595374484059655',
                'title': 'Facebook',
                'description': 'Public Facebook Reel on Android',
                'uploader': 'Deepinside',
                'webpage_url':
                    'https://m.facebook.com/watch/?v=4595374484059655&_rdr',
                'extractor_key': 'Facebook',
                'formats': [
                  {'format_id': 'sd', 'ext': 'mp4'},
                  {'format_id': 'hd', 'ext': 'mp4'},
                ],
              });
            }
            if (call.method == 'startDownload') {
              return 'android-fb-job-1';
            }
            return null;
          });

      final inspectRepo = MediaInspectionRepositoryImpl(
        androidDataSource: dataSource,
        isAndroidOverride: true,
      );
      final singleRepo = AndroidSingleDownloadRepositoryImpl(dataSource);

      final result = await inspectRepo.inspectUrl(
        'https://m.facebook.com/reel/4595374484059655/?mibextid=abc',
      );
      expect(result.kind, InspectionTargetKind.singleVideo);
      expect(result.video?.providerName, 'Facebook');
      expect(result.video?.title, 'Public Facebook Reel on Android');
      expect(result.video?.videoOptions.first.resolution, 'HD');

      final extractArgs = recordedCalls.first.arguments as Map;
      expect(extractArgs['isFacebook'], isTrue);
      expect(extractArgs['isInstagram'], isFalse);
      expect(
        extractArgs['url'],
        'https://www.facebook.com/reel/4595374484059655/',
      );

      final jobId = await singleRepo.startDownload(
        StartDownloadRequest(
          url: result.video!.webpageUrl,
          title: result.video!.title,
          selection: DownloadFormatSelection.single(
            result.video!.videoOptions.first.videoFormatId,
          ),
        ),
      );
      expect(jobId, 'android-fb-job-1');

      final startArgs = recordedCalls.last.arguments as Map;
      final requestMap =
          jsonDecode(startArgs['requestJson'] as String) as Map<String, dynamic>;
      expect(
        requestMap['url'],
        'https://www.facebook.com/watch/?v=4595374484059655',
      );
    });
  });
}
