#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-$(uname -m)}"
OLLAMA_VERSION="${OLLAMA_VERSION:-0.30.10}"

# Ollama's release assets are named with Go arch names (amd64/arm64), NOT the
# uname -m spellings (x86_64/aarch64). Mapping to the wrong name 404s.
case "$ARCH" in
    x86_64|amd64)  ARCH_ALT="amd64" ;;
    aarch64|arm64)  ARCH_ALT="arm64" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-${ARCH_ALT}.tar.zst"
OUTPUT="linux/llm-stack/ollama-binary.tar.zst"

echo "Downloading Ollama ${OLLAMA_VERSION} for ${ARCH}..."
echo "  URL: ${URL}"
echo "  ->  ${OUTPUT}"

curl -fsSL --retry 3 --retry-delay 10 -o "$OUTPUT" "$URL"
echo "Done. Size: $(du -h "$OUTPUT" | cut -f1)"
