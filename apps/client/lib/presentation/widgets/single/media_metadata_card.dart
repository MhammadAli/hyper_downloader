import 'package:flutter/material.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/presentation/widgets/common/section_card.dart';
import 'package:hyper_download_client/presentation/widgets/common/status_badges.dart';

class MediaMetadataCard extends StatelessWidget {
  final MediaInspection inspection;

  const MediaMetadataCard({super.key, required this.inspection});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return MediaSummaryCard(
      cardKey: const Key('media_metadata_card'),
      title: inspection.title,
      thumbnailUrl: inspection.thumbnailUrl,
      fallbackIcon: Icons.movie_outlined,
      badges: [
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
    );
  }
}
