import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/domain/platforms/instagram_platform_strategy.dart';
import 'package:hyper_download_client/domain/platforms/media_platform.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';

void main() {
  const registry = PlatformRegistry();

  group('PlatformRegistry URL normalization & classification', () {
    test('normalizes YouTube watch, youtu.be, and playlist URLs', () {
      final watch = registry.classifyAndNormalize(
        'https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&index=2',
      );
      expect(watch.platformId, MediaPlatformId.youtube);
      expect(watch.isPlaylist, isTrue);

      final single = registry.classifyAndNormalize(
        'https://youtu.be/dQw4w9WgXcQ?t=10',
      );
      expect(single.platformId, MediaPlatformId.youtube);
      expect(single.isPlaylist, isFalse);
    });

    test('canonicalizes Instagram reel and profile-scoped reel URLs', () {
      final reel = registry.classifyAndNormalize(
        'https://www.instagram.com/reel/C8x123AbC_/?utm_source=ig_web_copy_link',
      );
      expect(reel.platformId, MediaPlatformId.instagram);
      expect(reel.isPlaylist, isFalse);
      expect(reel.shortcode, 'C8x123AbC_');
      expect(
        reel.normalizedUrl,
        'https://www.instagram.com/reel/C8x123AbC_/',
      );

      final userReel = registry.classifyAndNormalize(
        'https://instagram.com/creatorname/reel/AbCdEf123/',
      );
      expect(userReel.platformId, MediaPlatformId.instagram);
      expect(userReel.shortcode, 'AbCdEf123');
      expect(
        userReel.normalizedUrl,
        'https://www.instagram.com/reel/AbCdEf123/',
      );
    });

    test('rejects unsupported Instagram routes and invalid schemes', () {
      expect(
        () => registry.classifyAndNormalize('https://www.instagram.com/explore/'),
        throwsA(isA<InvalidUrlException>()),
      );
      expect(
        () => registry.classifyAndNormalize(
          'https://instagram.com/share/reel/AbCdEf123/',
        ),
        throwsA(isA<InvalidUrlException>()),
      );
      expect(
        () => registry.classifyAndNormalize('ftp://example.com/file.mp4'),
        throwsA(isA<InvalidUrlException>()),
      );
      expect(
        () => registry.classifyAndNormalize('   '),
        throwsA(isA<InvalidUrlException>()),
      );
    });

    test('dispatches built-in Facebook URLs, unrecognized hosts, and custom strategies', () {
      final facebook = registry.classifyAndNormalize(
        'https://www.facebook.com/watch/?v=1234567890',
      );
      expect(facebook.platformId, MediaPlatformId.facebook);

      final generic = registry.classifyAndNormalize(
        'https://www.tiktok.com/@user/video/1234567890',
      );
      expect(generic.platformId, MediaPlatformId.generic);

      final customRegistry = PlatformRegistry(
        strategies: [
          ...registry.classifyAndNormalize('https://www.youtube.com/watch?v=x')
                  .platformId ==
              MediaPlatformId.youtube
              ? const [_FakeTikTokStrategy()]
              : const [],
        ],
      );
      final tiktok = customRegistry.classifyAndNormalize(
        'https://www.tiktok.com/@user/video/1234567890',
      );
      expect(tiktok.platformId, MediaPlatformId.tiktok);
    });
  });

  group('Instagram error classification & redaction', () {
    const instagram = InstagramPlatformStrategy();

    test('maps Instagram login/checkpoint/rate-limit diagnostics cleanly', () {
      expect(
        instagram.classifyError('HTTP Error 401: login required'),
        contains('requires login'),
      );
      expect(
        instagram.classifyError('429 Too Many Requests: rate limit'),
        contains('rate-limited'),
      );
      expect(
        instagram.isTransientError('curl: (28) Operation timed out'),
        isTrue,
      );
      expect(
        instagram.isTransientError('429 Too Many Requests'),
        isFalse,
      );
    });

    test('redacts sensitive session cookies and bearer tokens', () {
      final redacted = InstagramPlatformStrategy.redactSensitiveDiagnostics(
        'Cookie: sessionid=secret123; csrftoken=tok999; Authorization: Bearer abc.def.ghi',
      );
      expect(redacted, isNot(contains('secret123')));
      expect(redacted, isNot(contains('tok999')));
      expect(redacted, isNot(contains('abc.def.ghi')));
    });
  });
}

class _FakeTikTokStrategy implements PlatformStrategy {
  const _FakeTikTokStrategy();

  @override
  MediaPlatformId get id => MediaPlatformId.tiktok;

  @override
  String get displayName => 'TikTok';

  @override
  String get analysisStatusMessage => 'Analyzing TikTok link...';

  @override
  bool matchesHost(String normalizedHost) =>
      normalizedHost == 'tiktok.com' || normalizedHost.endsWith('.tiktok.com');

  @override
  NormalizedMediaUrl classifyAndNormalize(Uri uri, String rawUrl) =>
      NormalizedMediaUrl(
        platformId: MediaPlatformId.tiktok,
        normalizedUrl: uri.toString(),
      );

  @override
  String classifyError(String rawError) => rawError;

  @override
  bool isTransientError(String rawError) => false;
}
