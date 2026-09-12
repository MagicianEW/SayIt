# sayit_app（Flutter 桌面端）

SayIt 的桌面前端。英文名 `SayIt`、中文名「说吧」。
**名字和版本号的统一管理见仓库根 `README.md` 的「命名与版本」一节**，本目录下的平台元数据不要手改。

## 平台范围

- macOS 12+（Intel & Apple Silicon）
- Windows 10/11 (x64)
- Linux —— 平台壳未提交进仓库，由 CI 用 `flutter create` 生成后再构建

## 与 Rust 的通信方式：子进程，不用 flutter_rust_bridge

```
Flutter (Dart)  ──Process.start──▶  sayit-poc[.exe]  ──stdout JSON──▶  Dart 解析
```

- Rust 端是独立可执行程序 `sayit-poc`（crate `sayit-poc-bin`），结果以 JSON 打到 stdout。
- Dart 端按一组候选路径查找这个可执行文件（`lib/main.dart` 的 `_pocBinaryCandidates()`），
  找不到会在界面上明确报出已查找的路径，而不是静默失败。
- 因此 `pubspec.yaml` **不声明** `flutter_rust_bridge` / `ffi` / `riverpod`，
  `lib/src/rust/` 下的 frb 生成码已删除。

放弃 FRB、改用子进程的记录见 [`notes.md`](./notes.md)。

## 当前结构

```
apps/sayit_app/
├── README.md              ← 本文件
├── pubspec.yaml           ← 依赖（无 FRB / ffi / riverpod）
├── notes.md               ← 架构决策记录（为什么不用 flutter_rust_bridge）
├── lib/
│   ├── main.dart          ← UI、播放、导出
│   └── src/
│       ├── build_info.dart       ← 自动生成，勿手改；版本号来自仓库根 VERSION
│       ├── text_segmenter.dart   ← 分句
│       └── voice_data.dart       ← 音色数据
├── test/
│   └── text_segmenter_test.dart  ← 分句规则回归测试（13 个用例）
├── macos/  windows/       ← 平台壳（已提交）
└── linux/                 ← 未提交，CI 用 flutter create 生成
```

## 音频格式

- edge_tts 的输出格式在其库内部写死为 **MP3**（24 kHz / 48 kbps / 单声道 CBR），
  `Communicate.__init__` 没有 `output_format` 参数，**拿不到 PCM**。
- 所以合成与导出都直接拼接 MP3 字节；逐句高亮的起始时间按已写入字节数 ÷ 6 换算毫秒
  （6000 字节/秒，整除关系精确），时间轴不漂移。
- 句间停顿功能已移除：插静音需要 MP3 解码后重编码，本项目栈内没有 MP3 编码器。

## 改代码前须知

- **版本号**：唯一来源是仓库根的 `VERSION`，由 `scripts/sync_version.py` 同步到
  `pubspec.yaml` 和 Rust 的 `Cargo.toml`，并生成本目录的 `lib/src/build_info.dart`。
  不要手改 `pubspec.yaml` 的 `version:`。
- **软件名称**：由 `scripts/sync_app_name.py` 同步到 9 个平台文件。不要手改
  `windows/CMakeLists.txt`、`windows/runner/Runner.rc`、`macos/Runner/Info.plist` 等。
- 两者都提供 `--check`，提交前跑一遍可验证是否漂移。
