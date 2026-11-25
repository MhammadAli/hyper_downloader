import 'package:equatable/equatable.dart';

/// Supported media platform identifiers.
enum MediaPlatformId { youtube, instagram, tiktok, facebook, generic }

/// Validated URL paired with its canonical downstream form and detected platform.
class NormalizedMediaUrl extends Equatable {
  final MediaPlatformId platformId;
  final String normalizedUrl;
  final bool isPlaylist;
  final String? shortcode;

  const NormalizedMediaUrl({
    required this.platformId,
    required this.normalizedUrl,
    this.isPlaylist = false,
    this.shortcode,
  });

  @override
  List<Object?> get props => [platformId, normalizedUrl, isPlaylist, shortcode];
}

/// Pluggable platform strategy so adding TikTok, Facebook, or new YouTube
/// behaviors only requires implementing and registering a strategy class.
abstract interface class PlatformStrategy {
  MediaPlatformId get id;

  String get displayName;

  String get analysisStatusMessage;

  bool matchesHost(String normalizedHost);

  NormalizedMediaUrl classifyAndNormalize(Uri uri, String rawUrl);

  String classifyError(String rawError);

  bool isTransientError(String rawError);
}
