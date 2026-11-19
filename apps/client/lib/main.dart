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
    final baseDark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6366F1),
      brightness: Brightness.dark,
    );

    final darkScheme = baseDark.copyWith(
      primary: const Color(0xFF818CF8),
      onPrimary: const Color(0xFF0A0D18),
      primaryContainer: const Color(0xFF283066),
      onPrimaryContainer: const Color(0xFFE0E7FF),
      secondary: const Color(0xFF22D3EE),
      onSecondary: const Color(0xFF052029),
      secondaryContainer: const Color(0xFF143647),
      onSecondaryContainer: const Color(0xFFCFFAFE),
      tertiary: const Color(0xFF34D399),
      onTertiary: const Color(0xFF062319),
      tertiaryContainer: const Color(0xFF15362B),
      onTertiaryContainer: const Color(0xFFD1FAE5),
      error: const Color(0xFFFB7185),
      errorContainer: const Color(0xFF3B1522),
      onErrorContainer: const Color(0xFFFFE4E6),
      surface: const Color(0xFF121726),
      onSurface: const Color(0xFFF1F5F9),
      onSurfaceVariant: const Color(0xFF94A3B8),
      surfaceContainerLowest: const Color(0xFF0A0D16),
      surfaceContainerLow: const Color(0xFF171E31),
      surfaceContainerHighest: const Color(0xFF222B45),
      outline: const Color(0xFF475569),
      outlineVariant: const Color(0xFF26314D),
    );

    final darkTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: darkScheme,
      scaffoldBackgroundColor: darkScheme.surfaceContainerLowest,
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF0D111E),
        foregroundColor: darkScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: darkScheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: darkScheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0D121F),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: darkScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: darkScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: darkScheme.secondary, width: 1.6),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return darkScheme.primaryContainer;
            }
            return darkScheme.surfaceContainerLow;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return darkScheme.onPrimaryContainer;
            }
            return darkScheme.onSurfaceVariant;
          }),
          side: WidgetStatePropertyAll(
            BorderSide(color: darkScheme.outlineVariant),
          ),
        ),
      ),
    );

    return MaterialApp(
      title: 'HyperDownload',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: darkTheme,
      theme: darkTheme,
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
