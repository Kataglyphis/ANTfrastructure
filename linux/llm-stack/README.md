# LLM Stack — serving

Ollama + Open WebUI for serving LLMs with an OpenAI-compatible API, designed
for integration with Nextcloud Assistant.

**The benchmark lab moved.** The measurement suite, its capability evals, the
viewer and the tracked results now live in **OrchestrANT**
(`benchmarks/`, plus the `orchestrant.benchmark` package and its
`orchestrant-bench` entry point); the runner half is installed with the
OrchestrANT test extra. This stack is the reference server those benchmarks
point at, and `backends.json` below is the registry that names its lanes.

`nas_census.py` stays here for now (the NAS document-AI thread); it is
documented in [`../../docs/nas-document-ai.md`](../../docs/nas-document-ai.md).

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

```bash
nerdctl compose -f linux/llm-stack/docker-compose.yml logs -f
```

## GPU mode (NVIDIA)

The default stack is CPU-only. `docker-compose.gpu.yml` is a compose overlay
that grants the ollama service all NVIDIA GPUs and raises the default context
window via `OLLAMA_CONTEXT_LENGTH`:

```bash
docker compose -f linux/llm-stack/docker-compose.yml -f linux/llm-stack/docker-compose.gpu.yml up -d
docker exec llm-stack-ollama-1 ollama ps   # PROCESSOR column = 100% GPU
```

It requires the NVIDIA container toolkit on the host.

### VRAM & context sizing

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

## Services

| Service | Port | URL | Purpose |
|---------|------|-----|---------|
| Ollama | 11434 | http://localhost:11434/v1 | OpenAI-compatible API |
| Open WebUI | 3000 | http://localhost:3000 | Chat UI for debugging |
| Glances | 61208 | http://localhost:61208 | System monitoring dashboard |

## Named backends

`backends.json` maps a lane name to a `base_url`, an optional default `model`,
and optional `api_key_env` / `headers` / `request_extra` fields. It is read by
two consumers:

* OrchestrANT's benchmark runner (`orchestrant-bench`, resolution order
  `--base-url` > `LLM_BASE_URL` / `OLLAMA_BASE_URL` > `--backend <name>` > the
  registry's `default` entry), which also finds the file through `LLM_BACKENDS`
  or its vendored hub checkout.
* `windows/scripts/host/Start-GeniexServers.ps1`, which reads the model ids for
  the Snapdragon lanes it starts.

Adding a lane here is the one edit both consumers need; never put an API key in
this file, only the NAME of the environment variable holding it.

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
