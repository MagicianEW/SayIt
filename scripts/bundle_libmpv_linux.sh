#!/usr/bin/env bash
# Bundle libmpv and its transitive dependencies for Linux distribution.
#
# Usable for both the plain Flutter tar.gz bundle and an AppImage AppDir:
# just point it at the directory that should hold the shared libraries
# (e.g. .../bundle/lib or AppDir/usr/lib).
#
# Why this is needed:
#   media_kit (just_audio_media_kit on desktop) loads libmpv via
#   dlopen("libmpv.so.2") at runtime, so the dynamic loader must find it
#   through the host binary's RPATH ($ORIGIN/lib). We copy the *full*
#   dependency tree there (not just libmpv.so) and rewrite each bundled
#   lib's RPATH to $ORIGIN so the tree resolves internally instead of
#   hitting the (often absent) system multimedia libraries.
#
# System core libraries are deliberately NOT bundled — shipping our own
# libc / libstdc++ / libGL / libgtk would cause ABI conflicts and shadow
# the host's. This is exactly the trap of only copying libmpv.so.
#
# License note: libmpv (mpv) is GPL-3.0-or-later, same as this project, so
# bundling is compatible. The distribution must still carry the license /
# copyright of the bundled libs — see THIRD_PARTY_LICENSES in the repo root.
set -euo pipefail

TARGET_LIB="${1:?usage: bundle_libmpv_linux.sh <target-lib-dir>}"
mkdir -p "$TARGET_LIB"

# --- locate libmpv ---------------------------------------------------------
LIBMPV=""
if command -v ldconfig >/dev/null 2>&1; then
  LIBMPV=$(ldconfig -p 2>/dev/null | grep -oE '/[^ ]+libmpv\.so\.[0-9]+' | head -1 || true)
fi
if [ -z "$LIBMPV" ]; then
  LIBMPV=$(find /usr/lib /usr/lib/x86_64-linux-gnu -name 'libmpv.so.*' 2>/dev/null | head -1 || true)
fi
[ -n "$LIBMPV" ] || { echo "::error::libmpv not found on build host (install libmpv-dev)"; exit 1; }
echo "==> Bundling libmpv: $LIBMPV"

# System libs that must stay provided by the host OS. Bundling these causes
# ABI conflicts / shadowing. Keep in sync with what a normal desktop provides.
SYSTEM_RE='(linux-vdso|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread|librt\.so|libstdc\+\+|libgcc_s|libresolv|libnss_|libX[a-z]|libxcb|libwayland|libdrm|libgbm|libGL\.so|libEGL\.so|libGLX|libGLdispatch|libgl\b|libgtk|libgdk|libglib|libgobject|libgio|libpango|libcairo|libatk|libdbus|libsystemd|libfontconfig|libfreetype|libasound|libpulse|libudev|libgmodule|libgthread|libmount|libblkid|libsepol|libselinux|libpcre)'

# Recursive copy of non-system deps. Uses a plain `for` (not a pipe) so the
# `seen` map and recursion persist across calls.
declare -A seen
copy_deps() {
  local f="$1"
  local deps
  deps=$(ldd "$f" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' || true)
  for dep in $deps; do
    [ -e "$dep" ] || continue
    local base; base=$(basename "$dep")
    if echo "$base" | grep -qE "$SYSTEM_RE"; then continue; fi
    if [ -n "${seen[$base]:-}" ]; then continue; fi
    seen[$base]=1
    cp -L "$dep" "$TARGET_LIB/" 2>/dev/null || continue
    patchelf --set-rpath '$ORIGIN' "$TARGET_LIB/$base" 2>/dev/null || true
    copy_deps "$dep"
  done
}

cp -L "$LIBMPV" "$TARGET_LIB/"
REAL_BASE="$(basename "$LIBMPV")"
patchelf --set-rpath '$ORIGIN' "$TARGET_LIB/$REAL_BASE" 2>/dev/null || true
copy_deps "$LIBMPV"

# versioned sonames media_kit probes (it tries both .1 and .2). Create them
# AFTER the real file exists, and skip the one that already is the real file
# so we never build a self-referencing symlink (which breaks the copy above).
for v in 1 2; do
  if [ "libmpv.so.$v" != "$REAL_BASE" ]; then
    ln -sf "$REAL_BASE" "$TARGET_LIB/libmpv.so.$v"
  fi
done

echo "==> Bundled $(ls -1 "$TARGET_LIB" | wc -l) files into $TARGET_LIB"
ls -1 "$TARGET_LIB"
