import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/android_file_launcher.dart';
import 'package:hyper_download_client/features/media_download/android_media_download_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidEngineJsonCodec', () {
    test(
      'decodes MediaInspection preserving original vs auto-dub metadata',
      () {
        final json = <String, dynamic>{
          'id': 'aqz-KE-bpKQ',
          'title': 'Big Buck Bunny 60fps 4K',
          'uploader': 'Blender Foundation',
          'duration_seconds': 634.5,
          'thumbnail_url': 'https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg',
          'webpage_url': 'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
          'provider_name': 'Youtube',
          'original_audio': {
            'language': 'en',
            'language_display_name': 'English',
            'is_original': true,
            'is_default': true,
            'is_auto_dub': false,
            'selection_confidence': 'ConfirmedOriginal',
            'status_note': 'Original: English',
          },
          'video_options': [
            {
              'resolution': '1080p',
              'height': 1080,
              'fps': 60.0,
              'container': 'mp4',
              'display_size': '150.00 MB (Exact)',
              'file_size_bytes': 157286400,
              'size_accuracy': 'Exact',
              'video_format_id': '299',
              'selected_audio_format_id': '140-drc',
              'audio_language': {
                'language': 'en',
                'language_display_name': 'English',
                'is_original': true,
                'is_default': true,
                'is_auto_dub': false,
                'selection_confidence': 'ConfirmedOriginal',
                'status_note': 'Original: English',
              },
              'format_selection_strategy': 'PairVideoAndAudioWithFfmpeg',
            },
            {
              'resolution': '720p',
              'height': 720,
              'fps': 30.0,
              'container': 'mp4',
              'display_size': '~55.00 MB (Estimated)',
              'file_size_bytes': 57671680,
              'size_accuracy': 'Estimated',
              'video_format_id': '22',
              'selected_audio_format_id': null,
              'audio_language': null,
              'format_selection_strategy': 'CombinedAudioVideo',
            },
          ],
          'audio_options': [
            {
              'quality_label': 'High Audio (128 kbps m4a)',
              'container': 'm4a',
              'bitrate_kbps': 128.0,
              'display_size': '10.00 MB (Exact)',
              'file_size_bytes': 10485760,
              'size_accuracy': 'Exact',
              'format_id': '140',
              'audio_language': {
                'language': 'es',
                'language_display_name': 'Spanish (Auto-dub)',
                'is_original': false,
                'is_default': false,
                'is_auto_dub': true,
                'selection_confidence': 'AmbiguousOrUnknown',
                'status_note': 'Audio track marked auto-dubbed',
              },
            },
          ],
          'formats': [
            {
              'format_id': '299',
              'container': 'mp4',
              'stream_kind': 'VideoOnly',
              'resolution': '1920x1080',
              'width': 1920,
              'height': 1080,
              'fps': 60.0,
              'vcodec': 'avc1.64002a',
              'acodec': 'none',
              'bitrate_kbps': 2500.0,
              'file_size_bytes': 146800640,
              'size_accuracy': 'Exact',
              'format_note': '1080p60',
            },
          ],
        };

        final inspection = AndroidEngineJsonCodec.mediaInspectionFromJson(json);
        expect(inspection.id, 'aqz-KE-bpKQ');
        expect(inspection.originalAudio?.isOriginal, isTrue);
        expect(inspection.originalAudio?.isAutoDub, isFalse);
        expect(
          inspection.originalAudio?.selectionConfidence,
          AudioSelectionConfidence.confirmedOriginal,
        );
        expect(inspection.videoOptions, hasLength(2));
        expect(
          inspection.videoOptions[0].formatSelectionStrategy,
          FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
        );
        expect(
          inspection.videoOptions[0].fileSizeBytes,
          BigInt.from(157286400),
        );
        expect(
          inspection.videoOptions[1].formatSelectionStrategy,
          FormatSelectionStrategy.combinedAudioVideo,
        );
        expect(inspection.audioOptions[0].audioLanguage?.isAutoDub, isTrue);
        expect(inspection.formats[0].streamKind, StreamKind.videoOnly);
      },
    );

    test(
      'decodes Instagram Reel MediaInspection with portrait qualities and Audio included automatically',
      () {
        final json = <String, dynamic>{
          'id': 'DTVTvUDj-b1',
          'title': 'Video by rahulmfg',
          'uploader': 'Rahul',
          'duration_seconds': null,
          'thumbnail_url': 'https://instagram.example.com/cover.jpg',
          'webpage_url': 'https://www.instagram.com/reel/DTVTvUDj-b1/',
          'provider_name': 'Instagram',
          'original_audio': {
            'language': null,
            'language_display_name': null,
            'is_original': null,
            'is_default': null,
            'is_auto_dub': null,
            'selection_confidence': 'SingleOrUnmarked',
            'status_note': 'Audio included automatically',
          },
          'video_options': [
            {
              'resolution': '1080p',
              'height': 1080,
              'fps': null,
              'container': 'mp4',
              'display_size': 'Unknown size',
              'file_size_bytes': null,
              'size_accuracy': 'Unknown',
              'video_format_id': 'dash-1080v',
              'selected_audio_format_id': 'dash-a',
              'audio_language': {
                'language': null,
                'language_display_name': null,
                'is_original': null,
                'is_default': null,
                'is_auto_dub': null,
                'selection_confidence': 'SingleOrUnmarked',
                'status_note': 'Audio included automatically',
              },
              'format_selection_strategy': 'PairVideoAndAudioWithFfmpeg',
            },
          ],
          'audio_options': [
            {
              'quality_label': 'Compact Quality (68 kbps)',
              'container': 'm4a',
              'bitrate_kbps': 68.0,
              'display_size': 'Unknown size',
              'file_size_bytes': null,
              'size_accuracy': 'Unknown',
              'format_id': 'dash-a',
              'audio_language': {
                'language': null,
                'language_display_name': null,
                'is_original': null,
                'is_default': null,
                'is_auto_dub': null,
                'selection_confidence': 'SingleOrUnmarked',
                'status_note': 'Audio included automatically',
              },
            },
          ],
          'formats': const [],
        };

        final inspection = AndroidEngineJsonCodec.mediaInspectionFromJson(json);
        expect(inspection.providerName, 'Instagram');
        expect(
          inspection.originalAudio?.statusNote,
          'Audio included automatically',
        );
        expect(inspection.videoOptions.single.resolution, '1080p');
        expect(
          inspection.videoOptions.single.formatSelectionStrategy,
          FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
        );
        expect(inspection.audioOptions.single.formatId, 'dash-a');
      },
    );

    test(
      'decodes playlist inspection, snapshot, progress, and size estimate',
      () {
        final urlResult = AndroidEngineJsonCodec.urlInspectionResultFromJson({
          'kind': 'Playlist',
          'video': null,
          'playlist': {
            'id': 'PL_TEST',
            'title': 'Blender Open Movies',
            'uploader': 'Blender',
            'thumbnail_url': null,
            'webpage_url': 'https://www.youtube.com/playlist?list=PL_TEST',
            'provider_name': 'Youtube',
            'total_item_count': 3,
            'entries': [
              {
                'order_index': 0,
                'video_id': 'vid0',
                'title': 'First',
                'url': 'https://www.youtube.com/watch?v=vid0',
                'uploader': 'Blender',
                'duration_seconds': 120.0,
                'thumbnail_url': null,
                'availability': 'Available',
                'availability_reason': null,
              },
              {
                'order_index': 1,
                'video_id': 'vid1',
                'title': '[Private video]',
                'url': 'https://www.youtube.com/watch?v=vid1',
                'uploader': null,
                'duration_seconds': null,
                'thumbnail_url': null,
                'availability': 'Private',
                'availability_reason': 'Private video',
              },
            ],
          },
        });

        expect(urlResult.kind, InspectionTargetKind.playlist);
        expect(
          urlResult.playlist?.entries[1].availability,
          PlaylistEntryAvailability.private,
        );

        final snapshot = AndroidEngineJsonCodec.playlistSessionSnapshotFromJson(
          {
            'session_id': 'sess-1',
            'playlist_id': 'PL_TEST',
            'playlist_title': 'Blender Open Movies',
            'playlist_url': 'https://www.youtube.com/playlist?list=PL_TEST',
            'uploader': 'Blender',
            'thumbnail_url': null,
            'output_directory':
                '/storage/emulated/0/Download/HyperDownload/PL_TEST',
            'media_mode': 'VideoWithSound',
            'quality_cap': 'UpTo720p',
            'is_running': true,
            'is_paused': false,
            'completed_count': 1,
            'failed_count': 0,
            'skipped_count': 1,
            'total_count': 2,
            'items': [
              {
                'order_index': 0,
                'video_id': 'vid0',
                'title': 'First',
                'url': 'https://www.youtube.com/watch?v=vid0',
                'duration_seconds': 120.0,
                'thumbnail_url': null,
                'status': 'Completed',
                'selected_quality': '720p',
                'audio_language': null,
                'downloaded_bytes': 12345678,
                'total_bytes': 12345678,
                'is_total_estimated': false,
                'output_path': 'content://media/external/downloads/42',
                'error_message': null,
              },
            ],
          },
        );

        expect(snapshot.qualityCap, PlaylistQualityCap.upTo720P);
        expect(snapshot.items.single.status, PlaylistItemStatus.completed);
        expect(snapshot.items.single.downloadedBytes, BigInt.from(12345678));

        final estimate = AndroidEngineJsonCodec.playlistSizeEstimateFromJson({
          'estimation_id': 'est-1',
          'playlist_id': 'PL_TEST',
          'media_mode': 'AudioOnly',
          'quality_cap': 'UpTo480p',
          'status': 'Partial',
          'known_total_bytes': 20971520,
          'total_entries_count': 3,
          'unavailable_count': 1,
          'eligible_count': 2,
          'inspected_count': 2,
          'exact_count': 1,
          'estimated_count': 0,
          'unknown_count': 1,
          'failed_count': 0,
          'display_summary': '20.00 MB+ (partial: 1 unknown)',
          'status_message': 'One track lacked Content-Length.',
          'item_sizes': [
            {
              'order_index': 0,
              'selected_quality': 'High Audio',
              'expected_size_bytes': 20971520,
              'size_accuracy': 'Exact',
              'display_size': '20.00 MB',
              'failed': false,
              'error_message': null,
            },
            {
              'order_index': 2,
              'selected_quality': 'Medium Audio',
              'expected_size_bytes': null,
              'size_accuracy': 'Unknown',
              'display_size': 'Unknown',
              'failed': false,
              'error_message': null,
            },
          ],
        });

        expect(estimate.mediaMode, PlaylistMediaMode.audioOnly);
        expect(estimate.qualityCap, PlaylistQualityCap.upTo480P);
        expect(estimate.status, PlaylistSizeStatus.partial);
        expect(estimate.knownTotalBytes, BigInt.from(20971520));
        expect(estimate.itemSizes[1].sizeAccuracy, FileSizeAccuracy.unknown);
      },
    );

    test(
      'encodes quality caps and download requests in canonical Rust serde format',
      () {
        const playlist = PlaylistInspection(
          id: 'PL_1',
          title: 'Test Playlist',
          webpageUrl: 'https://www.youtube.com/playlist?list=PL_1',
          providerName: 'Youtube',
          totalItemCount: 1,
          entries: [
            PlaylistEntrySummary(
              orderIndex: 0,
              videoId: 'v0',
              title: 'Item 0',
              url: 'https://www.youtube.com/watch?v=v0',
              availability: PlaylistEntryAvailability.available,
            ),
          ],
        );

        final est720 = AndroidEngineJsonCodec.estimatePlaylistSizeRequestToJson(
          const EstimatePlaylistSizeRequest(
            playlist: playlist,
            mediaMode: PlaylistMediaMode.videoWithSound,
            qualityCap: PlaylistQualityCap.upTo720P,
          ),
        );
        expect(est720['media_mode'], 'VideoWithSound');
        expect(est720['quality_cap'], 'UpTo720p');

        expect(
          AndroidEngineJsonCodec.encodePlaylistQualityCap(
            PlaylistQualityCap.upTo1080P,
          ),
          'UpTo1080p',
        );
        expect(
          AndroidEngineJsonCodec.encodePlaylistQualityCap(
            PlaylistQualityCap.upTo480P,
          ),
          'UpTo480p',
        );
        expect(
          AndroidEngineJsonCodec.encodePlaylistQualityCap(
            PlaylistQualityCap.bestAvailable,
          ),
          'BestAvailable',
        );

        final dlReq = AndroidEngineJsonCodec.startDownloadRequestToJson(
          const StartDownloadRequest(
            url: 'https://www.youtube.com/watch?v=v0',
            title: 'Item 0',
            selection: DownloadFormatSelection(
              kind: DownloadSelectionKind.videoAndAudio,
              videoFormatId: '137',
              audioFormatId: '140',
              mergeContainer: 'mp4',
            ),
          ),
        );
        final selection = dlReq['selection'] as Map<String, dynamic>;
        expect(selection['kind'], 'VideoAndAudio');
        expect(selection['video_format_id'], '137');
        expect(selection['audio_format_id'], '140');
        expect(selection['merge_container'], 'mp4');
      },
    );
  });

  group('Android MethodChannel wiring', () {
    const channel = MethodChannel('com.hyperdownload/media_engine');
    final recordedCalls = <MethodCall>[];

    tearDown(() {
      recordedCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'AndroidMediaDownloadRepository forwards inspectPlaylist & unwraps PlatformException',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              recordedCalls.add(call);
              if (call.method == 'inspectPlaylist') {
                return jsonEncode({
                  'id': 'PL_X',
                  'title': 'PL Title',
                  'uploader': null,
                  'thumbnail_url': null,
                  'webpage_url': 'https://www.youtube.com/playlist?list=PL_X',
                  'provider_name': 'Youtube',
                  'total_item_count': 0,
                  'entries': [],
                });
              }
              if (call.method == 'startDownload') {
                throw PlatformException(
                  code: 'START_DOWNLOAD_FAILED',
                  message: 'Another download is already running.',
                );
              }
              return null;
            });

        const repo = AndroidMediaDownloadRepository();
        expect(repo.ping(), 'pong');
        expect(repo.engineVersion(), '0.1.0-android');

        final playlist = await repo.inspectPlaylist(
          'https://www.youtube.com/playlist?list=PL_X',
        );
        expect(playlist.id, 'PL_X');

        await expectLater(
          repo.startDownload(
            const StartDownloadRequest(
              url: 'https://www.youtube.com/watch?v=abc',
              selection: DownloadFormatSelection(
                kind: DownloadSelectionKind.single,
                formatId: '18',
              ),
            ),
          ),
          throwsA(
            predicate<Object>(
              (e) =>
                  e.toString().contains('Another download is already running.'),
            ),
          ),
        );
        expect(recordedCalls.map((c) => c.method), [
          'inspectPlaylist',
          'startDownload',
        ]);
      },
    );

    test(
      'AndroidFileLauncher invokes openFile, revealInFolder, and shareFile',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              recordedCalls.add(call);
              return true;
            });

        const launcher = AndroidFileLauncher();
        expect(
          await launcher.openFile('content://media/external/downloads/1'),
          isTrue,
        );
        expect(
          await launcher.revealInFolder('/sdcard/Download/HyperDownload'),
          isTrue,
        );
        expect(
          await launcher.shareFile('content://media/external/downloads/1'),
          isTrue,
        );

        expect(recordedCalls.map((c) => c.method), [
          'openFile',
          'revealInFolder',
          'shareFile',
        ]);
      },
    );
  });
}
