import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

/// Contract for URL classification, single-video inspection, and playlist enumeration.
abstract interface class MediaInspectionRepository {
  Future<UrlInspectionResult> inspectUrl(String url);

  Future<MediaInspection> inspectMedia(String url);

  Future<PlaylistInspection> inspectPlaylist(String url);

  bool isRegisteredAudioOnlyFormat(String url, String formatId);
}
