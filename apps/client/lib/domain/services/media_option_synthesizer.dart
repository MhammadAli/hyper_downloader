import 'dart:collection';

import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

/// Complete high-level option synthesis returned alongside raw discovered formats.
class SynthesizedMediaOptions {
  final AudioTrackMetadata? originalAudio;
  final List<VideoQualityOption> videoOptions;
  final List<AudioQualityOption> audioOptions;

  const SynthesizedMediaOptions({
    required this.originalAudio,
    required this.videoOptions,
    required this.audioOptions,
  });
}

class _AudioEnvironmentSignals {
  final String? normalizedVideoLang;
  final bool hasExplicitMultiAudioMarkers;
  final bool hasMultipleDistinctLanguages;
  final bool hasAnyNonDubTrack;

  const _AudioEnvironmentSignals({
    this.normalizedVideoLang,
    this.hasExplicitMultiAudioMarkers = false,
    this.hasMultipleDistinctLanguages = false,
    this.hasAnyNonDubTrack = false,
  });
}

/// Pure-Dart domain service synthesizing user-facing quality options, selecting
/// original vs dubbed audio tracks, resolving playlist item formats, and
/// computing aggregate playlist size estimates without fabricating streams.
class MediaOptionSynthesizer {
  const MediaOptionSynthesizer();

  /// Parses `acont=<tag>` from YouTube `xtags` or HLS `sgoap` URL query parameters.
  String? extractXtagsAcont(String? rawUrl) {
    final url = rawUrl?.trim();
    if (url == null || url.isEmpty) return null;

    final decoded = url
        .replaceAll('%3D', '=')
        .replaceAll('%3d', '=')
        .replaceAll('%3A', ':')
        .replaceAll('%3a', ':')
        .replaceAll('%3B', ';')
        .replaceAll('%3b', ';');

    final lower = decoded.toLowerCase();
    for (final marker in const ['acont=', 'acont:']) {
      final pos = lower.indexOf(marker);
      if (pos != -1) {
        final after = lower.substring(pos + marker.length);
        final value = after.split(RegExp(r'[:&; ]')).first.trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  /// Synthesizes `originalAudio`, `videoOptions`, and `audioOptions` strictly
  /// from genuinely discovered streams.
  SynthesizedMediaOptions buildQualityOptionsForPlatform(
    List<RawFormatCandidate> candidates, {
    String? videoLanguage,
    bool isInstagram = false,
    bool isFacebook = false,
  }) {
    final isSingleSocialAudio = isInstagram || isFacebook;
    final audioCandidates = candidates
        .where((c) => c.format.streamKind == StreamKind.audioOnly)
        .toList(growable: false);
    final muxedCandidates = candidates
        .where((c) => c.format.streamKind == StreamKind.muxedAudioVideo)
        .toList(growable: false);
    final videoOnlyCandidates = candidates
        .where((c) => c.format.streamKind == StreamKind.videoOnly)
        .toList(growable: false);

    final _AudioEnvironmentSignals signals;
    final AudioTrackMetadata? initialOriginalAudio;
    final AudioTrackMetadata? winningAudioMeta;

    if (isSingleSocialAudio) {
      signals = const _AudioEnvironmentSignals();
      final selected = _selectPreferredAudioCandidate(
        audioCandidates,
        signals,
        preferM4a: true,
      );
      final meta = selected != null
          ? _buildInstagramAudioMetadata(selected)
          : null;
      initialOriginalAudio = meta;
      winningAudioMeta = meta;
    } else {
      signals = _analyzeAudioEnvironment(audioCandidates, videoLanguage);
      final selected = _selectPreferredAudioCandidate(
        audioCandidates,
        signals,
        preferM4a: true,
      );
      final meta = selected != null
          ? _buildAudioMetadata(selected, signals)
          : null;
      initialOriginalAudio = meta;
      winningAudioMeta = meta;
    }

    final audioOptions = _buildAudioOnlyOptions(
      audioCandidates,
      signals,
      winningAudioMeta,
    );

    final videoOptions = _buildVideoWithSoundOptions(
      muxedCandidates,
      videoOnlyCandidates,
      audioCandidates,
      signals,
      winningAudioMeta,
      isInstagram: isSingleSocialAudio,
    );

    final originalAudio =
        (isSingleSocialAudio &&
            initialOriginalAudio == null &&
            videoOptions.isNotEmpty)
        ? _buildInstagramAudioMetadata(null)
        : initialOriginalAudio;

    return SynthesizedMediaOptions(
      originalAudio: originalAudio,
      videoOptions: videoOptions,
      audioOptions: audioOptions,
    );
  }

  /// Selects the best playable option for an individually inspected playlist video
  /// using its discovered formats, original-audio metadata, and quality cap.
  ResolvedPlaylistSelection selectPlaylistItemOption(
    MediaInspection inspection,
    PlaylistMediaMode mode,
    PlaylistQualityCap cap,
  ) {
    switch (mode) {
      case PlaylistMediaMode.videoWithSound:
        if (inspection.videoOptions.isEmpty) {
          throw const ParseException(
            'No playable Video with Sound formats (valid audio track unavailable) for this item.',
          );
        }
        final maxHeight = switch (cap) {
          PlaylistQualityCap.bestAvailable => 1 << 30,
          PlaylistQualityCap.upTo1080p => 1080,
          PlaylistQualityCap.upTo720p => 720,
          PlaylistQualityCap.upTo480p => 480,
        };

        final chosen = inspection.videoOptions.firstWhere(
          (opt) => opt.height != null && opt.height! <= maxHeight,
          orElse: () => inspection.videoOptions.last,
        );

        final DownloadFormatSelection selection;
        final int? expectedSizeBytes;
        final FileSizeAccuracy sizeAccuracy;

        switch (chosen.formatSelectionStrategy) {
          case FormatSelectionStrategy.combinedAudioVideo:
            selection = DownloadFormatSelection.single(chosen.videoFormatId);
            expectedSizeBytes = chosen.fileSizeBytes;
            sizeAccuracy = chosen.sizeAccuracy;
          case FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg:
            final audioId = chosen.selectedAudioFormatId;
            if (audioId == null || audioId.isEmpty) {
              throw const ParseException(
                'Internal format pairing error: missing original audio format ID.',
              );
            }
            if (chosen.fileSizeBytes != null &&
                (chosen.sizeAccuracy == FileSizeAccuracy.exact ||
                    chosen.sizeAccuracy == FileSizeAccuracy.estimated)) {
              expectedSizeBytes = chosen.fileSizeBytes;
              sizeAccuracy = FileSizeAccuracy.estimated;
            } else {
              expectedSizeBytes = null;
              sizeAccuracy = FileSizeAccuracy.unknown;
            }
            selection = DownloadFormatSelection.videoAndAudio(
              videoFormatId: chosen.videoFormatId,
              audioFormatId: audioId,
              mergeContainer: chosen.container,
            );
          case FormatSelectionStrategy.audioOnlyStream:
            throw const ParseException(
              'Unexpected AudioOnly strategy inside video options.',
            );
        }

        final fpsPart = (chosen.fps != null && chosen.fps! >= 45.0)
            ? ' ${chosen.fps!.round()}fps'
            : '';
        final qualityLabel =
            '${chosen.resolution}$fpsPart ${chosen.container.toUpperCase()}';

        return ResolvedPlaylistSelection(
          selection: selection,
          qualityLabel: qualityLabel,
          container: chosen.container,
          audioLanguage: chosen.audioLanguage ?? inspection.originalAudio,
          expectedSizeBytes: expectedSizeBytes,
          sizeAccuracy: sizeAccuracy,
        );

      case PlaylistMediaMode.audioOnly:
        if (inspection.audioOptions.isEmpty) {
          throw const ParseException(
            'No downloadable Audio Only stream discovered for this item.',
          );
        }
        final chosen = inspection.audioOptions.first;
        final qualityLabel =
            '${chosen.container.toUpperCase()} · ${chosen.qualityLabel}';
        return ResolvedPlaylistSelection(
          selection: DownloadFormatSelection.single(chosen.formatId),
          qualityLabel: qualityLabel,
          container: chosen.container,
          audioLanguage: chosen.audioLanguage ?? inspection.originalAudio,
          expectedSizeBytes: chosen.fileSizeBytes,
          sizeAccuracy: chosen.sizeAccuracy,
        );
    }
  }

  /// Aggregates per-item inspection results into an honest [PlaylistSizeEstimate].
  PlaylistSizeEstimate buildPlaylistSizeEstimate({
    required String estimationId,
    required PlaylistInspection playlist,
    required PlaylistMediaMode mediaMode,
    required PlaylistQualityCap qualityCap,
    required Map<int, ({MediaInspection? inspection, String? error})> results,
    required bool isCalculating,
    required bool wasCanceled,
  }) {
    var unavailableCount = 0;
    var eligibleCount = 0;
    var inspectedCount = 0;
    var exactCount = 0;
    var estimatedCount = 0;
    var unknownCount = 0;
    var failedCount = 0;
    var knownTotalBytes = 0;
    final itemSizes = <PlaylistItemSizeInfo>[];

    for (final entry in playlist.entries) {
      if (entry.availability != PlaylistEntryAvailability.available) {
        unavailableCount++;
        continue;
      }
      eligibleCount++;

      final outcome = results[entry.orderIndex];
      if (outcome == null) continue;

      final inspection = outcome.inspection;
      if (inspection != null) {
        inspectedCount++;
        try {
          final resolved = selectPlaylistItemOption(
            inspection,
            mediaMode,
            qualityCap,
          );
          final displaySize = ByteFormatter.formatDisplaySize(
            resolved.expectedSizeBytes,
            resolved.sizeAccuracy,
          );
          if (resolved.expectedSizeBytes != null &&
              resolved.sizeAccuracy == FileSizeAccuracy.exact) {
            exactCount++;
            knownTotalBytes += resolved.expectedSizeBytes!;
          } else if (resolved.expectedSizeBytes != null &&
              resolved.sizeAccuracy == FileSizeAccuracy.estimated) {
            estimatedCount++;
            knownTotalBytes += resolved.expectedSizeBytes!;
          } else {
            unknownCount++;
          }
          itemSizes.add(
            PlaylistItemSizeInfo(
              orderIndex: entry.orderIndex,
              selectedQuality: resolved.qualityLabel,
              expectedSizeBytes: resolved.expectedSizeBytes,
              sizeAccuracy: resolved.sizeAccuracy,
              displaySize: displaySize,
              failed: false,
            ),
          );
        } catch (err) {
          failedCount++;
          itemSizes.add(
            PlaylistItemSizeInfo(
              orderIndex: entry.orderIndex,
              sizeAccuracy: FileSizeAccuracy.unknown,
              displaySize: 'Unavailable',
              failed: true,
              errorMessage: err.toString(),
            ),
          );
        }
      } else if (outcome.error != null) {
        inspectedCount++;
        failedCount++;
        itemSizes.add(
          PlaylistItemSizeInfo(
            orderIndex: entry.orderIndex,
            sizeAccuracy: FileSizeAccuracy.unknown,
            displaySize: 'Unavailable',
            failed: true,
            errorMessage: outcome.error,
          ),
        );
      }
    }

    final PlaylistSizeStatus status;
    if (isCalculating) {
      status = PlaylistSizeStatus.calculating;
    } else if (wasCanceled) {
      status = PlaylistSizeStatus.canceled;
    } else if (eligibleCount == 0) {
      status = PlaylistSizeStatus.unknown;
    } else if (failedCount > 0 && exactCount == 0 && estimatedCount == 0) {
      status = PlaylistSizeStatus.failed;
    } else if (unknownCount > 0 || failedCount > 0) {
      status = (knownTotalBytes > 0 || exactCount > 0 || estimatedCount > 0)
          ? PlaylistSizeStatus.partial
          : PlaylistSizeStatus.unknown;
    } else if (estimatedCount > 0) {
      status = PlaylistSizeStatus.estimated;
    } else if (exactCount > 0) {
      status = PlaylistSizeStatus.exact;
    } else {
      status = PlaylistSizeStatus.unknown;
    }

    final (String displaySummary, String? statusMessage) = switch (status) {
      PlaylistSizeStatus.idle => ('Pending size check', null),
      PlaylistSizeStatus.calculating => (
        'Calculating playlist size...',
        'Calculating sizes: $inspectedCount / $eligibleCount videos',
      ),
      PlaylistSizeStatus.canceled => (
        knownTotalBytes > 0
            ? 'At least ${ByteFormatter.formatBytesHuman(knownTotalBytes)} · canceled'
            : 'Size calculation canceled',
        'Canceled after inspecting $inspectedCount of $eligibleCount videos.',
      ),
      PlaylistSizeStatus.exact => (
        '${ByteFormatter.formatBytesHuman(knownTotalBytes)} (Exact)',
        '$eligibleCount accessible video(s) with exact sizes.',
      ),
      PlaylistSizeStatus.estimated => (
        '~${ByteFormatter.formatBytesHuman(knownTotalBytes)} (Estimated)',
        '$eligibleCount accessible video(s) ($exactCount exact, $estimatedCount estimated/merged).',
      ),
      PlaylistSizeStatus.partial => _partialMessages(
        knownTotalBytes: knownTotalBytes,
        unknownCount: unknownCount,
        failedCount: failedCount,
      ),
      PlaylistSizeStatus.failed => (
        'Some video sizes could not be determined',
        '$failedCount of $eligibleCount accessible video(s) failed size inspection.',
      ),
      PlaylistSizeStatus.unknown =>
        eligibleCount == 0
            ? ('No accessible videos to size', null)
            : (
                'Unknown size',
                '$unknownCount video(s) have unknown sizes.',
              ),
    };

    return PlaylistSizeEstimate(
      estimationId: estimationId,
      playlistId: playlist.id,
      mediaMode: mediaMode,
      qualityCap: qualityCap,
      status: status,
      knownTotalBytes: knownTotalBytes,
      totalEntriesCount: playlist.entries.length,
      unavailableCount: unavailableCount,
      eligibleCount: eligibleCount,
      inspectedCount: inspectedCount,
      exactCount: exactCount,
      estimatedCount: estimatedCount,
      unknownCount: unknownCount,
      failedCount: failedCount,
      displaySummary: displaySummary,
      statusMessage: statusMessage,
      itemSizes: itemSizes,
    );
  }

  static (String, String) _partialMessages({
    required int knownTotalBytes,
    required int unknownCount,
    required int failedCount,
  }) {
    final human = ByteFormatter.formatBytesHuman(knownTotalBytes);
    if (unknownCount > 0 && failedCount == 0) {
      return (
        'At least $human · $unknownCount unknown',
        'At least $human · $unknownCount video(s) have unknown sizes.',
      );
    }
    if (failedCount > 0 && unknownCount == 0) {
      return (
        'At least $human · $failedCount failed',
        'Some video sizes could not be determined.',
      );
    }
    return (
      'At least $human · $unknownCount unknown, $failedCount failed',
      'Some video sizes are unknown or could not be determined.',
    );
  }

  _AudioEnvironmentSignals _analyzeAudioEnvironment(
    List<RawFormatCandidate> audioCandidates,
    String? videoLanguage,
  ) {
    final trimmedVidLang = videoLanguage?.trim();
    final normalizedVideoLang =
        (trimmedVidLang != null && trimmedVidLang.isNotEmpty)
        ? trimmedVidLang
        : null;

    final distinctLangs = <String>{};
    var hasExplicitMultiAudioMarkers = false;
    var hasAnyNonDubTrack = false;

    for (final cand in audioCandidates) {
      final lang = cand.language?.trim();
      if (lang != null && lang.isNotEmpty) {
        distinctLangs.add(_primaryLangTag(lang));
      }
      final dub = _isExplicitDub(cand).isDub;
      if (_isExplicitOriginal(cand) ||
          dub ||
          (cand.languagePreference != null && cand.languagePreference! > 0)) {
        hasExplicitMultiAudioMarkers = true;
      }
      if (!dub) {
        hasAnyNonDubTrack = true;
      }
    }

    final hasMultipleDistinctLanguages = distinctLangs.length > 1;
    if (hasMultipleDistinctLanguages) {
      hasExplicitMultiAudioMarkers = true;
    }

    return _AudioEnvironmentSignals(
      normalizedVideoLang: normalizedVideoLang,
      hasExplicitMultiAudioMarkers: hasExplicitMultiAudioMarkers,
      hasMultipleDistinctLanguages: hasMultipleDistinctLanguages,
      hasAnyNonDubTrack: hasAnyNonDubTrack,
    );
  }

  static String _primaryLangTag(String tag) =>
      tag.trim().split(RegExp(r'[-_]')).first.toLowerCase();

  static bool _languagesMatch(String a, String b) {
    final ta = a.trim();
    final tb = b.trim();
    if (ta.toLowerCase() == tb.toLowerCase()) return true;
    return _primaryLangTag(ta) == _primaryLangTag(tb);
  }

  static bool _isExplicitOriginal(RawFormatCandidate cand) {
    if (cand.xtagsAcont == 'original') return true;
    final note = cand.format.formatNote;
    if (note != null) {
      final words = note.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
      if (words.contains('original')) return true;
    }
    return false;
  }

  static ({bool isDub, bool isAutoDub}) _isExplicitDub(
    RawFormatCandidate cand,
  ) {
    if (cand.xtagsAcont == 'dubbed-auto') {
      return (isDub: true, isAutoDub: true);
    }
    if (cand.xtagsAcont == 'dubbed') {
      return (isDub: true, isAutoDub: false);
    }
    final note = cand.format.formatNote;
    if (note != null) {
      final lower = note.toLowerCase();
      if (lower.contains('dubbed-auto') || lower.contains('auto-dub')) {
        return (isDub: true, isAutoDub: true);
      }
      if (lower.split(RegExp(r'[^a-z0-9]+')).contains('dubbed')) {
        return (isDub: true, isAutoDub: false);
      }
    }
    return (isDub: false, isAutoDub: false);
  }

  static bool _isDefaultMarked(RawFormatCandidate cand) {
    if (cand.languagePreference != null && cand.languagePreference! > 0) {
      return true;
    }
    final note = cand.format.formatNote;
    return note != null && note.toLowerCase().contains('(default)');
  }

  static int _originalityTier(
    RawFormatCandidate cand,
    _AudioEnvironmentSignals signals,
  ) {
    if (_isExplicitDub(cand).isDub) return 0;
    if (_isExplicitOriginal(cand)) return 4;
    if (cand.languagePreference != null && cand.languagePreference! > 0) {
      return 3;
    }
    final vidLang = signals.normalizedVideoLang;
    final fmtLang = cand.language;
    if (vidLang != null &&
        fmtLang != null &&
        _languagesMatch(vidLang, fmtLang)) {
      return 2;
    }
    return 1;
  }

  static bool _isHttpsDirect(RawFormatCandidate cand) =>
      !(cand.protocol?.contains('m3u8') ?? false);

  static bool _isDrcVariant(RawFormatCandidate cand) =>
      cand.format.formatId.endsWith('-drc') ||
      (cand.format.formatNote?.toLowerCase().contains('drc') ?? false);

  static int _audioContainerRank(RawFormatCandidate cand, bool preferM4a) {
    final isM4a =
        cand.format.container.toLowerCase() == 'm4a' ||
        (cand.format.acodec?.startsWith('mp4a') ?? false);
    return preferM4a == isM4a ? 2 : 1;
  }

  RawFormatCandidate? _selectPreferredAudioCandidate(
    List<RawFormatCandidate> audioCandidates,
    _AudioEnvironmentSignals signals, {
    required bool preferM4a,
  }) {
    if (audioCandidates.isEmpty) return null;
    var best = audioCandidates.first;
    for (var i = 1; i < audioCandidates.length; i++) {
      final cand = audioCandidates[i];
      if (_compareAudioCandidates(cand, best, signals, preferM4a) > 0) {
        best = cand;
      }
    }
    return best;
  }

  int _compareAudioCandidates(
    RawFormatCandidate a,
    RawFormatCandidate b,
    _AudioEnvironmentSignals signals,
    bool preferM4a,
  ) {
    final tierCmp = _originalityTier(
      a,
      signals,
    ).compareTo(_originalityTier(b, signals));
    if (tierCmp != 0) return tierCmp;

    final directCmp = _boolCmp(_isHttpsDirect(a), _isHttpsDirect(b));
    if (directCmp != 0) return directCmp;

    final drcCmp = _boolCmp(!_isDrcVariant(a), !_isDrcVariant(b));
    if (drcCmp != 0) return drcCmp;

    final rankCmp = _audioContainerRank(
      a,
      preferM4a,
    ).compareTo(_audioContainerRank(b, preferM4a));
    if (rankCmp != 0) return rankCmp;

    final brCmp = (a.format.bitrateKbps ?? 0.0).compareTo(
      b.format.bitrateKbps ?? 0.0,
    );
    if (brCmp != 0) return brCmp;

    return b.format.formatId.compareTo(a.format.formatId);
  }

  AudioTrackMetadata _buildAudioMetadata(
    RawFormatCandidate cand,
    _AudioEnvironmentSignals signals,
  ) {
    final langRaw = cand.language;
    final language = (langRaw != null && langRaw.isNotEmpty) ? langRaw : null;
    final languageDisplayName = _extractLanguageDisplayName(cand, language);
    final dub = _isExplicitDub(cand);
    final explicitOrig = _isExplicitOriginal(cand);
    final isDefault = _isDefaultMarked(cand) ? true : null;

    final matchesVideoLang =
        signals.normalizedVideoLang != null &&
        language != null &&
        _languagesMatch(signals.normalizedVideoLang!, language);

    if (explicitOrig && !dub.isDub) {
      final langLabel = languageDisplayName ?? language;
      final note = langLabel != null
          ? 'Audio included automatically · Original: $langLabel'
          : 'Audio included automatically · Original track';
      return AudioTrackMetadata(
        language: language,
        languageDisplayName: languageDisplayName,
        isOriginal: true,
        isDefault: isDefault,
        isAutoDub: false,
        selectionConfidence: AudioSelectionConfidence.confirmedOriginal,
        statusNote: note,
      );
    }

    if (!dub.isDub &&
        cand.languagePreference != null &&
        cand.languagePreference! > 0) {
      final confirmed = matchesVideoLang || language != null;
      final confidence = confirmed
          ? AudioSelectionConfidence.confirmedOriginal
          : AudioSelectionConfidence.likelyOriginal;
      final langLabel = languageDisplayName ?? language;
      final note = langLabel != null
          ? 'Audio included automatically · Original: $langLabel'
          : 'Audio included automatically · Original track';
      return AudioTrackMetadata(
        language: language,
        languageDisplayName: languageDisplayName,
        isOriginal: true,
        isDefault: true,
        isAutoDub: false,
        selectionConfidence: confidence,
        statusNote: note,
      );
    }

    if (!dub.isDub &&
        matchesVideoLang &&
        signals.hasExplicitMultiAudioMarkers) {
      final langLabel = languageDisplayName ?? language;
      final note = 'Audio included automatically · Likely original: $langLabel';
      return AudioTrackMetadata(
        language: language,
        languageDisplayName: languageDisplayName,
        isOriginal: null,
        isDefault: isDefault,
        isAutoDub: false,
        selectionConfidence: AudioSelectionConfidence.likelyOriginal,
        statusNote: note,
      );
    }

    if (dub.isDub) {
      final langLabel = languageDisplayName ?? language;
      final langSuffix = langLabel != null ? ' ($langLabel)' : '';
      return AudioTrackMetadata(
        language: language,
        languageDisplayName: languageDisplayName,
        isOriginal: false,
        isDefault: isDefault,
        isAutoDub: dub.isAutoDub,
        selectionConfidence: AudioSelectionConfidence.ambiguousOrUnknown,
        statusNote:
            'Audio included automatically · Only dubbed track found$langSuffix; original not marked',
      );
    }

    if (signals.hasMultipleDistinctLanguages) {
      return AudioTrackMetadata(
        language: language,
        languageDisplayName: languageDisplayName,
        isOriginal: null,
        isDefault: isDefault,
        isAutoDub: null,
        selectionConfidence: AudioSelectionConfidence.ambiguousOrUnknown,
        statusNote:
            'Audio included automatically · Original language not marked among multiple audio tracks',
      );
    }

    final langLabel = languageDisplayName ?? language;
    final suffix = langLabel != null
        ? ' · Language: $langLabel (original not marked)'
        : ' · Original language not marked in metadata';
    return AudioTrackMetadata(
      language: language,
      languageDisplayName: languageDisplayName,
      isOriginal: null,
      isDefault: isDefault,
      isAutoDub: null,
      selectionConfidence: AudioSelectionConfidence.singleOrUnmarked,
      statusNote: 'Audio included automatically$suffix',
    );
  }

  static String? _extractLanguageDisplayName(
    RawFormatCandidate cand,
    String? langCode,
  ) {
    final note = cand.format.formatNote;
    if (note != null) {
      final lower = note.toLowerCase();
      final origIdx = lower.indexOf(' original');
      if (origIdx != -1) {
        var prefix = note.substring(0, origIdx).trim();
        while (prefix.endsWith('-')) {
          prefix = prefix.substring(0, prefix.length - 1).trim();
        }
        if (prefix.isNotEmpty) return prefix;
      }
      final dubIdx = lower.indexOf(' - dubbed');
      if (dubIdx != -1) {
        final prefix = note.substring(0, dubIdx).trim();
        if (prefix.isNotEmpty) return prefix;
      }
      if (langCode != null) {
        final commaIdx = note.indexOf(',');
        if (commaIdx != -1) {
          final candidate = note.substring(0, commaIdx).trim();
          final cl = candidate.toLowerCase();
          if (candidate.isNotEmpty &&
              cl != 'low' &&
              cl != 'medium' &&
              cl != 'high' &&
              cl != 'drc' &&
              cl != 'tiny') {
            return candidate;
          }
        }
      }
    }

    if (langCode == null) return null;
    final lowerCode = langCode.toLowerCase();
    return switch (_primaryLangTag(langCode)) {
      'en' =>
        lowerCode == 'en-us'
            ? 'English (US)'
            : lowerCode == 'en-gb'
            ? 'English (UK)'
            : 'English',
      'ar' => 'Arabic',
      'es' => 'Spanish',
      'fr' => 'French',
      'de' => 'German',
      'it' => 'Italian',
      'pt' => 'Portuguese',
      'ru' => 'Russian',
      'ja' => 'Japanese',
      'ko' => 'Korean',
      'zh' => 'Chinese',
      'tr' => 'Turkish',
      'hi' => 'Hindi',
      _ => langCode,
    };
  }

  List<AudioQualityOption> _buildAudioOnlyOptions(
    List<RawFormatCandidate> audioCandidates,
    _AudioEnvironmentSignals signals,
    AudioTrackMetadata? winningMeta,
  ) {
    if (audioCandidates.isEmpty) return const [];

    var filtered = audioCandidates
        .where((c) => _matchesWinningLineage(c, signals, winningMeta))
        .toList();
    if (filtered.isEmpty) {
      filtered = List<RawFormatCandidate>.from(audioCandidates);
    }

    if (filtered.any(_isHttpsDirect)) {
      filtered.retainWhere(_isHttpsDirect);
    }
    if (filtered.any((c) => !_isDrcVariant(c))) {
      filtered.retainWhere((c) => !_isDrcVariant(c));
    }

    filtered.sort((a, b) {
      final brCmp = (b.format.bitrateKbps ?? 0.0).compareTo(
        a.format.bitrateKbps ?? 0.0,
      );
      if (brCmp != 0) return brCmp;
      return _audioContainerRank(b, true).compareTo(_audioContainerRank(a, true));
    });

    final seenBuckets = <String>{};
    final out = <AudioQualityOption>[];
    for (final cand in filtered) {
      final brBucket = cand.format.bitrateKbps != null
          ? (cand.format.bitrateKbps! / 16.0).round()
          : -1;
      final containerLower = cand.format.container.toLowerCase();
      final key = '$containerLower|$brBucket';
      if (!seenBuckets.add(key)) continue;

      out.add(
        AudioQualityOption(
          qualityLabel: _formatAudioQualityLabel(cand),
          container: containerLower,
          bitrateKbps: cand.format.bitrateKbps,
          displaySize: ByteFormatter.formatDisplaySize(
            cand.format.fileSizeBytes,
            cand.format.sizeAccuracy,
          ),
          fileSizeBytes: cand.format.fileSizeBytes,
          sizeAccuracy: cand.format.sizeAccuracy,
          formatId: cand.format.formatId,
          audioLanguage: winningMeta,
        ),
      );
      if (out.length >= 4) break;
    }
    return out;
  }

  static bool _matchesWinningLineage(
    RawFormatCandidate cand,
    _AudioEnvironmentSignals signals,
    AudioTrackMetadata? winningMeta,
  ) {
    if (_isExplicitDub(cand).isDub && signals.hasAnyNonDubTrack) {
      return false;
    }
    if (winningMeta != null) {
      final winLang = winningMeta.language;
      if (winLang != null) {
        final candLang = cand.language;
        if (candLang != null) {
          if (!_languagesMatch(winLang, candLang)) return false;
        } else if (signals.hasExplicitMultiAudioMarkers) {
          return false;
        }
      }
      if (winningMeta.selectionConfidence ==
              AudioSelectionConfidence.confirmedOriginal &&
          signals.hasExplicitMultiAudioMarkers &&
          _originalityTier(cand, signals) < 2) {
        return false;
      }
    }
    return true;
  }

  static String _formatAudioQualityLabel(RawFormatCandidate cand) {
    final br = cand.format.bitrateKbps;
    final tier = switch (br) {
      final kbps? when kbps >= 190.0 => 'High Quality',
      final kbps? when kbps >= 96.0 => 'Standard Quality',
      final _? => 'Compact Quality',
      null => 'Audio Stream',
    };
    return br != null ? '$tier (${br.round()} kbps)' : tier;
  }

  static AudioTrackMetadata _buildInstagramAudioMetadata(
    RawFormatCandidate? cand,
  ) {
    final langRaw = cand?.language;
    final language = (langRaw != null && langRaw.isNotEmpty) ? langRaw : null;
    return AudioTrackMetadata(
      language: language,
      selectionConfidence: AudioSelectionConfidence.singleOrUnmarked,
      statusNote: 'Audio included automatically',
    );
  }

  static int? _effectiveQualityHeight(RawFormatCandidate cand) {
    final w = cand.format.width;
    final h = cand.format.height;
    if (w != null && h != null && w > 0 && h > 0) {
      return w < h ? w : h;
    }
    if (h != null && h > 0) return h;
    return null;
  }

  List<VideoQualityOption> _buildVideoWithSoundOptions(
    List<RawFormatCandidate> muxedCandidates,
    List<RawFormatCandidate> videoOnlyCandidates,
    List<RawFormatCandidate> audioCandidates,
    _AudioEnvironmentSignals signals,
    AudioTrackMetadata? winningAudioMeta, {
    required bool isInstagram,
  }) {
    final groupedHeights = SplayTreeMap<int, (List<RawFormatCandidate>, List<RawFormatCandidate>)>();
    final unknownResMuxed = <RawFormatCandidate>[];

    for (final cand in muxedCandidates) {
      final h = _effectiveQualityHeight(cand);
      if (h != null) {
        groupedHeights.putIfAbsent(h, () => (<RawFormatCandidate>[], <RawFormatCandidate>[])).$1.add(cand);
      } else {
        unknownResMuxed.add(cand);
      }
    }
    for (final cand in videoOnlyCandidates) {
      final h = _effectiveQualityHeight(cand);
      if (h != null) {
        groupedHeights.putIfAbsent(h, () => (<RawFormatCandidate>[], <RawFormatCandidate>[])).$2.add(cand);
      }
    }

    final results = <VideoQualityOption>[];
    final heightsDesc = groupedHeights.keys.toList(growable: false).reversed;

    for (final height in heightsDesc) {
      final group = groupedHeights[height]!;
      final bestMuxed = _selectBestMuxedForHeight(
        group.$1,
        signals,
        winningAudioMeta,
      );
      final bestVideoOnly = _selectBestVideoOnlyForHeight(group.$2);

      (RawFormatCandidate, RawFormatCandidate)? pairedOption;
      if (bestVideoOnly != null) {
        final preferM4a = bestVideoOnly.format.container.toLowerCase() == 'mp4';
        final pairAudio = _selectAudioForPairing(
          audioCandidates,
          signals,
          winningAudioMeta,
          preferM4a: preferM4a,
        );
        if (pairAudio != null) {
          pairedOption = (bestVideoOnly, pairAudio);
        }
      }

      if (bestMuxed != null && pairedOption != null) {
        final muxFps = bestMuxed.format.fps ?? 0.0;
        final vidFps = pairedOption.$1.format.fps ?? 0.0;
        if (vidFps > muxFps + 5.0 ||
            _shouldPreferPairedOverMuxed(
              bestMuxed,
              winningAudioMeta,
              signals,
            )) {
          results.add(
            _buildPairedVideoOption(
              height,
              pairedOption.$1,
              pairedOption.$2,
              winningAudioMeta,
            ),
          );
        } else {
          results.add(
            _buildCombinedVideoOption(
              height,
              bestMuxed,
              winningAudioMeta,
              isInstagram: isInstagram,
            ),
          );
        }
      } else if (bestMuxed != null) {
        results.add(
          _buildCombinedVideoOption(
            height,
            bestMuxed,
            winningAudioMeta,
            isInstagram: isInstagram,
          ),
        );
      } else if (pairedOption != null) {
        results.add(
          _buildPairedVideoOption(
            height,
            pairedOption.$1,
            pairedOption.$2,
            winningAudioMeta,
          ),
        );
      }
      // Silent video without any valid audio track MUST NOT appear in "Video with Sound".
    }

    if (results.isEmpty && unknownResMuxed.isNotEmpty) {
      final acceptableUnknown = unknownResMuxed
          .where((m) => _isMuxedAudioAcceptable(m, signals, winningAudioMeta))
          .toList(growable: false);
      final hdMatches = acceptableUnknown
          .where((m) => m.format.formatId.toLowerCase() == 'hd')
          .toList(growable: false);
      final sdMatches = acceptableUnknown
          .where((m) => m.format.formatId.toLowerCase() == 'sd')
          .toList(growable: false);

      if (hdMatches.isNotEmpty || sdMatches.isNotEmpty) {
        final bestHd = _maxByVideoComparison(hdMatches);
        if (bestHd != null) {
          results.add(
            _buildUnknownResCombinedVideoOption(
              bestHd,
              winningAudioMeta,
              isInstagram: isInstagram,
              resolutionLabel: 'HD',
              assumedHeight: 720,
            ),
          );
        }
        final bestSd = _maxByVideoComparison(sdMatches);
        if (bestSd != null) {
          results.add(
            _buildUnknownResCombinedVideoOption(
              bestSd,
              winningAudioMeta,
              isInstagram: isInstagram,
              resolutionLabel: 'SD',
              assumedHeight: 480,
            ),
          );
        }
      } else {
        final bestMuxed = _maxByVideoComparison(acceptableUnknown);
        if (bestMuxed != null) {
          results.add(
            _buildUnknownResCombinedVideoOption(
              bestMuxed,
              winningAudioMeta,
              isInstagram: isInstagram,
            ),
          );
        }
      }
    }

    return results;
  }

  static bool _shouldPreferPairedOverMuxed(
    RawFormatCandidate muxed,
    AudioTrackMetadata? winningMeta,
    _AudioEnvironmentSignals signals,
  ) {
    if (_isExplicitDub(muxed).isDub) return true;
    final origLang = winningMeta?.language;
    if (origLang != null) {
      final muxLang = muxed.language;
      if (muxLang != null) {
        if (!_languagesMatch(origLang, muxLang)) return true;
      } else if (signals.hasExplicitMultiAudioMarkers &&
          winningMeta?.selectionConfidence ==
              AudioSelectionConfidence.confirmedOriginal) {
        return true;
      }
    }
    return false;
  }

  RawFormatCandidate? _selectBestMuxedForHeight(
    List<RawFormatCandidate> muxedList,
    _AudioEnvironmentSignals signals,
    AudioTrackMetadata? winningMeta,
  ) {
    final acceptable = muxedList
        .where((m) => _isMuxedAudioAcceptable(m, signals, winningMeta))
        .toList(growable: false);
    return _maxByVideoComparison(acceptable);
  }

  static bool _isMuxedAudioAcceptable(
    RawFormatCandidate muxed,
    _AudioEnvironmentSignals signals,
    AudioTrackMetadata? winningMeta,
  ) {
    if (_isExplicitDub(muxed).isDub && signals.hasAnyNonDubTrack) {
      return false;
    }
    final origLang = winningMeta?.language;
    final muxLang = muxed.language;
    if (origLang != null && muxLang != null) {
      if (!_languagesMatch(origLang, muxLang)) return false;
    }
    return true;
  }

  RawFormatCandidate? _selectBestVideoOnlyForHeight(
    List<RawFormatCandidate> videoList,
  ) => _maxByVideoComparison(videoList);

  RawFormatCandidate? _maxByVideoComparison(List<RawFormatCandidate> list) {
    if (list.isEmpty) return null;
    var best = list.first;
    for (var i = 1; i < list.length; i++) {
      if (_compareVideoStreams(list[i], best) > 0) {
        best = list[i];
      }
    }
    return best;
  }

  static int _compareVideoStreams(RawFormatCandidate a, RawFormatCandidate b) {
    final directCmp = _boolCmp(_isHttpsDirect(a), _isHttpsDirect(b));
    if (directCmp != 0) return directCmp;

    final fpsA = a.format.fps?.round() ?? 0;
    final fpsB = b.format.fps?.round() ?? 0;
    final fpsCmp = fpsA.compareTo(fpsB);
    if (fpsCmp != 0) return fpsCmp;

    final codecCmp = _videoContainerCodecRank(
      a,
    ).compareTo(_videoContainerCodecRank(b));
    if (codecCmp != 0) return codecCmp;

    final sizeCmp = _boolCmp(
      a.format.fileSizeBytes != null,
      b.format.fileSizeBytes != null,
    );
    if (sizeCmp != 0) return sizeCmp;

    final bitrateCmp = (a.format.bitrateKbps ?? 0.0).compareTo(
      b.format.bitrateKbps ?? 0.0,
    );
    if (bitrateCmp != 0) return bitrateCmp;

    final qualityRankA = _progressiveQualityTagRank(a.format.formatId);
    final qualityRankB = _progressiveQualityTagRank(b.format.formatId);
    return qualityRankA.compareTo(qualityRankB);
  }

  static int _progressiveQualityTagRank(String formatId) =>
      switch (formatId.toLowerCase()) {
        'hd' => 2,
        'sd' => 1,
        _ => 0,
      };

  static int _videoContainerCodecRank(RawFormatCandidate cand) {
    final isMp4 = cand.format.container.toLowerCase() == 'mp4';
    final vcodec = cand.format.vcodec ?? '';
    if (isMp4 && vcodec.startsWith('avc1')) return 4;
    if (isMp4) return 3;
    if (cand.format.container.toLowerCase() == 'webm') return 2;
    return 1;
  }

  RawFormatCandidate? _selectAudioForPairing(
    List<RawFormatCandidate> audioCandidates,
    _AudioEnvironmentSignals signals,
    AudioTrackMetadata? winningMeta, {
    required bool preferM4a,
  }) {
    final lineageMatches = audioCandidates
        .where((c) => _matchesWinningLineage(c, signals, winningMeta))
        .toList(growable: false);
    final pool = lineageMatches.isEmpty ? audioCandidates : lineageMatches;
    return _selectPreferredAudioCandidate(pool, signals, preferM4a: preferM4a);
  }

  VideoQualityOption _buildCombinedVideoOption(
    int height,
    RawFormatCandidate muxed,
    AudioTrackMetadata? winningAudioMeta, {
    required bool isInstagram,
  }) {
    final audioMeta =
        winningAudioMeta ??
        (isInstagram
            ? _buildInstagramAudioMetadata(muxed)
            : _buildMuxedFallbackAudioMetadata(muxed));
    return VideoQualityOption(
      resolution: _formatResolutionLabel(height),
      height: height,
      fps: muxed.format.fps,
      container: muxed.format.container.toLowerCase(),
      displaySize: ByteFormatter.formatDisplaySize(
        muxed.format.fileSizeBytes,
        muxed.format.sizeAccuracy,
      ),
      fileSizeBytes: muxed.format.fileSizeBytes,
      sizeAccuracy: muxed.format.sizeAccuracy,
      videoFormatId: muxed.format.formatId,
      audioLanguage: audioMeta,
      formatSelectionStrategy: FormatSelectionStrategy.combinedAudioVideo,
    );
  }

  VideoQualityOption _buildUnknownResCombinedVideoOption(
    RawFormatCandidate muxed,
    AudioTrackMetadata? winningAudioMeta, {
    required bool isInstagram,
    String resolutionLabel = 'Standard',
    int? assumedHeight,
  }) {
    final audioMeta =
        winningAudioMeta ??
        (isInstagram
            ? _buildInstagramAudioMetadata(muxed)
            : _buildMuxedFallbackAudioMetadata(muxed));
    return VideoQualityOption(
      resolution: resolutionLabel,
      height: assumedHeight,
      fps: muxed.format.fps,
      container: muxed.format.container.toLowerCase(),
      displaySize: ByteFormatter.formatDisplaySize(
        muxed.format.fileSizeBytes,
        muxed.format.sizeAccuracy,
      ),
      fileSizeBytes: muxed.format.fileSizeBytes,
      sizeAccuracy: muxed.format.sizeAccuracy,
      videoFormatId: muxed.format.formatId,
      audioLanguage: audioMeta,
      formatSelectionStrategy: FormatSelectionStrategy.combinedAudioVideo,
    );
  }

  static AudioTrackMetadata _buildMuxedFallbackAudioMetadata(
    RawFormatCandidate muxed,
  ) {
    final lang = muxed.language;
    final display = _extractLanguageDisplayName(muxed, lang);
    final dub = _isExplicitDub(muxed);
    final langLabel = display ?? lang;
    final note = dub.isDub
        ? 'Audio included automatically · Dubbed track only; original not marked'
        : langLabel != null
        ? 'Audio included automatically · Language: $langLabel (original not marked)'
        : 'Audio included automatically · Original language not marked in metadata';

    return AudioTrackMetadata(
      language: lang,
      languageDisplayName: display,
      isOriginal: dub.isDub ? false : null,
      isAutoDub: dub.isDub ? dub.isAutoDub : null,
      selectionConfidence: AudioSelectionConfidence.singleOrUnmarked,
      statusNote: note,
    );
  }

  static VideoQualityOption _buildPairedVideoOption(
    int height,
    RawFormatCandidate video,
    RawFormatCandidate audio,
    AudioTrackMetadata? winningAudioMeta,
  ) {
    final vContainer = video.format.container.toLowerCase();
    final aContainer = audio.format.container.toLowerCase();
    final targetContainer = (vContainer == 'mp4' || aContainer == 'm4a')
        ? 'mp4'
        : (vContainer == 'webm' && aContainer == 'webm')
        ? 'webm'
        : 'mp4';

    final (bytes, accuracy) = _combineSizes(
      (video.format.fileSizeBytes, video.format.sizeAccuracy),
      (audio.format.fileSizeBytes, audio.format.sizeAccuracy),
    );

    return VideoQualityOption(
      resolution: _formatResolutionLabel(height),
      height: height,
      fps: video.format.fps,
      container: targetContainer,
      displaySize: ByteFormatter.formatDisplaySize(bytes, accuracy),
      fileSizeBytes: bytes,
      sizeAccuracy: accuracy,
      videoFormatId: video.format.formatId,
      selectedAudioFormatId: audio.format.formatId,
      audioLanguage: winningAudioMeta,
      formatSelectionStrategy:
          FormatSelectionStrategy.pairVideoAndAudioWithFfmpeg,
    );
  }

  static (int?, FileSizeAccuracy) _combineSizes(
    (int?, FileSizeAccuracy) video,
    (int?, FileSizeAccuracy) audio,
  ) {
    final vb = video.$1;
    final va = video.$2;
    final ab = audio.$1;
    final aa = audio.$2;
    if (vb != null &&
        ab != null &&
        va != FileSizeAccuracy.unknown &&
        aa != FileSizeAccuracy.unknown) {
      final accuracy =
          (va == FileSizeAccuracy.exact && aa == FileSizeAccuracy.exact)
          ? FileSizeAccuracy.exact
          : FileSizeAccuracy.estimated;
      return (vb + ab, accuracy);
    }
    return (null, FileSizeAccuracy.unknown);
  }

  static String _formatResolutionLabel(int height) => switch (height) {
    2160 => '4K (2160p)',
    4320 => '8K (4320p)',
    _ => '${height}p',
  };

  static int _boolCmp(bool a, bool b) => a == b ? 0 : (a ? 1 : -1);
}
