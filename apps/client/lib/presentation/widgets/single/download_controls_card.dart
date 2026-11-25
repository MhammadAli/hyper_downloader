import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/download_entities.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_state.dart';
import 'package:hyper_download_client/presentation/widgets/common/animated_entrance.dart';
import 'package:hyper_download_client/presentation/widgets/common/section_card.dart';

class DownloadControlsCard extends StatelessWidget {
  final SingleDownloadState state;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const DownloadControlsCard({
    super.key,
    required this.state,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SingleDownloadCubit>();
    final progress = state.latestProgress;
    final isPreparingInitial = state.isPreparingDownload;
    final phase =
        progress?.phase ??
        (isPreparingInitial ? DownloadPhase.analyzing : null);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    double? fraction;
    if (progress != null) {
      if (progress.phase == DownloadPhase.completed) {
        fraction = 1.0;
      } else if (progress.totalBytes != null && progress.totalBytes! > 0) {
        fraction = (progress.downloadedBytes / progress.totalBytes!).clamp(
          0.0,
          1.0,
        );
      }
    }

    final outputPath = progress?.outputPath;
    final isCompleted =
        phase == DownloadPhase.completed &&
        outputPath != null &&
        outputPath.isNotEmpty;
    final phaseLabel = phase == null
        ? null
        : _resolvePhaseLabel(
            phase,
            isPaused: state.isPaused,
            message: progress?.message,
            downloadedBytes: progress?.downloadedBytes,
          );
    final statusMessage =
        progress?.message ??
        (isPreparingInitial ? 'Preparing download...' : null);

    return SectionCard(
      cardKey: const Key('download_controls_card'),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Download Transfer',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (phase != null && phaseLabel != null)
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _PhaseBadge(
                      key: ValueKey(
                        '${phase.name}_${state.isPaused}_$phaseLabel',
                      ),
                      label: phaseLabel,
                      phase: phase,
                      isPaused: state.isPaused,
                    ),
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
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                  ),
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
            if (progress != null || isPreparingInitial) ...[
              const SizedBox(height: 16),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: fraction ?? 0.0),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                builder: (context, animatedValue, _) {
                  return Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            key: const Key('download_progress_bar'),
                            minHeight: 9,
                            backgroundColor: scheme.surfaceContainerHighest,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isCompleted
                                  ? const Color(0xFF34D399)
                                  : state.isPaused
                                  ? const Color(0xFFFBBF24)
                                  : const Color(0xFF22D3EE),
                            ),
                            value: fraction == null ? null : animatedValue,
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
                            color: isCompleted
                                ? const Color(0xFF34D399)
                                : scheme.secondary,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  Text(
                    'Transferred: ${ByteFormatter.formatTransferBytes(progress?.downloadedBytes ?? 0, progress?.totalBytes, progress?.isTotalEstimated ?? false)}',
                    key: const Key('progress_bytes_text'),
                  ),
                  Text(
                    'Speed: ${ByteFormatter.formatSpeed(progress?.speedBytesPerSec)}',
                    key: const Key('progress_speed_text'),
                  ),
                  Text(
                    'ETA: ${ByteFormatter.formatEta(progress?.etaSeconds)}',
                    key: const Key('progress_eta_text'),
                  ),
                ],
              ),
              if (statusMessage != null && !isCompleted) ...[
                const SizedBox(height: 8),
                Text(
                  statusMessage,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              AnimatedCollapsibleSection(
                visible: isCompleted,
                topSpacing: 14,
                duration: const Duration(milliseconds: 240),
                entranceKey: ValueKey('done_$outputPath'),
                child: _CompletedFilePanel(
                  outputPath: outputPath ?? '',
                  onOpenFile: onOpenFile,
                  onRevealInFolder: onRevealInFolder,
                ),
              ),
            ],
          ],
      ),
    );
  }

  static String _resolvePhaseLabel(
    DownloadPhase phase, {
    required bool isPaused,
    String? message,
    int? downloadedBytes,
  }) {
    if (isPaused && phase == DownloadPhase.canceled) {
      return 'Paused';
    }
    if (phase == DownloadPhase.downloading &&
        downloadedBytes != null &&
        downloadedBytes == 0) {
      return 'Connecting';
    }
    return switch (phase) {
      DownloadPhase.analyzing => _resolvePreparingLabel(message),
      DownloadPhase.downloading => 'Downloading',
      DownloadPhase.merging => 'Merging',
      DownloadPhase.completed => 'Completed',
      DownloadPhase.canceled => 'Canceled',
      DownloadPhase.failed => 'Failed',
    };
  }

  static String _resolvePreparingLabel(String? message) {
    final lower = (message ?? '').toLowerCase();
    if (lower.contains('connecting') || lower.contains('retrying')) {
      return 'Connecting';
    }
    if (lower.contains('resolving')) {
      return 'Resolving';
    }
    return 'Preparing';
  }
}

class _CompletedFilePanel extends StatelessWidget {
  final String outputPath;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const _CompletedFilePanel({
    required this.outputPath,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      key: const Key('completed_file_panel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF10B981).withValues(alpha: 0.16),
            const Color(0xFF06B6D4).withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF34D399).withValues(alpha: 0.45),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fileInfo = Row(
            children: [
              const Icon(
                Icons.task_alt_rounded,
                color: Color(0xFF34D399),
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ByteFormatter.fileBaseName(outputPath),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ByteFormatter.formatDisplayPath(outputPath),
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
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('Show in Folder'),
              ),
              FilledButton.tonalIcon(
                key: const Key('open_file_button'),
                onPressed: () => onOpenFile(outputPath),
                icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
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
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  final String label;
  final DownloadPhase phase;
  final bool isPaused;

  const _PhaseBadge({
    super.key,
    required this.label,
    required this.phase,
    required this.isPaused,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = isPaused
        ? (const Color(0xFF452B0B), const Color(0xFFFBBF24))
        : switch (phase) {
            DownloadPhase.completed => (
              const Color(0xFF0E3829),
              const Color(0xFF34D399),
            ),
            DownloadPhase.failed => (
              scheme.errorContainer,
              const Color(0xFFFB7185),
            ),
            DownloadPhase.canceled => (
              scheme.surfaceContainerHighest,
              scheme.onSurfaceVariant,
            ),
            DownloadPhase.merging => (
              const Color(0xFF2B2250),
              const Color(0xFFC084FC),
            ),
            DownloadPhase.analyzing || DownloadPhase.downloading => (
              const Color(0xFF10344A),
              const Color(0xFF22D3EE),
            ),
          };

    return Container(
      key: const Key('download_phase_chip'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
