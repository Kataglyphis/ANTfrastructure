# Changelog

## 2026-08-08 (afternoon) — Linux lane: the --no-push hole, and a forensic audit of "green"

### `--no-push` full-chain handoffs never worked on this host

The BuildKit **OCI worker keeps its own image store**: `nerdctl build -t`
loads results into containerd, which the next build's `FROM` never consults —
the mutable parent tag resolves against the **registry**. Every downstream
stage of a `--no-push` chain silently built on the last PUSHED parent. Proof:
a freshly built compiler shipped `/opt/gcc-16.2.0` while the sdk built "from"
it contained `/opt/gcc-16.1.0` (a months-old ghcr image); `FROM
repo@<containerd-digest>` errors "not found". Two full validation runs were
lost to this before the digest trail exposed it. Interim: push mode is the
only correct full-chain flow (docs updated, a warning fires at `--no-push`
parse time); real fix (OCI-layout build-context handoff, the runtime lane's
existing mechanism) is specced in the backlog. The manifest is protected by
running `--to-stage android` + the runtime lane with `--skip-manifest` until
all arches exist.

### A fifth shell bug class, found by auditing the helper scripts

Functions whose **last statement** is `[ cond ] && action` return 1 in the
healthy case; under `set -e` the guard tool kills itself. The flagship victim:
`verify-critical-fixes.sh` — the script guarding the Five Critical Fixes —
aborted after fix 1 **whenever the fixes were actually present**, silently
skipping fixes 2–9 and the summary. It only ever looked green because hosts
don't carry the staged payloads. Fixed there, in `smoke-common.sh` (the
"Unknown arch" guard was unreachable), and lint/preflight/NVIDIA-lane guards
in the same sweep.

### Forensic audit of the build logs: what "21/21 PASS" was hiding

Two-agent sweep over ~12 MB of logs, each claim re-verified:

- **Built 0.15.2, shipped 0.14.0**: the app's `uv.lock` outvoted the chain's
  freshly built `onnxruntime-genai` wheel (`--find-links` only OFFERS).
  Fixed (pre-install + `--no-install-package`), and genai added to the
  version-pin smoke so this class cannot recur unnoticed.
- **The libcamera pin was undercut at the finish line**: the media validator
  did not know meson's `lib/<multiarch>` install dirs, declared the build's
  own libs missing, and apt-installed Ubuntu's older libcamera as a shadow
  copy — a false-positive "repair". Fixed (multiarch dirs in the scan path).
- **ccache delivers zero in LLVM's nested sub-builds** (189 identical objects
  compiled twice, second pass 1.9% slower): `CROSS_TOOLCHAIN_FLAGS_NATIVE`
  forwards no compiler launcher. Plus: no ccache statistics are emitted
  anywhere — and the 2MiB step-log clip truncates **stdout only**, so stats
  (and anything that must survive) belong on stderr. Both queued.
- Still open, prioritized in the backlog: TVM ships import-broken (built
  against distro LLVM 22.1.2, not the pinned 22.1.8 — the telltale line
  prints at INFO), pyav is pinned but never installed, FFmpeg's TF/OpenVINO
  DNN backends died silently, OpenCV links distro GStreamer/FFmpeg due to
  stage ordering, three assertion-free fallback-PASSes, inner smoke warnings
  invisible to the outer verdict.
- Verified NON-issues (do not chase): "missing NVENC" is `ENABLE_NVIDIA`-gated
  by design; runtime Python 3.14.4 is Ubuntu's distro CPython as venv base
  (a decision, not a stale layer); "is not a commit!" clone warnings are
  annotated-tag peeling.

### Also — periphery audit (workflows, hooks, tooling)

A dedicated sweep over the never-audited edges. The flagship: the pre-commit
hook's sphinx gate pointed at a nonexistent `docs/source/` with the real error
swallowed — every commit on a hook-enabled clone failed; fixing the path then
exposed 12 real docs warnings under `-W` (10 orphaned pages now in an
"Operations & Reference" toctree, 2 unknown-lexer blocks) — the strict gate is
green end-to-end for the first time. Also fixed: deps.json's libcamera entry
now bound to `LIBCAMERA_VERSION` (the public license pages published
"git master" past yesterday's pin), the install-deps action's
dirname-of-empty-string putting `.` on GITHUB_PATH, a benchmark-viewer build
that reported success over a failed `npm build`, three unreachable FAIL
branches in the webserver flutter smoke, least-privilege `permissions:` on the
two unpinned workflows, SHA-pins for the last two mutable action refs, rename
coverage (`--diff-filter=ACMR`) and a loud git-grep failure mode in the hook,
and the license generator now fails on unknown versions.env vars and defaults
to check mode. Remaining periphery items are in the backlog.

### Also

- Owner priorities codified: AGENTS.md § Project priorities (speed AND
  stability AND tests, docs always in the same work unit), README
  § Engineering principles.
- buildkitd GC budget pinned (`~/.config/buildkit/buildkitd.toml`,
  gckeepstorage 500GB) + step-log-size drop-in (both effective at the next
  between-runs restart). Unexplained: base cache-missed after the first
  restart despite unchanged mounts and a surviving store — under
  investigation before cross-restart layer reuse is trusted.
- versions.env: 11 bumps (checksums from official sources), libcamera pinned
  for the first time (`v0.7.2` — the only media library that tracked master),
  OpenCV moved to the immutable `5.0.0` tag; ROCm deliberately HELD (new
  "TheRock" releases 404 on the old apt path); LiteRT-LM 0.15.0 verified to
  keep the protobuf 6.31.1 coupling.
- `latest-cross-amd64` shipped: full from-base chain in push mode with
  digest-pinned handoffs + live ancestry annotations; runtime smoke 21/21
  after a host containerd-shim failure was diagnosed (every `nerdctl run`
  died; builds unaffected) and the services restarted. The ancestry guard and
  the annotation-based `--verify-chain` verdicts had their first real-world
  successes the same day.

## 2026-08-08 — Windows lane: backlog cleared before the from-toolchain rebuild

The remaining four items, closed so the chain restarts against a tree with no
known open work. Two of them turned out to be blocked only by a third.

- **Warning floods cut at the source.** 16 % of a chain log (72 864 of 459 061
  lines) was four upstream constructs repeated thousands of times, which matters
  because buildkitd clips a RUN step's log at 2 MiB and then *deadlocks* it.
  Targeted suppressions, never a blanket `-w`: `-Wno-deprecated-copy` (OpenCV
  `matx.hpp`), `/clang:-Wno-unused-value` (ONNX), `-Wno-documentation-unknown-command`
  (TVM), and — because STL4037 is emitted by the MSVC STL headers themselves and
  no clang group can switch it off — `_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING`
  for IREE/MLIR, at directory scope where it survives LLVM's `HandleLLVMOptions`
  stripping. OpenCV's is safe for the CUDA path because the repo's own patch
  strips `-W*` before nvcc's `cl.exe` host compiler sees it (verified against the
  patch, not the comment above it). New `Measure-BuildWarnings.ps1` reports each
  family against its pre-suppression baseline, so the next run PROVES each flag
  still earns its place rather than it becoming folklore.
- **Smoke test split**, 1 573 → 1 386 lines, harness into
  `WindowsSmokeTest.Common.psm1` (no Dockerfile change — the final image already
  COPYs the whole modules dir). The move had one hazard and both halves of it
  fail silently: `Assert-Test` read `$ExitOnFirstFailure` out of the *calling
  script's* scope, which a module cannot see (the switch would have quietly
  stopped working), and the summary read `$script:passed`, which across a module
  boundary would have reported 0 passed / 0 failed and exited 0 on any run.
  Both are explicit state now. An AST inventory of every assertion call site is
  194 before and 194 after, identical as a set; 11 new tests, suite at 412.
- **Pre-commit hooks are enabled**, and the reason they were not is gone:
  `preflight.sh` used bare `python3`, which on this host is the Microsoft Store
  stub, so every commit would have failed for reasons unrelated to the commit.
  It now probes for an interpreter that can actually execute code.
- **Submodule pin drift** (`Kataglyphis-DocumANTation`, `UV_VERSION` 0.12.1 vs
  0.12.3) kept the version-snapshot check red, which is what blocked the hooks.
  Fixed and committed in that submodule; it still needs a push there plus a
  pointer bump here, left explicit because it is a different repository.

## 2026-08-08 — Windows lane: three gaps that could not fail loudly

Landed in the window a concurrent `versions.env` pin bump opened: `PYTHON_VERSION`
3.14.7 invalidates `Dockerfile.base` from its `COPY versions.env` down and every
media stage under the toolchain, so these changes cost no rebuild that was not
already owed. Each one is the same shape as the rest of this week's work — a
check that was structurally incapable of reporting the failure it existed for.

- **The FFmpeg `.pc` gate could not fail in its worst case.** It sat inside
  `if (Test-Path $ffPkgConfigDir)`, so a *missing* `lib\pkgconfig` — the most
  complete failure available — skipped every assertion without a word. Extracted
  to `Assert-FfmpegPkgConfig`, which treats an absent directory as fatal, and
  called outside that guard. Five unit tests, one per failure mode, reaching the
  function by AST extraction so it stays out of the three media branches'
  compile closure (the reason `Remove-MakefileShowIncludes` moved out of the
  shared module on 2026-08-03).
- **The base image's PATH had two dead entries and was missing a live one.**
  `SCOOP_HOME`/`SCOOP_GLOBAL` are scoop app *roots* and hold no executables.
  Meanwhile flutter is installed `--global`, so `C:\ProgramData\scoop\shims`
  exists and was on no PATH entry at all — a 2026-07-14 comment had removed it
  as a "never-created dir", which stopped being true the moment anything was
  installed globally. Invisible only because `FLUTTER_BIN` is baked separately;
  any future global package would have been unresolvable by name. Restored (user
  shims keep priority) and asserted by the smoke test.
- **An unresolved merge conflict had been committed** into
  `docs/refactoring-backlog.md` and survived several commits: two sections were
  appended concurrently and never merged. Markdown and shell lint both pass a
  conflict marker, because it is valid text. Resolved (content verified
  identical modulo the markers), and `.githooks/pre-commit` now greps the
  *staged* content for `<<<<<<< ` / `>>>>>>> ` — verified to fire on the exact
  commit that carried the bug. A bare `=======` is deliberately not matched: it
  is a legitimate Markdown setext underline, and real conflicts carry the others.
- **Nothing was linting the git hooks.** Writing that guard surfaced a live
  `SC1072`/`SC1073` parse error already sitting in `.githooks/pre-commit`: a
  comment starting with the word "shellcheck" reads as a malformed directive and
  aborts ShellCheck's parse of the whole file. It survived because
  `lint-shell.sh` filters to `*.sh` and a git hook cannot carry that suffix.
  Comment reworded, and `lint-shell.sh` now also accepts explicitly-passed
  extension-less files with a shell shebang — default sweep unchanged (223
  files), staged-file coverage gained, and the hook now lints itself.

Note: `core.hooksPath` is **unset** on the primary dev clone, so none of these
hooks have been running there — the documented one-time
`git config core.hooksPath .githooks` (AGENTS.md) is still pending, and is left
to the owner because it changes commit behaviour for every process writing to
that tree.

## 2026-08-08 — Linux cross lane: four bug classes, machine-checked ancestry, live caching

Driven by a from-base amd64 rebuild of `:latest-cross`, fixing every failure as
the chain hit it. The theme mirrors yesterday's: silent failure made loud.

### Four bash bug classes found live, fixed repo-wide, and lint-gated

1. **`trap … RETURN` leaks to the caller** — a RETURN trap set inside a
   function fires again when the CALLER returns, where the function's locals
   are gone; under `set -u` this killed `build-cross-chain.sh` AFTER every
   stage had succeeded. Three instances (parallel-loop, context-management).
2. **Unguarded pipelines under `set -euo pipefail`** — `du` on a
   not-yet-created cache dir aborted the orchestrator on FIRST runs; `readelf`
   on linker scripts, `dpkg -S` on unowned files, `find | head` SIGPIPE and
   friends would have killed the media validators mid-stage. ~10 sites.
3. **Comma-split loops break under `IFS=$'\n\t'`** — `for x in ${list//,/ }`
   runs ONCE with the whole list as one bogus element in strict-IFS scripts.
   Broke the GCC GPG key import AND would have killed the compiler stage's
   multi-target Python staging. New lint suite (`test-ifs-safety.sh`) bans the
   idiom; safe pattern is `IFS=',' read -r -a`.
4. **Vendor scripts sourced under `set -u`** — LunarG's Vulkan `setup-env.sh`
   reads `$1` unguarded and is sourced with explicitly cleared args; killed the
   sdk stage's TVM step. Vendor sourcing now suspends nounset and restores it.

### Cross-invocation ancestry is machine-checked now

Digest pinning only ever protected a SINGLE run. Every pushed cross stage now
records its parent's digest as an OCI manifest annotation
(`org.kataglyphis.parent-digest`); partial runs (`--from-stage` after base)
walk the recorded chain against the registry and hard-fail on a stale ancestor
(`linux/scripts/01-core/ancestry.sh`). `--verify-chain` gives real FRESH/STALE
verdicts from the same annotations. The old "after a compiler push start from
sdk" rule is enforced by the machine, not the reader.

### The GCC GPG failure was a key-rotation, not tampering

gcc-16.2.0 is signed by Richard Biener's key; the script pinned only Jakub
Jelinek's and reported the missing public key as possible tampering (with
SHA512 already OK). Now: accepted key SET, verdict via `gpg --status-fd`
(NO_PUBKEY → warn/skip per policy; BADSIG → fatal), signer checked against the
set so an arbitrary imported key cannot pass.

### Toolchain caching went from decorative to real

The ccache wiring was inverted: the GCC RUN mounted the cache but never exec'd
ccache; the LLVM RUN exec'd ccache but never mounted the cache. Fixed both,
plus `CCACHE_BASEDIR`/`SLOPPINESS` (without which per-target build dirs made
identical TUs never hit) and a multi-word-`CC` PATH fix for the Canadian path.
`--with-build-config=bootstrap-ccache` was PROPOSED and REJECTED — GCC 16
ships no such config (verified against the tarball). Per-target GCC builds can
now run concurrently behind `GCC_PARALLEL_TARGETS=1` (serial apt pre-pass,
divided JOBS, per-target logs; default off).

### Version pins: complete and current

`versions.env` audited for completeness (libcamera was the ONLY unpinned
media library — now `LIBCAMERA_VERSION=v0.7.2`, and the generated wheel stops
lying about its version) and currency (11 bumps incl. Python 3.14.7,
Node 26.7.0, OpenCV `5.x`→`5.0.0` tag = last non-reproducible media pin
closed; ROCm deliberately HELD — the new upstream releases 404 on the old apt
path). All checksums fetched from official sources; a new checker section
catches the case-mapped version literals the ARG checks could not see.

### Also

- `--no-push` validation runs no longer validate STALE registry images: the
  wrapper smoke pulled the published tag over the freshly built one, and the
  runtime handoff pulled `cross-android-<arch>` over the local build
  (BUILT_THIS_RUN now set on the local path too). Runtime chain failures
  propagate instead of reporting success.
- Disk preflight measures the cache dir's own filesystem (not its parent's)
  and survives first runs; `--final-image` is no longer silently overridden.
- apt.llvm.org 5xx no longer kills a multi-hour layer (falls back to source).
- Regression suites: `test-ancestry.sh`, `test-parallel-loop.sh`,
  `test-ifs-safety.sh` — auto-discovered by the pre-commit `script-tests` gate.

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
