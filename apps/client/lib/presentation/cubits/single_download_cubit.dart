import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/usecases/manage_single_download_usecase.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_state.dart';

/// Manages quality selection and single-video / audio-only transfer lifecycle.
class SingleDownloadCubit extends Cubit<SingleDownloadState> {
  final ManageSingleDownloadUseCase _useCase;

  StreamSubscription<DownloadProgressEvent>? _progressSubscription;
  bool _pauseRequested = false;

  SingleDownloadCubit(this._useCase) : super(const SingleDownloadState());

  void initialize() {
    _progressSubscription?.cancel();
    _progressSubscription = _useCase.watchProgress().listen(
      _onProgressEvent,
      onError: (Object error) {
        emit(state.copyWith(downloadError: 'Progress stream error: $error'));
      },
    );
  }

  void loadInspection(MediaInspection inspection, {String sourceUrl = ''}) {
    final defaultVideoId = inspection.videoOptions.isNotEmpty
        ? inspection.videoOptions.first.videoFormatId
        : null;
    final defaultAudioId = inspection.audioOptions.isNotEmpty
        ? inspection.audioOptions.first.formatId
        : null;
    _pauseRequested = false;
    emit(
      SingleDownloadState(
        inspection: inspection,
        sourceUrl: sourceUrl,
        mediaMode: DownloadMediaMode.videoWithSound,
        selectedVideoFormatId: defaultVideoId,
        selectedAudioOptionFormatId: defaultAudioId,
      ),
    );
  }

  void clear() {
    _pauseRequested = false;
    emit(const SingleDownloadState());
  }

  void setMediaMode(DownloadMediaMode mode) {
    if (mode == DownloadMediaMode.audioOnly && state.audioOptions.isEmpty) {
      return;
    }
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
    if (!state.canStartDownload || inspection == null) return;

    _pauseRequested = false;
    emit(
      state.copyWith(
        isStartingDownload: true,
        isPaused: false,
        activeJobId: null,
        latestProgress: null,
        downloadError: null,
      ),
    );

    try {
      final jobId = await _useCase.start(
        inspection: inspection,
        fallbackUrl: state.sourceUrl,
        mediaMode: state.mediaMode,
        videoOption: state.selectedVideoOption,
        audioOption: state.selectedAudioOption,
      );
      if (isClosed) return;
      emit(state.copyWith(activeJobId: jobId, isStartingDownload: false));
    } catch (err) {
      if (isClosed) return;
      emit(
        state.copyWith(
          isStartingDownload: false,
          downloadError: err.toString().trim(),
        ),
      );
    }
  }

  Future<void> pauseDownload() async {
    final jobId = state.activeJobId;
    if (jobId == null || !state.canPause) return;

    _pauseRequested = true;
    try {
      await _useCase.cancel(jobId);
    } catch (err) {
      _pauseRequested = false;
      if (isClosed) return;
      emit(state.copyWith(downloadError: err.toString().trim()));
    }
  }

  Future<void> cancelDownload() async {
    final jobId = state.activeJobId;
    if (jobId == null || !state.canCancel) return;

    _pauseRequested = false;
    try {
      await _useCase.cancel(jobId);
    } catch (err) {
      if (isClosed) return;
      emit(state.copyWith(downloadError: err.toString().trim()));
    }
  }

  Future<void> resumeDownload() async {
    final jobId = state.activeJobId;
    if (jobId == null || !state.canResume) return;

    _pauseRequested = false;
    emit(
      state.copyWith(
        isStartingDownload: true,
        isPaused: false,
        downloadError: null,
      ),
    );
    try {
      final resumedJobId = await _useCase.resume(jobId);
      if (isClosed) return;
      emit(
        state.copyWith(activeJobId: resumedJobId, isStartingDownload: false),
      );
    } catch (err) {
      if (isClosed) return;
      emit(
        state.copyWith(
          isStartingDownload: false,
          downloadError: err.toString().trim(),
        ),
      );
    }
  }

  void _onProgressEvent(DownloadProgressEvent event) {
    final activeId = state.activeJobId;
    if (activeId != null && event.jobId != activeId) return;

    final isActivePhase =
        event.phase != DownloadPhase.completed &&
        event.phase != DownloadPhase.failed &&
        event.phase != DownloadPhase.canceled;
    if (activeId == null && !state.isStartingDownload && !isActivePhase) {
      return;
    }

    final isPauseEvent =
        event.phase == DownloadPhase.canceled && _pauseRequested;
    if (event.phase != DownloadPhase.canceled) {
      _pauseRequested = false;
    }

    final effectiveEvent = isPauseEvent
        ? DownloadProgressEvent(
            jobId: event.jobId,
            phase: event.phase,
            downloadedBytes: event.downloadedBytes,
            totalBytes: event.totalBytes,
            isTotalEstimated: event.isTotalEstimated,
            outputPath: event.outputPath,
            message: 'Download paused. Click Resume to continue.',
          )
        : event;

    emit(
      state.copyWith(
        activeJobId: activeId ?? event.jobId,
        isPaused: isPauseEvent,
        latestProgress: effectiveEvent,
        downloadError: event.phase == DownloadPhase.failed
            ? (event.message ?? 'Download failed.')
            : null,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _progressSubscription?.cancel();
    return super.close();
  }
}
