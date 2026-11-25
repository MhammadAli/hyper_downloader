import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/repositories/single_download_repository.dart';

/// Coordinates starting, pausing/canceling, resuming, and watching single downloads.
class ManageSingleDownloadUseCase {
  final SingleDownloadRepository _repository;

  const ManageSingleDownloadUseCase(this._repository);

  Stream<DownloadProgressEvent> watchProgress() =>
      _repository.watchDownloadProgress();

  Future<String> start({
    required MediaInspection inspection,
    required String fallbackUrl,
    required DownloadMediaMode mediaMode,
    VideoQualityOption? videoOption,
    AudioQualityOption? audioOption,
  }) {
    final DownloadFormatSelection selection;
    if (mediaMode == DownloadMediaMode.videoWithSound) {
      final chosen = videoOption!;
      if (chosen.formatSelectionStrategy ==
          FormatSelectionStrategy.combinedAudioVideo) {
        selection = DownloadFormatSelection.single(chosen.videoFormatId);
      } else {
        selection = DownloadFormatSelection.videoAndAudio(
          videoFormatId: chosen.videoFormatId,
          audioFormatId: chosen.selectedAudioFormatId!,
          mergeContainer: chosen.container,
        );
      }
    } else {
      selection = DownloadFormatSelection.single(audioOption!.formatId);
    }

    final targetUrl = inspection.webpageUrl.isNotEmpty
        ? inspection.webpageUrl
        : fallbackUrl.trim();

    return _repository.startDownload(
      StartDownloadRequest(
        url: targetUrl,
        title: inspection.title,
        selection: selection,
      ),
    );
  }

  Future<void> cancel(String jobId) => _repository.cancelDownload(jobId);

  Future<String> resume(String jobId) => _repository.resumeDownload(jobId);
}
