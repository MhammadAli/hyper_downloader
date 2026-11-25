import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_state.dart';

class QualitySelectionCard extends StatelessWidget {
  final SingleDownloadState state;

  const QualitySelectionCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SingleDownloadCubit>();
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('quality_selection_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                Text(
                  'Choose Quality',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (state.audioOptions.isNotEmpty)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<DownloadMediaMode>(
                      key: const Key('media_mode_toggle'),
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: const [
                        ButtonSegment<DownloadMediaMode>(
                          value: DownloadMediaMode.videoWithSound,
                          icon: Icon(Icons.movie_creation_outlined, size: 18),
                          label: Text('Video with Sound'),
                        ),
                        ButtonSegment<DownloadMediaMode>(
                          value: DownloadMediaMode.audioOnly,
                          icon: Icon(Icons.audiotrack_outlined, size: 18),
                          label: Text('Audio Only'),
                        ),
                      ],
                      selected: {state.mediaMode},
                      onSelectionChanged: (selected) {
                        if (selected.isNotEmpty) {
                          cubit.setMediaMode(selected.first);
                        }
                      },
                    ),
                  )
                else
                  Chip(
                    key: const Key('video_only_mode_badge'),
                    avatar: Icon(
                      Icons.movie_creation_outlined,
                      size: 18,
                      color: scheme.secondary,
                    ),
                    label: const Text('Video with Sound'),
                  ),
              ],
            ),
            if (state.originalAudio != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 16,
                    color: scheme.secondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.originalAudio!.statusNote,
                      key: const Key('audio_policy_note'),
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.03),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: state.mediaMode == DownloadMediaMode.videoWithSound
                  ? _VideoQualityList(
                      key: const ValueKey('mode_video'),
                      options: state.videoOptions,
                      selectedVideoFormatId: state.selectedVideoFormatId,
                      onSelect: cubit.selectVideoQuality,
                    )
                  : _AudioQualityList(
                      key: const ValueKey('mode_audio'),
                      options: state.audioOptions,
                      selectedFormatId: state.selectedAudioOptionFormatId,
                      onSelect: cubit.selectAudioQuality,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoQualityList extends StatelessWidget {
  final List<VideoQualityOption> options;
  final String? selectedVideoFormatId;
  final ValueChanged<String> onSelect;

  const _VideoQualityList({
    super.key,
    required this.options,
    required this.selectedVideoFormatId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No playable Video with Sound options were discovered (audio track unavailable).',
          key: Key('empty_video_options_message'),
        ),
      );
    }

    return ListView.separated(
      key: const Key('video_quality_list'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final opt = options[index];
        final isSelected = opt.videoFormatId == selectedVideoFormatId;
        final scheme = Theme.of(context).colorScheme;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            gradient: isSelected
                ? LinearGradient(
                    colors: [
                      const Color(0xFF6366F1).withValues(alpha: 0.22),
                      const Color(0xFF06B6D4).withValues(alpha: 0.14),
                    ],
                  )
                : null,
            color: isSelected ? null : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? scheme.primary : scheme.outlineVariant,
              width: isSelected ? 1.7 : 1.0,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('video_quality_card_${opt.resolution}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelect(opt.videoFormatId),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: _QualityCardRow(
                  isSelected: isSelected,
                  titleAndTags: Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        opt.resolution,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (opt.fps != null)
                        _QualityTag(label: '${opt.fps!.round()} fps'),
                      _QualityTag(
                        label: opt.container.toUpperCase(),
                        highlight: true,
                      ),
                    ],
                  ),
                  displaySize: opt.displaySize,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AudioQualityList extends StatelessWidget {
  final List<AudioQualityOption> options;
  final String? selectedFormatId;
  final ValueChanged<String> onSelect;

  const _AudioQualityList({
    super.key,
    required this.options,
    required this.selectedFormatId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No downloadable Audio Only streams were discovered for this media.',
          key: Key('empty_audio_options_message'),
        ),
      );
    }

    return ListView.separated(
      key: const Key('audio_quality_list'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final opt = options[index];
        final isSelected = opt.formatId == selectedFormatId;
        final scheme = Theme.of(context).colorScheme;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            gradient: isSelected
                ? LinearGradient(
                    colors: [
                      const Color(0xFF6366F1).withValues(alpha: 0.22),
                      const Color(0xFF06B6D4).withValues(alpha: 0.14),
                    ],
                  )
                : null,
            color: isSelected ? null : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? scheme.primary : scheme.outlineVariant,
              width: isSelected ? 1.7 : 1.0,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('audio_quality_card_$index'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelect(opt.formatId),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: _QualityCardRow(
                  isSelected: isSelected,
                  titleAndTags: Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        opt.qualityLabel,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      _QualityTag(
                        label: opt.container.toUpperCase(),
                        highlight: true,
                      ),
                    ],
                  ),
                  displaySize: opt.displaySize,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QualityCardRow extends StatelessWidget {
  final bool isSelected;
  final Widget titleAndTags;
  final String displaySize;

  const _QualityCardRow({
    required this.isSelected,
    required this.titleAndTags,
    required this.displaySize,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final indicator = AnimatedScale(
          scale: isSelected ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 180),
          child: Icon(
            isSelected
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: isSelected ? scheme.secondary : scheme.outline,
          ),
        );
        final sizeText = Text(
          displaySize,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isSelected ? scheme.secondary : scheme.onSurfaceVariant,
          ),
        );

        if (constraints.maxWidth < 380) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              indicator,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [titleAndTags, const SizedBox(height: 6), sizeText],
                ),
              ),
            ],
          );
        }

        return Row(
          children: [
            indicator,
            const SizedBox(width: 14),
            Expanded(child: titleAndTags),
            const SizedBox(width: 12),
            sizeText,
          ],
        );
      },
    );
  }
}

class _QualityTag extends StatelessWidget {
  final String label;
  final bool highlight;

  const _QualityTag({required this.label, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: highlight ? scheme.onSecondaryContainer : scheme.onSurface,
        ),
      ),
    );
  }
}
