import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/features/media_download/media_download_state.dart';

/// Coordinates URL analysis, simplified quality selection, and single-job downloads.
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
      final defaultVideoId = result.videoOptions.isNotEmpty
          ? result.videoOptions.first.videoFormatId
          : null;
      final defaultAudioId = result.audioOptions.isNotEmpty
          ? result.audioOptions.first.formatId
          : null;

      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.loaded,
          inspection: result,
          inspectionError: null,
          mediaMode: DownloadMediaMode.videoWithSound,
          selectedVideoFormatId: defaultVideoId,
          selectedAudioOptionFormatId: defaultAudioId,
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

  void setMediaMode(DownloadMediaMode mode) {
    emit(state.copyWith(mediaMode: mode));
  }

  void selectVideoQuality(String videoFormatId) {
    emit(state.copyWith(selectedVideoFormatId: videoFormatId));
  }

  void selectAudioQuality(String formatId) {
    emit(state.copyWith(selectedAudioOptionFormatId: formatId));
  }

  Future<void> startDownload() async {
    final inspection = state.inspection;
    if (!state.canStartDownload || inspection == null) {
      return;
    }

    final DownloadFormatSelection selection;
    if (state.mediaMode == DownloadMediaMode.videoWithSound) {
      final chosen = state.selectedVideoOption!;
      if (chosen.formatSelectionStrategy ==
          FormatSelectionStrategy.combinedAudioVideo) {
        selection = DownloadFormatSelection(
          kind: DownloadSelectionKind.single,
          formatId: chosen.videoFormatId,
        );
      } else {
        selection = DownloadFormatSelection(
          kind: DownloadSelectionKind.videoAndAudio,
          videoFormatId: chosen.videoFormatId,
          audioFormatId: chosen.selectedAudioFormatId,
          mergeContainer: chosen.container,
        );
      }
    } else {
      final chosenAudio = state.selectedAudioOption!;
      selection = DownloadFormatSelection(
        kind: DownloadSelectionKind.single,
        formatId: chosenAudio.formatId,
      );
    }

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
