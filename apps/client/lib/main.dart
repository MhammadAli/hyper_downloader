import 'package:flutter/material.dart';
import 'package:hyper_download_client/core/di/injection_container.dart';
import 'package:hyper_download_client/core/theme/app_theme.dart';
import 'package:hyper_download_client/presentation/pages/media_download_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initDependencies();
  runApp(const HyperDownloadApp());
}

/// Root Flutter widget configuring the application theme and initial page.
class HyperDownloadApp extends StatelessWidget {
  const HyperDownloadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HyperDownload',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.dark,
      theme: AppTheme.dark,
      home: const MediaDownloadPage(),
    );
  }
}
