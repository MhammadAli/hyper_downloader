import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/domain/platforms/facebook_platform_strategy.dart';
import 'package:hyper_download_client/domain/platforms/generic_platform_strategy.dart';
import 'package:hyper_download_client/domain/platforms/instagram_platform_strategy.dart';
import 'package:hyper_download_client/domain/platforms/media_platform.dart';
import 'package:hyper_download_client/domain/platforms/youtube_platform_strategy.dart';

/// Central URL validation and strategy dispatch registry.
/// Register new platforms (TikTok, Facebook, etc.) in [_strategies].
class PlatformRegistry {
  final List<PlatformStrategy> _strategies;
  final PlatformStrategy _fallback;

  const PlatformRegistry({
    List<PlatformStrategy>? strategies,
    this._fallback = const GenericPlatformStrategy(),
  }) : _strategies =
           strategies ??
           const [
             YoutubePlatformStrategy(),
             InstagramPlatformStrategy(),
             FacebookPlatformStrategy(),
           ];

  static String normalizeHost(String host) {
    var clean = host.trim().toLowerCase();
    while (clean.endsWith('.')) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  PlatformStrategy strategyForHost(String rawHost) {
    final host = normalizeHost(rawHost);
    if (host.isEmpty) return _fallback;
    for (final strategy in _strategies) {
      if (strategy.matchesHost(host)) {
        return strategy;
      }
    }
    return _fallback;
  }

  PlatformStrategy strategyForId(MediaPlatformId id) {
    for (final strategy in _strategies) {
      if (strategy.id == id) return strategy;
    }
    return _fallback;
  }

  PlatformStrategy? strategyForRawUrl(String rawUrl) {
    final parsed = Uri.tryParse(rawUrl.trim());
    if (parsed == null || parsed.host.isEmpty) return null;
    return strategyForHost(parsed.host);
  }

  /// Validates HTTP/HTTPS syntax and delegates normalization/rejection to the matched strategy.
  NormalizedMediaUrl classifyAndNormalize(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw const InvalidUrlException('Media URL cannot be empty.');
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) {
      throw InvalidUrlException("Invalid media URL: '$trimmed'.");
    }
    final scheme = parsed.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw InvalidUrlException(
        "Unsupported URL scheme '$scheme'. Only http and https URLs are supported.",
      );
    }
    if (parsed.host.trim().isEmpty) {
      throw const InvalidUrlException('Media URL must include a host.');
    }
    final strategy = strategyForHost(parsed.host);
    return strategy.classifyAndNormalize(parsed, trimmed);
  }

  String analysisStatusForRawUrl(String rawUrl) {
    final strategy = strategyForRawUrl(rawUrl) ?? _fallback;
    return strategy.analysisStatusMessage;
  }
}
