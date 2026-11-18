import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hyper_download_client/core/bridge/frb_generated.dart';
import 'package:hyper_download_client/features/media_download/desktop_file_launcher.dart';
import 'package:hyper_download_client/features/media_download/media_download_cubit.dart';
import 'package:hyper_download_client/features/media_download/media_download_repository.dart';
import 'package:hyper_download_client/features/media_download/media_download_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const HyperDownloadApp());
}

class HyperDownloadApp extends StatelessWidget {
  final MediaDownloadRepository? repository;
  final DesktopFileLauncher? fileLauncher;

  const HyperDownloadApp({super.key, this.repository, this.fileLauncher});

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3949AB)),
      useMaterial3: true,
    );

    return MaterialApp(
      title: 'HyperDownload',
      debugShowCheckedModeBanner: false,
      theme: baseTheme.copyWith(
        cardTheme: CardThemeData(
          elevation: 0,
          color: baseTheme.colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: baseTheme.colorScheme.outlineVariant),
          ),
        ),
      ),
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
