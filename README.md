# SayIt（说吧）

> 本地桌面文本转语音（TTS）工具，支持多语种、多音色、逐句高亮。
> 调用 Microsoft Edge 的在线 TTS 服务，合成过程在本机完成，不经过第三方服务器中转。

| 平台 | 构建 |
|------|------|
| macOS / Windows / Linux | ![Build](https://github.com/MagicianEW/SayIt/actions/workflows/build.yml/badge.svg) |

## 功能特点

- **多语种支持**：支持 37+ 种语言，包括中文（简体/粤语/台语）、英语、日语、韩语等
- **多音色选择**：多种音色可选，支持按语种和性别筛选
- **参数可调**：可调节语速、音高、音量
- **逐句播放**：文本分句播放，逐句高亮不漂移
- **导出功能**：支持导出 MP3（24kHz / 48kbps / 单声道），文件名格式 `序号_前10个字.mp3`
- **设定导入导出**：可保存和恢复音色、语速等偏好设置

## 架构

```
┌──────────────┐  Process.run  ┌───────────────────┐  spawn  ┌────────────────┐
│  Flutter UI  │ ────────────▶ │  sayit-poc (Rust) │ ──────▶ │ Python edge_tts│
│    (Dart)    │ ◀──────────── │   独立可执行程序    │ ◀────── │                │
└──────────────┘  stdout JSON  └───────────────────┘ MP3 字节 └────────────────┘
```

- **Dart 与 Rust 之间不用 `flutter_rust_bridge`**，而是由 Dart 用 `Process.run` 调起
  独立可执行程序 `sayit-poc`，Rust 把结果以 JSON 打到 stdout。这样 Rust 端可以脱离
  Flutter 单独调试，也不用维护一份要提交进仓库的桥接生成码。
  完整取舍见 [`apps/sayit_app/notes.md`](./apps/sayit_app/notes.md)。
- Rust workspace 三个 crate：
  - `sayit-drm` —— Edge TTS 的 DRM Token 生成
  - `sayit-edge` —— WebSocket 客户端，并负责调起 Python 侧的 `edge_tts`
  - `sayit-poc-bin` —— 命令行入口，产物即 `sayit-poc`
- Python 解释器的查找顺序：`SAYIT_PYTHON` 环境变量 → `~/.sayit-venv` → `python` → `python3`。
- 音频格式被 `edge_tts` 限死：其 `Communicate.__init__` 里写死了 MP3 输出，
  没有 `output_format` 参数，**拿不到 PCM**。所以合成与导出都直接拼接 MP3 字节，
  逐句高亮的时间轴按已写入字节数 ÷ 6 换算毫秒（48 kbps = 6000 字节/秒），精确不漂移。

## 目录结构

```
SayIt/
├── VERSION                  ← 版本号唯一来源（不要手改各平台文件）
├── scripts/
│   ├── sync_version.py      ← VERSION → pubspec.yaml / Cargo.toml / build_info.dart
│   └── sync_app_name.py     ← 应用名 → 9 个平台元数据文件
├── apps/sayit_app/          ← Flutter 桌面前端
│   ├── lib/                 ← UI、分句、播放、导出
│   ├── test/                ← 分句规则回归测试
│   ├── macos/  windows/     ← 平台壳（已随仓库提交）
│   └── linux/               ← 未提交，由 CI 现场生成
└── sayit-poc/               ← Rust workspace
    └── crates/
        ├── sayit-drm/       ← Edge DRM Token
        ├── sayit-edge/      ← WebSocket 客户端 + 调用 Python edge_tts
        └── sayit-poc-bin/   ← 命令行入口（产物 sayit-poc）
```

## 下载

从 [Releases](https://github.com/MagicianEW/SayIt/releases) 页面下载最新版本。各平台产物：

| 平台 | 文件 | 安装方式 |
|------|------|----------|
| macOS | `SayIt_macos_<ver>.dmg` | 拖进 Applications，首次需移除 quarantine（见下文） |
| Windows | `SayIt_windows_<ver>.zip` | 解压即用的便携版 |
| Linux | `SayIt_linux_<ver>.AppImage` | 加可执行权限后直接运行，**无需安装 libmpv** |

## 前置依赖

SayIt 需要 **Python 3.8+** 和 **edge_tts** 模块。

### 安装 Python 和 edge_tts

**macOS**（通常已预装 Python）：
```bash
# 检查 Python 版本
python3 --version

# 安装 edge_tts
pip3 install edge_tts
# 或使用虚拟环境
python3 -m venv ~/.sayit-venv
~/.sayit-venv/bin/pip install edge_tts
```

**Windows**：
```powershell
# 安装 Python（如果没有）
# 从 https://python.org 下载 Python 3.8+

# 安装 edge_tts
pip install edge_tts
```

**Linux**：
```bash
sudo apt install python3 python3-pip  # Debian/Ubuntu
sudo yum install python3 python3-pip    # Fedora/RHEL
pip3 install edge_tts
```

### 验证安装
```bash
python3 -c "import edge_tts; print('edge_tts OK')"
```

### 自定义 Python 路径（可选）
如果 Python 不在默认路径，可通过环境变量指定：
```bash
export SAYIT_PYTHON=/path/to/your/python3
```

### 音频播放后端（Windows / Linux 需要）

macOS 由 `just_audio` 自带原生实现，下面这段不用管。

Windows 与 Linux 上 `just_audio` 官方**不带**播放后端，直接用会在第一次播放时抛
`MissingPluginException(No implementation found for method init on channel
com.ryanheise.just_audio.methods)`。本项目用 `just_audio_media_kit` 把播放调用桥接到
`media_kit`（底层 libmpv），两个平台共用同一套后端 —— 避免两个实现同时抢注同一个
MethodChannel。初始化只需在 `main()` 里调一次 `JustAudioMediaKit.ensureInitialized()`。

| 平台 | libmpv 来源 | 是否需要额外安装 |
|------|-------------|------------------|
| Windows | `media_kit_libs_windows_audio` 随包自带 libmpv / FFmpeg DLL | 否，解压即用 |
| Linux | AppImage 内已打包 libmpv 及其依赖树（CI 用 `scripts/bundle_libmpv_linux.sh` 递归收集） | 否，AppImage 直接运行 |

> **Linux 的 libmpv 是怎么打进包的**：`libmpv2` 自身依赖 40 多个库（libplacebo、
> libmujs、libbluray、libsdl2、ffmpeg 各件……）。CI 不再只拷一个 `libmpv.so.2`，
> 而是用 `ldd` 递归把整棵依赖树拷进 AppImage 的 `lib/`，并把每个库的 rpath 改成
> `$ORIGIN`，使依赖树内部自洽；同时排除 libc / libstdc++ / libGL / libgtk 等系统核心库，
> 避免 ABI 冲突与「抢在系统库前生效」。这样发布的 AppImage **无需用户再装 libmpv** 即可播放。
> 随包分发的第三方库许可证见仓库根 `THIRD_PARTY_LICENSES`（本项目自身为 GPL-3.0-or-later，
> 与 libmpv 同源，相容）。

> 之所以不用 `just_audio_windows`：它体积更小，但对「读取字节流」标注为 *not tested*，
> 而本应用的 `_BytesAudioSource` 正是把内存里的 MP3 交给 just_audio 的本地 HTTP 代理
> 再喂给播放器，走的就是字节流这条路；且它与 `just_audio_media_kit` 在 Windows 上会冲突。

## 命名与版本

**应用名**：英文 `SayIt`，中文「说吧」。

- 英文名用于技术标识：可执行文件名、CMake 工程名、macOS 的 `CFBundleName`、
  Windows 文件属性里的产品名。
- 中文名用于面向用户的显示：Windows 窗口标题、界面标题、
  macOS 的 `CFBundleDisplayName`。

两个名字和各平台的版本号都**由脚本统一同步，不要手改各平台文件**
（改了会被脚本覆盖）：

| 用途 | 单一来源 | 同步命令 |
|------|----------|----------|
| 应用名 | `scripts/sync_app_name.py` 顶部的 `EN_NAME` / `ZH_NAME` | `python3 scripts/sync_app_name.py` |
| 版本号 | 仓库根目录的 `VERSION` 文件 | `python3 scripts/sync_version.py` |

`sync_version.py` 把 `VERSION` 写进 `apps/sayit_app/pubspec.yaml` 和
`sayit-poc/Cargo.toml`，并生成 `apps/sayit_app/lib/src/build_info.dart`
供界面显示版本号。Flutter 工具链再据此生成 macOS `Info.plist` 和 Windows
exe 的版本资源；`sayit-poc --version` 读的也是同一个值。

改版本号：

```bash
# 直接改 VERSION 文件后同步
python3 scripts/sync_version.py

# 或一条命令搞定
python3 scripts/sync_version.py --set 0.2.0

# 校验各处是否一致（提交前 / CI 检查用）
python3 scripts/sync_version.py --check
python3 scripts/sync_app_name.py --check
```

> Linux 的 `linux/` 目录没有提交进仓库，由 CI 在构建时用 `flutter create`
> 生成，生成后立刻调用 `sync_app_name.py` 同步名字。

## 发版流程

CI 由 **`release: published`** 触发 —— **不是** tag 推送触发。必须先在 GitHub 上
发布一个 Release，构建任务才会启动，完成后把产物回传到同一个 Release。

```bash
# 1. 定版本号并同步
python3 scripts/sync_version.py --set 0.1.4
python3 scripts/sync_version.py --check
python3 scripts/sync_app_name.py --check
git add -A && git commit -m "chore: bump version to 0.1.4"
git push origin main

# 2. 发布 Release（这一步会创建 tag v0.1.4 并触发构建）
gh release create v0.1.4 --title "SayIt v0.1.4" --generate-notes
```

要点：

- Release 必须是**已发布**状态才触发，存草稿不会触发。
- 构建时 CI 会把 tag 里的版本号（去掉 `v` 前缀）写回 `VERSION` 再重新同步一遍，
  所以**产物文件名、打包进二进制的版本资源、`sayit-poc --version` 三者始终一致**。
- 三个平台并行构建，全部成功后 `release` job 才把 `.dmg` / `.zip` / `.AppImage`
  上传到该 Release。构建产物同时保留为 Actions artifact，14 天有效。
- 想只做一次测试构建、不发布，用 `workflow_dispatch` 手动触发（可指定版本号，
  留空则用仓库 `VERSION` 里的值）。

### 同一个版本号重新出包

修完 bug 但版本号不动（比如 v0.1.4 要重出）时，有两个前提容易漏：

1. **tag 必须指向新提交** —— CI 按 release 对应 tag 的提交构建，光推 `main` 没用。
2. **必须重新触发 `release: published`** —— 只推 tag 不触发任何构建。

```bash
# 0. 取 release id
gh api repos/<owner>/<repo>/releases/tags/v0.1.4 --jq .id

# 1. 把 tag 移到新提交（tag 已存在，要 --force）
git tag -f v0.1.4 <新提交>
git push --force origin v0.1.4

# 2. 重新触发：Release 先置回草稿、再重新发布
gh api -X PATCH repos/<owner>/<repo>/releases/<release_id> -F draft=true
gh api -X PATCH repos/<owner>/<repo>/releases/<release_id> -F draft=false
```

> 别用「删 Release + 删 tag 再重建」：正文会丢，而且中途失败容易留下一个游离的
> 草稿 Release。上面的草稿往返能同时保留正文和 tag 关联。

## macOS 安装说明

⚠️ 当前 release 为**临时签名**（ad-hoc），未通过 Apple 公证。首次打开会提示"无法验证开发者"。

**绕过 Gatekeeper 的方法（三选一）：**

**方法 1：右键打开（推荐）**
1. 在 Finder 中找到 `SayIt.app`
2. **右键点击** → **打开**
3. 弹出警告时再次点 **打开**

**方法 2：终端命令**
```bash
# 移除下载 quarantine 属性
xattr -dr com.apple.quarantine /Applications/SayIt.app

# 或者允许任意来源（系统设置）
sudo spctl --master-disable
```

**方法 3：移动到 Applications 后尝试**
1. 拖动 `SayIt.app` 到 `/Applications/`
2. 双击打开

> 💡 正式发布需要 Apple Developer 账号（$99/年）进行签名 + 公证，本项目目前未配置。

## 协议

本项目遵守 **GPL-3.0-or-later** 协议开源。

## 许可

本仓库源码采用 [GNU General Public License v3.0-or-later](./LICENSE)。
