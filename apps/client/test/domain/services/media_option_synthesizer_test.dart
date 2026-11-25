import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/services/media_option_synthesizer.dart';

void main() {
  const synthesizer = MediaOptionSynthesizer();

  RawFormatCandidate videoCandidate({
    required String id,
    required int height,
    String container = 'mp4',
    String vcodec = 'avc1.640028',
    int? bytes,
    FileSizeAccuracy accuracy = FileSizeAccuracy.exact,
    StreamKind kind = StreamKind.videoOnly,
    String? acodec,
    double fps = 30,
  }) {
    return RawFormatCandidate(
      format: DiscoveredFormat(
        formatId: id,
        container: container,
        streamKind: kind,
        resolution: '${height}p',
        width: (height * 16) ~/ 9,
        height: height,
        fps: fps,
        vcodec: vcodec,
        acodec: acodec,
        bitrateKbps: 1200,
        fileSizeBytes: bytes,
        sizeAccuracy: accuracy,
      ),
    );
  }

  RawFormatCandidate audioCandidate({
    required String id,
    String container = 'm4a',
    String acodec = 'mp4a.40.2',
    double bitrate = 128,
    int? bytes,
    String? language = 'en',
    int? languagePreference,
    String? formatNote,
    String? xtagsAcont,
  }) {
    return RawFormatCandidate(
      format: DiscoveredFormat(
        formatId: id,
        container: container,
        streamKind: StreamKind.audioOnly,
        resolution: 'audio',
        acodec: acodec,
        bitrateKbps: bitrate,
        fileSizeBytes: bytes,
        sizeAccuracy: bytes != null
            ? FileSizeAccuracy.exact
            : FileSizeAccuracy.unknown,
        formatNote: formatNote,
      ),
      language: language,
      languagePreference: languagePreference,
      xtagsAcont: xtagsAcont,
    );
  }

  group('MediaOptionSynthesizer', () {
    test('prefers original language audio over auto-dubbed tracks', () {
      final synthesized = synthesizer.buildQualityOptionsForPlatform([
        videoCandidate(id: '137', height: 1080, bytes: 100 * 1024 * 1024),
        audioCandidate(
          id: '140-en',
          language: 'en',
          languagePreference: 10,
          bitrate: 128,
          bytes: 10 * 1024 * 1024,
          xtagsAcont: 'original',
        ),
        audioCandidate(
          id: '140-es',
          language: 'es',
          languagePreference: 1,
          bitrate: 192,
          bytes: 15 * 1024 * 1024,
          formatNote: 'Spanish (auto-dubbed)',
          xtagsAcont: 'dubbed',
        ),
      ], videoLanguage: 'en');

      expect(synthesized.originalAudio?.language, 'en');
      expect(synthesized.originalAudio?.isOriginal, isTrue);
      expect(synthesized.videoOptions, hasLength(1));
      expect(synthesized.videoOptions.first.selectedAudioFormatId, '140-en');
      expect(
        synthesized.videoOptions.first.fileSizeBytes,
        110 * 1024 * 1024,
      );
      expect(
        synthesized.videoOptions.first.formatSelectionStrategy,
        FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
      );
    });

    test('applies playlist quality cap without fabricating higher formats', () {
      final inspection = MediaInspection(
        id: 'vid1',
        title: 'Sample',
        webpageUrl: 'https://www.youtube.com/watch?v=vid1',
        providerName: 'YouTube',
        videoOptions: const [
          VideoQualityOption(
            resolution: '1080p',
            height: 1080,
            container: 'mp4',
            displaySize: '100 MB',
            fileSizeBytes: 100000000,
            sizeAccuracy: FileSizeAccuracy.exact,
            videoFormatId: '137',
            selectedAudioFormatId: '140',
            formatSelectionStrategy:
                FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
          ),
          VideoQualityOption(
            resolution: '720p',
            height: 720,
            container: 'mp4',
            displaySize: '60 MB',
            fileSizeBytes: 60000000,
            sizeAccuracy: FileSizeAccuracy.exact,
            videoFormatId: '136',
            selectedAudioFormatId: '140',
            formatSelectionStrategy:
                FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
          ),
        ],
        audioOptions: const [
          AudioQualityOption(
            qualityLabel: '128 kbps',
            container: 'm4a',
            bitrateKbps: 128,
            displaySize: '5 MB',
            fileSizeBytes: 5000000,
            sizeAccuracy: FileSizeAccuracy.exact,
            formatId: '140',
          ),
        ],
        formats: const [],
      );

      final capped = synthesizer.selectPlaylistItemOption(
        inspection,
        PlaylistMediaMode.videoWithSound,
        PlaylistQualityCap.upTo720p,
      );
      expect(capped.qualityLabel, '720p MP4');
      expect(capped.selection.kind, DownloadSelectionKind.videoAndAudio);
      expect(capped.selection.videoFormatId, '136');

      final audio = synthesizer.selectPlaylistItemOption(
        inspection,
        PlaylistMediaMode.audioOnly,
        PlaylistQualityCap.bestAvailable,
      );
      expect(audio.selection.kind, DownloadSelectionKind.single);
      expect(audio.selection.formatId, '140');
    });

    test('builds truthful playlist size estimates for mixed accuracy', () {
      const playlist = PlaylistInspection(
        id: 'PL1',
        title: 'List',
        webpageUrl: 'https://www.youtube.com/playlist?list=PL1',
        providerName: 'YouTube',
        totalItemCount: 2,
        entries: [
          PlaylistEntrySummary(
            orderIndex: 1,
            videoId: 'v1',
            title: 'One',
            url: 'https://www.youtube.com/watch?v=v1',
            availability: PlaylistEntryAvailability.available,
          ),
          PlaylistEntrySummary(
            orderIndex: 2,
            videoId: 'v2',
            title: 'Two',
            url: 'https://www.youtube.com/watch?v=v2',
            availability: PlaylistEntryAvailability.private,
          ),
        ],
      );

      const media1 = MediaInspection(
        id: 'v1',
        title: 'One',
        webpageUrl: 'https://www.youtube.com/watch?v=v1',
        providerName: 'YouTube',
        videoOptions: [
          VideoQualityOption(
            resolution: '720p',
            height: 720,
            container: 'mp4',
            displaySize: '50 MB',
            fileSizeBytes: 52428800,
            sizeAccuracy: FileSizeAccuracy.exact,
            videoFormatId: '22',
            formatSelectionStrategy:
                FormatSelectionStrategy.combinedAudioVideo,
          ),
        ],
        audioOptions: [],
        formats: [],
      );

      final estimate = synthesizer.buildPlaylistSizeEstimate(
        estimationId: 'est-1',
        playlist: playlist,
        mediaMode: PlaylistMediaMode.videoWithSound,
        qualityCap: PlaylistQualityCap.bestAvailable,
        results: {1: (inspection: media1, error: null)},
        isCalculating: false,
        wasCanceled: false,
      );

      expect(estimate.status, PlaylistSizeStatus.exact);
      expect(estimate.knownTotalBytes, 52428800);
      expect(estimate.unavailableCount, 1);
      expect(estimate.eligibleCount, 1);
      expect(estimate.itemSizes.first.selectedQuality, '720p MP4');
    });
  });
}
