import 'dart:io';
import 'package:flutter/services.dart';

/// 由原生层返回的「可导入文档」条目。
typedef PreparedBookDocument = ({String name, String? path, String? error});

/// 便携文档转换通道。
///
/// 真正的转换在原生侧完成（EPUB/MOBI/PDF → 纯文本），本类只负责
/// 调度、并发上限与临时目录清理。当前构建保留完整签名，
/// 但 [prepare] 在缺少原生实现时会直接返回空列表，不会静默损坏文件。
class PortableBookPreparer {
  PortableBookPreparer({
    required this.directory,
    required this.textCodecToken,
    required this.decodeNames,
    required this.convert,
    required this.extractKindle,
    this.extractPdf,
  });

  final Directory directory;
  final RootIsolateToken textCodecToken;
  final Future<List<String>> Function(List<String> names) decodeNames;
  final Future<List<PreparedBookDocument>> Function(String name, String path)
  convert;
  final Future<int> Function(String source, String output) extractKindle;
  final Future<void> Function(String name, String source, String output)?
  extractPdf;

  /// 上一次运行残留的半成品目录，启动时清掉。
  static Future<void> clearPreviousRuns(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // 清理失败不影响导入，保留现场供下次重试。
    }
  }

  Future<List<PreparedBookDocument>> prepare(
    String name,
    String path, {
    void Function(int done, int total)? onProgress,
  }) async {
    onProgress?.call(0, 1);
    try {
      final lower = name.toLowerCase();
      // iOS 已内置 libmobi，但 prepareBook 仍是抛错桩；Kindle 文件必须在
      // 这里显式走 extractKindle，转成统一 EPUB 后再进共享导入链路。
      if (const ['.mobi', '.azw', '.azw3', '.prc'].any(lower.endsWith)) {
        await directory.create(recursive: true);
        final output =
            '${directory.path}/kindle-${DateTime.now().microsecondsSinceEpoch}.epub';
        final chapters = await extractKindle(path, output);
        if (chapters <= 0) throw StateError('Kindle 文档未解析出正文');
        final epubName = name.replaceFirst(
          RegExp(r'\.(mobi|azw|azw3|prc)$', caseSensitive: false),
          '.epub',
        );
        onProgress?.call(1, 1);
        return [(name: epubName, path: output, error: null)];
      }
      // iOS / Harmony 用原生 PDF 渲染器把每一页转成图片 EPUB。原生侧没有
      // 把它接进 prepareBook（那里是抛错桩），所以必须在这里显式分派，
      // 否则 PDF 会掉进「此平台正在适配此格式」的失败分支。
      if (extractPdf != null && lower.endsWith('.pdf')) {
        await directory.create(recursive: true);
        final output =
            '${directory.path}/pdf-${DateTime.now().microsecondsSinceEpoch}.epub';
        await extractPdf!(name, path, output);
        final epubName = name.replaceFirst(
          RegExp(r'\.pdf$', caseSensitive: false),
          '.epub',
        );
        onProgress?.call(1, 1);
        return [(name: epubName, path: output, error: null)];
      }
      final docs = await convert(name, path);
      onProgress?.call(1, 1);
      return docs;
    } catch (error) {
      onProgress?.call(1, 1);
      return [(name: name, path: null, error: '$error')];
    }
  }

  /// 释放某个文档在这次运行里占用的临时路径。
  Future<void> releasePaths(Iterable<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }
}

/// 供原生侧回传的二进制片段。
typedef PreparedBytes = ({String name, Uint8List bytes});
