import 'package:hyper_download_client/domain/platforms/media_platform.dart';

/// YouTube video, Shorts, and finite playlist strategy (ignoring `RD...` auto-mixes).
class YoutubePlatformStrategy implements PlatformStrategy {
  const YoutubePlatformStrategy();

  @override
  MediaPlatformId get id => MediaPlatformId.youtube;

  @override
  String get displayName => 'YouTube';

  @override
  String get analysisStatusMessage =>
      'Analyzing link and discovering available qualities...';

  @override
  bool matchesHost(String normalizedHost) {
    return normalizedHost == 'youtube.com' ||
        normalizedHost.endsWith('.youtube.com') ||
        normalizedHost == 'youtu.be' ||
        normalizedHost.endsWith('.youtu.be') ||
        normalizedHost == 'youtube-nocookie.com' ||
        normalizedHost.endsWith('.youtube-nocookie.com');
  }

  @override
  NormalizedMediaUrl classifyAndNormalize(Uri uri, String rawUrl) {
    final trimmed = rawUrl.trim();
    final listId = uri.queryParameters['list']?.trim() ?? '';
    final pathLower = uri.path.toLowerCase();

    final isPlaylist = pathLower.contains('/playlist')
        ? listId.isNotEmpty
        : (listId.isNotEmpty && !listId.startsWith('RD'));

    final normalizedUrl = isPlaylist && listId.isNotEmpty
        ? 'https://www.youtube.com/playlist?list=$listId'
        : trimmed;

    return NormalizedMediaUrl(
      platformId: MediaPlatformId.youtube,
      normalizedUrl: normalizedUrl,
      isPlaylist: isPlaylist,
    );
  }

  @override
  String classifyError(String rawError) {
    final trimmed = rawError.trim();
    return trimmed.isEmpty ? 'YouTube extraction failed.' : trimmed;
  }

  @override
  bool isTransientError(String rawError) =>
      rawError.contains('HTTP Error 403');
}
