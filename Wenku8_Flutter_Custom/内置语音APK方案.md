# 方案 B：把离线语音包内置进 APK 的方案与所需条件

目标：产出一个**单一 APK**，安装后自带离线中文男女声，听书时不需联网、不需另外装 TTS 引擎。

## 一、为什么不能直接改官方 APK

- 官方 APK 带签名，任何改动都会使签名失效。
- 没有官方签名私钥，改完的包无法覆盖安装，也无法通过官方渠道校验。
- 因此只能在**源码层面**集成语音 + **重新编译签名**，产出新包。

## 二、所需环境 / 材料

| 项目 | 说明 | 获取方式 |
|---|---|---|
| Flutter SDK | 版本需匹配 pubspec（`sdk: ^3.11.3`，Flutter 3.35+/Dart 3.11） | https://docs.flutter.dev/get-started/install/windows |
| Android SDK + NDK | 编译原生库（libmobi / sherpa-onnx）必需 | Android Studio 安装 Android SDK、NDK 25+、CMake |
| Java JDK 17 | Gradle 构建 | https://adoptium.net |
| Gradle | 项目自带 wrapper，首次联网下载 | 自动 |
| Git | 拉取源码 | 已有 |

## 三、语音引擎与模型（开源）

- **sherpa-onnx Flutter 插件**：`sherpa_onnx`（pub.dev），提供离线 TTS，Android 可用。
  - 或直接用其 Android TTS Engine 源码集成：`k2-fsa/sherpa-onnx` 的 `android/SherpaOnnxTtsEngine`
- **中文离线模型**（从 `k2-fsa/sherpa-onnx` 的 `tts-models` Release 下载，建议 int8 量化版，体积小）：
  - 男声：`vits-piper-zh_CN-chaowen-medium-int8`（约 13MB）
  - 女声：`vits-piper-zh_CN-xiao_ya-medium-int8`（约 13MB）或 `huayan-medium`
  - 多说话人：`vits-icefall-zh-aishell3`（30MB，含男女声）
- 许可证：sherpa-onnx 为 Apache-2.0；Piper 模型多为 MIT/CC-BY，需在应用"关于/许可"页保留声明。

## 四、要改的代码（定制版源码内）

1. `pubspec.yaml`：加入 `sherpa_onnx` 依赖，把模型文件加入 `assets`。
2. `lib/listening/models.dart`：`ListeningSource` 增加 `local` 枚举值；`builtinChineseEdgeVoices` 增加内置离线音色条目。
3. `lib/listening/cache.dart` / `controller.dart`：新增本地 TTS 的音源实现，`voicesForLanguage` / `_voiceInventory` 支持 `local` 分支，合成走本地引擎。
4. `lib/listening/widgets.dart`：音源与音色选择 UI 增加"内置离线"分组。
5. Android 原生配置：模型随 APK 打包（assets）或首次启动解压到应用私有目录。

## 五、构建与签名步骤（概要）

1. 安装上述环境，`flutter doctor` 全绿。
2. 在定制版源码目录执行 `flutter pub get`。
3. 按第四节改代码、加模型资源。
4. `flutter build apk --release --target-platform=android-arm64`（或 `--split-per-abi`）。
5. 用自签名 keystore 签名（`keytool` 生成 + `jarsigner`/Gradle signingConfig）。
6. 产出 APK 安装测试：因签名不同，需先卸载官方版。

## 六、已知障碍与风险

- **签名冲突**：新包无法覆盖官方版，书架/阅读记录不通用（除非做数据迁移）。
- **体积增大**：每内置一个 int8 模型约 +13MB，两个约 +26MB。
- **兼容性**：Flutter/Dart 版本需与源码快照匹配，过低或过高都可能编译失败。
- **原生库**：libmobi 等通过 CMake/NDK 编译，NDK 版本不匹配可能报错。
- **模型许可**：分发前确认各模型许可证，保留署名。

## 七、结论

技术上完全可行，源码已补齐到 316 个 dart 文件、内部 import 零缺失，具备构建基础。
主要成本是**环境搭建（Flutter SDK + Android SDK/NDK）**和**听书模块的本地 TTS 适配开发**，以及**重新签名带来的安装方式变化**。
