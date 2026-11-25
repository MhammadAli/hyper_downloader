import 'package:flutter/material.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/presentation/widgets/common/status_badges.dart';

class PlaylistSizeSummaryCard extends StatelessWidget {
  final PlaylistSizeEstimate estimate;
  final VoidCallback? onCancel;
  final VoidCallback? onRecalculate;

  const PlaylistSizeSummaryCard({
    super.key,
    required this.estimate,
    required this.onCancel,
    required this.onRecalculate,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isCalculating = estimate.status == PlaylistSizeStatus.calculating;
    final canRecalculate =
        estimate.status == PlaylistSizeStatus.canceled ||
        estimate.status == PlaylistSizeStatus.failed;

    final (IconData icon, Color accent, Color bg) = switch (estimate.status) {
      PlaylistSizeStatus.exact => (
        Icons.verified_rounded,
        const Color(0xFF34D399),
        const Color(0xFF103B2C).withValues(alpha: 0.45),
      ),
      PlaylistSizeStatus.estimated => (
        Icons.storage_rounded,
        const Color(0xFF22D3EE),
        const Color(0xFF10344A).withValues(alpha: 0.50),
      ),
      PlaylistSizeStatus.partial => (
        Icons.info_outline_rounded,
        const Color(0xFFFBBF24),
        const Color(0xFF3E2D0F).withValues(alpha: 0.45),
      ),
      PlaylistSizeStatus.failed => (
        Icons.warning_amber_rounded,
        const Color(0xFFFB7185),
        scheme.errorContainer.withValues(alpha: 0.55),
      ),
      PlaylistSizeStatus.calculating => (
        Icons.analytics_outlined,
        scheme.secondary,
        scheme.surfaceContainerLow,
      ),
      PlaylistSizeStatus.idle ||
      PlaylistSizeStatus.unknown ||
      PlaylistSizeStatus.canceled => (
        Icons.help_outline_rounded,
        scheme.onSurfaceVariant,
        scheme.surfaceContainerLow,
      ),
    };

    final double? progressValue =
        isCalculating &&
            estimate.eligibleCount > 0 &&
            estimate.inspectedCount > 0
        ? (estimate.inspectedCount / estimate.eligibleCount).clamp(0.0, 1.0)
        : null;

    return Container(
      key: const Key('playlist_size_summary_card'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isCalculating)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        key: const Key('playlist_size_spinner'),
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  else
                    Icon(icon, size: 18, color: accent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      estimate.displaySummary,
                      key: const Key('playlist_size_summary_text'),
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              if (isCalculating && onCancel != null)
                TextButton.icon(
                  key: const Key('cancel_size_estimation_button'),
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Cancel'),
                )
              else if (canRecalculate && onRecalculate != null)
                TextButton.icon(
                  key: const Key('recalculate_size_button'),
                  onPressed: onRecalculate,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: accent,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Recalculate'),
                ),
            ],
          ),
          if (isCalculating) ...[
            const SizedBox(height: 8),
            if (progressValue == null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  key: const Key('playlist_size_progress_bar'),
                  minHeight: 6,
                  value: null,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              )
            else
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: progressValue),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                builder: (context, animatedValue, _) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      key: const Key('playlist_size_progress_bar'),
                      minHeight: 6,
                      value: animatedValue,
                      backgroundColor: scheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(accent),
                    ),
                  );
                },
              ),
          ],
          if (estimate.statusMessage != null &&
              estimate.statusMessage!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              estimate.statusMessage!,
              key: const Key('playlist_size_status_message'),
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            key: const Key('playlist_size_breakdown'),
            spacing: 8,
            runSpacing: 6,
            children: [
              StatusTag(
                label: '${estimate.eligibleCount} included',
                fg: scheme.onSurface,
                bg: scheme.surfaceContainerHighest,
              ),
              if (estimate.exactCount > 0)
                StatusTag(
                  label: '${estimate.exactCount} exact',
                  fg: const Color(0xFF34D399),
                  bg: const Color(0xFF103B2C),
                ),
              if (estimate.estimatedCount > 0)
                StatusTag(
                  label: '${estimate.estimatedCount} estimated',
                  fg: const Color(0xFF22D3EE),
                  bg: const Color(0xFF10344A),
                ),
              if (estimate.unknownCount > 0)
                StatusTag(
                  label: '${estimate.unknownCount} unknown',
                  fg: const Color(0xFFFBBF24),
                  bg: const Color(0xFF3E2D0F),
                ),
              if (estimate.failedCount > 0)
                StatusTag(
                  label: '${estimate.failedCount} failed',
                  fg: const Color(0xFFFB7185),
                  bg: scheme.errorContainer,
                ),
              if (estimate.unavailableCount > 0)
                StatusTag(
                  label: '${estimate.unavailableCount} skipped',
                  fg: scheme.onSurfaceVariant,
                  bg: scheme.surfaceContainerHighest,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
