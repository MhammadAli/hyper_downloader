import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/media_download_cubit.dart';
import 'package:hyper_download_client/features/media_download/media_download_state.dart';

/// Main interactive workspace providing an IDM-like simplified quality chooser
/// ("Video with Sound" default + "Audio Only") backed by Rust `yt-dlp` and FFmpeg.
class MediaDownloadScreen extends StatefulWidget {
  const MediaDownloadScreen({super.key});

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HyperDownload'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: BlocSelector<MediaDownloadCubit, MediaDownloadState, String>(
              selector: (state) => state.engineStatus,
              builder: (context, engineStatus) {
                return Chip(
                  key: const Key('engine_status_chip'),
                  avatar: const Icon(Icons.memory, size: 16),
                  label: Text('Rust: $engineStatus'),
                );
              },
            ),
          ),
        ],
      ),
      body: BlocBuilder<MediaDownloadCubit, MediaDownloadState>(
        builder: (context, state) {
          if (_urlController.text != state.urlInput &&
              state.urlInput.isNotEmpty &&
              _urlController.text.isEmpty) {
            _urlController.text = state.urlInput;
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _UrlInputCard(
                      controller: _urlController,
                      isAnalyzing:
                          state.inspectionStatus == InspectionStatus.loading,
                      onUrlChanged: (val) =>
                          context.read<MediaDownloadCubit>().updateUrl(val),
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
                      _DownloadControlsCard(state: state),
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
  final bool isAnalyzing;
  final ValueChanged<String> onUrlChanged;
  final VoidCallback onPaste;
  final VoidCallback onAnalyze;

  const _UrlInputCard({
    required this.controller,
    required this.isAnalyzing,
    required this.onUrlChanged,
    required this.onPaste,
    required this.onAnalyze,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Media URL Analysis',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('url_input_field'),
                    controller: controller,
                    enabled: !isAnalyzing,
                    onChanged: onUrlChanged,
                    onSubmitted: (_) => onAnalyze(),
                    decoration: const InputDecoration(
                      labelText: 'Video or Media URL',
                      hintText: 'https://www.youtube.com/watch?v=...',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  key: const Key('paste_url_button'),
                  onPressed: isAnalyzing ? null : onPaste,
                  icon: const Icon(Icons.content_paste),
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
                      : const Icon(Icons.search),
                  label: Text(isAnalyzing ? 'Analyzing...' : 'Analyze'),
                ),
              ],
            ),
          ],
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
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
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
    final thumbnail = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 192,
        height: 108,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
        Text(inspection.title, style: textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(
              avatar: const Icon(Icons.public, size: 16),
              label: Text(inspection.providerName),
            ),
            if (inspection.uploader != null)
              Chip(
                avatar: const Icon(Icons.person_outline, size: 16),
                label: Text(inspection.uploader!),
              ),
            if (inspection.durationSeconds != null)
              Chip(
                avatar: const Icon(Icons.schedule, size: 16),
                label: Text(
                  _formatDuration(inspection.durationSeconds!.round()),
                ),
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
            if (constraints.maxWidth < 520) {
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
                Text('Download Quality', style: textTheme.titleMedium),
                SegmentedButton<DownloadMediaMode>(
                  key: const Key('media_mode_toggle'),
                  segments: const [
                    ButtonSegment<DownloadMediaMode>(
                      value: DownloadMediaMode.videoWithSound,
                      icon: Icon(Icons.movie_creation_outlined),
                      label: Text('Video with Sound'),
                    ),
                    ButtonSegment<DownloadMediaMode>(
                      value: DownloadMediaMode.audioOnly,
                      icon: Icon(Icons.audiotrack_outlined),
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
            const SizedBox(height: 12),
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

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.separated(
        key: const Key('video_quality_list'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: options.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final opt = options[index];
          final isSelected = opt.videoFormatId == selectedVideoFormatId;
          final scheme = Theme.of(context).colorScheme;

          return InkWell(
            key: Key('video_quality_card_${opt.resolution}'),
            onTap: () => onSelect(opt.videoFormatId),
            child: Container(
              color: isSelected
                  ? scheme.primaryContainer.withValues(alpha: 0.35)
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          opt.resolution,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (opt.fps != null)
                          Text(
                            '${opt.fps!.round()} fps',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            opt.container.toUpperCase(),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    opt.displaySize,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          );
        },
      ),
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

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.separated(
        key: const Key('audio_quality_list'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: options.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final opt = options[index];
          final isSelected = opt.formatId == selectedFormatId;
          final scheme = Theme.of(context).colorScheme;

          return InkWell(
            key: Key('audio_quality_card_$index'),
            onTap: () => onSelect(opt.formatId),
            child: Container(
              color: isSelected
                  ? scheme.primaryContainer.withValues(alpha: 0.35)
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          opt.qualityLabel,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            opt.container.toUpperCase(),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    opt.displaySize,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DownloadControlsCard extends StatelessWidget {
  final MediaDownloadState state;

  const _DownloadControlsCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MediaDownloadCubit>();
    final progress = state.latestProgress;
    final phase =
        progress?.phase ??
        (state.isStartingDownload ? DownloadPhase.analyzing : null);

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
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (phase != null)
                  Chip(
                    key: const Key('download_phase_chip'),
                    label: Text(_phaseLabel(phase)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  key: const Key('start_download_button'),
                  onPressed: state.canStartDownload
                      ? cubit.startDownload
                      : null,
                  icon: const Icon(Icons.download),
                  label: const Text('Download'),
                ),
                OutlinedButton.icon(
                  key: const Key('cancel_download_button'),
                  onPressed: state.canCancel ? cubit.cancelDownload : null,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel'),
                ),
                OutlinedButton.icon(
                  key: const Key('resume_download_button'),
                  onPressed: state.canResume ? cubit.resumeDownload : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
              ],
            ),
            if (progress != null || state.isStartingDownload) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                key: const Key('download_progress_bar'),
                value: fraction,
              ),
              const SizedBox(height: 10),
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
              if (progress?.message != null) ...[
                const SizedBox(height: 8),
                Text(
                  progress!.message!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (progress?.outputPath != null) ...[
                const SizedBox(height: 4),
                SelectableText(
                  'File: ${progress!.outputPath!}',
                  key: const Key('output_path_text'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
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

String _phaseLabel(DownloadPhase phase) {
  return switch (phase) {
    DownloadPhase.analyzing => 'Analyzing',
    DownloadPhase.downloading => 'Downloading',
    DownloadPhase.merging => 'Merging',
    DownloadPhase.completed => 'Completed',
    DownloadPhase.canceled => 'Canceled',
    DownloadPhase.failed => 'Failed',
  };
}
