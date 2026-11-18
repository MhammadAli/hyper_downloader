import 'package:equatable/equatable.dart';
import 'package:hyper_download_client/core/bridge/models.dart';

/// UI selection mode for downloading either one format or a merged pair.
enum SelectionMode { single, mergeVideoAudio }

/// URL inspection lifecycle status.
enum InspectionStatus { initial, loading, loaded, failure }

const Object _unset = Object();

/// Immutable UI and engine state for Phase 2B media inspection & downloading.
class MediaDownloadState extends Equatable {
  final String engineStatus;
  final String urlInput;
  final InspectionStatus inspectionStatus;
  final MediaInspection? inspection;
  final String? inspectionError;
  final SelectionMode selectionMode;
  final String? selectedSingleFormatId;
  final String? selectedVideoFormatId;
  final String? selectedAudioFormatId;
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
    this.selectionMode = SelectionMode.single,
    this.selectedSingleFormatId,
    this.selectedVideoFormatId,
    this.selectedAudioFormatId,
    this.activeJobId,
    this.isStartingDownload = false,
    this.latestProgress,
    this.downloadError,
  });

  List<DiscoveredFormat> get allFormats => inspection?.formats ?? const [];

  List<DiscoveredFormat> get videoOnlyFormats => allFormats
      .where((f) => f.streamKind == StreamKind.videoOnly)
      .toList(growable: false);

  List<DiscoveredFormat> get audioOnlyFormats => allFormats
      .where((f) => f.streamKind == StreamKind.audioOnly)
      .toList(growable: false);

  bool get supportsMergeSelection =>
      videoOnlyFormats.isNotEmpty && audioOnlyFormats.isNotEmpty;

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
    switch (selectionMode) {
      case SelectionMode.single:
        return selectedSingleFormatId != null;
      case SelectionMode.mergeVideoAudio:
        return selectedVideoFormatId != null && selectedAudioFormatId != null;
    }
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
    SelectionMode? selectionMode,
    Object? selectedSingleFormatId = _unset,
    Object? selectedVideoFormatId = _unset,
    Object? selectedAudioFormatId = _unset,
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
      selectionMode: selectionMode ?? this.selectionMode,
      selectedSingleFormatId: identical(selectedSingleFormatId, _unset)
          ? this.selectedSingleFormatId
          : selectedSingleFormatId as String?,
      selectedVideoFormatId: identical(selectedVideoFormatId, _unset)
          ? this.selectedVideoFormatId
          : selectedVideoFormatId as String?,
      selectedAudioFormatId: identical(selectedAudioFormatId, _unset)
          ? this.selectedAudioFormatId
          : selectedAudioFormatId as String?,
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
    inspection?.formats,
    inspectionError,
    selectionMode,
    selectedSingleFormatId,
    selectedVideoFormatId,
    selectedAudioFormatId,
    activeJobId,
    isStartingDownload,
    latestProgress,
    downloadError,
  ];
}
