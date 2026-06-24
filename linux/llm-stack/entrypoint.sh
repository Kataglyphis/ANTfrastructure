#!/usr/bin/env bash
set -euo pipefail

ollama serve &
OLLAMA_PID=$!

for i in $(seq 1 30); do
    if curl -fs http://localhost:8080/api/tags >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if [ -n "${OLLAMA_PULL_MODELS:-}" ]; then
    IFS=',' read -ra MODELS <<< "$OLLAMA_PULL_MODELS"
    for model in "${MODELS[@]}"; do
        echo "Pulling model: $model"
        ollama pull "$model"
    done
fi

wait $OLLAMA_PID
