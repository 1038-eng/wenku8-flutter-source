import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_ui.dart';
import 'models.dart';

/// 内置离线音色选择面板。与系统引擎面板一样，通过 Navigator.pop 回传音色。
class LocalSpeechVoicesPanel extends StatelessWidget {
  const LocalSpeechVoicesPanel({super.key, required this.selected});
  final SpeechVoice selected;

  bool _chosen(SpeechVoice voice) =>
      voice.source == selected.source && voice.id == selected.id;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .5,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 14, 12),
          child: Row(
            children: [
              const Expanded(
                child: ArchiveSection(
                  title: '内置离线音色',
                  code: 'AUDIO / OFFLINE VOICES',
                ),
              ),
              GlassIconButton(
                icon: CupertinoIcons.xmark,
                label: '关闭内置音色',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              for (final voice in builtinLocalVoices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassTextButton(
                    key: ValueKey('local-voice-${voice.id}'),
                    onPressed: () => Navigator.pop(context, voice),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppText(
                                voice.label,
                                style: const TextStyle(fontSize: 14),
                              ),
                              const AppText(
                                '普通话 · 随安装包内置 · 完全离线',
                                style: TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        if (_chosen(voice))
                          const ArchiveIcon(CupertinoIcons.checkmark, size: 16),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              AppText(
                '模型随安装包分发，首次使用会解压到应用私有目录；朗读过程不联网、不需要安装外部引擎。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
