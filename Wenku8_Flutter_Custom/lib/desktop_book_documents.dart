import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import 'package:html/parser.dart' show parse;
import 'package:path_provider/path_provider.dart';
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
          message: 'Windows 版暂不支持该格式，请先用 TXT / EPUB 导入',
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

  static Future<String> _decode(String path) async {
    final bytes = await File(path).readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      final script = r'''
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$bytes = [IO.File]::ReadAllBytes($args[0])
$text = [Text.Encoding]::GetEncoding(936).GetString($bytes)
[Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))
''';
      final result = await _runPs(script, [path]);
      if (result.exitCode != 0) throw StateError('无法识别文本编码');
      return utf8.decode(base64.decode((result.stdout as String).trim()));
    }
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
          'error': 'Windows 版暂不支持 $ext，请用 TXT / EPUB / PDF',
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
      final text = await _decode(path);
      final plain = ext == 'md' || ext == 'markdown' ? text : _stripMarkup(text);
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

  /// Render a PDF (typical comics are image-only) into the same EPUB shape the
  /// Android PDFBox importer produces, so the shared reader opens it unchanged.
  static Future<List<Map<String, dynamic>>> _pdfToEpub(
    String name,
    String path,
    Directory root,
  ) async {
    const maxPages = 1000;
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

      final manifest = StringBuffer()
        ..write(
          '<item id="nav" href="nav.xhtml" '
          'media-type="application/xhtml+xml" properties="nav"/>',
        );
      final spine = StringBuffer();
      final nav = StringBuffer();
      for (var index = 1; index <= pages; index++) {
        final page = await document.getPage(index);
        final image = await page.render(
          width: page.width * 1.4,
          height: page.height * 1.4,
          format: PdfPageImageFormat.jpeg,
          quality: 88,
        );
        await page.close();
        if (image == null) throw StateError('第 $index 页渲染失败');
        final imageName = 'image-$index.jpg';
        add(imageName, image.bytes);
        manifest.write(
          '<item id="i$index" href="$imageName" media-type="image/jpeg"/>',
        );
        spine.write('<itemref idref="c$index"/>');
        nav.write(
          '<li><a href="c$index.xhtml">第 $index 页</a></li>',
        );
        add(
          'c$index.xhtml',
          utf8.encode(
            '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
            '<img src="$imageName" style="width:100%"/>'
            '</body></html>',
          ),
        );
      }
      final title = _stripExt(name)
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      add(
        'content.opf',
        utf8.encode(
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>$title</dc:title></metadata>'
          '<manifest>$manifest</manifest><spine>$spine</spine></package>',
        ),
      );
      add(
        'nav.xhtml',
        utf8.encode(
          '<html xmlns="http://www.w3.org/1999/xhtml" '
          'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
          '<nav epub:type="toc"><ol>$nav</ol></nav></body></html>',
        ),
      );
      final bytes = ZipEncoder().encode(archive);
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
