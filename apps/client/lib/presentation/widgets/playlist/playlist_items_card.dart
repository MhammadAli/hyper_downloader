import 'package:flutter/material.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/presentation/widgets/common/status_badges.dart';

class PlaylistItemsCard extends StatelessWidget {
  final List<PlaylistItemState> items;
  final PlaylistSizeEstimate? sizeEstimate;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const PlaylistItemsCard({
    super.key,
    required this.items,
    required this.sizeEstimate,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final sizeByOrder = <int, PlaylistItemSizeInfo>{
      for (final info in sizeEstimate?.itemSizes ?? const [])
        info.orderIndex: info,
    };

    return Card(
      key: const Key('playlist_items_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Playlist Items (${items.length})',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Text(
                'No playlist entries were returned.',
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 460),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _PlaylistItemRow(
                      item: item,
                      sizeInfo: sizeByOrder[item.orderIndex],
                      onOpenFile: onOpenFile,
                      onRevealInFolder: onRevealInFolder,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistItemRow extends StatelessWidget {
  final PlaylistItemState item;
  final PlaylistItemSizeInfo? sizeInfo;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const _PlaylistItemRow({
    required this.item,
    this.sizeInfo,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final numberLabel = (item.orderIndex + 1).toString().padLeft(3, '0');
    final isCompleted =
        item.status == PlaylistItemStatus.completed && item.outputPath != null;
    final showNote =
        item.errorMessage != null &&
        item.errorMessage!.isNotEmpty &&
        (item.status == PlaylistItemStatus.failed ||
            item.status == PlaylistItemStatus.skipped ||
            item.status == PlaylistItemStatus.canceled);

    return Container(
      key: Key('playlist_item_${item.orderIndex}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 500;
          final leadingAndInfo = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  numberLabel,
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.secondary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        if (item.durationSeconds != null)
                          Text(
                            ByteFormatter.formatDuration(
                              item.durationSeconds!.round(),
                            ),
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if ((item.selectedQuality ??
                                sizeInfo?.selectedQuality) !=
                            null)
                          Text(
                            item.selectedQuality ?? sizeInfo!.selectedQuality!,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.secondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (sizeInfo != null)
                          Text(
                            sizeInfo!.displaySize,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if (item.audioLanguage?.languageDisplayName != null)
                          Text(
                            item.audioLanguage!.languageDisplayName!,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    if (showNote) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.errorMessage!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: item.status == PlaylistItemStatus.failed
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );

          final trailingControls = Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PlaylistItemStatusBadge(status: item.status),
              if (isCompleted) ...[
                IconButton(
                  key: Key('playlist_item_open_${item.orderIndex}'),
                  tooltip: 'Open File',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onOpenFile(item.outputPath!),
                  icon: const Icon(Icons.play_circle_outline_rounded, size: 20),
                ),
                IconButton(
                  key: Key('playlist_item_folder_${item.orderIndex}'),
                  tooltip: 'Show in Folder',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onRevealInFolder(item.outputPath!),
                  icon: const Icon(Icons.folder_open_rounded, size: 20),
                ),
              ],
            ],
          );

          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leadingAndInfo,
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: trailingControls,
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: leadingAndInfo),
              const SizedBox(width: 12),
              trailingControls,
            ],
          );
        },
      ),
    );
  }
}
