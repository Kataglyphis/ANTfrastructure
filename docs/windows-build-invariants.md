<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows build invariants (do not regress)

Load-bearing fixes for the Windows lane. Preserve them or builds slow down,
ship broken, or start lying about their own results. **Every entry here was
found live** — the date in a heading's body is when it cost a build.

These are agent-behavioral rules: what you must not do when editing the
Windows chain. They are deliberately separate from the *reference* data
(component matrix, script tables, build sequences), which lives in
[`windows-builds.md`](windows-builds.md), and from the *symptom lookup*, which
lives in [`failure-modes.md`](failure-modes.md).

> **Editing one of these?** The rule and its evidence travel together. If you
> change a mechanism, update the entry in the same commit — a rule whose
> evidence no longer matches the code is worse than no rule.

## Contents

**Shell and PowerShell discipline**

- [pwsh 7 everywhere — no `powershell.exe`, no `cmd` SHELL](#pwsh-7-everywhere--no-powershellexe-no-cmd-shell)
- [Never cross a pwsh process boundary with an array parameter](#never-cross-a-pwsh-process-boundary-with-an-array-parameter)
- [Never put double quotes inside shell-form `RUN` lines](#never-put-double-quotes-inside-shell-form-run-lines)
- [`Import-Module -Force` only at entry-script top level](#import-module--force-only-at-entry-script-top-level)
- [Never splat a string array of `-Param`-shaped tokens](#never-splat-a-string-array-of--param-shaped-tokens)
- [Four more pwsh traps: bareword comma-attributes, switch-name collisions, glued parameter tokens, null env restores](#four-more-pwsh-traps-bareword-comma-attributes-switch-name-collisions-glued-parameter-tokens-null-env-restores)
- [Windows stage scripts must end with an explicit `exit 0`](#windows-stage-scripts-must-end-with-an-explicit-exit-0)
- [Production scripts run under `Set-StrictMode -Version Latest`](#production-scripts-run-under-set-strictmode--version-latest)

**Gates that must stay armed**

- [Every BK chain ends with a mandatory smoke gate](#every-bk-chain-ends-with-a-mandatory-smoke-gate)
- [Never rewrite upstream sources with a bare `string(REPLACE)`](#never-rewrite-upstream-sources-with-a-bare-stringreplace)
- [AVX-512/AMX flags never go in global CXX flags](#avx-512amx-flags-never-go-in-global-cxx-flags)
- [The mandatory GStreamer plugin set is a contract, never `auto`](#the-mandatory-gstreamer-plugin-set-is-a-contract-never-auto)
- [A missing stage artifact is a THROW, not a warning](#a-missing-stage-artifact-is-a-throw-not-a-warning)

**Diagnosing: probes and evidence**

- [When a probe says the product is broken, suspect the probe first](#when-a-probe-says-the-product-is-broken-suspect-the-probe-first)
- [Reproducing the ENVIRONMENT is not reproducing the FAILURE](#reproducing-the-environment-is-not-reproducing-the-failure)
- [A probe can destroy its own experiment](#a-probe-can-destroy-its-own-experiment)
- [Aggregate evidence has a shelf life](#aggregate-evidence-has-a-shelf-life)

**Logs**

- [A daemon's log is only as durable as its last flush](#a-daemons-log-is-only-as-durable-as-its-last-flush)
- [Never put a log inside a directory another tool prunes](#never-put-a-log-inside-a-directory-another-tool-prunes)
- [A build log written inside the build dir dies with the solve](#a-build-log-written-inside-the-build-dir-dies-with-the-solve)
- [Never swallow logs — display may truncate, persistence must not](#never-swallow-logs--display-may-truncate-persistence-must-not)

**Layers, scratch and image size**

- [Scratch must be scrubbed INSIDE the layer that created it](#scratch-must-be-scrubbed-inside-the-layer-that-created-it)
- [A committed layer can never be shrunk later](#a-committed-layer-can-never-be-shrunk-later)
- [Preserve committed line endings when editing a COPY'd `.psm1`/`.ps1`](#preserve-committed-line-endings-when-editing-a-copyd-psm1ps1)
- [Windows images have a hard 125-layer cap](#windows-images-have-a-hard-125-layer-cap)
- [`docker commit` inherits the container's `Cmd`](#docker-commit-inherits-the-containers-cmd)

**Lanes, isolation and CPU**

- [media-core builds via run+commit — never re-add `--isolation process`](#media-core-builds-via-runcommit--never-re-add---isolation-process)
- [Parallelism is memory-bounded, not CPU-bounded](#parallelism-is-memory-bounded-not-cpu-bounded)
- [`buildctl` builds (non-admin), `nerdctl` runs and inspects (admin)](#buildctl-builds-non-admin-nerdctl-runs-and-inspects-admin)
- [Never pass a command to `nerdctl run` of an image with an ENTRYPOINT](#never-pass-a-command-to-nerdctl-run-of-an-image-with-an-entrypoint)
- [`Invoke-BkStage -MaxAttempts` — the media merge stage passes 5](#invoke-bkstage--maxattempts--the-media-merge-stage-passes-5)
- [The classic lane's fallback needs a RUNNING dockerd](#the-classic-lanes-fallback-needs-a-running-dockerd)
- [Two BK-driver guards to know before debugging around them](#two-bk-driver-guards-to-know-before-debugging-around-them)

**Container networking (CNI)**

- [The CNI nat config must exist as BOTH `.conf` AND `.conflist`](#the-cni-nat-config-must-exist-as-both-conf-and-conflist)
- [The CNI `.conf` is DERIVED from the `.conflist`, not hand-edited](#the-cni-conf-is-derived-from-the-conflist-not-hand-edited)

**Build inputs and toolchain**

- [TVM builds its OWN minimal LLVM — do not "simplify" it away](#tvm-builds-its-own-minimal-llvm--do-not-simplify-it-away)
- [freedesktop/videolan GitLab downloads must go through `Invoke-WrapDownload`](#freedesktopvideolan-gitlab-downloads-must-go-through-invoke-wrapdownload)
- [graphene needs `-Dgraphene:sse2=false` plus the meson.build patch](#graphene-needs--dgraphenesse2false-plus-the-mesonbuild-patch)
- [In `RUN --mount=...,from=<stage>` the SOURCE path is Unix-style](#in-run---mountfromstage-the-source-path-is-unix-style)
- [A whole-directory `modules` mount puts EVERY module in the cache key](#a-whole-directory-modules-mount-puts-every-module-in-the-cache-key)
- [The "unreferenced" `windows/scripts` modules are external-consumer API](#the-unreferenced-windowsscripts-modules-are-external-consumer-api)
- [Rust: rustup WITH a default toolchain is the sole provider](#rust-rustup-with-a-default-toolchain-is-the-sole-provider)
- [`versions.env` is the single source of truth](#versionsenv-is-the-single-source-of-truth)
- [CMake cross configures must carry the ASM language target too](#cmake-cross-configures-must-carry-the-asm-language-target-too)
- [vcpkg ships zlib ONLY](#vcpkg-ships-zlib-only)
- [Python bindings plumbing is load-bearing](#python-bindings-plumbing-is-load-bearing)


---

## Shell and PowerShell discipline

### pwsh 7 everywhere — no `powershell.exe`, no `cmd` SHELL

**pwsh (PowerShell 7) everywhere — owner policy 2026-08-04.** Every SHELL
directive, every in-container exec, every script runs pwsh 7. The ONLY
sanctioned Windows PowerShell 5.1 context is the single bootstrap RUN in
`Dockerfile.base` that installs pwsh itself (nothing else may run in that
window). Never add `powershell`/`powershell.exe` invocations or `cmd`
SHELL directives; `cmd.exe /c` may appear only inside
`Invoke-ShieldedNative` and the documented bespoke sites.

### Never cross a pwsh process boundary with an array parameter

**Never cross a pwsh process boundary with an array parameter.** `& pwsh
-File script.ps1 -Param 'a','b'` delivers ONE literal string INCLUDING the
quote characters, not a two-element array. Cost (2026-08-18): the deadlock
repro's `-BuildArg` pair reached buildctl as one mangled undeclared ARG
name, buildctl silently discarded it, and an 88-minute repro measured
nothing while reporting success. Invoke repo scripts DIRECTLY (`&
'windows\build-buildkit.ps1' …`) when already in pwsh 7;
`build-buildkit.ps1` now throws on non-identifier `-BuildArg` keys so the
flattened form fails loudly instead of vanishing downstream.

### Never put double quotes inside shell-form `RUN` lines

**Never put DOUBLE QUOTES inside shell-form RUN lines in the Windows
Dockerfiles.** The dockerfile frontend strips embedded `"` from the command
string before it reaches the pwsh SHELL (three incidents on 2026-08-04:
`"$env:TEMP\*"` became bare `$env:TEMP\*` → ParserError; the pwsh-written
Directory.Build.props lost its XML attribute quotes → MSB4024). Use single
quotes / `''`-doubling / string concatenation instead; XML attributes may
legally use single quotes.

### `Import-Module -Force` only at entry-script top level

**`Import-Module X -Force` is safe ONLY at ENTRY-script top level — never in
a module, and never in a script that gets `&`-invoked FROM module scope.**
A forced re-import from module context unloads the caller's top-level copy
and rebinds it into the module's private session state (probed 2026-08-05:
`load-versions.ps1`'s `Import-Module Shared -Force`, run via
Import-CanonicalVersions, made `Resolve-DirectoryPath` CommandNotFound at
gstreamer top level and killed the merge-warm solve). Nested imports use the
guarded form `if (-not (Get-Module -Name 'X')) { Import-Module $path }`.
Regression pin: import Shared→Installer→SourceBuild.Common, run
Import-CanonicalVersions, then `Get-Command Resolve-DirectoryPath` must still
resolve.
**The "REPO-COMPLETE since 2026-08-05" claim that stood here was WRONG, and
it cost a 53-minute compile on 2026-08-21.** Every leaf builder
(`build-onnx-from-source.ps1`, `-opencv-`, `-ffmpeg-`, `-gstreamer-`, `-tvm-`,
`-litert-`, `-iree-`, …) still opened with `Import-Module $modulePath -Force`
— and those are precisely "scripts `&`-invoked from module scope": the chain
runs them in-process via `& (Join-Path $ScriptDir $stage.Script)`. ONNX built
green for 53 min; the chain tail then died on `The term
'Stop-LingeringBuildProcess' is not recognized`, because `-Force` had removed
the module instance `Invoke-SourceBuildChain` was still running inside.
**Read the asymmetry in the log — it is the fingerprint of this bug:** the
EXPORTED call one line earlier (`Write-SccacheStats`) succeeded, because
exported names resolve through the global command table, while the UNEXPORTED
helper existed only in the destroyed scope. A prose rule with no gate is a
suggestion: `windows/scripts/tests/Modules.ForceImportScope.Tests.ps1` now
discovers the leaves from the `$stages` tables and fails on any `-Force`
among them (with a rot guard, so it cannot pass vacuously).

### Never splat a string array of `-Param`-shaped tokens

**Never splat a string ARRAY containing `-Param`-shaped tokens onto a
PowerShell script/function — array splatting binds strictly BY POSITION.**
`& $script @('-ResumeFrom','OpenCV')` delivers `-ResumeFrom` as the VALUE of
parameter 1 (silently wrong without CmdletBinding, "positional parameter
cannot be found" with it) — this killed the opencv warm solve on 2026-08-04
and reproduces identically on host pwsh 7.6. Route such argv through a child
process instead (`& pwsh -NoProfile -File $script @argv` — native argv is
re-parsed into named parameters; `bk-warm.ps1` is the reference), or splat a
HASHTABLE. Splatting arrays onto native executables stays fine.

### Four more pwsh traps: bareword comma-attributes, switch-name collisions, glued parameter tokens, null env restores

**Four more pwsh traps — (a) and (b) found live 2026-08-10 in
`probe-build-copy.ps1`, (c) and (d) on 2026-08-25 in the arm64 target-cpython
and LiteRT stages (regression pins: `windows/scripts/tests/Native.ArgQuoting.Tests.ps1`
for (a)–(c), which are AST traps in `Invoke-Lint.ps1`, and
`SourceBuild.HostArchLibEnv.Tests.ps1` for (d)):**
(c) A parameter token glued to its argument PARSES: `Get-PeFileMachine
-Path$staged.FullName` is a parameter literally NAMED `Path$staged` (the
`.FullName` becomes a positional argument) and dies at runtime with "A
parameter cannot be found that matches parameter name 'Path$staged'";
`-Path(Join-Path ...)` binds the paren expression positionally, right only by
accident. Four such calls survived a refactor, the parse gate and 662 tests and
surfaced 90 s into the arm64 regression. Native tools are exempt — for
clang-cl/nasm the glued token IS the syntax (`-Fotiny.o`, `-I<dir>`) — the
detector inspects Verb-Noun commands with an approved verb plus `Assert-*`.
(d) **Restoring a captured `$null` with `[Environment]::SetEnvironmentVariable`
does not unset the variable.** PowerShell binds `$null` to the `string`
parameter as `''`, and pwsh 7.6 then leaves `NAME=` DEFINED-EMPTY in the
process block (`Test-Path env:NAME` → True, and every native child inherits
it as *set*). Measured 2026-08-25, arm64 runs 16/17: the LiteRT stage never
enters VsDevCmd, so `LIB` is unset there and lld-link auto-detects the MSVC/SDK
directories — until the host-flatc pass "restored" `LIB=` and the very next
target try-compile died with `could not open 'kernel32.lib'` (IREE/TVM restore
a real value and never noticed). Save-and-restore code must branch:
`if ($null -eq $saved) { Remove-Item Env:NAME } else { SetEnvironmentVariable }`
(`[NullString]::Value` also works); pin:
`windows/scripts/tests/SourceBuild.HostArchLibEnv.Tests.ps1`.
(a) a BAREWORD comma-attribute native argument
(`buildctl --output type=local,dest=$outDir`) parses as an ArrayLiteral and
the exe receives the VERBATIM SOURCE TEXT — no variable expansion, no comma
split (buildctl exported into a directory literally named `$outDir`).
Double-quote the whole attribute string (`--output "type=image,name=$tag"`).
(b) Variable names are case-insensitive, so a local
`$docker = "...\docker.exe"` in a script declaring `[switch]$Docker` assigns
to the switch-typed PARAMETER variable and throws `Cannot convert ... String
to ... SwitchParameter` at runtime — the probe's docker lane had never
executed. Never reuse a switch parameter's name for a local variable.

### Windows stage scripts must end with an explicit `exit 0`

**Windows stage scripts must end with an explicit `exit 0`.** `pwsh -File` propagates the LAST native command's exit code: a fully green LiteRT-LM build was declared failed because the final cleanup `rmdir` exited 145 (`ERROR_DIR_NOT_EMPTY`). Real failures throw (EAP=Stop + gates); reaching the end IS success — say so explicitly.

### Production scripts run under `Set-StrictMode -Version Latest`

**Every entry script gets `Set-StrictMode -Version Latest`, and adding it is a
BUG HUNT, not a formality (2026-08-31).** Adding it to seven scripts surfaced
four latent defects — three of them on NORMAL SUCCESS PATHS. Two traps account
for all four, and both are about `.Count`/`.Sum` on a pipeline result:
**(a) `@()`-wrap a pipeline result before touching `.Count`** — on pwsh 7.6.5 a
one-element result is the scalar (`.Count` throws) and an empty result is
`AutomationNull` (`.Count` throws too), so the working and the empty case both
fail while only the two-or-more case passes. `normalize-tensorrt-tree.ps1`'s
`$dllDirs` hit exactly this on its success path (TensorRT 10+/11 keep the DLLs
in `bin` only, so precisely one dir survives the filter), and
`stage-cuda-runtime.ps1`'s `$roots` would have re-broken the arm64/CPU merge
lane that the 2026-08-23 degrade-cleanly fix unblocked.
**(b) `Measure-Object -Property` emits NOTHING for empty input**, so an inline
`(… | Measure-Object Length -Sum).Sum` throws on an empty directory — bind the
result first (`clean-sccache-mount.ps1`, empty cache dir).
**StrictMode is INHERITED across `&`-invocation, so a script can already be
under it without saying so.** `debug-litertlm-link.ps1`'s
`(Get-Command 'llvm-nm.exe' -EA SilentlyContinue).Source` was a LIVE bug for
that reason: its only caller, `build-litert-lm-from-source.ps1`, sets
StrictMode, and a missing `llvm-nm` — the case the code was written to
handle — threw instead. Deliberately EXCLUDED: modules and dot-sourced
scripts (`WindowsFlutter.Common`, `WindowsContainerLog.Common`,
`Initialize-CiEnvironment.ps1`, `litert-lm-export-bridge.ps1`). A module does
not inherit its caller's strict mode, and a dot-sourced script leaks it into
every caller — in-repo and external — so those are behaviour changes, not
hygiene.

---

## Gates that must stay armed

### Every BK chain ends with a mandatory smoke gate

**Every BK chain ends with a MANDATORY smoke gate — do not route around it.**
`build-buildkit.ps1` solves `windows/Dockerfile.smoke-gate` against the
finished image after `final`, and a failure fails the chain (backlog #44).
It is the only gate since the classic driver's deletion on 2026-08-31
(mechanism and gating history: `docs/windows-builds.md` § Smoke Testing).
Three rules when touching it: it
must run **through `entrypoint.cmd`** (a bare `RUN` bypasses ENTRYPOINT and
loses VsDevCmd + the ASAN runtime dir);
it **bind-mounts** the current script rather than the image's baked copy, so a
smoke-test fix is re-verifiable without an image rebuild; and it enforces
**coverage floors** (`-SmokeMinPassed`/`-SmokeMaxSkipped`, exit 3), because a
run that asserted nothing used to print "All smoke tests passed!" and exit 0.
`-SkipSmokeGate` is for chain iteration only.
**On `-TargetArch arm64` the gate is arch-SPLIT (2026-08-24).**
`smoke-test-container.ps1` mostly verifies by EXECUTING the staged binaries,
and Windows x64 has no ARM64 emulation — so the payload sections keep floor 0
on arm64 and the driver reports them `NOT APPLICABLE`, never "passed", while
the host-toolchain sections (1-6, 14-16, and 19 arch-filtered:
`TORCH_APP_DIR` dropped) RUN with their OWN floor column, and the healthcheck
likewise runs its host-tool checks, skipping only payload execution.
Sections 14/15 compile FOR the target and assert the produced PE machine
instead of running (ASAN skipped there — LLVM's win-x64 package ships no
aarch64-windows ASAN runtime). The arm64 floor values and the measured green
runs live in `docs/windows-builds.md` § Smoke Testing. **Never lower the
amd64 floors** toward the arm64 column: a reduced `-SmokeMinPassed` would
leave a number a later amd64 change could quietly be measured against, which
is exactly how this gate became decorative once before. The cross lane's
execution-side verification is `verify-target-arch.ps1` (PE machine type over
`C:\runtime` AND the fanned-in site-packages, `.lib` archives included,
inside the merge stage, floor raised to 100 there) plus the fact that every
artifact linked at all — neither proves the code RUNS, and nothing available
on this host can.

### Never rewrite upstream sources with a bare `string(REPLACE)`

**Never rewrite upstream sources with a bare `string(REPLACE)`.** Use
`patch_replace_required` / `patch_regex_replace_required` from
`patches/litert-lm/patch-assert.cmake`, which `FATAL_ERROR`s when the pattern
matched nothing (backlog #56). The old pattern printed "Patched …"
unconditionally, so an upstream reformat silently restored the defect the
patch existed to fix — for sentencepiece's duplicate `ABSL_FLAG(minloglevel)`
that means a link-clean `litert_lm_main.exe` that aborts on every run.
`Patches.CmakeNoOpGuards.Tests.ps1` fails any unguarded replace; a genuine
non-source replace opts out with a `patch-assert-exempt` marker AND a reason.

### AVX-512/AMX flags never go in global CXX flags

**AVX-512/AMX flags NEVER go in global CXX flags (final polarity, settled 2026-08-03).** Globally, clang may emit AVX-512 anywhere — the in-tree protoc AND `onnxruntime.dll`'s static initializers both crashed with `STATUS_ILLEGAL_INSTRUCTION` at run/load time on the AVX2-only build host (the import assert catches this). But entirely without the flags, MLAS's arch TUs fail to COMPILE (clang-cl gates intrinsics behind target features; MSVC doesn't). The settled design: `build-onnx-from-source.ps1` appends `Get-WindowsTargetKernelSimdFlags -Arch` per-TU (the name this line carried until 2026-08-24, `Get-WindowsX86Avx512Flags`, survives only as a zero-caller compat shim) to exactly the MLAS arch `FLAGS =` lines in build.ninja post-configure (runtime-dispatched kernels — the only code allowed to assume the features) and **asserts the tagged count against `Get-MlasKernelTuMinimum` — a THROW, not a log**. Two field lessons shape that floor: on aarch64 the x86 pattern matches nothing and a no-match patch *succeeds* (why the pattern is arch-parameterized), and on 2026-08-24 the amd64 lane broke with the floor PRESENT but too low — ORT v1.29.0 added six AVX-512 TUs outside `intrinsics/`, the stale pattern still matched 5 ≥ floor 4, and five kernels failed to compile. Floor rule: **it must be high enough that the previous broken state trips it** (now 8 against 11 matched; the stale pattern's 5 fails loudly). When bumping `ONNXRUNTIME_VERSION`, re-measure BOTH arches' patterns against the new MLAS tree — the 1.29 bump re-measured only aarch64 and amd64 paid for it. Don't "simplify" in either direction.

### The mandatory GStreamer plugin set is a contract, never `auto`

**The mandatory GStreamer plugin set is a CONTRACT, never `auto` (2026-08-07).** `Get-RequiredGstPlugin` (`WindowsGstPlugins.Common.psm1`) is the SINGLE definition of which integrations must exist — `libav`, `opencv`, `onnx`, `tflite`, the same four on BOTH lanes — enforced at four points that must never disagree: the pkg-config pre-flight in `build-gstreamer-from-source.ps1`, meson features set to `enabled` (meson's `auto` means **skip silently** — never use it; tflite's flag is presence-driven `-Dgst-plugins-bad:tflite=enabled`), a post-install gate that throws, and smoke-test assertions that fail. Any arch filtering lives in the CONTRACT, never in a caller — teaching only one enforcement point about an arch would recreate the 2026-07-11 regression. `tensorfilter` is an NNStreamer element, not a GStreamer plugin — never add it to the set. Deliberate exception: `-SkipPluginGate`, which marks the image unshippable. The root causes, per-plugin mechanisms and the hardened export-marker gate: `docs/windows-builds.md` § Mandatory GStreamer plugins (the contract); the cross-lane arch conditionals: `docs/windows-cross-builds.md` § The merge stage on arm64.

### A missing stage artifact is a THROW, not a warning

**A missing stage artifact is a THROW, not a warning.** media-litert once "completed" without `litert_lm_main.exe` (configure had failed; the script only warned) and the degraded image would have shipped through merge/final. Every stage's terminal artifact check must throw (debug escape hatches env-gated, e.g. `LITERTLM_KEEP_BUILD_TREE`).

---

## Diagnosing: probes and evidence

### When a probe says the product is broken, suspect the probe first

**When a probe says the product is broken, suspect the probe first — and
always run a known-good control.** Three probes lied on 2026-08-14 before one
told the truth, each looking exactly like a product defect:
(1) a hand-rolled `[DllImport("kernel32")] LoadLibraryW(string)` marshals
`string` as **ANSI** by default, so a UTF-16 API answered "module not found"
(126) for all 14 TensorRT DLLs — the repo's `Assert-DllLoads`
(`WindowsSmokeTest.Common.psm1:233`) has always declared
`CharSet=CharSet.Unicode`; **use the existing helper, don't re-declare
P/Invoke**. (2) A hand-written probe Dockerfile without `# escape=\`` let the
default `\` escape eat the `s` in `target=C:\sccache`, so a cache mount
silently did not exist. (3) `/Fo:C:\x.obj` (colon) makes sccache build
`C:\:C:\x.obj` and fail with a misleading "failed to zip up compiler outputs";
MSVC syntax is `/Fo<path>`. In each case the control is what exposed it — a
`VCRUNTIME140.dll` that obviously loads in an MSVC-built image, a mount that
should exist. **A probe with no control cannot distinguish "broken product"
from "broken probe".**

### Reproducing the ENVIRONMENT is not reproducing the FAILURE

**A probe that reproduces the ENVIRONMENT does not necessarily reproduce the
FAILURE — and until it does, it can clear nothing.** `probe-sccache-write.ps1`
ran the real image, the real cache mount ids and the real ENV, and for two days
every configuration it pronounced clean then failed in the next 90-minute
build: a repaired cache tree, a fresh `SCCACHE_DIR`, the multilevel chain,
16-way concurrency, 239-character paths. It was not lying — its writes really
did succeed. It was simply too SMALL: the defect needs ~250 objects written
into a directory a PREVIOUS container populated, and every section until then
wrote a single object. Two rules from that: (a) treat a green probe as a hypothesis to test
in a real build, never as clearance — only per-stage `--show-stats` numbers
from a build settled anything here; (b) when a probe and the product disagree,
the next move is to make the probe BIGGER along the dimension you have not
varied, not to trust it. See backlog #99 for the full list of dead hypotheses.

### A probe can destroy its own experiment

**A probe can destroy its own experiment — read the setup output, not just the
verdict.** The same script sweeps anything in the cache root that is not a hex
bucket off the mount as debris; that quietly deleted the inheritance fixture a
later section depended on, and the run reported "0 files inherited" — which
reads as "the cache mount lost 250 objects", i.e. exactly backwards.
The directory listing printed at the top of the log is what exposed it. Keep
fixtures on an explicit allow-list (`$probeOwned`), and when a probe's result
is surprising, check what the probe DID to the system before believing what it
says about the system.

### Aggregate evidence has a shelf life

**Aggregate evidence has a SHELF LIFE — check the newest sample's timestamp
against the last fix.** The log forensics concluded "sccache has never
worked" from 0 hits / 189,861 failed writes across 94 stat blocks. Every one
of those samples predated the dufs SYSTEM-service migration on the same day,
and no run since had exercised sccache — a direct probe showed
miss → store → HIT with 0 write errors. Confident conclusions about a state
that no longer exists are the failure mode of corpus-wide aggregation; date
the newest sample before trusting the aggregate.

---

## Logs

### A daemon's log is only as durable as its last flush

**A daemon's log is only as durable as its last flush — stop the server before
the RUN ends.** `SCCACHE_ERROR_LOG` is written by the sccache SERVER, and
`SCCACHE_IDLE_TIMEOUT=0` means it never exits on its own, so BuildKit tears
the RUN's process tree down with the log still buffered and nothing reaches
the mount. `Complete-SourceBuildChain` now calls `sccache --stop-server` as
the chain epilogue (after every `Write-SccacheStatsToStderr`, which needs a
live server), which also flushes the async webdav write-through tail.
`Invoke-SourceBuildChain`'s prologue is the other half: it stops the server,
**truncates the error log**, and starts the server explicitly from `C:\`. The
truncation is not tidiness — the log lives on a SHARED mount and only appends,
so the epilogue's dump was replaying a PREVIOUS run's failures verbatim
(50,928 lines / 12,413 error lines) and cost a full false alarm before anyone
compared its timestamps to the run's start time. Dump `-Last N`, never
`-First N`, on any log that accumulates.
**Diagnostic value of this one:** the path, the level and the mount were all
correct for days while three separate hypotheses were chased — LRU pruning,
wrong location, unset `SCCACHE_LOG` — because a hand probe that waits a few
seconds with the server alive ALWAYS saw content, and a real build never did.
When a log is empty only after real runs, suspect lifetime before correctness.

### Never put a log inside a directory another tool prunes

**Never put a log inside a directory some OTHER tool owns and prunes.**
`SCCACHE_ERROR_LOG` was set to `C:\sccache\logs\sccache-error.log` — inside
`SCCACHE_DIR`, the directory sccache itself manages by LRU. The dir-creation
code runs, the cache mount persists (236 MB of content survived), and the
`logs\` directory is gone anyway: sccache pruned it. **That is why sccache's
own error log was unobtainable through an entire multi-day investigation** —
it was deleted by design, not lost by accident, and its absence is what left
the genai write failures undiagnosable (backlog #90). It now lives on its
**own** cache mount — `C:\sccache-logs` (`id=sccache-logs-winamd64`), mounted
next to the sccache mount on every compiling RUN — and is listed in
`windows/buildkitd.toml`'s tier-0 inventory, which must stay in step with that
budget. Sibling rule to the one below: a log must live where nothing else has
a delete policy over it.

### A build log written inside the build dir dies with the solve

**A build log written inside the build dir DIES WITH THE SOLVE — always use
`Get-PersistentBuildLogPath`.** When a vertex fails, BuildKit discards the
container filesystem, so a log at `$buildDir\x-build.log` is gone exactly
when it is needed and the only diagnosis left is the 50-line tail
`Invoke-NinjaBuildWithRetry` prints. The helper
(`WindowsSourceBuild.Common.psm1`) therefore puts logs on the persistent
**`C:\sccache-logs`** mount (derived from `SCCACHE_ERROR_LOG`'s parent, so the
two cannot drift apart) with one `.prev` generation, falling back to the build
dir only when no mount exists. **Never `$SCCACHE_DIR\logs`** — it wrote build
logs straight into sccache's own LRU-managed cache ROOT, which is the same
mistake #90 had already fixed for the error log; corrected 2026-08-16. Pass the result as `-LogFile`; never hand-roll the path, and never
omit `-LogFile` (build-onnx-genai did, and produced no ninja log at all).
This lived as ONE inline block in build-onnx for months while
opencv/iree/tvm/litert silently lost their logs — hence a shared helper
(backlog #43). Corollary of the owner's standing "never swallow logs" rule.

### Never swallow logs — display may truncate, persistence must not

**NEVER swallow logs — display may truncate, persistence must not (owner
directive 2026-08-10).** Every tool that shows `-Last N` lines Tee's the
FULL stream to `out\build-logs\` first and prints the path; sccache's
server error log persists on its OWN cache mount
(`SCCACHE_ERROR_LOG=C:\sccache-logs\sccache-error.log` in
Dockerfile.media-builder — NOT inside `SCCACHE_DIR`, see #90 — the 2026-08-10 nvcc-decomposition postmortem had
only client-side 10054s because the server died with its logs); build
stats go to STDERR (survives the step-log clip); and
`BUILDKIT_STEP_LOG_MAX_SIZE=-1`/`MAX_SPEED=-1` on the buildkitd service is
a REQUIRED host setting — a Stevedore reinstall/repair wipes the service
env silently (found empty 2026-08-10; that clip hid guard verdicts and
stats for three runs). Verify with `setup-new-host.ps1 -ReportOnly`;
re-apply + `Restart-Service buildkitd` only between builds.

---

## Layers, scratch and image size

### Scratch must be scrubbed INSIDE the layer that created it

**Scratch must be scrubbed INSIDE the layer that created it — image layers
are additive.** Deleting package-manager scratch (NuGet restore, pip cache,
`%TEMP%`, INetCache) from a LATER layer only writes a whiteout; the bytes
still ship. Until 2026-08-07 only the last media-core partition scrubbed, so
the onnx/opencv/ffmpeg/litert/tvm/gstreamer layers each carried their own
forever. Every chain wrapper now takes `-ScrubAfter` and every heavy RUN in
the BK lane passes it; the shared epilogue is `Complete-SourceBuildChain`.
Safe because `Clear-BuildScratch` targets `$env:TEMP` (the container profile
temp) — `setup-vs.ps1` repoints `$env:TEMP` to `C:\temp` but only inside its
own process in the base layer, so `C:\temp\cpython` and the mounted
script/patch trees are never touched. **Check that before widening it
further**: a scrub of `C:\temp` would delete the CPython tree the merge stage
fans in.

### A committed layer can never be shrunk later

**Windows images have a HARD 125-layer cap — it binds any image LOADED INTO DOCKER, whichever builder produced it.** The final stage died with `max depth exceeded` on 2026-08-03 because the merge Dockerfile carried ~28 separate `ENV` lines, one layer apiece, under the since-deleted classic builder. BuildKit keeps metadata in the image config, so a BK solve spends layers only on `RUN`/`COPY`/`ADD` — but `-FinalTar` hands the result to `docker load`, which enforces the ceiling again. Rule: in every windows Dockerfile, consolidate ENV/metadata into single instructions (see `Dockerfile.media-merge-builder`'s one big ENV, layers 114→86). When adding stages/instructions, check headroom: `docker inspect <tag> --format '{{len .RootFS.Layers}}'` chain-wide; the final image currently sits at **~75 layers** (settled 2026-08-28 by counting the inherited chain's RUN+COPY+ADD+ENV instructions: base 16 + nvidia 3 + toolchain 4 + media-merge 15 + torch 3 + final 2 = 43, plus 20 ENV layers and ~12 from the servercore base = ~75). The earlier "~108/125" figure was the pre-ENV-consolidation count — the merge-builder's 28 ENV lines → 5 blocks alone removed ~23 layers.

### Preserve committed line endings when editing a COPY'd `.psm1`/`.ps1`

**Preserve committed line endings when editing a COPY'd `.psm1`/`.ps1`.** Media modules are LF, some build scripts CRLF; `core.autocrlf=true` plus some editors can flip a whole file, busting the media layer cache. `.gitattributes` pins these `-text`; after editing, confirm `git diff` shows only your change, not a whole-file EOL flip.

### Windows images have a hard 125-layer cap

**CMake cross configures must carry the ASM language target too (2026-08-24).** `Get-CMakeCrossArgs` (`WindowsTargetArch.Common.psm1`) sets `CMAKE_ASM_COMPILER_TARGET`/`CMAKE_ASM_FLAGS_INIT` alongside the C/CXX pair, and it OWNS them — never hand a project ad-hoc ASM cross flags. Before it did, any project enabling the ASM language assembled with clang's X64 default target — signature: `brackets expression not supported on this target` on aarch64 `.S` sources — and an aarch64 `-march` handed to that x86-targeted driver was misread as a CPU name (`unknown target CPU 'armv8.2-a+fp16'`), which sent the first diagnosis chasing a nonexistent driver gap. amd64 is untouched: the cross args stay empty there.

### `docker commit` inherits the container's `Cmd`

> **HISTORICAL since 2026-08-31** — no run+commit site remains in the repo
> (`build.ps1` and `Invoke-RunCommitStage` are deleted). Kept because nothing
> gates this: a re-introduced `docker commit` would repeat it silently.

**`docker commit` inherits the container's `Cmd` — always commit with `--change 'CMD ["pwsh"]'` (classic lane, fixed 2026-08-07).** The run+commit stages launched the container with a build-script argv, and `commit` captured it as the image's `CMD`: `local/kataglyphis:windows-media` and `windows-torch` shipped a `CMD` that RE-RUNS the GStreamer build, so `docker run -it local/kataglyphis:windows-media` starts recompiling over `C:\runtime` instead of opening a shell. The FINAL image was never affected (a Dockerfile `ENTRYPOINT` resets an inherited `CMD`), which is why it hid for months. Any new run+commit site must carry the same `--change`.

---

## Lanes, isolation and CPU

### media-core builds via run+commit — never re-add `--isolation process`

> **HISTORICAL since 2026-08-31** — `Invoke-RunCommitStage` was deleted with
> `build.ps1`; media-core is a plain BK solve at full CPU count. The
> `docker build` finding below is still true of this host, and the re-test
> pointer is still a valid hand run.

**media-core built via run+commit for CPU parallelism — never re-add `--isolation process`.** `docker build` is 2-CPU-capped here and process isolation **cannot commit layers** (`hcsshim::ActivateLayer 0x20`, reproduced even for a 100 MB dummy). media-core therefore ran as `docker run --isolation hyperv --cpu-count $MediaCoreCpus` + `docker commit` (`Invoke-RunCommitStage`) — the only way to get >2 CPUs *and* a committable image. Regression symptom of the era: `-j2` in `out\windows-build-logs\media-core.log`, or `ActivateLayer` on any commit. Full rationale: `docs/windows-build-lanes.md` § Build isolation and CPU parallelism. **Before assuming this is still needed after a Docker/Windows/base-image upgrade, re-check with `windows/scripts/diagnostics/test-process-isolation-commit.ps1`** — if it reports `BUG GONE`, process isolation for `docker build` is usable again and the workaround can be retired (see [`windows-build-lanes.md`](windows-build-lanes.md) § Re-testing process isolation on new versions).

### Parallelism is memory-bounded, not CPU-bounded

**Parallelism is memory-bounded, not CPU-bounded — and the defaults ARE the max.** `Get-BuildJobCount = min(ProcessorCount, MEMORY_LIMIT_GB / MemGBPerJob)`; every BK RUN is process-isolated and sees all host logical processors (32 here). ONNX is tuned to ~4 GB/job (its CUDA/AVX-512 TUs are the RAM-heaviest; the `-j2` incremental retry absorbs the occasional OOM) → ~`-j10` at the auto-detected `-MediaMemoryGb 39` (`61 GB usable − 22 GB host reserve`). **Do not "optimize" by raising the memory cap or cutting `-HostReserveGb`**: the verified maximum envelope for this host (32 CPUs / 39 GB; media-core bottomed the host at 0.2 GB free and survived; 53 GB deadlocked it) is documented in `docs/windows-build-resources.md` § Maximum resource envelope — average CPU of ~35–45 % during compiles is the expected memory-bound signature, not a tuning failure. **You cannot reach `-j32` on ONNX**: 32 heavy TUs need ~128+ GB — RAM per job, not core count, is the ceiling; the real speed levers are more physical RAM and the sccache WebDAV remote. **The local L0 disk tier is DISABLED BY DEFAULT since 2026-08-16 — and the fault is BuildKit, not sccache.** A BuildKit cache mount on Windows loses writes once its directory holds objects an EARLIER RUN wrote: 158 of 250 failed on the mount vs 0 of 250 into a plain container directory, same program, same moment; a FRESH directory on the same mount takes all 250. That is why opencv/genai (which inherit onnx's cache dir) failed ~100 % of writes while onnx, filling its own, failed 1.9 %. `SCCACHE_MULTILEVEL_CHAIN` is an ARG defaulting to `""` in BOTH media Dockerfiles; restore `disk,webdav` only after re-verifying against a newer buildkit (recipe + full measurement in `docs/windows-builds.md` #99). Do not "fix" this in sccache.

### `buildctl` builds (non-admin), `nerdctl` runs and inspects (admin)

**BOTH lanes are supported: `buildctl` (NON-ADMIN) builds the chain, `nerdctl`
(ADMIN, always) runs/inspects/administers — and can build too.** Verified
2026-08-07: `nerdctl build` with `BUILDKIT_HOST=npipe:////./pipe/buildkitd`
produced and stored an image; `nerdctl run --network nat` gets a routable IP.
**The admin requirement is upstream, not a misconfiguration** — nerdctl opens
`\\.\pipe\containerd-containerd` for EVERY subcommand (even
`build --output type=tar`), and containerd has no `--group` equivalent to
buildkitd's `--group docker-users`; checked against its full flag set and
default config, `--address` only moves the pipe. Do NOT attempt pipe-ACL
hacks (recreated on every restart; containerd access is machine-admin) and do
NOT re-litigate this — the legitimate route is an upstream containerd feature
request. The chain keeps using `buildctl` deliberately: `nerdctl build` is a
wrapper around the same buildkitd, does not expose the load-bearing
`--opt image-resolve-mode=local`, and would force every unattended build to
run elevated. Always pass `--namespace buildkit` (the `bk-*` images live
there). Recipes + traps: `docs/windows-build-lanes.md` § nerdctl lane.

### Never pass a command to `nerdctl run` of an image with an ENTRYPOINT

**Never pass a command to a nerdctl `run` of an image that has an
`ENTRYPOINT`** — it is appended as entrypoint ARGUMENTS, not substituted. On
`bk-winamd64` that exits `255` instantly and leaves a container whose
`rm -f` then BLOCKS for up to 45 minutes, because the patched shim waits for
a teardown instead of force-terminating (right for builds, painful
interactively). Use no command (the final image's `entrypoint.cmd` starts
pwsh itself) or `--entrypoint`. Zombie recovery, safe only when the container
did no real filesystem work:
`Get-Process containerd-shim-runhcs-v1,CExecSvc | Stop-Process -Force` then
`rm -f` again. Exit `3221225786` = `0xC000013A` = the container was Ctrl+C'd.

### `Invoke-BkStage -MaxAttempts` — the media merge stage passes 5

**`Invoke-BkStage -MaxAttempts` defaults to 3; the media MERGE stage passes
5.** It fans in three branch images, so it does far more mount work than any
other stage and flakes proportionally — 2026-08-06 it burned its whole
3-attempt budget (two `failed to mount {windows-layer}` failures, green only
on the last try). Retries are cheap: completed RUN vertices stay cached, only
the failed finalize/export re-runs. Raise the per-stage budget rather than
the global default.

### The classic lane's fallback needs a RUNNING dockerd

> **HISTORICAL since 2026-08-26** — this no longer guards a usable lane; `build.ps1`
> was retired then and deleted 2026-08-31 (rationale:
> [windows-build-lanes.md](windows-build-lanes.md)). Kept
> because the *host* observation below is still true and still bites `docker.exe`
> publish/inspect work: a Stevedore host can have `docker` on PATH with the daemon
> Stopped. Heading unchanged on purpose — it is a live anchor target.

**The classic docker lane's "always-working fallback" needs a RUNNING
daemon, and on a Stevedore host that daemon is the `stevedore` SERVICE.**
`stevedore` IS dockerd (`...\Stevedore\dockerd.exe --run-service
--service-name stevedore --host npipe:...dockerDesktopWindowsEngine
--containerd=npipe:...`). Found **Stopped** on 2026-08-07 while the BuildKit
lane ran happily — i.e. the documented fallback was unavailable and nothing
said so. `docker.exe` sitting on PATH proves nothing — and since 2026-08-31
**nothing fail-fasts on it**: `Assert-DockerDaemon` was deleted with
`build.ps1`. `verify-host-setup.ps1` reports the service state (WARN:
"docker.exe publish/inspect unavailable"), which is the only check left.
Starting it is NOT a safe reflex:
a dockerd start recreates the nat HNS network and can move the subnet out
from under `0-containerd-nat.conf`, leaving BuildKit containers with
unroutable IPs — so start it deliberately, then RE-CHECK the CNI subnet
(`build-buildkit.ps1` fail-fasts on that drift with the exact fix).

### Two BK-driver guards to know before debugging around them

**Two guards added 2026-08-07 that change how the BK driver behaves — know they exist before debugging around them.** (1) `Invoke-TransientCooldown` now takes `-PreviousTail` and **refuses to retry a byte-identical failure**: a flake changes between attempts, a poisoned snapshot does not, and the old behaviour burned the whole retry budget on `ImportLayer 0xb7`. The comparison strips buildkit's per-line elapsed-time prefixes, which differ every attempt. (2) `Invoke-BkStage` gates **disk per stage** with a stage-aware floor (CUDA 60 GB, media 80, merge 60, toolchain 45, else 40) because the start-of-run check passed at 164 GB while the chain still walked to 23 GB inside one heavy stage. Both honour the existing override switches; both were BK-only when added, and since 2026-08-31 there is no other driver to differ from.

---

## Container networking (CNI)

### The CNI nat config must exist as BOTH `.conf` AND `.conflist`

**The CNI nat config must exist as BOTH `0-containerd-nat.conf` AND
`0-containerd-nat.conflist` — the two clients disagree and each breaks
silently without its own file. NEVER "convert" one into the other.**
- **buildkitd needs the `.conf`.** Without it, RUN steps get **no network
  adapter at all** — not a DNS problem: measured 2026-08-07 with a probe
  container, `ipconfig` was EMPTY and a raw TCP connect to a literal GitHub IP
  returned *"unreachable network"*; the containerd debug log showed the
  `HcsCreateComputeSystem` spec for `buildkitsandbox` with Storage,
  MappedDirectories and MappedPipes but **no networking block**. Surfaces as
  `Could not resolve host: github.com` at the first downloading RUN.
- **nerdctl needs the `.conflist`.** It indexes `plugins[0]` with no length
  check and dies `index out of range [0] with length 0`, in `network create`
  (`netutil_windows.go:40`) AND in `run` (`container_network_manager.go:857`).
  Upstream nerdctl bug (it should return an error), worth reporting.

**This entry previously said the opposite** ("containerd and BuildKit read
either") and that error cost a launched chain on 2026-08-07: the `.conf` was
converted away to fix nerdctl, which silently killed buildkitd's networking,
and nothing caught it because no chain build ran in between. Restoring the
`.conf` beside the `.conflist` + `Restart-Service buildkitd -Force` fixed it
on the spot (IPv4 172.31.44.107, GW 172.31.32.1, DNS 192.168.188.1,
github.com resolved). `build-buildkit.ps1` now fail-fasts via
`Get-CniConfFormIssue`. **When you edit one file, edit both** — nothing
detects the two drifting apart in CONTENT, only absence.

Two guards, two different failures, do not conflate them:
`Get-CniNatSubnetDrift` judges only subnet-vs-adapter drift and reads
`.conflist` then `.conf` (its "file absent = nothing to judge" contract means
a conf under any other name silently disables it — and it passed green the
entire time the lane had no network). `Get-CniConfFormIssue` judges presence
of the form each client needs. ALWAYS re-run a network canary after touching
either file — it is load-bearing for every media compile via sccache.

### The CNI `.conf` is DERIVED from the `.conflist`, not hand-edited

**The CNI `.conf` is DERIVED from the `.conflist`, not hand-edited (2026-08-07).** `apply-containerd-config.ps1` rewrites it via `ConvertFrom-CniConfList` whenever the two differ, so the two forms the clients each require cannot drift in content. Edit the **`.conflist`** and re-run that script; a multi-plugin conflist is refused rather than truncated to `plugins[0]`.

---

## Build inputs and toolchain

### TVM builds its OWN minimal LLVM — do not "simplify" it away

**TVM builds its OWN minimal LLVM (#47, 2026-08-17) — do not "simplify" it
away.** Scoop's LLVM (official Windows installer) ships NO `llvm-config.exe`
and no dev libs anywhere (probed: 0 hits), so every earlier Windows TVM was
silently `USE_LLVM=OFF` — no CPU codegen, `tvm.build` for llvm targets dies
at runtime. The official `clang+llvm-*-windows-msvc` dev tarball is NOT the
fix: its static libs are /MT and want `xml2s.lib`, fatally mismatched
against this /MD chain (verified by one link attempt). The heal in
`build-tvm-from-source.ps1` builds a SHA-pinned llvm-project from source
(X86+NVPTX, no xml2/zlib/tests, `LLVM_ENABLE_DIA_SDK=OFF` — no ATL in these
Build Tools, RTTI ON, full-`:FILEPATH` archiver) and passes
`USE_LLVM=<path>/llvm-config.exe`. sccache makes it a one-time ~6 min cost.

### freedesktop/videolan GitLab downloads must go through `Invoke-WrapDownload`

**freedesktop/videolan GitLab downloads MUST go through
`Invoke-WrapDownload`** (curl-native UA + gzip/bzip2 magic-byte check, in
`WindowsMeson.Common.psm1` since #134 — a merge-lane leaf module, NOT in the
shared `buildmods` closure) — the Anubis anti-scraper in front of
those hosts answers browser UAs without JS with an HTTP-200 HTML challenge
page, which is exactly what the shared `Invoke-DownloadWithRetry` sends.
Also strip `.git` from GitLab `/-/archive/` URLs (with it, GitLab serves
HTML even to curl). Both burned a merge run each on 2026-08-17; do not
"unify" wrap fetching back onto the shared helper.

### graphene needs `-Dgraphene:sse2=false` plus the meson.build patch

**graphene builds only with `-Dgraphene:sse2=false` plus the post-setup
meson.build patch** dropping its `-Werror=undef` (it outranks our c_args —
last flag wins; clang-cl defines no `__GNUC__`, and its MSVC SIMD path
calls SSE4.1 intrinsics unguarded). graphene entered the build for the
FIRST time when #88 made every wrap actually arrive — expect more
first-ever subprojects to surface clang-cl corners after wrap fixes.

### In `RUN --mount=...,from=<stage>` the SOURCE path is Unix-style

**In `RUN --mount=...,from=<stage>` the SOURCE path is Unix-style with NO
drive letter, even on Windows containers.** `source=C:\bkmods` is normalised
to `/C:/bkmods` and fails the solve with `failed to calculate checksum of ref
...: "/C:/bkmods": not found` — it is a PARSE-time/cache-key failure, so it
dies the moment the stage is reached, not inside the container. Write
`source=/bkmods`; the COPY that populates the stage keeps the Windows form
(`C:\bkmods`), and `target=` stays Windows-shaped too. Only the from-stage
source is Unix. Cost a chain launch on 2026-08-07 (`buildmods` closure stage
in Dockerfile.media-builder / .media-merge-builder). Verify a from-stage
mount with a `Test-Path` assertion through it, NOT with `Get-ChildItem` — an
empty mount lists cleanly and exits 0, so a bare listing proves nothing.

### A whole-directory `modules` mount puts EVERY module in the cache key

**Never bind-mount `windows/scripts/modules` as a DIRECTORY — mount the
per-file closure the script imports (2026-08-31).** Every file under a
directory mount is part of that RUN's cache key, so one host-only `.psm1` edit
re-keys the whole vertex. `Dockerfile.toolchain-builder`'s `patched-llvm` RUN
did exactly this, and it is the DEFAULT toolchain target (`-StockLlvm` is the
opt-out, #135): editing *any* module — `WindowsBuildDriver.Common.psm1`
included, which no container ever loads — re-paid a full LLVM 23.1.0 compile
plus every media lane derived from that image. That RUN now mounts the six
modules `build-llvm-from-source.ps1` actually imports, and
`BuildKit.ModuleClosure.Tests.ps1` fails any windows Dockerfile that
re-introduces the directory form. `Dockerfile.probe` is exempt BY DESIGN
(`PROBE_NONCE` busts its layer regardless, and it dispatches arbitrary
diagnostic scripts — its own header says so). Corollary: "a module edit is
cheap" is a claim about the MOUNTS, not about the module.

### The "unreferenced" `windows/scripts` modules are external-consumer API

**The "unreferenced" `windows/scripts` modules are EXTERNAL-CONSUMER API —
never delete (owner decision 2026-08-04).** Flutter/CMake/CodeQL/MSIX/
Slang/Vulkan/PerfBaseline/WasmOpt/AppRunner/ContainerBuild.Reuse/Uv/
Build.Common/WebDav/Toolchain/Config/Formatting/**ContainerLog** (verified
live 2026-08-21: RustProjectTemplate's container scripts import it —
Invoke-StevedoreBuild + rust-build/test-all — vendored into
BeschleunigerBallett and Inference-Engine) plus `scripts/rust/` and
`scripts/python/` are the shared build framework other Kataglyphis repos
consume (this repo IS the upstream). Repo-internal reference audits will
flag them as dead — they are library surface. Keep them lint-clean; do not
rename exported functions without checking external consumers. Their
build-cache cost is zero **only while every mount stays per-file** (§ A
whole-directory `modules` mount puts EVERY module in the cache key).
**Applied 2026-08-31, do not re-litigate:** the driver-cleanup wave kept
`Get-LlvmMasmCmakeArg` (zero in-repo callers) and four
`WindowsSourceBuild.Common` re-exports on this rule alone — the audit that
flags them next will be the same audit, not new evidence.

### Rust: rustup WITH a default toolchain is the sole provider

**Rust: rustup WITH a default toolchain is the sole provider — never a toolchain-less rustup, never a second provider (no scoop rust).** Polarity INVERTED by the Flutter-Cargokit fix: Cargokit (flutter_rust_bridge-style plugins) hard-requires rustup and aborts with "rustup not found in PATH." otherwise, so `setup-rust-toolchain.ps1` runs `rustup-init -y --default-toolchain stable --profile minimal` and `setup-scoop-tools.ps1` installs NO rust. `CARGO_BIN` (= `...\.cargo\bin`, the rustup proxy dir) sits ahead of scoop's shims on PATH **by design**. The failure the old "never rustup" rule guarded against was narrower than the rule: a **toolchain-less** rustup (`--default-toolchain none`) drops proxy shims that resolve no toolchain ("no default toolchain configured"); installed WITH a default they resolve correctly. Do not re-add `scoop install main/rust` alongside — one provider only. Details: `docs/windows-builds.md` § Rust toolchain.

### `versions.env` is the single source of truth

**`versions.env` is the single source of truth.** `build-buildkit.ps1` forwards every version as `--build-arg`; the smoke test and scripts derive expected values from it (e.g. CMake URL from `CMAKE_VERSION`; `LLVM_RELEASE` pins the LINUX clang, `LLVM_WINDOWS_VERSION` the Windows one — separate on purpose). Don't hardcode versions in scripts or Dockerfiles. **Anything that produces or shapes compiled output belongs here**; tools the build merely invokes may float, and `setup-scoop-tools.ps1` splits its installs into exactly those two blocks.

### CMake cross configures must carry the ASM language target too

**A committed layer can never be shrunk later, so scrub INSIDE the container.** The BK lane — the only lane since 2026-08-31 — passes `-ScrubAfter` to the media branch and merge/GStreamer runs (`Clear-BuildScratch`: pip cache, `~\.nuget`, `%TEMP%`, INetCache). It was added there first; the classic lane went without it until 2026-08-07 and shipped debris the BK lane's images did not. Source trees are a separate mechanism — each leaf script calls `Remove-SourceBuildTree` itself. The toolchain stage is excluded on purpose: its CPython tree at `C:\temp\cpython` IS the deliverable.

### vcpkg ships zlib ONLY

**vcpkg ships zlib ONLY (protobuf removed 2026-08-03).** Nothing consumed vcpkg protobuf — every source build brings its own (ONNX `_deps`, LiteRT-LM's `protobuf_external` + downloaded version-matched protoc), and LiteRT-LM even had to hide vcpkg's protobuf headers to avoid version skew. Don't re-add it "for convenience"; it costs ~15 min of base build and creates header-leak hazards.

### Python bindings plumbing is load-bearing

**Python bindings plumbing is load-bearing (added 2026-07-13; full detail in `docs/windows-builds.md` § What is verified: native vs. Python).** (1) The `sitecustomize.py` shim written by `Initialize-PythonPlatformTag` fixes clang-built CPython's win32 platform misreport (pip pulls 32-bit wheels without it) AND registers native DLL dirs (`os.add_dll_directory`; python ignores PATH for pyd deps) — never remove it. (2) OpenCV must keep `WITH_MSMF=OFF` **and** `WITH_OBSENSOR=OFF`: both hard-import Media Foundation, absent on Server Core — either ON makes videoio and the cv2 pyd unloadable. (3) Always `@()`-wrap `Save-PythonWheel` results: PS unwraps a 1-element array so `[0]` becomes the first *character* and pip once installed the PyPI package literally named `c`. (4) Binding asserts go through `Test-PythonImport` (cmd.exe-shielded): tvm writes warnings to stderr on successful imports, which raw `&` under EAP=Stop turns into false failures. (5) Wheels live at `C:\runtime\wheels` (`PYTHON_WHEELS`); the Orchestr-ANT-ion torch step resolves the app's LATEST tag per build and its wheel-smoke suite gates the final docker build — both amd64-lane facts. On arm64 (#120, 2026-08-24) the target CPython ships at `C:\runtime\python` (source-built, `PCbuild\build.bat -e -p ARM64`, ClangCL props, PE `0xAA64` verified in-stage) and the wheel store holds the `onnxruntime`/`onnxruntime_genai_directml`/`av` wheels tagged `cp314-win_arm64` plus `cv2.cp314-win_arm64.pyd` in the target site-packages — **staged, never installed or imported** (nothing here can run aarch64). Load-bearing rules on that lane: the HOST interpreter runs every build and the TARGET import lib is linked (`Get-TargetBuildPython` — `.Exe` host, `.Lib` target; never conflate them); wheels go through `Invoke-PythonWheelBuild -CrossStage` (one call for both lanes: on cross it appends the target `--plat-name`, stages, and runs `Assert-WheelTargetArch` — PE machine + `EXT_SUFFIX` name tag of every member; natively it installs + import-asserts); the shim pins `EXT_SUFFIX` to the target while `get_platform()` stays host — two different facts (what this interpreter *builds* vs what pip may *download*); ORT/GenAI take `Python_*` hints (GenAI additionally the legacy `PYTHON_*` trio for vendored pybind11) — `Python3_*` is silently ignored, see `SourceBuild.FindPythonPrefix.Tests.ps1`. The GenAI wheel's ORT requirement is rewritten to plain `onnxruntime` before packing (both lanes, #126): upstream's `setup.py.in` derives `onnxruntime-directml`/`-gpu` from the package name, but our combined ORT wheel is named `onnxruntime` — unpatched, the edge is unsatisfiable on arm64 (no `win_arm64` `onnxruntime-directml` exists) and pulls a second ORT over ours on amd64. The cross merge then stages the target's runtime deps (`stage-target-python-deps.ps1`: host pip `download --platform win_arm64 --python-version 3.14` for what the bundle does not provide; gate: every wheel pure or `win_arm64`, every `Requires-Dist` resolves inside `C:\runtime\wheels`) and the arch gate walks every PE's import table (`verify-target-arch.ps1 -ImportWalk`, #127: each import must resolve to a bundle DLL, an `api-ms-`/System32 name — CRT DLLs excluded from System32 on cross — the driver allowlist, or the client-OS list `-ClientOsPattern` for DLLs a Windows client SKU ships but Server Core does not: `dsound`, `mf*`, `winspool.drv`). Its first run (arm64 run 13) found 13 real unresolved imports — the OpenSSL runtime DLLs nobody installed, the client-OS set, and `vcruntime140_threads.dll` — so treat a green walk as the gate it is, not decoration. It is a hard gate on cross lanes only: on the native lane the deliverable is the image, whose PATH carries the host CPython, scoop's OpenSSL and the toolkits, so the same walk reports (amd64: 186× `python314.dll` + 8× `python3.dll` from the host interpreter outside the roots, 6× `libcrypto/libssl-4-x64`) and never throws. (6) PyAV is built from sdist against OUR FFmpeg (`setup.py --ffmpeg-dir`) — PyPI's `av` wheel is unloadable on Server Core (bundled avdevice imports desktop-only `AVICAP32.dll`); in headless code request software encoders by name (`mpeg4`) — the generic `h264` alias resolves to the hardware `h264_d3d12va`. (7) IREE (media-tvm branch, TVM→IREE chain) is a shallow-submodule git clone (release tarballs lack LLVM); its wheels come from the ninja build tree's synthesized `compiler/`+`runtime` pip dirs with `--no-build-isolation` — plain `pip wheel` of the repo would rebuild all of LLVM in an isolated tree. Native tools at `IREE_ROOT` (`C:\runtime\iree`); CUDA HAL/target need no nvcc (PTX via NVPTX, driver dlopens nvcuda.dll).
