import 'package:equatable/equatable.dart';

/// Simplified IDM-style download modes shown in the UI.
enum DownloadMediaMode { videoWithSound, audioOnly }

/// Distinguishes single-format downloads from separate video+audio FFmpeg merges.
enum DownloadSelectionKind { single, videoAndAudio }

/// User-chosen format specification for a download job.
class DownloadFormatSelection extends Equatable {
  final DownloadSelectionKind kind;
  final String? formatId;
  final String? videoFormatId;
  final String? audioFormatId;
  final String? mergeContainer;

  const DownloadFormatSelection({
    required this.kind,
    this.formatId,
    this.videoFormatId,
    this.audioFormatId,
    this.mergeContainer,
  });

  const DownloadFormatSelection.single(String this.formatId)
    : kind = DownloadSelectionKind.single,
      videoFormatId = null,
      audioFormatId = null,
      mergeContainer = null;

  const DownloadFormatSelection.videoAndAudio({
    required String this.videoFormatId,
    required String this.audioFormatId,
    String this.mergeContainer = 'mp4',
  }) : kind = DownloadSelectionKind.videoAndAudio,
       formatId = null;

  @override
  List<Object?> get props => [
    kind,
    formatId,
    videoFormatId,
    audioFormatId,
    mergeContainer,
  ];
}

/// Request payload to start a single download job.
class StartDownloadRequest extends Equatable {
  final String url;
  final String? title;
  final DownloadFormatSelection selection;
  final String? outputDirectory;

  const StartDownloadRequest({
    required this.url,
    this.title,
    required this.selection,
    this.outputDirectory,
  });

  @override
  List<Object?> get props => [url, title, selection, outputDirectory];
}

/// High-level lifecycle phase emitted for a download job.
enum DownloadPhase {
  analyzing,
  downloading,
  merging,
  completed,
  canceled,
  failed,
}

/// Incremental progress update streamed from the download engine.
class DownloadProgressEvent extends Equatable {
  final String jobId;
  final DownloadPhase phase;
  final int downloadedBytes;
  final int? totalBytes;
  final bool isTotalEstimated;
  final double? speedBytesPerSec;
  final int? etaSeconds;
  final String? outputPath;
  final String? message;

  const DownloadProgressEvent({
    required this.jobId,
    required this.phase,
    required this.downloadedBytes,
    this.totalBytes,
    required this.isTotalEstimated,
    this.speedBytesPerSec,
    this.etaSeconds,
    this.outputPath,
    this.message,
  });

  @override
  List<Object?> get props => [
    jobId,
    phase,
    downloadedBytes,
    totalBytes,
    isTotalEstimated,
    speedBytesPerSec,
    etaSeconds,
    outputPath,
    message,
  ];
}
