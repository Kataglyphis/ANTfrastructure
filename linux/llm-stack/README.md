# LLM Stack

Ollama + Open WebUI for serving LLMs with an OpenAI-compatible API.
Designed for integration with Nextcloud Assistant.

## Prerequisites

- [nerdctl](https://github.com/containerd/nerdctl) with BuildKit
- curl, zstd (for download script)

## Quick start

```bash
# 1. Download Ollama binary for your architecture
bash linux/llm-stack/scripts/download-ollama.sh

# 2. Build and start
docker compose -f linux/llm-stack/docker-compose.yml up -d
```

First start downloads the model (~8.5GB for `gemma4:12b`) — this takes a while.
Watch progress:

```bash
docker compose -f linux/llm-stack/docker-compose.yml logs -f
```

## Services

| Service | Port | URL | Purpose |
|---------|------|-----|---------|
| Ollama | 8080 | http://localhost:8080/v1 | OpenAI-compatible API |
| Open WebUI | 3000 | http://localhost:3000 | Chat UI for debugging |

## Nextcloud Assistant configuration

Settings → AI → OpenAI-compatible endpoint:
- **URL**: `http://localhost:8080/v1`
- **API key**: *(leave blank)*
- **Model**: `gemma4:12b`

## Managing models

```bash
# Pull additional models
docker compose -f linux/llm-stack/docker-compose.yml exec ollama ollama pull qwen2.5-coder:7b

# List pulled models
docker compose -f linux/llm-stack/docker-compose.yml exec ollama ollama list

# Remove a model
docker compose -f linux/llm-stack/docker-compose.yml exec ollama ollama rm gemma4:12b
```

## Change default model

Edit `OLLAMA_PULL_MODELS` in `docker-compose.yml` and restart:

```bash
docker compose -f linux/llm-stack/docker-compose.yml up -d
```

## Manual build (without compose)

```bash
bash linux/llm-stack/scripts/download-ollama.sh
nerdctl build -t kataglyphis/llm-stack:latest -f linux/llm-stack/Dockerfile linux/llm-stack
nerdctl run -d --name llm-stack -p 8080:8080 \
  -v ollama-models:/root/.ollama \
  -e OLLAMA_PULL_MODELS=gemma4:12b \
  kataglyphis/llm-stack:latest
```

## Architecture notes

- Standalone subproject (not part of the cross-build chain)
- Multi-arch: amd64, arm64 (riscv64 unsupported — Ollama does not ship riscv64 binaries)
- CPU-only inference (no GPU required)
- Models persist in Docker volumes across restarts
