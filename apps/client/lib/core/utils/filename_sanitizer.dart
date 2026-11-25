import 'dart:collection';

const int _maxWindowsReservedCheck = 4;

/// Sanitizes titles, playlist names, and file stems safely for Windows/Android
/// filesystems while preserving Unicode (including Arabic) intact.
abstract final class FilenameSanitizer {
  static const Set<String> _reservedWindowsDevices = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  /// Mirrors Rust `sanitize_windows_filename`: collapses forbidden/control/whitespace
  /// characters to single spaces, trims spaces/dots, truncates to [maxChars] runes,
  /// falls back to `'Untitled'`, and escapes Windows reserved device names.
  static String sanitizeWindowsFilename(String raw, int maxChars) {
    final buffer = StringBuffer();
    var prevSpace = true;

    for (final rune in raw.runes) {
      final ch = String.fromCharCode(rune);
      final isForbidden =
          ch == '<' ||
          ch == '>' ||
          ch == ':' ||
          ch == '"' ||
          ch == '/' ||
          ch == r'\' ||
          ch == '|' ||
          ch == '?' ||
          ch == '*' ||
          _isControl(rune);
      final isWhitespace = _isWhitespace(rune);

      if (isForbidden || isWhitespace) {
        if (!prevSpace) {
          buffer.write(' ');
          prevSpace = true;
        }
      } else {
        buffer.write(ch);
        prevSpace = false;
      }
    }

    var trimmed = _trimSpaceAndDot(buffer.toString());
    if (trimmed.runes.length > maxChars) {
      trimmed = String.fromCharCodes(trimmed.runes.take(maxChars));
      trimmed = _trimSpaceAndDot(trimmed);
    }

    if (trimmed.isEmpty) {
      trimmed = 'Untitled';
    }

    final upper = trimmed.toUpperCase();
    if (upper.length <= _maxWindowsReservedCheck &&
        _reservedWindowsDevices.contains(upper)) {
      return '_$trimmed';
    }
    return trimmed;
  }

  /// Computes `<sanitized_title> [<sanitized_id>]`.
  static String playlistFolderName(String playlistTitle, String playlistId) {
    final safeTitle = sanitizeWindowsFilename(playlistTitle, 72);
    final safeId = sanitizeWindowsFilename(playlistId, 48);
    return '$safeTitle [$safeId]';
  }

  /// Builds a collision-free numeric-prefixed file stem (`001 - Title`, `001 - Title (2)`).
  static String formatOrderedFilenameStem(
    int orderIndex,
    int totalCount,
    String title,
    Set<String> usedLowerStems,
  ) {
    final effectiveTotal = totalCount < 1 ? 1 : totalCount;
    final width = effectiveTotal.toString().length.clamp(3, 12);
    final safeTitle = sanitizeWindowsFilename(title, 90);
    final prefix = (orderIndex + 1).toString().padLeft(width, '0');
    final baseStem = '$prefix - $safeTitle';

    if (usedLowerStems.add(baseStem.toLowerCase())) {
      return baseStem;
    }

    var suffix = 2;
    while (true) {
      final candidate = '$baseStem ($suffix)';
      if (usedLowerStems.add(candidate.toLowerCase())) {
        return candidate;
      }
      suffix++;
    }
  }

  /// Computes deterministic ordered stems for a list of `(orderIndex, title)` pairs.
  static List<String> computeStemsForItems(
    List<({int orderIndex, String title})> items,
  ) {
    final total = items.length;
    final used = HashSet<String>();
    return items
        .map(
          (item) => formatOrderedFilenameStem(
            item.orderIndex,
            total,
            item.title,
            used,
          ),
        )
        .toList(growable: false);
  }

  static String _trimSpaceAndDot(String value) {
    var start = 0;
    var end = value.length;
    while (start < end && (value[start] == ' ' || value[start] == '.')) {
      start++;
    }
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '.')) {
      end--;
    }
    return value.substring(start, end);
  }

  static bool _isControl(int rune) =>
      (rune >= 0x00 && rune <= 0x1F) || (rune >= 0x7F && rune <= 0x9F);

  static bool _isWhitespace(int rune) {
    if (rune == 0x20 ||
        rune == 0x09 ||
        rune == 0x0A ||
        rune == 0x0B ||
        rune == 0x0C ||
        rune == 0x0D) {
      return true;
    }
    return rune == 0x00A0 ||
        rune == 0x1680 ||
        (rune >= 0x2000 && rune <= 0x200A) ||
        rune == 0x2028 ||
        rune == 0x2029 ||
        rune == 0x202F ||
        rune == 0x205F ||
        rune == 0x3000;
  }
}
