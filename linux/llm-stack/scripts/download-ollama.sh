#!/usr/bin/env bash
set -euo pipefail

# Fetches the Ollama tarball for the llm-stack build; versions.env pins it, the environment may override.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

# shellcheck source=../../scripts/01-core/load-versions-env.sh
source "${CORE_DIR}/load-versions-env.sh"
load_versions_env "${CORE_DIR}/versions.env"

ARCH="${1:-$(uname -m)}"
OLLAMA_VERSION="${OLLAMA_VERSION:?OLLAMA_VERSION not set (versions.env missing?)}"

# Release assets use Go arch names, not uname -m spellings; the wrong one 404s.
case "$ARCH" in
    x86_64|amd64)  ARCH_ALT="amd64"; EXPECTED_SHA="${OLLAMA_AMD64_SHA256:-}" ;;
    aarch64|arm64)  ARCH_ALT="arm64"; EXPECTED_SHA="${OLLAMA_ARM64_SHA256:-}" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-${ARCH_ALT}.tar.zst"
OUTPUT="${REPO_ROOT}/linux/llm-stack/ollama-binary.tar.zst"

echo "Downloading Ollama ${OLLAMA_VERSION} for ${ARCH}..."
echo "  URL: ${URL}"
echo "  ->  ${OUTPUT}"

curl -fsSL --retry 3 --retry-delay 10 -o "$OUTPUT" "$URL"

# An empty pin (a new arch) skips the gate loudly instead of failing.
if [ -n "${EXPECTED_SHA}" ]; then
    echo "${EXPECTED_SHA}  ${OUTPUT}" | sha256sum -c - \
        || { echo "ERROR: checksum mismatch — deleting ${OUTPUT}" >&2; rm -f "$OUTPUT"; exit 1; }
else
    echo "WARNING: no OLLAMA_${ARCH_ALT^^}_SHA256 pin in versions.env — download NOT verified." >&2
fi

echo "Done. Size: $(du -h "$OUTPUT" | cut -f1)"
