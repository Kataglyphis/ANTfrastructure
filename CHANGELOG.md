# Changelog

## 2026-08-07 — Windows lane: reproducibility, mandatory plugins, honest gates

The theme is less the repairs than what they have in common: several things had
been failing **silently** for months, so most of this work is about making
failure loud and early.

### Mandatory GStreamer plugins are a contract now

`libav`, `opencv`, `onnx` and `tflite` were absent from the published
`winamd64` image and nothing was ever red — meson's `auto` feature state means
*skip silently*, and the healthcheck printed `[PASS]` for plugins that did not
exist. Four **unrelated** root causes, diagnosed against gstreamer 1.29.2:

- **opencv** — OpenCV ships no `.pc` at all (confirmed: zero files in the built
  image). One is now authored, enumerating the import libraries from the real
  install (64 of them) instead of a hand-kept list that would rot.
- **onnx** — ONNX Runtime ships no `.pc` on any platform; one is emitted.
- **libav** — `subprojects/FFmpeg.wrap` *provides* the libav\* modules pinned to
  FFmpeg 7.1.1, and `-Dwrap_mode=forcefallback` **forced** meson onto it, so
  pkg-config was never consulted: the build fetched a second, older FFmpeg
  instead of the `n9.0` it had just built. The wrap is disabled before configure.
- **tflite** — consults no pkg-config at all. It probes the compiler for
  `tensorflow/lite/c/c_api.h`, the *pre-rename* path, while LiteRT ships the
  post-rename `tflite/` layout; an alias tree is staged. Confirmed in the field
  that upstream's first library name (`tensorflowlite_c`) does not exist here —
  only its fallback `tensorflow-lite`.

The set lives in `Get-RequiredGstPlugin` and is enforced at four points that
previously disagreed: a pkg-config pre-flight (checking version **floors**, not
just presence), meson features set to `enabled`, a post-install `gst-inspect`
gate that throws, and smoke-test assertions. `tensorfilter` is deliberately
excluded — it is an NNStreamer element this repo never builds.

### FFmpeg's .pc files were unusable

Found by probing the built image rather than waiting for the merge stage:
`Version: ..` (configure found neither a VERSION file nor git tags, because the
source is a GitHub auto-tarball) and MSYS-style `prefix=/c/…` paths that
clang-cl cannot resolve. The empty version alone kept gst-libav out,
independently of the wrap. Both fixed, and gated at the end of the FFmpeg stage.

### Reproducibility

- **LLVM, ninja and nasm pinned** (`LLVM_WINDOWS_VERSION`, …). The OS base was
  digest-pinned while the very next layer installed whatever scoop served that
  day — and five patches in this tree are written against a specific clang-cl.
  Asserted at base-build time.
- **`C:\toolchain-manifest.json`** records every pinned input as a pin/resolved
  pair plus the floating ones, so *which compiler built this image* is answerable
  from the artifact. It captures the MSVC toolset (14.51.36231) that floats
  inside VS major 18 and was previously recorded nowhere.
- **`versions.env` no longer invalidates the whole media chain.** It was COPY'd
  into the stage all three branches descend from, so three Windows-only pins
  re-ran all six media compiles (~90 min of ONNX among them). Versions now travel
  as build-args; the file is demoted to a gap-filler by a precedence rule that
  distinguishes a real build-arg override from a value merely inherited from the
  base image's machine environment.

### Gates that stop lying

- **Disk** is checked per stage, with floors calibrated against measured
  consumption, on every drive the build uses (not just `C:`), in **both** lanes.
- **The runhcs shim** is identified by the SHA256 recorded at install time
  instead of by file size; `deploy-shim-patch.ps1 -RecordCurrent` arms that
  without a redeploy.
- **The CNI conf must exist as BOTH `.conf` and `.conflist`** — buildkitd reads
  one, nerdctl the other, and "converting" between them cost a launched chain.
  The `.conf` is now *derived* from the `.conflist`.
- **Retries** stop immediately when a failure repeats byte-for-byte (a poisoned
  snapshot, whose remedy is `-NoCache` on that stage) but still retry
  snapshot-mount contention, which repeats verbatim and clears anyway. The merge
  stage's `-MaxAttempts 5` had been dead code, because its failure signature was
  never in the transient pattern.

## 2026-07-30 — Agentic loop: backlog-driven planner skip + completed-task pruning

- **Skip planner when tasks are pending** (`backlog.skipPlannerWhenTasksPending`,
  default `true`): while `BACKLOG.md` still has unchecked tasks, iterations go
  straight to the executor instead of paying for a planning pass.
- **Completed tasks are deleted from the backlog**
  (`backlog.deleteCompletedTasks`, default `true`): executor prompts now
  instruct deleting the finished entry (summary goes into the commit message),
  and a deterministic pruner (`remove_checked_tasks` /
  `Remove-CheckedBacklogTasks`) removes any lingering `- [x]`/`- [X]` blocks
  (title + indented body) before each auto-commit and at drain start.
  Completed work stays visible in git history instead of growing the file.

## 2026-07-30 — Agentic loop: live streaming output

- **Claude engine streams by default**: `claude -p` now runs with
  `--output-format stream-json --verbose` (config
  `engines.claude.streamOutput`, default `true`) and both libraries render
  the events live to console + log: session start, one line per tool call,
  assistant text per turn, tool errors, and a final
  `turns / duration / cost` summary. Set `streamOutput: false` to return to
  the silent text mode.
- **Bash opencode invocation streams too**: output is echoed line-by-line to
  console + log as it arrives instead of being buffered until exit (the
  PowerShell module already streamed).

## 2026-07-30 — Agentic loop: Claude Code engine + robustness

- **Engine abstraction** in both agentic-loop libraries
  (`linux/scripts/lib/agentic-loop.sh`,
  `windows/scripts/modules/WindowsAgenticLoop.Common.psm1`): `opencode` and
  `claude` (Claude Code CLI, headless `claude -p`) backends behind a single
  dispatcher (`invoke_agent` / `Invoke-AgenticAgent`). Selection via config
  `engine`, `AGENTIC_ENGINE`, or runner flag; model overrides via
  `AGENTIC_PLANNER_MODEL` / `AGENTIC_EXECUTOR_MODEL`.
- **Claude engine**: role system prompts via `--append-system-prompt-file`,
  planner sandboxed with `--allowed-tools`, executor permission mode
  configurable (default `bypassPermissions`), planner `--fallback-model`
  support.
- **Robustness**: retry with linear backoff per agent invocation, per-role
  timeouts (`plannerTimeoutSeconds` / `executorTimeoutSeconds`), build-failure
  fixer phase (executor-tier model gets the build log tail, then one rebuild),
  consecutive-build-failure cap that stops the loop, dry-run stall guard.
- **Shared loop features moved into the libraries**: planner-only /
  executor-only modes, max-iteration override, default phase prompts.
- PowerShell module: new exports `Resolve-AgenticEngine`, `Invoke-ClaudeCode`,
  `Invoke-AgenticAgent`, `Invoke-AgentProcess`, `Invoke-BuildFixer`,
  `Get-AgenticConfigValue`, `Get-AgentTimeoutForRole`; module version 1.1.0.
  Fixed the refactor planning cycle erroneously reusing the executor prompt.
- Pester suite extended to 38 tests (engine resolution, dispatcher, claude
  dry-run, engine-override loop smoke tests).
