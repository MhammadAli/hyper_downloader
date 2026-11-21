import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/bridge/frb_generated.dart';
import 'package:hyper_download_client/core/theme/app_theme.dart';
import 'package:hyper_download_client/features/media_download/android_file_launcher.dart';
import 'package:hyper_download_client/features/media_download/android_media_download_repository.dart';
import 'package:hyper_download_client/features/media_download/desktop_file_launcher.dart';
import 'package:hyper_download_client/features/media_download/media_download_cubit.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/features/media_download/media_download_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid) {
    await RustLib.init();
    runApp(const HyperDownloadApp());
    return;
  }

  const intentChannel = MethodChannel('com.hyperdownload/platform_intents');
  final sharedUrlsController = StreamController<String>.broadcast();
  intentChannel.setMethodCallHandler((call) async {
    if (call.method == 'onSharedUrl') {
      final raw = call.arguments as String?;
      if (raw != null && raw.trim().isNotEmpty) {
        sharedUrlsController.add(raw.trim());
      }
    }
  });

  runApp(
    HyperDownloadApp(
      repository: const AndroidMediaDownloadRepository(),
      fileLauncher: const AndroidFileLauncher(),
      getInitialSharedUrl: () =>
          intentChannel.invokeMethod<String>('consumeInitialSharedUrl'),
      sharedUrls: sharedUrlsController.stream,
    ),
  );
}

/// Root Flutter widget wiring dependencies, dark theme, and the media download screen.
class HyperDownloadApp extends StatelessWidget {
  final MediaDownloadRepository? repository;
  final DesktopFileLauncher? fileLauncher;
  final Future<String?> Function()? getInitialSharedUrl;
  final Stream<String>? sharedUrls;

  const HyperDownloadApp({
    super.key,
    this.repository,
    this.fileLauncher,
    this.getInitialSharedUrl,
    this.sharedUrls,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveRepository =
        repository ??
        (Platform.isAndroid
            ? const AndroidMediaDownloadRepository()
            : const FrbMediaDownloadRepository());
    final effectiveLauncher =
        fileLauncher ??
        (Platform.isAndroid
            ? const AndroidFileLauncher()
            : const WindowsDesktopFileLauncher());

    return MaterialApp(
      title: 'HyperDownload',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.dark,
      theme: AppTheme.dark,
      home: BlocProvider(
        create: (_) => MediaDownloadCubit(
          repository: effectiveRepository,
          getInitialSharedUrl: getInitialSharedUrl,
          sharedUrls: sharedUrls,
        )..initialize(),
        child: MediaDownloadScreen(fileLauncher: effectiveLauncher),
      ),
    );
  }
}
