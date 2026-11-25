import 'dart:ffi';
import 'dart:io';

import 'package:hyper_download_client/core/error/app_exception.dart';

typedef _GetProcessHeapNative = Pointer<Void> Function();
typedef _GetProcessHeapDart = Pointer<Void> Function();
typedef _HeapAllocNative = Pointer<Uint8> Function(Pointer<Void>, Uint32, IntPtr);
typedef _HeapAllocDart = Pointer<Uint8> Function(Pointer<Void>, int, int);
typedef _HeapFreeNative = Int32 Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef _HeapFreeDart = int Function(Pointer<Void>, int, Pointer<Void>);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void>);
typedef _CoTaskMemFreeDart = void Function(Pointer<Void>);
typedef _SHGetKnownFolderPathNative =
    Int32 Function(
      Pointer<Uint8>,
      Uint32,
      Pointer<Void>,
      Pointer<Pointer<Uint16>>,
    );
typedef _SHGetKnownFolderPathDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Void>,
      Pointer<Pointer<Uint16>>,
    );

/// Resolved external tool executable paths and default download directories for Windows.
class WindowsToolPaths {
  static const String appDownloadFolderName = 'HyperDownload';
  static const String videoSubfolderName = 'Videos';
  static const String audioSubfolderName = 'Audios';

  final String ytDlpExe;
  final String ffmpegExe;
  final String nodeExe;
  final String defaultOutputDir;

  const WindowsToolPaths({
    required this.ytDlpExe,
    required this.ffmpegExe,
    required this.nodeExe,
    required this.defaultOutputDir,
  });

  String get ffmpegDir => File(ffmpegExe).parent.path;

  static Directory mediaSubfolder(Directory root, {required bool isAudioOnly}) {
    final sep = Platform.pathSeparator;
    final sub = isAudioOnly ? audioSubfolderName : videoSubfolderName;
    return Directory('${root.path}$sep$sub');
  }

  static WindowsToolPaths resolve() {
    final roots = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    return resolveFrom(roots, Platform.environment);
  }

  static WindowsToolPaths resolveFrom(
    List<Directory> searchRoots,
    Map<String, String> env,
  ) {
    final protoRoots = _collectPrototypeRoots(searchRoots);
    final sep = Platform.pathSeparator;
    final ytDlpName = Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
    final ffmpegName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final nodeName = Platform.isWindows ? 'node.exe' : 'node';
    final pathVar = env['PATH'] ?? env['Path'];

    final ytDlpExe = _resolveBinary(
      tool: 'yt-dlp',
      explicitOverride: env['HYPERDL_YTDLP_PATH'],
      candidates: protoRoots
          .map((r) => '${r.path}${sep}bin$sep$ytDlpName')
          .toList(growable: false),
      pathVar: pathVar,
      exeName: ytDlpName,
    );

    final ffmpegExe = _resolveBinary(
      tool: 'ffmpeg',
      explicitOverride: env['HYPERDL_FFMPEG_PATH'],
      candidates: protoRoots
          .map((r) => '${r.path}${sep}bin$sep$ffmpegName')
          .toList(growable: false),
      pathVar: pathVar,
      exeName: ffmpegName,
    );

    final nodeCandidates = <String>[
      ...protoRoots.map((r) => '${r.path}${sep}bin$sep$nodeName'),
      if (Platform.isWindows) ...[
        r'C:\Program Files\nodejs\node.exe',
        r'C:\Program Files (x86)\nodejs\node.exe',
      ],
    ];
    final nodeExe = _resolveBinary(
      tool: 'node',
      explicitOverride: env['HYPERDL_NODE_PATH'],
      candidates: nodeCandidates,
      pathVar: pathVar,
      exeName: nodeName,
    );

    final envOut = env['HYPERDL_OUTPUT_DIR']?.trim();
    final defaultOutputDir = (envOut != null && envOut.isNotEmpty)
        ? envOut
        : (_defaultWindowsDownloadRoot(env) ??
              (protoRoots.isNotEmpty
                  ? '${protoRoots.first.path}${sep}output${sep}app_downloads'
                  : (searchRoots.isNotEmpty
                        ? '${searchRoots.first.path}${sep}downloads'
                        : 'downloads')));

    return WindowsToolPaths(
      ytDlpExe: ytDlpExe,
      ffmpegExe: ffmpegExe,
      nodeExe: nodeExe,
      defaultOutputDir: defaultOutputDir,
    );
  }

  static List<Directory> _collectPrototypeRoots(List<Directory> searchRoots) {
    final found = <Directory>[];
    final seen = <String>{};
    final sep = Platform.pathSeparator;

    for (final root in searchRoots) {
      var current = root.absolute;
      for (var depth = 0; depth < 12; depth++) {
        final candidate = Directory(
          '${current.path}${sep}tools${sep}windows_media_prototype',
        );
        if (candidate.existsSync() && seen.add(candidate.path)) {
          found.add(candidate);
        }
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
    }
    return found;
  }

  static String _resolveBinary({
    required String tool,
    required String? explicitOverride,
    required List<String> candidates,
    required String? pathVar,
    required String exeName,
  }) {
    final overrideTrimmed = explicitOverride?.trim();
    if (overrideTrimmed != null && overrideTrimmed.isNotEmpty) {
      if (File(overrideTrimmed).existsSync()) {
        return overrideTrimmed;
      }
      throw ToolUnavailableException(tool: tool, searched: overrideTrimmed);
    }

    final searched = <String>[];
    for (final candidate in candidates) {
      searched.add(candidate);
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    if (pathVar != null && pathVar.isNotEmpty) {
      final pathSep = Platform.isWindows ? ';' : ':';
      final sep = Platform.pathSeparator;
      for (final entry in pathVar.split(pathSep)) {
        final cleaned = entry.trim();
        if (cleaned.isEmpty) continue;
        final candidate = '$cleaned$sep$exeName';
        if (File(candidate).existsSync()) {
          return candidate;
        }
      }
      searched.add('PATH ($exeName)');
    }

    throw ToolUnavailableException(tool: tool, searched: searched.join('; '));
  }

  static String? _defaultWindowsDownloadRoot(Map<String, String> env) {
    if (!Platform.isWindows) return null;
    final videos =
        _windowsVideosKnownFolder() ??
        (env['USERPROFILE'] != null
            ? '${env['USERPROFILE']}\\Videos'
            : null);
    if (videos == null || videos.isEmpty) return null;
    return '$videos\\$appDownloadFolderName';
  }

  /// Queries `SHGetKnownFolderPath(FOLDERID_Videos)` using `shell32.dll` + `ole32.dll`.
  static String? _windowsVideosKnownFolder() {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final shell32 = DynamicLibrary.open('shell32.dll');
      final ole32 = DynamicLibrary.open('ole32.dll');

      final getProcessHeap = kernel32
          .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
            'GetProcessHeap',
          );
      final heapAlloc = kernel32
          .lookupFunction<_HeapAllocNative, _HeapAllocDart>('HeapAlloc');
      final heapFree = kernel32
          .lookupFunction<_HeapFreeNative, _HeapFreeDart>('HeapFree');
      final shGetKnownFolderPath = shell32
          .lookupFunction<
            _SHGetKnownFolderPathNative,
            _SHGetKnownFolderPathDart
          >('SHGetKnownFolderPath');
      final coTaskMemFree = ole32
          .lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>(
            'CoTaskMemFree',
          );

      // FOLDERID_Videos = {18989B1D-99B5-455B-841C-AB7C74E4DDFC}
      const guidBytes = <int>[
        0x1D, 0x9B, 0x98, 0x18, // Data1 LE
        0xB5, 0x99, // Data2 LE
        0x5B, 0x45, // Data3 LE
        0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC, // Data4
      ];

      final heap = getProcessHeap();
      final guidPtr = heapAlloc(heap, 0x08, 16);
      final outPtrAddr = heapAlloc(heap, 0x08, sizeOf<IntPtr>());
      if (guidPtr == nullptr || outPtrAddr == nullptr) {
        if (guidPtr != nullptr) heapFree(heap, 0, guidPtr.cast());
        if (outPtrAddr != nullptr) heapFree(heap, 0, outPtrAddr.cast());
        return null;
      }

      try {
        guidPtr.asTypedList(16).setAll(0, guidBytes);
        final outPtr = outPtrAddr.cast<Pointer<Uint16>>();
        final hr = shGetKnownFolderPath(guidPtr, 0, nullptr, outPtr);
        final strPtr = outPtr.value;
        try {
          if (hr == 0 && strPtr != nullptr) {
            final units = <int>[];
            for (var i = 0; i < 32768; i++) {
              final unit = strPtr[i];
              if (unit == 0) break;
              units.add(unit);
            }
            if (units.isNotEmpty) {
              return String.fromCharCodes(units);
            }
          }
          return null;
        } finally {
          if (strPtr != nullptr) {
            coTaskMemFree(strPtr.cast());
          }
        }
      } finally {
        heapFree(heap, 0, guidPtr.cast());
        heapFree(heap, 0, outPtrAddr.cast());
      }
    } catch (_) {
      return null;
    }
  }
}
