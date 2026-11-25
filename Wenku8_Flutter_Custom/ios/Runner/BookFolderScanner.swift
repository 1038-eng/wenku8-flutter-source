import Foundation

/// Reads a security-scoped documents folder and lists importable books.
/// The folder bookmark and settings persist across launches; scanning never
/// modifies or deletes user files.
final class BookFolderScanner {
  private struct State: Codable {
    var bookmark: Data?
    var name: String = "书籍文件夹"
    var automatic = false
    var formats: [String] = Array(BookImportFormatPolicy.extensions).sorted()
    var imported: [String: Int64] = [:] // relative path -> file size at import
  }

  private let stateFile: URL
  private let documentsDirectory: URL
  private let files: FileManager
  private var state: State
  private var entries: [String: URL] = [:] // token -> source url

  init(stateFile: URL, documentsDirectory: URL, files: FileManager = .default) throws {
    self.stateFile = stateFile
    self.documentsDirectory = documentsDirectory
    self.files = files
    if let data = try? Data(contentsOf: stateFile),
       let decoded = try? JSONDecoder().decode(State.self, from: data) {
      state = decoded
    } else {
      state = State()
    }
  }

  private func save() throws {
    try files.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(state)
    try data.write(to: stateFile, options: .atomic)
  }

  private func resolvedRoot() -> (URL, Bool)? {
    guard let bookmark = state.bookmark else { return nil }
    var stale = false
    let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    return url.map { ($0, true) }
  }

  // MARK: - Folder selection

  func select(_ url: URL) throws -> [String: Any] {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw BookDocumentFailure(code: "scan_folder", message: "请选择一个文件夹")
    }
    let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    state.bookmark = bookmark
    state.name = url.lastPathComponent
    state.imported.removeAll()
    entries.removeAll()
    try save()
    return info() ?? ["name": url.lastPathComponent, "automatic": state.automatic, "readable": true, "all": false]
  }

  func selectApplicationDocuments() throws -> [String: Any] {
    state.bookmark = nil
    state.name = "应用文稿"
    state.imported.removeAll()
    entries.removeAll()
    try save()
    return info() ?? ["name": state.name, "automatic": state.automatic, "readable": true, "all": true]
  }

  func info() -> [String: Any]? {
    guard let root = resolvedRoot() else {
      // Application documents is always readable even without a bookmark.
      if state.bookmark == nil && state.name == "应用文稿" {
        return ["name": state.name, "automatic": state.automatic, "readable": true, "all": true]
      }
      return nil
    }
    return ["name": state.name, "automatic": state.automatic, "readable": root.1, "all": false]
  }

  func disconnect() throws {
    state.bookmark = nil
    state.imported.removeAll()
    entries.removeAll()
    try save()
  }

  // MARK: - Settings

  func formats() -> [String] { state.formats }

  func setFormats(_ extensions: [String]) throws {
    let chosen = Set(extensions.map { $0.lowercased() }).filter { BookImportFormatPolicy.extensions.contains($0) }
    guard !chosen.isEmpty else {
      throw BookDocumentFailure(code: "scan_format", message: "请至少选择一种支持的格式")
    }
    state.formats = chosen.sorted()
    try save()
  }

  func setAutomatic(_ value: Bool) throws {
    state.automatic = value
    try save()
  }

  // MARK: - Scanning

  func scan() throws -> [String: Any] {
    let root: URL
    let release: Bool
    if let resolved = resolvedRoot() {
      root = resolved.0
      release = resolved.1
    } else if state.bookmark == nil && state.name == "应用文稿" {
      root = documentsDirectory
      release = false
    } else {
      throw BookDocumentFailure(code: "scan_folder", message: "请先选择书籍文件夹")
    }
    if release { _ = root.startAccessingSecurityScopedResource() }
    defer { if release { root.stopAccessingSecurityScopedResource() } }

    var books = [[String: Any]]()
    var warnings = [String]()
    entries.removeAll()
    let allowed = Set(state.formats)
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
    let enumerator = files.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    var total = 0
    while let item = enumerator?.nextObject() as? URL {
      let ext = item.pathExtension.lowercased()
      guard allowed.contains(ext) else { continue }
      guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
      let size = values.fileSize ?? 0
      total += 1
      let token = UUID().uuidString
      entries[token] = item
      let relative = relativePath(item, under: root)
      let changed = state.imported[relative] != Int64(size)
      if changed {
        books.append([
          "token": token,
          "name": item.lastPathComponent,
          "size": size,
          "folder": (relative as NSString).deletingLastPathComponent,
        ])
      }
    }
    return [
      "books": books,
      "total": total,
      "unchanged": total - books.count,
      "warnings": warnings,
    ]
  }

  private func relativePath(_ url: URL, under root: URL) -> String {
    let path = url.standardizedFileURL.path
    let base = root.standardizedFileURL.path
    if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
    return url.lastPathComponent
  }

  func stage(_ token: String, documents: ManagedBookDocuments) throws -> [String: Any] {
    guard let source = entries[token] else {
      throw BookDocumentFailure(code: "scan_token", message: "扫描结果已失效，请重新扫描")
    }
    let scope = source.startAccessingSecurityScopedResource()
    defer { if scope { source.stopAccessingSecurityScopedResource() } }
    let staged = try documents.copy(source, maximumBytes: BookImportFormatPolicy.byteLimit(source.pathExtension))
    return ["name": source.lastPathComponent, "path": staged.path]
  }

  func link(_ token: String, documents: LinkedBookDocuments) throws -> [String: Any] {
    guard let source = entries[token] else {
      throw BookDocumentFailure(code: "scan_token", message: "扫描结果已失效，请重新扫描")
    }
    return try documents.retain(source)
  }

  func markImported(_ token: String) throws {
    guard let source = entries[token] else { return }
    let root = resolvedRoot()?.0 ?? documentsDirectory
    let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    state.imported[relativePath(source, under: root)] = Int64(size)
    try save()
  }

  func finish() throws {
    entries.removeAll()
  }
}
