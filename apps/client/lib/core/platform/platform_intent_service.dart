import 'dart:async';

import 'package:flutter/services.dart';

/// Bridges OS share intents (e.g. Android `ACTION_SEND`) into the Flutter app.
class PlatformIntentService {
  static const MethodChannel _defaultChannel = MethodChannel(
    'com.hyperdownload/platform_intents',
  );

  final Future<String?> Function()? _getInitialSharedUrlOverride;
  final Stream<String>? _sharedUrlsOverride;
  final MethodChannel _channel;
  StreamController<String>? _controller;
  bool _handlerInstalled = false;

  PlatformIntentService({
    MethodChannel? channel,
    Future<String?> Function()? getInitialSharedUrl,
    Stream<String>? sharedUrls,
  }) : _channel = channel ?? _defaultChannel,
       _getInitialSharedUrlOverride = getInitialSharedUrl,
       _sharedUrlsOverride = sharedUrls;

  Future<String?> consumeInitialSharedUrl() async {
    final override = _getInitialSharedUrlOverride;
    if (override != null) {
      return override();
    }
    try {
      return await _channel.invokeMethod<String>('consumeInitialSharedUrl');
    } catch (_) {
      return null;
    }
  }

  Stream<String> watchSharedUrls() {
    final override = _sharedUrlsOverride;
    if (override != null) {
      return override;
    }
    _controller ??= StreamController<String>.broadcast();
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onSharedUrl') {
          final raw = call.arguments as String?;
          if (raw != null && raw.trim().isNotEmpty) {
            _controller?.add(raw.trim());
          }
        }
      });
    }
    return _controller!.stream;
  }

  Future<void> dispose() async {
    await _controller?.close();
    _controller = null;
  }
}
