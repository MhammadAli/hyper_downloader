import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/utils/formatters.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_state.dart';
import 'package:hyper_download_client/presentation/widgets/common/status_badges.dart';
import 'package:hyper_download_client/presentation/widgets/playlist/playlist_size_summary_card.dart';

class PlaylistControlsCard extends StatelessWidget {
  final PlaylistDownloadState state;
  final PlaylistInspection playlist;

  const PlaylistControlsCard({
    super.key,
    required this.state,
    required this.playlist,
  });

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<PlaylistDownloadCubit>();
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final session = state.playlistSession;
    final activeItem = state.activePlaylistItem;
    final controlsLocked = state.isPlaylistRunning;

    return Card(
      key: const Key('playlist_controls_card'),
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
                  'Playlist Download Options',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<PlaylistMediaMode>(
                    key: const Key('playlist_mode_toggle'),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment<PlaylistMediaMode>(
                        value: PlaylistMediaMode.videoWithSound,
                        icon: Icon(Icons.movie_creation_outlined, size: 18),
                        label: Text('Video with Sound'),
                      ),
                      ButtonSegment<PlaylistMediaMode>(
                        value: PlaylistMediaMode.audioOnly,
                        icon: Icon(Icons.audiotrack_outlined, size: 18),
                        label: Text('Audio Only'),
                      ),
                    ],
                    selected: {state.playlistMediaMode},
                    onSelectionChanged: controlsLocked
                        ? null
                        : (selected) {
                            if (selected.isNotEmpty) {
                              cubit.setPlaylistMediaMode(selected.first);
                            }
                          },
                  ),
                ),
              ],
            ),
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
                    state.playlistMediaMode == PlaylistMediaMode.videoWithSound
                        ? 'Selects the best playable video + original audio per item up to your quality cap.'
                        : 'Extracts the best original audio track automatically for each available item.',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (state.playlistMediaMode ==
                PlaylistMediaMode.videoWithSound) ...[
              const SizedBox(height: 12),
              Wrap(
                key: const Key('playlist_quality_cap_selector'),
                spacing: 8,
                runSpacing: 8,
                children: PlaylistQualityCap.values
                    .map((cap) {
                      final selected = state.playlistQualityCap == cap;
                      return ChoiceChip(
                        label: Text(_qualityCapLabel(cap)),
                        selected: selected,
                        onSelected: controlsLocked
                            ? null
                            : (_) => cubit.setPlaylistQualityCap(cap),
                      );
                    })
                    .toList(growable: false),
              ),
            ],
            if (state.playlistSizeEstimate != null) ...[
              const SizedBox(height: 12),
              PlaylistSizeSummaryCard(
                estimate: state.playlistSizeEstimate!,
                onCancel: state.canCancelPlaylistSize
                    ? cubit.cancelPlaylistSizeEstimation
                    : null,
                onRecalculate: controlsLocked
                    ? null
                    : cubit.estimatePlaylistSize,
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const Key('start_playlist_button'),
                  onPressed: state.canStartPlaylist
                      ? cubit.startPlaylistDownload
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
                  label: const Text('Download Playlist'),
                ),
                OutlinedButton.icon(
                  key: const Key('pause_playlist_button'),
                  onPressed: state.canPausePlaylist
                      ? cubit.pausePlaylistDownload
                      : null,
                  icon: const Icon(Icons.pause_rounded, size: 18),
                  label: const Text('Pause'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('resume_playlist_button'),
                  onPressed: state.canResumePlaylist
                      ? cubit.resumePlaylistDownload
                      : null,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Resume'),
                ),
                OutlinedButton.icon(
                  key: const Key('cancel_playlist_button'),
                  onPressed: state.canCancelPlaylist
                      ? cubit.cancelPlaylistDownload
                      : null,
                  icon: const Icon(Icons.cancel_outlined, size: 18),
                  label: const Text('Cancel'),
                ),
                if (state.canRetryFailedPlaylist ||
                    (session != null && session.failedCount > 0))
                  FilledButton.tonalIcon(
                    key: const Key('retry_failed_playlist_button'),
                    onPressed: state.canRetryFailedPlaylist
                        ? cubit.retryFailedPlaylistItems
                        : null,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry Failed'),
                  ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: session != null
                  ? Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: _OverallBatchProgressPanel(
                        session: session,
                        fallbackTotal: playlist.totalItemCount,
                        statusMessage: state.playlistStatusMessage,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: activeItem != null
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _ActivePlaylistItemPanel(
                        item: activeItem,
                        speedBytesPerSec: state.activePlaylistSpeedBytesPerSec,
                        etaSeconds: state.activePlaylistEtaSeconds,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  static String _qualityCapLabel(PlaylistQualityCap cap) => switch (cap) {
    PlaylistQualityCap.bestAvailable => 'Best Available',
    PlaylistQualityCap.upTo1080p => 'Up to 1080p',
    PlaylistQualityCap.upTo720p => 'Up to 720p',
    PlaylistQualityCap.upTo480p => 'Up to 480p',
  };
}

class _OverallBatchProgressPanel extends StatelessWidget {
  final PlaylistSessionSnapshot session;
  final int fallbackTotal;
  final String? statusMessage;

  const _OverallBatchProgressPanel({
    required this.session,
    required this.fallbackTotal,
    this.statusMessage,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final total = session.totalCount > 0 ? session.totalCount : fallbackTotal;
    final resolvedCount = session.completedCount + session.skippedCount;
    final fraction = total > 0 ? (resolvedCount / total).clamp(0.0, 1.0) : 0.0;
    final allDone =
        !session.isRunning &&
        !session.isPaused &&
        total > 0 &&
        session.completedCount + session.skippedCount >= total &&
        session.failedCount == 0;

    return Container(
      key: const Key('playlist_overall_progress'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(
                '${session.completedCount} / $total completed',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (session.isPaused)
                    const StatusTag(
                      label: 'Paused',
                      fg: Color(0xFFFBBF24),
                      bg: Color(0xFF3E2D0F),
                    )
                  else if (session.isRunning)
                    const StatusTag(
                      label: 'Running',
                      fg: Color(0xFF22D3EE),
                      bg: Color(0xFF10344A),
                    )
                  else if (allDone)
                    const StatusTag(
                      label: 'Finished',
                      fg: Color(0xFF34D399),
                      bg: Color(0xFF103B2C),
                    ),
                  if (session.failedCount > 0)
                    StatusTag(
                      label: '${session.failedCount} failed',
                      fg: const Color(0xFFFB7185),
                      bg: scheme.errorContainer,
                    ),
                  if (session.skippedCount > 0)
                    StatusTag(
                      label: '${session.skippedCount} skipped',
                      fg: scheme.onSurfaceVariant,
                      bg: scheme.surfaceContainerHighest,
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: fraction),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  key: const Key('playlist_overall_progress_bar'),
                  minHeight: 8,
                  value: value,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    allDone
                        ? const Color(0xFF34D399)
                        : session.isPaused
                        ? const Color(0xFFFBBF24)
                        : const Color(0xFF6366F1),
                  ),
                ),
              );
            },
          ),
          if (statusMessage != null && statusMessage!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              statusMessage!,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActivePlaylistItemPanel extends StatelessWidget {
  final PlaylistItemState item;
  final double? speedBytesPerSec;
  final int? etaSeconds;

  const _ActivePlaylistItemPanel({
    required this.item,
    this.speedBytesPerSec,
    this.etaSeconds,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isMerging = item.status == PlaylistItemStatus.merging;
    final total = item.totalBytes;
    final double? fraction = !isMerging && total != null && total > 0
        ? (item.downloadedBytes / total).clamp(0.0, 1.0)
        : null;

    return Container(
      key: const Key('playlist_active_item_panel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF22D3EE).withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Item ${(item.orderIndex + 1).toString().padLeft(3, '0')} · ${item.title}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PlaylistItemStatusBadge(status: item.status),
            ],
          ),
          if (item.selectedQuality != null || item.audioLanguage != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                if (item.selectedQuality != null)
                  Text(
                    'Quality: ${item.selectedQuality!}',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.secondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (item.audioLanguage != null)
                  Text(
                    item.audioLanguage!.statusNote,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: fraction ?? 0.0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            builder: (context, animatedValue, _) {
              return Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        key: const Key('playlist_item_progress_bar'),
                        minHeight: 8,
                        backgroundColor: scheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isMerging
                              ? const Color(0xFFC084FC)
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
                      style: textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.secondary,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 20,
            runSpacing: 6,
            children: [
              Text(
                'Transferred: ${ByteFormatter.formatTransferBytes(item.downloadedBytes, item.totalBytes, item.isTotalEstimated)}',
              ),
              Text('Speed: ${ByteFormatter.formatSpeed(speedBytesPerSec)}'),
              Text('Item ETA: ${ByteFormatter.formatEta(etaSeconds)}'),
            ],
          ),
        ],
      ),
    );
  }
}
