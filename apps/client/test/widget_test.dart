import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_download_client/core/bridge/api.dart';
import 'package:hyper_download_client/core/bridge/frb_generated.dart';
import 'package:hyper_download_client/main.dart';

void main() {
  test('Flutter-to-Rust Debug DLL responds to ping and engineVersion', () async {
    final debugDll = File('../../rust/target/debug/engine_ffi.dll');
    expect(debugDll.existsSync(), isTrue);

    await RustLib.init(
      externalLibrary: ExternalLibrary.open(debugDll.absolute.path),
    );

    expect(ping(), 'pong');
    expect(engineVersion(), '0.1.0');

    RustLib.dispose();
  });

  testWidgets(
    'HyperDownloadApp renders ping and engineVersion from Rust Debug DLL',
    (WidgetTester tester) async {
      final debugDll = File('../../rust/target/debug/engine_ffi.dll');
      expect(debugDll.existsSync(), isTrue);

      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(debugDll.absolute.path),
        );
      });

      await tester.pumpWidget(const HyperDownloadApp());

      expect(find.text('Ping: pong'), findsOneWidget);
      expect(find.text('Engine Version: 0.1.0'), findsOneWidget);

      RustLib.dispose();
    },
  );

  test(
    'Flutter-to-Rust Release DLL responds to ping and engineVersion',
    () async {
      final releaseDll = File('../../rust/target/release/engine_ffi.dll');
      expect(releaseDll.existsSync(), isTrue);

      await RustLib.init(
        externalLibrary: ExternalLibrary.open(releaseDll.absolute.path),
      );

      expect(ping(), 'pong');
      expect(engineVersion(), '0.1.0');

      RustLib.dispose();
    },
  );
}
