# Windows backlog archive — closed items and history (archived 2026-08-11)

Everything below was the live "Refactor Backlog (Windows container chain)"
section of docs/windows-builds.md until the 2026-08-11 close-out. All items
annotated *(DONE ...)* are completed and verified (gates held after every
sub-batch: Invoke-Lint 141 files 0/0 incl. the AST-trap pass, 457/457 unit
tests, Test-PatchesApplyClean 12/12). Consult for evidence and rationale;
do not resurrect items without re-verifying against the current tree.
The lean OPEN-only backlog lives in docs/windows-builds.md § Refactor Backlog.

---

## Addendum — closed 2026-08-14 (Batch B: driver/log hardening, zero rebuild)

Eight backlog items landed in one sitting. Selection criterion: **none touches a
Dockerfile**, so nothing invalidated a cache layer and the whole batch was
verifiable with lint + unit tests alone — no container build. Result: lint
152/0, tests **484/484** (up from 480; the 4 new ones are #40's regression
guard). All eight came out of the 2026-08-14 deep audit.

- **41 (DONE) The retry path destroyed the failing attempt's log.**
  `build-buildkit.ps1` teed without `-Append`, so attempt 2 truncated attempt 1
  — a stage that burned its budget kept only the last attempt, and when
  attempt 1 held the real compile error while 2-3 died on infra flakes the
  evidence was gone. Now: log cleared once per RUN, appended per ATTEMPT with a
  `===== attempt N/M =====` banner. Direct "never swallow logs" fix, inside the
  path that exists to survive failures.
- **42 (DONE) The failure tail was computed, then thrown away — both lanes.**
  `$tail` was built purely to CLASSIFY the error and then discarded, so the
  throw carried a bare path (BK) or a bare exit code (classic) and the owner
  opened a deliberately-unbounded log by hand. Both lanes now print the tail
  before throwing, and the classic lane's throw names the log file.
- **43 (DONE) 4 of 5 ninja logs died with the build tree; genai had none.**
  Only ONNX wrote to the persistent `$SCCACHE_DIR\logs`; opencv/iree/tvm/litert
  wrote inside `$buildDir`, which is discarded with the failed solve (IREE is a
  60-120 min build whose only surviving diagnosis was a 50-line tail), and
  `build-onnx-genai` passed no `-LogFile` at all, so not even that existed.
  **Fixed as a SHARED helper, not five copies:** `Get-PersistentBuildLogPath`
  in `WindowsSourceBuild.Common.psm1`, with all six call sites converted —
  including ONNX's original inline block. Copy-paste is exactly how this drift
  happened; there is now one implementation to drift from.
- **39 (DONE) `-MediaBranches <subset>` silently shipped a STALE image.** The
  merge is skipped on a branch subset, but torch/final still resolved
  `BASE_IMAGE` from the `windows-media` tag — the PREVIOUS run's merge. So
  "I fixed LiteRT, re-ship" delivered a `winamd64` without the fix, with a zero
  exit code. Now throws when the merge is skipped while torch/final are
  selected, naming both the subset and the missing branches.
- **40 (DONE) The scripted resume never worked (closure scope).**
  `.GetNewClosure()` snapshots LOCALS only, but
  `$Docker`/`$MediaCoreCpus`/`$MediaMemoryGb`/`$ResumeStage` are script-level
  `param()` vars → empty inside the module invoker, degrading the run to
  `[] run --isolation hyperv --cpu-count  --memory "g"` and dying with a
  PowerShell *parser* error that pointed nowhere. The identical fix had been on
  the sibling `Invoke-RunCommitStage` since 2026-07 *with an explanatory
  comment*; this path never got it. Fixed with four local copies. **Note the
  first draft of this entry overstated it:** the `docker container rm -f` is NOT
  data loss — the state is committed to `$partial` and exit-code-checked first,
  and the removal is required to reuse the container name.
  **NEW TEST — guards the CLASS, not the instance:**
  `tests/Driver.ClosureScope.Tests.ps1` walks the AST of both drivers, finds
  every `.GetNewClosure()` block *inside a function*, and fails if it reads a
  top-level `param()` variable that is not shadowed by a local. It correctly
  ignores top-level closures (there, params ARE locals) and locally-shadowed
  names like `$isolation`; it carries its own negative control (a synthetic
  re-introduction of the defect must be caught) and a false-positive control
  (the sibling's correct pattern must NOT be flagged).
- **62 (DONE) `-ConcurrentAux` dropped six parameters — three guaranteed a
  failure AFTER media-core was paid for.** Children re-run the full preflight
  with defaults, so `-SkipHostChecks`, `-SkipRdna4Gate`, `-SkipStepLogGate`,
  `-NoSccache`, `-MinFreeGb`, `-HostReserveGb` now forward.
  `-ConcurrentAux -NoSccache` previously could NEVER succeed. Same change adds
  **fail-fast** (a child dying at minute 5 was unnoticed until the other
  finished ~40 min later) and a **`finally` that stops surviving children** —
  they were spawned outside any `try`, so killing the parent orphaned two
  pwsh+buildctl trees racing the same store.
- **63 (DONE) Every preflight-gate failure orphaned a hidden sampler.** It
  started ~500 lines before the `try` that owns it, so each rejected launch
  (sccache down, RDNA4 enabled, disk short, dockerd stopped — all common) left
  an invisible `-WindowStyle Hidden` pwsh in a `while ($true)` loop forever, one
  per failed attempt. Moved to immediately before the `try/finally`; the
  preflight costs seconds, so no sample coverage is lost.
- **64 (DONE) The driver prescribed a remedy it could not express.** The
  determinism gate says "the fix is `-NoCache` on this stage alone, NOT a
  retry", but `-NoCache` applied to every solve — for a poisoned
  `media-core-built-opencv` the only lever was `-Stages media -NoCache`, which
  re-does all four media-core sub-stages plus litert plus tvm plus merge. Added
  **`-NoCacheStage <label[]>`**, substring-matched against the same `$Label` the
  stage logs and disk gate already use (`-NoCacheStage opencv` works).

## Addendum — closed 2026-08-13 (`:winamd64` green end-to-end)

- **34 + ELEVATED WINDOW + dufs (DONE 2026-08-13, applied by owner).** Owner ran
  the between-runs elevated bundle: (1) buildkitd service env restored
  (`BUILDKIT_STEP_LOG_MAX_SIZE/-SPEED=-1`) so `-SkipStepLogGate` is no longer
  needed; (2) GC budgets deployed (`apply-buildkitd-gcpolicy.ps1`, buildkitd.toml
  400/450GB) — fixes the cross-run snapshot eviction (#34); (3) poisoned
  probe-build-copy layer chain pruned (`probe-build-copy.ps1` no longer FALSE
  RED); (4) diagnostic tag cleanup. Also ran `setup-dufs-service.ps1` → dufs is
  now a session-independent SYSTEM ONSTART task (no more mid-run WebDAV-write
  fail-open). Sanity: `buildctl debug workers -v` should show reservedSpace=200GB.
- **Upstream issues (POSTED 2026-08-13):** mozilla/sccache#2808 (nvcc deadlock +
  miscompile) and google-ai-edge/LiteRT-LM#3245 (CMake-lane staleness). opencv/opencv
  (dnn ORT `char*`/`wchar_t`) draft still unposted.
- **28 (LANDED 2026-08-13) Ninja job-count `-MemGBPerJob 2`.** Changed `4`→`2`
  at the build-onnx-from-source.ps1 (line ~451) and build-opencv-from-source.ps1
  (line ~295) `Invoke-NinjaBuildWithRetry` call sites → ~19 jobs (from ~9) at the
  measured ~1 GB/process, well under the 39 GB budget. Code landed + lint/tests
  green; the throughput win verifies on the next full media-core build.
- **27 (DONE + VERIFIED 2026-08-14) Dockerfile.base 1214-char single-line RUN →
  mounted script.** Extracted the pwsh-7 bootstrap blob into
  `windows/scripts/bootstrap-pwsh.ps1` (WPS-5.1-safe, byte-identical logic:
  3-attempt backoff + in-loop SHA256 + original-exception rethrow) and rewrote
  the base RUN to `RUN --mount=type=bind,source=windows/scripts/bootstrap-pwsh.ps1,target=C:\bootstrap-pwsh.ps1 & 'C:\bootstrap-pwsh.ps1'`.
  Bind-mount, NOT COPY — no layer, nothing COPY'd this early in base by design;
  runs under WPS 5.1 (SHELL not yet switched to pwsh). Despite the item's
  "never alone / batch with a base bump" caveat, verified standalone with a
  scoped `-Stages base` build: **step `#6 … RUN --mount=…bootstrap-pwsh.ps1… DONE
  11.1s`**, build proceeded to VS Build Tools (#9) — the mounted-script bootstrap
  behaves exactly as the inline blob did. Lint 151/0, parse-clean. NOTE: landing
  it busts the base-tier cache (base instruction changed) → the next full chain
  rebuilds downstream of base; that cost is inherent to the change, not the
  verify build.


- **37 (DONE 2026-08-13) TVM `import tvm` → WinError 127.** Root cause was NOT
  an LLVM ABI skew (the archived suspicion): TVM 0.25 vendors `3rdparty/tvm-ffi`
  at an UNRELEASED commit (0.1.13.dev1, not on PyPI), so the PyPI `apache-tvm-ffi`
  wheel pip pulled was ABI-skewed vs our source-built `tvm_runtime.dll`. Fix =
  build tvm_ffi FROM the vendored source + install the tvm wheel `--no-deps`
  (build-tvm-from-source.ps1). Three sub-fixes gated that source build:
  `Copy-CpythonPyConfigHeader` (CMake-4.4 FindPython can't read in-tree
  pyconfig.h), install `cython` (core.pyx transpile → MSB8066), install
  `typing_extensions` (`--no-deps` starves tvm_ffi's only declared dep). See
  memory `tvm-ffi-source-build-winfix`.
- **36 (DONE 2026-08-13) litert branch → BAZEL — chain integration complete.**
  The canary recipe (`build-litert-lm-bazel.ps1`) was wired into the media-litert
  branch and the full chain built green; media-litert now produces
  litert_lm_main.exe via bazel, CMake path frozen as fallback. Included the
  zlib.net→GitHub-mirror WORKSPACE patch (flaky-download fix).
- **(NEW, not previously numbered) GStreamer merge stage — 8 versions.env-bump
  regressions** that blocked `:winamd64`, all fixed 2026-08-13: /LIBPATH-breaks-
  clang-cl, opencv-5 data-dir + API relocation (xobjdetect/geometry/calib),
  tflite C-API export, cpp_std c++11→c++17 (MSVC 14.51 STL), plugin-LOAD gate
  (recursive dumpbin walker), and CUDA-runtime FLATTEN-deploy for opencv's
  cudnn64_9.dll (`stage-cuda-runtime.ps1`). Full detail in memory
  `gstreamer-merge-winfix`. Verified: `[bk] Done in 00:41:30` →
  `local/kataglyphis:bk-winamd64` (all stages, GPU).

---

## Refactor Backlog (Windows container chain)

> Cross-lane / Linux-side items live in [docs/refactoring-backlog.md](refactoring-backlog.md);
> this section owns the WINDOWS chain exclusively (pointer there exists too).

Owner-requested backlog from the 2026-08-10 systematic code review (8-angle
sweep over `windows/`). Ordering = suggested attack order: correctness-adjacent
first, then reuse, then cosmetics. **Before touching anything, check the
cache-tier map** (AGENTS.md / windows-refactor notes): edits to base/toolchain
closure files force a full chain rebuild — batch those, and never remove the
deliberate media-merge version-ARG mirrors.

**Contents**: P0 architecture (0a-0c) → P1 correctness-adjacent (1-4,
16-19) → P2 reuse (5-9, 20) → P3 hygiene (10-15, 21-25) → second-pass
build-definition/ops items (26-32) → pending host/upstream actions →
already-fixed protocol. Cross-cutting pairs to do together: #1+#18 (RDNA4
single source), #7+#19 (patch-stanza helper incl. hard-fail rung), #8+#30
(log convention + retention).

### Execution guide (effort·impact legend as in docs/refactoring-backlog.md; tier = what a change cache-busts)

Work the backlog in BATCHES keyed on the cache tier — every media-closure
edit costs one ONNX-vertex rebuild, so land them together:

| Batch | Items | Tier | Effort | Impact |
|---|---|---|---|---|
| **W0 pending actions** | buildkitd env (now ENFORCED by the 0a gate — restore before run 13!), sccache issue, tag cleanup | host | S | ★★★ (unblocks log visibility) |
| **W1 host-only quick wins** | ~~2, 5, 6, 8+30, 9, 12, 13, 15, 21, 22, 24, 25, 29~~ ALL DONE | host scripts/tests only — zero cache impact | S-M | ★★ |
| **W2 preflight architecture** | ~~0a, 0c, 1+18, 26, 32~~ ALL DONE | host (drivers, diagnostics, probe assets) | M | ★★★ |
| **W3 media-closure batch** | ~~3, 4, 7+19, 10, 11, 16+17, 20, 23~~ ALL DONE (2026-08-10 night, landed inside run 12's already-busted closure window) | media closure | M-L | ★★★ |
| **W4 base-tier batch** | 27 (+ anything else touching base closure) | base — FULL chain rebuild; batch with the next planned base bump | M | ★ |
| **W5 process/policy** | 0b (CI half DONE — patch-drift job; human bump-protocol half stands), 28 (measurement RUNNING: per-process fleet sampler captured run 12's ONNX compile → `out\build-logs\onnx-tu-memory-samples-20260810.csv`; analyze, then split job pools), 31 (needs the registry-creds decision) | repo/CI policy + measurements | M | ★★★ |

OPEN as of 2026-08-10 night: **NEW 34 [M·★★★, P0] — the chain has NO
cross-run caching; MECHANISM IDENTIFIED (2026-08-11 ~08:15): snapshot GC
eviction under an undersized tier-2 budget, NOT export nondeterminism.**
Evidence chain: (i) prefix stages rebuild every driver run (73/35 min
instead of seconds, zero manifest-digest overlap between runs 14/15);
(ii) back-to-back canary solves show digests ARE stable on cache-hit
re-export (with AND without SOURCE_DATE_EPOCH) — so the exporter is
deterministic given cached snapshots; (iii) the run-over-run delta is the
hours of vertex churn between runs: tier 2 (buildkitd.toml, `keepDuration
720h, maxUsedSpace 150GB`) is far below one night's vertex fleet
(multiple ONNX/OpenCV generations at tens of GB each), so GC evicts the
OLDEST snapshots = the prefix stages; the re-solved layers carry fresh
internal file timestamps → new blobs → new digests → downstream FROMs
miss, cascade. `BUILD_DATE`/`VCS_REF` stamps are exonerated (they reach
only torch/final). FIX (elevated window, bundle with the W0 env restore):
raise tier-2 maxUsedSpace 150→350GB and tier-3 240→450GB in
windows/buildkitd.toml (930 GB disk, ~790 free — satisfiable; keep the
2026-08-08 invariants), redeploy via apply-buildkitd-gcpolicy.ps1.
SIDE-FINDING from the fix research: `rewrite-timestamp=true` on the
Windows image exporter CRASHES mid-finalize and poisons the layer chain —
never use it here (see the probe-chain cleanup pending-action). Item-34 fix research (2026-08-11 ~08:00): **`rewrite-timestamp=true` on the Windows image exporter is DANGEROUS** — it crashed mid-finalize (`hcsshim::ActivateLayer ... process cannot access the file`) and left a POISONED SNAPSHOT in the probe's layer chain (same snapshot id failed identically on the next two solves; a unique-layer discriminator solve was green, so the damage is chain-local, not a host wedge). ⚠ Until that snapshot is pruned (`buildctl prune` of the probe refs / worst case reboot), **probe-build-copy.ps1 will return a FALSE RED on this host** — do not trust a probe verdict before the cleanup. Epoch-only canary (no rewrite-timestamp) running separately. **NEW 35 [observe·★]**: run-15's ffmpeg stage stalled
for ~120 min between `Enter-VsDevCmdEnvironment`'s vswhere-fallback line
(15 s) and the awk-replacement line (7216 s) — a section that runs in
seconds normally (run 14: whole prefix 177 s; no scoop-install messages,
so both install branches were skipped). Smells like a stuck TCP/timeout
(VsDevCmd first-run or scoop probe); transient, self-recovered, build
continued green. If it recurs, wrap the section's candidates in explicit
short timeouts. Also **27** (base-tier window), **28** (analyze the
captured samples → pool split), **31** (owner decision), **0b human half**
(bump protocol), **33** *(DONE 2026-08-11 morning: unmapped patch dirs now FAIL with
"add it to $repoMap"; current tree 12/12 mapped+OK.)* Everything else in this
backlog is closed.
Done-when held throughout: gates green after every sub-batch (lint 141
files 0/0 incl. the new AST-trap pass, 457/457 tests), behavior changes in
AGENTS + this doc + CHANGELOG per repo priority 4.

### Pending host/upstream actions (not refactors — do not let these evaporate)

- **Restore the buildkitd service env** (`BUILDKIT_STEP_LOG_MAX_SIZE=-1`,
  `MAX_SPEED=-1`): found EMPTY on 2026-08-10 (wiped by the Stevedore/repair
  work); the default 2 MiB step-log clip hid verdicts all day. Elevated
  `setup-new-host.ps1` (idempotent, refuses during builds) or the registry
  Multi-String + `Restart-Service buildkitd` — ONLY between chain runs.
  **Since 2026-08-10 night this is ENFORCED: `Assert-BuildkitdStepLogEnv`
  refuses to launch the BK driver until restored (0a).**
- **Make dufs session-independent** (attribution dossier 2.8, 2026-08-10
  night): today it is an ONLOGON scheduled task bound to the RDP session —
  alive at driver-launch time (so Assert-SccacheEndpoint passes), killable
  by a mid-run logoff/lock, and every WebDAV write then fails OPEN
  (multilevel policy `l0`) with zero L2 entries as the only symptom.
  Convert to a Windows service or ONSTART/SYSTEM task + single-instance
  guard (two dufs.exe were live on 2026-08-10). Evidence:
  `out/sccache-fault-attribution.md`.
- **Post the sccache upstream issue**: `out/upstream-issue-sccache-nvcc.md`
  now carries BOTH failure classes — the deterministic server death on the
  fused_moe launchers (±2 s across two runs) AND the silent miscompilation
  of arch-guarded instantiations (runs 10/11 vs bare-nvcc run 5, fresh-cache
  control) — ready to file against mozilla/sccache. The
  docker/for-win#14977 comment is already posted.
- **Admin cleanup of 2026-08-10 diagnostic tags** (`copyprobe-*`, `sweep-*`,
  `rdna4ab-*`, `flush-*`, `size*`, `pw*`, `mlchain-probe`,
  `verify-cuda-cache`, `postboot-*`, `nano-*`, `gpuab-*`, **plus the
  pre-rename stable probe tags `probe-build-copy` and
  `probe-build-copy-heavy`** — orphaned by the #29 `diag-` prefix adoption,
  so the `findstr diag-` one-liner does NOT find them): admin
  `nerdctl --namespace buildkit rmi` per docs § Store GC (see backlog #29
  for the durable convention).

### P0 — architecture-level (highest leverage; from the same review's deep pass)

0a. *(DONE 2026-08-10 night: `Assert-BuildkitdStepLogEnv` (non-admin registry
    read, throws with the elevated remediation, `-SkipHostChecks` downgrades)
    closed the one missing cheap check — disk/shim/daemon/RDNA4/dufs-endpoint
    gates already ran in both drivers. NOTE: the gate now REFUSES to launch
    until the wiped buildkitd env is restored — do W0 first.)*
    **Host-drift detection as a mandatory driver preflight.** Four of the
    2026-08-10 blockers were pure host drift (dufs ONLOGON task dead after
    reboot, buildkitd service env wiped by the Stevedore repair, Defender
    exclusion uncertainty, dGPU state): the code is reproducible, the host
    is not. `verify-host-setup.ps1` already exists — carve out its CHEAP
    subset (service-env registry read, dufs HEAD request, RDNA4 state,
    shim hash) and run it at the top of BOTH drivers. Seconds at launch
    instead of minute-80 surprises.
0b. *(HALF DONE 2026-08-10 night: `patch-drift` job added to
    windows-scripts.yml — Test-PatchesApplyClean now runs in CI on every
    windows/**/versions.env trigger (shallow+sparse clones, ~minutes). The
    HUMAN half stands: a versions.env bump still needs one local full-chain
    build before trust — CI builds no containers.)*
    **Version bumps must ride the Windows lane.** The 2026-08-03 bump
    (ONNX 1.28, OpenCV 5.0.0) carried FIVE latent Windows breaks because
    `[build-win]` is opt-in and nobody built the bump. Rule: versions.env
    bump commits require `[build-win]` (or a weekly scheduled canary), and
    `Test-PatchesApplyClean.ps1` runs as a pre-commit gate whenever
    versions.env changes — that alone would have caught the OpenCV patch
    drift before any container built.
0c. *(DONE 2026-08-10 night: `Driver.PreflightParity.Tests.ps1` — shared
    contract table + lane allowlists with reasons + a catch-all that fails on
    any NEW unlisted `Assert-*` in either driver; caught its first real case
    (`Assert-ImageExists`) on the first run.)*
    **Lane parity is unowned.** The RDNA4 gate initially landed only in the
    BK driver; the classic lane got it a day later via review. Either demote
    build.ps1 to bootstrap-only, or add a parity test (BuildKit.TwinParity
    is the in-repo pattern) asserting both drivers wire the same preflight
    set.

### P1 — correctness-adjacent (drift that already bites or will)

1. *(DONE 2026-08-10 night: `Get-Rdna4HazardDevice` + `Set-Rdna4DeviceState`
   exported from WindowsBuildDriver.Common are the single source; the gate,
   toggle (empty `-GpuName` default = resolve all hazard SKUs, `-NoPrompt`
   for automation) and the A/B all consume them. +3 unit tests.)*
   **RDNA4 hazard set exists in THREE divergent copies**: the
   `Assert-NoActiveRdna4Gpu` regex (covers RX 9xxx + AI PRO R9700), the
   hardcoded `FriendlyName -eq 'AMD Radeon RX 9070 XT'` in
   `toggle-rdna4-gpu.ps1`, and the same literal as `-GpuName` default in
   `test-rdna4-layer-lock.ps1`. Concrete dead end: on an RX 9060 host the
   gate refuses and points at a toggle script that cannot find the device.
   Fix: export ONE `Get-Rdna4HazardDevice` from WindowsBuildDriver.Common and
   let toggle + A/B resolve through it. *(The gate regex additionally
   gained `(TM)`-rename tolerance on 2026-08-10 — the other two copies did
   NOT, widening the drift this item exists to close. Do together with
   #18.)*
2. *(DONE 2026-08-10 — candidate lists landed same-day (scope note: the truly single-candidate set was 6); the night batch finished the consolidation: reset-container-stores + verify-cuda-cache now resolve via `Get-PreferredToolPath` (candidates → PATH; `$null`-safe — the old `Test-Path $bt` threw when buildctl was absent), and reset-container-stores' hardcoded `D:\GitHub` repo path became `$PSScriptRoot`-relative. DELIBERATE keepers: probe-build-copy stays inline (first-script-on-a-new-host must be module-free), collect-host-docker-state's glob is forensics enumeration not tool resolution, deploy-shim-patch/verify-host-setup keep their overridable Program-Files param defaults — the shim deploy target must not silently follow a stale D:\ layout)* **The Stevedore tool path was hardcoded single-candidate in several files**
   (2026-08-10 evening sweep: probe-build-copy, verify-cuda-cache,
   test-rdna4-layer-lock, test-layer-rename, test-process-isolation-commit,
   deploy-shim-patch, reset-container-stores, verify-host-setup, ... — only
   build-buildkit.ps1 and friends carry the candidate list incl.
   `D:\Stevedore\bin`). On a D:\ layout the diagnostics throw exactly where
   they are needed, and the constant now has a dozen copies. Fix:
   `Get-PreferredToolPath` (already exported by WindowsScripts.Shared)
   everywhere; one candidate list, zero copies.
3. *(DONE 2026-08-10 night: `Write-SccacheStatsToStderr` in
   WindowsScripts.Shared (name states the sink; the sink-stays-with-caller
   doctrine holds for other consumers); called end-of-build by ALL SIX
   source-build scripts — onnx, opencv, genai, tvm, iree, litert.)*
   **Consolidate the ONNX stderr stats loop into `Write-SccacheStats`**
   (give the helper a `-Sink Stderr` switch and call it) so formatting and
   the `-RequireRemote` contract live in one place and the next CUDA
   consumer (TVM/OpenCV) inherits the clip-surviving sink for free.
   *(The original finding's acute half — the missing `-RequireRemote`,
   which would have spawned a throwaway server on no-remote builds — was
   fixed same-day; only the consolidation remains.)*
4. *(DONE 2026-08-10 night: onnx ninja logs to
   `$env:SCCACHE_DIR\logs\onnx-ninja.log` — the PERSISTENT cache mount, so
   the stream survives a failed vertex into the next run/debug container;
   one `.prev` rotation generation bounds growth.)*
   **ONNX ninja runs without `-LogFile`** — the full ninja stream exists
   only in the (clip-prone) step log; `[n/1891]` progress is invisible from
   the host. Violates the never-swallow-logs invariant. Fix: pass a LogFile
   under the build tree (or out-mounted), always.

### P2 — reuse / single-source-of-truth

5. *(DONE 2026-08-10 night: the A/B now delegates each GPU-state side to
   `probe-build-copy.ps1 -Heavy` — digest-pinned base, lane logs and the
   output-shape lessons live once; the A/B only orchestrates GPU state.)*
   **`test-rdna4-layer-lock.ps1` re-implements the finalize probe** that
   `probe-build-copy.ps1` (exit codes + `-Heavy` + per-lane Tee logs) was
   just upgraded to provide. Fix: call the probe (or extract a shared
   lane-runner) so the load-bearing output-shape/quoting lessons live once.
   *(Its log-swallowing was fixed same-day — the duplication remains.)*
6. *(DONE 2026-08-10 night: toggle lifted into the module as
   `Set-Rdna4DeviceState` (post-state-verified); toggle script + A/B finally
   block both consume it, and the toggle gained `-NoPrompt` + exit 1 on a
   failed state change.)*
   **GPU toggle logic duplicated** between `toggle-rdna4-gpu.ps1` and the
   A/B script's finally-block re-enable (the safety-critical path). Fix:
   parameterize the toggle script (`-GpuName`, `-NoPrompt`) and call it, or
   lift the toggle into the module.
7. *(DONE 2026-08-10 night: `Invoke-SourcePatchWithFallback` in
   WindowsSourceBuild.Patches (fallback scriptblock runs in caller scope,
   `-Fatal` throws on a double miss); all six build-onnx stanzas collapsed;
   4 unit tests incl. the Fatal rung. See #19.)*
   **Patch-apply stanzas ×6 in build-onnx-from-source.ps1** (try →
   Invoke-SourcePatch → catch → inline fallback → WarnMessage, near-identical
   each time; 3 added on 2026-08-10 alone). Fix: `Invoke-PatchWithFallback`
   helper in WindowsSourceBuild.Patches.psm1.
8. *(DONE 2026-08-10 night: `Get-DiagnosticLogPath` + `Limit-DiagnosticLogs`
   in WindowsScripts.Shared own path + retention; verify-cuda-cache
   consumes them, the A/B's copy vanished with the #5 delegation, and
   probe-build-copy keeps its inline block BY DESIGN (module-free
   first-script rule).)*
   **Log-persistence convention has no owner.** Pair with #30.
9. *(DONE 2026-08-10 night: script-local `Invoke-ProbeLane` (exe check, Tee
   log, tail echo, exit report, attempted/failed bookkeeping) called for
   all three lanes; args are quoted array elements per the ArgQuoting
   lesson. NOTE: not yet live-smoked — run `probe-build-copy.ps1 -Heavy`
   once after run 12's media-core finishes, before trusting a verdict.)*
   **probe-build-copy's three lanes are the same 9-line block ×3.**

### P3 — cosmetics / hygiene

10. *(DONE 2026-08-10 night: log reset once up front, every invocation
    appends; flag deleted.)*
    **`$invokeNinja`'s positional `$true/$false` append flag**
    (WindowsSourceBuild.Common): delete the LogFile once up front and always
    `-Append` — removes a silent-log-truncation failure mode and two
    branches.
11. *(DONE 2026-08-10 night: marker is the single channel; the job stream
    only speaks when a marker WRITE fails — see #17.)*
    **Stall-guard verdicts print twice** (job stream + marker file re-read).
    Marker file is the single source of truth (ladder reads it, survives
    clip) — drop the Write-Output/Receive-Job channel.
12. *(DONE 2026-08-10 W1)* **`Native.ArgQuoting.Tests.ps1` manual case-insensitive loop** —
    `-notcontains` already compares case-insensitively; five lines → one.
13. *(DONE 2026-08-10 W1)* **Fake-ninja 'fail' line evaluates its condition twice**
    (SourceBuild.NinjaRetry.Tests) — fold into one guarded block like the
    FAILONCE line below it.
14. *(DONE 2026-08-10 night: payload lives at
    `windows/diagnostics/verify-cuda-cache/cachetest.ps1` (lint scope),
    copied into the solve context and run as `RUN & C:\cachetest.ps1`.)*
    **`verify-cuda-cache.ps1`'s 21-statement concatenated RUN line.**
15. *(DONE 2026-08-10 night: `git mv verify-defender-exclusions.ps1
    sync-defender-exclusions.ps1`, all references updated — the name now
    says what it does.)*
    **`verify-defender-exclusions.ps1` naming**: it verified AND applied.

### P1 addenda from the full sweep

16. *(DONE 2026-08-10 night: guard v2 — CPU delta demoted to pre-filter,
    verdict is a timed `sccache --show-stats` client probe (15 s,
    Start-Process + `.Handle` quirk); an answering server resets to healthy
    idle, a hanging probe = kill on first confirmation.)*
    **Stall-guard trigger is a CPU proxy — replace with a timed sccache
    client probe.**
17. *(DONE 2026-08-10 night: marker truncated inside `$invokeNinja` before
    every invocation, ladder classifies on THIS attempt's kills only and
    prints lines as it consumes them; `Add-Content` is try/catch with a
    loud job-stream fallback on write failure. +1 regression test
    (fail-fail-succeed at full `-j` ×2). The former POISONING paragraph is
    RETRACTED: run 11 failed byte-identically on a FRESH mount — the run-10
    link failure was the sccache nvcc MISCOMPILE (see the CUDA-launcher-OFF
    block in build-onnx-from-source.ps1), not truncated cache objects. The
    mount-id bump to `sccache-winamd64-2` stays, harmlessly.)*
    **Marker-based retry classification is not attempt-scoped.**
18. *(DONE 2026-08-10 night, pragmatic form: gate-specific `-SkipRdna4Gate`
    in BOTH drivers (message points at `probe-build-copy.ps1 -Heavy` as the
    evidence to earn it); the full probe-as-verdict altitude change is
    deliberately NOT built — the probe costs minutes, the gate seconds, and
    the skip-switch covers the healthy-host-after-driver-fix case.)*
    **RDNA4 gate altitude**: regex-match should be the cheap trigger, the
    finalize probe the verdict (block only on a red probe); add a
    gate-specific `-SkipRdna4Gate` instead of the all-or-nothing
    `-SkipHostChecks` (which also disarms the disk gates); the day the
    driver interaction is fixed upstream, healthy RDNA4 hosts stay blocked
    until module surgery.
19. *(DONE 2026-08-10 night: the 006 stanza passes `-Fatal` to
    `Invoke-SourcePatchWithFallback` — a double miss throws at patch time
    instead of re-arming the sccache crash at re-enable time.)*
    **Patch-fallback last rung is soft**: when both the `.patch` AND the
    inline-regex anchor miss (next ORT bump), `Invoke-InlineRegexPatch`
    warns and returns `$false` piped to `Out-Null` — for patch 006 that
    silently re-arms the deterministic sccache crash ~4900 s in. Hard-fail
    the 006 rung (`-Require` or check the return).

### P2/P3 addenda

20. *(DONE 2026-08-10 night: `Start-SccacheStallGuard` returns `$null`
    without `Test-SccacheRemoteConfigured`, same gate as the launcher
    wiring.)*
    **Guard job spawns even when sccache has no remote configured** (baked
    into the toolchain image, so it exists on PATH in every container):
    gate `Start-SccacheStallGuard` on `Test-SccacheRemoteConfigured` like
    the launcher wiring does.
21. *(DONE 2026-08-10 night: detectors moved to
    `modules/WindowsLint.Common.psm1`; Invoke-Lint runs them inside its
    parse loop (one parse per file, `\archive\` excluded, violations fail
    the gate) over a now fully-recursive windows\ walk that also picked up
    `windows\upstream`; the test suite keeps the 6 positive controls.)*
    **AST sweep double-parses the tree** every gate cycle.
22. *(DONE 2026-08-10 W1)* **`verify-cuda-cache.ps1` exports a throwaway image** nobody consumes —
    drop `--output` (solve-only is enough for the hit/write assertions;
    contrast: the finalize probes NEED `type=image,unpack=true`).
23. *(DONE 2026-08-10 night: moved to `C:\sccache\logs\` in both media
    Dockerfiles; `Initialize-SourceBuildEnvironment` creates the dir before
    the server can spawn — sccache does not create missing parents.)*
    **`SCCACHE_ERROR_LOG` sits at the root of a GC-capped cache mount** —
    eviction under pressure can delete the postmortem exactly when needed;
    consider a subdirectory exempted by policy or copying the log out in
    the chain epilogue.
24. *(DONE 2026-08-10 night: prepended to all 40 remaining files, each
    matching its own EOL style.)*
    **`#Requires -Version 7.0` missing across `windows/scripts/tests/`.**
25. *(DONE 2026-08-10 W1)* **`test-rdna4-layer-lock.ps1` StrictMode fragility**: `$offTiny`/
    `$offHeavy` are only-safe-by-control-flow; initialize them up front so a
    future try/catch edit cannot turn the verdict line into a StrictMode
    error on the exact host being diagnosed.

### Second deep pass (build-definition & operations angles, 2026-08-10 evening)

The 8-finder review read almost only `.ps1`/`.psm1`; this pass covered the
Dockerfiles, resource economics, store hygiene and probe supply-chain.
Checked and deliberately NOT flagged: isolation-probe already parameterizes
its FROM; scrub coverage matches its documented tier map; `.dockerignore`
guards the context; the ENV/ARG mirrors are the documented deliberate ones.

26. *(DONE 2026-08-10 W1: ARG BASE in both probe Dockerfiles; probe-build-copy.ps1 pins it to versions.env WINDOWS_BASE_DIGEST via dependency-free parse on all three lanes, smoke-verified; the A/B script inherits the tag default until #5)* **Probe Dockerfiles float their base** (`FROM ...servercore:ltsc2025`
    without a digest) while the chain pins `WINDOWS_BASE_DIGEST` — when MS
    rolls the tag, the probe certifies a DIFFERENT base than the chain
    builds on, and pulls a fresh multi-GB image to do it. Fix: `ARG BASE`
    like Dockerfile.isolation-probe, defaulted by the probe script from
    versions.env's digest.
27. **Dockerfile.base carries a 1214-char single-line RUN** (the pwsh
    bootstrap blob) — unreviewable and undiffable. Move to a mounted script
    like the heavy lanes; BASE-TIER CLOSURE, so batch it with the next
    planned base rebuild, never alone.
28. **~60-70 % of the CPU is idle during the heaviest stage** (26-31 %
    total at ONNX `-j9`, memory-capped by a flat MemGBPerJob=4 that treats
    a 200 MB CXX TU like a 4 GB flash-attention TU). AGENTS.md priority 1
    calls idle cores "the standing wall-clock reserve": measure real
    per-TU-class peaks, then split into heavy/light ninja job pools or
    per-stage MemGBPerJob. Potentially the single largest wall-clock win
    left in the chain.
    *(MEASURED COMPLETE 2026-08-11: run-13 full window, 7821 samples @15 s
    (`run13-tu-memory-samples.csv`) covering toolchain build + the ENTIRE
    ONNX vertex incl. the early flash-attention region + the OpenCV
    attempt; corroborated by run-12's 1453-sample tail window. Peak
    per-process WorkingSet: cicc 998 MB / clang-cl 989 / cudafe++ 944 /
    ptxas 830 — NO process reaches 1 GB; peak concurrent fleet total
    5.5 GB across 21 processes at `-j9`. READY TO LAND: `-MemGBPerJob 2`
    at the build-onnx/build-opencv call sites → 19 jobs (peak assumption
    still ~2× measured; extrapolated fleet ≈ 11-12 GB against the 39 GB
    budget). DELIBERATELY NOT hot-landed mid-run-14: media-closure edit =
    one more ONNX rebuild, so bundle it with the NEXT closure window per
    the standing cache-tier rule.)*
29. *(DONE 2026-08-10 night: the tag-minting diagnostics now share the
    `diag-` prefix (`diag-probe-build-copy[-heavy]`, docker lane
    `local/test:diag-probe-build-copy`; the A/B mints nothing since the #5
    delegation, verify-cuda-cache nothing since #22). Cleanup one-liner:
    admin `nerdctl --namespace buildkit images | findstr diag-` → `rmi`.
    The pre-convention 2026-08-10 tags — incl. the old
    `probe-build-copy[-heavy]` names — stay on the pending-cleanup list.)*
    **Diagnostic image debris pins store layers.**
30. *(DONE 2026-08-10 night: `Limit-DiagnosticLogs` retention — driver keeps
    the newest 80 stage logs in `out\windows-build-logs`, diagnostics the
    newest 60 in `out\build-logs` via `Get-DiagnosticLogPath`. Console-log
    convention: the LAUNCHER names one timestamped file per driver
    invocation — never append across runs.)*
    **Build-log growth is unbounded.**
31. **Green stage images live ONLY in the local containerd store** until a
    manual `-PushRef` — a host loss (this host has form: repair-installs,
    driver surgery) costs every stage. Auto-push green stage tags (or at
    least export-cache) once a chain goes green; the driver params already
    exist, they are just never invoked by default.
32. *(DONE 2026-08-10 night — answered by reading the workflow: the Windows
    CI lane is GITHUB-HOSTED `windows-latest`, builds NO container images
    (scripts gate only, stated in windows-scripts.yml's header) and hosted
    VMs carry no AMD dGPU → **CI is immune to the RDNA4 hazard**; the
    gate/toggle workflow is local-host-only, which is where it lives.)*
    **Document the CI runner's GPU class vs the RDNA4 hazard.**

### Already fixed during the review session (2026-08-10, for the record)

The sweep also surfaced correctness bugs in same-day code; these were fixed
immediately rather than backlogged: probe zero-lane false-green (exit 0 with
no lane run), `repair-windows-componentstore.ps1` still using the retired
`type=local` probe shape, the classic lane (`build.ps1`) missing the RDNA4
gate, `Get-SccacheStatsText` not re-exported (would have thrown AFTER the
multi-hour ONNX build), `Dockerfile.heavy`'s trailing-backslash COPY dest
(Dockerfile escape char), the RDNA4 A/B swallowing lane logs and re-enable
failures, the `(TM)`-rename hole in the hazard regex, the opencv/001 patch
EOL flip, `SCCACHE_ERROR_LOG` parity for the merge builder, and a stale
module comment describing the abandoned launcher-opt-out design.
