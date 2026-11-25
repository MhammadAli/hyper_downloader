import 'package:flutter/material.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';

class MetaBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;

  const MetaBadge({
    super.key,
    required this.icon,
    required this.label,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StatusTag extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;

  const StatusTag({
    super.key,
    required this.label,
    required this.fg,
    required this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class PlaylistItemStatusBadge extends StatelessWidget {
  final PlaylistItemStatus status;

  const PlaylistItemStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, fg, bg) = switch (status) {
      PlaylistItemStatus.pending => (
        'Pending',
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
      ),
      PlaylistItemStatus.analyzing => (
        'Analyzing',
        const Color(0xFF22D3EE),
        const Color(0xFF10344A),
      ),
      PlaylistItemStatus.ready => (
        'Ready',
        const Color(0xFF818CF8),
        const Color(0xFF283066),
      ),
      PlaylistItemStatus.downloading => (
        'Downloading',
        const Color(0xFF22D3EE),
        const Color(0xFF10344A),
      ),
      PlaylistItemStatus.merging => (
        'Merging',
        const Color(0xFFC084FC),
        const Color(0xFF2B2250),
      ),
      PlaylistItemStatus.completed => (
        'Completed',
        const Color(0xFF34D399),
        const Color(0xFF103B2C),
      ),
      PlaylistItemStatus.failed => (
        'Failed',
        const Color(0xFFFB7185),
        scheme.errorContainer,
      ),
      PlaylistItemStatus.skipped => (
        'Skipped',
        const Color(0xFFFBBF24),
        const Color(0xFF3E2D0F),
      ),
      PlaylistItemStatus.canceled => (
        'Canceled',
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
      ),
    };

    return StatusTag(label: label, fg: fg, bg: bg);
  }
}
