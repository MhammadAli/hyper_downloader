import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/core/utils/filename_sanitizer.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_tool_paths.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_yt_dlp_datasource.dart';
import 'package:hyper_download_client/data/parsers/yt_dlp_json_parser.dart';
import 'package:hyper_download_client/data/parsers/yt_dlp_progress_parser.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/platforms/facebook_platform_strategy.dart';
import 'package:hyper_download_client/domain/platforms/media_platform.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';

void main() {
  const registry = PlatformRegistry();
  const facebook = FacebookPlatformStrategy();
  const parser = YtDlpJsonParser();

  group('FacebookPlatformStrategy URL normalization & validation', () {
    test('normalizes standard videos, watch, watch/live, and video.php', () {
      final userVideo = registry.classifyAndNormalize(
        'https://m.facebook.com/nasa/videos/10158534112345678/?ref=share',
      );
      expect(userVideo.platformId, MediaPlatformId.facebook);
      expect(
        userVideo.normalizedUrl,
        'https://www.facebook.com/nasa/videos/10158534112345678/',
      );
      expect(userVideo.shortcode, '10158534112345678');

      final slugVideo = registry.classifyAndNormalize(
        'https://web.facebook.com/nasa/videos/launch-recap/987654321/',
      );
      expect(slugVideo.shortcode, '987654321');

      final watch = registry.classifyAndNormalize(
        'https://ar-ar.facebook.com/watch/?v=1122334455&ref=search',
      );
      expect(
        watch.normalizedUrl,
        'https://www.facebook.com/watch/?v=1122334455',
      );
      expect(watch.shortcode, '1122334455');

      final live = registry.classifyAndNormalize(
        'https://www.facebook.com/watch/live/?v=99887766',
      );
      expect(
        live.normalizedUrl,
        'https://www.facebook.com/watch/live/?v=99887766',
      );

      final videoPhp = registry.classifyAndNormalize(
        'https://mbasic.facebook.com/video/video.php?v=55443322',
      );
      expect(
        videoPhp.normalizedUrl,
        'https://www.facebook.com/watch/?v=55443322',
      );
      expect(videoPhp.shortcode, '55443322');
    });

    test('normalizes Reels, Posts/pfbid, Story/Permalink, Groups, Share, and fb.watch', () {
      final reel = registry.classifyAndNormalize(
        'https://www.facebook.com/reel/4567891230/?s=yWDuG2',
      );
      expect(
        reel.normalizedUrl,
        'https://www.facebook.com/reel/4567891230/',
      );
      expect(reel.shortcode, '4567891230');

      final pfbidPost = registry.classifyAndNormalize(
        'https://www.facebook.com/creator/posts/pfbid02AbCdEfGhIjKlMnOpQrStUvWxYz12345/',
      );
      expect(pfbidPost.platformId, MediaPlatformId.facebook);
      expect(
        pfbidPost.shortcode,
        'pfbid02AbCdEfGhIjKlMnOpQrStUvWxYz12345',
      );

      final storyPhp = registry.classifyAndNormalize(
        'https://m.facebook.com/story.php?story_fbid=pfbid09XyZ&id=100012345',
      );
      expect(
        storyPhp.normalizedUrl,
        'https://www.facebook.com/story.php?story_fbid=pfbid09XyZ&id=100012345',
      );

      final groupPost = registry.classifyAndNormalize(
        'https://www.facebook.com/groups/flutterdevs/posts/9988112233/?mibextid=abc',
      );
      expect(
        groupPost.normalizedUrl,
        'https://www.facebook.com/groups/flutterdevs/posts/9988112233/',
      );

      final fbWatch = registry.classifyAndNormalize(
        'https://fb.watch/sTr123AbC_/?mibextid=nnl',
      );
      expect(fbWatch.normalizedUrl, 'https://fb.watch/sTr123AbC_/');
      expect(fbWatch.shortcode, 'sTr123AbC_');

      final shareR = registry.classifyAndNormalize(
        'https://www.facebook.com/share/r/1AbCdEf99/?mibextid=wwXIfr',
      );
      expect(
        shareR.normalizedUrl,
        'https://www.facebook.com/share/r/1AbCdEf99/',
      );

      final pluginEmbed = registry.classifyAndNormalize(
        'https://www.facebook.com/plugins/video.php?href=https%3A%2F%2Fwww.facebook.com%2Freel%2F777888999%2F',
      );
      expect(
        pluginEmbed.normalizedUrl,
        'https://www.facebook.com/reel/777888999/',
      );
      expect(pluginEmbed.shortcode, '777888999');
    });

    test('rejects non-video feeds, profiles, stories, photos, and marketplace', () {
      for (final invalid in const [
        'https://www.facebook.com/',
        'https://www.facebook.com/watch/',
        'https://www.facebook.com/reels/',
        'https://www.facebook.com/groups/flutterdevs/',
        'https://www.facebook.com/photo.php?fbid=123',
        'https://www.facebook.com/stories/user/123/',
        'https://www.facebook.com/marketplace/',
        'https://www.facebook.com/somepage',
      ]) {
        expect(
          () => registry.classifyAndNormalize(invalid),
          throwsA(isA<InvalidUrlException>()),
          reason: 'Expected InvalidUrlException for $invalid',
        );
      }
    });
  });

  group('YtDlpJsonParser & MediaOptionSynthesizer for Facebook payloads', () {
    test('parses Facebook DASH video+audio streams into FFmpeg merge options', () {
      final raw = jsonEncode({
        'id': '123456789012345',
        'title': 'Facebook',
        'description':
            'Clean Architecture Live Demo on Windows\nMore details in caption.',
        'uploader': 'Flutter Community',
        'duration': 94.0,
        'webpage_url': 'https://www.facebook.com/watch/?v=123456789012345',
        'extractor_key': 'Facebook',
        'formats': [
          {
            'format_id': 'dash_v_1080',
            'ext': 'mp4',
            'height': 1080,
            'width': 1920,
            'fps': 30,
            'vcodec': 'avc1.64002a',
            'acodec': 'none',
            'filesize': 42000000,
          },
          {
            'format_id': 'dash_v_720',
            'ext': 'mp4',
            'height': 720,
            'width': 1280,
            'fps': 30,
            'vcodec': 'avc1.4d401f',
            'acodec': 'none',
            'filesize': 21000000,
          },
          {
            'format_id': 'dash_a_128',
            'ext': 'm4a',
            'vcodec': 'none',
            'acodec': 'mp4a.40.2',
            'abr': 128,
            'filesize': 2000000,
          },
        ],
      });

      final inspection = parser.parseMediaInspection(raw);
      expect(inspection.providerName, 'Facebook');
      expect(inspection.title, 'Clean Architecture Live Demo on Windows');
      expect(inspection.videoOptions, hasLength(2));
      expect(inspection.videoOptions.first.resolution, '1080p');
      expect(
        inspection.videoOptions.first.formatSelectionStrategy,
        FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
      );
      expect(inspection.videoOptions.first.selectedAudioFormatId, 'dash_a_128');
      expect(inspection.videoOptions.first.fileSizeBytes, 44000000);
      expect(inspection.audioOptions, hasLength(1));
      expect(
        inspection.originalAudio?.statusNote,
        'Audio included automatically',
      );
    });

    test('preserves progressive hd and sd streams without width/height metadata', () {
      final raw = jsonEncode({
        'id': '987654321',
        'title': 'Facebook Video #987654321',
        'description': 'Quick Facebook Reel clip',
        'uploader_id': 'creator99',
        'webpage_url': 'https://www.facebook.com/reel/987654321/',
        'extractor_key': 'FacebookReel',
        'formats': [
          {
            'format_id': 'sd',
            'ext': 'mp4',
          },
          {
            'format_id': 'hd',
            'ext': 'mp4',
          },
        ],
      });

      final inspection = parser.parseMediaInspection(raw);
      expect(inspection.providerName, 'Facebook');
      expect(inspection.title, 'Quick Facebook Reel clip');
      expect(inspection.uploader, 'creator99');
      expect(inspection.videoOptions, hasLength(2));
      expect(inspection.videoOptions[0].resolution, 'HD');
      expect(inspection.videoOptions[0].videoFormatId, 'hd');
      expect(
        inspection.videoOptions[0].formatSelectionStrategy,
        FormatSelectionStrategy.combinedAudioVideo,
      );
      expect(inspection.videoOptions[1].resolution, 'SD');
      expect(inspection.videoOptions[1].videoFormatId, 'sd');
    });
  });

  group('Facebook errors, progress stage, and Windows filename sanitization', () {
    test('classifies login, age-restricted, deleted/no-video, and transient errors', () {
      expect(
        facebook.classifyError(
          'ERROR: [facebook] You must log in to continue; use --cookies',
        ),
        contains('private or requires login'),
      );
      expect(
        facebook.classifyError('This video is age-restricted (18+)'),
        contains('age-restricted'),
      );
      expect(
        facebook.classifyError('ERROR: [facebook] 123: No video formats found!'),
        contains('does not contain a playable video'),
      );
      expect(
        facebook.classifyError(
          'Exception invoking yt-dlp: BrokenPipeError: [Errno 22] Invalid argument',
        ),
        contains('Local file or stream error'),
      );
      expect(
        facebook.isTransientError('curl: (28) Operation timed out'),
        isTrue,
      );
      expect(
        FacebookPlatformStrategy.redactSensitiveDiagnostics(
          'Cookie: c_user=12345; xs=secret_token',
        ),
        isNot(contains('secret_token')),
      );
    });

    test('parses [facebook] stdout progress stage and sanitizes long captions', () {
      final stage = YtDlpProgressParser.parseLine(
        '[facebook] Extracting URL: https://www.facebook.com/watch/?v=123',
      );
      expect(stage, isA<ParsedStageStatus>());
      expect((stage as ParsedStageStatus).message, 'Connecting to Facebook...');

      final sanitized = FilenameSanitizer.sanitizeWindowsFilename(
        'Watch: "Epic Goal?" 100% <2026> | Part 1/2...',
        80,
      );
      expect(sanitized.contains(':'), isFalse);
      expect(sanitized.contains('?'), isFalse);
      expect(sanitized.endsWith('.'), isFalse);
    });

    test('WindowsYtDlpDataSource forces --encoding utf-8 and safe template length', () {
      final ds = WindowsYtDlpDataSource();
      const paths = WindowsToolPaths(
        ytDlpExe: r'C:\tools\yt-dlp.exe',
        ffmpegExe: r'C:\tools\ffmpeg.exe',
        nodeExe: r'C:\tools\node.exe',
        defaultOutputDir: r'C:\Downloads',
      );

      final inspectArgs = ds.buildInspectArgs(
        paths,
        'https://www.facebook.com/reel/4595374484059655/',
      );
      expect(inspectArgs, containsAllInOrder(['--encoding', 'utf-8']));

      final infoArgs = ds.buildDownloadArgsFromInfoJson(
        paths,
        const StartDownloadRequest(
          url: 'https://www.facebook.com/reel/4595374484059655/',
          selection: DownloadFormatSelection.videoAndAudio(
            videoFormatId: '1388357453190506v',
            audioFormatId: '1388252816534303a',
          ),
        ),
        r'C:\Downloads\out.%(ext)s',
        r'C:\Temp\info.json',
        useMetaNetworkArgs: true,
      );
      expect(infoArgs, containsAllInOrder(['--encoding', 'utf-8']));
      expect(infoArgs, containsAllInOrder(['--load-info-json', r'C:\Temp\info.json']));

      final template = ds.resolveOutputTemplateForNewJob(
        Directory(r'C:\Downloads'),
        const StartDownloadRequest(
          url: 'https://www.facebook.com/watch/?v=4595374484059655',
          title:
              '756K views · 21K reactions | اللّهم خير الأمور وخير الأيام وخير الأقدار დ | Ｄ ｅ ｅ ｐ ｉ ｎ ｓ ｉ ｄ ｅ',
          selection: DownloadFormatSelection.videoAndAudio(
            videoFormatId: '1388357453190506v',
            audioFormatId: '1388252816534303a',
          ),
        ),
        shortcode: '4595374484059655',
      );
      expect(template, endsWith('[4595374484059655] [1388357453190506v+1388252816534303a].%(ext)s'));
      expect(template.length, lessThan(180));
    });
  });
}
