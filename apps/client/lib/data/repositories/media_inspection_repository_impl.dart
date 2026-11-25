import 'dart:collection';
import 'dart:io';

import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/data/datasources/android/android_method_channel_datasource.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_tool_paths.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_yt_dlp_datasource.dart';
import 'package:hyper_download_client/data/parsers/yt_dlp_json_parser.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/platforms/instagram_platform_strategy.dart';
import 'package:hyper_download_client/domain/platforms/media_platform.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';
import 'package:hyper_download_client/domain/repositories/media_inspection_repository.dart';

class _CachedRawEntry {
  final String rawJson;
  final DateTime cachedAt;
  DateTime lastUsed;

  _CachedRawEntry({
    required this.rawJson,
    required this.cachedAt,
    required this.lastUsed,
  });
}

/// Unified URL inspection repository across Windows (`yt-dlp.exe`) and Android
/// (Chaquopy raw JSON extraction), sharing Dart [PlatformRegistry], [YtDlpJsonParser],
/// raw `.info.json` LRU cache, and audio-only format tracking.
class MediaInspectionRepositoryImpl implements MediaInspectionRepository {
  static const int _rawCacheMaxEntries = 64;
  static const Duration _standardCacheTtl = Duration(minutes: 30);
  static const Duration _shortLivedCdnCacheTtl = Duration(minutes: 15);
  static const Duration _metaInspectTimeout = Duration(seconds: 120);
  static const int _audioRegistryMaxKeys = 64;

  final PlatformRegistry _platformRegistry;
  final YtDlpJsonParser _jsonParser;
  final WindowsYtDlpDataSource? _windowsYtDlp;
  final AndroidMethodChannelDataSource? _androidDataSource;
  final bool _isAndroid;

  final Map<String, _CachedRawEntry> _rawCache =
      HashMap<String, _CachedRawEntry>();
  final Map<String, List<String>> _audioOnlyFormatsByUrl = {};

  MediaInspectionRepositoryImpl({
    PlatformRegistry? platformRegistry,
    YtDlpJsonParser? jsonParser,
    this._windowsYtDlp,
    this._androidDataSource,
    bool? isAndroidOverride,
  }) : _platformRegistry = platformRegistry ?? const PlatformRegistry(),
       _jsonParser =
           jsonParser ??
           YtDlpJsonParser(
             platformRegistry: platformRegistry ?? const PlatformRegistry(),
           ),
       _isAndroid = isAndroidOverride ?? Platform.isAndroid;

  @override
  Future<UrlInspectionResult> inspectUrl(String url) async {
    final classified = _platformRegistry.classifyAndNormalize(url);
    if (classified.isPlaylist) {
      final playlist = await _inspectPlaylistNormalized(classified);
      return UrlInspectionResult(
        kind: InspectionTargetKind.playlist,
        playlist: playlist,
      );
    }
    final video = await _inspectMediaNormalized(classified);
    return UrlInspectionResult(
      kind: InspectionTargetKind.singleVideo,
      video: video,
    );
  }

  @override
  Future<MediaInspection> inspectMedia(String url) async {
    final classified = _platformRegistry.classifyAndNormalize(url);
    return _inspectMediaNormalized(classified);
  }

  @override
  Future<PlaylistInspection> inspectPlaylist(String url) async {
    final classified = _platformRegistry.classifyAndNormalize(url);
    return _inspectPlaylistNormalized(classified);
  }

  @override
  bool isRegisteredAudioOnlyFormat(String url, String formatId) {
    final ids = _audioOnlyFormatsByUrl[url.trim()];
    if (ids == null) return false;
    return ids.contains(formatId.trim());
  }

  String? getCachedRawJson(
    String url, {
    bool isInstagram = false,
    bool isShortLivedCdn = false,
  }) {
    final key = url.trim();
    if (key.isEmpty) return null;
    final ttl = (isInstagram || isShortLivedCdn)
        ? _shortLivedCdnCacheTtl
        : _standardCacheTtl;
    final entry = _rawCache[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.cachedAt) <= ttl) {
      entry.lastUsed = DateTime.now();
      return entry.rawJson;
    }
    _rawCache.remove(key);
    return null;
  }

  void evictCachedRawJson(String url) {
    final key = url.trim();
    if (key.isNotEmpty) {
      _rawCache.remove(key);
    }
  }

  Future<MediaInspection> _inspectMediaNormalized(
    NormalizedMediaUrl classified,
  ) async {
    final isInstagram = classified.platformId == MediaPlatformId.instagram;
    final isFacebook = classified.platformId == MediaPlatformId.facebook;
    final isShortLivedCdn = isInstagram || isFacebook;
    final String rawJson;

    if (_isAndroid) {
      final android = _androidDataSource!;
      rawJson = await android.extractRawInfo(
        url: classified.normalizedUrl,
        isPlaylist: false,
        isInstagram: isInstagram,
        isFacebook: isFacebook,
      );
    } else {
      rawJson = await _extractWindowsSingleMediaJson(classified);
    }

    try {
      final inspected = await _jsonParser.parseMediaInspectionAsync(rawJson);
      _registerAudioOnlyFormatIds([
        classified.normalizedUrl,
        inspected.webpageUrl,
        inspected.id,
      ], inspected.audioOptions.map((a) => a.formatId).toList(growable: false));
      final cacheKeys = <String>{classified.normalizedUrl};
      if (inspected.webpageUrl.trim().isNotEmpty) {
        cacheKeys.add(inspected.webpageUrl.trim());
        try {
          cacheKeys.add(
            _platformRegistry
                .classifyAndNormalize(inspected.webpageUrl)
                .normalizedUrl,
          );
        } catch (_) {}
      }

      if (isShortLivedCdn) {
        final cleaned = WindowsYtDlpDataSource.sanitizeInfoJsonForReuse(
          rawJson,
        );
        if (cleaned != null) {
          for (final cacheKey in cacheKeys) {
            _putRawCache(cacheKey, cleaned, ttl: _shortLivedCdnCacheTtl);
          }
        }
      } else {
        for (final cacheKey in cacheKeys) {
          _putRawCache(cacheKey, rawJson, ttl: _standardCacheTtl);
        }
      }
      return inspected;
    } on ParseException {
      if (isInstagram) {
        throw const ParseException(
          'Instagram returned an unsupported media format or incomplete response.',
        );
      }
      if (isFacebook) {
        throw const ParseException(
          'Facebook returned an unsupported media format or incomplete response.',
        );
      }
      rethrow;
    }
  }

  Future<PlaylistInspection> _inspectPlaylistNormalized(
    NormalizedMediaUrl classified,
  ) async {
    final String rawJson;
    if (_isAndroid) {
      rawJson = await _androidDataSource!.extractRawInfo(
        url: classified.normalizedUrl,
        isPlaylist: true,
        isInstagram: false,
      );
    } else {
      final ytDlp = _windowsYtDlp!;
      final paths = ytDlp.resolveToolPaths();
      final args = ytDlp.buildPlaylistInspectArgs(
        paths,
        classified.normalizedUrl,
      );
      final output = await ytDlp.runInspectionCommand(paths, args);
      if (!output.succeeded) {
        throw ProcessExecutionException(
          output.stderr.isEmpty
              ? 'yt-dlp playlist enumeration exited with non-zero status'
              : output.stderr,
          exitCode: output.exitCode,
        );
      }
      rawJson = output.stdout;
    }

    return _jsonParser.parsePlaylistInspectionAsync(
      rawJson,
      classified.normalizedUrl,
    );
  }

  Future<String> _extractWindowsSingleMediaJson(
    NormalizedMediaUrl classified,
  ) async {
    final ytDlp = _windowsYtDlp!;
    final paths = ytDlp.resolveToolPaths();
    final isMetaPlatform =
        classified.platformId == MediaPlatformId.instagram ||
        classified.platformId == MediaPlatformId.facebook;
    final strategy = _platformRegistry.strategyForId(classified.platformId);
    final timeout = isMetaPlatform ? _metaInspectTimeout : null;

    var output = await _runSingleWindowsInspection(
      ytDlp: ytDlp,
      paths: paths,
      url: classified.normalizedUrl,
      useMetaNetworkArgs: isMetaPlatform,
      timeout: timeout,
    );

    if (!output.succeeded &&
        isMetaPlatform &&
        !output.timedOut &&
        strategy.isTransientError(output.stderr)) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      output = await _runSingleWindowsInspection(
        ytDlp: ytDlp,
        paths: paths,
        url: classified.normalizedUrl,
        useMetaNetworkArgs: true,
        timeout: timeout,
      );
    }

    if (!output.succeeded &&
        classified.platformId == MediaPlatformId.facebook &&
        !output.timedOut &&
        _shouldTryFacebookCanonicalFallback(output.stderr)) {
      for (final fallbackUrl in _facebookFallbackUrls(classified)) {
        final retryOutput = await _runSingleWindowsInspection(
          ytDlp: ytDlp,
          paths: paths,
          url: fallbackUrl,
          useMetaNetworkArgs: true,
          timeout: timeout,
        );
        if (retryOutput.succeeded) {
          return retryOutput.stdout;
        }
      }
    }

    if (!output.succeeded) {
      if (isMetaPlatform) {
        throw ProcessExecutionException(
          strategy.classifyError(output.stderr),
          exitCode: output.exitCode,
        );
      }
      throw ProcessExecutionException(
        output.stderr.isEmpty
            ? 'yt-dlp inspection exited with non-zero status'
            : output.stderr,
        exitCode: output.exitCode,
      );
    }

    return output.stdout;
  }

  Future<YtDlpCommandResult> _runSingleWindowsInspection({
    required WindowsYtDlpDataSource ytDlp,
    required WindowsToolPaths paths,
    required String url,
    required bool useMetaNetworkArgs,
    required Duration? timeout,
  }) {
    final baseArgs = ytDlp.buildInspectArgs(paths, url);
    final args = useMetaNetworkArgs
        ? ytDlp.buildInstagramNetworkArgs(baseArgs)
        : baseArgs;
    return ytDlp.runInspectionCommand(paths, args, timeout: timeout);
  }

  static bool _shouldTryFacebookCanonicalFallback(String stderrText) {
    final lower = stderrText.toLowerCase();
    return lower.contains('no video formats') ||
        lower.contains('cannot parse data') ||
        lower.contains('unable to extract');
  }

  static List<String> _facebookFallbackUrls(NormalizedMediaUrl classified) {
    final code = classified.shortcode?.trim();
    if (code == null || !RegExp(r'^\d{6,}$').hasMatch(code)) {
      return const [];
    }
    return [
      'https://www.facebook.com/watch/?v=$code',
      'https://www.facebook.com/video/video.php?v=$code',
    ].where((url) => url != classified.normalizedUrl).toList(growable: false);
  }

  void _putRawCache(String url, String rawJson, {required Duration ttl}) {
    final key = url.trim();
    if (key.isEmpty || rawJson.trim().isEmpty) return;
    final now = DateTime.now();
    _rawCache.removeWhere((_, v) => now.difference(v.cachedAt) > ttl);
    if (_rawCache.length >= _rawCacheMaxEntries &&
        !_rawCache.containsKey(key)) {
      String? oldestKey;
      DateTime? oldestTime;
      for (final entry in _rawCache.entries) {
        if (oldestTime == null || entry.value.lastUsed.isBefore(oldestTime)) {
          oldestTime = entry.value.lastUsed;
          oldestKey = entry.key;
        }
      }
      if (oldestKey != null) _rawCache.remove(oldestKey);
    }
    _rawCache[key] = _CachedRawEntry(
      rawJson: rawJson,
      cachedAt: now,
      lastUsed: now,
    );
  }

  void _registerAudioOnlyFormatIds(List<String> keys, List<String> formatIds) {
    if (_audioOnlyFormatsByUrl.length >= _audioRegistryMaxKeys) {
      _audioOnlyFormatsByUrl.clear();
    }
    for (final rawKey in keys) {
      final key = rawKey.trim();
      if (key.isNotEmpty) {
        _audioOnlyFormatsByUrl[key] = formatIds;
      }
    }
  }
}

/// Convenience helper exposing sensitive log redaction for repositories.
String redactDiagnosticText(String raw) =>
    InstagramPlatformStrategy.redactSensitiveDiagnostics(raw);
