<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows backlog archive — 2026-09-17

Closed on 2026-09-17 and moved out of
[`windows-refactor-backlog.md`](windows-refactor-backlog.md), which is
OPEN-only, per that file's COUNTING NOTE: item numbers are historical, and a
bare `#N` that is not in the open file resolves here.

**Every item in this archive is landed-but-unbuilt.** No Windows image was
rebuilt for this wave — the container-side files are cache inputs of the next
chain — so each verdict is a source diff, a Pester assertion or a static gate on
an idle tree. Nothing here is proven by a solve.

Earlier tranches:
[`2026-08-11`](windows-backlog-archive-2026-08-11.md) ·
[`2026-08-17`](windows-backlog-archive-2026-08-17.md) ·
[`2026-08-21`](windows-backlog-archive-2026-08-21.md) ·
[`2026-08-26`](windows-backlog-archive-2026-08-26.md) ·
[`2026-08-31`](windows-backlog-archive-2026-08-31.md).

---

## #158 — the 13 verified defects, landed in ONE closure window

The 2026-09-01 audit confirmed 17 defects and deferred the container-side eleven
so their cache re-key was paid once. They landed together, plus the two
majors the audit flagged "check while there".

**`windows/Build-Buildkit.ps1`.**

* `-TargetArch` is forwarded to the `-ConcurrentAux` child drivers
  (`if ($TargetArch -ne 'amd64')`), so an arm64 parent no longer builds aux
  branches under amd64 tags or merges stale trees.
* Child-forwarded `-NoCacheStage` entries are registered in the parent's
  `$script:NoCacheStageMatched`, so a correct parent run no longer ends red in
  the matched-nothing gate.
* `final-tar` and `final-push` are exempt from `-NoCache`/`-NoCacheStage`
  matching: both re-export the post-smoke final solve and must stay cache hits.
* `-ConcurrentAux -NoSccache` is refused at launch — the halved aux budget is
  published only through the WebDAV path that `-NoSccache` disables, so the
  combination would silently run both children at full host RAM.
* The halving formula has a single owner (`$auxMem`, #175 prework); the publish
  call reads it instead of recomputing it.

**`windows/Dockerfile.media-merge-builder`.** The `DEPS_MIN_BUNDLE_WHEELS` /
`DEPS_MIN_FIRST_TOUCH_REQS` ARGs are declared globally (so `--build-arg` binds),
redeclared inside `built` (ARGs do not cross a `FROM`) and ENV'd **above** the
`Copy-TargetPythonDeps` RUN that reads them. Declared after that RUN, both floors
had been dead since landing.

**Toolchain closure.** `Build-ToolchainAll.ps1` and `Build-LlvmFromSource.ps1`
now call `Disable-ContainerWindowsUpdate`, and `Dockerfile.toolchain-builder`'s
`built` stage mounts the module files that call needs
(`WindowsSourceBuild.Common.psm1`, `WindowsTargetArch.Common.psm1`) — the docs
promised the call, the lane never made it, and a WU spool write killed the layer
finalize.

**`WindowsSourceBuild.Common.psm1`.** `Invoke-GitClone` captures the
`git submodule update` exit code (`$cloneExit = $LASTEXITCODE`), so a failed
submodule init no longer leaves an incomplete tree and a green clone. TVM's
commit-pin path is the real caller.

**`windows/scripts/host/Install-NewHost.ps1`.** The shim is built from the
Kataglyphis hcsshim fork (`feature/configurable-teardown-timeout`) pinned by
commit `192514290b9875a18481869f15b3649657237001` (fetch-by-SHA so the tree
stays one commit deep), and the build **asserts** the
`CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT` knob is present in `task_hcs.go`
instead of applying the retired 45min/100min constant patch. The deploy passes
`-ServiceEnvironment @('CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m')`, and the
closing buildkitd restart refuses when live `buildctl` processes exist (unless
`-Force`) and reports a failed restart as red rather than swallowing it.

**`windows/scripts/host/Update-HostVhdx.ps1`.** Both rollback paths and the
final restart call `Start-HostServices`, which starts services in reverse stop
order and writes each failure as a red line — the measured 2026-09-01 bug was a
swallowed error over a buildkitd that started before containerd.
`Optimize-HostVhdx.ps1` and `Publish-ShimPatch.ps1` were repointed to the same
owner. `Measure-Tree` takes `-ExcludeDir` and both verify passes skip
`System Volume Information` and `$RECYCLE.BIN`, matching what robocopy `/XD`
skips — a fresh volume root carries its own `$RECYCLE.BIN`, which made the copy
look short.

**Probe mounts.** `Dockerfile.probe` and `Dockerfile.sccache-write-probe` were
already repaired by `145c17f2`; verified in the tree and left unedited.

**`WindowsAgenticLoop.Common.psm1`.** Captured output uses
`ConcurrentQueue`, not `ConcurrentBag` (the bag enumerates LIFO, reversing every
consumer's transcript). The `-ExecutorOnly` failure cap now sets
`$script:AgenticExitCode = 1`; before, a capped run reported exit 0. The cap is
unreachable from Pester (dry-run makes `Invoke-BuildCommand` return `$true`
unconditionally), so the contract is pinned at the source level by two
assertions in `WindowsAgenticLoop.Common.Tests.ps1` that require each
failure-cap arm to assign the exit code before stopping.

**`Build-OnnxGenaiFromSource.ps1`.** The post-copy floor the audit asked for:
the install must contain headers plus `onnxruntime-genai*.dll`/`.lib` or the
step throws — `Copy-BuildArtifact` reports counts but never threw, so an empty
or partial install shipped green.

**Honest residue.** The 36-minor opportunistic sweep (dominated by fail-open
error paths in the nuget/scoop/git-lfs class) was **not** done. #158 closes on
the thirteen verified defects; the minors remain unfiled and a future sweep
starts from the audit's class list, each with its mutate-the-guard test.

---

## #159 — the eight settled sccache/CUDA probes are gone

Plain delete, git history as the record: `Test-Sccache2726Repro`,
`Test-SccacheNvccInstantiation`, `Test-SccacheOptionsStrict`,
`Test-SccachePatchVerify`, `Test-SccachePrHygiene`, `Test-SccacheRelativeFo`,
`Test-SccacheRspShapes` and `Test-CudaRuntimeClosure` — **714 lines** removed.
Three were dead by construction (they mounted the #137-deleted
`sccache-nvcc-quote-fix` tree). `Dockerfile.probe`'s default `PROBE_SCRIPT` was
re-pointed from `Test-SccacheOptionsStrict.ps1` to `Test-OnnxTuReplay.ps1`, and
the stale comment references in `Invoke-DiagnosticProbe.ps1` and
`Test-OnnxTuReplay.ps1` were updated. The duplication gate's corpus effect
followed: every allow row held by a deleted probe fell out, and two rows that
survive re-measured one shingle lower.

---

## #160 — the verify + System32-tar block is in the base and merge copies

`Install-ScoopTools.ps1` now imports `WindowsScripts.Shared.psm1` (one of the
three modules `Dockerfile.base` COPYs before the script) for
`Assert-FileSha256` and `Get-PreferredToolPath`, and its aarch64 compiler-rt
staging uses the verified-or-warn SHA contract plus the System32 `bsdtar` (GNU
tar parses `C:\...` as a remote-host spec). `Build-GstreamerFromSource.ps1`'s
merge-stage self-heal calls the new shared owner `Install-AArch64CompilerRt`
(`WindowsSourceBuild.Common.psm1`, re-exported). **ScoopTools keeps its own
copy** of the recipe because the base-stage closure mounts only
`Shared/ContainerImage/Installer` — the base stage cannot call the shared owner,
and the allow rows record that as a forced duplicate rather than drift.

---

## #164 — patched-LLVM compiles go through sccache

`Build-LlvmFromSource.ps1` gates on `Test-SccacheRemoteConfigured` **and** a
present `sccache.exe` (the old `SCCACHE_DIR`/`SCCACHE_SERVE` test was never set
by the toolchain stage, so every re-key compiled LLVM cold), wraps the build in
`Start-SccacheServerSession`/`Complete-SccacheServerSession`, and writes the
hit-rate stats to stderr (`Write-SccacheStatsToStderr -Advanced -RequireRemote`).
`Dockerfile.toolchain-builder`'s `patched-llvm` stage gained the SCCACHE
ARG/ENV block and the two cache mounts, and `Build-Buildkit.ps1` forwards
`$sccache` into the toolchain stage's build args. `Test-SccacheRemoteConfigured`
is the remote-only gate because a container-local cache dies with the layer.

**Follow-up, 2026-09-23: that ENV block published the endpoint.** It copied the
media builder's block, and like it put `SCCACHE_WEBDAV_ENDPOINT` (and the chain and
force-local switches) into the image ENV, where the published `:winamd64` carried
the build host's LAN address to every consumer. The block is now split: the three
build-host names are ARGs only (RUN environment, never the image), and the ENV keeps
the container-local defaults. The mounts, the gate and the forwarding above are
unchanged. The account, the ARG/ENV table and the gates that hold it:
[`windows-build-resources.md` § What the published image carries](windows-build-resources.md#what-the-published-image-carries).

---

## #167 — the baked `C:\temp\scripts` surface is smoked

`Test-Container.ps1` gained section 23: the three (four on amd64; the
torch-baked `Build-TorchApp.ps1` is cross-skipped) baked files exist, a module
imports from the in-image set rather than the bind mount, and the baked
`Test-Health.ps1` exits 0 — exit code only, so its own `[PASS]`/`[SKIP]` lines
do not read as suite assertions. A `C:\temp\scripts` that predates the
final-stage COPY SKIPs the section. The arm64 global smoke floor moved 66 → 69
against the new section floor (`Smoke.FloorCalibration.Tests.ps1` lists 23 among
the host sections; the arm64 floor sum is 77). Section counts and both floor
columns were updated in `windows-builds.md`, `windows-cross-builds.md`,
`cross-build-verification.md` and `project-info.md`.

---

## #168-#174 — the comment-discipline wave

Each script's essay was replaced by short comments and a pointer to the page
that owns the facts; none of the deleted text was dropped.

* **#168** `WindowsMeson.Common.psm1` → `failure-modes.md` § *meson cross*.
* **#169** `WindowsContainerBuild.Reuse.psm1`'s `Get-Help` transport essay →
  `windows-container-build-performance.md` (the page already owned the facts;
  the fsutil form the docs call broken is no longer served to consumers).
* **#170** the same module's `Get-SccacheContainerEnv` → a new section in
  `windows-container-build-performance.md`; the 2026-07-20 os-error-3 diagnosis
  was added there **first**, then the comment trimmed to a pointer.
* **#171** `Start-GeniexServers.ps1` → `geniex-local-ai-setup.md`.
* **#172** `Set-TensorrtTree.ps1` → `windows-builds.md`.
* **#173** `WindowsSlang.Common.psm1` → `slang-shader-compilation.md`.
* **#174** `Build-LitertAll.ps1` → `windows-builds.md`; the comment's claim
  that the Bazel script runs *outside* `Invoke-SourceBuildChain` had been false
  since #128 and is gone.
* The follow-on: `Build-OpencvGstreamerPlugin.ps1` — the audit's only comment
  with no docs home — got a `windows-builds.md` section and a two-line pointer,
  and the page's script index now links it.

---

## #175 — the three neighbourhood checks

* The `-ConcurrentAux` halving formula has one owner: `$auxMem` (#158 consumed
  it).
* The executor drain-loop's failure cap sets `$script:AgenticExitCode = 1`
  (#158's agentic-loop half), pinned by the two source-level Pester assertions.
* The optional Pester runtime test for that cap was replaced by the source-level
  contract assertions because the cap is unreachable in dry-run. Recorded
  honestly: the assertions check the source text, not a live capped run.
  `mutations.json` carries no entry for the contract at this tip.

---

## Doc drift — the six findings and a cross-lane attribution

All fixed here, verified against the tree before editing:

* `windows-host-setup.md` now points at `windows/scripts/host/Test-HostSetup.ps1`
  in both the prose and the copy-pasteable command.
* `project-info.md` points the HEALTHCHECK at
  `windows/scripts/build/Test-Health.ps1`; its media-stage version restatements
  were replaced with the variable names (`ONNXRUNTIME_VERSION`,
  `LITERT_VERSION`, `TVM_REF`, `GSTREAMER_VERSION`, …), its LLVM line names
  `LLVM_WINDOWS_VERSION`, and the category count is 23.
* `overview.md` names `windows/Dockerfile.toolchain-builder`.
* `README.md`'s QNN sentence no longer contradicts itself: QAIRT
  `2.44.0.260225`, and the note says only ORT consumes the QNN EP (#154).
* `docs/deps/deps.json` attributed the **Linux** sccache to the Windows patch
  series; the Linux row is now the unmodified `distro-archive` binary and a
  separate Windows-lane row carries the patches. All generators were
  regenerated: `sbom-curated.spdx.json`, `third-party-licenses.md` and the two
  website licence footers.
* `windows-build-lanes.md`'s ConcurrentAux deterrent now states the #51 fix
  (`MEMORY_LIMIT_GB` is a scheduling knob published on the WebDAV, not a baked
  ENV), and `windows-cross-builds.md`'s status header reflects the 2026-09-02
  green dual-lane state and the 69/20 arm64 floors.

---

## The PascalCase doc anchors — resolved before this wave

`19982134` + `9b819f28` renamed every PowerShell script and left
`docs/windows-builds.md` pointing at six old headings. The anchors now resolve
against the live headings; `verify_doc_links.py` is green over the whole tree and
the pre-commit hook no longer needs `--no-verify` for this class.
