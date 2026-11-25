/// Parsed representation of one `yt-dlp` stdout status line.
sealed class ParsedYtDlpLine {
  const ParsedYtDlpLine();
}

final class ParsedDownloadProgress extends ParsedYtDlpLine {
  final String status;
  final int downloadedBytes;
  final int? totalBytes;
  final bool isTotalEstimated;
  final double? speedBytesPerSec;
  final int? etaSeconds;

  const ParsedDownloadProgress({
    required this.status,
    required this.downloadedBytes,
    this.totalBytes,
    required this.isTotalEstimated,
    this.speedBytesPerSec,
    this.etaSeconds,
  });
}

final class ParsedPostprocessProgress extends ParsedYtDlpLine {
  final String status;
  final String postprocessor;

  const ParsedPostprocessProgress({
    required this.status,
    required this.postprocessor,
  });
}

final class ParsedStageStatus extends ParsedYtDlpLine {
  final String message;

  const ParsedStageStatus(this.message);
}

final class ParsedOutputPathDetected extends ParsedYtDlpLine {
  final String path;

  const ParsedOutputPathDetected(this.path);
}

final class ParsedOtherLine extends ParsedYtDlpLine {
  const ParsedOtherLine();
}

/// Parses structured progress and output path lines emitted by `yt-dlp`.
abstract final class YtDlpProgressParser {
  static ParsedYtDlpLine parseLine(String rawLine) {
    final line = rawLine.trim();
    if (line.startsWith('HYPERDL|')) {
      final parts = line.substring('HYPERDL|'.length).split('|');
      if (parts.length >= 6) {
        final status = parts[0].trim();
        final downloadedBytes = _parseOptionalInt(parts[1]) ?? 0;
        final exactTotal = _parseOptionalInt(parts[2]);
        final estimatedTotal = _parseOptionalInt(parts[3]);
        final (int? totalBytes, bool isEstimated) = switch ((
          exactTotal,
          estimatedTotal,
        )) {
          (final int t, _) => (t, false),
          (null, final int est) => (est, true),
          (null, null) => (null, false),
        };
        return ParsedDownloadProgress(
          status: status,
          downloadedBytes: downloadedBytes,
          totalBytes: totalBytes,
          isTotalEstimated: isEstimated,
          speedBytesPerSec: _parseOptionalDouble(parts[4]),
          etaSeconds: _parseOptionalInt(parts[5]),
        );
      }
    }

    if (line.startsWith('HYPERDL_PP|')) {
      final parts = line.substring('HYPERDL_PP|'.length).split('|');
      if (parts.length >= 2) {
        return ParsedPostprocessProgress(
          status: parts[0].trim(),
          postprocessor: parts[1].trim(),
        );
      }
    }

    const mergerPrefix = '[Merger] Merging formats into ';
    if (line.startsWith(mergerPrefix)) {
      var path = line.substring(mergerPrefix.length).trim();
      if (path.length >= 2 && path.startsWith('"') && path.endsWith('"')) {
        path = path.substring(1, path.length - 1);
      }
      if (path.isNotEmpty) return ParsedOutputPathDetected(path);
    }

    const destPrefix = '[download] Destination: ';
    if (line.startsWith(destPrefix)) {
      final path = line.substring(destPrefix.length).trim();
      if (path.isNotEmpty) return ParsedOutputPathDetected(path);
    }

    const dlPrefix = '[download] ';
    const alreadySuffix = ' has already been downloaded';
    if (line.startsWith(dlPrefix) && line.endsWith(alreadySuffix)) {
      final cleaned = line
          .substring(dlPrefix.length, line.length - alreadySuffix.length)
          .trim();
      if (cleaned.isNotEmpty) return ParsedOutputPathDetected(cleaned);
    }

    if (line.startsWith('[Instagram] Setting up session')) {
      return const ParsedStageStatus('Connecting to Instagram...');
    }
    if (line.startsWith('[Instagram] ')) {
      return const ParsedStageStatus('Resolving media...');
    }
    if (line.startsWith('[info] ') &&
        line.contains('Downloading') &&
        line.contains('format(s)')) {
      return const ParsedStageStatus('Resolving media...');
    }

    return const ParsedOtherLine();
  }

  static int? _parseOptionalInt(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();
    if (lower == 'na' || lower == 'none') return null;

    final intVal = int.tryParse(trimmed);
    if (intVal != null && intVal >= 0) return intVal;

    final doubleVal = double.tryParse(trimmed);
    if (doubleVal != null && doubleVal.isFinite && doubleVal >= 0) {
      return doubleVal.round();
    }
    return null;
  }

  static double? _parseOptionalDouble(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();
    if (lower == 'na' || lower == 'none') return null;

    final val = double.tryParse(trimmed);
    return (val != null && val.isFinite) ? val : null;
  }
}
