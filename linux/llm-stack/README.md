# LLM Stack

Ollama + Open WebUI for serving LLMs with an OpenAI-compatible API.
Designed for integration with Nextcloud Assistant.

## Quick start

```bash
# 1. Set the required Open WebUI secret (compose refuses to start without it).
#    The .env must sit next to the compose file so compose picks it up.
cp linux/llm-stack/.env.example linux/llm-stack/.env
# then edit linux/llm-stack/.env and set WEBUI_SECRET_KEY, e.g.:
#    printf 'WEBUI_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" > linux/llm-stack/.env

# 2. Pull images and start all services (auto-pulls gemma4:26b on first start)
nerdctl compose -f linux/llm-stack/docker-compose.yml pull
nerdctl compose -f linux/llm-stack/docker-compose.yml up -d
```

First start downloads the model (~17GB for `gemma4:26b`) — this takes a while.
Watch progress:

```bash
nerdctl compose -f linux/llm-stack/docker-compose.yml logs -f
```

## GPU mode (NVIDIA)

The default stack is CPU-only. To run the Ollama service on all NVIDIA GPUs,
use the GPU override file:

```bash
# 1. On the host, install the NVIDIA container toolkit ONCE:
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# 2. Start the stack with the GPU override:
docker compose -f linux/llm-stack/docker-compose.yml -f linux/llm-stack/docker-compose.gpu.yml up -d
```

The override is a compose overlay — `docker-compose.yml` stays CPU-only. It
grants the ollama service all NVIDIA GPUs (`deploy.resources.reservations
.devices`) and raises the default context window via `OLLAMA_CONTEXT_LENGTH`.
Verify GPU placement:

```bash
docker exec llm-stack-ollama-1 ollama ps   # PROCESSOR column = 100% GPU
```

## VRAM & context sizing

The context length Ollama lists for a model is its **maximum supported**
window, not what fits your VRAM. Ollama loads as many layers as fit on GPU; the
rest spill to CPU/RAM and crater throughput. Size `num_ctx` to the VRAM free
*after* the weights. Rule of thumb at q8_0 KV: a Qwen3-class 30B A3B model uses
~104 KB of KV per context token.

| Total GPU VRAM | `qwen3-coder:30b` (Q4_K_M, ~19 GB) | Reasonable context (q8_0 KV) |
|----------------|------------------------------------|------------------------------|
| 24 GB          | fits, ~5 GB left                   | ~32K |
| 28 GB (e.g. 2× 12+16 GB) | fits, ~9 GB left          | ~64K |
| 48 GB          | fits, ~29 GB left                  | ~256K (model max) |

`qwen3-coder:30b` advertises 256K, but that needs ~27 GB of KV cache alone —
i.e. >45 GB total VRAM alongside the 19 GB of weights. On a 28 GB stack, 64K
is the realistic ceiling; a host with 48 GB can run the full 256K.

## Services

| Service | Port | URL | Purpose |
|---------|------|-----|---------|
| Ollama | 11434 | http://localhost:11434/v1 | OpenAI-compatible API |
| Open WebUI | 3000 | http://localhost:3000 | Chat UI for debugging |
| Glances | 61208 | http://localhost:61208 | System monitoring dashboard |
| Benchmark Viewer | 4173 | http://localhost:4173 | Interactive benchmark charts (profile `viewer`) |

### Benchmark Viewer

The `benchmark-viewer` is a standalone nginx container (not part of the compose
stack). Start it after building the viewer app.

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

```pwsh
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

## Benchmarking

The stack includes an automated benchmark suite and an interactive React viewer.

### 1. Run benchmarks

```bash
cd linux/llm-stack
bash run_benchmarks.sh
```

This runs 5 configurations (different `num_ctx` × `max_tokens`) through a set of
short and medium prompts, measuring tokens/sec, latency, CPU, and RAM via the
Glances API. Results land in `benchmark_results/` as individual JSON files plus
a consolidated `_manifest.json`.

### 2. Build the viewer

```bash
cd linux/llm-stack/benchmark-viewer
bash build-viewer.sh
```

Builds the React + Recharts app using a Node 20 container (no host Node needed).

### 3. View results

```bash
# Start the viewer (nginx container, available at http://localhost:4173)
bash linux/llm-stack/serve-viewer.sh

# Stop it when done
nerdctl stop llm-benchmark-viewer
```

The viewer shows hardware info, a config comparison table, bar charts for T/s /
latency / CPU / RAM, and an expandable per-prompt drill-down for each config.

### Adding new configs

Edit the `CONFIGS` array in `run_benchmarks.sh` and re-run. Each config is a
`num_ctx:max_tokens` pair. The manifest regenerates automatically, and the
viewer picks up all configs — rebuild the viewer (`build-viewer.sh`) to deploy
updates.

## Architecture notes

- Standalone subproject (not part of the cross-build chain)
- The compose stack pulls the official `ollama/ollama` image. A separate custom
  `Dockerfile` + `scripts/download-ollama.sh` also exist for an offline / pre-baked
  binary lane (bake the tarball with `bash linux/llm-stack/scripts/download-ollama.sh`,
  then `nerdctl build linux/llm-stack`); compose does **not** use that image.
- Model auto-pulled on container startup via compose `command` override
- Multi-arch: amd64, arm64 (riscv64 unsupported — Ollama does not ship riscv64 binaries)
- CPU-only by default; an optional GPU override grants the Ollama service all
  NVIDIA GPUs (see § GPU mode)
- Models persist in Docker volumes across restarts
