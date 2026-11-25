import 'dart:ffi';
import 'dart:io';

typedef _CreateJobObjectWNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>);
typedef _CreateJobObjectWDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>);
typedef _SetInformationJobObjectNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32);
typedef _SetInformationJobObjectDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int);
typedef _OpenProcessNative = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = Pointer<Void> Function(int, int, int);
typedef _AssignProcessToJobObjectNative =
    Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _AssignProcessToJobObjectDart =
    int Function(Pointer<Void>, Pointer<Void>);
typedef _TerminateJobObjectNative = Int32 Function(Pointer<Void>, Uint32);
typedef _TerminateJobObjectDart = int Function(Pointer<Void>, int);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);
typedef _GetProcessHeapNative = Pointer<Void> Function();
typedef _GetProcessHeapDart = Pointer<Void> Function();
typedef _HeapAllocNative = Pointer<Uint8> Function(Pointer<Void>, Uint32, IntPtr);
typedef _HeapAllocDart = Pointer<Uint8> Function(Pointer<Void>, int, int);
typedef _HeapFreeNative = Int32 Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef _HeapFreeDart = int Function(Pointer<Void>, int, Pointer<Void>);

/// Supervises a spawned process and all child processes (`ffmpeg.exe`, `node.exe`)
/// using a Win32 Job Object on Windows so canceling terminates the full tree.
class ProcessTreeHandle {
  static const int _jobObjectExtendedLimitInformation = 9;
  static const int _jobObjectLimitKillOnJobClose = 0x00002000;
  static const int _processSetQuotaAndTerminate = 0x0101;
  static const int _extendedInfoSizeBytes = 144;
  static const int _limitFlagsByteOffset = 16;

  final Process _process;
  Pointer<Void>? _jobHandle;
  bool _disposed = false;

  ProcessTreeHandle._(this._process, this._jobHandle);

  static ProcessTreeHandle attach(Process process) {
    if (!Platform.isWindows) {
      return ProcessTreeHandle._(process, null);
    }

    Pointer<Void>? jobHandle;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final createJobObjectW = kernel32
          .lookupFunction<_CreateJobObjectWNative, _CreateJobObjectWDart>(
            'CreateJobObjectW',
          );
      final setInformationJobObject = kernel32
          .lookupFunction<
            _SetInformationJobObjectNative,
            _SetInformationJobObjectDart
          >('SetInformationJobObject');
      final openProcess = kernel32
          .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
      final assignProcessToJobObject = kernel32
          .lookupFunction<
            _AssignProcessToJobObjectNative,
            _AssignProcessToJobObjectDart
          >('AssignProcessToJobObject');
      final closeHandle = kernel32
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
      final getProcessHeap = kernel32
          .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
            'GetProcessHeap',
          );
      final heapAlloc = kernel32
          .lookupFunction<_HeapAllocNative, _HeapAllocDart>('HeapAlloc');
      final heapFree = kernel32
          .lookupFunction<_HeapFreeNative, _HeapFreeDart>('HeapFree');

      final job = createJobObjectW(nullptr, nullptr);
      if (job == nullptr) {
        return ProcessTreeHandle._(process, null);
      }

      final heap = getProcessHeap();
      final infoBuf = heapAlloc(heap, 0x08, _extendedInfoSizeBytes);
      if (infoBuf == nullptr) {
        closeHandle(job);
        return ProcessTreeHandle._(process, null);
      }

      var configured = false;
      try {
        infoBuf.cast<Uint32>()[_limitFlagsByteOffset ~/ 4] =
            _jobObjectLimitKillOnJobClose;
        configured =
            setInformationJobObject(
              job,
              _jobObjectExtendedLimitInformation,
              infoBuf.cast(),
              _extendedInfoSizeBytes,
            ) !=
            0;
      } finally {
        heapFree(heap, 0, infoBuf.cast());
      }

      if (!configured) {
        closeHandle(job);
        return ProcessTreeHandle._(process, null);
      }

      final procHandle = openProcess(
        _processSetQuotaAndTerminate,
        0,
        process.pid,
      );
      if (procHandle != nullptr) {
        try {
          final assigned = assignProcessToJobObject(job, procHandle) != 0;
          if (assigned) {
            jobHandle = job;
          } else {
            closeHandle(job);
          }
        } finally {
          closeHandle(procHandle);
        }
      } else {
        closeHandle(job);
      }
    } catch (_) {
      jobHandle = null;
    }

    return ProcessTreeHandle._(process, jobHandle);
  }

  /// Terminates the supervised process and all descendant processes.
  Future<void> terminate() async {
    if (_disposed) return;
    _disposed = true;

    var terminatedByJob = false;
    final job = _jobHandle;
    _jobHandle = null;

    if (Platform.isWindows && job != null && job != nullptr) {
      try {
        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final terminateJobObject = kernel32
            .lookupFunction<
              _TerminateJobObjectNative,
              _TerminateJobObjectDart
            >('TerminateJobObject');
        final closeHandle = kernel32
            .lookupFunction<_CloseHandleNative, _CloseHandleDart>(
              'CloseHandle',
            );
        terminatedByJob = terminateJobObject(job, 1) != 0;
        closeHandle(job);
      } catch (_) {}
    }

    if (!terminatedByJob && Platform.isWindows) {
      try {
        await Process.run('taskkill.exe', [
          '/F',
          '/T',
          '/PID',
          '${_process.pid}',
        ], runInShell: false);
      } catch (_) {}
    }

    try {
      _process.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }

  /// Releases the Win32 Job Object handle once the process has exited naturally.
  void close() {
    if (_disposed) return;
    _disposed = true;
    final job = _jobHandle;
    _jobHandle = null;
    if (Platform.isWindows && job != null && job != nullptr) {
      try {
        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final closeHandle = kernel32
            .lookupFunction<_CloseHandleNative, _CloseHandleDart>(
              'CloseHandle',
            );
        closeHandle(job);
      } catch (_) {}
    }
  }
}
