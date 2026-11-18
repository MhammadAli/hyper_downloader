import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/desktop_file_launcher.dart';
import 'package:hyper_download_client/features/media_download/media_download_cubit.dart';
import 'package:hyper_download_client/features/media_download/media_download_state.dart';

/// Polished Phase 2C desktop interface:
/// Paste URL -> Analyze -> Choose Quality -> Download / Pause / Resume / Open Folder.
class MediaDownloadScreen extends StatefulWidget {
  final DesktopFileLauncher fileLauncher;

  const MediaDownloadScreen({
    super.key,
    this.fileLauncher = const WindowsDesktopFileLauncher(),
  });

  @override
  State<MediaDownloadScreen> createState() => _MediaDownloadScreenState();
}

class _MediaDownloadScreenState extends State<MediaDownloadScreen> {
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!context.mounted || text == null || text.isEmpty) {
      return;
    }
    _urlController.text = text;
    _urlController.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
    context.read<MediaDownloadCubit>().updateUrl(text);
  }

  void _clearUrl(BuildContext context) {
    _urlController.clear();
    context.read<MediaDownloadCubit>().updateUrl('');
  }

  Future<void> _openFile(BuildContext context, String path) async {
    final opened = await widget.fileLauncher.openFile(path);
    if (!context.mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open file. Check if it still exists on disk.'),
      ),
    );
  }

  Future<void> _revealInFolder(BuildContext context, String path) async {
    final opened = await widget.fileLauncher.revealInFolder(path);
    if (!context.mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not open folder. Check if the path still exists on disk.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        scrolledUnderElevation: 1,
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                Icons.downloading_rounded,
                size: 20,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'HyperDownload',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Video & Audio Downloader',
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: BlocBuilder<MediaDownloadCubit, MediaDownloadState>(
        builder: (context, state) {
          if (_urlController.text != state.urlInput &&
              state.urlInput.isNotEmpty &&
              _urlController.text.isEmpty) {
            _urlController.text = state.urlInput;
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (state.engineError != null) ...[
                      _ErrorBanner(message: state.engineError!),
                      const SizedBox(height: 16),
                    ],
                    _UrlInputCard(
                      controller: _urlController,
                      hasUrlText: state.urlInput.isNotEmpty,
                      isAnalyzing:
                          state.inspectionStatus == InspectionStatus.loading,
                      onUrlChanged: (val) =>
                          context.read<MediaDownloadCubit>().updateUrl(val),
                      onClear: () => _clearUrl(context),
                      onPaste: () => _pasteFromClipboard(context),
                      onAnalyze: () => context
                          .read<MediaDownloadCubit>()
                          .analyzeUrl(_urlController.text),
                    ),
                    if (state.inspectionError != null ||
                        state.downloadError != null) ...[
                      const SizedBox(height: 16),
                      _ErrorBanner(
                        message:
                            (state.downloadError ?? state.inspectionError)!,
                      ),
                    ],
                    if (state.inspection != null) ...[
                      const SizedBox(height: 16),
                      _MediaMetadataCard(inspection: state.inspection!),
                      const SizedBox(height: 16),
                      _QualitySelectionCard(state: state),
                    ],
                    if (state.inspection != null ||
                        state.latestProgress != null ||
                        state.activeJobId != null) ...[
                      const SizedBox(height: 16),
                      _DownloadControlsCard(
                        state: state,
                        onOpenFile: (path) => _openFile(context, path),
                        onRevealInFolder: (path) =>
                            _revealInFolder(context, path),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _UrlInputCard extends StatelessWidget {
  final TextEditingController controller;
  final bool hasUrlText;
  final bool isAnalyzing;
  final ValueChanged<String> onUrlChanged;
  final VoidCallback onClear;
  final VoidCallback onPaste;
  final VoidCallback onAnalyze;

  const _UrlInputCard({
    required this.controller,
    required this.hasUrlText,
    required this.isAnalyzing,
    required this.onUrlChanged,
    required this.onClear,
    required this.onPaste,
    required this.onAnalyze,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final textField = TextField(
              key: const Key('url_input_field'),
              controller: controller,
              enabled: !isAnalyzing,
              onChanged: onUrlChanged,
              onSubmitted: (_) => onAnalyze(),
              decoration: InputDecoration(
                labelText: 'Paste video or Shorts link',
                hintText: 'https://www.youtube.com/watch?v=...',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: hasUrlText && !isAnalyzing
                    ? IconButton(
                        tooltip: 'Clear URL',
                        onPressed: onClear,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      )
                    : null,
              ),
            );

            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('paste_url_button'),
                  onPressed: isAnalyzing ? null : onPaste,
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('Paste'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  key: const Key('analyze_url_button'),
                  onPressed: isAnalyzing ? null : onAnalyze,
                  icon: isAnalyzing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search_rounded, size: 18),
                  label: Text(isAnalyzing ? 'Analyzing...' : 'Analyze'),
                ),
              ],
            );

            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  textField,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: textField),
                const SizedBox(width: 12),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('error_banner'),
      color: scheme.errorContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.error.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaMetadataCard extends StatelessWidget {
  final MediaInspection inspection;

  const _MediaMetadataCard({required this.inspection});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final thumbnail = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 200,
        height: 112,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: inspection.thumbnailUrl != null
            ? Image.network(
                inspection.thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.movie_outlined, size: 40),
              )
            : const Icon(Icons.movie_outlined, size: 40),
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
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _MetaItem(
              icon: Icons.public_rounded,
              label: inspection.providerName,
            ),
            if (inspection.uploader != null)
              _MetaItem(
                icon: Icons.person_outline_rounded,
                label: inspection.uploader!,
              ),
            if (inspection.durationSeconds != null)
              _MetaItem(
                icon: Icons.schedule_rounded,
                label: _formatDuration(inspection.durationSeconds!.round()),
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

class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetaItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _QualitySelectionCard extends StatelessWidget {
  final MediaDownloadState state;

  const _QualitySelectionCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MediaDownloadCubit>();
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
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
                ),
              ],
            ),
            if (state.originalAudio != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.volume_up_outlined,
                    size: 16,
                    color: scheme.primary,
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
            if (state.mediaMode == DownloadMediaMode.videoWithSound)
              _VideoQualityList(
                options: state.videoOptions,
                selectedVideoFormatId: state.selectedVideoFormatId,
                onSelect: cubit.selectVideoQuality,
              )
            else
              _AudioQualityList(
                options: state.audioOptions,
                selectedFormatId: state.selectedAudioOptionFormatId,
                onSelect: cubit.selectAudioQuality,
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
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final opt = options[index];
        final isSelected = opt.videoFormatId == selectedVideoFormatId;
        final scheme = Theme.of(context).colorScheme;

        return Material(
          color: isSelected
              ? scheme.primaryContainer.withValues(alpha: 0.42)
              : scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: isSelected ? scheme.primary : scheme.outlineVariant,
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: InkWell(
            key: Key('video_quality_card_${opt.resolution}'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSelect(opt.videoFormatId),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final titleAndTags = Wrap(
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
                  );
                  final sizeText = Text(
                    opt.displaySize,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  );

                  if (constraints.maxWidth < 380) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          isSelected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: isSelected ? scheme.primary : scheme.outline,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              titleAndTags,
                              const SizedBox(height: 6),
                              sizeText,
                            ],
                          ),
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Icon(
                        isSelected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: isSelected ? scheme.primary : scheme.outline,
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: titleAndTags),
                      const SizedBox(width: 12),
                      sizeText,
                    ],
                  );
                },
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
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final opt = options[index];
        final isSelected = opt.formatId == selectedFormatId;
        final scheme = Theme.of(context).colorScheme;

        return Material(
          color: isSelected
              ? scheme.primaryContainer.withValues(alpha: 0.42)
              : scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: isSelected ? scheme.primary : scheme.outlineVariant,
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: InkWell(
            key: Key('audio_quality_card_$index'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSelect(opt.formatId),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final titleAndTags = Wrap(
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
                  );
                  final sizeText = Text(
                    opt.displaySize,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  );

                  if (constraints.maxWidth < 380) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          isSelected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: isSelected ? scheme.primary : scheme.outline,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              titleAndTags,
                              const SizedBox(height: 6),
                              sizeText,
                            ],
                          ),
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Icon(
                        isSelected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: isSelected ? scheme.primary : scheme.outline,
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: titleAndTags),
                      const SizedBox(width: 12),
                      sizeText,
                    ],
                  );
                },
              ),
            ),
          ),
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

class _DownloadControlsCard extends StatelessWidget {
  final MediaDownloadState state;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const _DownloadControlsCard({
    required this.state,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MediaDownloadCubit>();
    final progress = state.latestProgress;
    final phase =
        progress?.phase ??
        (state.isStartingDownload ? DownloadPhase.analyzing : null);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    double? fraction;
    if (progress != null) {
      if (progress.phase == DownloadPhase.completed) {
        fraction = 1.0;
      } else if (progress.totalBytes != null &&
          progress.totalBytes! > BigInt.zero) {
        fraction =
            (progress.downloadedBytes.toDouble() /
                    progress.totalBytes!.toDouble())
                .clamp(0.0, 1.0);
      }
    }

    final outputPath = progress?.outputPath;
    final isCompleted =
        phase == DownloadPhase.completed &&
        outputPath != null &&
        outputPath.isNotEmpty;

    return Card(
      key: const Key('download_controls_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Download Transfer',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (phase != null)
                  _PhaseBadge(
                    label: _resolvePhaseLabel(phase, isPaused: state.isPaused),
                    phase: phase,
                    isPaused: state.isPaused,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const Key('start_download_button'),
                  onPressed: state.canStartDownload
                      ? cubit.startDownload
                      : null,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(isCompleted ? 'Download Again' : 'Download'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('pause_download_button'),
                  onPressed: state.canPause ? cubit.pauseDownload : null,
                  icon: const Icon(Icons.pause_rounded, size: 18),
                  label: const Text('Pause'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('resume_download_button'),
                  onPressed: state.canResume ? cubit.resumeDownload : null,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Resume'),
                ),
                OutlinedButton.icon(
                  key: const Key('cancel_download_button'),
                  onPressed: state.canCancel ? cubit.cancelDownload : null,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Cancel'),
                ),
              ],
            ),
            if (progress != null || state.isStartingDownload) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        key: const Key('download_progress_bar'),
                        minHeight: 8,
                        value: fraction,
                      ),
                    ),
                  ),
                  if (fraction != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      '${(fraction * 100).round()}%',
                      key: const Key('progress_percent_text'),
                      style: textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  Text(
                    'Transferred: ${_formatProgressBytes(progress)}',
                    key: const Key('progress_bytes_text'),
                  ),
                  Text(
                    'Speed: ${_formatSpeed(progress?.speedBytesPerSec)}',
                    key: const Key('progress_speed_text'),
                  ),
                  Text(
                    'ETA: ${_formatEta(progress?.etaSeconds)}',
                    key: const Key('progress_eta_text'),
                  ),
                ],
              ),
              if (progress?.message != null && !isCompleted) ...[
                const SizedBox(height: 8),
                Text(
                  progress!.message!,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (isCompleted) ...[
                const SizedBox(height: 14),
                Container(
                  key: const Key('completed_file_panel'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: scheme.secondary.withValues(alpha: 0.35),
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final fileInfo = Row(
                        children: [
                          Icon(
                            Icons.task_alt_rounded,
                            color: scheme.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _fileBaseName(outputPath),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  outputPath,
                                  key: const Key('output_path_text'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );

                      final folderActions = Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            key: const Key('open_folder_button'),
                            onPressed: () => onRevealInFolder(outputPath),
                            icon: const Icon(
                              Icons.folder_open_outlined,
                              size: 18,
                            ),
                            label: const Text('Show in Folder'),
                          ),
                          FilledButton.tonalIcon(
                            key: const Key('open_file_button'),
                            onPressed: () => onOpenFile(outputPath),
                            icon: const Icon(
                              Icons.play_circle_outline_rounded,
                              size: 18,
                            ),
                            label: const Text('Open File'),
                          ),
                        ],
                      );

                      if (constraints.maxWidth < 600) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            fileInfo,
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerRight,
                              child: folderActions,
                            ),
                          ],
                        );
                      }

                      return Row(
                        children: [
                          Expanded(child: fileInfo),
                          const SizedBox(width: 12),
                          folderActions,
                        ],
                      );
                    },
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  final String label;
  final DownloadPhase phase;
  final bool isPaused;

  const _PhaseBadge({
    required this.label,
    required this.phase,
    required this.isPaused,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;

    if (isPaused) {
      bg = scheme.tertiaryContainer;
      fg = scheme.onTertiaryContainer;
    } else {
      switch (phase) {
        case DownloadPhase.completed:
          bg = scheme.primaryContainer;
          fg = scheme.onPrimaryContainer;
        case DownloadPhase.failed:
          bg = scheme.errorContainer;
          fg = scheme.onErrorContainer;
        case DownloadPhase.canceled:
          bg = scheme.surfaceContainerHighest;
          fg = scheme.onSurfaceVariant;
        case DownloadPhase.analyzing:
        case DownloadPhase.downloading:
        case DownloadPhase.merging:
          bg = scheme.secondaryContainer;
          fg = scheme.onSecondaryContainer;
      }
    }

    return Container(
      key: const Key('download_phase_chip'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _fileBaseName(String fullPath) {
  final sep = Platform.pathSeparator;
  final normalized = fullPath.replaceAll('/', sep).replaceAll('\\', sep);
  final parts = normalized.split(sep);
  return parts.isNotEmpty && parts.last.isNotEmpty ? parts.last : fullPath;
}

String _formatDuration(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

String _formatBytes(BigInt bytes) {
  final value = bytes.toDouble();
  if (value < 1024) return '${bytes.toInt()} B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _formatProgressBytes(DownloadProgressEvent? progress) {
  if (progress == null) return '0 B';
  final down = _formatBytes(progress.downloadedBytes);
  final total = progress.totalBytes;
  if (total == null) return down;
  final prefix = progress.isTotalEstimated ? '~' : '';
  return '$down / $prefix${_formatBytes(total)}';
}

String _formatSpeed(double? speedBytesPerSec) {
  if (speedBytesPerSec == null || speedBytesPerSec <= 0) return '--';
  if (speedBytesPerSec < 1024) {
    return '${speedBytesPerSec.toStringAsFixed(0)} B/s';
  }
  if (speedBytesPerSec < 1024 * 1024) {
    return '${(speedBytesPerSec / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(speedBytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MB/s';
}

String _formatEta(BigInt? etaSeconds) {
  if (etaSeconds == null) return '--';
  return _formatDuration(etaSeconds.toInt());
}

String _resolvePhaseLabel(DownloadPhase phase, {required bool isPaused}) {
  if (isPaused && phase == DownloadPhase.canceled) {
    return 'Paused';
  }
  return switch (phase) {
    DownloadPhase.analyzing => 'Analyzing',
    DownloadPhase.downloading => 'Downloading',
    DownloadPhase.merging => 'Merging',
    DownloadPhase.completed => 'Completed',
    DownloadPhase.canceled => 'Canceled',
    DownloadPhase.failed => 'Failed',
  };
}
