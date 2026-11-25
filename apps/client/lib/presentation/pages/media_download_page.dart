import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/repositories/file_launcher_repository.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_state.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_state.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_state.dart';
import 'package:hyper_download_client/presentation/widgets/common/animated_entrance.dart';
import 'package:hyper_download_client/presentation/widgets/common/error_banner.dart';
import 'package:hyper_download_client/presentation/widgets/inspector/url_input_card.dart';
import 'package:hyper_download_client/presentation/widgets/playlist/playlist_view.dart';
import 'package:hyper_download_client/presentation/widgets/single/download_controls_card.dart';
import 'package:hyper_download_client/presentation/widgets/single/media_metadata_card.dart';
import 'package:hyper_download_client/presentation/widgets/single/quality_selection_card.dart';

/// Main adaptive workspace coordinating URL analysis, single downloads, and playlists.
class MediaDownloadPage extends StatefulWidget {
  final FileLauncherRepository fileLauncher;

  const MediaDownloadPage({super.key, required this.fileLauncher});

  @override
  State<MediaDownloadPage> createState() => _MediaDownloadPageState();
}

class _MediaDownloadPageState extends State<MediaDownloadPage> {
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
    if (!context.mounted || text == null || text.isEmpty) return;
    _urlController.text = text;
    _urlController.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
    context.read<UrlInspectorCubit>().updateUrl(text);
  }

  void _clearUrl(BuildContext context) {
    _urlController.clear();
    context.read<UrlInspectorCubit>().updateUrl('');
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
      appBar: AppBar(
        titleSpacing: 24,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  scheme.primary.withValues(alpha: 0.0),
                  scheme.primary.withValues(alpha: 0.45),
                  scheme.secondary.withValues(alpha: 0.45),
                  scheme.secondary.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6366F1), Color(0xFF06B6D4)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.downloading_rounded,
                size: 20,
                color: Colors.white,
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
                    letterSpacing: -0.2,
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
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.4, -0.9),
            radius: 1.5,
            colors: [
              const Color(0xFF1A2242).withValues(alpha: 0.72),
              const Color(0xFF0E1729).withValues(alpha: 0.45),
              scheme.surfaceContainerLowest,
            ],
          ),
        ),
        child: MultiBlocListener(
          listeners: [
            BlocListener<UrlInspectorCubit, UrlInspectorState>(
              listenWhen: (prev, curr) => prev.urlInput != curr.urlInput,
              listener: (context, state) {
                if (_urlController.text != state.urlInput) {
                  _urlController.text = state.urlInput;
                  _urlController.selection = TextSelection.fromPosition(
                    TextPosition(offset: state.urlInput.length),
                  );
                }
              },
            ),
            BlocListener<UrlInspectorCubit, UrlInspectorState>(
              listenWhen: (prev, curr) =>
                  prev.analysisId != curr.analysisId &&
                  curr.inspectionStatus == InspectionStatus.loaded &&
                  curr.lastResult != null,
              listener: (context, state) {
                final result = state.lastResult!;
                final singleCubit = context.read<SingleDownloadCubit>();
                final playlistCubit = context.read<PlaylistDownloadCubit>();

                if (result.kind == InspectionTargetKind.playlist &&
                    result.playlist != null) {
                  singleCubit.clear();
                  unawaited(
                    playlistCubit.loadPlaylist(
                      result.playlist!,
                      savedSession: result.savedPlaylistSession,
                    ),
                  );
                } else if (result.video != null) {
                  unawaited(playlistCubit.clear());
                  singleCubit.loadInspection(
                    result.video!,
                    sourceUrl: state.urlInput,
                  );
                }
              },
            ),
          ],
          child: BlocBuilder<UrlInspectorCubit, UrlInspectorState>(
            builder: (context, inspectorState) {
              if (_urlController.text != inspectorState.urlInput &&
                  inspectorState.urlInput.isNotEmpty &&
                  _urlController.text.isEmpty) {
                _urlController.text = inspectorState.urlInput;
              }

              return BlocBuilder<SingleDownloadCubit, SingleDownloadState>(
                builder: (context, singleState) {
                  return BlocBuilder<
                    PlaylistDownloadCubit,
                    PlaylistDownloadState
                  >(
                    builder: (context, playlistState) {
                      final activeError =
                          playlistState.playlistError ??
                          singleState.downloadError ??
                          inspectorState.inspectionError;
                      final isPlaylistTarget =
                          inspectorState.targetKind ==
                              InspectionTargetKind.playlist &&
                          playlistState.hasPlaylist;

                      return SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 22,
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 920),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                AnimatedEntrance(
                                  child: UrlInputCard(
                                    controller: _urlController,
                                    urlInput: inspectorState.urlInput,
                                    analysisStatusText:
                                        inspectorState.analysisStatusText,
                                    hasUrlText:
                                        inspectorState.urlInput.isNotEmpty,
                                    isAnalyzing: inspectorState.isAnalyzing,
                                    onUrlChanged: (val) => context
                                        .read<UrlInspectorCubit>()
                                        .updateUrl(val),
                                    onClear: () => _clearUrl(context),
                                    onPaste: () => _pasteFromClipboard(context),
                                    onAnalyze: () => context
                                        .read<UrlInspectorCubit>()
                                        .analyzeUrl(_urlController.text),
                                    onCancelAnalysis: () => context
                                        .read<UrlInspectorCubit>()
                                        .cancelAnalysis(),
                                  ),
                                ),
                                AnimatedSize(
                                  duration: const Duration(milliseconds: 260),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  child: activeError != null
                                      ? Padding(
                                          padding: const EdgeInsets.only(
                                            top: 16,
                                          ),
                                          child: AnimatedEntrance(
                                            child: ErrorBanner(
                                              message: activeError,
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                                AnimatedSize(
                                  duration: const Duration(milliseconds: 280),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  child: isPlaylistTarget
                                      ? Padding(
                                          padding: const EdgeInsets.only(
                                            top: 16,
                                          ),
                                          child: AnimatedEntrance(
                                            key: ValueKey(
                                              'playlist_${playlistState.playlistInspection!.id}',
                                            ),
                                            child: PlaylistView(
                                              state: playlistState,
                                              onOpenFile: (path) =>
                                                  _openFile(context, path),
                                              onRevealInFolder: (path) =>
                                                  _revealInFolder(
                                                    context,
                                                    path,
                                                  ),
                                            ),
                                          ),
                                        )
                                      : singleState.inspection != null
                                      ? Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            const SizedBox(height: 16),
                                            AnimatedEntrance(
                                              key: ValueKey(
                                                'meta_${singleState.inspection!.id}',
                                              ),
                                              child: MediaMetadataCard(
                                                inspection:
                                                    singleState.inspection!,
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            AnimatedEntrance(
                                              key: ValueKey(
                                                'qual_${singleState.inspection!.id}',
                                              ),
                                              child: QualitySelectionCard(
                                                state: singleState,
                                              ),
                                            ),
                                          ],
                                        )
                                      : const SizedBox.shrink(),
                                ),
                                AnimatedSize(
                                  duration: const Duration(milliseconds: 260),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  child:
                                      (!isPlaylistTarget &&
                                          singleState.hasTransferOrInspection)
                                      ? Padding(
                                          padding: const EdgeInsets.only(
                                            top: 16,
                                          ),
                                          child: AnimatedEntrance(
                                            child: DownloadControlsCard(
                                              state: singleState,
                                              onOpenFile: (path) =>
                                                  _openFile(context, path),
                                              onRevealInFolder: (path) =>
                                                  _revealInFolder(
                                                    context,
                                                    path,
                                                  ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
