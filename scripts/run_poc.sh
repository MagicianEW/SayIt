#!/usr/bin/env bash
# 本地一键跑通 SayIt PoC（阶段 1a）
# 用法：bash scripts/run_poc.sh [--skip-network]
#
# 不需要 Claude 账号，不需要 Cowork App，只需要：
#   - Rust 工具链（rustc + cargo）>= 1.75
#   - 可选：Python 3（仅 token 对照时需要）
#   - 用例 1 / 4 需要联网到 wss://speech.platform.bing.com
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POC_DIR="${ROOT}/sayit-poc"

cd "${POC_DIR}"

echo "============================================="
echo "SayIt PoC（阶段 1a）—— 本地执行"
echo "============================================="
echo "工作目录: ${POC_DIR}"
echo "Rust 版本:"
rustc --version
echo "----------------------------------------"

# 1. 单测（离线；不需要联网）
echo "[1/4] cargo test --workspace"
cargo test --workspace --quiet

# 2. 用例 3（DRM Token，离线）
echo "[2/4] 用例 3：DRM Token 生成（离线）"
cargo run -p sayit-poc-bin --quiet -- --case 3

# 3. token 对照：Rust vs Python（如果 Python 可用）
if command -v python3 >/dev/null 2>&1; then
  echo "[3/4] token 对照：Rust 手写 vs Python 参考"
  RUST_TOKEN=$(cargo run -p sayit-poc-bin --quiet -- --case 3 --token-only 2>/dev/null || \
               cargo run -p sayit-poc-bin --quiet -- --case 3 2>/dev/null | grep -oE 'token=[A-Za-z0-9.!]+' | head -1 | cut -d= -f2)
  PY_TOKEN=$(python3 reference/edge-tts/sec_ms_gec.py 2>/dev/null || echo "")
  if [ -n "${PY_TOKEN:-}" ] && [ -n "${RUST_TOKEN:-}" ]; then
    if [ "${RUST_TOKEN}" = "${PY_TOKEN}" ]; then
      echo "  ✅ Rust 与 Python token 完全一致"
    else
      echo "  ⚠️  Rust 与 Python token 不一致"
      echo "     Rust:  ${RUST_TOKEN}"
      echo "     Python: ${PY_TOKEN}"
      echo "     需要校核 sayit-drm 实现"
    fi
  else
    echo "  ⚠️  跳过：未能提取 token"
  fi
else
  echo "[3/4] 跳过 token 对照（未检测到 python3）"
fi

# 4. 用例 1 / 4（需要联网）
if [ "${1:-}" != "--skip-network" ]; then
  echo "[4/4] 用例 1 + 4：需要联网"
  cargo run -p sayit-poc-bin --quiet -- --case 1 || echo "  ⚠️  用例 1 失败（通常是网络/服务端拒连）"
  cargo run -p sayit-poc-bin --quiet -- --case 4 || echo "  ⚠️  用例 4 失败"
else
  echo "[4/4] 跳过网络用例（--skip-network）"
fi

echo "----------------------------------------"
echo "产物:"
ls -la reports/ || true
echo "----------------------------------------"
echo "关键决策文件: reports/boundary_offset_semantics.md"
echo "============================================="