import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/di/injection_container.dart';
import 'package:hyper_download_client/core/platform/platform_intent_service.dart';
import 'package:hyper_download_client/core/theme/app_theme.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';
import 'package:hyper_download_client/domain/repositories/file_launcher_repository.dart';
import 'package:hyper_download_client/domain/repositories/media_inspection_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_download_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_session_repository.dart';
import 'package:hyper_download_client/domain/repositories/single_download_repository.dart';
import 'package:hyper_download_client/domain/usecases/estimate_playlist_size_usecase.dart';
import 'package:hyper_download_client/domain/usecases/inspect_url_usecase.dart';
import 'package:hyper_download_client/domain/usecases/manage_playlist_download_usecase.dart';
import 'package:hyper_download_client/domain/usecases/manage_single_download_usecase.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_cubit.dart';
import 'package:hyper_download_client/presentation/pages/media_download_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initDependencies();
  runApp(const HyperDownloadApp());
}

/// Root Flutter widget wiring dependencies, dark theme, and the media download page.
class HyperDownloadApp extends StatelessWidget {
  final MediaInspectionRepository? inspectionRepository;
  final SingleDownloadRepository? singleDownloadRepository;
  final PlaylistDownloadRepository? playlistDownloadRepository;
  final PlaylistSessionRepository? playlistSessionRepository;
  final FileLauncherRepository? fileLauncher;
  final Future<String?> Function()? getInitialSharedUrl;
  final Stream<String>? sharedUrls;

  const HyperDownloadApp({
    super.key,
    this.inspectionRepository,
    this.singleDownloadRepository,
    this.playlistDownloadRepository,
    this.playlistSessionRepository,
    this.fileLauncher,
    this.getInitialSharedUrl,
    this.sharedUrls,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveLauncher = fileLauncher ?? sl<FileLauncherRepository>();

    return MaterialApp(
      title: 'HyperDownload',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.dark,
      theme: AppTheme.dark,
      home: MultiBlocProvider(
        providers: [
          BlocProvider<UrlInspectorCubit>(
            create: (_) => _buildUrlInspectorCubit()..initialize(),
          ),
          BlocProvider<SingleDownloadCubit>(
            create: (_) => _buildSingleDownloadCubit()..initialize(),
          ),
          BlocProvider<PlaylistDownloadCubit>(
            create: (_) => _buildPlaylistDownloadCubit()..initialize(),
          ),
        ],
        child: MediaDownloadPage(fileLauncher: effectiveLauncher),
      ),
    );
  }

  UrlInspectorCubit _buildUrlInspectorCubit() {
    if (inspectionRepository != null ||
        playlistSessionRepository != null ||
        getInitialSharedUrl != null ||
        sharedUrls != null) {
      final inspectRepo =
          inspectionRepository ?? sl<MediaInspectionRepository>();
      final sessionRepo =
          playlistSessionRepository ??
          (sl.isRegistered<PlaylistSessionRepository>()
              ? sl<PlaylistSessionRepository>()
              : const _NoopPlaylistSessionRepository());
      final intentSvc =
          (getInitialSharedUrl != null || sharedUrls != null)
          ? PlatformIntentService(
              getInitialSharedUrl: getInitialSharedUrl,
              sharedUrls: sharedUrls,
            )
          : (sl.isRegistered<PlatformIntentService>()
                ? sl<PlatformIntentService>()
                : PlatformIntentService(
                    getInitialSharedUrl: () async => null,
                    sharedUrls: const Stream.empty(),
                  ));
      return UrlInspectorCubit(
        inspectUrlUseCase: InspectUrlUseCase(
          inspectionRepository: inspectRepo,
          sessionRepository: sessionRepo,
        ),
        platformRegistry: sl.isRegistered<PlatformRegistry>()
            ? sl<PlatformRegistry>()
            : const PlatformRegistry(),
        intentService: intentSvc,
      );
    }
    return sl<UrlInspectorCubit>();
  }

  SingleDownloadCubit _buildSingleDownloadCubit() {
    if (singleDownloadRepository != null) {
      return SingleDownloadCubit(
        ManageSingleDownloadUseCase(singleDownloadRepository!),
      );
    }
    return sl<SingleDownloadCubit>();
  }

  PlaylistDownloadCubit _buildPlaylistDownloadCubit() {
    if (playlistDownloadRepository != null) {
      return PlaylistDownloadCubit(
        managePlaylistUseCase: ManagePlaylistDownloadUseCase(
          playlistDownloadRepository!,
        ),
        estimateSizeUseCase: EstimatePlaylistSizeUseCase(
          playlistDownloadRepository!,
        ),
      );
    }
    return sl<PlaylistDownloadCubit>();
  }
}

class _NoopPlaylistSessionRepository implements PlaylistSessionRepository {
  const _NoopPlaylistSessionRepository();

  @override
  Future<PlaylistSessionSnapshot?> loadSavedSession({
    required String playlistId,
    String? outputDirectory,
  }) async => null;

  @override
  Future<void> saveSession({
    required String playlistDirectory,
    required PlaylistSessionSnapshot snapshot,
  }) async {}
}
