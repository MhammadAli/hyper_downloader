import 'package:flutter/material.dart';

/// Consistent rounded surface card shell used across inspector, single, and playlist cards.
class SectionCard extends StatelessWidget {
  final Key? cardKey;
  final EdgeInsetsGeometry padding;
  final Widget child;

  const SectionCard({
    super.key,
    this.cardKey,
    this.padding = const EdgeInsets.all(16),
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      key: cardKey,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Shared adaptive thumbnail + title + metadata badges + optional footer summary card.
class MediaSummaryCard extends StatelessWidget {
  final Key? cardKey;
  final String title;
  final String? thumbnailUrl;
  final IconData fallbackIcon;
  final double fallbackIconSize;
  final List<Widget> badges;
  final Widget? footer;

  const MediaSummaryCard({
    super.key,
    this.cardKey,
    required this.title,
    this.thumbnailUrl,
    required this.fallbackIcon,
    this.fallbackIconSize = 40,
    required this.badges,
    this.footer,
  });

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
      child: thumbnailUrl != null
          ? Image.network(
              thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                fallbackIcon,
                size: fallbackIconSize,
                color: scheme.onSurfaceVariant,
              ),
            )
          : Icon(
              fallbackIcon,
              size: fallbackIconSize,
              color: scheme.onSurfaceVariant,
            ),
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
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
          children: badges,
        ),
        if (footer != null) ...[const SizedBox(height: 12), footer!],
      ],
    );

    return SectionCard(
      cardKey: cardKey,
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
    );
  }
}
