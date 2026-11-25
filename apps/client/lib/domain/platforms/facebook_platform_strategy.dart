import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/domain/platforms/instagram_platform_strategy.dart';
import 'package:hyper_download_client/domain/platforms/media_platform.dart';

/// Facebook video, Reel, Watch, Live, Group, and Share-link strategy (pure Dart).
/// Models URL canonicalization and error mapping after `yt_dlp/extractor/facebook.py`.
class FacebookPlatformStrategy implements PlatformStrategy {
  const FacebookPlatformStrategy();

  static const Set<String> _unsupportedRootRoutes = {
    'stories',
    'explore',
    'marketplace',
    'events',
    'gaming',
    'friends',
    'messages',
    'notifications',
    'bookmarks',
    'settings',
    'login',
    'reg',
    'recover',
    'privacy',
    'help',
    'pages',
    'photo',
    'photo.php',
    'photos',
    'albums',
    'profile.php',
  };

  @override
  MediaPlatformId get id => MediaPlatformId.facebook;

  @override
  String get displayName => 'Facebook';

  @override
  String get analysisStatusMessage =>
      'Connecting to Facebook and checking available formats...';

  @override
  bool matchesHost(String normalizedHost) {
    return _isFacebookHost(normalizedHost);
  }

  @override
  NormalizedMediaUrl classifyAndNormalize(Uri uri, String rawUrl) {
    return _classifyUri(uri, depth: 0);
  }

  NormalizedMediaUrl _classifyUri(Uri uri, {required int depth}) {
    if (depth > 3) {
      throw const InvalidUrlException(
        'Invalid Facebook plugin embed URL: too many nested redirects.',
      );
    }

    final host = _normalizeHost(uri.host);
    final segments = uri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    // 1. Short domain: https://fb.watch/{code}/
    if (host == 'fb.watch' || host.endsWith('.fb.watch')) {
      if (segments.isEmpty) {
        throw const InvalidUrlException(
          'Invalid fb.watch link: missing video code.',
        );
      }
      final code = segments.first;
      if (!_isValidToken(code)) {
        throw const InvalidUrlException(
          'Invalid fb.watch link: malformed video code.',
        );
      }
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.facebook,
        normalizedUrl: 'https://fb.watch/$code/',
        isPlaylist: false,
        shortcode: code,
      );
    }

    if (segments.isEmpty) {
      throw const InvalidUrlException(
        'Facebook home and profile feeds cannot be downloaded. Please paste a specific public Facebook video, Reel, or Watch URL.',
      );
    }

    final firstLower = segments[0].toLowerCase();

    // 2. Embedded video plugin wrapper: /plugins/video.php?href=<innerUrl>
    if (segments.length >= 2 &&
        firstLower == 'plugins' &&
        segments[1].toLowerCase() == 'video.php') {
      final href = uri.queryParameters['href']?.trim();
      if (href == null || href.isEmpty) {
        throw const InvalidUrlException(
          'Invalid Facebook video plugin URL: missing href parameter.',
        );
      }
      final innerUri = Uri.tryParse(href);
      if (innerUri == null ||
          !innerUri.hasScheme ||
          !_isFacebookHost(_normalizeHost(innerUri.host))) {
        throw const InvalidUrlException(
          'Invalid Facebook video plugin URL: unsupported embedded target.',
        );
      }
      return _classifyUri(innerUri, depth: depth + 1);
    }

    // 3. Explicit non-video routes
    if (_unsupportedRootRoutes.contains(firstLower)) {
      throw InvalidUrlException(_unsupportedRouteMessage(firstLower));
    }

    // 4. Share redirect wrappers: /share/v/{code}, /share/r/{code}, /share/{code}
    if (firstLower == 'share') {
      if (segments.length >= 3 &&
          (segments[1].toLowerCase() == 'v' ||
              segments[1].toLowerCase() == 'r' ||
              segments[1].toLowerCase() == 'p') &&
          _isValidToken(segments[2])) {
        final kind = segments[1].toLowerCase();
        final code = segments[2];
        return NormalizedMediaUrl(
          platformId: MediaPlatformId.facebook,
          normalizedUrl: 'https://www.facebook.com/share/$kind/$code/',
          isPlaylist: false,
          shortcode: code,
        );
      }
      if (segments.length == 2 && _isValidToken(segments[1])) {
        final code = segments[1];
        return NormalizedMediaUrl(
          platformId: MediaPlatformId.facebook,
          normalizedUrl: 'https://www.facebook.com/share/$code/',
          isPlaylist: false,
          shortcode: code,
        );
      }
      throw const InvalidUrlException(
        'Invalid Facebook share link: missing or malformed share code.',
      );
    }

    // 5. Reels: /reel/{id}, /reels/{id}, /{user}/reel/{id}
    if (firstLower == 'reel' || firstLower == 'reels') {
      if (segments.length == 1) {
        throw const InvalidUrlException(
          'The Facebook Reels feed cannot be downloaded. Please paste a direct public Facebook Reel URL.',
        );
      }
      final reelId = segments[1];
      if (!_isValidToken(reelId)) {
        throw const InvalidUrlException(
          'Invalid Facebook Reel URL: missing or malformed Reel ID.',
        );
      }
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.facebook,
        normalizedUrl: 'https://www.facebook.com/reel/$reelId/',
        isPlaylist: false,
        shortcode: reelId,
      );
    }
    if (segments.length >= 3 &&
        (segments[1].toLowerCase() == 'reel' ||
            segments[1].toLowerCase() == 'reels')) {
      final reelId = segments[2];
      if (!_isValidToken(reelId)) {
        throw const InvalidUrlException(
          'Invalid Facebook Reel URL: malformed Reel ID.',
        );
      }
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.facebook,
        normalizedUrl: 'https://www.facebook.com/reel/$reelId/',
        isPlaylist: false,
        shortcode: reelId,
      );
    }

    // 6. Watch & Watch Live: /watch/?v={id}, /watch/live/?v={id}, /watch/{id}
    if (firstLower == 'watch') {
      final vParam = uri.queryParameters['v']?.trim();
      final isLive = segments.length >= 2 && segments[1].toLowerCase() == 'live';
      if (vParam != null && vParam.isNotEmpty) {
        if (!_isValidToken(vParam)) {
          throw const InvalidUrlException(
            'Invalid Facebook Watch URL: malformed video ID.',
          );
        }
        final canonical = isLive
            ? 'https://www.facebook.com/watch/live/?v=$vParam'
            : 'https://www.facebook.com/watch/?v=$vParam';
        return NormalizedMediaUrl(
          platformId: MediaPlatformId.facebook,
          normalizedUrl: canonical,
          isPlaylist: false,
          shortcode: vParam,
        );
      }
      if (segments.length == 2 && !isLive && _isNumericId(segments[1])) {
        final id = segments[1];
        return NormalizedMediaUrl(
          platformId: MediaPlatformId.facebook,
          normalizedUrl: 'https://www.facebook.com/watch/?v=$id',
          isPlaylist: false,
          shortcode: id,
        );
      }
      throw const InvalidUrlException(
        'The Facebook Watch feed cannot be downloaded. Please paste a direct Watch URL containing ?v=<video_id>.',
      );
    }

    // 7. video.php & /video/video.php?v={id}
    if (firstLower == 'video.php' ||
        (firstLower == 'video' &&
            segments.length >= 2 &&
            segments[1].toLowerCase() == 'video.php')) {
      final vParam = uri.queryParameters['v']?.trim() ??
          uri.queryParameters['id']?.trim();
      if (vParam == null || !_isValidToken(vParam)) {
        throw const InvalidUrlException(
          'Invalid Facebook video.php URL: missing or malformed v= video ID.',
        );
      }
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.facebook,
        normalizedUrl: 'https://www.facebook.com/watch/?v=$vParam',
        isPlaylist: false,
        shortcode: vParam,
      );
    }

    // 8. /story.php?story_fbid=...&id=... & /permalink.php?story_fbid=...
    if (firstLower == 'story.php' || firstLower == 'permalink.php') {
      final storyFbid = uri.queryParameters['story_fbid']?.trim();
      if (storyFbid == null || !_isValidToken(storyFbid)) {
        throw InvalidUrlException(
          'Invalid Facebook $firstLower URL: missing story_fbid parameter.',
        );
      }
      final ownerId = uri.queryParameters['id']?.trim();
      final ownerQuery =
          (ownerId != null && ownerId.isNotEmpty && _isValidToken(ownerId))
          ? '&id=$ownerId'
          : '';
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.facebook,
        normalizedUrl:
            'https://www.facebook.com/$firstLower?story_fbid=$storyFbid$ownerQuery',
        isPlaylist: false,
        shortcode: storyFbid,
      );
    }

    // 9. /videos/{id}, /{user}/videos/{id}, /{user}/videos/{slug}/{id}
    if (firstLower == 'videos' &&
        segments.length >= 2 &&
        _isValidToken(segments[1])) {
      final videoId = segments[1];
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.facebook,
        normalizedUrl: 'https://www.facebook.com/watch/?v=$videoId',
        isPlaylist: false,
        shortcode: videoId,
      );
    }
    if (segments.length >= 3 && segments[1].toLowerCase() == 'videos') {
      final videoId = segments.length >= 4 && _isNumericId(segments[3])
          ? segments[3]
          : segments[2];
      if (!_isValidToken(videoId)) {
        throw const InvalidUrlException(
          'Invalid Facebook video URL: missing or malformed video ID.',
        );
      }
      final user = segments[0];
      final canonical = segments.length >= 4 && _isNumericId(segments[3])
          ? 'https://www.facebook.com/$user/videos/${segments[2]}/${segments[3]}/'
          : 'https://www.facebook.com/$user/videos/$videoId/';
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.facebook,
        normalizedUrl: canonical,
        isPlaylist: false,
        shortcode: videoId,
      );
    }

    // 10. Groups: /groups/{group}/posts/{id}, /groups/{group}/permalink/{id}, /groups/{group}/videos/{id}
    if (firstLower == 'groups') {
      if (segments.length >= 4 &&
          (segments[2].toLowerCase() == 'posts' ||
              segments[2].toLowerCase() == 'permalink' ||
              segments[2].toLowerCase() == 'videos')) {
        final groupId = segments[1];
        final kind = segments[2].toLowerCase();
        final itemId = segments[3];
        if (!_isValidToken(groupId) || !_isValidToken(itemId)) {
          throw const InvalidUrlException(
            'Invalid Facebook group URL: missing or malformed post/video ID.',
          );
        }
        return NormalizedMediaUrl(
          platformId: MediaPlatformId.facebook,
          normalizedUrl:
              'https://www.facebook.com/groups/$groupId/$kind/$itemId/',
          isPlaylist: false,
          shortcode: itemId,
        );
      }
      throw const InvalidUrlException(
        'Facebook Group feeds cannot be downloaded. Please paste a specific group post or video URL.',
      );
    }

    // 11. User/Page posts: /{user}/posts/{id_or_pfbid} (also support ?v= on /posts if present)
    if (segments.length >= 3 && segments[1].toLowerCase() == 'posts') {
      final user = segments[0];
      final postId = segments[2];
      if (!_isValidToken(postId)) {
        throw const InvalidUrlException(
          'Invalid Facebook post URL: missing or malformed post ID.',
        );
      }
      return NormalizedMediaUrl(
        platformId: MediaPlatformId.facebook,
        normalizedUrl: 'https://www.facebook.com/$user/posts/$postId/',
        isPlaylist: false,
        shortcode: postId,
      );
    }

    // 12. Reject /{user}/photos/... or /{user}/videos (without id) or bare /{user}
    if (segments.length >= 2 && segments[1].toLowerCase() == 'photos') {
      throw const InvalidUrlException(
        'Facebook photo posts are not supported. Only Facebook videos and Reels can be downloaded.',
      );
    }

    throw const InvalidUrlException(
      'Unsupported Facebook URL. Please paste a direct link to a public Facebook video, Reel, Watch video, or video post.',
    );
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
      return 'Failed to process Facebook video and audio streams with FFmpeg.';
    }

    if (_containsAny(lower, const [
      'brokenpipeerror',
      'broken pipe',
      'errno 22',
      'errno 32',
      'file name too long',
      'no space left',
      'permission denied',
    ])) {
      return 'Local file or stream error while saving media. Please check folder permissions and disk space, then try again.';
    }

    if (_containsAny(lower, const [
      'age-restricted',
      'age restricted',
      'age gate',
      '18+',
      'mature content',
      'inappropriate for some users',
    ])) {
      return 'This Facebook video is age-restricted and requires an authenticated account.';
    }

    if (_containsAny(lower, const [
      'login required',
      'you must log in',
      'must log in to continue',
      'logged-in',
      'need to log in',
      'sign in',
      'use --cookies',
      'cookies are needed',
      'cookies-from-browser',
      'registered users',
      'this video is private',
      'private video',
      "content isn't available right now",
      'content is not available right now',
    ])) {
      return 'This Facebook video is private or requires login. Only public Facebook videos and Reels are supported.';
    }

    if (_containsAny(lower, const [
      '429',
      'rate-limit',
      'rate limit',
      'too many requests',
      'please wait a few minutes',
    ])) {
      return 'Facebook temporarily rate-limited requests. Please wait a few minutes and try again.';
    }

    if (_containsAny(lower, const [
      'http error 404',
      '404: not found',
      'not found',
      'does not exist',
      'has been deleted',
      'been deleted',
      'removed',
      'expired',
      'no longer available',
      'no video formats found',
      "there's no video",
      'no video on this',
    ])) {
      return 'This Facebook video is unavailable, has been deleted, or the post does not contain a playable video.';
    }

    if (_containsAny(lower, const [
      'cannot parse data',
      'unable to extract',
      'empty media response',
      'checkpoint',
      'challenge_required',
      'http error 403',
      '403',
      'blocked',
      'automated',
    ])) {
      return 'Facebook temporarily restricted or changed this page response. Please try again later.';
    }

    if (lower.contains('before media transfer started') ||
        _containsAny(lower, const [
          'timed out',
          'timeout',
          'could not resolve',
          'curl: (6)',
          'curl: (7)',
          'curl: (28)',
          'transporterror',
          'urlopen',
          'gaierror',
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
      return 'Network error or timeout while contacting Facebook. Check your internet connection and try again.';
    }

    return 'Facebook extraction failed. Please verify the video or Reel is public and try again.';
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
  static String redactSensitiveDiagnostics(String raw) =>
      InstagramPlatformStrategy.redactSensitiveDiagnostics(raw);

  static String _unsupportedRouteMessage(String route) {
    switch (route) {
      case 'stories':
        return 'Facebook Stories are temporary and unsupported here. Only public Facebook videos and Reels are supported.';
      case 'photo':
      case 'photo.php':
      case 'photos':
      case 'albums':
        return 'Facebook photo links are not supported. Only Facebook videos and Reels can be downloaded.';
      case 'marketplace':
      case 'events':
      case 'gaming':
      case 'friends':
      case 'messages':
      case 'notifications':
      case 'bookmarks':
      case 'settings':
      case 'login':
      case 'reg':
      case 'recover':
      case 'privacy':
      case 'help':
      case 'pages':
      case 'profile.php':
        return 'This Facebook page is not a downloadable video or Reel. Please paste a direct video or Reel URL.';
      default:
        return 'Unsupported Facebook URL. Please paste a direct link to a public Facebook video or Reel.';
    }
  }

  static bool _isFacebookHost(String host) {
    return host == 'facebook.com' ||
        host.endsWith('.facebook.com') ||
        host == 'fb.watch' ||
        host.endsWith('.fb.watch') ||
        host == 'fb.com' ||
        host.endsWith('.fb.com');
  }

  static String _normalizeHost(String host) {
    var clean = host.trim().toLowerCase();
    while (clean.endsWith('.')) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  static bool _isNumericId(String value) {
    if (value.isEmpty || value.length > 32) return false;
    for (var i = 0; i < value.length; i++) {
      final cu = value.codeUnitAt(i);
      if (cu < 48 || cu > 57) return false;
    }
    return true;
  }

  static bool _isValidToken(String value) {
    if (value.length < 3 || value.length > 160) return false;
    for (var i = 0; i < value.length; i++) {
      final cu = value.codeUnitAt(i);
      final ok =
          (cu >= 48 && cu <= 57) ||
          (cu >= 65 && cu <= 90) ||
          (cu >= 97 && cu <= 122) ||
          cu == 95 || // _
          cu == 45 || // -
          cu == 46; // .
      if (!ok) return false;
    }
    return true;
  }

  static bool _containsAny(String haystack, List<String> needles) {
    for (final needle in needles) {
      if (haystack.contains(needle)) return true;
    }
    return false;
  }
}
