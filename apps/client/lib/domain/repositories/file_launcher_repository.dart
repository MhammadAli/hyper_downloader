/// Contract for opening completed files, revealing folders, and sharing files.
abstract interface class FileLauncherRepository {
  Future<bool> openFile(String path);

  Future<bool> revealInFolder(String path);

  Future<bool> shareFile(String path);
}
