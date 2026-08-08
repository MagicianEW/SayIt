# PoC 阶段开发约定

## 不做

- 不引入 Flutter crate 与 flutter_rust_bridge（留到 1b）
- 不引入 symphonia / minimp3（MP3 兜底留到 1b）
- 不引入 drift（存储层留到 1c）
- 不引入 Riverpod（UI 层留到 2）
- PoC 阶段 Rust 端不依赖 `tokio-tungstenite` 之外的任何 Edge TTS 客户端 crate
- 不写 cargo features 之外的"早优化"

## 做

- 复用 `rany2/edge-tts` 的 Python 源码作为参考（仅 PoC 阶段存放于 `reference/edge-tts/`，1b 后删除）
- 一份**纯 Rust 手写** DRM 实现（`crates/sayit-drm/`）
- 一份**纯 Rust 手写** WebSocket 客户端（`crates/sayit-edge/`）
- 用例 1 / 3 / 4 的可执行验证（`crates/sayit-poc-bin/`）
- 所有 PoC 报告落 `reports/`，作为阶段 1b/2 决策依据

## 命名

- crate 名：`sayit-drm` / `sayit-edge` / `sayit-poc-bin`
- 模块公开 API 用 `pub`，内部细节默认私有
- 不使用 `unsafe`（除 PoC 阶段明确标注的边界 FFI 之外）

## 测试

- DRM 模块单测：token 形状（长度、前缀、时变）
- WebSocket 客户端：仅 happy path（PoC 不做 mock 网络层）
- 用例 4 报告必须落盘 JSON，附可读 Markdown 摘要