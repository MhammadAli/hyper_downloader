import 'package:equatable/equatable.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';

const Object _unset = Object();

class SingleDownloadState extends Equatable {
  final MediaInspection? inspection;
  final String sourceUrl;
  final DownloadMediaMode mediaMode;
  final String? selectedVideoFormatId;
  final String? selectedAudioOptionFormatId;
  final String? activeJobId;
  final bool isStartingDownload;
  final bool isPaused;
  final DownloadProgressEvent? latestProgress;
  final String? downloadError;

  const SingleDownloadState({
    this.inspection,
    this.sourceUrl = '',
    this.mediaMode = DownloadMediaMode.videoWithSound,
    this.selectedVideoFormatId,
    this.selectedAudioOptionFormatId,
    this.activeJobId,
    this.isStartingDownload = false,
    this.isPaused = false,
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

  bool get isPreparingDownload =>
      isStartingDownload || (activeJobId != null && latestProgress == null);

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

  bool get canPause {
    if (activeJobId == null || isStartingDownload) return false;
    final progress = latestProgress;
    return progress != null &&
        progress.phase == DownloadPhase.downloading &&
        progress.downloadedBytes > 0;
  }

  bool get canCancel {
    if (activeJobId == null) return false;
    if (isPreparingDownload) return true;
    final phase = currentPhase;
    return phase == DownloadPhase.analyzing ||
        phase == DownloadPhase.downloading ||
        phase == DownloadPhase.merging;
  }

  bool get canResume {
    if (activeJobId == null || isStartingDownload) return false;
    final phase = currentPhase;
    return isPaused ||
        phase == DownloadPhase.canceled ||
        phase == DownloadPhase.failed;
  }

  bool get hasTransferOrInspection =>
      inspection != null || latestProgress != null || activeJobId != null;

  SingleDownloadState copyWith({
    Object? inspection = _unset,
    String? sourceUrl,
    DownloadMediaMode? mediaMode,
    Object? selectedVideoFormatId = _unset,
    Object? selectedAudioOptionFormatId = _unset,
    Object? activeJobId = _unset,
    bool? isStartingDownload,
    bool? isPaused,
    Object? latestProgress = _unset,
    Object? downloadError = _unset,
  }) {
    return SingleDownloadState(
      inspection: identical(inspection, _unset)
          ? this.inspection
          : inspection as MediaInspection?,
      sourceUrl: sourceUrl ?? this.sourceUrl,
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
      isPaused: isPaused ?? this.isPaused,
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
    inspection,
    sourceUrl,
    mediaMode,
    selectedVideoFormatId,
    selectedAudioOptionFormatId,
    activeJobId,
    isStartingDownload,
    isPaused,
    latestProgress,
    downloadError,
  ];
}
