#!/usr/bin/env bash
# Build a SayIt Linux AppImage from the Flutter Linux bundle.
#
# Mirrors Flutter's bundle layout (binary at root, lib/ at lib/, data/ at data/)
# into an AppDir so the rpaths Flutter sets ($ORIGIN/lib) and the rpaths the
# libmpv bundling script sets ($ORIGIN) keep working once the AppImage is mounted.
#
# Usage: scripts/make_appimage.sh <version>
set -euo pipefail

VER="${1:?usage: make_appimage.sh <version>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE=apps/sayit_app/build/linux/x64/release/bundle
APPDIR="$PWD/AppDir"

rm -rf "$APPDIR"
mkdir -p "$APPDIR"

# main binary (Flutter artifact; force the name so AppRun/desktop can rely on it)
MAIN_BIN=$(find "$BUNDLE" -maxdepth 1 -type f -executable ! -name 'sayit-poc' | head -1)
[ -n "$MAIN_BIN" ] || { echo "::error::找不到 Flutter 主二进制"; exit 1; }
cp "$MAIN_BIN" "$APPDIR/sayit_app"
chmod +x "$APPDIR/sayit_app"

cp -r "$BUNDLE/lib"  "$APPDIR/lib"
cp -r "$BUNDLE/data" "$APPDIR/data" 2>/dev/null || true
cp "$BUNDLE/sayit-poc" "$APPDIR/" 2>/dev/null || true
cp THIRD_PARTY_LICENSES "$APPDIR/" 2>/dev/null || true

# AppRun launcher
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
exec "$HERE/sayit_app" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# desktop entry (binary lives at the AppDir root)
#   Categories 必须满足 AppStream 校验：Audio 是 AudioVideo 的子类，必须同时列出
#   AudioVideo 主分类，否则 appimagetool 报 "requires another category: AudioVideo" 并退 1。
#   Icon 必须指向 AppDir 内真实存在的图标文件，否则 appimagetool 报
#   "Icon entry not found" 并退 1。
cat > "$APPDIR/sayit.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=SayIt
Comment=说吧 - 文本转语音 (TTS)
Exec=sayit_app
Icon=sayit
Categories=AudioVideo;Audio;
Terminal=false
EOF

# 内置一个 256x256 PNG 图标（SayIt 深蓝主题色），避免依赖外部图标资源。
# 由 base64 解码生成，CI 环境无 ImageMagick/rsvg 也能产出合法图标。
SAYIT_ICON_B64="iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAYAAABccqhmAAACYUlEQVR42u3UMQEAAAQAQYU001kUCmjghivww0dWD/BTiAAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAYABiAAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAYABiAAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAYABCAEGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAYABAAYAGABgAIABAAYAGABgAIABAAYAGABgAIABAAYAGABgAIABAAYAGABgAIABAAYAGABgAIABAAYAGABgAIABAAYAGABgAIABgAEABgAYAGAAgAEABgAYAGAAgAEABgAYAGAAgAEABgAYAGAAgAEABgAYAGAAgAEABgAYAGAAgAEABgAYAGAAgAEABgAYAGAAgAGAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQAGABgAYACAAQCXBT5oJPoouCz6AAAAAElFTkSuQmCC"
printf '%s' "$SAYIT_ICON_B64" | base64 -d > "$APPDIR/sayit.png"
[ -s "$APPDIR/sayit.png" ] || { echo "::error::生成图标失败"; exit 1; }

# sanity: libmpv must be inside the bundle (bundle_libmpv_linux.sh wrote it)
ls "$APPDIR/lib" | grep -E '^libmpv\.so' || { echo "::error::libmpv 未进入 AppDir/lib"; exit 1; }

# appimagetool only packs the AppDir; it does not rewrite rpaths.
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool.AppImage
chmod +x appimagetool.AppImage
APPIMAGE_EXTRACT_AND_RUN=1 ./appimagetool.AppImage "$APPDIR" "SayIt_linux_${VER}.AppImage"

ls -l "SayIt_linux_${VER}.AppImage"
