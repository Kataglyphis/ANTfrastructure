# LLM Stack — serving

Ollama + Open WebUI for serving LLMs with an OpenAI-compatible API, designed
for integration with Nextcloud Assistant.

**The benchmark lab moved.** The measurement suite, its capability evals, the
viewer and the tracked results now live in **OrchestrANT**
(`benchmarks/`, plus the `orchestrant.benchmark` package and its
`orchestrant-bench` entry point); the runner half is installed with the
OrchestrANT test extra. This stack is the reference server those benchmarks
point at, and `backends.json` below is the registry that names its lanes.

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
| Gateway (APISIX) | 9080 | http://127.0.0.1:9080/v1 | Keyed front door to the GenieX lanes (§ Gateway) |
| Gateway status / metrics | 7085 / 9091 | `/status/ready`, `/apisix/prometheus/metrics` | Liveness and per-lane metrics |

## Named backends

`backends.json` maps a lane name to a `base_url`, an optional default `model`,
and optional `api_key_env` / `headers` / `request_extra` fields. It is read by
three consumers:

* OrchestrANT's benchmark runner (`orchestrant-bench`, resolution order
  `--base-url` > `LLM_BASE_URL` / `OLLAMA_BASE_URL` > `--backend <name>` > the
  registry's `default` entry), which also finds the file through `LLM_BACKENDS`
  or its vendored hub checkout.
* `windows/scripts/host/Start-GeniexServers.ps1`, which reads the model ids for
  the Snapdragon lanes it starts.
* `gateway/render_apisix.py`, which reads only the top-level `serving` block and
  the entries its lanes name (§ Gateway).

Adding a lane here is the one edit every consumer needs; never put an API key in
this file, only the NAME of the environment variable holding it.

## Gateway

APISIX 3.18.0 in front of the GenieX lanes: one keyed endpoint on
`127.0.0.1:9080`, model aliases instead of lane ports, and the GenieX rules the
lab measured applied on the way through. **Phase P1: the lab only.** Lanes are
started by hand, nothing listens beyond localhost, and Open WebUI is not wired
yet (P2). This section is how it works, how to run it and how it is accepted.

| File | What it is |
| --- | --- |
| `backends.json` → `serving` | The source of truth: gateway listeners, clients, lanes, aliases, the pinned tools prompt |
| `gateway/render_apisix.py` | Renders `apisix.json` + `config.yaml` from it, and refuses what it cannot vouch for: an unknown lane, backend or key, a GGUF on the QAIRT lane, a prompt whose raw bytes miss their pin, a listener off loopback, a route id emitted twice (APISIX would silently keep the last), a lane that is the gateway itself |
| `gateway/config.template.yaml` | APISIX's boot config (listeners, the 7 loaded plugins, the hook) |
| `gateway/lua/apisix/plugins/geniex-shape.lua` | The per-route plugin: tools prompt, `power_mode`, size estimate, log tags |
| `gateway/lua/geniex_hook.lua` | Four patches of APISIX internals (below) |
| `docker-compose.gateway.yml` | APISIX only, host network, image pinned by digest, config and Lua read-only |
| `scripts/serve-stack.sh` | `up`, `reload`, `down`, `status`, `keys`, `validate` |

### Running it (WSL)

```bash
# Once: three random client keys into the state dir (mode 600).
bash linux/llm-stack/scripts/serve-stack.sh keys
# The lanes, on the Windows host (mirrored WSL networking reaches loopback):
#   pwsh -File windows/scripts/host/Start-GeniexServers.ps1 -BindAddress 127.0.0.1 -WithCpu `
#        -Models @{cpu='empero-ai/Qwen3.8-9B-Distill-GGUF:Q4_K_M'}
#   (a lane already running is skipped; one on another address gets a warning: -Restart rebinds it)
# The consumer names the directory holding the pinned prompt:
export ANTFRASTRUCTURE_LLM_PROMPTS_DIR=/mnt/c/GitHub/OrchestrANT/benchmarks/prompts
bash linux/llm-stack/scripts/serve-stack.sh up       # render, validate, (re)start, wait
bash linux/llm-stack/scripts/serve-stack.sh status   # running vs what the registry renders now
bash linux/llm-stack/scripts/serve-stack.sh reload   # routing change, no restart
bash linux/llm-stack/scripts/serve-stack.sh down
```

**Keep WSL running.** WSL stops a distro soon after its last session ends
(`instanceIdleTimeout`), and the gateway's container stops with it: the first
acceptance run on the dev host (2026-09-25) found every request refused on
`127.0.0.1:9080` minutes after a clean `up`. Until the P3 supervisor holds it,
keep one session open for as long as the gateway should serve, e.g.
`wsl.exe -d Ubuntu-26.04 --exec sleep infinity` in a spare terminal.

The lab then uses the `lab-*` entries with `GW_KEY_LAB` exported from the keys
file (`ANTFRASTRUCTURE_LLM_GATEWAY_DIR/keys.env`).

| Knob | Default | Meaning |
| --- | --- | --- |
| `ANTFRASTRUCTURE_LLM_PROMPTS_DIR` | none | Where the pinned prompt files are; the render refuses without it |
| `ANTFRASTRUCTURE_LLM_GATEWAY_DIR` | `~/.local/state/antfrastructure/llm-gateway` | State: `keys.env`, `live/` (what is mounted), `logs/requests.jsonl` |
| `ANTFRASTRUCTURE_LLM_BACKENDS` | this directory's `backends.json` | The registry to render |
| `ANTFRASTRUCTURE_LLM_ENGINE` | `nerdctl` if present, else `docker` | Container engine (`<engine> compose` too) |
| `ANTFRASTRUCTURE_LLM_GATEWAY_PROJECT` | `llm-gateway` | Compose project name |
| `GW_KEY_WEBUI`, `GW_KEY_LAB`, `GW_KEY_AGENT` | from `keys.env` | Client keys; an exported variable wins. 16+ characters of `[A-Za-z0-9._~+/-]`, all different |

**`up`** renders into `candidate/`, boots that candidate in a throwaway
container (`--net=none`, dummy keys) and refuses it unless it serves its own
`/gateway/info` and its boot log shows no dropped item, parse error or failed
plugin load: APISIX drops an invalid item with one error line and serves the
rest. It then installs the bundle, recreates the container and waits until
`/gateway/info` reports the new `config_sha256` five times in a row (two
workers). **`reload`** does the same without a restart: it refuses when the
image, the boot config or the Lua changed (`restart_sha256` differs; run `up`),
waits until the next whole second (APISIX compares mtimes in seconds), rewrites
`apisix.json` in place (a rename would leave the single-file bind mount on the
old inode) and puts the previous file back if the new config sha never shows.
A new key needs `up`: keys live in the container's environment. `keys.env`,
`live/runtime.env` (the env file compose reads) and `compose.log` (compose
echoes the environment) are mode 600; the rest of `live/` is world-readable,
because the container's uid 636 reads it. The overlay's
healthcheck (bash `/dev/tcp` against `/status/ready`; the image has no curl)
runs under docker; rootless nerdctl 2.3.5 records no health state for it, so on
the dev host `serve-stack.sh status` is the check.

### Routes

| Route | Matches | Lane | Notes |
| --- | --- | --- | --- |
| `models` | `GET /v1/models`, no key | none | Static list of the aliases; never touches a lane (GenieX lists its whole cache and hangs while busy) |
| `gateway-info` | `GET /gateway/info`, no key | none | Image, `config_sha256`, `restart_sha256`, boot-config, Lua, prompt and registry shas |
| `chat-presend` (priority 30) | `model == chat` and the estimate over `budget_tokens` | gpu | R3a: large requests skip the NPU |
| `chat` (20) | `model == chat` | npu, then gpu once | R3b: on a 5xx or a relabelled overflow |
| `chat-long`, `agent` (20) | `model ==` alias | gpu, cpu (9B) | One lane each: nothing to retry |
| `raw-npu`, `raw-gpu`, `raw-cpu` (20) | `model == raw-<lane>`, lab key only | that lane | No GenieX shaping; the transparency path |
| `unknown-model` (0) | any other model | none | OpenAI-format 404 `model_not_found` |

Routing on `model` reads the JSON body, so a request without
`Content-Type: application/json` gets the 404. The estimate is
`ceil((body bytes + tools-prompt bytes) / bytes_per_token) + (max_tokens or
default_reserve)`; `bytes_per_token` wants calibrating from lab reports.

### The GenieX rules, and where each one lives

| Req | Rule | Mechanism | Proven by (`tests/gateway_e2e/`) |
| --- | --- | --- | --- |
| R1 | Aliases, each lane's model pinned | One route per alias; `options.model` | `test_each_alias_goes_to_its_lane_once` |
| R2 | Pinned tools prompt, only with non-empty `tools` | Plugin: sha-checked bytes as the first system message; a request already starting with it is left alone; a client's own system message stays second (D9, not measured) | `test_the_prompt_*` |
| R3a | Too large for the NPU → GPU before sending | `gw_est_tokens` on the priority-30 route | `test_a_large_request_*`, `test_the_estimate_*` |
| R3b | NPU overflow → GPU, once | Hook relabels the NPU's `400 context_length_exceeded` to 503; `http_5xx` fallback, `max_retries: 1`. Another 400 passes unchanged; a GPU overflow is not retried | `test_an_npu_overflow_*`, `test_a_second_overflow_*` |
| R4 | T=0 made greedy on the GGUF lanes only; `power_mode` dropped | Hook, per lane (`0.01` + `top_k 1`); the NPU keeps T=0 (owner decision: P8.1 ran at T=0) | `test_t0_*`, `test_power_mode_*` |
| R5 | No retries, no 429 cap | Single-lane routes cannot retry; `chat` falls back once, never after the reply started (hook), never after the primary's own timeout; no rate limits, no cache, keepalive off; a client hang-up closes the lane's connection | `test_a_lane_that_dies_mid_stream_*`, `test_the_npu_times_out_*`, `test_two_failing_lanes_*`, `test_a_single_lane_route_never_retries`, `test_a_lane_429_*`, `test_concurrent_requests_*`, `test_a_client_that_hangs_up_*` |
| R6 | 300 s on the NPU, 1800 s on the GGUF lanes | Hook: cap raised, timeout per lane (per socket operation, so no stream is capped) | `test_the_npu_times_out_*`, `test_the_gpu_waits_out_*`, `test_a_route_above_*`, `test_the_fallback_attempt_gets_the_gpu_timeout` |
| R7 | SSE and tool calls pass through | Chunks forwarded as they arrive (`streaming_flush_interval_ms: 0`) | `test_sse_passes_*`, `test_tool_calls_*` |
| R8 | A key per client | `key-auth` on `Authorization`, stored as `Bearer ${{GW_KEY_*}}`; lanes get `Bearer unused`; every listener on 127.0.0.1 | `test_every_client_*`, `test_the_lane_never_sees_*`, `test_the_keys_on_disk_stay_private`, `test_every_listener_is_on_loopback` |
| R9 | One JSON log line per request, per-lane metrics | Global `file-logger` + `prometheus`; plugin sets lane, reroute and prompt tags | `test_one_log_line_*`, `test_metrics_*` |
| R10 | Nothing probes a lane | No `checks` anywhere; `/v1/models` static | `test_models_is_static_*` |
| R11 | The lab through the gateway | `lab-*` registry entries (`probe: false`), static `/v1/models`, `/gateway/info` | `test_gateway_info_*` |
| R12 | Generated, pinned, validated config | Renderer, digest pin, throwaway validation, sha-checked reload | `test_validation_*`, `test_reload_*`, `test_gateway_render.py` |

### The hook: four patches of APISIX 3.18.0 internals

`geniex_hook.lua` is loaded through `apisix.lua_module_hook` and patches each
worker before APISIX's own worker init. It fails loudly (a `moved` error, which
validation refuses) when a patched internal is gone, and warns when APISIX is
not 3.18.0.

1. **Timeout cap.** `ai-proxy(-multi)` caps `timeout` at 600000 ms in its
   schema; the hook raises it to 1800000. Without it every route with a GGUF
   lane is dropped at load.
2. **Per-lane policy in the transport.** `ai-transport.http.request` is
   wrapped: each attempt gets its own lane's timeout (the plugin allows one per
   route, so the NPU would get 1800 s on `chat`) and its lane's T=0 rewrite.
3. **Overflow relabel.** On a lane armed for it (the NPU on `chat`), a `400`
   whose body names `context_length_exceeded` becomes `503`, so the 5xx fallback
   moves the request to the GPU once. `$upstream_status` therefore logs `503`;
   the log's `rerouted: overflow` tells it from a real one.
4. **No fallback after the response started.** `ai-proxy.base.before_proxy`'s
   retry callback is wrapped: once headers are sent, a lane failure ends the
   stream instead of sending the whole request to the GPU for nobody.

**Upgrade rule: re-run the e2e suite (and Stage A below) before any APISIX
bump.** Each patch was mutation-tested on 2026-09-25: removing it turns these
tests red, and nothing else (rows 2 and 4 re-run on the 79-test suite).

| Removed | Red |
| --- | --- |
| 1, the cap | `up` itself: validation refuses the dropped routes (every test errors) |
| 2, the transport wrap | 11: both overflow tests and the second-overflow test, the NPU timeout, the GPU timeout after a fallback, the three T=0 tests, the prompt after an overflow, the fallback log line, the reload test (the hook must outlive a reload) |
| 4, the headers guard | `test_a_lane_that_dies_mid_stream_is_not_retried` |
| `nginx_config.envs` | `test_reload_swaps_routing_in_place_and_keys_survive_it`: a hot reload cannot resolve `${{GW_KEY_*}}` and the old config stays live |
| The plugin's prompt insert | the prompt tests |

### What a client sees that a direct lane does not

- Replies carry the lane's model id, not the alias.
- Streams get a final usage chunk with empty `choices`: `stream_options.include_usage` is forced.
- Bodies reach the lane re-encoded with keys sorted at every level (tools included), and the lane's path gets a bare `?` appended. The `raw-*` routes are not byte-transparent, so Stage A must control key order. What survives (`test_tool_definitions_keep_their_meaning_not_their_bytes`): array order, `{}` and `[]`, every number's value (a whole-number float loses its `.0`), non-ASCII as UTF-8.
- Only the lane's status and `Content-Type` come back, plus `X-Gw-Lane` and `X-Gw-Rerouted` (`no`, `presend`, `overflow`, `fallback`).
- The lane sees `X-Consumer-Username` and `X-Forwarded-*`; never the client's key.
- A 401 is APISIX's `{"message": …}`, not OpenAI's error format.
- `/v1/completions` rides the passthrough: it keeps the lane model but logs 0 tokens and gets no token metrics.
- After a fallback, `ttft_ms` and the latency metrics time the GPU attempt only.

### Logs and metrics

`logs/requests.jsonl` in the state dir gets one line per request: `consumer`,
`route_id`, `alias`, `lane`, `rerouted`, `prompt`, `est_tokens` (chat routes),
`status`, `upstream` (both addresses after a fallback), `upstream_status`,
`model`, token counts, `ttft_ms`, `upstream_ms`, `request_s`, `stream`, `tools`,
`tool_calls` and `aborted` (`read_error` for a lane that died mid-stream). The
AI-route lines of a run window are the R5 evidence: one line, one address, per
request. Prometheus on `127.0.0.1:9091` labels LLM latency and tokens by
`node` = lane and `consumer`; the exporter refreshes every 15 s and skips a
0 ms latency. `apisix_llm_active_connections` is not a queue gauge: every
fallback leaves the NPU series one too high.

### Tests

```bash
python3 -m pytest linux/llm-stack/tests                     # offline: renderer, overlay, registry
GATEWAY_E2E=1 python3 -m pytest linux/llm-stack/tests/gateway_e2e   # live: pinned image + fake lanes
```

The e2e suite starts three fake OpenAI lanes in the test process (SSE,
overflow, crash mid-stream, first-byte hold, reset; each answers per a
`X-Fake-<Lane>` request header and records what it received), renders a
fixture registry with timeouts scaled to 2 s / 6 s / 1800 s, and drives the
real `serve-stack.sh up` … `down`. CI runs it on x64 and arm64
(`llm-stack-serving.yml`, job `gateway-e2e`).

### Acceptance (P1): the lab benchmarks the gateway

Both stages on one day, one GenieX version, serving on hold, a quiet host.

- **Stage A, transparency** (`lab-raw-X` against direct `geniex-X`, `geniex-cpu-9b` for the CPU lane):
  every `contract` answer equal (`identical_repeat_intact`, the prefix-cache
  checks, the `tool_calls` shape, the `/v1/completions` stop sequence);
  `bench_chat --correctness-only` and `bench_tools` without `--system` give the
  same answers, with the direct baseline sent with sorted keys or key order
  shown not to matter; `orchestrant-bench speed` TTFT within noise; the AI-route
  log lines equal the requests sent, one address each, `rerouted: no` throughout.
- **Stage B, shaping** (`lab-chat`): `bench_chat` reproduces P8.2; `bench_tools`
  is not separable from `geniex-npu --system benchmarks/prompts/tool-disambiguation.md`
  (P8.1); `contract` differs only where expected (`power_mode_understood` no,
  `overflow_is_clean_error` a GPU 200); a ~7k-token document logs
  `route_id: chat-presend, lane: gpu`; with `estimate.bytes_per_token` raised
  (say to 1000) so the estimate never fires, an overflow logs one NPU and one
  GPU attempt, `rerouted: overflow` and a 200, streamed and not. (Not
  `budget_tokens`: the renderer refuses a budget at or above the NPU's 4096.)
- **Upgrade gate:** Stage A and the overflow row again after every APISIX or GenieX bump.

Not covered yet: how GenieX answers a streamed overflow (only a 400 before the
stream is handled), whether it stops generating when a client hangs up (the
gateway does close the lane's connection then), the
gateway's TTFT overhead on the real lanes, its idle memory, and the P2/P3 work
(Open WebUI, a logon supervisor, `hold`/`release` for lab windows).

## Nextcloud Assistant configuration

Settings → AI → OpenAI-compatible endpoint:

- **URL**: `http://localhost:11434/v1`
- **API key**: *(leave blank)*
- **Model**: `gemma4:26b`

## What AGENTS.md used to say about this stack

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading and the relative links. The RULES stayed there; this is the reference behind them.

A standalone serving stack lives in `linux/llm-stack/` (docs in its own
README). CPU-only is the compose default; an opt-in GPU override
(`linux/llm-stack/docker-compose.gpu.yml`, `docker compose -f docker-compose.yml
-f docker-compose.gpu.yml up -d`) grants the Ollama service all NVIDIA GPUs and
raises `OLLAMA_CONTEXT_LENGTH`. **VRAM caveat:** the context Ollama lists is the
model's max, not what fits — ~19 GB of weights + ~104 KB/token q8_0 KV means a
28 GB stack (e.g. 12 GB + 16 GB GPUs) caps at ~64K, and 256K needs >45 GB VRAM.
Requires the nvidia-container-toolkit on any host that wants GPU mode.

**The stack is the family's reference server.** Endpoints are named in
`linux/llm-stack/backends.json` (`ollama` is the default; the GenieX lanes are
listed too), and the model ids there are what `Start-GeniexServers.ps1` starts —
one edit serves both consumers. Never put a key in that file, only the NAME of
the environment variable that holds it.

**The benchmark suite moved to OrchestrANT.** The `orchestrant.benchmark`
package owns the runner (one request path, the backend registry, speed and
lane measurement, statistics, provenance; `orchestrant-bench speed|lanes|report`)
and `benchmarks/` carries the capability evals (coding, tool calling, the agent
loop, embeddings, sweep, compare), the viewer and the tracked results, with
their docs. Read the measurement rationale there — including **why correctness
is gated first: a broken model is fast**, and the sub-4-bit i-quant evidence.
`llm-stack-serving.yml` runs this directory's serving-shape tests and a
compose-parse check. The NAS document-AI thread -- the census tool, its tests and
its page -- moved to OrchestrANT on 2026-09-15, beside the benchmark lab it
belongs to.

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
