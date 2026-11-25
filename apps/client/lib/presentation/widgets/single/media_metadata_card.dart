import 'package:flutter/material.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/presentation/widgets/common/status_badges.dart';

class MediaMetadataCard extends StatelessWidget {
  final MediaInspection inspection;

  const MediaMetadataCard({super.key, required this.inspection});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final thumbnail = Container(
      width: 204,
      height: 115,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: inspection.thumbnailUrl != null
          ? Image.network(
              inspection.thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.movie_outlined,
                size: 40,
                color: scheme.onSurfaceVariant,
              ),
            )
          : Icon(
              Icons.movie_outlined,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          inspection.title,
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
              label: inspection.providerName,
              accent: scheme.secondary,
            ),
            if (inspection.uploader != null)
              MetaBadge(
                icon: Icons.person_outline_rounded,
                label: inspection.uploader!,
                accent: scheme.primary,
              ),
            if (inspection.durationSeconds != null)
              MetaBadge(
                icon: Icons.schedule_rounded,
                label: ByteFormatter.formatDuration(
                  inspection.durationSeconds!.round(),
                ),
                accent: scheme.tertiary,
              ),
          ],
        ),
      ],
    );

    return Card(
      key: const Key('media_metadata_card'),
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
