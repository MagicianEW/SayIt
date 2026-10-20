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
cd /path/to/SayIt   # 换成你的仓库路径
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

## 5. Flutter 工具链

### 5.1 装 SDK 并配 PATH

Flutter SDK（<https://docs.flutter.dev/get-started/install>）—— macOS / Windows 桌面端都要。
装好后把 `bin` 目录加进 PATH（`git clone` 方式和压缩包方式二选一）：

```bash
# 方式 A：git clone（推荐，能用 git 切版本）
git clone https://github.com/flutter/flutter.git -b stable ~/flutter

# 方式 B：官方压缩包，解压到 ~/flutter 后同样要把 ~/flutter/bin 加进 PATH
```

macOS / zsh 加到 `~/.zprofile` 与 `~/.zshrc`（用带判断的写法，重复 source 不会越加越长）：

```bash
# >>> flutter toolchain >>>
if [ -d "$HOME/flutter/bin" ]; then
  case ":$PATH:" in
    *":$HOME/flutter/bin:"*) ;;
    *) export PATH="$HOME/flutter/bin:$PATH" ;;
  esac
fi
# <<< flutter toolchain <<<
```

验证：

```bash
flutter --version   # Flutter 3.44.x stable / Dart 3.12.x
flutter doctor      # 桌面端只看 Xcode(ios/macos) 与 Chrome 是否 ✓
```

> `flutter doctor` 里 Android toolchain 报红是正常的 —— 本项目只做桌面端，
> 不需要 Android SDK。

### 5.2 日常三个命令

```bash
cd apps/sayit_app
flutter pub get     # 拉依赖
flutter test        # 分句单测 + 界面冒烟 + 帮助文案回归（共 13 个用例）
flutter analyze     # 静态检查
```

Rust 侧：

```bash
cargo test --manifest-path sayit-poc/Cargo.toml
```

CI 的 `test` job 会跑上面这些（外加 `sync_version.py --check` /
`sync_app_name.py --check`），所以**本地能跑通就不用担心发版被卡**。

### 5.3 ⚠️ 坑：项目路径含中文时 `flutter analyze` 会崩

如果仓库路径里带非 ASCII 字符（例如本机 clone 到了 `~/开发/SayIt`），
`flutter analyze` 会让 analysis server 崩掉并报：

```
Unhandled exception:
FormatException: Unexpected end of input (at character 353)
  .../开发/SayIt/apps/sayit_app/..."],"capabilities":{"window":{"workDoneProgress":true
```

这是 Dart analysis server 的 LSP 通道在**非 ASCII 的 workspace URI** 上把
`Content-Length` 按字符数而不是字节数算，导致消息被截断。同一份代码拷到
纯 ASCII 路径下 analyze 完全正常，所以不是代码问题。

- `flutter test` **不受影响**（它走 `flutter_tester`，不经过 analysis server）。
- CI **不受影响**：GitHub runner 的工作目录是 `/home/runner/work/SayIt/SayIt`，纯 ASCII。

本地想跑 analyze，把源码同步一份到纯 ASCII 路径再跑：

```bash
rsync -a --delete --exclude build --exclude .dart_tool \
  apps/sayit_app/ /tmp/sayit_ascii/
cd /tmp/sayit_ascii && flutter pub get && flutter analyze
```

或直接把仓库 clone 到 `~/dev/SayIt` 这类纯 ASCII 路径。

### 5.4 analyze 的既有告警（不影响 CI）

当前 `flutter analyze` 会报 3 条 warning，全部来自 just_audio 的实验性 API
（`_BytesAudioSource` 用了 `StreamAudioSource` / `StreamAudioResponse`）：

```
warning • 'StreamAudioSource' is experimental ... • lib/main.dart • experimental_member_use
warning • 'StreamAudioResponse' is experimental ... • lib/main.dart • experimental_member_use
warning • 'StreamAudioResponse' is experimental ... • lib/main.dart • experimental_member_use
```

所以 CI 里用的是 `flutter analyze --no-fatal-warnings --no-fatal-infos` ——
只对真正的 error 失败。**别改成默认的 fatal-warnings，一改这 3 条就会把发版卡住。**

### 5.5 `flutter pub get` 会动 `pubspec.lock`

本机 Dart 版本低于 lock 文件里锁定的版本时，`pub get` 会把几个传递依赖
降级（实测：`matcher` / `meta` / `test_api` / `vector_math`），
`pubspec.lock` 会出现与本次改动无关的 diff。**提交前记得 `git checkout` 掉它**：

```bash
git checkout -- apps/sayit_app/pubspec.lock
```

> 例外：本次新增 `charset_codec`（为了解 GB18030）时 lock 必须带上这个依赖，
> 那种情况下 lock 的改动要提交，只是里面会混着上面那几个无关降级 ——
> CI 用的 Flutter 更新，会自动把它们升回去，不影响正确性。

> `charset_codec` 自带一个 6.7MB 的生成代码文件（CPython 的 MBCS 编解码全表），
> 所以**第一次**编译会明显变慢（实测首次 `flutter test` 两分钟以上），
> 之后走增量缓存很快（5 秒）。不用怀疑是不是环境坏了。

### 5.6 不需要的工具

**不需要** protoc，也**不需要** `build_runner`：Dart 与 Rust 不走 flutter_rust_bridge，
而是 `sayit-poc` 子进程 + stdout JSON（`apps/sayit_app/notes.md` 有完整说明），
因此没有 protobuf 定义、也没有需要代码生成的桥接层。

### Windows 本地构建的两个硬性前提

Windows 上 `flutter build windows` 有两道容易卡住的门槛，缺一个都编译不过：

1. **Visual Studio 的「使用 C++ 的桌面开发」工作负载**（含 MSVC 生成工具 + C++ CMake 工具）。
   只装「Visual Studio 生成工具」而不勾这个工作负载是不够的 —— 报错是
   `Unable to find suitable Visual Studio toolchain`。用 `flutter doctor -v` 可以看到
   具体缺哪些组件，按提示在 VS Installer 里勾上即可。
2. **开启开发者模式**（设置 → 系统 → 开发者选项）。
   只要项目里有带原生代码的插件，Flutter 就要在
   `windows/flutter/ephemeral/.plugin_symlinks/` 下建符号链接，而普通账户建符号链接需要
   这个开关；没开会报 `Building with plugins requires symlink support.`
   （`flutter pub get` 每次都会重建该目录，所以这个开关是长期需要，不是一次性设置）。
   macOS / Linux 没有这个要求。

```powershell
# 检查开发者模式是否已开（返回 1 即为已开）
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name AllowDevelopmentWithoutDevLicense
```

> 只**运行**已发布的 Windows 包不需要以上任何一条 —— 符号链接和 MSVC 只影响**编译**。

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

**Q：`Building with plugins requires symlink support.` 又没管理员权限，怎么办？**  
A：正解是开启开发者模式。确实开不了（比如没有管理员权限）时，可以退而用**目录联接**
顶替符号链接 —— 建目录联接不需要管理员权限，而 Flutter 对已存在的链接会直接跳过：

```powershell
$base = "apps\sayit_app\windows\flutter\ephemeral\.plugin_symlinks"
$pub  = "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev"
# 插件名和路径以 apps/sayit_app/.flutter-plugins-dependencies 里 windows 列表为准
New-Item -ItemType Junction -Path "$base\media_kit_libs_windows_audio" `
         -Target "$pub\media_kit_libs_windows_audio-1.0.9"
```

注意 `flutter pub get` 每次都会以 `force` 重建该目录，会把联接清掉，所以这个办法
只适合「pub get 之后、build 之前」临时补一次。长期还是建议开开发者模式。

**Q：`Unable to find suitable Visual Studio toolchain.`？**  
A：VS 生成工具装了但没勾「使用 C++ 的桌面开发」工作负载。跑 `flutter doctor -v`
会列出具体缺失组件，在 VS Installer 里勾上补齐即可。注意只有带原生代码的插件才会
用到它 —— 只跑 Rust PoC 和单元测试时不需要。

**Q：token 对照显示不一致？**  
A：核对 `sayit-drm/src/lib.rs` 中的 `CHARS`（80 字符）与 `INDEX_CHARS`（16 字符）是否与 `reference/edge-tts/sec_ms_gec.py` 完全对齐。差异通常来自字符表抄错。