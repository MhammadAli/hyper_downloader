import 'package:equatable/equatable.dart';
import 'package:hyper_download_client/core/bridge/models.dart';


/// Simplified IDM-style download modes shown in the UI.
enum DownloadMediaMode { videoWithSound, audioOnly }

/// URL inspection lifecycle status.
enum InspectionStatus { initial, loading, loaded, failure }

const Object _unset = Object();

/// Immutable UI and engine state for IDM-style media inspection & downloading.
class MediaDownloadState extends Equatable {
  final String engineStatus;
  final String urlInput;
  final InspectionStatus inspectionStatus;
  final MediaInspection? inspection;
  final String? inspectionError;
  final DownloadMediaMode mediaMode;
  final String? selectedVideoFormatId;
  final String? selectedAudioOptionFormatId;
  final String? activeJobId;
  final bool isStartingDownload;
  final DownloadProgressEvent? latestProgress;
  final String? downloadError;

  const MediaDownloadState({
    this.engineStatus = 'Connecting to Rust engine...',
    this.urlInput = '',
    this.inspectionStatus = InspectionStatus.initial,
    this.inspection,
    this.inspectionError,
    this.mediaMode = DownloadMediaMode.videoWithSound,
    this.selectedVideoFormatId,
    this.selectedAudioOptionFormatId,
    this.activeJobId,
    this.isStartingDownload = false,
    this.latestProgress,
    this.downloadError,
  });

  List<VideoQualityOption> get videoOptions =>
      inspection?.videoOptions ?? const [];

  List<AudioQualityOption> get audioOptions =>
      inspection?.audioOptions ?? const [];

  AudioTrackMetadata? get originalAudio => inspection?.originalAudio;

  VideoQualityOption? get selectedVideoOption {
    final key = selectedVideoFormatId;
    if (key == null) return null;
    for (final option in videoOptions) {
      if (option.videoFormatId == key) return option;
    }
    return null;
  }

  AudioQualityOption? get selectedAudioOption {
    final key = selectedAudioOptionFormatId;
    if (key == null) return null;
    for (final option in audioOptions) {
      if (option.formatId == key) return option;
    }
    return null;
  }

  DownloadPhase? get currentPhase => latestProgress?.phase;

  bool get isDownloadActive {
    if (isStartingDownload) return true;
    final phase = currentPhase;
    return phase == DownloadPhase.analyzing ||
        phase == DownloadPhase.downloading ||
        phase == DownloadPhase.merging;
  }

  bool get canStartDownload {
    if (isDownloadActive || inspection == null) return false;
    return switch (mediaMode) {
      DownloadMediaMode.videoWithSound => selectedVideoOption != null,
      DownloadMediaMode.audioOnly => selectedAudioOption != null,
    };
  }

  bool get canCancel {
    if (activeJobId == null) return false;
    final phase = currentPhase;
    return isStartingDownload ||
        phase == DownloadPhase.analyzing ||
        phase == DownloadPhase.downloading ||
        phase == DownloadPhase.merging;
  }

  bool get canResume {
    if (activeJobId == null || isStartingDownload) return false;
    final phase = currentPhase;
    return phase == DownloadPhase.canceled || phase == DownloadPhase.failed;
  }

  MediaDownloadState copyWith({
    String? engineStatus,
    String? urlInput,
    InspectionStatus? inspectionStatus,
    Object? inspection = _unset,
    Object? inspectionError = _unset,
    DownloadMediaMode? mediaMode,
    Object? selectedVideoFormatId = _unset,
    Object? selectedAudioOptionFormatId = _unset,
    Object? activeJobId = _unset,
    bool? isStartingDownload,
    Object? latestProgress = _unset,
    Object? downloadError = _unset,
  }) {
    return MediaDownloadState(
      engineStatus: engineStatus ?? this.engineStatus,
      urlInput: urlInput ?? this.urlInput,
      inspectionStatus: inspectionStatus ?? this.inspectionStatus,
      inspection: identical(inspection, _unset)
          ? this.inspection
          : inspection as MediaInspection?,
      inspectionError: identical(inspectionError, _unset)
          ? this.inspectionError
          : inspectionError as String?,
      mediaMode: mediaMode ?? this.mediaMode,
      selectedVideoFormatId: identical(selectedVideoFormatId, _unset)
          ? this.selectedVideoFormatId
          : selectedVideoFormatId as String?,
      selectedAudioOptionFormatId:
          identical(selectedAudioOptionFormatId, _unset)
          ? this.selectedAudioOptionFormatId
          : selectedAudioOptionFormatId as String?,
      activeJobId: identical(activeJobId, _unset)
          ? this.activeJobId
          : activeJobId as String?,
      isStartingDownload: isStartingDownload ?? this.isStartingDownload,
      latestProgress: identical(latestProgress, _unset)
          ? this.latestProgress
          : latestProgress as DownloadProgressEvent?,
      downloadError: identical(downloadError, _unset)
          ? this.downloadError
          : downloadError as String?,
    );
  }

  @override
  List<Object?> get props => [
    engineStatus,
    urlInput,
    inspectionStatus,
    inspection?.id,
    inspection?.title,
    inspection?.uploader,
    inspection?.durationSeconds,
    inspection?.thumbnailUrl,
    inspection?.webpageUrl,
    inspection?.providerName,
    inspection?.originalAudio,
    inspection?.videoOptions,
    inspection?.audioOptions,
    inspection?.formats,
    inspectionError,
    mediaMode,
    selectedVideoFormatId,
    selectedAudioOptionFormatId,
    activeJobId,
    isStartingDownload,
    latestProgress,
    downloadError,
  ];
}
