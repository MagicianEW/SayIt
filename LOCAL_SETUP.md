# SayIt 本地开发指引（不依赖 Cowork App / Claude 账号）

> 你想跑通 PoC，但没装 Cowork 桌面 App / 没注册 Claude 账号。这条路完全走得通：
> **只需 Rust 工具链 + 一个能跑 `python3` 的环境（可选）**。

## 1. 安装 Rust

### macOS / Linux
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
# 接受默认安装即可
. "$HOME/.cargo/env"
rustc --version   # 应该 >= 1.75
cargo --version
```

### Windows
下载 <https://rustup.rs/> 的 `rustup-init.exe`，按默认安装。安装完成后重启终端。

## 2. （可选）安装 Python 3

仅当你需要 Rust 手写 token 与 Python 参考实现的**对照验证**时才需要。

- macOS：`brew install python3` 或用系统自带
- Windows：从 <https://www.python.org/downloads/> 下载
- Linux：`sudo apt install python3` / `sudo dnf install python3`

不需要 pip / 任何第三方库——`reference/edge-tts/sec_ms_gec.py` 只用标准库。

## 3. 一键跑通 PoC

```bash
cd /Users/xingxiaoshu/开发/SayIt
bash scripts/run_poc.sh
```

脚本会自动：
1. 跑 `cargo test --workspace`（离线单元测试）
2. 跑用例 3：DRM Token 生成（离线）
3. （若 Python 可用）对照 Rust 与 Python 的 token 串
4. 跑用例 1 + 4：需要联网到 `wss://speech.platform.bing.com`

跳过联网用例（纯离线验证）：
```bash
bash scripts/run_poc.sh --skip-network
```

## 4. 产物位置

跑完后看 `sayit-poc/reports/`：

| 文件 | 决策含义 |
| :--- | :--- |
| `case1_pcm.json` | PCM 直出是否成功 → 决定走 raw-16khz 路径还是退到 MP3 兜底（1b） |
| `case3_drm.json` | DRM Token 形状 → 必须 100% 通过 |
| `case4_boundary_offset.json` | SSML 边界偏移决策（plain_text / ssml_text / ambiguous / no_boundaries） |
| `boundary_offset_semantics.md` | **关键决策文件** —— 决定阶段 2 用哪种映射策略 |
| `summary.json` | 全部用例汇总 |

## 5. 阶段 1b 之后需要什么

阶段 1b 接入 flutter_rust_bridge，需要**额外**装：

- Flutter SDK（<https://docs.flutter.dev/get-started/install>）—— macOS / Windows 桌面端
- protoc（Protocol Buffers 编译器）—— `brew install protobuf` / `apt install protobuf-compiler` / Windows 见 protoc 官方
- Dart `build_runner` —— `dart pub global activate ...`，在 1b 步骤清单里有

到时再按 `apps/sayit_app/notes.md` 一步步走即可。

## 6. 常见问题

**Q：rustc 太旧？**  
A：`rustup update stable`

**Q：`cargo build` 报 SSL 错？**  
A：Windows 上常见，需要 `cargo install --version 0.10.3 sqlx-cli` 之外，先确认 rustls 已装：
```bash
rustup default stable
rustup component add rustfmt clippy
```

**Q：跑用例 4 时 PoC 没产生 boundaries？**  
A：可能服务端拒连（403）或返回空。检查日志 `RUST_LOG=debug cargo run -p sayit-poc-bin -- --case 4 -v`。这是预期内的失败：v1.4 §9.2 已经写明"边界缺失"是中等风险降级路径。

**Q：token 对照显示不一致？**  
A：核对 `sayit-drm/src/lib.rs` 中的 `CHARS`（80 字符）与 `INDEX_CHARS`（16 字符）是否与 `reference/edge-tts/sec_ms_gec.py` 完全对齐。差异通常来自字符表抄错。