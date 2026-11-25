import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/domain/platforms/media_platform.dart';

/// Instagram public Reel strategy with canonical normalization, route validation,
/// and user-friendly error classification + secret redaction.
class InstagramPlatformStrategy implements PlatformStrategy {
  const InstagramPlatformStrategy();

  static const Set<String> _reservedRoutes = {
    'stories',
    'explore',
    'accounts',
    'direct',
    'p',
    'tv',
    'live',
    'api',
    'graphql',
    'share',
    'reel',
    'reels',
  };

  @override
  MediaPlatformId get id => MediaPlatformId.instagram;

  @override
  String get displayName => 'Instagram';

  @override
  String get analysisStatusMessage =>
      'Connecting to Instagram and checking available formats...';

  @override
  bool matchesHost(String normalizedHost) {
    return normalizedHost == 'instagram.com' ||
        normalizedHost.endsWith('.instagram.com');
  }

  @override
  NormalizedMediaUrl classifyAndNormalize(Uri uri, String rawUrl) {
    final segments = uri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    String? shortcode;
    if (segments.length == 2 && _isReelSegment(segments[0])) {
      shortcode = segments[1];
    } else if (segments.length == 3 &&
        _isReelSegment(segments[1]) &&
        !_reservedRoutes.contains(segments[0].toLowerCase())) {
      shortcode = segments[2];
    }

    if (shortcode != null) {
      if (!_isValidShortcode(shortcode)) {
        throw const InvalidUrlException(
          'Invalid Instagram Reel URL: missing or malformed Reel shortcode.',
        );
      }
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.instagram,
        normalizedUrl: 'https://www.instagram.com/reel/$shortcode/',
        isPlaylist: false,
        shortcode: shortcode,
      );
    }

    throw InvalidUrlException(_unsupportedMessage(segments));
  }

  @override
  String classifyError(String rawError) {
    final lower = rawError.toLowerCase();

    if (_containsAny(lower, const [
      'ffmpeg',
      'ffprobe',
      'postprocessing',
      'error merging',
      '[merger]',
      'muxing',
      'moov atom',
    ])) {
      return 'Failed to process video and audio streams with FFmpeg.';
    }

    if (_containsAny(lower, const [
      '429',
      'rate-limit',
      'rate limit',
      'too many requests',
      'please wait a few minutes',
    ])) {
      return 'Instagram temporarily rate-limited requests. Please wait a few minutes and try again.';
    }

    if (_containsAny(lower, const [
      'http error 404',
      '404: not found',
      'not found',
      'does not exist',
      'has been deleted',
      'been deleted',
      'removed',
      'broken',
      'no longer available',
    ])) {
      return 'This Instagram Reel is unavailable or has been deleted.';
    }

    if (_containsAny(lower, const [
      'account is private',
      'private reel',
      'private video',
      'this content is private',
      'not available to you',
    ])) {
      return 'This Instagram Reel is private or inaccessible.';
    }

    if (_containsAny(lower, const [
      'login required',
      'logged-in',
      'locked behind the login page',
      'need to log in',
      'sign in',
      'use --cookies',
      'cookies are needed',
      'cookies-from-browser',
      'authentication',
    ])) {
      return 'Instagram requires login to view this Reel. Only public Reels are supported without login.';
    }

    if (_containsAny(lower, const [
      'empty media response',
      'checkpoint',
      'challenge_required',
      'http error 403',
      '403',
      'csrf',
      'unable to extract',
      'blocked',
      'automated',
    ])) {
      return 'Instagram temporarily restricted this request. Please try again later.';
    }

    if (lower.contains('before media transfer started')) {
      return 'Timed out while connecting to Instagram. Check your internet connection and try again.';
    }

    if (_containsAny(lower, const [
      'timed out',
      'timeout',
      'could not resolve',
      'curl: (6)',
      'curl: (7)',
      'curl: (28)',
      'transporterror',
      'urlopen',
      'gaierror',
      'name or service not known',
      'temporary failure in name resolution',
      'nodename nor servname',
      'remote end closed',
      'incompleteread',
      'eof occurred',
      'connection',
      'network',
      'ssl',
      'tls',
      'dns',
      'reset by peer',
    ])) {
      return 'Network error while contacting Instagram. Check your internet connection and try again.';
    }

    return 'Instagram extraction failed. Please verify the Reel is public and try again.';
  }

  @override
  bool isTransientError(String rawError) {
    final lower = rawError.toLowerCase();
    return _containsAny(lower, const [
      'curl: (6)',
      'curl: (7)',
      'curl: (28)',
      'transporterror',
      'urlopen',
      'gaierror',
      'temporary failure in name resolution',
      'connection reset',
      'remote end closed',
      'incompleteread',
      'eof occurred',
      'unexpected eof',
      'timed out',
      'could not resolve',
      'failed to connect',
    ]);
  }

  /// Redacts cookies, authorization headers, and signed tokens from diagnostic logs.
  static String redactSensitiveDiagnostics(String raw) {
    final lineRedacted = _redactMarkers(raw, const [
      'cookie:',
      'authorization:',
    ], untilEol: true);
    return _redactMarkers(lineRedacted, const [
      'sessionid=',
      'csrftoken=',
      'ds_user_id=',
      'oh=',
      '_nc_ohc=',
    ], untilEol: false);
  }

  static String _redactMarkers(
    String input,
    List<String> markers, {
    required bool untilEol,
  }) {
    final out = StringBuffer();
    final lower = input.toLowerCase();
    var idx = 0;

    while (idx < input.length) {
      String? matched;
      for (final marker in markers) {
        if (lower.startsWith(marker, idx)) {
          matched = marker;
          break;
        }
      }

      if (matched != null) {
        final prefixEnd = idx + matched.length;
        out.write(input.substring(idx, prefixEnd));
        var valStart = prefixEnd;
        while (valStart < input.length && untilEol && input[valStart] == ' ') {
          out.write(' ');
          valStart++;
        }
        var valEnd = valStart;
        while (valEnd < input.length) {
          final ch = input[valEnd];
          final stop = untilEol
              ? (ch == '\r' || ch == '\n')
              : (ch == '&' ||
                    ch == ';' ||
                    ch == '"' ||
                    ch == "'" ||
                    ch == ')' ||
                    ch == ']' ||
                    ch.trim().isEmpty);
          if (stop) break;
          valEnd++;
        }
        out.write('[REDACTED]');
        idx = valEnd;
      } else {
        out.write(input[idx]);
        idx++;
      }
    }

    return out.toString();
  }

  static bool _isReelSegment(String segment) {
    final lower = segment.toLowerCase();
    return lower == 'reel' || lower == 'reels';
  }

  static bool _isValidShortcode(String code) {
    if (code.length < 5 || code.length > 40) return false;
    for (var i = 0; i < code.length; i++) {
      final cu = code.codeUnitAt(i);
      final isAlphaNum =
          (cu >= 48 && cu <= 57) ||
          (cu >= 65 && cu <= 90) ||
          (cu >= 97 && cu <= 122);
      if (!isAlphaNum && cu != 95 && cu != 45) {
        return false;
      }
    }
    return true;
  }

  static String _unsupportedMessage(List<String> segments) {
    if (segments.isEmpty) {
      return 'Instagram profile, feed, and bulk downloads are not supported. Please paste a single public Instagram Reel URL.';
    }

    final first = segments[0].toLowerCase();
    final second = segments.length > 1 ? segments[1].toLowerCase() : null;

    switch (first) {
      case 'stories':
        return 'Instagram Stories are not supported. Only public individual Instagram Reels are supported.';
      case 'p':
        return 'Instagram posts and carousels (/p/) are not supported. Only public individual Instagram Reels are supported.';
      case 'tv':
        return 'Instagram IGTV links (/tv/) are not supported. Only public individual Instagram Reels are supported.';
      case 'live':
        return 'Instagram Live streams are not supported. Only public individual Instagram Reels are supported.';
      case 'reel':
      case 'reels':
        if (segments.length == 1) {
          return 'The Instagram Reels feed cannot be downloaded. Please paste a direct public Instagram Reel URL.';
        }
        if (segments.length == 2) {
          return 'Invalid Instagram Reel URL: missing or malformed Reel shortcode.';
        }
      case 'explore':
      case 'accounts':
      case 'direct':
      case 'share':
        return 'Instagram profile, feed, and bulk downloads are not supported. Please paste a single public Instagram Reel URL.';
    }

    if (second == 'live') {
      return 'Instagram Live streams are not supported. Only public individual Instagram Reels are supported.';
    }
    if (segments.length == 1 ||
        (segments.length == 2 && (second == 'reels' || second == 'tagged'))) {
      return 'Instagram profile, feed, and bulk downloads are not supported. Please paste a single public Instagram Reel URL.';
    }
    return 'Unsupported Instagram URL. Only public individual Instagram Reel URLs (/reel/... or /reels/...) are supported.';
  }

  static bool _containsAny(String haystackLower, List<String> needles) {
    for (final needle in needles) {
      if (haystackLower.contains(needle)) return true;
    }
    return false;
  }
}
