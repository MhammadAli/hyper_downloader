import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:hyper_download_client/core/platform/platform_intent_service.dart';
import 'package:hyper_download_client/data/datasources/android/android_file_launcher_datasource.dart';
import 'package:hyper_download_client/data/datasources/android/android_method_channel_datasource.dart';
import 'package:hyper_download_client/data/datasources/local/json_playlist_session_local_datasource.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_desktop_file_launcher.dart';
import 'package:hyper_download_client/data/datasources/windows/windows_yt_dlp_datasource.dart';
import 'package:hyper_download_client/data/parsers/yt_dlp_json_parser.dart';
import 'package:hyper_download_client/data/repositories/android_playlist_download_repository_impl.dart';
import 'package:hyper_download_client/data/repositories/android_single_download_repository_impl.dart';
import 'package:hyper_download_client/data/repositories/media_inspection_repository_impl.dart';
import 'package:hyper_download_client/data/repositories/playlist_session_repository_impl.dart';
import 'package:hyper_download_client/data/repositories/windows_playlist_download_repository_impl.dart';
import 'package:hyper_download_client/data/repositories/windows_single_download_repository_impl.dart';
import 'package:hyper_download_client/data/services/playlist_size_estimator.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';
import 'package:hyper_download_client/domain/repositories/file_launcher_repository.dart';
import 'package:hyper_download_client/domain/repositories/media_inspection_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_download_repository.dart';
import 'package:hyper_download_client/domain/repositories/playlist_session_repository.dart';
import 'package:hyper_download_client/domain/repositories/single_download_repository.dart';
import 'package:hyper_download_client/domain/services/media_option_synthesizer.dart';
import 'package:hyper_download_client/domain/usecases/estimate_playlist_size_usecase.dart';
import 'package:hyper_download_client/domain/usecases/inspect_url_usecase.dart';
import 'package:hyper_download_client/domain/usecases/manage_playlist_download_usecase.dart';
import 'package:hyper_download_client/domain/usecases/manage_single_download_usecase.dart';
import 'package:hyper_download_client/presentation/cubits/playlist_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_cubit.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_cubit.dart';

final GetIt sl = GetIt.instance;

/// Registers all Clean Architecture dependencies in [sl] (Composition Root).
Future<void> initDependencies({
  bool? isAndroidOverride,
  MediaInspectionRepository? inspectionRepositoryOverride,
  SingleDownloadRepository? singleDownloadRepositoryOverride,
  PlaylistDownloadRepository? playlistDownloadRepositoryOverride,
  PlaylistSessionRepository? playlistSessionRepositoryOverride,
  FileLauncherRepository? fileLauncherRepositoryOverride,
  PlatformIntentService? platformIntentServiceOverride,
}) async {
  await sl.reset();

  final isAndroid = isAndroidOverride ?? Platform.isAndroid;

  // Domain pure services & registries
  sl.registerLazySingleton<PlatformRegistry>(() => const PlatformRegistry());
  sl.registerLazySingleton<MediaOptionSynthesizer>(
    () => const MediaOptionSynthesizer(),
  );

  // Core platform bridge
  sl.registerLazySingleton<PlatformIntentService>(
    () => platformIntentServiceOverride ?? PlatformIntentService(),
  );

  // Data parsers & local/platform data sources
  sl.registerLazySingleton<YtDlpJsonParser>(
    () => YtDlpJsonParser(
      platformRegistry: sl<PlatformRegistry>(),
      synthesizer: sl<MediaOptionSynthesizer>(),
    ),
  );
  sl.registerLazySingleton<JsonPlaylistSessionLocalDataSource>(
    () => const JsonPlaylistSessionLocalDataSource(),
  );

  if (isAndroid) {
    sl.registerLazySingleton<AndroidMethodChannelDataSource>(
      () => const AndroidMethodChannelDataSource(),
    );
  } else {
    sl.registerLazySingleton<WindowsYtDlpDataSource>(
      () => WindowsYtDlpDataSource(),
    );
  }

  // Repositories
  sl.registerLazySingleton<MediaInspectionRepository>(
    () =>
        inspectionRepositoryOverride ??
        MediaInspectionRepositoryImpl(
          platformRegistry: sl<PlatformRegistry>(),
          jsonParser: sl<YtDlpJsonParser>(),
          windowsYtDlp: isAndroid ? null : sl<WindowsYtDlpDataSource>(),
          androidDataSource: isAndroid
              ? sl<AndroidMethodChannelDataSource>()
              : null,
          isAndroidOverride: isAndroid,
        ),
  );

  sl.registerLazySingleton<PlaylistSessionRepository>(
    () =>
        playlistSessionRepositoryOverride ??
        PlaylistSessionRepositoryImpl(
          localDataSource: sl<JsonPlaylistSessionLocalDataSource>(),
          androidDataSource: isAndroid
              ? sl<AndroidMethodChannelDataSource>()
              : null,
          isAndroidOverride: isAndroid,
        ),
  );

  sl.registerLazySingleton<PlaylistSizeEstimator>(
    () => PlaylistSizeEstimator(
      inspectionRepository: sl<MediaInspectionRepository>(),
      synthesizer: sl<MediaOptionSynthesizer>(),
    ),
  );

  sl.registerLazySingleton<SingleDownloadRepository>(() {
    if (singleDownloadRepositoryOverride != null) {
      return singleDownloadRepositoryOverride;
    }
    if (isAndroid) {
      return AndroidSingleDownloadRepositoryImpl(
        sl<AndroidMethodChannelDataSource>(),
      );
    }
    return WindowsSingleDownloadRepositoryImpl(
      ytDlpDataSource: sl<WindowsYtDlpDataSource>(),
      inspectionRepository:
          sl<MediaInspectionRepository>() as MediaInspectionRepositoryImpl,
      platformRegistry: sl<PlatformRegistry>(),
    );
  });

  sl.registerLazySingleton<PlaylistDownloadRepository>(() {
    if (playlistDownloadRepositoryOverride != null) {
      return playlistDownloadRepositoryOverride;
    }
    if (isAndroid) {
      return AndroidPlaylistDownloadRepositoryImpl(
        dataSource: sl<AndroidMethodChannelDataSource>(),
        sizeEstimator: sl<PlaylistSizeEstimator>(),
      );
    }
    return WindowsPlaylistDownloadRepositoryImpl(
      ytDlpDataSource: sl<WindowsYtDlpDataSource>(),
      inspectionRepository:
          sl<MediaInspectionRepository>() as MediaInspectionRepositoryImpl,
      localDataSource: sl<JsonPlaylistSessionLocalDataSource>(),
      sizeEstimator: sl<PlaylistSizeEstimator>(),
      synthesizer: sl<MediaOptionSynthesizer>(),
    );
  });

  sl.registerLazySingleton<FileLauncherRepository>(() {
    if (fileLauncherRepositoryOverride != null) {
      return fileLauncherRepositoryOverride;
    }
    return isAndroid
        ? const AndroidFileLauncherDataSource()
        : const WindowsDesktopFileLauncher();
  });

  // UseCases
  sl.registerLazySingleton<InspectUrlUseCase>(
    () => InspectUrlUseCase(
      inspectionRepository: sl<MediaInspectionRepository>(),
      sessionRepository: sl<PlaylistSessionRepository>(),
    ),
  );
  sl.registerLazySingleton<ManageSingleDownloadUseCase>(
    () => ManageSingleDownloadUseCase(sl<SingleDownloadRepository>()),
  );
  sl.registerLazySingleton<ManagePlaylistDownloadUseCase>(
    () => ManagePlaylistDownloadUseCase(sl<PlaylistDownloadRepository>()),
  );
  sl.registerLazySingleton<EstimatePlaylistSizeUseCase>(
    () => EstimatePlaylistSizeUseCase(sl<PlaylistDownloadRepository>()),
  );

  // Presentation Cubits
  sl.registerFactory<UrlInspectorCubit>(
    () => UrlInspectorCubit(
      inspectUrlUseCase: sl<InspectUrlUseCase>(),
      platformRegistry: sl<PlatformRegistry>(),
      intentService: sl<PlatformIntentService>(),
    ),
  );
  sl.registerFactory<SingleDownloadCubit>(
    () => SingleDownloadCubit(sl<ManageSingleDownloadUseCase>()),
  );
  sl.registerFactory<PlaylistDownloadCubit>(
    () => PlaylistDownloadCubit(
      managePlaylistUseCase: sl<ManagePlaylistDownloadUseCase>(),
      estimateSizeUseCase: sl<EstimatePlaylistSizeUseCase>(),
    ),
  );
}
