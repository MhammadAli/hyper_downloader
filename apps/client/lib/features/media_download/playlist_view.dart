import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/bridge/models.dart';
import 'package:hyper_download_client/features/media_download/media_download_cubit.dart';
import 'package:hyper_download_client/features/media_download/media_download_state.dart';

/// Dark studio view for YouTube playlist inspection, quality caps, and ordered batch progress.
class PlaylistView extends StatelessWidget {
  final MediaDownloadState state;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const PlaylistView({
    super.key,
    required this.state,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final playlist = state.playlistInspection;
    if (playlist == null) {
      return const SizedBox.shrink();
    }

    final session = state.playlistSession;
    final displayItems = _buildDisplayItems(playlist, session);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PlaylistHeaderCard(
          playlist: playlist,
          session: session,
          onRevealInFolder: onRevealInFolder,
        ),
        const SizedBox(height: 16),
        _PlaylistControlsCard(state: state, playlist: playlist),
        const SizedBox(height: 16),
        _PlaylistItemsCard(
          items: displayItems,
          sizeEstimate: state.playlistSizeEstimate,
          onOpenFile: onOpenFile,
          onRevealInFolder: onRevealInFolder,
        ),
      ],
    );
  }

  List<PlaylistItemState> _buildDisplayItems(
    PlaylistInspection playlist,
    PlaylistSessionSnapshot? session,
  ) {
    if (session != null) {
      return session.items;
    }

    return playlist.entries
        .map((entry) {
          final (status, message) = switch (entry.availability) {
            PlaylistEntryAvailability.available => (
              PlaylistItemStatus.pending,
              null,
            ),
            PlaylistEntryAvailability.private => (
              PlaylistItemStatus.skipped,
              entry.availabilityReason ?? 'Skipped: private video.',
            ),
            PlaylistEntryAvailability.removed => (
              PlaylistItemStatus.skipped,
              entry.availabilityReason ?? 'Skipped: removed or deleted video.',
            ),
            PlaylistEntryAvailability.unavailable => (
              PlaylistItemStatus.skipped,
              entry.availabilityReason ?? 'Skipped: unavailable video.',
            ),
          };
          return PlaylistItemState(
            orderIndex: entry.orderIndex,
            videoId: entry.videoId,
            title: entry.title,
            url: entry.url,
            durationSeconds: entry.durationSeconds,
            thumbnailUrl: entry.thumbnailUrl,
            status: status,
            downloadedBytes: BigInt.zero,
            isTotalEstimated: false,
            errorMessage: message,
          );
        })
        .toList(growable: false);
  }
}

class _PlaylistHeaderCard extends StatelessWidget {
  final PlaylistInspection playlist;
  final PlaylistSessionSnapshot? session;
  final ValueChanged<String> onRevealInFolder;

  const _PlaylistHeaderCard({
    required this.playlist,
    required this.session,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final unavailableCount = playlist.entries
        .where((e) => e.availability != PlaylistEntryAvailability.available)
        .length;
    final outputDir = session?.outputDirectory;

    final thumbnail = Container(
      width: 204,
      height: 115,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: playlist.thumbnailUrl != null
          ? Image.network(
              playlist.thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.playlist_play_rounded,
                size: 42,
                color: scheme.onSurfaceVariant,
              ),
            )
          : Icon(
              Icons.playlist_play_rounded,
              size: 42,
              color: scheme.onSurfaceVariant,
            ),
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          playlist.title,
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
          children: [
            _PlaylistMetaBadge(
              icon: Icons.public_rounded,
              label: playlist.providerName,
              accent: scheme.secondary,
            ),
            if (playlist.uploader != null)
              _PlaylistMetaBadge(
                icon: Icons.person_outline_rounded,
                label: playlist.uploader!,
                accent: scheme.primary,
              ),
            _PlaylistMetaBadge(
              icon: Icons.format_list_numbered_rounded,
              label: '${playlist.totalItemCount} items',
              accent: scheme.tertiary,
            ),
            if (unavailableCount > 0)
              _PlaylistMetaBadge(
                icon: Icons.block_outlined,
                label: '$unavailableCount unavailable',
                accent: const Color(0xFFFBBF24),
              ),
          ],
        ),
        if (outputDir != null && outputDir.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                key: const Key('playlist_open_folder_button'),
                onPressed: () => onRevealInFolder(outputDir),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('Open Folder'),
              ),
              Text(
                _folderTail(outputDir),
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ],
    );

    return Card(
      key: const Key('playlist_header_card'),
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

class _PlaylistControlsCard extends StatelessWidget {
  final MediaDownloadState state;
  final PlaylistInspection playlist;

  const _PlaylistControlsCard({required this.state, required this.playlist});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MediaDownloadCubit>();
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
              _PlaylistSizeSummaryBox(
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
                    const _StatusTag(
                      label: 'Paused',
                      fg: Color(0xFFFBBF24),
                      bg: Color(0xFF3E2D0F),
                    )
                  else if (session.isRunning)
                    const _StatusTag(
                      label: 'Running',
                      fg: Color(0xFF22D3EE),
                      bg: Color(0xFF10344A),
                    )
                  else if (allDone)
                    const _StatusTag(
                      label: 'Finished',
                      fg: Color(0xFF34D399),
                      bg: Color(0xFF103B2C),
                    ),
                  if (session.failedCount > 0)
                    _StatusTag(
                      label: '${session.failedCount} failed',
                      fg: const Color(0xFFFB7185),
                      bg: scheme.errorContainer,
                    ),
                  if (session.skippedCount > 0)
                    _StatusTag(
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
  final BigInt? etaSeconds;

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
    final double? fraction = !isMerging && total != null && total > BigInt.zero
        ? (item.downloadedBytes.toDouble() / total.toDouble()).clamp(0.0, 1.0)
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
              _ItemStatusBadge(status: item.status),
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
                'Transferred: ${_formatItemBytes(item.downloadedBytes, item.totalBytes, item.isTotalEstimated)}',
              ),
              Text('Speed: ${_formatSpeed(speedBytesPerSec)}'),
              Text('Item ETA: ${_formatEta(etaSeconds)}'),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlaylistSizeSummaryBox extends StatelessWidget {
  final PlaylistSizeEstimate estimate;
  final VoidCallback? onCancel;
  final VoidCallback? onRecalculate;

  const _PlaylistSizeSummaryBox({
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

    final (icon, accent, bg) = switch (estimate.status) {
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
              _StatusTag(
                label: '${estimate.eligibleCount} included',
                fg: scheme.onSurface,
                bg: scheme.surfaceContainerHighest,
              ),
              if (estimate.exactCount > 0)
                _StatusTag(
                  label: '${estimate.exactCount} exact',
                  fg: const Color(0xFF34D399),
                  bg: const Color(0xFF103B2C),
                ),
              if (estimate.estimatedCount > 0)
                _StatusTag(
                  label: '${estimate.estimatedCount} estimated',
                  fg: const Color(0xFF22D3EE),
                  bg: const Color(0xFF10344A),
                ),
              if (estimate.unknownCount > 0)
                _StatusTag(
                  label: '${estimate.unknownCount} unknown',
                  fg: const Color(0xFFFBBF24),
                  bg: const Color(0xFF3E2D0F),
                ),
              if (estimate.failedCount > 0)
                _StatusTag(
                  label: '${estimate.failedCount} failed',
                  fg: const Color(0xFFFB7185),
                  bg: scheme.errorContainer,
                ),
              if (estimate.unavailableCount > 0)
                _StatusTag(
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

class _PlaylistItemsCard extends StatelessWidget {
  final List<PlaylistItemState> items;
  final PlaylistSizeEstimate? sizeEstimate;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const _PlaylistItemsCard({
    required this.items,
    required this.sizeEstimate,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final Map<int, PlaylistItemSizeInfo> sizeByOrder = {
      for (final info in sizeEstimate?.itemSizes ?? const [])
        info.orderIndex: info,
    };

    return Card(
      key: const Key('playlist_items_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Playlist Items (${items.length})',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Text(
                'No playlist entries were returned.',
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 460),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _PlaylistItemRow(
                      item: item,
                      sizeInfo: sizeByOrder[item.orderIndex],
                      onOpenFile: onOpenFile,
                      onRevealInFolder: onRevealInFolder,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistItemRow extends StatelessWidget {
  final PlaylistItemState item;
  final PlaylistItemSizeInfo? sizeInfo;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const _PlaylistItemRow({
    required this.item,
    this.sizeInfo,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final numberLabel = (item.orderIndex + 1).toString().padLeft(3, '0');
    final isCompleted =
        item.status == PlaylistItemStatus.completed && item.outputPath != null;
    final showNote =
        item.errorMessage != null &&
        item.errorMessage!.isNotEmpty &&
        (item.status == PlaylistItemStatus.failed ||
            item.status == PlaylistItemStatus.skipped ||
            item.status == PlaylistItemStatus.canceled);

    return Container(
      key: Key('playlist_item_${item.orderIndex}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 500;
          final leadingAndInfo = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  numberLabel,
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.secondary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        if (item.durationSeconds != null)
                          Text(
                            _formatDuration(item.durationSeconds!.round()),
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if ((item.selectedQuality ??
                                sizeInfo?.selectedQuality) !=
                            null)
                          Text(
                            item.selectedQuality ?? sizeInfo!.selectedQuality!,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.secondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (sizeInfo != null)
                          Text(
                            sizeInfo!.displaySize,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if (item.audioLanguage?.languageDisplayName != null)
                          Text(
                            item.audioLanguage!.languageDisplayName!,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    if (showNote) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.errorMessage!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: item.status == PlaylistItemStatus.failed
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );

          final trailingControls = Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ItemStatusBadge(status: item.status),
              if (isCompleted) ...[
                IconButton(
                  key: Key('playlist_item_open_${item.orderIndex}'),
                  tooltip: 'Open File',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onOpenFile(item.outputPath!),
                  icon: const Icon(Icons.play_circle_outline_rounded, size: 20),
                ),
                IconButton(
                  key: Key('playlist_item_folder_${item.orderIndex}'),
                  tooltip: 'Show in Folder',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onRevealInFolder(item.outputPath!),
                  icon: const Icon(Icons.folder_open_rounded, size: 20),
                ),
              ],
            ],
          );

          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leadingAndInfo,
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: trailingControls,
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: leadingAndInfo),
              const SizedBox(width: 12),
              trailingControls,
            ],
          );
        },
      ),
    );
  }
}

class _ItemStatusBadge extends StatelessWidget {
  final PlaylistItemStatus status;

  const _ItemStatusBadge({required this.status});

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

    return _StatusTag(label: label, fg: fg, bg: bg);
  }
}

class _StatusTag extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;

  const _StatusTag({required this.label, required this.fg, required this.bg});

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

class _PlaylistMetaBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;

  const _PlaylistMetaBadge({
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

String _qualityCapLabel(PlaylistQualityCap cap) {
  return switch (cap) {
    PlaylistQualityCap.bestAvailable => 'Best Available',
    PlaylistQualityCap.upTo1080P => 'Up to 1080p',
    PlaylistQualityCap.upTo720P => 'Up to 720p',
    PlaylistQualityCap.upTo480P => 'Up to 480p',
  };
}

String _folderTail(String fullPath) {
  final sep = Platform.pathSeparator;
  final normalized = fullPath.replaceAll('/', sep).replaceAll('\\', sep);
  final parts = normalized.split(sep).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return fullPath;
  return parts.last;
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

String _formatItemBytes(BigInt downloaded, BigInt? total, bool isEstimated) {
  final down = _formatBytes(downloaded);
  if (total == null || total == BigInt.zero) return down;
  final prefix = isEstimated ? '~' : '';
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
