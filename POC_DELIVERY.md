# SayIt PoC 阶段交付清单（v1.4 §6 阶段 1a）

> **生成时间**：2026-08-08
> **最终结论**：阶段 1a **PASS**——通过 PyO3 嵌入 Python `edge-tts` 绕开 rustls TLS 指纹问题。
> 用例 1（PCM 直出）、用例 3（DRM Token）、用例 4（边界偏移）**全部通过**。

## 已完成（本会话内）

### 工程结构
- [x] `README.md`：仓库根，含 v1.4 §7 完整合规声明
- [x] `LICENSE`：MIT
- [x] `.gitignore`：Rust / Flutter / PoC 临时文件分类
- [x] `sayit-poc/`：Rust workspace + 子 crate 结构
- [x] `apps/sayit_app/`：Flutter Desktop 骨架（pubspec + lib/main.dart）

### Rust 端（sayit-poc/）
- [x] `crates/sayit-drm/`：Sec-MS-GEC Token（按 `rany2/edge-tts` master `drm.py` 实现：SHA256 + 5 分钟对齐 + TRUSTED_CLIENT_TOKEN）+ MUID（4 独立 xorshift seed 填满 16 字节，避免全零）+ 6 个单测
- [x] `crates/sayit-edge/`：**PyO3 子进程嵌入 Python edge-tts**（绕开 rustls TLS 指纹问题）+ 4 个单测
- [x] `crates/sayit-poc-bin/`：用例 1（PCM 优先 + MP3 兜底）/ 3 / 4，报告落 `reports/`
- [x] `reference/edge-tts/`：rany2/edge-tts Python 源码参考副本（1b 后删除）

### 单测结果（实测）
- `sayit-drm`：**6/6 通过**（token 64 hex / skew / MUID 全 hex 等）
- `sayit-edge`：**4/4 通过**（默认路径 / 自定义路径 / 输出格式常量 / 默认配置）
- `sayit-poc-bin`：编译通过

### PoC 实测结论（用户本机执行）

| 用例 | 路径 | 结果 | 关键数据 |
| :--- | : | :--- | :--- |
| 1 | `cargo run -p sayit-poc-bin -- --case 1` | **PASS** | 115344 字节 @ 16000Hz/1ch, 19 个 WordBoundary |
| 3 | `cargo run -p sayit-poc-bin -- --case 3` | **PASS** | DRM token 64 hex SHA256 |
| 4 | `cargo run -p sayit-poc-bin -- --case 4` | **PASS** | 26 个 WordBoundary，决策 = `ambiguous` |

### 关键决策文件

`sayit-poc/reports/boundary_offset_semantics.md`：

- 决策 = **`ambiguous`**
- 含义：WordBoundary 的 text 字段同时出现在 SSML 原文与纯文本视图中
- 含义：服务端对 `<speak><voice>` 包裹的文本按词发 boundary，文本片段从 SSML 拆出来后仍是 SSML 视角
- **v1.4 §3.3.2 决策**：阶段 2 需要维护"SSML 偏移 → 纯文本偏移"转换表（路径 B），不能直接按纯文本偏移匹配

## 调试历程（修复顺序）

1. **401 Unauthorized** → DRM 算法错误：从老版字符表 rotate 改为 SHA256 + 5 分钟对齐
2. **rustls CryptoProvider panic** → 加 `rustls` 显式依赖 + `ring` feature
3. **cases.rs 旧签名错误** → sayit-drm 重写后更新调用方
4. **CHARS 字面量长度 91 != 80** → 单测断言改为 91（与 Python 上游对齐）
5. **Sec-MS-GEC-Version 缺 `1-` 前缀** → 改为 `1-143.0.3650.75`
6. **URL 参数顺序** → 与 Python 一致
8. **MUID 后半段全零** → 4 独立 xorshift seed 填满 16 字节
9. **Accept: */* 缺失** → 显式添加
10. **`Sec-WebSocket-Extensions` 缺失** → 加 `permessage-deflate; client_max_window_bits`
11. **403 时钟偏差重试** → 读服务端 Date header 调 `adj_clock_skew_seconds`
12. **raw-16khz-pcm 降级 MP3** → 双路径尝试
13. **rustls TLS 指纹被识破** → **改用 PyO3 子进程嵌入 Python edge-tts**（绕开 TLS 层）

## PyO3 子进程方案（最终方案）

`sayit-edge` 不再直接发起 WebSocket，而是：

1. spawn `python3` 子进程（venv 内 `~/.sayit-venv/bin/python3`）
2. 通过 stdin 发 JSON 请求
3. 通过 stdout 流式接收 `AUDIO <base64>` 与 `META <json>` 行
4. stderr 用于错误诊断

**好处**：rustls TLS ClientHello 指纹问题绕开；Python edge-tts 已验证可跑通。

**限制**：
- 每次合成起一个 Python 进程（性能不是 PoC 关注点）
- 需要用户本机装 edge-tts（`pip install edge-tts`）
- 1b 阶段评估 Python 进程池复用

## v1.4 §9.2 决策（最终）

| 用例 | 路径 | 决策 |
| :--- | :--- | :--- |
| 用例 1 | PCM 直出 | ✅ 通过，进入阶段 1b |
| 用例 3 | DRM Token | ✅ 通过 |
| 用例 4 | 边界偏移 | ✅ 决策 = ambiguous → 阶段 2 维护 SSML→纯文本 偏移转换表 |
| 路径 A 直出 | raw-16khz-pcm | ✅ 已用 PyO3 验证（115344 字节） |
| 路径 B 兜底 | symphonia 解码 | 推迟到 1b 末 / 2 初 |

## 待办（用户在本机执行）

### 跑完整 PoC 收尾

```bash
cd /Users/xingxiaoshu/开发/SayIt/sayit-poc
cargo test --workspace
cargo run -p sayit-poc-bin -- --case 1
cargo run -p sayit-poc-bin -- --case 3
cargo run -p sayit-poc-bin -- --case 4
ls reports/
```

### 阶段 1b 准备

1b 接入：
- `flutter_rust_bridge` 把 `sayit-edge::EdgeClient` 暴露给 Dart
- 分句器（`endPunct` → `break_time_ms` 派生）
- 纯 Dart WAV 拼接工具类（44 字节头、字节级追加、静音 PCM 插入）
- 评估 Python 进程池复用（多次合成的性能）

## 范围外（推迟到对应阶段）

| 项 | 阶段 |
| :--- | :--- |
| flutter_rust_bridge 接入 | 1b |
| WAV 拼接工具类 | 1b |
| 文本分块器 / 分句器 | 1b |
| drift SQLite Schema | 1c |
| Riverpod 状态管理 | 2 |
| UI 细化 / 语音下拉 / 导出按钮 | 2 |
| 性能调优 / MP3 压缩导出 | 3 |
| README / CI / 发布 | 4 |

## 注意事项

1. **PyO3 子进程方案是 PoC 选择**——1b 阶段评估是否换其他栈（如 `reqwest-websocket` 走 OpenSSL）
2. **DRM 算法正确**——`sayit-drm` 与 master `drm.py` 行为等价
4. **Sec-MS-GEC-Version 格式 `1-{version}`** 是关键（仅 `{version}` 会拒）
5. **MUID 必须全 hex**——后半段全零的 MUID 会触发服务端校验失败
6. **WordBoundary text.Text** —— v1.4 §3.3.2 决策依据；阶段 2 维护"SSML → 纯文本"偏移转换表（路径 B）