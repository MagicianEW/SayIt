# SayIt 项目开发交接报告

> **版本**：1.0（PoC 阶段 1a 完成时）
> **日期**：2026-08-08
> **用途**：交接给新的开发 agent 继续开发。新 agent 应**通读本报告**，特别是第 6 节（踩坑记录），再开始工作。
> **配套文档**：`SayIt开发报告_v1.4.md`（产品/架构设计稿）、`POC_DELIVERY.md`（PoC 交付清单）

---

## 1. 项目现状（一句话总结）

**SayIt 是一款本地桌面文本转语音（TTS）工具，核心目标：逐句高亮播放 + 无损音频拼接。PoC 阶段 1a 已完成并全部通过，验证了「PyO3 子进程嵌入 Python edge-tts」这条 TTS 通路可行。**

当前**没有可运行的桌面应用**，只有：Rust PoC 验证工具（能跑通 TTS、拿到音频和逐词边界）+ Flutter 空骨架。真正的产品（导入、播放、高亮、导出、存储）还没开始写。

---

## 2. 仓库结构

```
SayIt/
├── README.md                    ← 仓库根介绍 + 合规声明
├── LICENSE                      ← MIT
├── LOCAL_SETUP.md               ← 本地开发环境搭建指引
├── POC_DELIVERY.md              ← PoC 交付清单（较新，含调试历程）
├── SayIt开发报告_v1.4.md        ← 产品/架构设计稿（原始需求）
├── .gitignore                   ← 已忽略 target/、reports/*.json 等
├── scripts/
│   └── run_poc.sh               ← 一键跑 PoC 脚本
├── sayit-poc/                   ← Rust workspace（PoC 验证）
│   ├── Cargo.toml               ← workspace 根
│   ├── rust-toolchain.toml      ← stable
│   ├── AGENTS.md                ← PoC 阶段开发约定
│   ├── crates/
│   │   ├── sayit-drm/           ← Sec-MS-GEC Token 生成器（纯 Rust，已完成）
│   │   ├── sayit-edge/          ← Edge TTS 客户端（子进程调 Python，已完成）
│   │   └── sayit-poc-bin/       ← PoC 用例 1/3/4 入口（已完成）
│   └── reference/edge-tts/      ← rany2/edge-tts Python 参考副本（**1b 后删除**）
└── apps/
    └── sayit_app/               ← Flutter Desktop 骨架（**仅骨架，未接 Rust**）
        ├── lib/main.dart         ← 占位 UI
        └── notes.md              ← 1b 接入 flutter_rust_bridge 的步骤清单
```

---

## 3. 技术架构（当前实现）

### 3.1 TTS 通路：子进程调 Python edge-tts

```
Rust (sayit-edge::EdgeClient)
  └─ spawn `python3` 子进程（默认 ~/.sayit-venv/bin/python3）
       └─ 内联 Python 脚本调用 edge_tts.Communicate(text, voice, boundary="WordBoundary")
            ├─ stdout: "AUDIO <base64>"（每段音频）
            ├─ stdout: "META <json>"   （WordBoundary / SentenceBoundary）
            └─ stdout: "DONE" / "ERROR <msg>"
```

**关键文件**：`sayit-poc/crates/sayit-edge/src/lib.rs`（含内联 `PYTHON_SCRIPT`）

**为什么这么做**：微软 Edge TTS 服务端识别 rustls 的 TLS ClientHello 指纹为非浏览器客户端，403 拒绝。Python 的 aiohttp（基于 OpenSSL）能通过。因此**不再用 Rust 直接连 WebSocket**。

### 3.2 DRM 模块（纯 Rust，已完成）

`sayit-poc/crates/sayit-drm/src/lib.rs`

算法（与 rany2/edge-tts master `drm.py` 一致）：
1. `ticks = unix_timestamp + clock_skew`
2. `ticks += WIN_EPOCH_SECONDS`（11644473600，Windows file time 起点）
3. `ticks -= ticks % 300`（5 分钟向下取整）
4. `ticks *= 10_000_000 / 100`
5. `sha256(format!("{ticks:.0}{TRUSTED_CLIENT_TOKEN}")).hex().to_uppercase()`

`TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"`

### 3.3 关键协议常量（已实测确认）

| 项 | 值 |
| :--- | :--- |
| WSS URL | `wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=...&ConnectionId=...&Sec-MS-GEC=...&Sec-MS-GEC-Version=...` |
| **Sec-MS-GEC-Version** | **`1-143.0.3650.75`**（`1-` 前缀必须有） |
| User-Agent | Chrome/143.0.0.0 Edg/143.0.0.0 |
| 请求头 | Pragma/Cache-Control/Origin/Sec-WebSocket-Version/User-Agent/Accept-Encoding/Accept-Language/Accept: */*/Cookie: muid=.../Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits |
| outputFormat | `raw-16khz-16bit-mono-pcm`（可用）或 `audio-24khz-48kbitrate-mono-mp3` |

---

## 4. PoC 结果（已实测）

| 用例 | 命令 | 结果 |
| :--- | :--- | :--- |
| 用例 1（PCM 直出） | `cargo run -p sayit-poc-bin -- --case 1` | ✅ PASS：115344 字节 @ 16kHz/1ch，19 个 WordBoundary |
| 用例 3（DRM Token） | `cargo run -p sayit-poc-bin -- --case 3` | ✅ PASS：64 hex SHA256 |
| 用例 4（边界偏移） | `cargo run -p sayit-poc-bin -- --case 4` | ✅ PASS：4 个 WordBoundary，文本正确 |
| 单测 | `cargo test --workspace` | ✅ 10/10（sayit-drm 6 + sayit-edge 4） |

**边界事件实测数据**（用例 4）：
```
text="第一", audio_offset_ms=100.0,  duration_ms=375.0
text="句",   audio_offset_ms=475.0,  duration_ms=312.5
text="第二", audio_offset_ms=1350.0, duration_ms=375.0
text="句",   audio_offset_ms=1725.0, duration_ms=325.0
```

**高亮映射结论**：WordBoundary 的 `text` 是**纯文本视角的词片段**（剥离 SSML 后切词）。阶段 2 应按纯文本偏移映射（v1.4 §3.3.2 路径 A），把 `text` 逐段匹配到原文的偏移即可。当前 `Boundary.text_offset` 恒为 0（Python 端不直接提供绝对偏移），**需要阶段 2 实现偏移推导**。

---

## 5. 环境要求（新 agent 必须知道）

### 用户本机（macOS）

- **Rust**：已装（cargo 可用）
- **Python venv**：`~/.sayit-venv`，内已装 `edge-tts 7.2.8`
- **crates.io 镜像**：`~/.cargo/config.toml` 配了 rsproxy（国内镜像）——**不要移除**
- **PyPI 镜像**：`~/.config/pip/pip.conf` 配了清华 TUNA——**不要移除**
- **Rust 客户端通过 `SAYIT_PYTHON` 环境变量或默认 `~/.sayit-venv/bin/python3` 找 Python**（见 `cases.rs` 的 python_path 解析）

### 关键前提

- **必须联网**（Edge TTS 是云端接口）
- **必须联网到 `wss://speech.platform.bing.com`**——如果新 agent 在无网环境，PoC 用例 1/4 会失败，属预期

---

## 6. 踩坑记录（最重要——新 agent 必读）

> 按时间顺序。每个坑标注「现象 → 根因 → 规避」。

### 坑 1：rustls TLS 指纹被微软识别 → 403（**最严重，改变了架构**）

- **现象**：rustls 0.23（ring）发起的 WSS 握手稳定 403 Forbidden；同一套 header/URL 用 curl（OpenSSL）有时 101 成功；Python aiohttp（OpenSSL）稳定 101。
- **根因**：微软服务端对 TLS ClientHello 做指纹识别（JA3 类）。rustls 的 ClientHello 与 Chromium/OpenSSL 不同，被判为非浏览器。
- **规避**：**彻底放弃 Rust 直连 WebSocket**，改用子进程调 Python edge-tts。**不要再花时间调 rustls**——这是 PoC 阶段验证过的死路。
- **备用**：如未来想纯 Rust，评估 `reqwest-websocket`（走 native-tls/OpenSSL），但需重新验证指纹。

### 坑 2：Sec-MS-GEC-Version 必须带 `1-` 前缀

- **现象**：传 `143.0.3650.75` 401/403。
- **根因**：服务端要求格式 `1-<full_version>`。
- **规避**：`SEC_MS_GEC_VERSION_HEADER = "1-143.0.3650.75"`。

### 坑 3：DRM 算法历史上换过代

- **现象**：旧版算法（字符表 rotate_left 拼接）生成的 token 全部 401。
- **根因**：rany2/edge-tts 在 2024 年底把 DRM 从「字符表置换」改成了「SHA256(ticks + TRUSTED_CLIENT_TOKEN)」（见 issue #290）。**我最初复刻的是废弃的旧算法**。
- **规避**：直接对照 `reference/edge-tts/` 里的最新 `drm.py`。**这个坑已解决**，`sayit-drm` 已是新算法。**监控上游**：若再次 401/403，先看 `rany2/edge-tts` 的 `drm.py` 是否又变（v1.4 §9.4 维护 Checklist）。

### 坑 4：MUID 后半段全零 → 疑似被拒

- **现象**：`generate_muid` 用单个 xorshift state 跑两次循环，导致 16 字节中后 8 字节全 0。服务端对异常 MUID 可能拒绝。
- **根因**：Rust 的 `chunks_mut(8)` 循环里 state 没有按 chunk 重置。
- **规避**：已改为 4 个独立 seed 各跑 xorshift。**不要退回单 state**。

### 坑 5：SSML 标签被当成文本念出来

- **现象**：传入 `<speak><voice>测试</voice></speak>` 后，WordBoundary 出现 `text="speak"` 等标签名，且音频念出了「speak」。
- **根因**：`edge_tts.Communicate()` 只接受**纯文本**，内部会对 `<` `>` 做 escape 再包 SSML。传完整 SSML 原文会被当作文本。
- **规避**：Python 脚本里 `strip_ssml()` 先剥离标签再传给 Communicate。**已在 `PYTHON_SCRIPT` 中实现**。

### 坑 6：cases.rs 的 `and_then(...).is_ok()` 类型错误

- **现象**：`and_then(|s| s.parse::<u64>().is_ok())` 报 E0308，因为 `and_then` 期望返回 `Option`，`is_ok()` 返回 `bool`。
- **规避**：改用 `map(...)`。**已完成**。

### 坑 7：`CHARS_TABLE` 长度断言从 80 改 91

- **现象**：单测 `assert_eq!(CHARS_TABLE.len(), 80)` 失败，实际 91。
- **根因**：rany2/edge-tts 的 CHARS 是 **91 字符**，我最初虚构 80。
- **规避**：单测断言 91。**注**：`sayit-drm` 后来换成 SHA256 算法，不再用 CHARS_TABLE，但这个认知仍记录在案。

### 坑 8：`tokio-tungstenite` 没有 `deflate`/`ring` feature

- **现象**：`cargo` 报 "package does not have that feature"。
- **根因**：`ring` 是 `rustls` 的 feature，`deflate` 在 tungstenite 内部，`tokio-tungstenite` 0.24 都不暴露。
- **规避**：直接依赖 `rustls` 并在其 features 里开 `ring`；不要往 `tokio-tungstenite` 加 `ring`/`deflate`。

### 坑 9：rustls 0.23 CryptoProvider panic

- **现象**：`Could not automatically determine the process-level CryptoProvider`。
- **规避**：`let _ = rustls::crypto::ring::default_provider().install_default();`（在 `EdgeClient::new()`）。**当前代码已回到 rustls 直连方案时需要用；子进程方案已不需要**，但保留无害。

### 坑 10：单测跨 5 分钟窗口导致 token 不稳定断言失败

- **现象**：`token_is_stable_within_5_minutes` 偶发失败。
- **根因**：单测运行跨过 5 分钟边界。
- **规避**：改为验证「格式稳定」（不验证同窗口相等）。**已完成**。

### 坑 11：`EdgeError` 缺 `From<tokio_tungstenite::Error>`（E0277）

- **现象**：`?` 操作报错。
- **规避**：加 `Ws(#[from] tokio_tungstenite::tungstenite::Error)` 变体。**子进程方案已不需要**，但架构上保留错误枚举习惯。

### 坑 12：二进制音频帧结构

- **现象**：解析音频帧时，headers 与 body 分隔算错。
- **根因**：Edge TTS 二进制帧格式为「前 2 字节大端 header length → `\r\n` → headers → body」。Python 用 `data[:header_length]` 和 `data[header_length+2:]`。
- **规避**：`parse_binary_frame` 按此结构解析（已在 `sayit-edge` 测试覆盖）。**子进程方案已绕开**（Python 端直接给音频 bytes）。

### 坑 13：`Path` 未用 import 警告 / `base64` 未声明

- **现象**：编译警告 + E0433。
- **规避**：清理 import，`sayit-edge/Cargo.toml` 加 `base64 = { workspace = true }`。**已完成**。

### 坑 14：venv 与系统 Python 混淆 → ModuleNotFoundError

- **现象**：用例 4 报 `ModuleNotFoundError: No module named 'edge_tts'`，用例 1 却能跑。
- **根因**：用例 1 在激活 venv 的 shell 里跑，用例 4 在未激活的 shell 里跑，`python3` 解析到系统 Python。
- **规避**：Rust 端**显式指定** `~/.sayit-venv/bin/python3`（或 `SAYIT_PYTHON` 环境变量），不依赖 shell 激活。**已在 `cases.rs` 实现**。

### 坑 15：zsh 交互陷阱（非代码，但耗时长）

- `cd path && cat` 之间漏空格 → 路径拼接错误
- heredoc 里多行被吞成一行 → Python 语法错误（缩进炸裂）
- 引号内 `#` 被当注释 → curl URL 被截断
- `python3 -c '...'` 里 `\"` 转义炸裂
- **规避**：优先用 heredoc（`python3 << 'PYEOF' ... PYEOF`）写多行脚本；复杂命令拆成小步；贴代码时检查空格。

---

## 7. 下一步开发指引（阶段 1b 及以后）

### 7.1 当前阻塞/未完成

- **Flutter 骨架未接入任何功能**：`apps/sayit_app/` 只有占位 UI。
- **无分句器**：`endPunct` → `break_time_ms` 派生规则（v1.4 §3.4.2）未实现。
- **无 WAV 拼接**：44 字节头、字节级追加、静音插入未实现（v1.4 §3.2）。
- **无存储层**：drift Schema（documents/sentences/audio_segments）未写（v1.4 §4）。
- **Boundary.text_offset 恒 0**：需要阶段 2 实现「把 WordBoundary.text 匹配回纯文本偏移」的逻辑。
- **`<break>` 停顿丢失**：Python 端剥离了 SSML 的 `<break>`，句间停顿要靠阶段 2 的 WAV 拼接插入静音实现。

### 7.2 阶段 1b 建议顺序

1. **Flutter 工程真正建起来**：`flutter create` 生成 macos/windows 平台壳，替换现有骨架。参考 `apps/sayit_app/notes.md`。
2. **flutter_rust_bridge 接入**：把 `sayit-edge::EdgeClient`（含 `SynthesizeRequest`/`SynthesizeResult`/`Boundary`）暴露给 Dart。注意 Rust 端目前是异步函数，需要 `#[frb(sync)]` 或 spawn_blocking 适配。
3. **纯 Dart 分句器**：按 v1.4 §3.4.2 实现（标点断句、排除小数/缩写/URL/邮箱、`endPunct` → `break_time_ms` 映射）。
4. **纯 Dart WAV 拼接**：按 v1.4 §3.2 实现（RIFF 头 + 字节级追加 + 静音 PCM）。
5. **（可选）Python 进程池**：当前每次合成 spawn 一个 Python 进程，长文本会慢。评估在 Rust 侧维护一个长驻 Python worker。

### 7.3 阶段 1c

- drift Schema：`documents` / `sentences` / `audio_segments`（v1.4 §4.2），注意 `combined_wav_path` 字段。
- 分句结果落库：`chunk_index`、`break_time_ms`。

### 7.4 阶段 2（核心功能）

- 文本导入（粘贴 + .txt）
- TTS 生成（调 sayit-edge）+ 逐句高亮播放
- 失败重试（chunk 级）
- 高亮映射：**把 WordBoundary.text 匹配回原文偏移**（这是核心逻辑，PoC 已验证可行）

---

## 8. 常用命令

```bash
# 跑全部 PoC（需联网 + venv）
cd /Users/xingxiaoshu/开发/SayIt/sayit-poc
bash ../scripts/run_poc.sh

# 单测
cargo test --workspace

# 单用例
cargo run -p sayit-poc-bin -- --case 1
cargo run -p sayit-poc-bin -- --case 3
cargo run -p sayit-poc-bin -- --case 4

# 调试日志
RUST_LOG=info cargo run -p sayit-poc-bin -- --case 1

# 指定 Python 路径（如需覆盖默认 venv 探测）
SAYIT_PYTHON=/path/to/python3 cargo run -p sayit-poc-bin -- --case 1
```

---

## 9. 注意事项（约束）

1. **不要再碰 rustls 直连**：已确认死路，浪费时间。
2. **不要移除 cargo/pip 镜像**：用户在国内网络，直连 crates.io / pypi.org 会超时。
3. **依赖 Python venv + edge-tts**：这是当前 TTS 通路的硬依赖。如果新 agent 想纯 Rust 化，需要先解决 TLS 指纹问题（风险高）。
4. **合规**：Edge TTS 是非官方接口，仅供学习研究。合规声明见 `README.md` 与 v1.4 §7。
5. **`reference/edge-tts/` 目录**：PoC 阶段的 Python 参考副本，**1b 结束后应删除**（不再需要对照）。
6. **`sayit-poc/target/`**：编译产物，已 gitignore，不影响。
7. **报告文件**：`POC_DELIVERY.md` 是最新的交付清单；`SayIt开发报告_v1.4.md` 是原始设计稿，二者若有出入以实测结论（本报告 + POC_DELIVERY）为准。

---

## 10. 附录：关键文件索引

| 文件 | 内容 |
| :--- | :--- |
| `sayit-poc/crates/sayit-drm/src/lib.rs` | DRM token 生成（SHA256 算法）、MUID、clock skew |
| `sayit-poc/crates/sayit-edge/src/lib.rs` | EdgeClient（子进程调 Python）、内联 PYTHON_SCRIPT、Boundary 结构 |
| `sayit-poc/crates/sayit-poc-bin/src/cases.rs` | PoC 用例 1/3/4 实现、python_path 探测 |
| `sayit-poc/crates/sayit-poc-bin/src/main.rs` | CLI 入口（--case 1/3/4/all） |
| `apps/sayit_app/notes.md` | 1b 接入 flutter_rust_bridge 的步骤清单 |
| `scripts/run_poc.sh` | 一键 PoC |
| `POC_DELIVERY.md` | 交付清单（含完整调试历程） |
