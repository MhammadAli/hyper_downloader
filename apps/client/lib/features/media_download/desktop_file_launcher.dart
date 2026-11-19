import 'dart:io';

/// Launches downloaded media files or opens their containing folder on desktop OSes.
abstract class DesktopFileLauncher {
  Future<bool> openFile(String path);

  Future<bool> revealInFolder(String path);
}

/// Default Windows implementation invoking `explorer.exe` cleanly without shell quoting issues.
class WindowsDesktopFileLauncher implements DesktopFileLauncher {
  const WindowsDesktopFileLauncher();

  @override
  Future<bool> openFile(String path) async {
    if (!Platform.isWindows) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    await Process.start('explorer.exe', [
      path,
    ], mode: ProcessStartMode.detached);
    return true;
  }

  @override
  Future<bool> revealInFolder(String path) async {
    if (!Platform.isWindows) return false;
    final file = File(path);
    if (await file.exists()) {
      await Process.start('explorer.exe', [
        '/select,$path',
      ], mode: ProcessStartMode.detached);
      return true;
    }
    final directory = Directory(path);
    if (await directory.exists()) {
      await Process.start('explorer.exe', [
        path,
      ], mode: ProcessStartMode.detached);
      return true;
    }
    final parent = file.parent;
    if (await parent.exists()) {
      await Process.start('explorer.exe', [
        parent.path,
      ], mode: ProcessStartMode.detached);
      return true;
    }
    return false;
  }
}
