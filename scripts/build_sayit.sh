#!/bin/bash
set -e

FLUTTER_PATH="/Users/xingxiaoshu/flutter/bin/flutter"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Building SayIt ==="

cd "$PROJECT_ROOT"

if [ "$1" = "--debug" ]; then
    echo "Building Debug version..."
    RUST_PROFILE="debug"
    FLUTTER_FLAG="--debug"
else
    echo "Building Release version..."
    RUST_PROFILE="release"
    FLUTTER_FLAG="--release"
fi

echo "=== Step 1: Build Rust binary ==="
cd "$PROJECT_ROOT/sayit-poc"
if [ "$RUST_PROFILE" = "release" ]; then
    cargo build --release
else
    cargo build
fi

echo "=== Step 2: Build Flutter app ==="
cd "$PROJECT_ROOT/apps/sayit_app"
"$FLUTTER_PATH" build macos $FLUTTER_FLAG

echo "=== Step 3: Copy Rust binary to app bundle ==="
if [ "$1" = "--debug" ]; then
    APP_DIR="$PROJECT_ROOT/apps/sayit_app/build/macos/Build/Products/Debug/SayIt.app"
else
    APP_DIR="$PROJECT_ROOT/apps/sayit_app/build/macos/Build/Products/Release/SayIt.app"
fi

mkdir -p "$APP_DIR/Contents/Resources/bin"
cp "$PROJECT_ROOT/sayit-poc/target/$RUST_PROFILE/sayit-poc" "$APP_DIR/Contents/Resources/bin/"
chmod +x "$APP_DIR/Contents/Resources/bin/sayit-poc"

if [ "$1" != "--debug" ]; then
    echo "=== Step 4: Code signing ==="
    codesign --force --sign - "$APP_DIR/Contents/Resources/bin/sayit-poc" 2>/dev/null || true
fi

echo ""
echo "=== Build complete ==="
echo "App location: $APP_DIR"
echo ""
echo "To run:"
echo "  open \"$APP_DIR\""
