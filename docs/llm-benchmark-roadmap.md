<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# LLM benchmark — where it stands and what to build next

The suite in [`linux/llm-stack/`](../linux/llm-stack/README.md) grew in a day,
driven by whatever the previous measurement got wrong. This page steps back:
what it can honestly claim today, what it cannot, and the order in which the
gaps are worth closing.

Written 2026-08-31, after the GenieX/Snapdragon measurement round. Every number
quoted here is measured on that host; see
[`geniex-local-ai-setup.md`](geniex-local-ai-setup.md) for the runs themselves.

---

## Where it stands

Six tools, 135 unit tests that need no server:

| Tool | Answers |
|---|---|
| `benchmark_openai_api.py` | throughput, TTFT, decode vs prefill, time-to-answer, generic correctness |
| `bench_coding.py` | does the generated code RUN (classic + novel task sets) |
| `bench_tools.py` | tool calling, including multi-turn and error recovery |
| `bench_lanes.py` | does one server batch; do several lanes add up |
| `inspect_gguf.py` | is this GGUF sane (tensor-type histogram) |
| `bench_provenance.py` | what produced a measurement |

**What it can claim:** for one model family, on one host, with short prompts, a
defensible ranking on speed, code that executes, and tool calling — with cold
start, unenforced constraints, inflated sample counts and truncation artefacts
all removed.

**What it cannot claim:** anything about models outside the Qwen3 family,
anything about a real agent session, and — at n = 3 tasks / 8 cases — anything
statistically separable between two close candidates.

---

## Phase 1 — Make a claim survive scrutiny [S–M]

The measurement errors are fixed; the *statistics* are not.

- **P1.1 Report confidence intervals, not bare fractions** [S·★★★] **DONE**
  (`bench_stats.py`). Scores now print as `8/12 = 67% [39-86%]`, and the
  comparer refuses to call an overlapping difference a regression.
- **P1.2 Prompt-variation sensitivity** [M·★★★] Every task has exactly one
  phrasing. Small models are highly prompt-sensitive, so an unknown share of
  the ranking may be an artefact of wording. Add 2–3 paraphrases per task and
  report the spread; a model whose score swings on rewording is fragile in a
  way the current number hides.
- **P1.3 A control model** [S·★★] No calibration point. When every model fails
  a task there is no way to tell a hard task from a broken one. Run one known-
  strong endpoint (the `ollama` backend, or a hosted model) as a reference row.
- **P1.4 Partial credit** [M·★] Pass/fail cannot distinguish "wrong algorithm"
  from "one edge case missed". Report per-assertion results; a model at 6/7
  assertions is not the same as one at 0/7.
- **P1.5 Record the environment, and serialise runs** [S·★★] Results shift with
  what else is running: a lane benchmark measured 18.56 tok/s on the CPU lane
  against 23.7 alone. Record which lanes were live and refuse to compare runs
  taken under different load.

## Phase 2 — A tripwire, not a scrapbook [M] — the highest-value phase

Every tool writes a report and **nothing reads two of them**. Until that
exists, every measurement is a one-off and a regression is invisible.

- **P2.1 `bench_compare.py`** [M·★★★] **DONE.** Diffs two reports (either
  envelope), attributes a shift to the model, the runtime or the grader via
  `bench_provenance.compare()`, and exits non-zero on a regression.
- **P2.2 Accepted baselines** [S·★★★] **DONE.** `--save-baseline <name>` /
  `--baseline <name>`, stored under `baselines/`.

- **P2.0 — MORE CASES, and it now blocks everything above** [L·★★★] Building
  the tripwire exposed that it has almost no power. Removing the system prompt
  took a model from **8/8 to 6/8** — a real degradation with a known cause —
  and the comparer correctly reported *no regression*, because at n = 8 the
  intervals still overlap. Measured requirement:

  | Drop to detect | Cases needed |
  |---|---|
  | 100 % → 50 % | 12 |
  | 100 % → 75 % | **27** |
  | 100 % → 87.5 % | 60 |

  The suite has **8 tool cases and 3–6 coding tasks**. And on the QAIRT/NPU
  path repeats add nothing — it is deterministic — so power comes *only* from
  more distinct cases. Until the case count reaches ~27, "no regression" mostly
  means "too small to tell", which the comparer now says out loud rather than
  leaving to be discovered. **Authoring cases is the unglamorous work that
  makes every other phase worth doing.**
- **P2.3 Unify the report schema** [M·★★] Four tools, **two incompatible
  shapes** (`{benchmark, provenance, config, reports}` vs
  `{timestamp, model, api_url, hardware, config, results}`), and a viewer that
  reads only the older one. Every downstream consumer — comparison, CI gate,
  viewer — has to special-case this. Converge on one envelope before building
  three readers.
- **P2.4 The viewer shows one tool out of four** [M·★★] Coding, tool-calling
  and lane results are invisible in it. Follows from P2.3.
- **P2.5 Scheduled CI run** [M·★★] The Ollama service already exists in
  `llm-stack-tests.yml`. Run the suite against it on a schedule and fail on a
  regression — that is what turns the tripwire on.

## Phase 3 — Measure the thing you actually run [M–L]

The suite measures *endpoints*. You run an *agent*. Nothing connects the two.

- **P3.1 End-to-end agent task** [L·★★★] Drive opencode against a scratch
  repository with a real task ("add a function and its test, make it pass") and
  record whether it succeeded, how many turns, how long. Everything measured so
  far is a proxy for this, and the proxies have already disagreed once: the
  coding winner was the tool-calling loser until a system prompt fixed it.
- **P3.2 Long context *and* tool calling together** [M·★★★] Measured
  separately, never combined — yet that is precisely an agent turn: a large
  prompt *and* a tool call. The QAIRT bundle's 4096-token ceiling is shared
  between input and output, so a long prompt leaves little room for a call, and
  nobody has checked what breaks first.
- **P3.3 Turn-count and context growth** [M·★★] An agent loop grows its context
  every turn. On a 4096-token model, how many turns until it silently returns
  nothing? That number is more useful than any tok/s figure here.

## Phase 4 — Widen the field [M, gated on downloads]

**Every model measured so far is from one family (Qwen3/Qwen3.8), and no
code-specialised model has been tried.** That is the single largest limit on
the ranking's authority.

- **P4.1 Qwen3-8B W4A16 on the NPU** [M·★★★] The winner's direct competitor:
  same fast prefill, same 4096 ceiling, twice the parameters. ~6 GB.
- **P4.2 A code-specialised GGUF** [M·★★] `Qwen2.5-Coder-7B` or similar — does
  a specialist beat a generalist here, and does its prefill cost sink it?
- **P4.3 The other QAIRT bundles** [M·★] `Ministral-3-3B-Instruct`,
  `Gemma-4-E2B-it`, and `GPT-OSS-20B` if the chipset supports it.
- **P4.4 Cross-family sanity** [S·★★] With more than one family in the table,
  re-check whether the findings (thinking tax, cut-off cap, prefill asymmetry)
  are properties of *this hardware* or of *Qwen*.

## Phase 5 — The remaining backlog items [M–L]

- **P5.1 Embeddings** [M·★★] Endpoints are tested, nothing measures them.
  Needed the moment a RAG or code-search path exists.
- **P5.2 Energy per token** [M·★] The real argument for the NPU on a battery
  device. 165 % vs 752 % of 800 % CPU hints at it; nothing measures joules.
- **P5.3 The lanes never swept** [S·★] hybrid on coding tasks, `nctx` below
  16384, `--ngl` on the GPU lane.

---

## Suggested order

1. **P2.1 + P2.2** — the tripwire. Everything already measured becomes
   defensible against future drift, and it is a day's work.
2. **P1.1** — stop publishing fractions that the sample cannot support.
3. **P4.1** — the one model that could still change the recommendation.
4. **P3.1** — the end-to-end check that tells you whether any of this was
   predictive.
5. Everything else, as the need appears.

## What would change the recommendation

Stated up front so it is falsifiable: today's answer is
`qualcomm/Qwen3-4B-Instruct-2507:W4A16` on the NPU lane with
`prompts/tool-disambiguation.md`. It would be overturned by any of:

- Qwen3-8B matching its latency while scoring higher on the **novel** task set;
- an end-to-end agent run where the 4096-token ceiling makes it fail tasks a
  slower long-context model completes;
- a code-specialised model whose prefill cost turns out to be tolerable in a
  real loop.
