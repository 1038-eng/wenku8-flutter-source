import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
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
    BookDocuments.channel.setMethodCallHandler(_handle);
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

  static Future<Map<String, dynamic>?> _selectFolder() async {
    const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.FolderBrowserDialog
$d.Description = '选择图书文件夹'
if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($d.SelectedPath)))
}
''';
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-STA', '-Command', script],
      stdoutEncoding: utf8,
    );
    if (result.exitCode != 0) return null;
    final line = (result.stdout as String).trim();
    if (line.isEmpty) return null;
    _scanPath = utf8.decode(base64.decode(line));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('desktop.scan.path', _scanPath!);
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

  static Future<dynamic> _handle(MethodCall call) async {
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
$d.Multiselect = $ARGS[0] -eq '1'
$d.Filter = "Books|$FILTER|$FILTER|All files|*.*"
if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  foreach ($f in $d.FileNames) {
    [Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($f)))
  }
}
'''
        .replaceAll('\$FILTER', filter);
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-STA', '-Command', script.replaceFirst('\$ARGS[0]', allowMultiple ? "'1'" : "'0'")],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
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
$bytes = [IO.File]::ReadAllBytes($ARGS[0])
$text = [Text.Encoding]::GetEncoding(936).GetString($bytes)
[Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))
''';
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-Command', script, path],
        stdoutEncoding: utf8,
      );
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
    if (const {'pdf', 'mobi', 'azw', 'azw3', 'prc'}.contains(ext)) {
      return [
        {
          'name': name,
          'path': null,
          'error': 'Windows 版暂不支持 $ext，请用 TXT 或 EPUB',
        },
      ];
    }
    try {
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
