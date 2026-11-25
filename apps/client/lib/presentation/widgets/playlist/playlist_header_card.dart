import 'package:flutter/material.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/presentation/widgets/common/section_card.dart';
import 'package:hyper_download_client/presentation/widgets/common/status_badges.dart';

class PlaylistHeaderCard extends StatelessWidget {
  final PlaylistInspection playlist;
  final PlaylistSessionSnapshot? session;
  final ValueChanged<String> onRevealInFolder;

  const PlaylistHeaderCard({
    super.key,
    required this.playlist,
    required this.session,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final unavailableCount = playlist.entries
        .where((e) => e.availability != PlaylistEntryAvailability.available)
        .length;
    final outputDir = session?.outputDirectory;

    return MediaSummaryCard(
      cardKey: const Key('playlist_header_card'),
      title: playlist.title,
      thumbnailUrl: playlist.thumbnailUrl,
      fallbackIcon: Icons.playlist_play_rounded,
      fallbackIconSize: 42,
      badges: [
        MetaBadge(
          icon: Icons.public_rounded,
          label: playlist.providerName,
          accent: scheme.secondary,
        ),
        if (playlist.uploader != null)
          MetaBadge(
            icon: Icons.person_outline_rounded,
            label: playlist.uploader!,
            accent: scheme.primary,
          ),
        MetaBadge(
          icon: Icons.format_list_numbered_rounded,
          label: '${playlist.totalItemCount} items',
          accent: scheme.tertiary,
        ),
        if (unavailableCount > 0)
          MetaBadge(
            icon: Icons.block_outlined,
            label: '$unavailableCount unavailable',
            accent: const Color(0xFFFBBF24),
          ),
      ],
      footer: (outputDir != null && outputDir.isNotEmpty)
          ? Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('playlist_open_folder_button'),
                  onPressed: () => onRevealInFolder(outputDir),
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Open Folder'),
                ),
                Text(
                  ByteFormatter.folderTail(outputDir),
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          : null,
    );
  }
}
