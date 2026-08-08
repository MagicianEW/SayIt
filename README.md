# SayIt

> 个人学习 / 研究场景的本地桌面文本转语音（TTS）工具。逐句高亮、音频拼接无损、协议合规。

## 项目定位

SayIt 是一款**本地桌面应用**，核心目标：

- 本地桌面运行，文本 / 音频 / 配置存于本地，无需用户自建后端、无需登录
- 协议合规：MIT 许可证，依赖链全部 MIT / Apache-2.0 / BSD-3
- 逐句高亮播放，允许轻微漂移（<150ms 可接受）
- 音频拼接无损：WAV PCM 字节级操作

⚠️ **关于"本地"的边界**：SayIt 是桌面应用，所有数据存于本地，但 TTS 语音合成本身依赖微软 Edge TTS 云端 WebSocket 接口（详见下文合规声明），因此**需要联网**。"本地"指运行位置与数据存储，不等于离线。

## 平台范围（V1）

| 优先级 | 平台 | 备注 |
| :--- | :--- | :--- |
| P0 | Windows 10/11 (x64) | 主力平台 |
| P0 | macOS 12+ (Intel & Apple Silicon) | 跨 Mac 使用 |
| — | Linux | V1 不支持 |

## 合规声明

> **Edge TTS 接口性质**：SayIt 使用的 Edge TTS WebSocket 接口（`wss://speech.platform.bing.com/...`）是微软 Edge 浏览器"大声朗读"功能的内部接口，**并非公开官方 API**。本项目通过 Rust 重实现 `rany2/edge-tts`（MIT）的客户端逻辑与之通信。该接口可能随时被微软修改、限制或关闭，且使用方式可能涉及微软服务条款。微软有权在不通知的情况下终止访问。
>
> **项目定位**：SayIt 仅供个人学习与研究用途，不商业化、不分发衍生服务。用户需自行遵守所在地区关于 TTS 服务使用的法律法规，并自行承担使用本工具的风险。
>
> **许可链**：SayIt 不包含任何 FFmpeg 二进制文件或 GPL/LGPL 组件。音频拼接由纯 Dart 实现，TTS 引擎通过 Rust FFI 调用 Edge TTS 接口。symphonia 的完整依赖链需在使用前完成合规审计；若子依赖中存在非 MIT/Apache-2.0 协议组件，需替换为等效 MIT 库（如 minimp3）。
>
> **数据**：所有文本、音频、配置均存储于用户本地设备，不上传至任何第三方服务器（TTS 请求本身发送至微软接口除外）。

## 仓库结构

```
SayIt/
├── README.md                       ← 本文件
├── LICENSE                         ← MIT
├── sayit-poc/                      ← Rust PoC（阶段 1a，独立验证）
│   ├── Cargo.toml                  ← workspace root
│   ├── crates/
│   │   ├── sayit-drm/              ← Sec-MS-GEC Token 实现
│   │   ├── sayit-edge/             ← Edge TTS WebSocket 客户端
│   │   └── sayit-poc-bin/          ← PoC 验证用例 1/3/4
│   ├── reference/edge-tts/         ← rany2/edge-tts Python 源码参考（PoC 阶段）
│   └── reports/                    ← PoC 输出报告
└── apps/sayit_app/                 ← Flutter Desktop 应用骨架（阶段 1b 接入）
```

## 开发状态

- **阶段 1a PoC**：进行中 —— 验证 Edge TTS WebSocket、PCM 直出、SSML 边界偏移语义
- **阶段 1b**：flutter_rust_bridge 集成、WAV 拼接工具类、分块器
- **阶段 1c**：drift 存储层
- **阶段 2**：核心功能（导入 / TTS / 高亮播放 / 失败重试）
- **阶段 3**：导出与优化
- **阶段 4**：发布准备

详细方案见 [`SayIt开发报告_v1.4.md`](./SayIt开发报告_v1.4.md)。

## 构建

> PoC 阶段不依赖 Flutter SDK；只验证 Rust 端。

```bash
cd sayit-poc
cargo run -p sayit-poc-bin -- --case 1     # PCM 直出
cargo run -p sayit-poc-bin -- --case 3     # DRM Token 生成
cargo run -p sayit-poc-bin -- --case 4     # SSML 边界偏移语义
cargo run -p sayit-poc-bin -- --all        # 跑全部用例
```

## 许可

本仓库源码采用 [MIT License](./LICENSE)。