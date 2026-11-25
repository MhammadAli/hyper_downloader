import 'package:equatable/equatable.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

/// Precision level reported for a format's byte size.
enum FileSizeAccuracy { exact, estimated, unknown }

/// Kind of media streams contained in a discovered format.
enum StreamKind { muxedAudioVideo, videoOnly, audioOnly }

/// Confidence level for identifying the source video's original audio track.
enum AudioSelectionConfidence {
  confirmedOriginal,
  likelyOriginal,
  singleOrUnmarked,
  ambiguousOrUnknown,
}

/// Metadata describing an audio track's language and originality signals.
class AudioTrackMetadata extends Equatable {
  final String? language;
  final String? languageDisplayName;
  final bool? isOriginal;
  final bool? isDefault;
  final bool? isAutoDub;
  final AudioSelectionConfidence selectionConfidence;
  final String statusNote;

  const AudioTrackMetadata({
    this.language,
    this.languageDisplayName,
    this.isOriginal,
    this.isDefault,
    this.isAutoDub,
    required this.selectionConfidence,
    required this.statusNote,
  });

  @override
  List<Object?> get props => [
    language,
    languageDisplayName,
    isOriginal,
    isDefault,
    isAutoDub,
    selectionConfidence,
    statusNote,
  ];
}

/// Strategy used internally to produce a playable download for a selected quality.
enum FormatSelectionStrategy {
  combinedAudioVideo,
  pairVideoAndAudioWithFfmpeg,
  audioOnlyStream,
}

/// High-level user-facing video quality option representing a complete video with sound.
class VideoQualityOption extends Equatable {
  final String resolution;
  final int? height;
  final double? fps;
  final String container;
  final String displaySize;
  final int? fileSizeBytes;
  final FileSizeAccuracy sizeAccuracy;
  final String videoFormatId;
  final String? selectedAudioFormatId;
  final AudioTrackMetadata? audioLanguage;
  final FormatSelectionStrategy formatSelectionStrategy;

  const VideoQualityOption({
    required this.resolution,
    this.height,
    this.fps,
    required this.container,
    required this.displaySize,
    this.fileSizeBytes,
    required this.sizeAccuracy,
    required this.videoFormatId,
    this.selectedAudioFormatId,
    this.audioLanguage,
    required this.formatSelectionStrategy,
  });

  @override
  List<Object?> get props => [
    resolution,
    height,
    fps,
    container,
    displaySize,
    fileSizeBytes,
    sizeAccuracy,
    videoFormatId,
    selectedAudioFormatId,
    audioLanguage,
    formatSelectionStrategy,
  ];
}

/// Curated user-facing audio-only quality option using the selected original audio track.
class AudioQualityOption extends Equatable {
  final String qualityLabel;
  final String container;
  final double? bitrateKbps;
  final String displaySize;
  final int? fileSizeBytes;
  final FileSizeAccuracy sizeAccuracy;
  final String formatId;
  final AudioTrackMetadata? audioLanguage;

  const AudioQualityOption({
    required this.qualityLabel,
    required this.container,
    this.bitrateKbps,
    required this.displaySize,
    this.fileSizeBytes,
    required this.sizeAccuracy,
    required this.formatId,
    this.audioLanguage,
  });

  @override
  List<Object?> get props => [
    qualityLabel,
    container,
    bitrateKbps,
    displaySize,
    fileSizeBytes,
    sizeAccuracy,
    formatId,
    audioLanguage,
  ];
}

/// A genuine media format discovered during URL inspection.
class DiscoveredFormat extends Equatable {
  final String formatId;
  final String container;
  final StreamKind streamKind;
  final String resolution;
  final int? width;
  final int? height;
  final double? fps;
  final String? vcodec;
  final String? acodec;
  final double? bitrateKbps;
  final int? fileSizeBytes;
  final FileSizeAccuracy sizeAccuracy;
  final String? formatNote;

  const DiscoveredFormat({
    required this.formatId,
    required this.container,
    required this.streamKind,
    required this.resolution,
    this.width,
    this.height,
    this.fps,
    this.vcodec,
    this.acodec,
    this.bitrateKbps,
    this.fileSizeBytes,
    required this.sizeAccuracy,
    this.formatNote,
  });

  @override
  List<Object?> get props => [
    formatId,
    container,
    streamKind,
    resolution,
    width,
    height,
    fps,
    vcodec,
    acodec,
    bitrateKbps,
    fileSizeBytes,
    sizeAccuracy,
    formatNote,
  ];
}

/// Enriched stream candidate extracted during `yt-dlp` JSON parsing.
class RawFormatCandidate {
  final DiscoveredFormat format;
  final String? protocol;
  final String? language;
  final int? languagePreference;
  final int? sourcePreference;
  final String? xtagsAcont;

  const RawFormatCandidate({
    required this.format,
    this.protocol,
    this.language,
    this.languagePreference,
    this.sourcePreference,
    this.xtagsAcont,
  });
}

/// Metadata and genuinely available options/formats extracted for a media URL.
class MediaInspection extends Equatable {
  final String id;
  final String title;
  final String? uploader;
  final double? durationSeconds;
  final String? thumbnailUrl;
  final String webpageUrl;
  final String providerName;
  final AudioTrackMetadata? originalAudio;
  final List<VideoQualityOption> videoOptions;
  final List<AudioQualityOption> audioOptions;
  final List<DiscoveredFormat> formats;

  const MediaInspection({
    required this.id,
    required this.title,
    this.uploader,
    this.durationSeconds,
    this.thumbnailUrl,
    required this.webpageUrl,
    required this.providerName,
    this.originalAudio,
    required this.videoOptions,
    required this.audioOptions,
    required this.formats,
  });

  @override
  List<Object?> get props => [
    id,
    title,
    uploader,
    durationSeconds,
    thumbnailUrl,
    webpageUrl,
    providerName,
    originalAudio,
    videoOptions,
    audioOptions,
    formats,
  ];
}

/// Identifies whether an analyzed URL points to a single video or a playlist.
enum InspectionTargetKind { singleVideo, playlist }

/// Unified result returned when analyzing any single-video or playlist URL.
class UrlInspectionResult extends Equatable {
  final InspectionTargetKind kind;
  final MediaInspection? video;
  final PlaylistInspection? playlist;
  final PlaylistSessionSnapshot? savedPlaylistSession;

  const UrlInspectionResult({
    required this.kind,
    this.video,
    this.playlist,
    this.savedPlaylistSession,
  });

  UrlInspectionResult copyWith({
    PlaylistSessionSnapshot? savedPlaylistSession,
  }) {
    return UrlInspectionResult(
      kind: kind,
      video: video,
      playlist: playlist,
      savedPlaylistSession: savedPlaylistSession ?? this.savedPlaylistSession,
    );
  }

  @override
  List<Object?> get props => [kind, video, playlist, savedPlaylistSession];
}
