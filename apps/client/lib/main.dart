import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/bridge/frb_generated.dart';
import 'package:hyper_download_client/core/theme/app_theme.dart';
import 'package:hyper_download_client/features/media_download/desktop_file_launcher.dart';
import 'package:hyper_download_client/features/media_download/media_download_cubit.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/features/media_download/media_download_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const HyperDownloadApp());
}

/// Root Flutter widget wiring dependencies, dark theme, and the media download screen.
class HyperDownloadApp extends StatelessWidget {
  final MediaDownloadRepository? repository;
  final DesktopFileLauncher? fileLauncher;

  const HyperDownloadApp({super.key, this.repository, this.fileLauncher});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HyperDownload',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.dark,
      theme: AppTheme.dark,
      home: BlocProvider(
        create: (_) => MediaDownloadCubit(
          repository: repository ?? const FrbMediaDownloadRepository(),
        )..initialize(),
        child: MediaDownloadScreen(
          fileLauncher: fileLauncher ?? const WindowsDesktopFileLauncher(),
        ),
      ),
    );
  }
}
