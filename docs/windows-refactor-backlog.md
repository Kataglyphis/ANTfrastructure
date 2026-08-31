<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows container chain — refactor backlog

Open work, standing directives and pending host/upstream actions for the
Windows container chain. Settled items are archived under
`docs/windows-backlog-archive-*.md`.

The Linux-side equivalent is [`refactoring-backlog.md`](refactoring-backlog.md).

> **COUNTING NOTE:** item numbers are HISTORICAL and never reused — the highest
> number is not the item count. Resolved narratives move to the dated archives
> (`windows-backlog-archive-*.md`); a bare "#N" that is not in this file
> resolves there. Lean-OPEN-only is the owner''s standing policy.

## OPEN

### ARM64 parity (opened 2026-08-23)

The `:winarm64` cross lane reached runtime parity with `:winamd64` apart from the
exclusions listed below, and **2026-08-31 reran the FULL chain with the QNN EP
enabled** (#121 build-time path proven; the earlier acceptance gap — HEAD vs the
2026-08-26 tree — was two dead-on-arrival GStreamer cross-lane fixes that are now
landed: see #135 follow-up below). Read the table as the last fully green run
(`bk-winarm64`, 2026-08-31).

| | arm64 cross (`bk-winarm64`, 2026-08-31, QNN ON) | amd64 native (`bk-20260826-130136`) |
|---|---|---|
| arch gate | **1168 binaries, 0 violations** (QNN payload rides in) | 1134, 0 |
| import walk | **793 files, 0 unresolved** (85 device-OS: FastRPC + client SKU) | — |
| bundle manifest | 7 DLL homes, **6 wheels**, 3 ABSENT markers | — |
| GStreamer contract plugins | **6/6** — `libav opencv onnx webrtc nice tflite` | 6/6 |
| smoke gate | **97 passed / 0 failed / 15 skipped** (floors 66/25) | **222 / 0 / 0** |
| QNN | EP ON, QAIRT 2.44.0, `aarch64-windows-msvc` backends staged beside all five frameworks | off (x64 CPU backend is pointless) |
| wall clock | ~40 min (media+final) | 2 h 18 min |

**Exactly three components are ABSENT on arm64**, each marked in the bundle by an
`ABSENT-ON-ARM64.txt` (call sites: `build-tvm-from-source.ps1:525`,
`build-iree-from-source.ps1:331`, `build-litert-all.ps1:85`): the **TVM compiler**, the **IREE
compiler** (both need an LLVM cross-built for aarch64-windows) and **LiteRT-LM** (Bazel + an x86_64
prebuilt `.lib`; a CMake port exists upstream — #133(d)). Their *python packages* DO now ship
(`apache_tvm`, `apache_tvm_ffi`, `iree.runtime` — closed by #133). Also excluded by owner decision
or construction: **CUDA** (#122, no Windows-on-ARM CUDA) and the **torch app stage** (`uv sync` must
execute the target interpreter). The **QNN EP is PRESENT and PROVEN 2026-08-31** (build-time path;
runtime execution still needs a Snapdragon host — see #121 below).

**The honest caveat, unchanged:** nothing the arm64 lane produces has ever been *executed*. Its
wheels ship staged, not installed, and every verdict above is a static check — PE machine type,
import resolution, exported symbols. The 15 skipped smoke assertions are the ones that would have
to run the aarch64 payload on an x64 host.

**Permanently out of reach — do not re-litigate without new upstream facts:** classic TensorRT
(genuinely x64-only — NVIDIA's support matrix has no ARM64 row), and the `torch` app stage (`uv
sync` must **execute** the target interpreter — uv can cross-RESOLVE into a directory, but the
synced venv is the stage's contract — and PyTorch builds no `win_arm64` wheel for **Python 3.14**,
this repo's cp314 pin).

---

### Open items

- **#147 — single-driver + module-mount cleanup wave.** **DONE 2026-08-31** on
  `refactor/windows-chain-cleanup`: code landed, suite green at 773 tests, **no
  chain run yet**. `build-buildkit.ps1` is the only driver.
  1. **Classic driver deleted.** `windows/build.ps1` (retired 2026-08-26) and the
     six `WindowsBuildDriver.Common.psm1` functions only it called —
     `Set-BuildDriverIsolation`, `Invoke-DockerWithRetry`,
     `Get-DockerBuildArgList`, `Assert-ImageExists`, `Resolve-BuildIsolation`,
     `Assert-DockerDaemon`. `Test-TransientDockerFailure` STAYS: the BK driver
     reaches it through `Invoke-TransientCooldown`. `$script:BuildDriverContext`
     is down to `TransientPattern`, and `Initialize-BuildDriverContext` takes
     only `-TransientPattern` (nothing read Docker/LogDir/NoCache).
     `Driver.PreflightParity.Tests.ps1` → `Driver.PreflightContract.Tests.ps1`
     (3 tests, one driver); floor 763 → 762 with provenance at
     `windows/scripts/tests/Invoke-Tests.ps1:154` — the first DROP, measured, not
     hiding a red run. Stale `build.ps1` references corrected in 19 files;
     `verify-host-setup.ps1` was a LIVE CHECK reporting stevedore as the "classic
     fallback lane" and now reports it as the publish/inspect tool.
     `Dockerfile.torch`'s `-TorchBaseImage` recipe has NO BuildKit equivalent
     (the driver pins the torch stage's `BASE_IMAGE` to the local windows-media
     tag), so it is documented as not driver-supported, not mechanically renamed.
  2. **The expensive one — a whole-dir modules mount on the DEFAULT toolchain
     target.** `Dockerfile.toolchain-builder`'s `patched-llvm` RUN bind-mounted
     all of `windows/scripts/modules` (~45 files), and `patched-llvm` is the
     default (`build-buildkit.ps1:526`; `-StockLlvm` is the opt-out) — so ANY
     `.psm1` edit re-keyed a full LLVM 23.1.0 compile **and** every media lane
     deriving from that image. Now six per-FILE mounts, exactly the closure
     `build-llvm-from-source.ps1` imports (`Dockerfile.toolchain-builder:66-76`),
     gated by a new test at `BuildKit.ModuleClosure.Tests.ps1:190` that fails a
     whole-dir modules mount in any windows Dockerfile except `Dockerfile.probe`
     (exempt by design — `PROBE_NONCE` busts its layer anyway; its header says
     so). **Correction of record:** while that mount existed, "a host-only module
     edit cannot bust a compile layer" and "editing `WindowsBuildDriver.Common`
     is cheap" were FALSE. They are true now. Same file: the
     `BUILD_PATCHED_LLVM` comment still claimed "OPT-IN / off by default" against
     its own `ARG BUILD_PATCHED_LLVM=1` and the driver default — corrected (#135
     made it default).
  3. **TVM wheel helpers off the hot facade.** `Write-AssembledWheelDistInfo` and
     `Get-PyprojectDependencies` moved from `WindowsSourceBuild.Common.psm1` (the
     `buildmods` six, mounted into all 11 media RUNs) to
     `WindowsTvm.Common.psm1:60,92` (the `tvmmods` leaf, mounted by media-tvm
     only). Sole consumer: `build-tvm-from-source.ps1:316-326`.
  4. **`Set-StrictMode -Version Latest`** added to `build-llvm-from-source`,
     `debug-litertlm-link`, `load-versions`, `normalize-tensorrt-tree`,
     `stage-cuda-runtime`, `clean-sccache-mount`, `bootstrap-pwsh`. Making that
     safe needed FOUR latent-bug fixes, each verified on pwsh 7.6.5 (where
     `.Count` throws on a scalar **and** on an empty pipeline result):
     `normalize-tensorrt-tree.ps1`'s `$dllDirs` was not `@()`-wrapped, so `.Count`
     threw on the **normal success path** (TensorRT 10+/11 ship the DLLs in `bin`
     only — exactly one dir survives); `stage-cuda-runtime.ps1`'s `$roots` had the
     same shape and would have re-broken the arm64/CPU merge lane that the
     2026-08-23 degrade-cleanly fix unblocked; `clean-sccache-mount.ps1` inlined
     `.Sum` on a `Measure-Object -Property`, which emits NOTHING for empty input;
     `debug-litertlm-link.ps1` took `.Source` off an absent `llvm-nm.exe` —
     **already a live bug**, because its caller `build-litert-lm-from-source.ps1`
     sets StrictMode and `&`-invocation inherits it.
  5. **GStreamer wrap provisioning extracted.** The phase-5 wrap-git prefetch +
     libffi force-download (~64 lines) became `Invoke-GstWrapProvisioning`
     (`WindowsMeson.Common.psm1:293`, a merge-lane leaf). It takes a `-Logger`
     scriptblock, accumulates failures in a LOCAL list and RETURNS them; the #88
     fail-closed throw stays at the call site
     (`build-gstreamer-from-source.ps1:288`) so that gate stays visible where it
     fires. The libffi version expression deliberately STAYED in the stage script
     (`:283-285`) — `SourceBuild.PinParity`'s W1c scanner keys the pin site by
     FILE NAME. Script 1574 → 1514 lines. New suite:
     `SourceBuild.GstWrapProvisioning.Tests.ps1`.
  6. **Non-hermetic test fixed.** `Assert-ShimPatch` gained `-AlternateRoot`
     (default unchanged, `WindowsBuildDriver.Common.psm1:333`) so its fail-closed
     not-found path is testable on a host that HAS a real shim — the two cases at
     `BuildDriver.HostGates.Tests.ps1:205,215` now pass `-AlternateRoot @()`
     instead of silently exercising the fallback probe.
  7. **Audited: no classic-only Dockerfile targets remain.**
     `Dockerfile.media-builder`'s stages are `common` / `buildmods` / `tvmmods` /
     `*-env` / `*-built`; the warm/materialize targets went in the 2026-08-06
     de-warming (see #149). Nothing in the tree still needs the classic driver.
  Docs: [`windows-builds.md`](windows-builds.md) § Reusable modules,
  [`windows-build-invariants.md`](windows-build-invariants.md) § external-consumer API,
  and `AGENTS.md` § Caching discipline for the module tiers. Note for readers of
  `windows-build-resources.md:136`: its "backlog #134" follow-up pointer is CLOSED
  and now resolves here (#147) — the sampler itself was wired into
  `build-buildkit.ps1:461` by #134's free follow-ups.

- **#148 — #147's deliberate declines (recorded so they are not re-litigated).**
  Each is a cleanup the wave could have made and did not, on purpose:
  1. **`Get-LlvmMasmCmakeArg` stays dead-but-present**, and the four re-exports on
     the `WindowsSourceBuild.Common` facade stay un-narrowed — other Kataglyphis
     repos import these modules, so a zero-references audit is not evidence of
     zero consumers. Rule: [`windows-builds.md`](windows-builds.md) § Reusable
     modules and [`windows-build-invariants.md`](windows-build-invariants.md)
     § external-consumer API.
  2. **`Set-StrictMode` declined on four files**, each for its own reason:
     `WindowsFlutter.Common.psm1` and `WindowsContainerLog.Common.psm1` are
     external-consumer API and a module does NOT inherit its caller's strict mode,
     so adding it is a real downstream behaviour change;
     `Initialize-CiEnvironment.ps1` is dot-sourced and would leak strict mode into
     seven in-repo callers plus external consumers; `litert-lm-export-bridge.ps1`
     is dot-sourced by a caller that already sets it, so the line is a no-op with
     leak risk.
  3. **`Export-BuildHandoff` / `Import-BuildHandoff` stay on the hot facade.**
     They look host-only, but `bk-warm.ps1`'s header keeps them plus
     `bk-materialize.ps1` as the TESTED ROLLBACK PATH, and the retired
     `media-core-built-opencv` RUN in `c9586c1^` mounts
     `WindowsSourceBuild.Common.psm1` into the container precisely so
     `bk-materialize` can call `Import-BuildHandoff`. Moving them breaks that path
     silently. See #149 for why that path is not currently safe anyway.

- **#149 — the `c9586c1^` warm/materialize rollback recipe is DEAD, not merely
  stale.** NOTE REPAIRED 2026-08-31 (`bk-warm.ps1:5-18`); the restore itself stays
  OPEN until someone needs it. `bk-warm.ps1` promised that if the ExportLayer-0x3
  canary fires again you can restore those targets and "these payloads work
  unchanged". The payloads do; the targets do not. Measured: all **ten** retired
  RUNs mount the same five modules (`WindowsSourceBuild.Common`, `Shared`,
  `Patches`, `Cuda`, `Native`) and neither module the tree has needed since:
  1. `WindowsTargetArch.Common.psm1` — `WindowsSourceBuild.Common` **throws at
     import** without it (#116, the deliberate throw at its line 36), so every
     restored RUN dies before executing a line. This is the one that makes the
     recipe dead rather than partial.
  2. `WindowsTvm.Common.psm1` — `build-tvm-from-source.ps1:27` throws without the
     `tvmmods` mount (#134), so TVM still fails once the import is fixed.
  The fix is two mount lines per restored target. The header now says so; do not
  delete the recipe, and do not trust it verbatim.

- **#150 — `.claude/settings.local.json` still allowlists `build.ps1` invocations**
  (four entries, lines 9-15) for a driver that no longer exists. NOT touched by
  #147: permission configuration is the owner's call. Harmless (the commands
  cannot run), but it is the last place the classic driver is still named as a
  live entry point.

- **#151 — `CHANGELOG.md` archive split.** **DONE 2026-08-31.** The file had run
  to 2430 lines against its own ~700 rule (`CHANGELOG.md:5`). Cut on the DATE
  boundary, not a line count: 2026-08-29 and newer stay live (568 lines), and
  `## 2026-08-28 — Layer headroom dispute settled` and older moved verbatim into
  [`changelog-archive-2026-08-28.md`](changelog-archive-2026-08-28.md) — 2026-08-28
  carries six entries and splitting inside it would strand half a day's story.
  The header pointer names both generations, and the new page is registered in
  `docs/INDEX.md` and `docs/index.rst` (without both, `verify_doc_links.py` reds
  on its `[index]` check — that is how this wave first tripped it).

### CLOSED (pointers — full narratives in the dated archives)

- **#121** — QNN EP: BUILD-TIME PATH PROVEN 2026-08-31 on the full `:winarm64`
  cross run — SDK qairt-2.44.0.260225 (SHA-pinned), `onnxruntime_USE_QNN=ON`
  with the `aarch64-windows-msvc` backend set, QNN provider built, QNN runtime
  staged beside all five frameworks (arch gate 1168/0, smoke 97/0/15).
  Execution verification still needs a Snapdragon host. Archive: this entry.

- **`-ResumeStage` BK equivalent** — CLOSED 2026-08-29 (no BK equivalent needed).
  The classic lane's `-ResumeStage` preserved a stopped container (hours of
  compile state), injected a fix via `docker cp`, committed to a partial image,
  and re-ran from a specific stage. BuildKit has no intermediate containers to
  preserve — but it caches completed RUN vertices, so re-running `buildctl`
  automatically resumes from the last cached step. Script fixes land via bind
  mounts (re-read at solve time), so the "inject a fix and re-run" case is
  covered natively. No BK equivalent is needed.

- **#135** — LLVM 23.1.0 AArch64 codegen: DONE 2026-08-29. `BUILD_PATCHED_LLVM=1`
  is now the DEFAULT (Dockerfile ARG + driver default), workarounds removed from
  `build-opencv-from-source.ps1`. `-StockLlvm` is the opt-out. Items 1+3 closed;
  item 2 (NINJA_KEEP_GOING census) is now unnecessary (root cause fixed); item 4
  filed as llvm#219200. Archive: `windows-backlog-archive-2026-08-26.md` § #135.
- **#135 follow-up — patched toolchain lacks the aarch64 compiler-rt** — DONE
  2026-08-31. The source-built `C:\llvm-patched` ships `clang_rt.builtins-x86_64.lib`
  only, so the arm64 GStreamer link died on `__udivti3` (2026-08-30 cross run,
  merge stage). The merge stage now self-heals: `build-gstreamer-from-source.ps1`
  § 5d mines `clang_rt.builtins-aarch64.lib` from the LLVM release archive on the
  cross lane (same recipe as setup-scoop-tools.ps1). Chosen over adding the lib to
  the toolchain layer because the media branches derive FROM `bk-windows-toolchain`,
  so that would re-pay ~2 h of media compiles for one lib. Toolchain-level fix stays
  a follow-up for the next natural toolchain rebuild. Regression:
  `SourceBuild.GstreamerCompilerRt.Tests.ps1`. Docs:
  `docs/windows-cross-builds.md` § aarch64 compiler-rt.
  Second unmasked failure fixed in the same window: the speculative cross-lane
  opus intrinsics enablement (2026-08-30) is REVERTED to the proven disabled
  state — under clang-cl aarch64 the RTCD path applies `-mfpu=neon` (ARM32-only
  flag) and its CPU probe uses MSVC's `__emit` (absent from clang-cl). Working
  enablement recipe for a future TESTED window: `-Dopus:intrinsics=enabled
  -Dopus:rtcd=disabled` (presumes NEON+dotprod; needs a real-device smoke).
  Final gate fix in the same window: the arch-gate import walk gained the
  Qualcomm FastRPC pair `libcdsprpc.dll`/`libadsprpc.dll` as device-OS
  allowances (imported by the QAIRT HTP stub DLLs staged by `Copy-QnnRuntime`;
  they ship in every Windows-on-Snapdragon OS image, never in the SDK zip).

- **#133(d)** — LiteRT-LM CMake port: CLOSED 2026-08-29 (owner decision — staying on Bazel).
- **#134** — post-#133 cleanup wave: DONE 2026-08-29. amd64 acceptance
  PASSED (smoke 192/0/1, arch gate 1134/0). Archive: `windows-backlog-archive-2026-08-26.md` § #134.
- **Layer headroom dispute** — SETTLED 2026-08-28. The final image sits at ~75
  layers (counted from the inherited chain's instructions: base 16 + nvidia 3 +
  toolchain 4 + media-merge 15 + torch 3 + final 2 = 43, + 20 ENV + ~12 servercore
  = ~75). The ~108 figure was the pre-ENV-consolidation count. Updated in
  `docs/windows-build-invariants.md`.
- **#122** — CUDA on arm64: CLOSED 2026-08-28 (owner decision). Archive: `windows-backlog-archive-2026-08-26.md` § #122.
- **#136** — VS RUN caching: SOLVED + DEPLOYED 2026-08-26. Archive: `windows-backlog-archive-2026-08-26.md` § #136.
- **#137** — sccache: DONE 2026-08-28. Needs rebuild to land.
- **#134 free follow-ups** — ALL DONE 2026-08-28: smoke floor recalibrated (85→66),
  §19 PROVISIONAL marker removed, pin parity updated for `TVM_COMMIT`, TVM
  fixtures fixed (single-quoted `` `n `` → real newlines), three merge-stage
  test suites added (39 tests), resource sampler wired into `build-buildkit.ps1`.
- **#133 (a)+(b)+(c)** — DONE 2026-08-26. Archive: `windows-backlog-archive-2026-08-26.md`.
- **#128, #129** — DONE 2026-08-25/26. GStreamer webrtc/nice, OpenCV NEON dispatch.
- **#124, #125, #126, #127** — DONE 2026-08-25. vcruntime140, sitecustomize, staged deps, import walk.

- **#31 [owner decision] registry push** — push the verified images to a
  registry instead of local-only tags. Parked until the owner wants it
  (#59 branch protection was DECLINED, #31 was not).

## STANDING DIRECTIVES (survive their archived entries — do not re-litigate)

- **NEVER trim CUDA_ARCHITECTURES** (80;86;89;90 in ALL builds, incl. dev
  iterations; pinned by Pins.CanonicalValues).
- **CUDA compiles stay BARE nvcc** — the sccache launcher-default question is
  CLOSED (miscompile is storage-independent and cold-cache; archive #99/P0b).
- **Do NOT collapse the media-core checkpoints** (#72: export is ~1.2% of the
  chain; resume granularity is worth more than ~60 s).
- **Do not re-propose** branch protection (#59) or a scheduled nightly/weekly
  chain run (#111) — DECLINED by owner 2026-08-17; manual launches are the
  verification cadence.
- **Do not re-propose #147's declines** (#148): deleting `Get-LlvmMasmCmakeArg`
  or narrowing the `WindowsSourceBuild.Common` re-exports (external-consumer
  API), `Set-StrictMode` on the two consumer modules or the two dot-sourced
  scripts, or moving the handoff helpers off the facade.
- **No logging-idiom sweep** (#110): chain scripts use Write-Host, gstreamer
  keeps its structured `log`, Write-BuildLog stays host-driver territory;
  enforcement is review, not a cache-busting mass edit.
- **GES `_commit` retry is DORMANT INSURANCE** (#77): re-open only if its
  retry marker reappears in a gstreamer build.
- **Restore `disk,webdav` only after WCOW cache mounts are PROVEN** (#99
  re-verification recipe in the archive; also listed under Pending).

## Pending host/upstream actions (not refactors — do not let these evaporate)


> The elevated between-runs window (buildkitd step-log env restore, GC-budget
> deploy = #34, poisoned probe-chain prune, diagnostic tag cleanup) and the dufs
> SYSTEM-service migration were APPLIED by the owner 2026-08-13 — see the archive
> addendum. Sanity-check the GC deploy with `buildctl debug workers -v` — the
> output says `Reserved space: 161.0612736GB` for a healthy 150 GiB pin, NOT
> "150GB": the toml takes GiB and buildctl prints GB, and the labels differ too.

- **UPSTREAM, consolidated 2026-08-17 (was scattered across #99''s body and two
  Open-items entries):**
  1. **moby/buildkit — WCOW cache mounts lose writes into an inherited
     directory.** Cause, A/B measurements and the 2-minute repro are in the
     archive (#99). Strengthen before filing: reproduce with PLAIN file writes
     (no sccache). Goes to moby/buildkit, NOT mozilla/sccache.
  2. **mozilla/sccache#2808 addendum** — the issue''s "WebDAV cache was largely
     empty" reasoning is now explained by the BuildKit mount defect (writes
     never reached the remote because L0 failed first under the default
     write-error-policy=l0). Core findings (nvcc deadlock + miscompile) stand;
     a two-sentence correction protects the report''s credibility. Also note
     CUDA is launcher-off by default since 2026-08-10, so the deadlock repro
     needs SCCACHE_CUDA_LAUNCHER=1.
  3. **Restore `disk,webdav`** once WCOW cache mounts stop losing inherited
     writes — owner intent; two-step re-verification recipe in the archive
     (#99): probe twice (ON-mount row must be clean on the SECOND, inheriting
     run), then one media build with the chain re-enabled and genai at 0 write
     errors.
- **hcsshim follow-ups still unfiled** (package README status header,
  re-checked 2026-08-21): the ISSUE.md issue and the
  Windows-Containers#547 comment for microsoft/hcsshim#2855 (the draft
  PR itself IS filed; the package's submission recipe is now marked
  HISTORICAL so nobody files a duplicate).
- **Post the upstream issues** — POSTED 2026-08-13:
  mozilla/sccache → https://github.com/mozilla/sccache/issues/2808 (nvcc
  deadlock + miscompile), google-ai-edge/LiteRT-LM →
  https://github.com/google-ai-edge/LiteRT-LM/issues/3245 (CMake-lane
  staleness, four findings). **POSTED 2026-08-24:** opencv/opencv#29788
  (dnn/ORT `char*` vs `wchar_t`, from out/upstream-issue-opencv-ort-wchar.md) —
  our `004-dnn-ort-profiling-wchar.patch` stays until it lands upstream.
  **NEW DRAFTS (2026-08-24 evening, not posted — owner's call), both found by #116's
  first cross runs:** out/upstream-issue-iree-host-bin-dir-exe.md — `IREE_HOST_BIN_DIR`
  composes host tool paths without `.exe` on a Windows host;
  out/upstream-issue-iree-elf-arch-arm64-msvc.md — `MSVC_C_ARCHITECTURE_ID MATCHES 64`
  matches `ARM64`, archiving the x64 MASM object into an ARM64 library.
- **Post-run diagnostics queue — DEMOTED 2026-08-14: the sccache half is
  CLOSED.** The forensics had escalated this to "sccache has never worked, on
  any run" (0 hits / 189,861 failed writes across 94 stat blocks). **That was
  stale evidence, not a live defect** — the newest sccache stats in the whole
  corpus are from 2026-08-13 19:43, the dufs SYSTEM-service migration landed
  the same day, and every run since had media-core CACHED, so nothing could
  have shown the improvement. A direct probe (real cache mount, real WebDAV
  endpoint, one TU compiled twice) returned **miss → store → HIT, 0 write
  errors, 0 read errors**, and confirmed `HEAD`/`GET`/`PUT` succeed **from
  inside a container** — the direction `Assert-SccacheEndpoint` never tests.
  `SCCACHE_ERROR_LOG` is no longer "the missing artifact": the cache mount was
  found EMPTY, so there was never a log to recover.
  What remains here: (1) the exact-TU replay (`bias_softmax_impl.cu`) for the
  miscompile mechanism and the nvcc/CUDA sccache crash — **untested by the
  clang-cl probe and still genuinely open** (it is what drives #75's silent
  `-j` downgrade ladder); (2) one `probe-build-copy.ps1 -Heavy` smoke after the
  poisoned-chain prune; (3) re-measure the at-scale hit rate on the first real
  media build after 2026-08-13 — until then it is simply unmeasured.
  VERIFIED 2026-08-14: the buildkitd service env now really does carry
  `BUILDKIT_STEP_LOG_MAX_SIZE=-1` + `..._MAX_SPEED=-1` (checked at the service
  registry key, and today's base build no longer emits the clip warning) — so
  the next full chain will be the FIRST fully-captured one. The 49-run corpus
  analysed above predates this: 28 of those logs contain real clip events, the
  green reference run is 49 % blind in its merge step, and historical ONNX
  steps are 83 % blind. Re-run the forensics against a full captured chain.
