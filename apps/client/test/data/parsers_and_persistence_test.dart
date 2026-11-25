import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/utils/filename_sanitizer.dart';
import 'package:hyper_download_client/data/datasources/local/json_playlist_session_local_datasource.dart';
import 'package:hyper_download_client/data/parsers/yt_dlp_json_parser.dart';
import 'package:hyper_download_client/data/parsers/yt_dlp_progress_parser.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

void main() {
  const jsonParser = YtDlpJsonParser();
  const localStore = JsonPlaylistSessionLocalDataSource();

  group('YtDlpJsonParser', () {
    test('parses single video JSON into curated video/audio options', () {
      final raw = jsonEncode({
        'id': 'abc123',
        'title': 'Clean Architecture Talk',
        'uploader': 'DevChannel',
        'duration': 320.5,
        'webpage_url': 'https://www.youtube.com/watch?v=abc123',
        'extractor_key': 'Youtube',
        'language': 'en',
        'formats': [
          {
            'format_id': '137',
            'ext': 'mp4',
            'height': 1080,
            'width': 1920,
            'fps': 60,
            'vcodec': 'avc1.640028',
            'acodec': 'none',
            'filesize': 104857600,
            'tbr': 2500,
          },
          {
            'format_id': '140',
            'ext': 'm4a',
            'vcodec': 'none',
            'acodec': 'mp4a.40.2',
            'abr': 128,
            'filesize': 5242880,
            'language': 'en',
            'language_preference': 10,
          },
        ],
      });

      final inspection = jsonParser.parseMediaInspection(raw);
      expect(inspection.id, 'abc123');
      expect(inspection.title, 'Clean Architecture Talk');
      expect(inspection.providerName, 'Youtube');
      expect(inspection.videoOptions, hasLength(1));
      expect(inspection.videoOptions.first.resolution, '1080p');
      expect(inspection.videoOptions.first.fps, 60);
      expect(inspection.videoOptions.first.selectedAudioFormatId, '140');
      expect(inspection.audioOptions, hasLength(1));
      expect(inspection.audioOptions.first.formatId, '140');
    });

    test('parses flat playlist JSON and classifies unavailable items', () {
      final raw = jsonEncode({
        'id': 'PLtest99',
        'title': 'Test Playlist',
        'uploader': 'Creator',
        'webpage_url': 'https://www.youtube.com/playlist?list=PLtest99',
        'extractor_key': 'YoutubeTab',
        'entries': [
          {
            'id': 'v1',
            'title': 'First Video',
            'url': 'v1',
            'duration': 120,
          },
          {
            'id': 'v2',
            'title': '[Private video]',
            'url': 'https://www.youtube.com/watch?v=v2',
          },
        ],
      });

      final playlist = jsonParser.parsePlaylistInspection(
        raw,
        'https://www.youtube.com/playlist?list=PLtest99',
      );
      expect(playlist.id, 'PLtest99');
      expect(playlist.providerName, 'YoutubeTab');
      expect(playlist.entries, hasLength(2));
      expect(playlist.entries[0].availability, PlaylistEntryAvailability.available);
      expect(
        playlist.entries[0].url,
        'https://www.youtube.com/watch?v=v1',
      );
      expect(playlist.entries[1].availability, PlaylistEntryAvailability.private);
    });
  });

  group('YtDlpProgressParser', () {
    test('extracts download percentage, ETA, postprocess, and output path', () {
      final dl = YtDlpProgressParser.parseLine(
        'HYPERDL|downloading|1048576|2097152|NA|524288.0|2',
      );
      expect(dl, isA<ParsedDownloadProgress>());
      final dp = dl as ParsedDownloadProgress;
      expect(dp.downloadedBytes, 1048576);
      expect(dp.totalBytes, 2097152);
      expect(dp.isTotalEstimated, isFalse);
      expect(dp.etaSeconds, 2);

      final pp = YtDlpProgressParser.parseLine(
        'HYPERDL_PP|started|Merger',
      );
      expect(pp, isA<ParsedPostprocessProgress>());

      final dest = YtDlpProgressParser.parseLine(
        r'[download] Destination: C:\Downloads\Video.mp4',
      );
      expect(dest, isA<ParsedOutputPathDetected>());
      expect((dest as ParsedOutputPathDetected).path, r'C:\Downloads\Video.mp4');
    });
  });

  group('FilenameSanitizer & JsonPlaylistSessionLocalDataSource', () {
    test('sanitizes reserved Windows names and pads ordered stems uniquely', () {
      expect(FilenameSanitizer.sanitizeWindowsFilename('CON', 40), '_CON');
      expect(
        FilenameSanitizer.sanitizeWindowsFilename('a/b:c*d?"<>|', 40),
        'a b c d',
      );

      final used = <String>{};
      final s1 = FilenameSanitizer.formatOrderedFilenameStem(0, 12, 'Intro', used);
      final sDup = FilenameSanitizer.formatOrderedFilenameStem(0, 12, 'Intro', used);
      final s2 = FilenameSanitizer.formatOrderedFilenameStem(1, 12, 'Intro', used);
      expect(s1, '001 - Intro');
      expect(sDup, '001 - Intro (2)');
      expect(s2, '002 - Intro');
    });

    test('persists manifest atomically and reconciles interrupted items on reload', () async {
      final tempRoot = await Directory.systemTemp.createTemp('hyperdl_json_test_');
      addTearDown(() => tempRoot.delete(recursive: true));

      final playlistDir = Directory('${tempRoot.path}${Platform.pathSeparator}PL_TEST');
      await playlistDir.create(recursive: true);
      final existingFile = File('${playlistDir.path}${Platform.pathSeparator}01 - Done.mp4');
      await existingFile.writeAsBytes(const [1, 2, 3, 4]);

      final snapshot = PlaylistSessionSnapshot(
        sessionId: 'sess-1',
        playlistId: 'PL_TEST',
        playlistTitle: 'My List',
        playlistUrl: 'https://www.youtube.com/playlist?list=PL_TEST',
        outputDirectory: playlistDir.path,
        mediaMode: PlaylistMediaMode.videoWithSound,
        qualityCap: PlaylistQualityCap.upTo720p,
        isRunning: true,
        isPaused: false,
        completedCount: 2,
        failedCount: 0,
        skippedCount: 0,
        totalCount: 3,
        items: [
          PlaylistItemState(
            orderIndex: 1,
            videoId: 'v1',
            title: 'Done',
            url: 'https://www.youtube.com/watch?v=v1',
            status: PlaylistItemStatus.completed,
            downloadedBytes: 4,
            isTotalEstimated: false,
            outputPath: existingFile.path,
          ),
          const PlaylistItemState(
            orderIndex: 2,
            videoId: 'v2',
            title: 'MissingFile',
            url: 'https://www.youtube.com/watch?v=v2',
            status: PlaylistItemStatus.completed,
            downloadedBytes: 500,
            isTotalEstimated: false,
            outputPath: r'C:\does\not\exist.mp4',
          ),
          const PlaylistItemState(
            orderIndex: 3,
            videoId: 'v3',
            title: 'Interrupted',
            url: 'https://www.youtube.com/watch?v=v3',
            status: PlaylistItemStatus.downloading,
            downloadedBytes: 120,
            isTotalEstimated: false,
          ),
        ],
      );

      await localStore.saveManifestAtomic(playlistDir, snapshot);
      final loaded = await localStore.loadSavedSession([tempRoot], 'PL_TEST');

      expect(loaded, isNotNull);
      expect(loaded!.isRunning, isFalse);
      expect(loaded.completedCount, 1);
      expect(loaded.items[0].status, PlaylistItemStatus.completed);
      expect(loaded.items[1].status, PlaylistItemStatus.pending);
      expect(loaded.items[2].status, PlaylistItemStatus.pending);
    });
  });
}
