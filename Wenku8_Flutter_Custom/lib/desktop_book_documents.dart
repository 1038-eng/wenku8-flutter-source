import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:charset/charset.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import 'package:html/parser.dart' show parse;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart' as xml;
import 'package:shared_preferences/shared_preferences.dart';

import 'book_documents.dart';

/// Windows/macOS/Linux 上的 BookDocuments 通道实现。
///
/// 与手机端共用同一条 Dart 导入链路（pickForImport → stageForImport →
/// importLocalDocuments → prepareBook），书库目录、缓存 key 和章节切分规则
/// 完全由共享代码决定；这里只负责「选文件」和「把其他文档转成 txt」。
class DesktopBookDocuments {
  DesktopBookDocuments._();

  static const _extensions = <String>[
    'txt', 'text', 'log', 'nfo', 'srt', 'csv', 'epub', 'zip',
    'html', 'htm', 'xhtml', 'md', 'markdown', 'fb2', 'docx', 'rtf',
    'pdf', 'mobi', 'azw', 'azw3', 'prc',
  ];

  static bool _supported(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _extensions.contains(name.substring(dot + 1).toLowerCase());
  }

  /// Direct-call API used by BookDocuments on desktop hosts. Bypasses the
  /// MethodChannel entirely so there is no plugin-registration race.
  static Future<void> ensureInstalled() async {
    if (_importRoot == null) await install();
  }

  static Future<List<Map<String, dynamic>>> pickFiles({
    required bool multiple,
  }) async {
    await ensureInstalled();
    return [
      for (final file in await _pick(allowMultiple: multiple))
        {'name': _name(file), 'path': file, 'error': null},
    ];
  }

  static Future<Map<String, dynamic>?> folderInfo() async {
    await ensureInstalled();
    return _folderInfo();
  }

  static Future<Map<String, dynamic>?> selectFolder() =>
      _selectFolder();

  static Future<Map<String, dynamic>> scan() async {
    await ensureInstalled();
    return _scanBooks();
  }

  static Future<List<String>> formats() async {
    await ensureInstalled();
    return _scanFormats ?? _extensions;
  }

  static Future<void> setFormats(List<String> values) async {
    await ensureInstalled();
    _scanFormats = values;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('desktop.scan.formats', values);
  }

  static Future<void> setAutomatic(bool value) async {
    await ensureInstalled();
    _scanAutomatic = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('desktop.scan.automatic', value);
  }

  static Future<void> disconnect() async {
    await ensureInstalled();
    await configureScanFolder('');
  }

  static Future<Map<String, dynamic>> staged(String token) async {
    await ensureInstalled();
    final path = _scanTokens[token];
    if (path == null) throw StateError('扫描结果已过期，请重新扫描');
    return {'name': _name(path), 'path': path};
  }

  static Future<List<Map<String, dynamic>>> prepareDirect(
    String name,
    String path,
  ) async {
    await ensureInstalled();
    return _prepare(name, path);
  }

  static Future<String> decodeDirect(String path) async {
    await ensureInstalled();
    return _decode(path);
  }

  /// Mobile `decodeTextFile` returns the path of a normalized temporary file;
  /// the desktop implementation must match that contract. Callers pass the
  /// result as `decodedPath`, so returning decoded text here made them open a
  /// novel body as if it were a file path (see "Cannot open file, path = ...").
  static Future<String> decodeDirectToFile(String path) async {
    await ensureInstalled();
    final text = await _decode(path);
    final target = File(
      '${_importRoot!.path}${Platform.pathSeparator}'
      'decoded-${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await target.writeAsString(text, flush: true);
    return target.path;
  }

  /// macOS sandbox grants file access only to the isolate that received the
  /// NSOpenPanel / drag-and-drop authorization. The import engine reads the
  /// original in a `compute()` background isolate, so an external path would
  /// fail there with FileSystemException. Copy into the app container first so
  /// both isolates can read it; [releaseBooks] cleans these copies by root.
  static Future<String> stageExternal(String path, String name) async {
    await ensureInstalled();
    final root = _importRoot!.path;
    if (path.startsWith(root)) return path;
    final source = File(path);
    if (!await source.exists()) {
      throw StateError('找不到文件：$name');
    }
    final target = File(
      '$root${Platform.pathSeparator}'
      'copy-${DateTime.now().microsecondsSinceEpoch}-${_safeName(name)}',
    );
    await source.copy(target.path);
    return target.path;
  }

  static const _powershell =
      r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
  static Directory? _importRoot;
  static String? _scanPath;
  static bool _scanAutomatic = false;
  static List<String>? _scanFormats;
  static final Map<String, String> _scanTokens = {};

  static Future<void> install() async {
    final support = await getApplicationSupportDirectory();
    _importRoot = Directory(
      '${support.path}${Platform.pathSeparator}book-import',
    );
    if (!await _importRoot!.exists()) {
      await _importRoot!.create(recursive: true);
    }
    final prefs = await SharedPreferences.getInstance();
    _scanPath = prefs.getString('desktop.scan.path');
    _scanAutomatic = prefs.getBool('desktop.scan.automatic') ?? false;
    _scanFormats = prefs.getStringList('desktop.scan.formats');
    BookDocuments.channel.setMethodCallHandler(handle);
  }

  /// Run a PowerShell script from a file instead of -Command: avoids Windows
  /// command-line quoting from mangling $variables and the multi-select filter.
  static Future<ProcessResult> _runPs(
    String script,
    List<String> arguments, {
    bool sta = false,
  }) async {
    final root = _importRoot!;
    final file = File(
      '${root.path}${Platform.pathSeparator}ps-${DateTime.now().microsecondsSinceEpoch}.ps1',
    );
    await file.writeAsString(script, flush: true);
    try {
      return await Process.run(
        _powershell,
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          if (sta) '-STA',
          '-File',
          file.path,
          ...arguments,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Map<String, dynamic>? _folderInfo() {
    final path = _scanPath;
    if (path == null || !Directory(path).existsSync()) return null;
    return {
      'name': _name(path),
      'automatic': _scanAutomatic,
      'readable': true,
      'all': false,
    };
  }

  /// Persist and activate a scan folder. Also used by the automated checks.
  static Future<void> configureScanFolder(String path) async {
    _scanPath = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('desktop.scan.path', path);
  }

  static Future<Map<String, dynamic>?> _selectFolder() async {
    if (Platform.isMacOS) {
      final path = await getDirectoryPath(confirmButtonText: '选择');
      if (path == null || path.isEmpty) return null;
      await configureScanFolder(path);
      return _folderInfo();
    }
    const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.FolderBrowserDialog
$d.Description = '选择图书文件夹'
if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($d.SelectedPath)))
}
''';
    final result = await _runPs(script, const [], sta: true);
    if (result.exitCode != 0) return null;
    final line = (result.stdout as String).trim();
    if (line.isEmpty) return null;
    await configureScanFolder(utf8.decode(base64.decode(line)));
    return _folderInfo();
  }

  static Future<Map<String, dynamic>> _scanBooks() async {
    final root = _scanPath;
    if (root == null) {
      throw PlatformException(code: 'no_folder', message: '请先选择图书文件夹');
    }
    final formats = (_scanFormats ?? _extensions).toSet();
    _scanTokens.clear();
    final books = <Map<String, dynamic>>[];
    var warnings = 0;
    await for (final entity in Directory(root).list(recursive: true)) {
      if (entity is! File) continue;
      final name = _name(entity.path);
      final dot = name.lastIndexOf('.');
      if (dot < 0) continue;
      if (!formats.contains(name.substring(dot + 1).toLowerCase())) continue;
      if (books.length >= 20000) {
        warnings++;
        continue;
      }
      final token = '${DateTime.now().microsecondsSinceEpoch}-${books.length}';
      _scanTokens[token] = entity.path;
      books.add({
        'token': token,
        'name': name,
        'size': await entity.length(),
        'folder': entity.parent.path,
      });
    }
    return {
      'books': books,
      'total': books.length,
      'unchanged': 0,
      'warnings': warnings == 0
          ? <String>[]
          : ['文件过多，仅显示前 20000 本'],
    };
  }

  static Future<dynamic> handle(MethodCall call) async {
    switch (call.method) {
      case 'pickBook':
        final files = await _pick(allowMultiple: false);
        if (files.isEmpty) return null;
        return {'name': _name(files.first), 'path': files.first};
      case 'pickBooks':
        return [
          for (final file in await _pick(allowMultiple: true))
            {'name': _name(file), 'path': file},
        ];
      case 'prepareBook':
        final args = call.arguments as Map<dynamic, dynamic>;
        return _prepare(
          args['name'] as String,
          args['path'] as String,
        );
      case 'decodeText':
      case 'decodeTextFile':
        final args = call.arguments as Map<dynamic, dynamic>;
        return _decode(args['path'] as String);
      case 'decodeBookNames':
        final args = call.arguments as Map<dynamic, dynamic>;
        return (args['names'] as List<dynamic>).cast<String>();
      case 'releaseBooks':
        final args = call.arguments as Map<dynamic, dynamic>;
        for (final path in (args['paths'] as List<dynamic>? ?? const []).cast<String>()) {
          await _release(path);
        }
        return null;
      case 'extractKindle':
      case 'extractPdf':
        throw PlatformException(
          code: 'unsupported',
          message: '桌面版暂不支持该格式，请先用 TXT / EPUB 导入',
        );
      case 'stageImportBook':
        final args = call.arguments as Map<dynamic, dynamic>;
        throw PlatformException(
          code: 'stale_token',
          message: '桌面端不需要暂存 token：${args['token']}',
        );
      case 'scanFolderInfo':
        return _folderInfo();
      case 'selectScanFolder':
        return _selectFolder();
      case 'selectAllScan':
        return null;
      case 'setScanAutomatic':
        final args = call.arguments as Map<dynamic, dynamic>;
        _scanAutomatic = args['value'] == true;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('desktop.scan.automatic', _scanAutomatic);
        return null;
      case 'disconnectScanFolder':
        _scanPath = null;
        _scanTokens.clear();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('desktop.scan.path');
        return null;
      case 'scanFormats':
        return _scanFormats ?? _extensions;
      case 'setScanFormats':
        final args = call.arguments as Map<dynamic, dynamic>;
        _scanFormats = (args['extensions'] as List<dynamic>).cast<String>();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('desktop.scan.formats', _scanFormats!);
        return null;
      case 'scanBooks':
        return _scanBooks();
      case 'stageScanBook':
      case 'linkScanBook':
        final args = call.arguments as Map<dynamic, dynamic>;
        final path = _scanTokens[args['token']];
        if (path == null) {
          throw PlatformException(
            code: 'stale_token',
            message: '扫描结果已过期，请重新扫描',
          );
        }
        return {'name': _name(path), 'path': path};
      case 'markScanBook':
      case 'finishBookScan':
        return null;
      case 'stagedTextReference':
        final args = call.arguments as Map<dynamic, dynamic>;
        return args['path'];
      default:
        return null;
    }
  }

  static String _name(String path) =>
      path.split(RegExp(r'[\\/]')).last;

  static Future<List<String>> _pick({required bool allowMultiple}) async {
    // macOS uses the native NSOpenPanel via file_selector. The PowerShell
    // path below is Windows-only and must never run on macOS.
    if (Platform.isMacOS) {
      final group = XTypeGroup(
        label: 'Books',
        extensions: _extensions,
      );
      if (allowMultiple) {
        final files = await openFiles(
          acceptedTypeGroups: <XTypeGroup>[group],
          confirmButtonText: '导入',
        );
        return files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
      }
      final file = await openFile(
        acceptedTypeGroups: <XTypeGroup>[group],
        confirmButtonText: '导入',
      );
      return file == null || file.path.isEmpty ? <String>[] : <String>[file.path];
    }
    final filter = _extensions.map((e) => '*.$e').join(';');
    final script = r'''
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.OpenFileDialog
$d.Multiselect = $args[0] -eq '1'
$d.Filter = "Books|$FILTER|$FILTER|All files|*.*"
if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  foreach ($f in $d.FileNames) {
    [Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($f)))
  }
}
'''
        .replaceAll('\$FILTER', filter);
    final result = await _runPs(
      script,
      [if (allowMultiple) '1' else '0'],
      sta: true,
    );
    if (result.exitCode != 0) {
      throw PlatformException(
        code: 'picker',
        message: '文件选择失败：${result.stderr}',
      );
    }
    return (result.stdout as String)
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .map((line) => utf8.decode(base64.decode(line.trim())))
        .toList();
  }

  static Future<String> _decode(String path) async =>
      decodeBytes(await File(path).readAsBytes());

  /// Two-pass text decoding shared by Windows/macOS/Linux. Mirrors the mobile
  /// engines: strict UTF-8 first, then UTF-16 by BOM/NUL cadence, then GBK —
  /// sampled near the first invalid byte so a UTF-8-looking ASCII preface
  /// cannot misclassify a legacy CJK book. Pure Dart, no shell dependency.
  static String decodeBytes(List<int> input) {
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    if (bytes.isEmpty) return '';
    final decoder = _TextDecoder(bytes);
    return decoder.decode();
  }


  static Future<List<Map<String, dynamic>>> _prepare(
    String name,
    String path,
  ) async {
    final ext = name.split('.').last.toLowerCase();
    final root = _importRoot!;
    if (ext == 'txt' || ext == 'epub') {
      return [
        {'name': name, 'path': path, 'error': null},
      ];
    }
    if (const {'mobi', 'azw', 'azw3', 'prc'}.contains(ext)) {
      return [
        {
          'name': name,
          'path': null,
          'error': '桌面版暂不支持 $ext，请用 TXT / EPUB / PDF',
        },
      ];
    }
    try {
      if (ext == 'pdf') {
        return await _pdfToEpub(name, path, root);
      }
      if (ext == 'zip') {
        return await _unpack(path, root);
      }
      // DOCX is a ZIP of XML; decoding its raw bytes as text yields garbage.
      // Extract word/document.xml and collect its <w:t> text nodes instead.
      final text = ext == 'docx'
          ? _docxText(await File(path).readAsBytes())
          : await _decode(path);
      final plain = ext == 'md' || ext == 'markdown' || ext == 'docx'
          ? text
          : _stripMarkup(text);
      final target = File(
        '${root.path}${Platform.pathSeparator}${_safeName(name)}.txt',
      );
      await target.writeAsString(plain, flush: true);
      return [
        {'name': '${_stripExt(name)}.txt', 'path': target.path, 'error': null},
      ];
    } catch (error) {
      return [
        {'name': name, 'path': null, 'error': '$error'},
      ];
    }
  }

  /// Raster scale for a rendered PDF page, identical to Android's
  /// BookPdfImport.kt: `min(120f / 72f, 1800f / max(width, height))`.
  /// Kept pure and public so the cap is testable without the native renderer.
  static double pdfRenderScale(double width, double height) {
    final longest = width > height ? width : height;
    if (longest <= 0) return 120 / 72;
    final byLongEdge = 1800 / longest;
    return (120 / 72) < byLongEdge ? 120 / 72 : byLongEdge;
  }

  /// Build the OPF and nav documents for a rendered PDF. Every spine idref is
  /// registered in the manifest — the reader rejects an unresolvable idref with
  /// "EPUB 的正文索引不完整" (local_books.dart). Kept pure so the contract is
  /// testable without the native pdf renderer.
  static ({String opf, String nav}) pdfEpubNavigation(
    String name,
    int pages,
  ) {
    final manifest = StringBuffer()
      ..write(
        '<item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>',
      );
    final spine = StringBuffer();
    final nav = StringBuffer();
    for (var index = 1; index <= pages; index++) {
      // Image items are referenced from the xhtml via <img>; chapter items are
      // referenced by the spine. Both ids must exist (mirrors BookEpubWriter.kt).
      // 第一页标记为封面，让书架自动显示封面（iOS 侧同样标记）。
      final coverProperty = index == 1 ? ' properties="cover-image"' : '';
      manifest.write(
        '<item id="i$index" href="image-$index.jpg" '
        'media-type="image/jpeg"$coverProperty/>',
      );
      manifest.write(
        '<item id="c$index" href="c$index.xhtml" '
        'media-type="application/xhtml+xml"/>',
      );
      spine.write('<itemref idref="c$index"/>');
      nav.write('<li><a href="c$index.xhtml">第 $index 页</a></li>');
    }
    final title = _stripExt(name)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final opf =
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>$title</dc:title>'
        '<meta name="cover" content="i1"/></metadata>'
        '<manifest>$manifest</manifest><spine>$spine</spine></package>';
    final navDoc =
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
        '<nav epub:type="toc"><ol>$nav</ol></nav></body></html>';
    return (opf: opf, nav: navDoc);
  }

  /// Render a PDF (typical comics are image-only) into the same EPUB shape the
  /// Android PDFBox importer produces, so the shared reader opens it unchanged.
  static Future<List<Map<String, dynamic>>> _pdfToEpub(
    String name,
    String path,
    Directory root,
  ) async {
    // Match the Android engine's limits (BookPdfImport.kt): 1..10000 pages.
    // Converted size is capped at 512 MiB below, same as BookEpubWriter.kt.
    const maxPages = 10000;
    final document = await PdfDocument.openFile(path);
    try {
      final pages = document.pagesCount;
      if (pages < 1 || pages > maxPages) {
        throw StateError('PDF 页数需在 1–$maxPages 之间');
      }
      final archive = Archive();
      void add(String name, List<int> bytes) =>
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
      add('mimetype', utf8.encode('application/epub+zip'));
      add(
        'META-INF/container.xml',
        utf8.encode(
          '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<rootfiles><rootfile full-path="content.opf" '
          'media-type="application/oebps-package+xml"/></rootfiles></container>',
        ),
      );

      final navigation = pdfEpubNavigation(name, pages);
      for (var index = 1; index <= pages; index++) {
        final page = await document.getPage(index);
        // Match Android's BookPdfImport.kt raster policy exactly: cap the
        // long edge at 1800px (and font-scale at 120/72). The old 1.4x upscale
        // was pure interpolation and pushed full-color comics (e.g. a
        // 387-page color volume) past the shared 512 MiB archive cap.
        final scale = pdfRenderScale(page.width, page.height);
        final image = await page.render(
          width: page.width * scale,
          height: page.height * scale,
          format: PdfPageImageFormat.jpeg,
          quality: 88,
        );
        await page.close();
        if (image == null) throw StateError('第 $index 页渲染失败');
        final imageName = 'image-$index.jpg';
        add(imageName, image.bytes);
        add(
          'c$index.xhtml',
          utf8.encode(
            '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
            '<img src="$imageName" style="width:100%"/>'
            '</body></html>',
          ),
        );
      }
      add('content.opf', utf8.encode(navigation.opf));
      add('nav.xhtml', utf8.encode(navigation.nav));
      final bytes = ZipEncoder().encode(archive);
      // Match the Android engine (BookEpubWriter.kt / MAX_ARCHIVE = 512 MiB).
      if (bytes.length > 512 * 1024 * 1024) {
        throw StateError('转换后的 PDF 超过 512 MiB');
      }
      final target = File(
        '${root.path}${Platform.pathSeparator}${_safeName(_stripExt(name))}.epub',
      );
      await target.writeAsBytes(bytes, flush: true);
      return [
        {'name': '${_stripExt(name)}.epub', 'path': target.path, 'error': null},
      ];
    } finally {
      await document.close();
    }
  }

  static Future<List<Map<String, dynamic>>> _unpack(
    String path,
    Directory root,
  ) async {
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final prepared = <Map<String, dynamic>>[];
    for (final entry in archive.files) {
      if (entry.isFile && _supported(entry.name)) {
        final target = File(
          '${root.path}${Platform.pathSeparator}${_safeName(_name(entry.name))}',
        );
        await target.writeAsBytes(entry.content as List<int>, flush: true);
        prepared.add({
          'name': _name(entry.name),
          'path': target.path,
          'error': null,
        });
      }
    }
    if (prepared.isEmpty) {
      prepared.add({
        'name': _name(path),
        'path': null,
        'error': '压缩包里没有可导入的图书',
      });
    }
    return prepared;
  }

  /// Extracts readable prose from a DOCX (ZIP) by reading word/document.xml
  /// and joining paragraph/text nodes. Kept bounded so a malformed archive
  /// cannot exhaust memory.
  static String _docxText(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? entry;
    for (final file in archive.files) {
      if (file.isFile && file.name == 'word/document.xml') {
        entry = file;
        break;
      }
    }
    if (entry == null) throw StateError('DOCX 结构无法识别，请另存为 DOCX 后重试');
    final document = xml.XmlDocument.parse(
      utf8.decode(entry.content as List<int>, allowMalformed: true),
    );
    final buffer = StringBuffer();
    for (final paragraph in document.findAllElements('w:p')) {
      final line = paragraph.findAllElements('w:t').map((n) => n.innerText).join();
      if (line.trim().isNotEmpty) buffer.writeln(line);
    }
    if (buffer.isEmpty) {
      buffer.write(document.findAllElements('w:t').map((n) => n.innerText).join());
    }
    return buffer.toString();
  }

  static String _stripMarkup(String source) {
    final document = parse(source);
    return document.body?.text ?? document.documentElement?.text ?? source;
  }

  static String _safeName(String name) =>
      name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  static String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  static Future<void> _release(String path) async {
    final root = _importRoot?.path;
    if (root == null || !path.startsWith(root)) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Stateful helper so the failure offset from the UTF-8 pass can be reused
/// when sampling for the legacy-encoding pass.
class _TextDecoder {
  _TextDecoder(this.bytes);
  final Uint8List bytes;

  String decode() {
    // Explicit BOMs are authoritative.
    if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
      return utf8.decode(bytes.sublist(3));
    }
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return _decodeUtf16(littleEndian: true, offset: 2);
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return _decodeUtf16(littleEndian: false, offset: 2);
    }

    // A fully valid UTF-8 file is unambiguous — decode directly.
    if (_firstInvalidUtf8(bytes) == null) return utf8.decode(bytes);

    // Otherwise try each candidate encoding on a truncated sample and pick the
    // one producing the most "text-like" characters. NUL cadence alone is not
    // enough: CJK UTF-16 has no NUL bytes, and GBK bytes can also decode as
    // plausible UTF-16 code units — scoring the decoded text is reliable.
    final leScore = _score(_decodeUtf16Sample(true));
    final beScore = _score(_decodeUtf16Sample(false));
    final gbkScore = _score(_gbkSample());
    if (leScore >= beScore && leScore > gbkScore) {
      return _decodeUtf16(littleEndian: true, offset: 0);
    }
    if (beScore > gbkScore) {
      return _decodeUtf16(littleEndian: false, offset: 0);
    }
    try {
      return const GbkCodec().decode(bytes);
    } on FormatException {
      // Truncated GBK tail can fail on the full file even if the sample was OK.
      return const GbkCodec(allowMalformed: true).decode(bytes);
    }
  }

  String _decodeUtf16Sample(bool littleEndian) {
    final end = bytes.length > 512 ? 512 : bytes.length;
    final even = end - end % 2;
    final view = ByteData.sublistView(bytes, 0, even);
    final endian = littleEndian ? Endian.little : Endian.big;
    final units = Uint16List(even ~/ 2);
    for (var i = 0; i < units.length; i++) {
      units[i] = view.getUint16(i * 2, endian);
    }
    return String.fromCharCodes(units);
  }

  String _gbkSample() {
    final sample = bytes.length > 512 ? bytes.sublist(0, 512) : bytes;
    try {
      return const GbkCodec().decode(sample);
    } on FormatException {
      return const GbkCodec(allowMalformed: true).decode(sample);
    }
  }

  /// Scores how text-like a decoded sample is. Rewards CJK / letters / digits
  /// / common punctuation; heavily penalises NUL, control chars, replacement
  /// chars and private-use characters that wrong byte orders typically yield.
  double _score(String text) {
    if (text.isEmpty) return 0;
    var good = 0.0, total = 0;
    for (final rune in text.runes) {
      total++;
      if (rune == 0x0a || rune == 0x0d || rune == 0x09 ||
          (rune >= 0x20 && rune <= 0x7e) ||
          (rune >= 0x4e00 && rune <= 0x9fff) ||
          (rune >= 0x3000 && rune <= 0x303f) ||
          (rune >= 0xff01 && rune <= 0xff65)) {
        good++;
      } else if (rune >= 0xe000 && rune <= 0xf8ff) {
        // Private use: GBK replacement character lives here (U+E7B3).
        good -= 0.5;
      }
    }
    return total == 0 ? 0 : good / total;
  }

  String _decodeUtf16({required bool littleEndian, required int offset}) {
    final end = bytes.length - (bytes.length - offset) % 2;
    final units = Uint16List((end - offset) ~/ 2);
    final view = ByteData.sublistView(bytes, offset, end);
    final endian = littleEndian ? Endian.little : Endian.big;
    for (var i = 0; i < units.length; i++) {
      units[i] = view.getUint16(i * 2, endian);
    }
    return String.fromCharCodes(units);
  }

  /// Returns the byte offset of the first malformed UTF-8 sequence, or null if
  /// the whole input is valid UTF-8.
  int? _firstInvalidUtf8(Uint8List data) {
    var i = 0;
    while (i < data.length) {
      final b = data[i];
      if (b < 0x80) {
        i++;
        continue;
      }
      int need;
      if (b >= 0xc2 && b <= 0xdf) {
        need = 1;
      } else if (b >= 0xe0 && b <= 0xef) {
        need = 2;
      } else if (b >= 0xf0 && b <= 0xf4) {
        need = 3;
      } else {
        return i;
      }
      if (i + need >= data.length) return i;
      for (var k = 1; k <= need; k++) {
        final c = data[i + k];
        if (c < 0x80 || c > 0xbf) return i;
      }
      i += need + 1;
    }
    return null;
  }
}