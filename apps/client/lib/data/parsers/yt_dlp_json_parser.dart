import 'dart:convert';
import 'dart:isolate';

import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';
import 'package:hyper_download_client/domain/services/media_option_synthesizer.dart';

const int _isolateOffloadThresholdChars = 50000;

/// Parses raw `yt-dlp --dump-single-json` and `--flat-playlist` payloads into
/// domain [MediaInspection] and [PlaylistInspection] entities.
class YtDlpJsonParser {
  final PlatformRegistry _platformRegistry;
  final MediaOptionSynthesizer _synthesizer;

  const YtDlpJsonParser({
    PlatformRegistry? platformRegistry,
    MediaOptionSynthesizer? synthesizer,
  }) : _platformRegistry = platformRegistry ?? const PlatformRegistry(),
       _synthesizer = synthesizer ?? const MediaOptionSynthesizer();

  Future<MediaInspection> parseMediaInspectionAsync(String rawJson) {
    if (rawJson.length > _isolateOffloadThresholdChars) {
      final registry = _platformRegistry;
      final synth = _synthesizer;
      return Isolate.run(
        () => YtDlpJsonParser(
          platformRegistry: registry,
          synthesizer: synth,
        ).parseMediaInspection(rawJson),
      );
    }
    return Future<MediaInspection>.value(parseMediaInspection(rawJson));
  }

  Future<PlaylistInspection> parsePlaylistInspectionAsync(
    String rawJson,
    String fallbackUrl,
  ) {
    if (rawJson.length > _isolateOffloadThresholdChars) {
      final registry = _platformRegistry;
      final synth = _synthesizer;
      return Isolate.run(
        () => YtDlpJsonParser(
          platformRegistry: registry,
          synthesizer: synth,
        ).parsePlaylistInspection(rawJson, fallbackUrl),
      );
    }
    return Future<PlaylistInspection>.value(
      parsePlaylistInspection(rawJson, fallbackUrl),
    );
  }

  MediaInspection parseMediaInspection(String rawJson) {
    final obj = _decodeRootObject(rawJson);

    final rawExtractor =
        _nonEmptyStr(obj['extractor_key']) ?? _nonEmptyStr(obj['extractor']);
    final rawWebUrl =
        _nonEmptyStr(obj['webpage_url']) ?? _nonEmptyStr(obj['original_url']);
    final isInstagramPayload =
        (rawExtractor?.toLowerCase().startsWith('instagram') ?? false) ||
        (rawWebUrl != null && inferProviderFromUrl(rawWebUrl) == 'Instagram');

    final rawFormats = obj['formats'];
    if (rawFormats is! List && obj['_type'] == 'playlist') {
      final msg = isInstagramPayload
          ? 'Instagram carousels and multi-item posts are not supported. Only individual public Reels are supported.'
          : 'Playlist URLs are not supported in single-video inspection yet. Please enter a single video URL.';
      throw ParseException(msg);
    }
    if (rawFormats is! List) {
      throw const ParseException(
        "Missing 'formats' array in yt-dlp output.",
      );
    }

    final id = _nonEmptyStr(obj['id']);
    if (id == null) {
      throw const ParseException("Missing media 'id' in yt-dlp output.");
    }

    final webpageUrl =
        _nonEmptyStr(obj['webpage_url']) ??
        _nonEmptyStr(obj['original_url']) ??
        '';
    final rawProvider = rawExtractor ?? inferProviderFromUrl(webpageUrl);
    final providerName = _normalizeProviderName(rawProvider, webpageUrl);
    final isInstagram = providerName.toLowerCase() == 'instagram';

    final uploader =
        _nonEmptyStr(obj['uploader']) ??
        _nonEmptyStr(obj['channel']) ??
        _nonEmptyStr(obj['creator']) ??
        (isInstagram ? _nonEmptyStr(obj['uploader_id']) : null);

    final title =
        _nonEmptyStr(obj['title']) ??
        (isInstagram
            ? (uploader != null
                  ? 'Instagram Reel by $uploader'
                  : 'Instagram Reel ($id)')
            : id);

    final durationSeconds =
        _asDouble(obj['duration']) ?? _asDouble(obj['duration_seconds']);
    final thumbnailUrl = extractThumbnailUrl(obj);
    final videoLanguage = _nonEmptyStr(obj['language']);

    final candidates = <RawFormatCandidate>[];
    for (final entry in rawFormats) {
      if (entry is Map) {
        final cand = _parseDiscoveredCandidate(
          Map<String, dynamic>.from(entry),
        );
        if (cand != null) candidates.add(cand);
      }
    }

    if (candidates.isEmpty) {
      throw const ParseException(
        'No usable non-DRM, non-storyboard formats were found for this URL.',
      );
    }

    final synthesized = _synthesizer.buildQualityOptionsForPlatform(
      candidates,
      videoLanguage: videoLanguage,
      isInstagram: isInstagram,
    );

    return MediaInspection(
      id: id,
      title: title,
      uploader: uploader,
      durationSeconds: durationSeconds,
      thumbnailUrl: thumbnailUrl,
      webpageUrl: webpageUrl,
      providerName: providerName,
      originalAudio: synthesized.originalAudio,
      videoOptions: synthesized.videoOptions,
      audioOptions: synthesized.audioOptions,
      formats: candidates.map((c) => c.format).toList(growable: false),
    );
  }

  PlaylistInspection parsePlaylistInspection(
    String rawJson,
    String fallbackUrl,
  ) {
    final obj = _decodeRootObject(rawJson, expectedLabel: 'playlist JSON');
    final rawEntries = obj['entries'];
    if (rawEntries is! List) {
      throw const ParseException(
        "Missing 'entries' array in yt-dlp playlist output.",
      );
    }

    final fallbackListId = Uri.tryParse(fallbackUrl)?.queryParameters['list'];
    final playlistId =
        _nonEmptyStr(obj['id']) ??
        (fallbackListId != null && fallbackListId.trim().isNotEmpty
            ? fallbackListId.trim()
            : null) ??
        'playlist';

    final title = _nonEmptyStr(obj['title']) ?? playlistId;
    final uploader =
        _nonEmptyStr(obj['uploader']) ??
        _nonEmptyStr(obj['channel']) ??
        _nonEmptyStr(obj['creator']);
    final webpageUrl =
        _nonEmptyStr(obj['webpage_url']) ??
        _nonEmptyStr(obj['original_url']) ??
        fallbackUrl;
    final providerName =
        _nonEmptyStr(obj['extractor_key']) ??
        _nonEmptyStr(obj['extractor']) ??
        inferProviderFromUrl(webpageUrl);

    final entries = <PlaylistEntrySummary>[];
    for (var idx = 0; idx < rawEntries.length; idx++) {
      entries.add(_parsePlaylistEntry(idx, rawEntries[idx]));
    }

    var rootThumb = extractThumbnailUrl(obj);
    if (rootThumb == null) {
      for (final entry in entries) {
        if (entry.availability == PlaylistEntryAvailability.available &&
            entry.thumbnailUrl != null) {
          rootThumb = entry.thumbnailUrl;
          break;
        }
      }
    }

    final reportedCount = _asInt(obj['playlist_count']) ?? 0;
    final totalItemCount = reportedCount > entries.length
        ? reportedCount
        : entries.length;

    return PlaylistInspection(
      id: playlistId,
      title: title,
      uploader: uploader,
      thumbnailUrl: rootThumb,
      webpageUrl: webpageUrl,
      providerName: providerName,
      totalItemCount: totalItemCount,
      entries: entries,
    );
  }

  String inferProviderFromUrl(String url) {
    final parsed = Uri.tryParse(url);
    final host = parsed?.host;
    if (host == null || host.isEmpty) return 'Unknown';
    final strategy = _platformRegistry.strategyForHost(host);
    return switch (strategy.displayName) {
      'YouTube' => 'YouTube',
      'Instagram' => 'Instagram',
      _ => host,
    };
  }

  static String? extractThumbnailUrl(Map<String, dynamic> obj) {
    final thumb = _nonEmptyStr(obj['thumbnail']);
    if (thumb != null) return thumb;
    final thumbs = obj['thumbnails'];
    if (thumbs is List) {
      for (var i = thumbs.length - 1; i >= 0; i--) {
        final item = thumbs[i];
        if (item is Map) {
          final url = _nonEmptyStr(item['url']);
          if (url != null) return url;
        }
      }
    }
    return null;
  }

  static Map<String, dynamic> _decodeRootObject(
    String rawJson, {
    String expectedLabel = 'JSON object',
  }) {
    var cleaned = rawJson.trim();
    if (cleaned.startsWith('\uFEFF')) {
      cleaned = cleaned.substring(1).trim();
    }
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw ParseException('Expected top-level $expectedLabel.');
    } on ParseException {
      rethrow;
    } catch (err) {
      throw ParseException(err.toString());
    }
  }

  RawFormatCandidate? _parseDiscoveredCandidate(Map<String, dynamic> obj) {
    if (_isDrmProtected(obj['has_drm'])) return null;

    final formatId = _nonEmptyStr(obj['format_id']);
    if (formatId == null) return null;

    final container =
        _nonEmptyStr(obj['ext']) ?? _nonEmptyStr(obj['container']) ?? 'unknown';
    final formatNote = _nonEmptyStr(obj['format_note']);

    final isStoryboard =
        container.toLowerCase() == 'mhtml' ||
        (formatNote?.toLowerCase().contains('storyboard') ?? false);
    if (isStoryboard) return null;

    final vcodec = _normalizeCodec(obj['vcodec']);
    final acodec = _normalizeCodec(obj['acodec']);
    final vcodecExplicitNone = _isCodecExplicitlyNone(obj['vcodec']);
    final acodecExplicitNone = _isCodecExplicitlyNone(obj['acodec']);
    final audioExt = _normalizeCodec(obj['audio_ext']);
    final videoExt = _normalizeCodec(obj['video_ext']);
    final resolutionRaw = _nonEmptyStr(obj['resolution']);

    final hasVideo = vcodec != null;
    final hasAudio =
        acodec != null || (audioExt != null && resolutionRaw == 'audio only');
    final isUnknownCodecMuxed =
        !vcodecExplicitNone &&
        !acodecExplicitNone &&
        vcodec == null &&
        acodec == null &&
        videoExt != null &&
        resolutionRaw != 'audio only';

    if (!hasVideo && !hasAudio && !isUnknownCodecMuxed) return null;

    final StreamKind streamKind;
    switch (_nonEmptyStr(obj['stream_kind'])) {
      case 'muxed_av':
        streamKind = StreamKind.muxedAudioVideo;
      case 'video_only':
        streamKind = StreamKind.videoOnly;
      case 'audio_only':
        streamKind = StreamKind.audioOnly;
      default:
        if (isUnknownCodecMuxed) {
          streamKind = StreamKind.muxedAudioVideo;
        } else if (hasVideo && hasAudio) {
          streamKind = StreamKind.muxedAudioVideo;
        } else if (hasVideo) {
          streamKind = StreamKind.videoOnly;
        } else {
          streamKind = StreamKind.audioOnly;
        }
    }

    final width = _asInt(obj['width']);
    final height = _asInt(obj['height']);
    final resolution =
        resolutionRaw ??
        ((width != null && height != null)
            ? '${width}x$height'
            : (streamKind == StreamKind.audioOnly ? 'audio only' : 'unknown'));

    final fps = _asDouble(obj['fps']);
    final bitrateKbps =
        _asDouble(obj['tbr']) ??
        _asDouble(obj['tbr_kbps']) ??
        _asDouble(obj['abr']);

    final (fileSizeBytes, sizeAccuracy) = _resolveSizeAndAccuracy(obj);
    final protocol = _nonEmptyStr(obj['protocol']);
    final language = _nonEmptyStr(obj['language']);
    final languagePreference = _asInt(obj['language_preference']);
    final sourcePreference = _asInt(obj['source_preference']);
    final xtagsAcont = _synthesizer.extractXtagsAcont(_nonEmptyStr(obj['url']));

    return RawFormatCandidate(
      format: DiscoveredFormat(
        formatId: formatId,
        container: container,
        streamKind: streamKind,
        resolution: resolution,
        width: width,
        height: height,
        fps: fps,
        vcodec: vcodec,
        acodec: acodec,
        bitrateKbps: bitrateKbps,
        fileSizeBytes: fileSizeBytes,
        sizeAccuracy: sizeAccuracy,
        formatNote: formatNote,
      ),
      protocol: protocol,
      language: language,
      languagePreference: languagePreference,
      sourcePreference: sourcePreference,
      xtagsAcont: xtagsAcont,
    );
  }

  PlaylistEntrySummary _parsePlaylistEntry(int orderIndex, Object? rawEntry) {
    if (rawEntry is! Map) {
      return PlaylistEntrySummary(
        orderIndex: orderIndex,
        videoId: 'unavailable_$orderIndex',
        title: '[Unavailable video]',
        url: '',
        availability: PlaylistEntryAvailability.unavailable,
        availabilityReason: 'Entry metadata missing from playlist',
      );
    }

    final obj = Map<String, dynamic>.from(rawEntry);
    final videoId = _nonEmptyStr(obj['id']) ?? '';
    final title = _nonEmptyStr(obj['title']) ?? 'Video ${orderIndex + 1}';
    final rawUrl =
        _nonEmptyStr(obj['url']) ?? _nonEmptyStr(obj['webpage_url']);

    final String url;
    if (rawUrl != null &&
        (rawUrl.startsWith('http://') || rawUrl.startsWith('https://'))) {
      url = rawUrl;
    } else if (videoId.isNotEmpty) {
      url = 'https://www.youtube.com/watch?v=$videoId';
    } else {
      url = '';
    }

    final uploader =
        _nonEmptyStr(obj['uploader']) ?? _nonEmptyStr(obj['channel']);
    final durationSeconds = _asDouble(obj['duration']);
    final thumbnailUrl = extractThumbnailUrl(obj);
    final availabilityStr = _nonEmptyStr(obj['availability']);

    final (availability, availabilityReason) = _classifyEntryAvailability(
      title,
      url,
      availabilityStr,
    );

    return PlaylistEntrySummary(
      orderIndex: orderIndex,
      videoId: videoId.isEmpty ? 'item_$orderIndex' : videoId,
      title: title,
      url: url,
      uploader: uploader,
      durationSeconds: durationSeconds,
      thumbnailUrl: thumbnailUrl,
      availability: availability,
      availabilityReason: availabilityReason,
    );
  }

  static (PlaylistEntryAvailability, String?) _classifyEntryAvailability(
    String title,
    String url,
    String? availabilityFlag,
  ) {
    final lowerTitle = title.trim().toLowerCase();
    final lowerFlag = availabilityFlag?.trim().toLowerCase();

    if (lowerTitle == '[private video]' || lowerFlag == 'private') {
      return (
        PlaylistEntryAvailability.private,
        'Private video (skipped automatically)',
      );
    }
    if (lowerTitle == '[deleted video]' ||
        lowerTitle == '[removed video]' ||
        lowerFlag == 'deleted') {
      return (
        PlaylistEntryAvailability.removed,
        'Removed or deleted video (skipped automatically)',
      );
    }
    if (lowerTitle == '[unavailable video]' ||
        url.isEmpty ||
        lowerFlag == 'unavailable' ||
        lowerFlag == 'needs_auth' ||
        lowerFlag == 'subscriber_only' ||
        lowerFlag == 'premium_only') {
      final reason =
          (lowerFlag == 'needs_auth' ||
              lowerFlag == 'subscriber_only' ||
              lowerFlag == 'premium_only')
          ? 'Restricted or members-only video (skipped automatically)'
          : 'Unavailable playlist entry (skipped automatically)';
      return (PlaylistEntryAvailability.unavailable, reason);
    }
    return (PlaylistEntryAvailability.available, null);
  }

  String _normalizeProviderName(String rawProvider, String webpageUrl) {
    final lower = rawProvider.toLowerCase();
    if (lower == 'instagram' ||
        lower == 'instagramios' ||
        inferProviderFromUrl(webpageUrl) == 'Instagram') {
      return 'Instagram';
    }
    return rawProvider;
  }

  static (int?, FileSizeAccuracy) _resolveSizeAndAccuracy(
    Map<String, dynamic> obj,
  ) {
    final exact = _asInt(obj['filesize']);
    if (exact != null) return (exact, FileSizeAccuracy.exact);

    final estimated = _asInt(obj['filesize_approx']);
    if (estimated != null) return (estimated, FileSizeAccuracy.estimated);

    final fixtureBytes = _asInt(obj['file_size_bytes']);
    if (fixtureBytes != null) {
      final accuracy = switch (_nonEmptyStr(obj['size_accuracy'])) {
        'exact' => FileSizeAccuracy.exact,
        'estimated' => FileSizeAccuracy.estimated,
        _ => FileSizeAccuracy.unknown,
      };
      return (fixtureBytes, accuracy);
    }
    return (null, FileSizeAccuracy.unknown);
  }

  static bool _isDrmProtected(Object? val) {
    if (val is bool) return val;
    if (val is String) {
      final trimmed = val.trim();
      return trimmed.isNotEmpty && trimmed.toLowerCase() != 'false';
    }
    return false;
  }

  static String? _normalizeCodec(Object? val) {
    final raw = _nonEmptyStr(val);
    if (raw == null || raw.toLowerCase() == 'none') return null;
    return raw;
  }

  static bool _isCodecExplicitlyNone(Object? val) {
    final raw = _nonEmptyStr(val);
    return raw != null && raw.toLowerCase() == 'none';
  }

  static String? _nonEmptyStr(Object? val) {
    if (val is! String) return null;
    final trimmed = val.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _asInt(Object? val) {
    if (val is int) return val >= 0 ? val : null;
    if (val is num) {
      final d = val.toDouble();
      if (d.isFinite && d >= 0) return d.round();
    }
    return null;
  }

  static double? _asDouble(Object? val) {
    if (val is num) {
      final d = val.toDouble();
      return d.isFinite ? d : null;
    }
    return null;
  }
}
