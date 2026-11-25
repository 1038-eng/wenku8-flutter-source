import Foundation

/// Shared import-format policy. Mirrors the Android/Dart limits so that
/// picking, inbox offers and folder scanning agree on what is importable.
enum BookImportFormatPolicy {
  /// Recognised book/document extensions (lower-cased, without the dot).
  static let extensions: Set<String> = [
    "txt", "text", "epub", "pdf", "zip", "mobi", "azw", "azw3", "prc",
    "fb2", "docx", "rtf", "html", "xhtml", "htm", "md", "markdown", "csv",
    "log", "nfo", "srt", "json",
  ]

  /// Text-like extensions that can be decoded directly to UTF-8.
  static let textExtensions: Set<String> = [
    "txt", "text", "html", "xhtml", "htm", "md", "markdown", "csv",
    "log", "nfo", "srt", "json",
  ]

  /// Per-file byte ceiling. Larger archives get a generous limit; a plain
  /// text file is capped tighter to avoid loading an entire disk into memory.
  static func byteLimit(_ rawExtension: String) -> Int {
    let ext = rawExtension.lowercased()
    switch ext {
    case "mobi", "azw", "azw3", "prc", "epub", "fb2", "docx", "rtf":
      return 512 * 1024 * 1024
    case "pdf", "zip":
      return 1024 * 1024 * 1024
    case "txt":
      return 128 * 1024 * 1024
    default:
      return 64 * 1024 * 1024
    }
  }

  static func isSupported(_ rawExtension: String) -> Bool {
    extensions.contains(rawExtension.lowercased())
  }

  static func isText(_ rawExtension: String) -> Bool {
    textExtensions.contains(rawExtension.lowercased())
  }
}
