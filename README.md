# SayIt （说吧）

> 本地桌面文本转语音（TTS）工具，支持多语种、多音色

## 功能特点

- **多语种支持**：支持 37+ 种语言，包括中文（简体/粤语/台语）、英语、日语、韩语等
- **多音色选择**：多种音色可选，支持按语种和性别筛选
- **参数可调**：可调节语速、音高、音量
- **逐句播放**：文本分句播放，音频拼接无损
- **导出功能**：支持导出 MP3 格式音频
- **设定导入导出**：可保存和恢复音色、语速等偏好设置

## 构建状态

| 平台 | 状态 |
|------|------|
| Windows | ![Build](https://github.com/MagicianEW/SayIt/actions/workflows/build.yml/badge.svg) |
| macOS | ![Build](https://github.com/MagicianEW/SayIt/actions/workflows/build.yml/badge.svg) |

## 技术栈

- **前端**：Flutter (Dart)
- **后端**：Rust
- **TTS 引擎**：Microsoft Edge TTS

## 下载

从 [Releases](https://github.com/MagicianEW/SayIt/releases) 页面下载最新版本。

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
