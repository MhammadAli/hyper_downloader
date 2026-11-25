import 'package:flutter/material.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
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

    final thumbnail = Container(
      width: 204,
      height: 115,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: playlist.thumbnailUrl != null
          ? Image.network(
              playlist.thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.playlist_play_rounded,
                size: 42,
                color: scheme.onSurfaceVariant,
              ),
            )
          : Icon(
              Icons.playlist_play_rounded,
              size: 42,
              color: scheme.onSurfaceVariant,
            ),
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          playlist.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
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
        ),
        if (outputDir != null && outputDir.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
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
          ),
        ],
      ],
    );

    return Card(
      key: const Key('playlist_header_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 540) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [thumbnail, const SizedBox(height: 12), details],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                thumbnail,
                const SizedBox(width: 16),
                Expanded(child: details),
              ],
            );
          },
        ),
      ),
    );
  }
}
