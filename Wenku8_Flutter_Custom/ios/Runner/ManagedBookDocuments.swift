import Foundation
import CoreFoundation
import Darwin

struct BookDocumentFailure: LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { message }
}

/// Owns only working copies. Provider URLs and original user files never enter
/// the deletion set. Copies and text conversion use bounded streaming buffers.
final class ManagedBookDocuments {
  private static let processRun = UUID()
  private static let ownershipAttribute = "org.mewx.wenku8.import-work-v1"
  let root: URL
  private let files: FileManager
  private let readableRoots: [URL]
  private let runIdentifier: UUID
  private var owned = Set<String>()

  init(root: URL, readableRoots: [URL] = [], files: FileManager = .default,
    runIdentifier: UUID? = nil) throws {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.files = files
    self.readableRoots = readableRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    self.runIdentifier = runIdentifier ?? Self.processRun
    try files.createDirectory(at: self.root, withIntermediateDirectories: true)
    var excluded = self.root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
    reclaimAbandonedCopies()
  }

  func copy(_ source: URL, maximumBytes: Int, kind: String = "import") throws -> URL {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    return try copy(input, maximumBytes: maximumBytes, kind: kind)
  }

  func copy(_ input: FileHandle, maximumBytes: Int, kind: String = "import") throws -> URL {
    let output = try allocate(kind: kind, extension: "source")
    do {
      let sink = try FileHandle(forWritingTo: output)
      defer { try? sink.close() }
      var total = 0
      while case let bytes = try read(input, count: 262144), !bytes.isEmpty {
        total += bytes.count
        guard total <= maximumBytes else {
          throw BookDocumentFailure(code: "file_too_large", message: "文件超过此格式的导入大小限制")
        }
        try write(bytes, to: sink)
      }
      return output
    } catch {
      _ = try? release(output.path)
      throw error
    }
  }

  func create(_ data: Data, name: String, preserveName: Bool = false) throws -> URL {
    let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters))
      .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    let safe = String((cleaned.isEmpty ? "文库导出" : cleaned).prefix(100))
    let filename = URL(fileURLWithPath: safe)
    let suffix = filename.pathExtension.isEmpty ? "data" : filename.pathExtension
    let stem = filename.deletingPathExtension().lastPathComponent
    let output = preserveName
      ? try allocateFile(filename: "\(stem).\(suffix)")
      : try allocate(kind: stem, extension: suffix)
    do {
      let sink = try FileHandle(forWritingTo: output)
      defer { try? sink.close() }
      try write(data, to: sink)
      return output
    } catch {
      _ = try? release(output.path)
      throw error
    }
  }

  @discardableResult
  func release(_ path: String) throws -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard owned.contains(url.path), url.deletingLastPathComponent().path == root.path else { return false }
    if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    owned.remove(url.path)
    return true
  }

  static func decodeBookNames(_ values: [Data]) throws -> [String] {
    guard values.count <= 64, values.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else {
      throw BookDocumentFailure(code: "zip_name", message: "ZIP 文件名数据无效")
    }
    let encodings: [String.Encoding] = [.utf8,
      String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
      String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))]
    return try values.map { data in
      for encoding in encodings { if let name = String(data: data, encoding: encoding) { return name } }
      throw BookDocumentFailure(code: "zip_name", message: "无法识别 ZIP 文件名编码，请使用 UTF-8 文件名重新压缩")
    }
  }

  func decodeTextFile(_ path: String, encoding: String,
    maximumBytes: Int = 128 * 1024 * 1024,
    maximumOutputBytes: Int = 384 * 1024 * 1024) throws -> URL {
    guard maximumBytes > 0, maximumBytes <= 1024 * 1024 * 1024,
      maximumOutputBytes > 0, maximumOutputBytes <= 1024 * 1024 * 1024 else {
      throw BookDocumentFailure(code: "file_limit", message: "文档转换大小限制无效")
    }
    let source = try readableSourceURL(path)
    let prefix = try {
      let handle = try FileHandle(forReadingFrom: source)
      defer { try? handle.close() }
      return try read(handle, count: 65536)
    }()
    let selected = try Self.resolveEncoding(encoding, sample: prefix)

    // Records how many input bytes were consumed before a decode failure, so a
    // retry can sample near the *actual* non-UTF-8 region instead of guessing.
    var readThrough = 0
    func convert(with name: String) throws -> URL {
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      guard let converter = iconv_open("UTF-8", name), converter != OpaquePointer(bitPattern: -1) else {
        throw BookDocumentFailure(code: "text_encoding", message: "系统不支持所选文字编码，请改用其他编码")
      }
      defer { iconv_close(converter) }
      let output = try allocate(kind: "decoded", extension: "txt")
      do {
        let sink = try FileHandle(forWritingTo: output)
        defer { try? sink.close() }
        var pending = Data(), total = 0, produced = 0
        while case let chunk = try read(input, count: 65536), !chunk.isEmpty {
          total += chunk.count
          readThrough = total
          guard total <= maximumBytes else {
            throw BookDocumentFailure(code: "file_too_large", message: "文本超过转换大小限制，请拆分后导入")
          }
          pending.append(chunk)
          var consumed = 0
          try pending.withUnsafeMutableBytes { raw in
            var pointer = raw.baseAddress?.assumingMemoryBound(to: Int8.self)
            var remaining = raw.count
            while remaining > 0 {
              var bytes = [Int8](repeating: 0, count: 65536)
              var available = bytes.count
              let result = bytes.withUnsafeMutableBufferPointer { destination -> Int in
                var next = destination.baseAddress
                return iconv(converter, &pointer, &remaining, &next, &available)
              }
              let conversionError = errno
              if available < bytes.count {
                produced += bytes.count - available
                guard produced <= maximumOutputBytes else {
                  throw BookDocumentFailure(code: "file_too_large", message: "解码后的文档超过大小限制，请拆分后导入")
                }
                try bytes.withUnsafeBytes { buffer in
                  try write(Data(buffer.prefix(bytes.count - available)), to: sink)
                }
              }
              if result == -1 {
                if conversionError == E2BIG { continue }
                if conversionError == EINVAL { break } // A multibyte character crosses the next chunk.
                throw BookDocumentFailure(code: "text_encoding", message: "文字编码不匹配，正在自动尝试其他编码")
              }
            }
            consumed = raw.count - remaining
          }
          pending.removeFirst(consumed)
        }
        guard pending.isEmpty else {
          throw BookDocumentFailure(code: "text_encoding", message: "文本末尾存在不完整字符，正在自动尝试其他编码")
        }
        return output
      } catch {
        _ = try? release(output.path)
        throw error
      }
    }

    do {
      return try convert(with: selected)
    } catch {
      // Two-pass decode, mirroring Android's BookTextDecoder.normalize: when
      // an auto-detected UTF-8 file fails mid-way, sample near the failing
      // offset, detect the real legacy encoding, and decode once more.
      guard encoding == "auto", selected == "UTF-8",
        let failure = error as? BookDocumentFailure, failure.code == "text_encoding" else {
        throw error
      }
      let retry = try {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let start = max(0, readThrough - 16 * 1024)
        try handle.seek(toOffset: UInt64(start))
        return try read(handle, count: 65536)
      }()
      let fallback = Self.legacyEncoding(for: retry)
      guard fallback.caseInsensitiveCompare(selected) != .orderedSame else { throw error }
      return try convert(with: fallback)
    }
  }

  func readableSourceURL(_ path: String) throws -> URL {
    let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard owned.contains(source.path) || readableRoots.contains(where: {
      source.path.hasPrefix($0.path + "/")
    }) else {
      throw BookDocumentFailure(code: "unowned_document", message: "导入文件的访问授权已失效，请重新选择")
    }
    return source
  }

  // POSIX-backed bounded reads/writes also work on iOS 13.0–13.3, where the
  // throwing FileHandle convenience methods are unavailable.
  private func read(_ handle: FileHandle, count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var length: Int
    repeat { length = Darwin.read(handle.fileDescriptor, &bytes, count) } while length < 0 && errno == EINTR
    guard length >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return Data(bytes.prefix(length))
  }

  private func write(_ bytes: Data, to handle: FileHandle) throws {
    try bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let count = Darwin.write(handle.fileDescriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        offset += count
      }
    }
  }

  private func allocate(kind: String, extension suffix: String) throws -> URL {
    try allocateFile(filename: "\(kind)-\(UUID().uuidString).\(suffix)")
  }

  private func allocateFile(filename: String) throws -> URL {
    let url = root.appendingPathComponent(filename)
    // A user-facing export keeps its proposed name. Reserve it exclusively;
    // another active export, unmarked file or symlink must never be replaced.
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { Darwin.close(descriptor) }
    owned.insert(url.standardizedFileURL.resolvingSymlinksInPath().path)
    do {
      // Persist ownership before writing any book bytes. A new process may
      // reclaim this copy; another engine in the same process must leave it.
      let marker = Data(runIdentifier.uuidString.utf8)
      let status = marker.withUnsafeBytes { bytes in
        fsetxattr(descriptor, Self.ownershipAttribute, bytes.baseAddress, bytes.count, 0, 0)
      }
      guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    } catch {
      _ = try? release(url.path)
      throw error
    }
    return url
  }

  private func reclaimAbandonedCopies() {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let candidates = try? files.contentsOfDirectory(at: root,
      includingPropertiesForKeys: Array(keys)) else { return }
    for candidate in candidates {
      guard let values = try? candidate.resourceValues(forKeys: keys),
        values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      // No filename/age heuristic and no recursive deletion. Older unmarked
      // files, provider URLs and other owners' directories remain untouched.
      var marker = [UInt8](repeating: 0, count: 36)
      let length = marker.withUnsafeMutableBytes { bytes in
        getxattr(candidate.path, Self.ownershipAttribute, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
      }
      guard length == marker.count,
        let text = String(bytes: marker, encoding: .utf8),
        let previous = UUID(uuidString: text), previous != runIdentifier else { continue }
      // Failure leaves its ownership marker available for the next opening;
      // it must not make an otherwise usable import fail at startup.
      try? files.removeItem(at: candidate)
    }
  }

  static let supportedTextEncodings = ["UTF-8", "GB18030", "Big5", "Big5-HKSCS", "UTF-16LE", "UTF-16BE",
    "SHIFT_JIS", "CP932", "EUC-JP", "KOI8-R", "ISO-8859-1",
    "WINDOWS-1250", "WINDOWS-1251", "WINDOWS-1252", "WINDOWS-1253", "WINDOWS-1254",
    "WINDOWS-1255", "WINDOWS-1256", "WINDOWS-1257", "WINDOWS-1258"]

  /// Strictly checks whether `sample` is well-formed in the given encoding.
  /// `allowTrailingPartial` tolerates a truncated multibyte character in the
  /// final 3 bytes (a normal boundary when reading a fixed-size chunk).
  static func isWellFormed(_ sample: Data, encoding: String, allowTrailingPartial: Bool) -> Bool {
    guard let converted = iconv_open("UTF-8", encoding), converted != OpaquePointer(bitPattern: -1) else {
      return false
    }
    defer { iconv_close(converted) }
    // iconv mutates inbuf through a pointer-to-pointer, so the sample must be
    // exposed with a MUTABLE buffer; withUnsafeBytes would yield an immutable
    // UnsafePointer and fail to compile.
    var mutable = sample
    return mutable.withUnsafeMutableBytes { raw -> Bool in
      var pointer = raw.baseAddress?.assumingMemoryBound(to: Int8.self)
      var remaining = raw.count
      while remaining > 0 {
        var buffer = [Int8](repeating: 0, count: 65536)
        var available = buffer.count
        let status = buffer.withUnsafeMutableBufferPointer { dst -> Int in
          var next = dst.baseAddress
          return iconv(converted, &pointer, &remaining, &next, &available)
        }
        if status != -1 {
          if remaining == 0 { break }
          continue // E2BIG: output buffer filled, keep converting the input.
        }
        let code = errno
        if code == E2BIG { continue }
        if code == EINVAL && allowTrailingPartial && remaining <= 4 { return true }
        return false
      }
      return true
    }
  }

  /// Detects a legacy CJK encoding from a sample taken near the first decode
  /// failure (mirrors Android's `BookTextDecoder.legacyCharset`). Statistical
  /// sampling here is what makes GBK / Big5 files with an ASCII preface decode
  /// correctly instead of being mis-read as UTF-8 from the first 64 KB.
  static func legacyEncoding(for sample: Data) -> String {
    var converted: NSString?
    let detected = NSString.stringEncoding(for: sample, encodingOptions: [
      .suggestedEncodingsKey: [
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)),
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
      ],
      .allowLossyKey: false
    ], convertedString: &converted, usedLossyConversion: nil)
    if detected != 0 {
      let cf = CFStringConvertNSStringEncodingToEncoding(detected)
      if let name = CFStringConvertEncodingToIANACharSetName(cf) as String? {
        let lower = name.lowercased()
        if lower.contains("big5") { return "Big5-HKSCS" }
        if lower.contains("gb") { return "GB18030" }
        if supportedTextEncodings.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
          return name
        }
      }
    }
    // GB18030 is a superset of GBK and can decode virtually any CJK byte
    // sequence, so it is the safe default for an auto-detected legacy file.
    return "GB18030"
  }

  static func resolveEncoding(_ value: String, sample: Data) throws -> String {
    if value != "auto" {
      guard supportedTextEncodings.contains(value) else {
        throw BookDocumentFailure(code: "text_encoding", message: "不支持此文字编码")
      }
      return value
    }
    if sample.starts(with: [0xff, 0xfe]) { return "UTF-16LE" }
    if sample.starts(with: [0xfe, 0xff]) { return "UTF-16BE" }
    // BOM-less UTF-16 has a distinctive NUL cadence (e.g. 41 00 42 00).
    // Without this check `00 41 00 42` is valid UTF-8 and would be read as NUL-filled text.
    if sample.count >= 32 {
      let bytes = [UInt8](sample.prefix(128))
      var evenNul = 0, oddNul = 0, pairs = bytes.count / 2
      if pairs >= 16 {
        for i in 0..<pairs {
          if bytes[i * 2] == 0 { evenNul += 1 }
          if bytes[i * 2 + 1] == 0 { oddNul += 1 }
        }
        let ratio = Double(max(evenNul, oddNul)) / Double(pairs)
        if ratio > 0.85 { return evenNul > oddNul ? "UTF-16LE" : "UTF-16BE" }
      }
    }
    // Accept UTF-8 only when the whole sample is strictly well-formed. The old
    // logic accepted any prefix that decoded, so a GBK file whose first 64 KB
    // happened to be valid UTF-8 (ASCII preface / GBK byte pairs that overlap
    // UTF-8) was misclassified and failed mid-file with EILSEQ.
    if isWellFormed(sample, encoding: "UTF-8", allowTrailingPartial: true) { return "UTF-8" }
    return legacyEncoding(for: sample)
  }
}
