import 'package:flutter/material.dart';

/// Finite slide-and-fade entrance animation safe for desktop and automated tests.
class AnimatedEntrance extends StatelessWidget {
  final Widget child;

  const AnimatedEntrance({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, childWidget) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1.0 - value) * 10.0),
            child: childWidget,
          ),
        );
      },
      child: child,
    );
  }
}

/// Smoothly expands/collapses an optional section with entrance animation.
class AnimatedCollapsibleSection extends StatelessWidget {
  final bool visible;
  final Widget child;
  final Key? entranceKey;
  final double topSpacing;
  final Duration duration;

  const AnimatedCollapsibleSection({
    super.key,
    required this.visible,
    required this.child,
    this.entranceKey,
    this.topSpacing = 16,
    this.duration = const Duration(milliseconds: 260),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: duration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: visible
          ? Padding(
              padding: EdgeInsets.only(top: topSpacing),
              child: AnimatedEntrance(key: entranceKey, child: child),
            )
          : const SizedBox.shrink(),
    );
  }
}
