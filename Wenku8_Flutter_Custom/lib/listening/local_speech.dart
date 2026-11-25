import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'models.dart';

const _assetPrefix = 'assets/models/tts/';
const _modelKey = 'kokoro';

// sid values come from the id2speaker metadata embedded in model.int8.onnx
// of kokoro-int8-multi-lang-v1_1: zf_001 -> 3; zm_009 -> 58; zm_010 -> 59;
// zm_011 -> 60; zm_016 -> 65. All share one engine; only the sid differs.
const _speakerIds = <String, int>{
  'kokoro-zf-001': 3,
  'kokoro-zm-009': 58,
  'kokoro-zm-010': 59,
  'kokoro-zm-011': 60,
  'kokoro-zm-016': 65,
};
const _maleSpeakerId = 59;

// Bump when the bundled model changes so an app update re-extracts it.
const _modelManifest = 'sherpa-tts-kokoro-v1';

/// sherpa-onnx Kokoro 本地 TTS 的串行客户端。
///
/// 模型解压、引擎初始化与 `tts.generate()`（同步 FFI）全部在常驻后台
/// isolate 完成；UI isolate 只收发请求与结果，切换离线音色时不再卡住界面。
/// 一个 App 生命周期内只有一个 worker，Kokoro 男女声共用一套模型/引擎。
class LocalSpeechClient {
  LocalSpeechClient();

  Isolate? _worker;
  SendPort? _port;
  ReceivePort? _messages;
  Future<void>? _starting;
  int _nextId = 0;
  final _pending = <int, Completer<Uint8List>>{};
  bool _disposed = false;

  void _failPending(Object error) {
    for (final request in _pending.values) {
      if (!request.isCompleted) request.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _startWorker() async {
    final ready = Completer<SendPort>();
    final messages = ReceivePort();
    _messages = messages;
    messages.listen(
      (message) {
        if (message is List && message.length >= 2 && message[0] == 'ready') {
          final port = message[1] as SendPort;
          _port = port;
          if (!ready.isCompleted) ready.complete(port);
          return;
        }
        if (message is! List || message.length < 2) return;
        final id = message[0] as int;
        final request = _pending.remove(id);
        if (request == null) return;
        if (message[1] == true) {
          request.complete(message[2] as Uint8List);
        } else {
          request.completeError(
            SpeechFailure(
              message[2] as String,
              kind: SpeechFailureKind.unavailable,
            ),
          );
        }
      },
      onError: _failPending,
      onDone: () => _failPending(
        const SpeechFailure(
          '离线语音引擎已退出，请重试',
          kind: SpeechFailureKind.unavailable,
        ),
      ),
    );
    try {
      _worker = await Isolate.spawn(_speechWorker, (
        messages.sendPort,
        ServicesBinding.rootIsolateToken,
      ));
      await ready.future;
    } catch (_) {
      _failPending(
        const SpeechFailure(
          '离线语音引擎未能启动，请重试',
          kind: SpeechFailureKind.unavailable,
        ),
      );
      _cleanup();
      rethrow;
    }
  }

  Future<void> _ensureWorker() {
    if (_disposed) throw StateError('本地语音客户端已关闭');
    if (_port != null) return Future.value();
    return _starting ??= _startWorker().catchError((Object error) {
      _starting = null;
      throw error;
    });
  }

  void _cleanup() {
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _port = null;
    _messages?.close();
    _messages = null;
  }

  /// 合成一段文本并返回带 RIFF 头的单声道 16-bit PCM WAV。
  Future<Uint8List> synthesize(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) async {
    cancellation.check();
    await _ensureWorker();
    cancellation.check();
    final id = ++_nextId;
    final result = Completer<Uint8List>();
    _pending[id] = result;
    final sid = _speakerIds[voice.id] ?? _maleSpeakerId;
    _port!.send([id, text, sid]);
    try {
      final bytes = await result.future;
      cancellation.check();
      return bytes;
    } catch (_) {
      _pending.remove(id);
      rethrow;
    }
  }

  /// 提前拉起后台 worker 并初始化模型，避免第一段朗读时把解压时间算进
  /// 播放准备超时而被跳过。失败静默，实际 synthesize 时会再报错。
  void warmUp() {
    if (_disposed) return;
    unawaited(_ensureWorker().catchError((Object _) {}));
  }

  void dispose() {
    _disposed = true;
    _cleanup();
    _failPending(StateError('本地语音客户端已关闭'));
    _starting = null;
  }
}

/// 常驻后台 worker：解压模型、初始化 sherpa 引擎、串行合成。
/// 这里发生的任何同步 FFI 都不会阻塞 UI。
void _speechWorker((SendPort, RootIsolateToken?) message) {
  final (port, token) = message;
  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
  final commands = ReceivePort();
  port.send(['ready', commands.sendPort]);

  final client = _WorkerSpeech();
  // 模型解压与引擎初始化在 worker 空闲时提前完成，用户点朗读时不必再等。
  unawaited(
    client._tts().then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    ),
  );
  commands.listen((message) async {
    if (message is! List || message.length < 3) return;
    final id = message[0] as int;
    final text = message[1] as String;
    final sid = message[2] as int;
    try {
      final bytes = await client.generate(text, sid);
      port.send([id, true, bytes]);
    } catch (error) {
      port.send([id, false, '$error']);
    }
  });
}

class _WorkerSpeech {
  bool _bindingsReady = false;
  Future<Directory>? _modelsDirectory;
  Future<sherpa.OfflineTts>? _engine;

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

  Future<Uint8List> generate(String text, int sid) async {
    final tts = await _tts();
    final audio = tts.generate(text: text, sid: sid, speed: 1.0);
    if (audio.samples.isEmpty || audio.sampleRate <= 0) {
      throw const SpeechFailure(
        '离线语音模型没有生成有效音频',
        kind: SpeechFailureKind.content,
      );
    }
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
