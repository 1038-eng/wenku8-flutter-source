import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'models.dart';

const _assetPrefix = 'assets/models/tts/';
const _modelKey = 'kokoro';

// sid values come from the id2speaker metadata embedded in model.int8.onnx
// of kokoro-int8-multi-lang-v1_1: zf_001 -> 3, zm_010 -> 59.
const _femaleSpeakerId = 3;
const _maleSpeakerId = 59;

// Bump when the bundled model changes so an app update re-extracts it.
const _modelManifest = 'sherpa-tts-kokoro-v1';

/// sherpa-onnx Kokoro 本地 TTS 的串行客户端。
///
/// 一个 App 生命周期内只创建一个实例；Kokoro 男女声共用一套模型，只用一个
/// [sherpa.OfflineTts] 实例，全部合成调用串行化，避免 FFI 并发与重复加载模型。
class LocalSpeechClient {
  LocalSpeechClient();

  bool _bindingsReady = false;
  Future<Directory>? _modelsDirectory;
  Future<sherpa.OfflineTts>? _engine;
  Future<void> _queue = Future.value();

  Future<Directory> _models() => _modelsDirectory ??= _extractModels();

  Future<Directory> _extractModels() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}sherpa-tts-kokoro',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final manifest = File(
      '${directory.path}${Platform.pathSeparator}manifest.txt',
    );
    if (await manifest.exists() &&
        await manifest.readAsString() == _modelManifest) {
      return directory;
    }

    // The asset bundle contains nested espeak-ng-data/ files, so enumerate
    // the asset manifest instead of hard-coding a flat file list.
    final bundle = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys =
        bundle
            .listAssets()
            .where((key) => key.startsWith(_assetPrefix))
            .toList()
          ..sort();
    if (keys.isEmpty) {
      throw const SpeechFailure(
        '内置离线语音模型未正确打包，请重新安装安装包',
        kind: SpeechFailureKind.unavailable,
      );
    }
    final sep = Platform.pathSeparator;
    for (final key in keys) {
      final relative = key.substring(_assetPrefix.length);
      final target = File(
        '${directory.path}$sep${relative.replaceAll('/', sep)}',
      );
      if (await target.exists() && await target.length() > 0) continue;
      try {
        final data = await rootBundle.load(key);
        await target.parent.create(recursive: true);
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      } on FlutterError {
        throw const SpeechFailure(
          '内置离线语音模型未正确打包，请重新安装安装包',
          kind: SpeechFailureKind.unavailable,
        );
      }
    }
    await manifest.writeAsString(_modelManifest, flush: true);
    return directory;
  }

  Future<sherpa.OfflineTts> _tts() {
    final existing = _engine;
    if (existing != null) return existing;
    final future = _createEngine();
    _engine = future;
    future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _engine = null;
      },
    );
    return future;
  }

  Future<sherpa.OfflineTts> _createEngine() async {
    if (!_bindingsReady) {
      sherpa.initBindings();
      _bindingsReady = true;
    }
    final root = await _models();
    final base = '${root.path}${Platform.pathSeparator}$_modelKey';
    final sep = Platform.pathSeparator;
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: '$base${sep}model.int8.onnx',
          voices: '$base${sep}voices.bin',
          tokens: '$base${sep}tokens.txt',
          // sherpa-onnx >= 2.0 ignores dataDir/lang; the lexicons decide
          // which languages are available.
          lexicon: '$base${sep}lexicon-us-en.txt,$base${sep}lexicon-zh.txt',
        ),
        numThreads: 1,
      ),
      maxNumSentences: 1,
    );
    try {
      return sherpa.OfflineTts(config);
    } catch (error) {
      throw SpeechFailure(
        '内置离线语音引擎启动失败：$error',
        kind: SpeechFailureKind.unavailable,
      );
    }
  }

  /// 合成一段文本并返回带 RIFF 头的单声道 16-bit PCM WAV。
  Future<Uint8List> synthesize(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) {
    cancellation.check();
    final result = _queue.then((_) => _generate(text, voice, cancellation));
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Uint8List> _generate(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) async {
    cancellation.check();
    final tts = await _tts();
    cancellation.check();
    final sid = voice.id == localFemaleVoice.id
        ? _femaleSpeakerId
        : _maleSpeakerId;
    final audio = tts.generate(text: text, sid: sid, speed: 1.0);
    if (audio.samples.isEmpty || audio.sampleRate <= 0) {
      throw const SpeechFailure(
        '离线语音模型没有生成有效音频',
        kind: SpeechFailureKind.content,
      );
    }
    cancellation.check();
    return _wav(audio.samples, audio.sampleRate);
  }
}

/// sherpa 返回 float PCM，听书播放链路要求 WAV 文件带 RIFF 头。
Uint8List _wav(Float32List samples, int sampleRate) {
  final bytes = ByteData(44 + samples.length * 2);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, 1, Endian.little); // mono
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, samples.length * 2, Endian.little);
  var offset = 44;
  for (final sample in samples) {
    final clamped = sample < -1
        ? -1.0
        : sample > 1
        ? 1.0
        : sample;
    bytes.setInt16(offset, (clamped * 32767).round(), Endian.little);
    offset += 2;
  }
  return bytes.buffer.asUint8List();
}
