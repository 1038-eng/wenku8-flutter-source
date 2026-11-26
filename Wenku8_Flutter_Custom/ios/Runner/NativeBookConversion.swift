import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

#if canImport(WenkuBookEngine)
import WenkuBookEngine
#endif

/// Converts local documents into a self-contained EPUB (a ZIP archive) that
/// the shared Dart importer can open. Conversion is bounded and never modifies
/// the source file.
final class NativeBookConversion {
  private let documents: ManagedBookDocuments
  private let portableRoot: URL

  init(documents: ManagedBookDocuments, portableRoot: URL) throws {
    self.documents = documents
    self.portableRoot = portableRoot
    try FileManager.default.createDirectory(at: portableRoot, withIntermediateDirectories: true)
  }

  // MARK: - PDF

  /// 横向跨页扫描件在两页之间有一条贯穿高度的近白装订缝。只在明显横向页
  /// 上采样，避免把竖版单页或普通横版试卷误判成两页。
  private static func hasSpreadGutter(_ image: CGImage) -> Bool {
    let sample = 160
    guard let context = CGContext(
      data: nil, width: sample, height: sample,
      bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: sample, height: sample))
    guard let data = context.data else { return false }
    let rowBytes = context.bytesPerRow
    let from = 8, to = sample - 8
    let center = sample / 2
    var whiteRows = 0
    for y in from..<to {
      var nearWhite = 0
      for x in (center - 1)...(center + 1) {
        let offset = y * rowBytes + x * 4
        let r = data.load(fromByteOffset: offset, as: UInt8.self)
        let g = data.load(fromByteOffset: offset + 1, as: UInt8.self)
        let b = data.load(fromByteOffset: offset + 2, as: UInt8.self)
        if r > 215 && g > 215 && b > 215 { nearWhite += 1 }
      }
      if nearWhite >= 2 { whiteRows += 1 }
    }
    return Double(whiteRows) / Double(to - from) > 0.8
  }

  /// 把一个 PDF 页拆成要写入的图片片段。检测到跨页装订缝时沿中线分成左右页。
  private static func spreadPieces(
    _ image: CGImage,
    pageNumber: Int
  ) -> [(image: CGImage, name: String, label: String)] {
    let plain = String(format: "page-%04d.jpg", pageNumber)
    let ratio = CGFloat(image.width) / CGFloat(image.height)
    guard ratio >= 1.15, ratio <= 2.4, hasSpreadGutter(image) else {
      return [(image, plain, "第 \(pageNumber) 页")]
    }
    let mid = image.width / 2
    guard
      let left = image.cropping(to: CGRect(x: 0, y: 0, width: mid, height: image.height)),
      let right = image.cropping(
        to: CGRect(x: mid, y: 0, width: image.width - mid, height: image.height)
      )
    else {
      return [(image, plain, "第 \(pageNumber) 页")]
    }
    return [
      (left, String(format: "page-%04d-L.jpg", pageNumber), "第 \(pageNumber) 页 · 左"),
      (right, String(format: "page-%04d-R.jpg", pageNumber), "第 \(pageNumber) 页 · 右"),
    ]
  }

  /// Renders each PDF page to a JPEG and writes a minimal image EPUB.
  func extractPdf(_ path: String, output: String, name: String) throws {
    let source = URL(fileURLWithPath: path)
    guard let document = CGPDFDocument(source as CFURL) else {
      throw BookDocumentFailure(code: "pdf_open", message: "无法打开 PDF，文件可能已损坏或受密码保护")
    }
    guard document.numberOfPages > 0 else {
      throw BookDocumentFailure(code: "pdf_empty", message: "PDF 没有可读取的页面")
    }
    let files = FileManager.default
    let work = portableRoot.appendingPathComponent("pdf-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: work) }

    let imagesDir = work.appendingPathComponent("images", isDirectory: true)
    try files.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    let pageCount = min(document.numberOfPages, 2000)
    var imageNames = [String]()
    var imageLabels = [String]()
    let targetWidth: CGFloat = 1400

    for pageNumber in 1...pageCount {
      guard let page = document.page(at: pageNumber) else { continue }
      let box = page.getBoxRect(.mediaBox)
      guard box.width > 0, box.height > 0 else { continue }
      let scale = targetWidth / box.width
      let width = Int(box.width * scale)
      let height = Int(box.height * scale)
      guard width > 0, height > 0,
            let context = CGContext(data: nil, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.scaleBy(x: scale, y: scale)
      context.drawCGPDFDocument(page, in: box)
      guard let image = context.makeImage() else { continue }
      let jpegType: String = {
        if #available(iOS 14.0, *) { return UTType.jpeg.identifier }
        return "public.jpeg"
      }()
      for piece in Self.spreadPieces(image, pageNumber: pageNumber) {
        let url = imagesDir.appendingPathComponent(piece.name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                jpegType as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(destination, piece.image,
          [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { continue }
        imageNames.append(piece.name)
        imageLabels.append(piece.label)
      }
    }
    guard !imageNames.isEmpty else {
      throw BookDocumentFailure(code: "pdf_render", message: "PDF 页面无法渲染，可能使用了不支持的编码")
    }

    let title = (name as NSString).deletingPathExtension
    try writeImageEpub(at: URL(fileURLWithPath: output), title: title,
                       images: imageNames, labels: imageLabels, imageRoot: imagesDir)
  }

  // MARK: - Markup / document formats

  /// Converts HTML / XHTML / Markdown / RTF / FB2 / DOCX into a text EPUB
  /// using only system frameworks, so no third-party parser is required.
  /// Returns the output EPUB path. Text is always capped and bounded.
  func convertMarkup(_ path: String, name: String, output: String) throws {
    let source = URL(fileURLWithPath: path)
    let ext = (name as NSString).pathExtension.lowercased()
    let raw = try Data(contentsOf: source, options: .mappedIfSafe)
    guard !raw.isEmpty, raw.count <= 64 * 1024 * 1024 else {
      throw BookDocumentFailure(code: "file_too_large", message: "文档为空或超过 64 MiB，请拆分后导入")
    }
    let title = (name as NSString).deletingPathExtension
    let text: String
    switch ext {
    case "html", "htm", "xhtml":
      text = Self.htmlToText(raw)
    case "rtf":
      guard let attributed = try? NSAttributedString(data: raw, options: [
        .documentType: NSAttributedString.DocumentType.rtf,
        .characterEncoding: String.Encoding.utf8.rawValue,
      ], documentAttributes: nil) else {
        throw BookDocumentFailure(code: "conversion", message: "RTF 解析失败，请另存为 TXT 或 DOCX 后导入")
      }
      text = attributed.string
    case "md", "markdown", "csv", "log", "nfo", "srt", "json", "text":
      text = Self.decodeLoose(raw)
    case "fb2":
      text = Self.xmlText(raw, tags: ["p"])
    case "docx":
      text = try Self.docxText(raw)
    default:
      throw BookDocumentFailure(code: "format_unavailable", message: "暂不支持该格式，请导入 TXT、EPUB 或 PDF")
    }
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
      throw BookDocumentFailure(code: "conversion", message: "文档中没有可读取的文字")
    }
    let chapters = splitChapters(clean)
    try writeTextEpub(at: URL(fileURLWithPath: output), title: title, chapters: chapters)
  }

  /// Decodes bytes with a UTF-8-first, then GB18030 fallback (mirrors TXT).
  private static func decodeLoose(_ data: Data) -> String {
    var clean = data
    if clean.starts(with: [0xef, 0xbb, 0xbf]) { clean = clean.dropFirst(3) }
    if let utf8 = String(data: clean, encoding: .utf8) { return utf8 }
    let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    return String(data: clean, encoding: String.Encoding(rawValue: gb))
      ?? String(decoding: clean, as: UTF8.self)
  }

  /// Extracts visible text from an HTML/XHTML document via the system HTML
  /// parser, stripping scripts/styles and collapsing markup into plain text.
  private static func htmlToText(_ data: Data) -> String {
    // Let NSAttributedString detect the declared/actual encoding from the raw
    // bytes (it honours <meta charset>; a UTF-8 misread of GBK would be garbled).
    if let attributed = try? NSAttributedString(
      data: data,
      options: [.documentType: NSAttributedString.DocumentType.html],
      documentAttributes: nil
    ) {
      return attributed.string
    }
    // Fallback: decode bytes loosely, then strip tags without a full parser.
    let html = decodeLoose(data)
    let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    return stripped
  }

  /// Collects text nodes for given element names from simple XML (FB2 body).
  private static func xmlText(_ data: Data, tags: Set<String>) -> String {
    let parser = XMLReader(tags: tags)
    let xmlParser = XMLParser(data: data)
    xmlParser.delegate = parser
    _ = xmlParser.parse()
    return parser.text.joined(separator: "\n")
  }

  /// DOCX stores prose in word/document.xml inside the ZIP container.
  private static func docxText(_ data: Data) throws -> String {
    guard let archive = ZipReader(data: data), let xml = archive.file(named: "word/document.xml") else {
      throw BookDocumentFailure(code: "conversion", message: "DOCX 结构无法识别，请另存为 DOCX 后重试")
    }
    return xmlText(xml, tags: ["w:t", "w:p"])
  }

  // MARK: - Kindle / MOBI

  /// Uses the bundled libmobi engine (when available) to export text into a
  /// directory, then wraps the result into an EPUB. Returns chapter count.
  @discardableResult
  func extractKindle(_ path: String, output: String) throws -> Int {
    let source = URL(fileURLWithPath: path)
    let files = FileManager.default
    let work = portableRoot.appendingPathComponent("mobi-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: work) }

    var raw = ""
    #if canImport(WenkuBookEngine)
    let status = path.withCString { input in
      work.path.withCString { out in wenku_export_mobi(input, out) }
    }
    // Non-positive results indicate failure (see WenkuBookEngine.h), except 5/6
    // which are dictionary/encoding variants that also yield no text here.
    if status > 0 {
      let texts = (try? files.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
      raw = texts.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                 .joined(separator: "\n")
    }
    #endif
    if raw.isEmpty {
      // Lenient fallback for unencrypted files with embedded readable text.
      if let data = try? Data(contentsOf: source, options: .mappedIfSafe) {
        raw = String(data: data, encoding: .utf8)
          ?? String(decoding: data.filter { $0 == 0x0A || $0 == 0x0D || ($0 >= 0x20 && $0 < 0x80) }, as: UTF8.self)
      }
    }
    guard !raw.isEmpty else {
      throw BookDocumentFailure(code: "kindle_extract", message: "无法解析该 Kindle 文件（可能受 DRM 保护）")
    }

    let chapters = splitChapters(raw)
    let title = (source.lastPathComponent as NSString).deletingPathExtension
    try writeTextEpub(at: URL(fileURLWithPath: output), title: title, chapters: chapters)
    return chapters.count
  }

  private func splitChapters(_ text: String) -> [String] {
    var result = [String]()
    var current = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.count > 3 && trimmed.count < 80 &&
         (trimmed.hasPrefix("第") || trimmed.hasPrefix("Chapter") || trimmed.hasPrefix("CHAPTER")) {
        if !current.isEmpty { result.append(current) }
        current = trimmed + "\n"
      } else {
        current += line + "\n"
      }
      if current.utf8.count > 2 * 1024 * 1024 {
        result.append(current)
        current = ""
      }
    }
    if !current.isEmpty { result.append(current) }
    return result.isEmpty ? [text] : result
  }

  // MARK: - EPUB writers

  private func writeImageEpub(at output: URL, title: String, images: [String], labels: [String], imageRoot: URL) throws {
    let files = FileManager.default
    let build = portableRoot.appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
    let meta = build.appendingPathComponent("META-INF", isDirectory: true)
    let content = build.appendingPathComponent("OEBPS", isDirectory: true)
    let pages = content.appendingPathComponent("pages", isDirectory: true)
    try files.createDirectory(at: meta, withIntermediateDirectories: true)
    try files.createDirectory(at: pages, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: build) }

    var items = [String]()
    var spine = [String]()
    // 第一页作为封面：同时写 EPUB3 的 properties 与 EPUB2 的 meta，兼容
    // Dart 侧 local_books.dart 的 coverId / cover-image 两条识别路径。
    let coverId = "img0"
    for (index, image) in images.enumerated() {
      try files.copyItem(at: imageRoot.appendingPathComponent(image), to: pages.appendingPathComponent(image))
      let id = "img\(index)"
      let coverProperty = index == 0 ? " properties=\"cover-image\"" : ""
      items.append("<item id=\"\(id)\" href=\"pages/\(image)\" media-type=\"image/jpeg\"\(coverProperty)/>")
      spine.append("<itemref idref=\"\(id)\"/>")
    }
    let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """
    try container.write(to: meta.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>\(Self.escapeXml(title))</dc:title>
        <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
        <dc:language>zh</dc:language>
        <meta name="cover" content="\(coverId)"/>
      </metadata>
      <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        \(items.joined(separator: "\n"))
      </manifest>
      <spine toc="ncx">\(spine.joined(separator: "\n"))</spine>
    </package>
    """
    try opf.write(to: content.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
    // 图片型 EPUB 不逐页写 navPoint：Dart 侧 local_books.dart 会把带目录标签的
    // itemref 各自做成一个章节，逐页标签会让每页都成为章节边界，翻页时若相邻
    // 章节未预排版好就要多划一次。留空目录后所有图片合并进同一章，翻页一次到位。
    // 封面仍由 OPF 的 cover-image / meta 标记识别，与目录无关。
    let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="converted"/></head>
      <docTitle><text>\(Self.escapeXml(title))</text></docTitle>
      <navMap></navMap>
    </ncx>
    """
    try ncx.write(to: content.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
    try Self.zip(build, to: output)
  }

  private func writeTextEpub(at output: URL, title: String, chapters: [String]) throws {
    let files = FileManager.default
    let build = portableRoot.appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
    let meta = build.appendingPathComponent("META-INF", isDirectory: true)
    let content = build.appendingPathComponent("OEBPS", isDirectory: true)
    try files.createDirectory(at: meta, withIntermediateDirectories: true)
    try files.createDirectory(at: content, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: build) }

    var items = [String]()
    var spine = [String]()
    var navPoints = ""
    for (index, chapter) in chapters.enumerated() {
      let fileName = "chapter-\(index + 1).xhtml"
      let body = chapter.split(separator: "\n").map { "<p>\(Self.escapeXml(String($0)))</p>" }.joined(separator: "\n")
      let xhtml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(Self.escapeXml(title))</title></head>
      <body>\(body)</body></html>
      """
      try xhtml.write(to: content.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
      let id = "ch\(index + 1)"
      items.append("<item id=\"\(id)\" href=\"\(fileName)\" media-type=\"application/xhtml+xml\"/>")
      spine.append("<itemref idref=\"\(id)\"/>")
      navPoints += "<navPoint id=\"nav\(index)\" playOrder=\"\(index + 1)\"><navLabel><text>第 \(index + 1) 章</text></navLabel><content src=\"\(fileName)\"/></navPoint>"
    }
    let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """
    try container.write(to: meta.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>\(Self.escapeXml(title))</dc:title>
        <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
        <dc:language>zh</dc:language>
      </metadata>
      <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        \(items.joined(separator: "\n"))
      </manifest>
      <spine toc="ncx">\(spine.joined(separator: "\n"))</spine>
    </package>
    """
    try opf.write(to: content.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
    let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="converted"/></head>
      <docTitle><text>\(Self.escapeXml(title))</text></docTitle>
      <navMap>\(navPoints)</navMap>
    </ncx>
    """
    try ncx.write(to: content.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
    try Self.zip(build, to: output)
  }

  /// Minimal stored (uncompressed) ZIP writer, so no external dependency is
  /// needed on iOS. EPUB readers accept stored entries.
  private static func zip(_ directory: URL, to output: URL) throws {
    var entries = [(path: String, data: Data)]()
    let files = FileManager.default
    // cachesDirectory 返回 /var/...，enumerator 有时给出 /private/var/...；
    // 字符串前缀替换会失败并让 entry 名保留绝对路径，导入端按目录穿越拒绝。
    // 用解析符号链接后的路径分量做相对差分，保证 entry 名始终是纯相对路径。
    let base = directory.resolvingSymlinksInPath().pathComponents
    let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
      guard let data = try? Data(contentsOf: url) else { continue }
      let parts = url.resolvingSymlinksInPath().pathComponents
      guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
      let relative = Array(parts.dropFirst(base.count)).joined(separator: "/")
      guard !relative.isEmpty else { continue }
      entries.append((relative, data))
    }
    guard !entries.isEmpty else {
      throw BookDocumentFailure(code: "epub_zip", message: "EPUB 内容为空")
    }

    var local = Data()
    var central = Data()
    var offset: UInt32 = 0
    for entry in entries {
      let name = Array(entry.path.utf8)
      let crc = crc32(entry.data)
      let size = UInt32(entry.data.count)
      // Local file header
      local.append(contentsOf: UInt32(0x04034b50).littleBytes)
      local.append(contentsOf: UInt16(20).littleBytes)   // version needed
      local.append(contentsOf: UInt16(0).littleBytes)    // flags
      local.append(contentsOf: UInt16(0).littleBytes)    // stored
      local.append(contentsOf: UInt16(0).littleBytes)    // time
      local.append(contentsOf: UInt16(0).littleBytes)    // date
      local.append(contentsOf: crc.littleBytes)
      local.append(contentsOf: size.littleBytes)
      local.append(contentsOf: size.littleBytes)
      local.append(contentsOf: UInt16(name.count).littleBytes)
      local.append(contentsOf: UInt16(0).littleBytes)    // extra
      local.append(contentsOf: name)
      local.append(entry.data)
      // Central directory header
      central.append(contentsOf: UInt32(0x02014b50).littleBytes)
      central.append(contentsOf: UInt16(20).littleBytes) // version made by
      central.append(contentsOf: UInt16(20).littleBytes) // version needed
      central.append(contentsOf: UInt16(0).littleBytes)
      central.append(contentsOf: UInt16(0).littleBytes)
      central.append(contentsOf: UInt16(0).littleBytes)
      central.append(contentsOf: UInt16(0).littleBytes)
      central.append(contentsOf: crc.littleBytes)
      central.append(contentsOf: size.littleBytes)
      central.append(contentsOf: size.littleBytes)
      central.append(contentsOf: UInt16(name.count).littleBytes)
      central.append(contentsOf: UInt16(0).littleBytes)
      central.append(contentsOf: UInt16(0).littleBytes)
      central.append(contentsOf: UInt16(0).littleBytes)
      central.append(contentsOf: UInt16(0).littleBytes)
      central.append(contentsOf: UInt32(0).littleBytes)
      central.append(contentsOf: offset.littleBytes)
      central.append(contentsOf: name)
      offset += UInt32(30 + name.count + entry.data.count)
    }
    let centralSize = UInt32(central.count)
    let centralOffset = UInt32(local.count)
    var end = Data()
    end.append(contentsOf: UInt32(0x06054b50).littleBytes)
    end.append(contentsOf: UInt16(0).littleBytes)
    end.append(contentsOf: UInt16(0).littleBytes)
    end.append(contentsOf: UInt16(entries.count).littleBytes)
    end.append(contentsOf: UInt16(entries.count).littleBytes)
    end.append(contentsOf: centralSize.littleBytes)
    end.append(contentsOf: centralOffset.littleBytes)
    end.append(contentsOf: UInt16(0).littleBytes)

    var archive = Data()
    archive.append(local)
    archive.append(central)
    archive.append(end)
    try archive.write(to: output, options: .atomic)
  }

  private static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB88320 : 0)
      }
    }
    return ~crc
  }

  private static func escapeXml(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}

// MARK: - Lightweight helpers for markup conversion

/// Collects character data inside a whitelist of XML element names. Used for
/// FB2 (<p>) and DOCX (<w:t>/<w:p>) prose. External entities are never resolved.
private final class XMLReader: NSObject, XMLParserDelegate {
  private let tags: Set<String>
  private var capture = false
  private var current = ""
  private(set) var text: [String] = []
  init(tags: Set<String>) { self.tags = tags }
  func parser(_ parser: XMLParser, didStartElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?,
              attributes attributeDict: [String: String] = [:]) {
    let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
    if tags.contains(local) || tags.contains(elementName) { capture = true }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if capture { current += string }
  }
  func parser(_ parser: XMLParser, didEndElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?) {
    let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
    if tags.contains(local) || tags.contains(elementName) {
      let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { text.append(value) }
      current = ""
      capture = false
    }
  }
}

/// Minimal stored/deflate ZIP reader for extracting a single named entry.
/// Supports method 0 (stored) and 8 (deflate); EPUB/DOCX both use these.
private final class ZipReader {
  private let data: Data
  private var entries: [String: (offset: Int, size: Int, method: Int)] = [:]
  init?(data: Data) {
    self.data = data
    guard Self.u32(data, data.count - 22) == 0x06054b50 else { return nil }
    let count = Int(Self.u16(data, data.count - 10))
    var cursor = Int(Self.u32(data, data.count - 6))
    for _ in 0..<count {
      guard Self.u32(data, cursor) == 0x02014b50, cursor + 46 <= data.count else { break }
      let method = Int(Self.u16(data, cursor + 10))
      let compressed = Int(Self.u32(data, cursor + 20))
      let nameLength = Int(Self.u16(data, cursor + 28))
      let extraLength = Int(Self.u16(data, cursor + 30))
      let commentLength = Int(Self.u16(data, cursor + 32))
      let localOffset = Int(Self.u32(data, cursor + 42))
      let nameStart = cursor + 46
      guard nameStart + nameLength <= data.count,
        let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) else {
        break
      }
      guard Self.u32(data, localOffset) == 0x04034b50, localOffset + 30 <= data.count else { break }
      let localName = Int(Self.u16(data, localOffset + 26))
      let localExtra = Int(Self.u16(data, localOffset + 28))
      let body = localOffset + 30 + localName + localExtra
      entries[name] = (body, compressed, method)
      cursor = nameStart + nameLength + extraLength + commentLength
    }
  }
  func file(named name: String) -> Data? {
    guard let entry = entries[name] else { return nil }
    // Guard against corrupt offsets so a malformed archive cannot trap on a
    // Range with lowerBound > upperBound.
    guard entry.offset >= 0, entry.size >= 0,
          entry.offset <= data.count, entry.size <= data.count - entry.offset else { return nil }
    let body = data.subdata(in: entry.offset..<(entry.offset + entry.size))
    if entry.method == 0 { return body }
    if entry.method == 8 {
      return body.withUnsafeBytes { raw -> Data? in
        guard raw.baseAddress != nil else { return nil }
        var source = z_stream()
        // zlib requires an init call before inflate; without it inflate returns
        // Z_STREAM_ERROR and every deflated DOCX entry fails to decompress.
        // inflateInit is a C macro invisible to Swift; call the underlying
        // function with the default 15-bit window bits.
        guard inflateInit2_(&source, 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        source.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.baseAddress?.assumingMemoryBound(to: Bytef.self))
        source.avail_in = uInt(min(body.count, Int.max))
        defer { inflateEnd(&source) }
        var result = Data()
        var out = [Bytef](repeating: 0, count: 65536)
        while source.avail_in > 0 {
          let produced = out.withUnsafeMutableBufferPointer { buf -> Int in
            source.next_out = buf.baseAddress
            source.avail_out = uInt(buf.count)
            let status = inflate(&source, Z_NO_FLUSH)
            if status != Z_OK && status != Z_STREAM_END { return -1 }
            return buf.count - Int(source.avail_out)
          }
          if produced < 0 { break }
          if produced > 0 { result.append(contentsOf: out.prefix(produced)) }
          if source.avail_in > 0 && produced == 0 { break } // no progress guard
        }
        return result.isEmpty ? nil : result
      }
    }
    return nil
  }
  private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= data.count else { return 0 }
    return data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
  }
  private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
  }
}

// MARK: - Little-endian byte helpers

private extension FixedWidthInteger {
  var littleBytes: [UInt8] {
    let byteCount = MemoryLayout<Self>.size
    var value = self.littleEndian
    return (0..<byteCount).map { _ in
      let byte = UInt8(truncatingIfNeeded: value)
      value >>= 8
      return byte
    }
  }
}

private extension CGContext {
  func drawCGPDFDocument(_ page: CGPDFPage, in rect: CGRect) {
    // apply the page->rect transform, then let CoreGraphics draw the PDF page
    saveGState()
    let transform = page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true)
    concatenate(transform)
    drawPDFPage(page)
    restoreGState()
  }
}
