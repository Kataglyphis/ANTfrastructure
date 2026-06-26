# LLM Stack

Ollama + Open WebUI for serving LLMs with an OpenAI-compatible API.
Designed for integration with Nextcloud Assistant.

## Quick start

```bash
# Pull images and start all services (auto-pulls gemma4:26b on first start)
nerdctl compose -f linux/llm-stack/docker-compose.yml pull
nerdctl compose -f linux/llm-stack/docker-compose.yml up -d
```

First start downloads the model (~17GB for `gemma4:26b`) — this takes a while.
Watch progress:

```bash
nerdctl compose -f linux/llm-stack/docker-compose.yml logs -f
```

## Services

| Service | Port | URL | Purpose |
|---------|------|-----|---------|
| Ollama | 11434 | http://localhost:11434/v1 | OpenAI-compatible API |
| Open WebUI | 3000 | http://localhost:3000 | Chat UI for debugging |
| Glances | 61208 | http://localhost:61208 | System monitoring dashboard |

## Nextcloud Assistant configuration

Settings → AI → OpenAI-compatible endpoint:
- **URL**: `http://localhost:11434/v1`
- **API key**: *(leave blank)*
- **Model**: `gemma4:26b`

## Managing models

```bash
# Pull additional models
nerdctl compose -f linux/llm-stack/docker-compose.yml exec ollama ollama pull qwen2.5-coder:7b

# List pulled models
nerdctl compose -f linux/llm-stack/docker-compose.yml exec ollama ollama list

# Remove a model
nerdctl compose -f linux/llm-stack/docker-compose.yml exec ollama ollama rm gemma4:26b
```

## Change default model

Edit the `ollama pull` line in the `command` block in `docker-compose.yml`, then restart:

```bash
nerdctl compose -f linux/llm-stack/docker-compose.yml up -d
```

## Network access (Windows firewall)

To access services from other devices on your network, open the required ports in Windows Firewall:

```powershell
New-NetFirewallRule -DisplayName "Allow OpenWebUI Port 3000" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3000
New-NetFirewallRule -DisplayName "Allow Ollama API Port 11434" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 11434
New-NetFirewallRule -DisplayName "Allow Glances Port 61208" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 61208
```

## Standalone run (without compose)

```bash
nerdctl run -d --name llm-stack -p 11434:8080 \
  -v ollama-models:/root/.ollama \
  -e OLLAMA_HOST=0.0.0.0:8080 \
  ollama/ollama:latest
```

## Architecture notes

- Standalone subproject (not part of the cross-build chain)
- Uses the official `ollama/ollama` image — no custom Dockerfile
- Model auto-pulled on container startup via compose `command` override
- Multi-arch: amd64, arm64 (riscv64 unsupported — Ollama does not ship riscv64 binaries)
- CPU-only inference (no GPU required)
- Models persist in Docker volumes across restarts
