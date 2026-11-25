import 'package:hyper_download_client/core/error/app_exception.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/repositories/media_inspection_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_session_repository.dart';

/// Validates input, inspects a single video or playlist URL, and hydrates any
/// saved resumable playlist session manifest.
class InspectUrlUseCase {
  final MediaInspectionRepository _inspectionRepository;
  final PlaylistSessionRepository _sessionRepository;

  const InspectUrlUseCase({
    required this._inspectionRepository,
    required this._sessionRepository,
  });

  Future<UrlInspectionResult> call(String rawUrl) async {
    final targetUrl = rawUrl.trim();
    if (targetUrl.isEmpty) {
      throw const InvalidUrlException(
        'Please paste or enter a media URL to analyze.',
      );
    }

    final result = await _inspectionRepository.inspectUrl(targetUrl);
    if (result.kind == InspectionTargetKind.playlist &&
        result.playlist != null) {
      PlaylistSessionSnapshot? saved;
      try {
        saved = await _sessionRepository.loadSavedSession(
          playlistId: result.playlist!.id,
        );
      } catch (_) {
        // Saved manifest loading is best-effort only.
      }
      if (saved != null) {
        return result.copyWith(savedPlaylistSession: saved);
      }
    }
    return result;
  }
}
