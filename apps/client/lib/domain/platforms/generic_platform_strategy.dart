import 'package:hyper_download_client/domain/platforms/media_platform.dart';

/// Fallback strategy for generic `yt-dlp`-compatible HTTP/HTTPS URLs.
class GenericPlatformStrategy implements PlatformStrategy {
  const GenericPlatformStrategy();

  @override
  MediaPlatformId get id => MediaPlatformId.generic;

  @override
  String get displayName => 'Web';

  @override
  String get analysisStatusMessage =>
      'Analyzing link and discovering available qualities...';

  @override
  bool matchesHost(String normalizedHost) => true;

  @override
  NormalizedMediaUrl classifyAndNormalize(Uri uri, String rawUrl) {
    final trimmed = rawUrl.trim();
    final listId = uri.queryParameters['list']?.trim() ?? '';
    final pathLower = uri.path.toLowerCase();
    final isPlaylist = pathLower.contains('/playlist')
        ? listId.isNotEmpty
        : (listId.isNotEmpty && !listId.startsWith('RD'));

    return NormalizedMediaUrl(
      platformId: MediaPlatformId.generic,
      normalizedUrl: trimmed,
      isPlaylist: isPlaylist,
    );
  }

  @override
  String classifyError(String rawError) {
    final trimmed = rawError.trim();
    return trimmed.isEmpty ? 'Media extraction failed.' : trimmed;
  }

  @override
  bool isTransientError(String rawError) =>
      rawError.contains('HTTP Error 403');
}
