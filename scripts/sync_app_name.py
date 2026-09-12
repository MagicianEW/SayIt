#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把应用名同步到各平台元数据文件。

**应用名的唯一来源是本文件顶部的 `EN_NAME` / `ZH_NAME` 两个常量。**
不要直接去改 runner 里的名字，改了也会被本脚本覆盖。

约定（见 README「命名」一节）：

  * 英文名 `SayIt` —— 技术标识：可执行文件名、CMake/工程名、
    Windows 文件属性的产品名、macOS 的 CFBundleName。
  * 中文名 `说吧` —— 面向用户的显示名：Windows 窗口标题、
    macOS 的 CFBundleDisplayName、Dart 界面的标题。

同步目标：

  Windows
    - `windows/runner/main.cpp`        窗口标题（中文名）
    - `windows/CMakeLists.txt`         project() / BINARY_NAME（英文名）
    - `windows/runner/Runner.rc`       exe 版本资源里的产品名、公司名、版权

  macOS
    - `macos/Runner/Info.plist`        CFBundleName（英文名）+ CFBundleDisplayName（中文名）
    - `macos/Runner/Configs/AppInfo.xcconfig`  PRODUCT_NAME / PRODUCT_COPYRIGHT
    - `macos/Runner/MainFlutterWindow.swift`   窗口标题（中文名）
    - `macos/Runner/Base.lproj/MainMenu.xib`   窗口标题（中文名，清掉模板占位符 APP_NAME）

  Linux（本仓库未提交 linux/ 目录，由 CI 用 `flutter create` 生成后立刻调用本脚本）
    - `linux/CMakeLists.txt`           BINARY_NAME（英文名）
    - `linux/runner/my_application.cc` 窗口标题（中文名）

C++ 源码里的中文一律写成 `\\uXXXX` 转义而不是字面量：MSVC 默认按系统
ANSI 代码页解释源文件，非中文 Windows 上直接写中文会变成乱码。

用法::

    python3 scripts/sync_app_name.py            # 同步（缺失的平台目录会跳过）
    python3 scripts/sync_app_name.py --check    # 只校验不写盘，不一致时 exit 1
"""

import argparse
import re
import sys
from pathlib import Path

EN_NAME = "SayIt"
ZH_NAME = "说吧"

COPYRIGHT = f"Copyright (C) 2026 {EN_NAME} Contributors"
COPYRIGHT_XC = f"Copyright © 2026 {EN_NAME} Contributors"

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "apps" / "sayit_app"

WIN_MAIN_CPP = APP / "windows" / "runner" / "main.cpp"
WIN_CMAKE = APP / "windows" / "CMakeLists.txt"
WIN_RC = APP / "windows" / "runner" / "Runner.rc"

MAC_PLIST = APP / "macos" / "Runner" / "Info.plist"
MAC_XCCONFIG = APP / "macos" / "Runner" / "Configs" / "AppInfo.xcconfig"
MAC_WINDOW_SWIFT = APP / "macos" / "Runner" / "MainFlutterWindow.swift"
MAC_MENU_XIB = APP / "macos" / "Runner" / "Base.lproj" / "MainMenu.xib"

LINUX_CMAKE = APP / "linux" / "CMakeLists.txt"
LINUX_APP_CC = APP / "linux" / "runner" / "my_application.cc"


def die(msg: str) -> "None":
    print(f"错误: {msg}", file=sys.stderr)
    sys.exit(1)


def cpp_escape(text: str) -> str:
    """'说吧' -> '\\u8BF4\\u5427'"""
    return "".join(f"\\u{ord(ch):04X}" for ch in text)


def read_normalized(path: Path) -> str:
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


def newline_of(path: Path) -> str:
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def write_like(path: Path, text: str) -> None:
    path.write_bytes(text.replace("\n", newline_of(path)).encode("utf-8"))


def sub_once(text: str, pattern: str, repl: str, what: str, label: str) -> str:
    """替换恰好一处；0 处或 2+ 处都视为错误，避免静默改错。"""
    new, n = re.subn(pattern, repl, text)
    if n != 1:
        die(f"{label}: 预期匹配 1 处「{what}」，实际 {n} 处。文件结构可能已变化。")
    return new


# ── Windows ─────────────────────────────────────────────────────────────────


def render_win_main_cpp(text: str) -> str:
    # if (!window.Create(L"sayit_app", origin, size)) {
    return sub_once(
        text,
        r'(window\.Create\()L"[^"]*"',
        lambda m: m.group(1) + f'L"{cpp_escape(ZH_NAME)}"',
        "window.Create 的窗口标题",
        "windows/runner/main.cpp",
    )


def render_win_cmake(text: str) -> str:
    text = sub_once(
        text,
        r"(?m)^project\(\s*\S+\s+LANGUAGES\s+CXX\s*\)",
        f"project({EN_NAME} LANGUAGES CXX)",
        "project()",
        "windows/CMakeLists.txt",
    )
    return sub_once(
        text,
        r'(?m)^set\(BINARY_NAME\s+"[^"]*"\)',
        f'set(BINARY_NAME "{EN_NAME}")',
        "BINARY_NAME",
        "windows/CMakeLists.txt",
    )


def render_win_rc(text: str) -> str:
    label = "windows/runner/Runner.rc"
    fields = {
        "CompanyName": EN_NAME,
        "FileDescription": EN_NAME,
        "InternalName": EN_NAME,
        "OriginalFilename": f"{EN_NAME}.exe",
        "ProductName": EN_NAME,
        "LegalCopyright": COPYRIGHT,
    }
    for key, value in fields.items():
        text = sub_once(
            text,
            rf'(?m)^([ \t]*VALUE[ \t]+"{key}",[ \t]+)"[^"]*"',
            lambda m, v=value: m.group(1) + f'"{v}"',
            f'VALUE "{key}"',
            label,
        )
    return text


# ── macOS ───────────────────────────────────────────────────────────────────


def render_mac_plist(text: str) -> str:
    label = "macos/Runner/Info.plist"
    # CFBundleName 指向 xcconfig 的 PRODUCT_NAME，保持"单点定义"
    text = sub_once(
        text,
        r"(?s)(<key>CFBundleName</key>\s*<string>)[^<]*(</string>)",
        rf"\g<1>$(PRODUCT_NAME)\g<2>",
        "CFBundleName",
        label,
    )
    # CFBundleDisplayName：Finder / 程序坞里显示的中文名。缺则补，有则改。
    if "<key>CFBundleDisplayName</key>" in text:
        text = sub_once(
            text,
            r"(?s)(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)",
            rf"\g<1>{ZH_NAME}\g<2>",
            "CFBundleDisplayName",
            label,
        )
    else:
        text = sub_once(
            text,
            r"(?s)(<key>CFBundleName</key>\s*<string>[^<]*</string>\n)",
            rf"\g<1>\t<key>CFBundleDisplayName</key>\n\t<string>{ZH_NAME}</string>\n",
            "CFBundleDisplayName（插入）",
            label,
        )
    return text


def render_mac_xcconfig(text: str) -> str:
    label = "macos/Runner/Configs/AppInfo.xcconfig"
    text = sub_once(
        text, r"(?m)^PRODUCT_NAME[ \t]*=.*$", f"PRODUCT_NAME = {EN_NAME}", "PRODUCT_NAME", label
    )
    return sub_once(
        text,
        r"(?m)^PRODUCT_COPYRIGHT[ \t]*=.*$",
        f"PRODUCT_COPYRIGHT = {COPYRIGHT_XC}",
        "PRODUCT_COPYRIGHT",
        label,
    )


def render_mac_window_swift(text: str) -> str:
    """窗口标题。

    xib 里的 `title="APP_NAME"` 是 Flutter 模板的占位符，本项目的 macos
    目录里它从来没被替换过（窗口标题会字面显示 "APP_NAME"）。所以这里在
    awakeFromNib 里显式设一次，不依赖模板机制。
    """
    label = "macos/Runner/MainFlutterWindow.swift"
    assign = f'    self.title = "{ZH_NAME}"'
    if re.search(r"(?m)^ *self[.]title *=", text):
        return sub_once(text, r"(?m)^ *self[.]title *=.*$", lambda m: assign, "self.title", label)
    comment = (
        "    // 窗口标题用中文显示名。xib 里的 APP_NAME 是模板占位符，本项目里它\n"
        "    // 从未被替换，所以这里显式覆盖一次。名字的单一来源是\n"
        "    // scripts/sync_app_name.py，改名请改那里再跑脚本。\n"
    )
    return sub_once(
        text,
        r"(?m)^( *self[.]setFrame[(]windowFrame, display: true[)]\n)",
        lambda m: m.group(1) + comment + assign + "\n",
        "self.setFrame(windowFrame, display: true) 行",
        label,
    )


def render_mac_menu_xib(text: str) -> str:
    """xib 里 window 元素的标题，避免留下 APP_NAME 占位符。"""
    return sub_once(
        text,
        r'(<window title=")[^"]*(")',
        lambda m: m.group(1) + ZH_NAME + m.group(2),
        "<window title=...>",
        "macos/Runner/Base.lproj/MainMenu.xib",
    )


# ── Linux（CI 生成后才存在） ────────────────────────────────────────────────


def render_linux_cmake(text: str) -> str:
    return sub_once(
        text,
        r'(?m)^set\(BINARY_NAME\s+"[^"]*"\)',
        f'set(BINARY_NAME "{EN_NAME}")',
        "BINARY_NAME",
        "linux/CMakeLists.txt",
    )


def render_linux_app_cc(text: str) -> str:
    label = "linux/runner/my_application.cc"
    for func in ("gtk_header_bar_set_title", "gtk_window_set_title"):
        text = sub_once(
            text,
            rf'({func}\([^,]+,[ \t]*)L?"[^"]*"',
            lambda m: m.group(1) + f'"{cpp_escape(ZH_NAME)}"',
            f"{func} 的窗口标题",
            label,
        )
    return text


TARGETS = [
    (WIN_MAIN_CPP, render_win_main_cpp),
    (WIN_CMAKE, render_win_cmake),
    (WIN_RC, render_win_rc),
    (MAC_PLIST, render_mac_plist),
    (MAC_XCCONFIG, render_mac_xcconfig),
    (MAC_WINDOW_SWIFT, render_mac_window_swift),
    (MAC_MENU_XIB, render_mac_menu_xib),
    (LINUX_CMAKE, render_linux_cmake),
    (LINUX_APP_CC, render_linux_app_cc),
]


def main() -> int:
    ap = argparse.ArgumentParser(description="把应用名同步到各平台元数据文件")
    ap.add_argument("--check", action="store_true", help="只校验不写盘，不一致时 exit 1")
    args = ap.parse_args()

    stale, changed, skipped = [], [], []
    for path, render in TARGETS:
        label = path.relative_to(ROOT).as_posix()
        if not path.is_file():
            skipped.append(label)
            continue
        current = read_normalized(path)
        wanted = render(current)
        if current == wanted:
            continue
        stale.append(label)
        if not args.check:
            write_like(path, wanted)
            changed.append(label)

    print(f"英文名 = {EN_NAME}    中文名 = {ZH_NAME}")
    for label in skipped:
        print(f"  [跳过] {label}（文件不存在）")

    if args.check:
        if stale:
            print("以下文件的名称与约定不一致：", file=sys.stderr)
            for label in stale:
                print(f"  - {label}", file=sys.stderr)
            print("请运行: python3 scripts/sync_app_name.py", file=sys.stderr)
            return 1
        print("名称一致。")
        return 0

    if changed:
        print("已更新：")
        for label in changed:
            print(f"  - {label}")
    else:
        print("无需改动。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
