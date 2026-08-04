#!/usr/bin/env bash
set -euo pipefail

ollama serve &
OLLAMA_PID=$!

READY=0
for _ in $(seq 1 30); do
    if curl -fs http://localhost:8080/api/tags >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 2
done
if [ "${READY}" -ne 1 ]; then
    echo "ERROR: ollama API did not become ready within 60s (http://localhost:8080/api/tags unreachable); continuing to wait on the server process, but model pulls below will likely fail" >&2
fi

if [ -n "${OLLAMA_PULL_MODELS:-}" ]; then
    IFS=',' read -ra MODELS <<< "$OLLAMA_PULL_MODELS"
    for model in "${MODELS[@]}"; do
        echo "Pulling model: $model"
        ollama pull "$model"
    done
fi

wait $OLLAMA_PID
