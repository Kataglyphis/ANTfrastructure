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

- **P2.0 — more cases** [L·★★★] **DONE for `bench_tools` (8 → 27).** Building
  the tripwire showed it had almost no power: removing the system prompt took a
  model from 8/8 to 6/8 — a real degradation with a known cause — and the
  comparer correctly reported *no regression*, because at n = 8 the intervals
  overlap. Detecting 100 % → 75 % needs 27 cases.

  The expansion immediately earned itself: two failure modes the 8-case suite
  could not see. The model mangled an identifier (`___init__.py` for
  `__init__.py`), and in one multi-turn case it *talked about* the tool call —
  "I already confirmed that `list_files` has been correctly called" — without
  ever telling the user what the files were.

  `bench_coding` still has 3 classic + 3 novel tasks. Each additional one needs
  a test set, a reference solution and a known-wrong solution (the task tests
  enforce both), so it is real authoring work rather than a copy-paste.

- **P2.6 Per-case diffing beat the statistics** [S·★★★] **DONE**, and it
  changes how the tripwire should be read. Even at 27 cases the observed
  25/27 → 22/27 drop is *not* separable — because a 93 % baseline carries a
  wide interval of its own, and separating 93 % → 81 % would need **119**
  cases. Perfect baselines are far cheaper statistically than near-perfect
  ones.

  For a deterministic endpoint the aggregate is the wrong instrument anyway.
  The comparer now diffs **per case**: a case that passed and now fails is a
  concrete, attributable change needing no statistics at all. On the same pair
  of runs it names the five cases the system prompt fixes — and the **two it
  breaks** (`extract_query_with_symbols`, `use_listing`), which no aggregate
  score had revealed. It also catches a swap that leaves the score identical.

## Phase 3 — Measure the thing you actually run [M–L]

The suite measures *endpoints*. You run an *agent*. Nothing connects the two.

- **P3.1 End-to-end agent task** [L·★★★] **DONE 2026-09-04** —
  `linux/llm-stack/bench_agent.py`, written up as § 1m of the GenieX page. It
  did what it was supposed to: it disagreed with every proxy. opencode's fixed
  preamble measures **8,175 tokens**, so the recommended QAIRT bundle (4096
  compiled in) fails all three tasks with **zero tool calls** — the models were
  never the constraint, the short prompts in every prior benchmark were.
  Then "zero tool calls" turned out to be the *server*: GenieX v0.5.0 returned
  Qwen's `<tool_call>` template as plain content, so no agent ever saw a call.
  Behind `geniex_toolcall_shim.py`, on the CPU lane with a trimmed tool set,
  `Qwen3.8-9B-Distill` scored **3/3, verified by the repositories' own tests**,
  at 10-14 minutes per task. **The suite has now observed a pass** — until then
  it had only ever seen failures, and a bug that made everything fail would have
  looked identical. Re-run on **GenieX v0.6.1** (2026-09-05), which parses the
  template itself and has a prefix cache: still 3/3, no shim, **657 s for all
  three tasks** where one used to take 656 s.
- **P3.2 Long context *and* tool calling together** [M·★★★] **Answered by
  P3.1** for the QAIRT lane: what breaks first is the context, and it breaks
  before any tool call is attempted. Ten tool schemas are 5,286 tokens on their
  own — more than the whole 4096 budget, prompt excluded. Still open for the
  GGUF lanes, where both fit and the question is quality rather than survival.
- **P3.3 Turn-count and context growth** [M·★★] **Answered, and worse than the
  question assumed.** On the 4096 model the answer is *zero* turns. On the GGUF
  lanes the limit is not the ceiling but the cost of approaching it: there is
  **no prefix cache** (the identical request twice costs 126 s then 122 s), so
  every turn re-prefills the whole conversation at 38-61 tok/s. Context growth
  is paid for again, in full, on each turn.

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

## Phase 4b — Refactoring review, applied (2026-08-31) — CLOSED

A six-dimension review with an adversarial stage that rejects any proposal
unable to name a concrete future task it helps: **45 proposals, 26 rejected,
19 kept — all now applied.**

- **P4b.1 `bench_cli.py`** [DONE] The candidate-resolution block was
  byte-identical across 17 lines in both tools, comment included — and the
  None-label defect existed in **both copies and was fixed twice**, only
  because an audit happened to sweep every file. Extracting it also revealed a
  **third instance the earlier fix had missed**: the single-run branch still
  read `args.label or args.model or model`, so `--backend ollama` with no
  `--model` would have crashed the same way. `resolve_candidates()` and
  `write_report()` now have 12 tests where there were none — nothing in
  `tests/` imports `main()`, so the code deciding *which endpoint gets
  measured* was entirely uncovered. Report writing is also atomic now.
  **`bench_cli.py` is deliberately excluded from `tool_sha256`**: that hash
  means "the grader moved", and folding plumbing into it would fire the alarm
  on every schema edit while the grader is provably unchanged.
- **P4b.2 One report envelope** [DONE for the two newer tools] Both now write
  through `write_report()`; `bench_compare`'s adapter still covers
  `benchmark_openai_api`'s legacy shape, which the viewer reads.
- **P4b.3 `bench_report.py`** [DONE] The per-config summary, manifest generator
  and comparison table left `run_benchmarks.sh` (192 → 131 lines). They were
  heredocs: unreachable from pytest, un-lintable, quoting-fragile — and one had
  already grown a comment about a `KeyError` that "killed the whole comparison
  under `set -e` at the end of every multi-hour run". 12 tests now.
- **P4b.4 `--base-url`** [DONE] `bench_lanes` spelled it `--endpoint` while
  both siblings said `--base-url`; kept as an alias.
- **P4b.5 `resolve_lane(spec, path=)`** [DONE] Its tests were wired to the
  shipped `backends.json` and broke on any edit to it. A test that fails for an
  unrelated change is one people learn to ignore.

**Verified after the refactor rather than assumed:** a live 27-case run scored
**25/27 in 78.7 s** against 25/27 in 79.0 s before it. The comparer then
reported `BENCHMARK SOURCE CHANGED` *and* `unchanged` in the same breath —
exactly the separation the fingerprint exists for — and the baseline was
re-recorded, which the reviewer had priced as the real cost of this refactor
and the proposal had not.

**222 tests**, up from 196.

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
4. ~~**P3.1**~~ — done 2026-09-04. It was **not** predictive: the suite ranked
   models while the binding constraints were prompt size, prefill throughput,
   and a server that silently discarded every tool call. None of the three was
   measurable through a short prompt, and the third was indistinguishable from
   "the model is bad at tools" until someone read the raw response body. Prefer
   a cheap end-to-end check *early* over a deep proxy suite — and when a
   benchmark reports zero of something, look at the wire before believing it.
5. Everything else, as the need appears.

## What would change the recommendation

**Partly overturned on 2026-09-04, and not by a model.** The answer below
stands for chat and completion. For *agent* use it is wrong: the bundle cannot
run opencode at all (§ 1m of the GenieX page). Agent work belongs on a GGUF
lane, at roughly two minutes per turn.

Stated up front so it is falsifiable: today's answer is
`qualcomm/Qwen3-4B-Instruct-2507:W4A16` on the NPU lane with
`prompts/tool-disambiguation.md`. It would be overturned by any of:

- Qwen3-8B matching its latency while scoring higher on the **novel** task set;
- an end-to-end agent run where the 4096-token ceiling makes it fail tasks a
  slower long-context model completes;
- a code-specialised model whose prefill cost turns out to be tolerable in a
  real loop.
