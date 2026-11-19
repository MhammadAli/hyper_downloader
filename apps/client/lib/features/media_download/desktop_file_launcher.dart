import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Launches downloaded media files or opens their containing folder on desktop OSes.
abstract class DesktopFileLauncher {
  Future<bool> openFile(String path);

  Future<bool> revealInFolder(String path);
}

/// Default Windows implementation using native Shell APIs so paths with spaces,
/// brackets, or Unicode characters highlight reliably without falling back to Documents.
class WindowsDesktopFileLauncher implements DesktopFileLauncher {
  const WindowsDesktopFileLauncher();

  @override
  Future<bool> openFile(String path) async {
    if (!Platform.isWindows) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    final normalized = _normalizeWindowsPath(file.absolute.path);
    await Process.start('explorer.exe', [
      normalized,
    ], mode: ProcessStartMode.detached);
    return true;
  }

  @override
  Future<bool> revealInFolder(String path) async {
    if (!Platform.isWindows) return false;
    final file = File(path);
    if (await file.exists()) {
      final normalized = _normalizeWindowsPath(file.absolute.path);
      if (_revealFileViaShellApi(normalized)) {
        return true;
      }
      final parent = file.parent;
      if (await parent.exists()) {
        await Process.start('explorer.exe', [
          _normalizeWindowsPath(parent.absolute.path),
        ], mode: ProcessStartMode.detached);
        return true;
      }
      return false;
    }

    final directory = Directory(path);
    if (await directory.exists()) {
      await Process.start('explorer.exe', [
        _normalizeWindowsPath(directory.absolute.path),
      ], mode: ProcessStartMode.detached);
      return true;
    }

    final parent = file.parent;
    if (await parent.exists()) {
      await Process.start('explorer.exe', [
        _normalizeWindowsPath(parent.absolute.path),
      ], mode: ProcessStartMode.detached);
      return true;
    }
    return false;
  }
}

String _normalizeWindowsPath(String rawPath) =>
    rawPath.trim().replaceAll('/', '\\');

typedef _CoInitializeExNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CoInitializeExDart = int Function(Pointer<Void>, int);
typedef _CoUninitializeNative = Void Function();
typedef _CoUninitializeDart = void Function();

typedef _GetProcessHeapNative = Pointer<Void> Function();
typedef _GetProcessHeapDart = Pointer<Void> Function();
typedef _HeapAllocNative =
    Pointer<Uint16> Function(Pointer<Void>, Uint32, IntPtr);
typedef _HeapAllocDart = Pointer<Uint16> Function(Pointer<Void>, int, int);
typedef _HeapFreeNative = Int32 Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef _HeapFreeDart = int Function(Pointer<Void>, int, Pointer<Void>);

typedef _ILCreateFromPathWNative = Pointer<Void> Function(Pointer<Uint16>);
typedef _ILCreateFromPathWDart = Pointer<Void> Function(Pointer<Uint16>);
typedef _SHOpenFolderAndSelectItemsNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>, Uint32);
typedef _SHOpenFolderAndSelectItemsDart =
    int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int);
typedef _ILFreeNative = Void Function(Pointer<Void>);
typedef _ILFreeDart = void Function(Pointer<Void>);

bool _withWindowsShellPidl(
  String rawPath,
  bool Function(DynamicLibrary shell32, Pointer<Void> pidl) action,
) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final shell32 = DynamicLibrary.open('shell32.dll');
    final getProcessHeap = kernel32
        .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
          'GetProcessHeap',
        );
    final heapAlloc = kernel32.lookupFunction<_HeapAllocNative, _HeapAllocDart>(
      'HeapAlloc',
    );
    final heapFree = kernel32.lookupFunction<_HeapFreeNative, _HeapFreeDart>(
      'HeapFree',
    );
    final ilCreateFromPathW = shell32
        .lookupFunction<_ILCreateFromPathWNative, _ILCreateFromPathWDart>(
          'ILCreateFromPathW',
        );
    final ilFree = shell32.lookupFunction<_ILFreeNative, _ILFreeDart>('ILFree');

    final normalized = _normalizeWindowsPath(File(rawPath).absolute.path);
    final heap = getProcessHeap();
    final units = normalized.codeUnits;
    final utf16Ptr = heapAlloc(heap, 0, (units.length + 1) * 2);
    if (utf16Ptr == nullptr) return false;

    Pointer<Void> pidl = nullptr;
    try {
      final list = utf16Ptr.asTypedList(units.length + 1);
      for (var i = 0; i < units.length; i++) {
        list[i] = units[i];
      }
      list[units.length] = 0;
      pidl = ilCreateFromPathW(utf16Ptr);
      if (pidl == nullptr) return false;
      return action(shell32, pidl);
    } finally {
      if (pidl != nullptr) {
        ilFree(pidl);
      }
      heapFree(heap, 0, utf16Ptr.cast<Void>());
    }
  } catch (_) {
    return false;
  }
}

bool _revealFileViaShellApi(String windowsPath) {
  try {
    final ole32 = DynamicLibrary.open('ole32.dll');
    final coInitializeEx = ole32
        .lookupFunction<_CoInitializeExNative, _CoInitializeExDart>(
          'CoInitializeEx',
        );
    final coUninitialize = ole32
        .lookupFunction<_CoUninitializeNative, _CoUninitializeDart>(
          'CoUninitialize',
        );

    // COINIT_APARTMENTTHREADED (0x2); S_OK (0) / S_FALSE (1) require matching CoUninitialize.
    final coHr = coInitializeEx(nullptr, 0x2);
    final shouldUninit = coHr == 0 || coHr == 1;
    try {
      return _withWindowsShellPidl(windowsPath, (shell32, pidl) {
        final shOpenFolderAndSelectItems = shell32
            .lookupFunction<
              _SHOpenFolderAndSelectItemsNative,
              _SHOpenFolderAndSelectItemsDart
            >('SHOpenFolderAndSelectItems');
        return shOpenFolderAndSelectItems(pidl, 0, nullptr, 0) >= 0;
      });
    } finally {
      if (shouldUninit) {
        coUninitialize();
      }
    }
  } catch (_) {
    return false;
  }
}

/// Verifies on Windows that `ILCreateFromPathW` resolves a valid shell PIDL for `rawPath`
/// without opening an Explorer window (used by automated tests).
@visibleForTesting
bool canCreateShellItemIdListForFile(String rawPath) {
  if (!Platform.isWindows) return false;
  return _withWindowsShellPidl(rawPath, (_, _) => true);
}
