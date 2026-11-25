import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/di/injection_container.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/repositories/file_launcher_repository.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_state.dart';
import 'package:hyper_download_client/presentation/widgets/common/animated_entrance.dart';
import 'package:hyper_download_client/presentation/widgets/common/error_banner.dart';
import 'package:hyper_download_client/presentation/widgets/common/hyper_app_bar.dart';
import 'package:hyper_download_client/presentation/widgets/inspector/url_input_card.dart';
import 'package:hyper_download_client/presentation/widgets/playlist/playlist_view.dart';
import 'package:hyper_download_client/presentation/widgets/single/single_download_view.dart';

/// Main adaptive workspace coordinating URL analysis, single downloads, and playlists.
class MediaDownloadPage extends StatelessWidget {
  const MediaDownloadPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<UrlInspectorCubit>(
          create: (_) => sl<UrlInspectorCubit>()..initialize(),
        ),
        BlocProvider<SingleDownloadCubit>(
          create: (_) => sl<SingleDownloadCubit>()..initialize(),
        ),
        BlocProvider<PlaylistDownloadCubit>(
          create: (_) => sl<PlaylistDownloadCubit>()..initialize(),
        ),
      ],
      child: _MediaDownloadView(fileLauncher: sl<FileLauncherRepository>()),
    );
  }
}

class _MediaDownloadView extends StatefulWidget {
  final FileLauncherRepository fileLauncher;

  const _MediaDownloadView({required this.fileLauncher});

  @override
  State<_MediaDownloadView> createState() => _MediaDownloadViewState();
}

class _MediaDownloadViewState extends State<_MediaDownloadView> {
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

  void _syncControllerText(String value) {
    if (_urlController.text == value) return;
    _urlController.text = value;
    _urlController.selection = TextSelection.fromPosition(
      TextPosition(offset: value.length),
    );
  }

  Future<void> _pasteFromClipboard(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!context.mounted || text == null || text.isEmpty) return;
    _syncControllerText(text);
    context.read<UrlInspectorCubit>().updateUrl(text);
  }

  void _clearUrl(BuildContext context) {
    _urlController.clear();
    context.read<UrlInspectorCubit>().updateUrl('');
  }

  Future<void> _runFileAction(
    BuildContext context,
    Future<bool> Function() action,
    String failureMessage,
  ) async {
    final succeeded = await action();
    if (!context.mounted || succeeded) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(failureMessage)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inspectorCubit = context.read<UrlInspectorCubit>();
    final inspectorState = context.watch<UrlInspectorCubit>().state;
    final singleState = context.watch<SingleDownloadCubit>().state;
    final playlistState = context.watch<PlaylistDownloadCubit>().state;

    if (inspectorState.urlInput.isNotEmpty && _urlController.text.isEmpty) {
      _urlController.text = inspectorState.urlInput;
    }

    final activeError =
        playlistState.playlistError ??
        singleState.downloadError ??
        inspectorState.inspectionError;
    final isPlaylistTarget =
        inspectorState.targetKind == InspectionTargetKind.playlist &&
        playlistState.hasPlaylist;
    final showSingleView =
        !isPlaylistTarget && singleState.hasTransferOrInspection;

    return Scaffold(
      appBar: const HyperAppBar(),
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
              listener: (context, state) =>
                  _syncControllerText(state.urlInput),
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
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
                        analysisStatusText: inspectorState.analysisStatusText,
                        hasUrlText: inspectorState.urlInput.isNotEmpty,
                        isAnalyzing: inspectorState.isAnalyzing,
                        onUrlChanged: inspectorCubit.updateUrl,
                        onClear: () => _clearUrl(context),
                        onPaste: () => _pasteFromClipboard(context),
                        onAnalyze: () =>
                            inspectorCubit.analyzeUrl(_urlController.text),
                        onCancelAnalysis: inspectorCubit.cancelAnalysis,
                      ),
                    ),
                    AnimatedCollapsibleSection(
                      visible: activeError != null,
                      child: ErrorBanner(message: activeError ?? ''),
                    ),
                    AnimatedCollapsibleSection(
                      visible: isPlaylistTarget,
                      duration: const Duration(milliseconds: 280),
                      entranceKey: isPlaylistTarget
                          ? ValueKey(
                              'playlist_${playlistState.playlistInspection!.id}',
                            )
                          : null,
                      child: isPlaylistTarget
                          ? PlaylistView(
                              state: playlistState,
                              onOpenFile: (path) => _runFileAction(
                                context,
                                () => widget.fileLauncher.openFile(path),
                                'Could not open file. Check if it still exists on disk.',
                              ),
                              onRevealInFolder: (path) => _runFileAction(
                                context,
                                () => widget.fileLauncher.revealInFolder(path),
                                'Could not open folder. Check if the path still exists on disk.',
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    AnimatedCollapsibleSection(
                      visible: showSingleView,
                      duration: const Duration(milliseconds: 280),
                      child: showSingleView
                          ? SingleDownloadView(
                              state: singleState,
                              onOpenFile: (path) => _runFileAction(
                                context,
                                () => widget.fileLauncher.openFile(path),
                                'Could not open file. Check if it still exists on disk.',
                              ),
                              onRevealInFolder: (path) => _runFileAction(
                                context,
                                () => widget.fileLauncher.revealInFolder(path),
                                'Could not open folder. Check if the path still exists on disk.',
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
