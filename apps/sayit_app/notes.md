# 架构决策：Dart ↔ Rust 不用 flutter_rust_bridge，改用子进程

> **本文件的前身是「阶段 1b 接入 flutter_rust_bridge 的步骤清单」。该方案已放弃。**
> 之所以保留这个文件而不是直接删掉，是为了把决策和取舍写下来 ——
> 否则以后有人看到 `lib/src/rust/` 空着，很可能又会按旧清单把 FRB 加回来。

## 现在的做法

Dart 用 `Process.run` 调起独立可执行程序 `sayit-poc`，Rust 把结果以 JSON 打到 stdout。

```dart
// lib/main.dart
final result = await Process.run(pocBinary, [
  '--synthesize-text=$encodedText',   // base64，避免命令行转义问题
  '--voice=$voice',
  '--rate=$rate',                     // 形如 +20% / -10%
  '--pitch=$pitchStr',                // 形如 +5Hz
  '--volume=$volumeStr',
  '--ssml-base64',
]);
final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
```

可执行文件由 `_pocBinaryCandidates()` 按平台给出一组候选路径依次查找
（macOS 看 `Resources/bin/`、`MacOS/`、`Frameworks/`；Windows 看 `exeDir\bin\`、`exeDir\`；
Linux 看 `exeDir/`、`exeDir/lib/`、`exeDir/bin/`）。找不到会在界面上报出已查找的全部路径。

## 已经删掉的东西

- `lib/src/rust/frb_generated.dart` / `.io.dart` / `.web.dart`
- `sayit-poc/crates/sayit-ffi/`（整个 crate）与 `sayit-poc/bridge.yaml`
- `pubspec.yaml` 里的 `flutter_rust_bridge` / `ffi` / `riverpod` 依赖，
  以及 `ffigen` / `build_runner` 这两个 dev 依赖

## 这个方案的取舍

**换来的：**

- Rust 端可以完全脱离 Flutter 单独开发与调试：`cargo run -p sayit-poc-bin -- --case all`
  就能跑全部用例，不需要先编译 Flutter 工程。
- 不用维护一份**要提交进仓库的生成代码**。FRB 的 `frb_generated.*` 是产物，
  但必须提交，一旦 Rust 端签名变了而忘了重新生成，两边就静默不一致。
- 依赖树小很多，不涉及 `ffi` 的 ABI 与平台动态库打包问题。
- 音频是字节流，本来就要跨语言搬运；走 stdout 的 base64 和走 FFI 没有本质区别，
  但省掉了一层桥接代码。

**代价：**

- 每次合成要 spawn 一个进程（进程创建开销，本机桌面场景可忽略）。
- 通信靠 JSON + base64，有编解码开销；文本量大时命令行参数长度受系统限制
  （Windows 上限约 32K 字符），所以走的是 base64 参数而非原始文本。
- 打包时必须把 `sayit-poc` 一起放进 bundle，且路径要对得上 —— 这是当前最脆弱的一环。

## 如果以后要改回 FRB

需要重新引入 `flutter_rust_bridge` / `ffi`、重建 `sayit-ffi` crate、重新生成
`lib/src/rust/`，并把打包流程改成链接动态库。这是新需求，不是 bug 修复。

## 顺带：音频格式也是被库限死的

edge_tts 的输出格式在其 `Communicate.__init__` 里写死为
`audio-24khz-48kbitrate-mono-mp3`，没有 `output_format` 参数。
所以：

- 拿不到 PCM，导出只能是 MP3；
- 想插句间静音就得 MP3 解码 → 拼 PCM → 重编码，本项目栈内没有 MP3 编码器，
  因此**句间停顿功能已整体移除**；
- 逐句高亮的时间轴按已写入字节数 ÷ 6 换算毫秒（48 kbps = 6000 字节/秒），精确不漂移。

## 决策：桌面端播放后端选 just_audio_media_kit

**问题**：`just_audio` 只有 Android / iOS / macOS / web 的原生实现，Windows 与 Linux
上没有任何播放后端。表现是代码完全正确、编译通过，但一按播放就抛
`MissingPluginException(No implementation found for method init on channel
com.ryanheise.just_audio.methods)` —— 容易误判成自己写错了。

**候选方案与取舍：**

| 方案 | Windows | Linux | 结论 |
|------|---------|-------|------|
| `just_audio_windows` | ✅ 纯原生 WinRT，体积小，无需初始化代码 | ❌ 不支持 | 单平台；且官方特性表里「读取字节流」标的是 *not tested*，而我们的 `_BytesAudioSource` 走的正是字节流 |
| `just_audio_libwinmedia` | ✅ | ❌ | 2022 年的包，SDK 约束仍是 `<3.0.0`，Dart 3 下装不上 |
| `just_audio_mpv` | ✅ | ✅ | 2023 年的包，同样受限于 `<3.0.0`，Dart 3 下装不上 |
| `just_audio_media_kit` | ✅ | ✅ | **采用** |

**为什么统一用 `just_audio_media_kit` 而不是「Windows 用一个、Linux 用另一个」：**

1. 两个实现会同时注册 `com.ryanheise.just_audio.methods` 这个 MethodChannel，
   在 Windows 上直接冲突，只能二选一。
2. 只要 Linux 需要它，Windows 就没有理由再引入第二套后端 —— 多一套就多一处要单独调试。
3. 它的官方特性表里「读取字节流」是 ✅（经由 just_audio 提供的本地 HTTP 代理），
   正好覆盖本应用的播放路径。

**代价：**

- Windows 产物变大：`media_kit_libs_windows_audio` 会带上 libmpv / FFmpeg 的动态库。
  换来的是零运行时依赖，解压即用。
- Linux 上 libmpv **不随包分发**（`media_kit_libs_linux` 的 CMake 只处理 mimalloc，
  并把 `bundled_libraries` 置空），media_kit 在运行期 `dlopen` 系统里的
  `libmpv.so.*`。所以 libmpv 是 Linux 的**运行前提**，写进 README。
  **不要试图把 `libmpv.so.*` 拷进 `bundle/lib/` 来"自带"它**：`libmpv2` 自身还依赖
  40 多个库（libplacebo / libmujs / libbluray / libsdl2 / ffmpeg 各件……），大多不在
  默认桌面环境里；只塞一个 `libmpv.so.2` 凑不出完整依赖，还会因为 Flutter Linux
  bundle 自带 `RPATH=$ORIGIN/lib` 而抢在系统库之前生效 —— 在只有 `libmpv.so.1` 的
  22.04 上反而会把本来能用的系统库挡掉。
- 必须在 `main()` 里显式调一次 `JustAudioMediaKit.ensureInitialized()`。
  默认只在 windows / linux 上注册，macOS 不受影响。

