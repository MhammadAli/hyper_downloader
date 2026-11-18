import 'package:flutter/material.dart';
import 'package:hyper_download_client/core/bridge/api.dart';
import 'package:hyper_download_client/core/bridge/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const HyperDownloadApp());
}

class HyperDownloadApp extends StatelessWidget {
  const HyperDownloadApp({super.key});

  @override
  Widget build(BuildContext context) {
    final pingResult = ping();
    final versionResult = engineVersion();

    return MaterialApp(
      title: 'HyperDownload',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('HyperDownload — Phase 1')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Ping: $pingResult'),
              const SizedBox(height: 8),
              Text('Engine Version: $versionResult'),
            ],
          ),
        ),
      ),
    );
  }
}
