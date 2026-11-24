import 'package:flutter/material.dart';

import 'book_documents.dart';
import 'local_book_importer.dart';
import 'local_import_batch.dart';

/// 扫描页：选择文件夹 → 扫描并导入 → 查看结果。
///
/// 官方快照里这个页面是空壳（SizedBox.shrink），点击入口后表现为黑屏。
/// 这里补成可见、可操作、错误信息可见的页面。
class LocalScanPage extends StatefulWidget {
  const LocalScanPage({
    super.key,
    required this.documents,
    required this.changes,
    required this.isBusy,
    required this.progress,
    required this.result,
    required this.failure,
    required this.onScan,
  });

  final BookDocuments documents;
  final LocalBookImporter changes;
  final bool Function() isBusy;
  final (int, int)? Function() progress;
  final LocalScanResult? Function() result;
  final String? Function() failure;
  final void Function(BuildContext context) onScan;

  @override
  State<LocalScanPage> createState() => _LocalScanPageState();
}

class _LocalScanPageState extends State<LocalScanPage> {
  String? _folder;
  String? _localError;

  Future<void> _selectFolder() async {
    try {
      final folder = await widget.documents.selectScanFolder();
      if (!mounted) return;
      setState(() {
        _folder = folder?.name;
        _localError = folder == null ? '已取消选择文件夹' : null;
      });
    } catch (error) {
      if (mounted) setState(() => _localError = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result();
    final busy = widget.isBusy();
    final progress = widget.progress();
    final failure = _localError ?? widget.failure();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描本地文件夹'),
        leading: const BackButton(),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          children: [
            if (_folder != null)
              Text('已选择：$_folder', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text(
              '关联一个文件夹，扫描其中的 TXT / EPUB / ZIP 等书籍并导入书库。'
              '原文件不会被移动或删除。',
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton(
                  onPressed: busy ? null : _selectFolder,
                  child: const Text('选择文件夹'),
                ),
                FilledButton(
                  onPressed: busy ? null : () => widget.onScan(context),
                  child: const Text('扫描并导入'),
                ),
              ],
            ),
            if (busy)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(
                  progress == null
                      ? '正在扫描…'
                      : '正在导入 ${progress.$1}/${progress.$2}',
                ),
              ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(
                  failure,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (result != null) ...[
              const SizedBox(height: 24),
              Text(result.summary, style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Text('共发现 ${result.total} 本，跳过 ${result.unchanged} 本。'),
              for (final warning in result.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(warning),
                ),
              for (final item in result.report.failures)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${item.name}：${item.message}',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: busy ? null : () => widget.onScan(context),
                child: const Text('重新扫描'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
