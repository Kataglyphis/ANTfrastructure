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

### Is it fast, or is it *working*? (`--correctness`)

Speed metrics cannot tell a working model from a broken one — a model emitting
fluent nonsense scores **excellent** tokens/sec. That is not hypothetical: a
GenieX i-quant kernel bug produced fast garbage that every throughput number
rated as a good run (see
[`docs/geniex-local-ai-setup.md`](../../docs/geniex-local-ai-setup.md)).

```bash
# quick health check on its own — exits non-zero if any answer is wrong
python3 benchmark_openai_api.py --correctness-only

# or alongside a normal run, recorded into the result JSON
python3 benchmark_openai_api.py --stream --correctness --output result.json
```

Six prompts with **verifiable** answers at `temperature=0` (arithmetic, a
capital city, letter counting, a one-step logic puzzle). The `<think>` block is
stripped before matching and matches are anchored on word boundaries, so a
discarded intermediate value cannot score a false positive.

**Truncation is reported apart from wrongness.** A reasoning model cut off
before it answers was not *wrong* — it was not *measured*. Conflating the two
makes a healthy model look degraded, and a check that cries wolf is a check
people stop reading. Exit codes reflect that:

| Exit | Verdict | Meaning |
|---|---|---|
| `0` | `OK` | every answer correct |
| `1` | `DEGRADED` / `BROKEN` | genuinely wrong answers — act on it |
| `2` | `INCONCLUSIVE` | only ran out of tokens — raise `--correctness-max-tokens` |

It is a smoke test, not a capability benchmark — but it is sharply
discriminating in practice. Measured on Qwen3-4B at `temperature=0`:

| Build | Score |
|---|---|
| `Q4_0` | 6/6 `OK` |
| `Q2_K` (2-bit) | 4/6 — both losses were reasoning items |
| `IQ3_XXS` (broken i-quant kernels) | 0/6 `BROKEN` |

The probes are deliberately cheap. An earlier version asked for `847 * 293`,
which a healthy 4B could not finish within 4000 thinking tokens — so it
reported `INCONCLUSIVE` on a perfectly good model.

### Reading the numbers: TTFT and time-to-answer

Two metrics were added because ranking by `tokens/sec` ranks models *wrongly*:

- **`ttft_s` / `prefill_tok_per_sec`** — time to first token. For an agent this
  is usually the dominant wait (13.1 s on a 2.5k-token prompt in one measured
  case) while `tokens_per_sec` looks healthy. Requires `--stream`.
- **`wall_s_to_answer` / `thinking_char_share`** — a reasoning model can be the
  fastest per token *and* the slowest to a usable answer: Qwen3-1.7B measured
  31.7 tok/s but spent ~1900 tokens thinking, giving 60.8 s to an answer, while
  a 4B-Instruct at 19.5 tok/s answered in 26.8 s. **Rank by time to answer.**

`tokens_per_sec` divides by the whole request and therefore mixes prefill with
decode; `decode_tok_per_sec` reports decode alone.

The summary also names the **busiest process** during the run. On some stacks
the process owning the serving port is not the one doing the work (GenieX
spawns a separate worker: the port owner read 11 % of 800 % while the worker
sat at 752 %), so the report says which PID actually burned the CPU.

### Concurrency: does one server batch? do lanes add up? (`bench_lanes.py`)

```bash
# Does ONE server overlap two concurrent requests?
python3 bench_lanes.py --batching --endpoint http://127.0.0.1:11434 --model llama3

# Do SEVERAL servers add up, or fight each other?
python3 bench_lanes.py --lanes \
  npu=http://127.0.0.1:18181,model=qualcomm/Qwen3-4B-Instruct-2507:W4A16 \
  cpu=http://127.0.0.1:18184,model=unsloth/Qwen3-4B-GGUF:Q4_0
```

`--batching` fires two simultaneous requests at one endpoint. If the second
one's first token arrives only after the first has finished, the server
serialises — **more throughput then needs more servers, not more clients**.
Measured on GenieX: second request's TTFT 74.27 s against the first request's
74.10 s total. Verdict `SERIALISED`.

`--lanes` measures each endpoint alone, then all of them at once, and reports
the per-lane change plus the aggregate. Compute units differ sharply: on one
Snapdragon host the NPU lane lost **0 %** when a CPU lane joined while the CPU
lane gave up **18 %**, for 39.9 tok/s aggregate (1.57x the best single lane).
Aggregate throughput only appears if you really have that many concurrent
requests — one agent waiting for one answer still sees a single lane's speed.

### Which model writes code that actually runs? (`bench_coding.py`)

The correctness probe answers "is this model working at all". It cannot answer
"is this model good at code" — a model can recite Canberra and still emit a
broken function.

```bash
python3 bench_coding.py --backend geniex-npu
python3 bench_coding.py --compare candidates.json --output coding.json
```

Each task pins an **exact required signature**; the reply's code is extracted,
executed in a temporary directory as a separate process with a hard timeout,
and checked against hidden tests chosen to catch plausible-but-wrong answers —
a merge that silently drops duplicates, a bracket matcher that counts instead
of nesting. Nothing is judged by eye. Ranking is by tasks passed, then by time
to a finished answer.

A `<think>` block is stripped before extraction, so a draft the model itself
discarded is never graded in place of its real answer.

**`--repeats N` — because a single run measures one draw, not the model.**
GenieX honours neither `max_tokens` nor `temperature`, so the llama.cpp lanes
sample even at `temperature=0`: five identical requests to one 2B produced five
different answers, four passing the same task and one failing it. That model
scored 2/3 in one sweep and 0/3 in the next; over 9 attempts its real rate is
44 %. The QAIRT/NPU path *is* deterministic (four requests, one unique output),
so repeats there only cost time.

**`--context-tokens N` — because ~40-token prompts are not what an agent
sends.** Prepends real repository source before each task. Prefill and any
hard context ceiling only appear under a realistic prompt: on one NPU bundle
accuracy fell from 3/3 to 2/3 once 1000 tokens of context were added, and past
its 4096-token limit the server returned an empty reply instantly with no
error at all.

Results are also reported in three states, not two: **PASS / FAIL / CUT**. A
reply the server truncated mid-function is *unmeasured*, not wrong — grading it
as a failure once scored a perfectly usable model 0/3. Cut attempts are listed
and then **excluded** from the rate, the interval and the rank, exactly like a
transport error; for a while the footer said "unmeasured" while the arithmetic
counted them as misses.

> **This executes model-generated code.** Each candidate runs in a temp dir as
> a subprocess with a timeout. Do not point it at an untrusted endpoint.

**`--task-set novel` — the textbook tasks measure recall, not coding.** Merging
sorted lists, balancing brackets and parsing a version string appear thousands
of times in any training corpus, so a model can ace them without composing
anything. The `novel` set is built from formats invented in *this* repository
with every rule stated in the prompt: the primitives are ordinary, the
combination cannot have been memorised. **Run both and compare** — a model much
stronger on `classic` than on `novel` is recalling. Measured: the QAIRT
4B-Instruct scores 3/3 classic and **2/3 novel**.

The sets by name, because for a while three places disagreed on what
`extended` meant: `classic` = 3 textbook tasks (the default, and too small to
prove any drop), `novel` = 3, `extended` = the 21 authored tasks, `all` = all
27. The published 17/27 is `--task-set all`.

**Constraints stated in a prompt are now enforced.** The merge task says "do not
use `sorted()`" and for a while nothing checked it — `return sorted(a + b)`
passed every assertion. Each task may declare `forbidden` tokens, checked
against the code with comments and strings stripped so that merely *mentioning*
`sorted()` in a docstring is not punished.

### Can it call tools at all? (`bench_tools.py`)

An agent lives on tool calls. A model that writes flawless code but cannot emit
a valid one never gets to read a file, run a test or apply a patch — so this is
worth checking *before* ranking anyone on code quality.

```bash
python3 bench_tools.py --backend geniex-npu
python3 bench_tools.py --compare candidates.json --repeats 2
```

The case inventory lives in `bench_tools.py` (`TOOLS`, `CASES`,
`MULTI_CASES`) and is deliberately not duplicated here — an earlier version of
this section enumerated the cases and was wrong within a day of the suite
growing. What the cases *cover*:

- **calling at all** rather than describing the call in prose;
- **near-neighbour selection** — `read_file` vs `list_files`, `write_file` vs
  `apply_patch`, `git_status` vs `git_diff`. With only distinct tools a model
  can succeed by elimination, which is not what agents fail at;
- **argument extraction**, including values with spaces and symbols, and
  optional booleans that must be set when asked;
- **restraint** — several cases expect **no** tool call. Over-eager tool use
  burns a round trip and can spin an agent loop, and one negative case out of
  many would let a tool-happy model score well by accident;
- **multi-turn** — is a returned tool result actually *used*, and after a tool
  *error* does the model admit the failure rather than inventing the contents
  of a file it could not read?

Run `python3 -c "import bench_tools as b; print(len(b.CASES)+len(b.MULTI_CASES))"`
for the current count; it is sized so a real regression is provable (see
**Reading a score honestly**).

Grading is strict on tool names and required values, lenient on formatting the
model cannot be blamed for (a `./` prefix, a trailing slash), and it accepts
arguments as either a JSON string or a dict, since servers differ.

**Two of the eight cases are multi-turn**, because a single-turn score cannot
see the failure agents actually hit:

- `multiturn_use_result` — a tool result is fed back; does the model *use* it,
  or emit another call and ignore what came back?
- `error_recovery` — the tool returned an error. Admitting it or retrying is
  fine; **inventing the contents of a file that could not be read is not**, and
  that is the dangerous answer a single-turn benchmark never sees.

### Does the whole agent loop work? (`bench_agent.py`)

Every other benchmark here measures an **endpoint**. You run an **agent**. This
one connects them: a scratch git repository, a task with a verifiable outcome,
and success defined as *the repository's tests pass afterwards* — never by
reading the transcript. An agent that says it fixed the bug and did not is
exactly the failure a transcript cannot catch.

```bash
python3 bench_agent.py --self-test          # prove the fixtures, no model
python3 bench_agent.py --list
python3 bench_agent.py --model geniex-cpu/empero-ai/Qwen3.8-9B-Distill-GGUF:Q4_K_M \
                       --timeout 1800 --output agent.json
```

Run `--self-test` first, and read a run without it with suspicion. It applies a
known-good solution to each fixture by hand and asserts the verification is red
before and green after. Without that, a column of failures is unreadable — a
broken fixture and a weak model look identical, and this suite spent a session
learning to tell those apart.

Three things the scoring does that a naive pass count does not:

- **A blocked run is not a failed run.** If the prompt never fitted the model's
  context, the model never received the task and did not fail it. Those are
  excluded from the denominator, so three blocked tasks report `0/0` — rendered
  `n/a` over a [0%, 100%] interval, never "0%, it cannot code".
- **A timeout keeps its evidence.** The events captured before the deadline are
  parsed, so an agent that made twenty tool calls and ran long is not reported
  as having made none.
- **The fixtures refuse cheap fakes.** Aliasing the old name is not a rename;
  an `assert True` does not test a `clamp` that never clamps. Both are pinned by
  tests.

Expect **minutes per task** on this hardware. That is prefill cost, not model
quality — see `docs/geniex-local-ai-setup.md` § 1m.

### When the lane loses the tool call (`geniex_toolcall_shim.py`)

If an agent run scores **zero tool calls**, suspect the server before the model.
GenieX serves Qwen GGUFs over an OpenAI-compatible API without parsing their
chat template: the model correctly emits

```text
<tool_call><function=bash><parameter=command>…</parameter></function></tool_call>
```

and the server hands it back as `content`, with `tool_calls` empty and
`finish_reason` `"stop"`. The agent sees prose, runs nothing, and ends the turn.

```bash
python3 geniex_toolcall_shim.py --upstream http://localhost:18184 --port 18190
# then point the agent's provider at 18190
```

The shim translates the template into real `tool_calls` and sets
`finish_reason` accordingly. It never invents a call from markdown code fences —
a model that writes ```` ```bash ```` is not requesting execution, and guessing
there runs commands nobody asked for — and a call cut off mid-template yields no
call at all, only its markup removed.

### What every report records

All tools write a `provenance` block: UTC timestamp, host, OS, architecture,
git SHA **and whether the tree was dirty**, the served model ids, and a
`tool_sha256` fingerprint of the benchmark's own source. That last one matters
most — a ranking can move because the *grader* changed, and without the
fingerprint that is indistinguishable from a model regression.
`bench_provenance.compare()` diffs two blocks and says so in as many words.

Fields that cannot be determined are recorded as `null` and listed in
`incomplete` rather than omitted: a gap you can see is a gap you can fix.

### Reading a score honestly

- **Warm-up is on by default.** Without it the first task carries the model load
  time and the ranking partly ranks load order — measured: ~34 s of the 27B's
  128.7 s total was loading, 26 % of its score-deciding number.
- **`effective_n` is reported, not just the raw total.** On a deterministic
  endpoint (the QAIRT/NPU path) every repeat returns the identical answer, so
  counting repeats inflates the apparent sample without adding information.
  Determinism is decided on the **output** — one hash per task across its
  measured repeats — not on pass/fail agreement, which a sampling endpoint
  that fails every draw also produces; the latter is reported separately as
  `repeats_agreed`. When the lane is deterministic the unit is the task:
  `effective_k`/`effective_n` are counts of tasks observed and passed, never a
  ratio rounded back into a count (that printed 8/9 for seven passes).
  Errored and cut attempts do not vote.
- **Median, min, max and stdev** accompany every total, because a mean over a
  cold first run and two warm ones describes neither.

### Is this GGUF even sane? (`inspect_gguf.py`)

```bash
python3 inspect_gguf.py model.gguf            # human-readable
python3 inspect_gguf.py --json model.gguf     # machine-readable; exit 1 if RISKY
```

Reads only the file header (instant on a 16 GB model) and prints the
architecture, imatrix metadata and the **tensor quantisation histogram**. That
histogram is what diagnosed a real failure no benchmark could have caught:
files dominated by sub-4-bit i-quants (`IQ3_S`, `IQ3_XXS`, `IQ2_*`, `IQ1_*`)
produced fluent garbage on GenieX v0.5.0, while plain K-quants at the same bit
width (`Q3_K_M`) and `IQ4_XS` were fine. Verdicts:

| Verdict | Meaning |
|---|---|
| `OK` | no sub-4-bit i-quant tensors |
| `LIKELY OK` | under 5 % of them (a known-good file had 4 tensors) |
| `RISKY` | i-quant-dominated — exit code 1 |

### Backends

Endpoints are named in `backends.json`, so neither the Ollama service nor a
Snapdragon lane has to be addressed by a URL typed from memory:

```bash
python3 benchmark_openai_api.py --list-backends

python3 benchmark_openai_api.py --backend ollama      --stream   # this stack
python3 benchmark_openai_api.py --backend geniex-npu  --stream   # NPU lane
python3 bench_lanes.py --lanes geniex-npu geniex-cpu             # both at once
BENCH_BACKEND=geniex-cpu bash run_benchmarks.sh                  # whole sweep
```

`ollama` is the default — it is the service `docker-compose.yml` brings up. A
backend entry may pin a default model, which is why `--backend geniex-npu`
needs no `--model`.

Resolution order, most specific first:

| # | Source | Notes |
|---|---|---|
| 1 | `--base-url` | explicit, wins over everything |
| 2 | `LLM_BASE_URL` / `OLLAMA_BASE_URL` | env beats `--backend` on purpose, so a wrapper script that exports it is not overridden by a stale config default |
| 3 | `--backend <name>` | from `backends.json` |
| 4 | the entry marked `default` | `ollama` |

An unknown name **fails loudly and lists the known ones** rather than falling
back to the default — silently benchmarking the wrong machine is the expensive
failure here. A missing or malformed `backends.json` never blocks an explicit
URL.

### Backend support — what is verified, and what is not

| Backend | Status |
|---|---|
| **GenieX** (Snapdragon NPU / GPU / CPU lanes) | verified end to end on real hardware |
| **Ollama** | stub tests for the dialect differences, plus `tests/test_harness_against_ollama.py` which runs the harness against a **live** server — it skips locally when none is up, and CI starts a digest-pinned `ollama/ollama` service, so that is where it is confirmed |

The Ollama dialect differs from GenieX in three ways that this harness had to
learn, each with a test in `tests/test_backend_compat.py`: Ollama sends
`data: ` **with** the space (GenieX omits it), it offers `/api/tags` when
`/v1/models` is unavailable, and existing scripts set `OLLAMA_BASE_URL`. Those
paths are exercised, but a stub is not a server — run one command against your
real instance before trusting a long sweep:

```bash
LLM_BASE_URL=http://your-ollama:11434 python3 benchmark_openai_api.py \
    --prompts 1 --stream --correctness-only
```

### Pointing the harness at something other than Ollama

Set `LLM_BASE_URL` (the old `OLLAMA_BASE_URL` still works). Model detection
asks the portable `/v1/models` first and only then falls back to Ollama's
native `/api/tags`, so GenieX, llama.cpp and vLLM endpoints work unchanged.

### 2. Build the viewer

```bash
cd linux/llm-stack/benchmark-viewer
bash build-viewer.sh
```

Builds the React + Recharts app using a Node 20 container (no host Node needed).

**What the viewer shows.** A **correctness banner** sits above every speed
number — a broken model is fast, so "is it working?" has to outrank "how
quickly?". Below it the comparison table leads with **time to a finished
answer** (the metric to rank by), then TTFT, decode rate, overall tok/s and the
share of output spent thinking. Drilling into a run adds per-prompt prefill
speed and the process that actually burned CPU.

Older result files predate these metrics. They render `-` and are dropped from
the charts rather than being drawn as `0`, which would claim an instant first
token.

**Smoke-render check** (needs `npm install` in `benchmark-viewer` once):

```bash
cd linux/llm-stack/benchmark-viewer && npm run smoke
```

`vite build` only proves the JSX compiles. This renders every component
server-side against the real manifest — including legacy runs — and asserts the
new numbers reach the DOM. It exists because both failure modes it checks for
actually happened while these metrics were added: a component that throws only
at render time, and an edit that silently failed to apply so the table rendered
empty cells.

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
