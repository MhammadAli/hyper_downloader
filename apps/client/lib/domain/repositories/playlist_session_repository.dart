import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

/// Contract for loading and saving durable playlist session manifests.
abstract interface class PlaylistSessionRepository {
  Future<PlaylistSessionSnapshot?> loadSavedSession({
    required String playlistId,
    String? outputDirectory,
  });

  Future<void> saveSession({
    required String playlistDirectory,
    required PlaylistSessionSnapshot snapshot,
  });
}
