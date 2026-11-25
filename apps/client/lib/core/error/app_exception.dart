/// Typed application exceptions with clean user-facing messages.
sealed class AppException implements Exception {
  final String message;

  const AppException(this.message);

  @override
  String toString() => message;
}

/// Thrown when a URL fails syntax validation or targets an unsupported route.
final class InvalidUrlException extends AppException {
  const InvalidUrlException(super.message);
}

/// Thrown when an external tool (`yt-dlp`, `ffmpeg`, `node`) cannot be located.
final class ToolUnavailableException extends AppException {
  final String tool;
  final String searched;

  const ToolUnavailableException({
    required this.tool,
    required this.searched,
  }) : super("Required tool '$tool' could not be found (searched: $searched)");
}

/// Thrown when an external extraction or download process fails.
final class ProcessExecutionException extends AppException {
  final int? exitCode;

  const ProcessExecutionException(super.message, {this.exitCode});
}

/// Thrown when extractor JSON or manifest payloads cannot be parsed.
final class ParseException extends AppException {
  const ParseException(super.message);
}

/// Thrown when an incompatible download or playlist operation is already active.
final class DownloadBusyException extends AppException {
  const DownloadBusyException(super.message);
}

/// Thrown when a requested job or playlist session ID does not exist.
final class JobNotFoundException extends AppException {
  const JobNotFoundException(super.message);
}
