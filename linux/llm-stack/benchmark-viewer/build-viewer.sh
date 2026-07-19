#!/usr/bin/env bash
set -euo pipefail

# Build the React benchmark viewer app using a Node container.
# Output goes to benchmark-viewer/dist/.
# The built files can be served from any HTTP server.

cd "$(dirname "$0")"

NODE_IMAGE="node:20-alpine"
SRC_DIR="/src"
OUT_DIR="/src/dist"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Building benchmark viewer (Vite + React)"
echo "  Using image: $NODE_IMAGE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Use nerdctl or docker
CMD="nerdctl"
if ! command -v nerdctl &>/dev/null; then
  CMD="docker"
fi

$CMD run --rm \
  -v "$(pwd):$SRC_DIR" \
  -w "$SRC_DIR" \
  "$NODE_IMAGE" \
  sh -c "
    npm install && \
    npm run build && \
    echo ''
    echo '✓ Build complete. Files in dist/:'
    ls -lh dist/
  "

# Copy benchmark results into dist/ so the viewer can load them
# (avoids needing multiple volume mounts at serve time)
echo ""
echo "  Copying benchmark_results/ into dist/ …"
mkdir -p dist/benchmark_results
cp -r ../benchmark_results/*.json dist/benchmark_results/
echo "  ✓ benchmark_results copied"
ls -lh dist/benchmark_results/

echo ""
echo "To serve:"
echo "  python3 -m http.server 4173 -d dist/"
echo "  # or open dist/index.html directly in a browser"
