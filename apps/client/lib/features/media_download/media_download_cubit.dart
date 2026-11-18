import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/features/media_download/media_download_state.dart';

/// Coordinates URL analysis, dynamic format selection, and single-job downloads.
class MediaDownloadCubit extends Cubit<MediaDownloadState> {
  final MediaDownloadRepository _repository;
  StreamSubscription<DownloadProgressEvent>? _progressSubscription;

  MediaDownloadCubit({required this._repository})
    : super(const MediaDownloadState());

  /// Checks Rust FFI connectivity and subscribes to live progress events.
  void initialize() {
    try {
      final pong = _repository.ping();
      final version = _repository.engineVersion();
      emit(state.copyWith(engineStatus: '$pong (v$version)'));
    } catch (err) {
      emit(state.copyWith(engineStatus: 'Engine error: $err'));
    }

    _progressSubscription?.cancel();
    _progressSubscription = _repository.watchDownloadProgress().listen(
      _onProgressEvent,
      onError: (Object error) {
        emit(state.copyWith(downloadError: 'Progress stream error: $error'));
      },
    );
  }

  void updateUrl(String url) {
    emit(state.copyWith(urlInput: url));
  }

  Future<void> analyzeUrl([String? overrideUrl]) async {
    final targetUrl = (overrideUrl ?? state.urlInput).trim();
    if (overrideUrl != null) {
      emit(state.copyWith(urlInput: overrideUrl));
    }

    if (targetUrl.isEmpty) {
      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.failure,
          inspectionError: 'Please paste or enter a media URL to analyze.',
        ),
      );
      return;
    }

    emit(
      state.copyWith(
        urlInput: targetUrl,
        inspectionStatus: InspectionStatus.loading,
        inspectionError: null,
        downloadError: null,
      ),
    );

    try {
      final result = await _repository.inspectMedia(targetUrl);
      final defaults = _pickInitialSelectionDefaults(result);

      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.loaded,
          inspection: result,
          inspectionError: null,
          selectionMode: SelectionMode.single,
          selectedSingleFormatId: defaults.singleId,
          selectedVideoFormatId: defaults.videoId,
          selectedAudioFormatId: defaults.audioId,
        ),
      );
    } catch (err) {
      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.failure,
          inspectionError: _cleanErrorMessage(err),
        ),
      );
    }
  }

  void setSelectionMode(SelectionMode mode) {
    if (mode == SelectionMode.mergeVideoAudio &&
        !state.supportsMergeSelection) {
      return;
    }
    emit(state.copyWith(selectionMode: mode));
  }

  void selectSingleFormat(String formatId) {
    emit(state.copyWith(selectedSingleFormatId: formatId));
  }

  void selectVideoFormat(String formatId) {
    emit(state.copyWith(selectedVideoFormatId: formatId));
  }

  void selectAudioFormat(String formatId) {
    emit(state.copyWith(selectedAudioFormatId: formatId));
  }

  Future<void> startDownload() async {
    final inspection = state.inspection;
    if (!state.canStartDownload || inspection == null) {
      return;
    }

    final selection = state.selectionMode == SelectionMode.single
        ? DownloadFormatSelection(
            kind: DownloadSelectionKind.single,
            formatId: state.selectedSingleFormatId,
          )
        : DownloadFormatSelection(
            kind: DownloadSelectionKind.videoAndAudio,
            videoFormatId: state.selectedVideoFormatId,
            audioFormatId: state.selectedAudioFormatId,
            mergeContainer: 'mp4',
          );

    final targetUrl = inspection.webpageUrl.isNotEmpty
        ? inspection.webpageUrl
        : state.urlInput.trim();

    final request = StartDownloadRequest(
      url: targetUrl,
      title: inspection.title,
      selection: selection,
    );

    emit(
      state.copyWith(
        isStartingDownload: true,
        activeJobId: null,
        latestProgress: null,
        downloadError: null,
      ),
    );

    try {
      final jobId = await _repository.startDownload(request);
      emit(state.copyWith(activeJobId: jobId, isStartingDownload: false));
    } catch (err) {
      emit(
        state.copyWith(
          isStartingDownload: false,
          downloadError: _cleanErrorMessage(err),
        ),
      );
    }
  }

  Future<void> cancelDownload() async {
    final jobId = state.activeJobId;
    if (jobId == null || !state.canCancel) return;

    try {
      await _repository.cancelDownload(jobId);
    } catch (err) {
      emit(state.copyWith(downloadError: _cleanErrorMessage(err)));
    }
  }

  Future<void> resumeDownload() async {
    final jobId = state.activeJobId;
    if (jobId == null || !state.canResume) return;

    emit(state.copyWith(isStartingDownload: true, downloadError: null));
    try {
      final resumedJobId = await _repository.resumeDownload(jobId);
      emit(
        state.copyWith(activeJobId: resumedJobId, isStartingDownload: false),
      );
    } catch (err) {
      emit(
        state.copyWith(
          isStartingDownload: false,
          downloadError: _cleanErrorMessage(err),
        ),
      );
    }
  }

  void _onProgressEvent(DownloadProgressEvent event) {
    final activeId = state.activeJobId;
    if (activeId != null && event.jobId != activeId) {
      return;
    }
    if (activeId == null && !state.isStartingDownload) {
      return;
    }

    emit(
      state.copyWith(
        activeJobId: activeId ?? event.jobId,
        latestProgress: event,
        downloadError: event.phase == DownloadPhase.failed
            ? (event.message ?? 'Download failed.')
            : null,
      ),
    );
  }

  ({String? singleId, String? videoId, String? audioId})
  _pickInitialSelectionDefaults(MediaInspection inspection) {
    final formats = inspection.formats;
    if (formats.isEmpty) {
      return (singleId: null, videoId: null, audioId: null);
    }

    DiscoveredFormat? preferredMuxed;
    for (final fmt in formats) {
      if (fmt.streamKind == StreamKind.muxedAudioVideo) {
        preferredMuxed = fmt;
        break;
      }
    }
    final singleId = (preferredMuxed ?? formats.first).formatId;

    final videoOnly = formats
        .where((f) => f.streamKind == StreamKind.videoOnly)
        .toList(growable: false);
    final audioOnly = formats
        .where((f) => f.streamKind == StreamKind.audioOnly)
        .toList(growable: false);

    String? bestVideoId;
    if (videoOnly.isNotEmpty) {
      final sortedVideo = List<DiscoveredFormat>.from(videoOnly)
        ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
      bestVideoId = sortedVideo.first.formatId;
    }

    String? bestAudioId;
    if (audioOnly.isNotEmpty) {
      final sortedAudio = List<DiscoveredFormat>.from(audioOnly)
        ..sort((a, b) => (b.bitrateKbps ?? 0).compareTo(a.bitrateKbps ?? 0));
      bestAudioId = sortedAudio.first.formatId;
    }

    return (singleId: singleId, videoId: bestVideoId, audioId: bestAudioId);
  }

  String _cleanErrorMessage(Object error) {
    final text = error.toString().trim();
    if (text.startsWith('AnyhowException(') && text.endsWith(')')) {
      return text.substring('AnyhowException('.length, text.length - 1);
    }
    return text;
  }

  @override
  Future<void> close() async {
    await _progressSubscription?.cancel();
    return super.close();
  }
}
