#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把仓库根的 VERSION 同步到所有版本声明点。

**版本号的唯一来源是仓库根目录的 `VERSION` 文件。**
不要直接去改 pubspec.yaml / Cargo.toml / build_info.dart 里的版本号，
改了也会被本脚本覆盖 —— 这正是设立单一来源的目的。

同步目标：

  1. `apps/sayit_app/pubspec.yaml`
     `version: X.Y.Z`。Flutter 工具链读它，进而生成 macOS 的
     Info.plist（CFBundleShortVersionString）和 Windows exe 的版本资源
     （经 windows/flutter/generated_config.cmake 的 FLUTTER_VERSION 宏）。

  2. `sayit-poc/Cargo.toml`
     `[workspace.package] version = "X.Y.Z"`。三个 crate 都是
     `version.workspace = true`，`sayit-poc --version` 报的也是这个值。

  3. `apps/sayit_app/lib/src/build_info.dart`（生成文件）
     给 Dart 侧提供 `kAppVersion`，界面的「关于」对话框读它，
     避免在 UI 里硬编码版本号。

用法::

    python3 scripts/sync_version.py               # 按 VERSION 同步各处
    python3 scripts/sync_version.py --set 0.2.0   # 先把 VERSION 写成 0.2.0 再同步
    python3 scripts/sync_version.py --check       # 只校验不写盘，不一致时 exit 1
    python3 scripts/sync_version.py --print       # 只打印当前 VERSION（供 CI 取用）
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
PUBSPEC = ROOT / "apps" / "sayit_app" / "pubspec.yaml"
CARGO_TOML = ROOT / "sayit-poc" / "Cargo.toml"
BUILD_INFO = ROOT / "apps" / "sayit_app" / "lib" / "src" / "build_info.dart"

# 三段式 + 可选预发布段。刻意不支持 `+build`：Cargo 的 version 不认它，
# 而 VERSION 要同时喂给 Cargo 和 Flutter。构建号交给 CI 另外处理。
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?$")

GPL_HEADER = """\
// Copyright (C) 2026 SayIt Contributors
//
// This file is part of SayIt.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
"""

BUILD_INFO_BODY = """
// 本文件由 `scripts/sync_version.py` 自动生成，请勿手动修改。
// 版本号的唯一来源是仓库根目录的 `VERSION` 文件。

/// 应用版本号。与 `VERSION` / `pubspec.yaml` / `Cargo.toml` 保持一致。
///
/// 界面的「关于」对话框读这个常量，不要在 UI 里硬编码版本号。
const String kAppVersion = '{version}';
"""


def die(msg: str) -> "None":
    print(f"错误: {msg}", file=sys.stderr)
    sys.exit(1)


def read_version() -> str:
    if not VERSION_FILE.is_file():
        die(f"找不到版本文件 {VERSION_FILE}")
    v = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not VERSION_RE.match(v):
        die(f"VERSION 内容不合法: {v!r}，应形如 0.1.4")
    return v


def read_normalized(path: Path) -> str:
    """读成 LF 文本。文件不存在时返回空串。"""
    if not path.is_file():
        return ""
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


def newline_of(path: Path) -> str:
    """保留原文件的换行风格，避免整个文件被判定为改动。"""
    if not path.is_file():
        return "\n"
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def write_like(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.replace("\n", newline_of(path)).encode("utf-8"))


def render_pubspec(text: str, version: str) -> str:
    new, n = re.subn(r"(?m)^version:[ \t]*\S+[ \t]*$", f"version: {version}", text)
    if n != 1:
        die(f"pubspec.yaml 里没找到唯一的顶层 `version:` 行（匹配到 {n} 处）")
    return new


def render_cargo(text: str, version: str) -> str:
    """只改 [workspace.package] 段内的 version，不碰依赖里的 version。"""
    out, in_section, hits = [], False, 0
    for line in text.split("\n"):
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_section = s == "[workspace.package]"
        if in_section and re.match(r"^version[ \t]*=", s):
            indent = line[: len(line) - len(line.lstrip())]
            line = f'{indent}version = "{version}"'
            hits += 1
        out.append(line)
    if hits != 1:
        die(f"Cargo.toml 的 [workspace.package] 段里没找到唯一的 version（匹配到 {hits} 处）")
    return "\n".join(out)


def render_build_info(_text: str, version: str) -> str:
    return GPL_HEADER + BUILD_INFO_BODY.format(version=version)


TARGETS = [
    (PUBSPEC, "apps/sayit_app/pubspec.yaml", render_pubspec),
    (CARGO_TOML, "sayit-poc/Cargo.toml", render_cargo),
    (BUILD_INFO, "apps/sayit_app/lib/src/build_info.dart", render_build_info),
]


def main() -> int:
    ap = argparse.ArgumentParser(
        description="把 VERSION 同步到 pubspec.yaml / Cargo.toml / build_info.dart"
    )
    ap.add_argument("--set", metavar="X.Y.Z", help="先把 VERSION 写为指定版本，再同步")
    ap.add_argument("--check", action="store_true", help="只校验不写盘，不一致时 exit 1")
    ap.add_argument("--print", dest="do_print", action="store_true", help="只打印当前 VERSION")
    args = ap.parse_args()

    if args.set:
        if not VERSION_RE.match(args.set):
            die(f"--set 的值不合法: {args.set!r}，应形如 0.1.4")
        if not args.check:
            VERSION_FILE.write_text(args.set + "\n", encoding="utf-8")
            print(f"VERSION -> {args.set}")

    version = read_version()

    if args.do_print:
        print(version)
        return 0

    stale, changed = [], []
    for path, label, render in TARGETS:
        current = read_normalized(path)
        wanted = render(current, version)
        if current == wanted:
            continue
        stale.append(label)
        if not args.check:
            write_like(path, wanted)
            changed.append(label)

    if args.check:
        if stale:
            print(f"版本不一致（VERSION={version}）：", file=sys.stderr)
            for label in stale:
                print(f"  - {label}", file=sys.stderr)
            print("请运行: python3 scripts/sync_version.py", file=sys.stderr)
            return 1
        print(f"版本一致：{version}（已校验 {len(TARGETS)} 个文件）")
        return 0

    if changed:
        print(f"已同步到 {version}：")
        for label in changed:
            print(f"  - {label}")
    else:
        print(f"全部已是最新：{version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
