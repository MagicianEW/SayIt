# 阶段 1b 接入 flutter_rust_bridge —— 步骤清单

> 这是**手动逐步**清单，阶段 1b 开始时逐条勾选。

## 1. 准备 Rust workspace

- [ ] 在 `sayit-poc/Cargo.toml` workspace 中确认 `sayit-edge`、`sayit-drm` 是 member（已是）
- [ ] 给 `sayit-edge` 与 `sayit-drm` 的 `lib.rs` 加 `#[flutter_rust_bridge::frb(init)]` 占位（待 1b 实施）
- [ ] 在 `sayit-poc` 根添加 `flutter` 作为 `frontend`（flutter_rust_bridge 模板）

## 2. 准备 Flutter 工程

- [ ] `cd apps && flutter create --platforms=macos,windows --org com.sayit sayit_app`
- [ ] 把 PoC 阶段的 `lib/main.dart`、`pubspec.yaml` 等覆盖到生成位置（保留 macos/、windows/ 子目录）
- [ ] 在 `pubspec.yaml` 添加：
  ```yaml
  dependencies:
    flutter_rust_bridge: ^2.0
    riverpod: ^2.5
  dev_dependencies:
  flutter_rust_bridge_codegen: ^2.0
  build_runner: ^2.4
  ```
- [ ] `flutter pub get`

## 3. 桥接生成

- [ ] 在 `apps/sayit_app` 根执行 `dart run flutter_rust_bridge_codegen build`
- [ ] 确认 `lib/src/rust/` 下生成了 `api.dart`、`io.dart`
- [ ] 在 `lib/main.dart` import 桥接代码：
  ```dart
  import 'src/rust/api.dart';
  ```

## 4. UI 接入

- [ ] 文本输入区（`TextField` + 导入 .txt 按钮）
- [ ] 语音选择 `DropdownButton`
- [ ] "生成并播放"按钮 → `sayitEdge.synthesize(...)`
- [ ] 播放区 + 逐句高亮
- [ ] WAV 导出按钮

## 5. 不在 1b 范围

- 存储层（drift）→ 1c
- MP3 兜底（symphonia/minimp3）→ 1b 末或 2 初
- 性能调优 → 3

## 6. 退出标准

- [ ] 粘贴一段 1KB 中文 → 点击生成 → 听到语音 → 文本按句高亮 → 导出 WAV 可播放
- [ ] `cargo clippy --workspace -- -D warnings` 零警告
- [ ] `flutter analyze` 零错误