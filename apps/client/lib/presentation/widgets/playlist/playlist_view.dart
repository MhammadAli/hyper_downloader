import 'package:flutter/material.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_state.dart';
import 'package:hyper_download_client/presentation/widgets/playlist/playlist_controls_card.dart';
import 'package:hyper_download_client/presentation/widgets/playlist/playlist_header_card.dart';
import 'package:hyper_download_client/presentation/widgets/playlist/playlist_items_card.dart';

class PlaylistView extends StatelessWidget {
  final PlaylistDownloadState state;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const PlaylistView({
    super.key,
    required this.state,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final playlist = state.playlistInspection;
    if (playlist == null) {
      return const SizedBox.shrink();
    }

    final session = state.playlistSession;
    final displayItems = _buildDisplayItems(playlist, session);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlaylistHeaderCard(
          playlist: playlist,
          session: session,
          onRevealInFolder: onRevealInFolder,
        ),
        const SizedBox(height: 16),
        PlaylistControlsCard(state: state, playlist: playlist),
        const SizedBox(height: 16),
        PlaylistItemsCard(
          items: displayItems,
          sizeEstimate: state.playlistSizeEstimate,
          onOpenFile: onOpenFile,
          onRevealInFolder: onRevealInFolder,
        ),
      ],
    );
  }

  List<PlaylistItemState> _buildDisplayItems(
    PlaylistInspection playlist,
    PlaylistSessionSnapshot? session,
  ) {
    if (session != null) return session.items;

    return playlist.entries
        .map((entry) {
          final (PlaylistItemStatus status, String? message) =
              switch (entry.availability) {
                PlaylistEntryAvailability.available => (
                  PlaylistItemStatus.pending,
                  null,
                ),
                PlaylistEntryAvailability.private => (
                  PlaylistItemStatus.skipped,
                  entry.availabilityReason ?? 'Skipped: private video.',
                ),
                PlaylistEntryAvailability.removed => (
                  PlaylistItemStatus.skipped,
                  entry.availabilityReason ??
                      'Skipped: removed or deleted video.',
                ),
                PlaylistEntryAvailability.unavailable => (
                  PlaylistItemStatus.skipped,
                  entry.availabilityReason ?? 'Skipped: unavailable video.',
                ),
              };
          return PlaylistItemState(
            orderIndex: entry.orderIndex,
            videoId: entry.videoId,
            title: entry.title,
            url: entry.url,
            durationSeconds: entry.durationSeconds,
            thumbnailUrl: entry.thumbnailUrl,
            status: status,
            downloadedBytes: 0,
            isTotalEstimated: false,
            errorMessage: message,
          );
        })
        .toList(growable: false);
  }
}
