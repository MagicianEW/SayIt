# sayit_app (Flutter Desktop Skeleton)

> 阶段 1a：仅骨架，**不接入 Rust crate**。
> 阶段 1b：接入 `flutter_rust_bridge`，桥接 `sayit-poc/crates/sayit-edge`。

## 平台范围（v1）

- macOS 12+（Intel & Apple Silicon）
- Windows 10/11 (x64)
- ❌ Linux（V1 不支持）

## 当前结构

```
apps/sayit_app/
├── README.md          ← 本文件
├── pubspec.yaml       ← 依赖（PoC 阶段只有 flutter SDK 自带）
├── lib/
│   └── main.dart      ← 最小可运行骨架（占位 UI）
└── notes.md           ← 阶段 1b 接入 flutter_rust_bridge 的步骤清单
```

## 阶段 1b 接入清单

> 详细步骤见 [`notes.md`](./notes.md)。

- [ ] 在 `pubspec.yaml` 添加 `flutter_rust_bridge`、`riverpod`
- [ ] 在 `Cargo.toml`（新工程根）添加 `sayit-edge`、`sayit-drm` 作为依赖
- [ ] 运行 `flutter_rust_bridge_codegen` 生成桥接代码
- [ ] 在 `lib/main.dart` 接入 `sayitEdge.synthesize(...)`
- [ ] 实现文本导入 / TTS / 高亮播放 UI

## 本地创建平台壳

> 当前 PoC 阶段此目录是手写骨架。在能联网的环境下，标准做法是：

```bash
cd apps
flutter create \
  --project-name sayit_app \
  --platforms=macos,windows \
  --org com.sayit \
  sayit_app
```

随后把本目录的 `lib/main.dart`、`pubspec.yaml`、`README.md`、`notes.md` 覆盖到生成的位置。

## PoC 阶段承诺

- 不会尝试 `flutter run`（无 Flutter SDK）
- 不会引入 `flutter_rust_bridge`（1b 才接）
- 不会写业务逻辑（1c / 2 阶段）