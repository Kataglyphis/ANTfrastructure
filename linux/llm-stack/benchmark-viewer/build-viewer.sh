#!/usr/bin/env bash
set -euo pipefail

# Build the React benchmark viewer app using a Node container.
# Output goes to benchmark-viewer/dist/.
# The built files can be served from any HTTP server.

cd "$(dirname "$0")"

# Node major from the canonical NODE_VERSION pin (versions.env) — was a
# hardcoded node:20-alpine that silently drifted from the 26.x pin (backlog
# 2026-08-10). Major-only tag: the viewer build needs a Node runtime, not a
# byte-pinned toolchain, and alpine tags exist per-major reliably.
_VERSIONS_ENV="$(cd ../../.. && pwd)/linux/scripts/01-core/versions.env"
NODE_MAJOR="$(grep -E '^NODE_VERSION=' "${_VERSIONS_ENV}" | head -1 | cut -d= -f2 | cut -d. -f1)"
NODE_IMAGE="node:${NODE_MAJOR:-20}-alpine"

# We mount the repo root so Vite can resolve the @import of brand.css
# from the DocumANTation submodule at build time.
REPO_ROOT="$(cd ../../.. && pwd)"
SRC_DIR="/repo"
VIEWER_DIR="$SRC_DIR/linux/llm-stack/benchmark-viewer"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Building benchmark viewer (Vite + React)"
echo "  Using image: $NODE_IMAGE"
echo "  Repo root: $REPO_ROOT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Use nerdctl or docker
CMD="nerdctl"
if ! command -v nerdctl &>/dev/null; then
  CMD="docker"
fi

$CMD run --rm \
  -v "$REPO_ROOT:$SRC_DIR" \
  -w "$VIEWER_DIR" \
  "$NODE_IMAGE" \
  sh -euc "
    npm ci
    npm run build
    echo ''
    echo '✓ Build complete. Files in dist/:'
    ls -lh dist/
  "
# -euc above: the old &&-chain ended at the first echo, so with a STALE dist/
# from an earlier run a failed npm build still exited 0 (the container's status
# was ls's) and this script printed the success banner over a broken build.

# Copy benchmark results into dist/ so the viewer can load them
# (avoids needing multiple volume mounts at serve time)
echo ""
echo "  Copying benchmark_results/ into dist/ …"
mkdir -p dist/benchmark_results
# Guarded: zero results is a fresh checkout, not a build failure — the bare
# glob aborted under set -e right AFTER a successful viewer build.
if compgen -G "../benchmark_results/*.json" > /dev/null; then
  cp -r ../benchmark_results/*.json dist/benchmark_results/
  echo "  ✓ benchmark_results copied"
else
  echo "  (no benchmark_results/*.json yet — viewer built without data)"
fi
ls -lh dist/benchmark_results/

echo ""
echo "To serve:"
echo "  python3 -m http.server 4173 -d dist/"
echo "  # or open dist/index.html directly in a browser"
