<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows build resources — CPU, memory, cache and GPU

How much of the host a Windows container build may take, the measured ceilings,
and how the compile cache is wired. Every number here was measured on this
repo's build host — treat them as *this host's* envelope and re-measure
elsewhere.

Neighbours: the lanes themselves are
[`windows-build-lanes.md`](windows-build-lanes.md); consumer-project build
performance (container reuse, transports, Dev Drive) is
[`windows-container-build-performance.md`](windows-container-build-performance.md);
Linux-side job counts are
[`build-parallelism-memory-tuning.md`](build-parallelism-memory-tuning.md).
## GPU acceleration in containers (DirectML on the host GPU)

On Windows, **GPU acceleration in containers is DirectX-only** — Direct3D 12 and
everything layered on it, which includes **DirectML** (the ONNX `DmlExecutionProvider`
and onnxruntime-genai's DML path). CUDA/TensorRT cannot be GPU-accelerated in a
Windows container. On this host that is exactly the point: the machine has an **AMD
Radeon RX 9070 XT** (+ iGPU) and **no NVIDIA GPU**, so DirectML — being
vendor-agnostic — is the *only* GPU path. (The CUDA/TensorRT EPs are still built and
smoke-checked for availability, but they have no device to run on here.)

Running DirectML on the physical GPU **inside a container** requires all of:

1. **Process isolation** — Hyper-V-isolated containers get **no** GPU. (The default
   isolation on this host is `hyperv`, so you must pass `--isolation process`.)
2. **The DirectX GPU device**, attached with the **exact** device interface class GUID:
   `--device class/5B45201D-F2F2-4F3B-85BB-30FF1F953599`. A wrong variant is *silently
   accepted* by `docker run` but matches no device, so the container falls back to the
   WARP software renderer with no error.
3. **A base-image OS build that matches the host build.** Basic process isolation
   tolerates skew (a `26100` image runs on a `26200` host), but GPU **driver-store
   injection does not** — `hcs::CreateComputeSystem` fails with *"The system cannot
   find the path specified"* when the builds differ. This is the **same** client-host
   (`26200` / 25H2) vs Server base image (`servercore:ltsc2025` = `26100`) skew that
   breaks `docker build --isolation process` layer commits.

**Current status on this host: BLOCKED by the build skew.** The GPUs *are* GPU-PV
partitionable (`Get-VMHostPartitionableGpu` lists both AMD adapters), process
isolation works, and the DirectML runtime is built correctly — but GPU device
assignment fails at `CreateComputeSystem` because the `ltsc2025` (`26100`) base does
not match the host (`26200`), and no public client `26200` base image exists to
rebuild against. A DXGI enumeration inside the (correctly-flagged) container therefore
sees only `Microsoft Basic Render Driver` (WARP), zero hardware adapters.

To retire the block: rebuild the base on a `servercore`/`nanoserver` tag whose build
equals the host, **or** run the image on a host whose build equals the image
(`26100`, e.g. a Windows Server 2025 host). Until then, **DirectML on the AMD GPU
still works fine _outside_ containers** — run the source-built ORT / GenAI binaries
directly on the bare host and the `DmlExecutionProvider` selects the RX 9070 XT.

Re-check after any Docker / containerd / hcsshim / Windows / base-image / GPU-driver
upgrade with the self-contained probe under `windows/scripts/diagnostics/`:

```pwsh
.\windows\scripts\diagnostics\Test-GpuPassthrough.ps1
```

It prints host/image builds and partitionable GPUs, runs a process-isolation control,
attaches the GPU device, compiles + runs a DXGI adapter enumerator inside the
container, and gives a verdict: **PASSTHROUGH WORKS** (a HARDWARE adapter is visible),
**BLOCKED** (build-skew `CreateComputeSystem` failure), or **DEVICE-NOT-INJECTED**
(started but only WARP). Note the DML probes in `Test-Container.ps1` validate
that the provider is *built and registered* (`GetAvailableProviders` → `dml=1`, plus
the x64 `D3D12Core.dll` PE-machine check); they do **not** create a device, so they
pass under either isolation regardless of whether a hardware adapter is present.

## Media fan-out and memory budgeting

**Media scheduling is sequential** (one log per solve —
`out\windows-build-logs\bk-<runid>-<stage>.log`, one per media-core library, one
per aux branch, one for the merge). Sequential gives media-core the *whole* host
RAM budget — and since its parallelism is memory-bound, more RAM = more ONNX jobs,
which matters more than overlapping the small aux branches (a former
`-ConcurrentMedia` overlap mode was removed for exactly that reason).

**`-MediaMemoryGb` auto-detects from host RAM** (default `0` = auto). It resolves
to `usable_physical_GB − HostReserveGb`. `-HostReserveGb` (default 22 — see the
learned-the-hard-way note below) is the RAM left for Windows + dockerd + Defender;
lower it to push closer to the metal (riskier — under memory pressure the hcsshim
`ttrpc` wedge is more likely). Pass an explicit `-MediaMemoryGb N` to override
auto-detection. The cap is forwarded as `MEMORY_LIMIT_GB` so the build scripts
scale their job count to the container's cap (`BUILD_JOBS` overrides the heuristic
outright).

Worked example (this 64 GB host, Windows reports 61.4 GB usable → floor 61,
default `-HostReserveGb 22`): auto `-MediaMemoryGb` = `61 − 22` = **39 g** →
ONNX runs `~j10` (`mem/4`, cores=32).

media-core, toolchain and the merge/GStreamer stage all solve process-isolated
with every host CPU (see [`windows-build-lanes.md`](windows-build-lanes.md) § Build isolation and CPU parallelism); the run+commit
path and its `-MediaCoreCpus` flag went with `build.ps1` on 2026-08-31. The
litert/tvm aux branches get the whole budget once media-core is done — halved per
child under `-ConcurrentAux`, which overlaps only those two.

## Building a project inside the image, as AGENTS.md carried it

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading and the relative links. The RULES stayed there; this is the reference behind them.

Consumers building large projects in this image should read
[`docs/windows-container-build-performance.md`](windows-container-build-performance.md)
before hand-rolling anything. The number that motivates it, measured on a
~690-object C++23 modules project: **9.6 s ninja / 44 s wall** for a no-change
incremental build against a reused container, versus **352-484 s** when every
build got a fresh one.

The rule that follows: **reuse ONE container**, recreating it only when the
image ID changes; stream sources in and executables/logs out, never the
intermediate build tree. Transport choice, the Dev Drive filter setup, and the
four traps that cost measurable time (bind mount slower behind a filesystem
filter, sccache useless on C++20/23 modules, a named volume unusable as a CMake
build dir, deep paths aborting tar transfers) are all in that page.

## Maximum resource envelope (verified 2026-07-12)

The defaults ARE the maximum for this 64 GB / 32-thread host — there is no
faster configuration to unlock, and the full-chain rebuild of 2026-07-12
(base → sdk → toolchain → media → final, phase-tagged resource CSV) is the proof:

| Phase        | Minutes | AvgCpuPct | MaxCpuPct | MinFreeGB |
|--------------|---------|-----------|-----------|-----------|
| media-core   | 111     | 37        | 100       | **0.2**   |
| media-litert | 18      | 38        | 100       | 24.9      |
| media-tvm    | ~25     | 42        | 100       | 41.8      |

- **CPUs: 32/32 on every heavy stage.** That chain took them from the classic
  lane's `docker run --cpu-count 32` + commit, the only >2-CPU path there
  (`docker build` was pinned at 2 CPUs by the host defect — hence its cheap
  COPY/clone-only layers); the BK lane gets all CPUs from process isolation.
- **RAM: 39 GB is the measured optimum, not a conservative default.** During
  media-core the host bottomed out at **0.2 GB free** — the 22 GB reserve was
  consumed almost exactly. Raising `-MediaMemoryGb` (or cutting
  `-HostReserveGb`) does not add jobs fast enough to beat the starvation
  cliff: the 53 GB experiment deadlocked media-core at 0 % CPU (see the
  hard-way note below).
- **Average CPU of ~35–45 % during compiles is CORRECT and expected** — it is
  the memory-bound signature (`jobs = min(32, 39 GB / ~4 GB-per-ONNX-job) ≈ 10`),
  not a tuning failure. Do not chase 100 % average CPU on this host.
- **The only real "go faster" levers are infrastructural:** ~128 GB RAM (true
  `j32` on ONNX), or a populated sccache remote (`-SccacheEndpoint` /
  `SCCACHE_WEBDAV_ENDPOINT`) to make *re*builds warm — cold full-chain is
  ~5–6 h with ~2.5 h of that in the media fan-out.

**Per-run resource log.** Every `Build-Buildkit.ps1` run samples host CPU / free
RAM / commit charge / container-VM (`vmmem`) size every 20 s into
`out\windows-build-logs\resources-<timestamp>.csv`, tagged with the current build
phase — the BK stage label (`Dockerfile.media-builder:media-core-built-onnx`),
plus `init` and `done` — and prints a per-phase exhaustion summary at the end,
including on failure. The sampler starts only after every preflight gate has
passed, so a rejected launch leaves nothing orphaned, and `-ConcurrentAux`
children run without one (the parent's already covers the machine). Re-analyze any
run later with
`pwsh -File windows/scripts/build/Build-ResourceSampler.ps1 -Summarize -CsvPath <csv>`;
`MinFreeGB` per phase shows which step pushed the host hardest, and an
`AvgCpuPct` far below 100 during a compile phase means the step was memory-bound
(`jobs = min(cores, MEMORY_LIMIT_GB/perJob)`), not CPU-bound. Disable with
`-NoResourceLog`.

> **Why the reserve is 22 GB, not ~8 (learned the hard way).** An earlier default
> of `-HostReserveGb 8` auto-sized media-core to **53 GB**, which **hung the build**:
> during a GPU build dockerd + containerd juggling the ~50 GB CUDA image layers,
> plus `svchost`/Defender, hold **~16–18 GB** steady — so 53 GB container + ~17 GB
> host exceeded the 61 GB physical, the Hyper-V VM starved at ~43 GB, and media-core
> deadlocked at **0 % CPU** with the host at **0.3 GB free** (log frozen mid-ONNX for
> 2 h). The `--memory` cap is real RAM committed to the utility VM, so
> `container_cap + host_footprint` must fit physical RAM with margin. 22 GB reserve
> (→ ~39 GB container, ~56 GB peak) is the verified-safe budget here. The heavy
> CUDA TUs (FlashAttention, MoE kernels) use **more than the ~4 GB/job estimate**, so
> do not shrink the reserve without watching `docker stats` + host free RAM.

## The Windows cache, tier by tier

Moved out of `AGENTS.md` on 2026-09-15, unedited except for this heading and the
list marker. The rule -- assume nothing from the Linux chain, preserve the layer
ordering and the per-file module closures, check the reserve before blaming a
cache key -- stays there; the tiers, the numbers and the two incidents are here.

**The WINDOWS chain caches differently — do not assume rules 1-4 apply.**
   It relies on (a) deliberate layer ORDERING — `Install-Vs.ps1` sits ABOVE the
   `versions.env` COPY in `Dockerfile.base` so a pin bump cannot re-pay VS
   Build Tools (confirmed live 2026-08-08: 4 of 16 base steps CACHED through a
   PYTHON_VERSION bump, and they were the expensive ones), (b) TIERED, PER-FILE
   in-container module closures so a host-only module edit re-keys only the RUNs
   that import it, (c) sccache, and (d) **buildkitd's GC reserve**. **Preserve
   (a) and (b) in any Dockerfile edit** — moving a COPY above the VS layer, or
   widening a module stage, costs hours per bump.

   **(b) has only actually been true since 2026-08-31.**
   `Dockerfile.toolchain-builder`'s `patched-llvm` RUN bind-mounted the WHOLE
   `windows/scripts/modules` directory, and `patched-llvm` is the DEFAULT
   toolchain target (`-StockLlvm` is the opt-out), so any `.psm1` edit re-keyed
   the LLVM 23.1.0 compile and every media lane derived from that image. It is a
   six-file mount now, and `BuildKit.ModuleClosure.Tests.ps1` fails a whole-dir
   modules mount in any windows Dockerfile except `Dockerfile.probe` (exempt by
   design — `PROBE_NONCE` busts its layer anyway).

   **(d) is the one that fails SILENTLY and looks like a Dockerfile problem.**
   `reservedSpace` in `windows/buildkitd.toml` is the only floor GC will not
   prune below, and it must exceed the **fresh chain spine** (~120–150 GB: base
   incl. VS + sdk + toolchain + branch images). Set below that, the ~37 GB
   VS-class layer is evicted between driver runs and every run re-solves the
   prefix — `#9 RUN Install-Vs.ps1` re-executing for 4–7 min while `#8`, the COPY
   of that very script, reports CACHED. It has happened twice (2026-08-11,
   2026-08-26). **Before blaming a cache key, check the reserve against
   `buildctl du`'s Total and against the store size**: `Reclaimable: 0B` is not
   "nothing to clean", it is what a store already pruned to its floor looks
   like. `maxUsedSpace` below the working-set size has the same effect, because
   it forces eviction regardless of what the reserve says.

   **The module tiers (#134, 2026-08-26; toolchain narrowed 2026-08-31) — check
   which one a module is in before editing it, because the cost differs by
   hours:**
   1. `Dockerfile.media-builder`'s **`buildmods`** six (SourceBuild.Common +
      Shared, Patches, Cuda, Native.Common, TargetArch.Common). They ARE the
      import closure — SourceBuild.Common imports the other five and every
      mounted build script imports it — so the set cannot be shrunk and **every
      media/merge RUN keys on all six**. A one-line edit costs a full media
      rebuild on both lanes.
   2. **`tvmmods`** (`FROM buildmods AS tvmmods` + `WindowsTvm.Common.psm1`),
      mounted by `media-tvm-built` alone. That branch runs parallel to
      media-core, so an edit costs nothing on the long pole. `Write-AssembledWheelDistInfo`
      and `Get-PyprojectDependencies` moved off the tier-1 facade into this leaf
      on 2026-08-31 — `Build-TvmFromSource.ps1` is their only caller.
   3. The **merge leaves** in `Dockerfile.media-merge-builder`'s `buildmods`:
      `WindowsGstPlugins.Common`, `WindowsMeson.Common`,
      `WindowsRustToolchain.Common`, `WindowsInstaller.Common`. An edit costs
      the GStreamer layer.
   4. `Dockerfile.toolchain-builder`'s **`patched-llvm`** RUN mounts the same six
      as tier 1, per-file. It is the DEFAULT toolchain target, so an edit re-pays
      the LLVM 23.1.0 compile AND every media lane below it — the most expensive
      tier in the chain.

   Do NOT move a helper into `WindowsSourceBuild.Common` because "that is where
   helpers go" — if one branch is its only consumer, it belongs in a leaf.
   `BuildKit.ModuleClosure.Tests.ps1` enforces both directions (a mounted
   script's transitive closure must be mounted; leaves must stay out of
   `buildmods`, and `tvmmods` must keep exactly one consumer). It is
   mutation-proven — trust it over reading the Dockerfile.

   **Wired**, with the rules an agent must not break. Full rationale,
   measurements and decision history:
   [`docs/windows-build-resources.md`](windows-build-resources.md)
   § Persistent compile cache (sccache).
   - **sccache runs WebDAV-remote-only since 2026-08-16.**
     `SCCACHE_MULTILEVEL_CHAIN` defaults to `""` in **both**
     `Dockerfile.media-builder`'s `common` stage and the merge builder (not a
     descendant, so the ENV is repeated — **change BOTH or neither**). Restore
     `disk,webdav` only after re-verifying against a newer buildkit.
     **`SCCACHE_DIR` alone does nothing** without the chain variable.
   - **sccache is the released 0.18.0 zip, installed into `CARGO_BIN`** (since
     2026-09-18; the `SCCACHE_GIT_REV` source build is retired). 0.18.0 carries
     #2722 + #2811 + #2816 — everything the pin carried. History and the CUDA
     canary bar: § Persistent compile cache (sccache).
   - **`CMAKE_CUDA_COMPILER_LAUNCHER` is ON BY DEFAULT since 2026-08-18.** Never
     flip that default off silently, and never export the launcher onto a new
     sccache without all THREE canaries — the miscompile it once caused is
     invisible until the DLL link.
   - **uv/pip wheel cache** in `Dockerfile.torch`, set INSIDE the RUN (an `ENV`
     would bake a build-only mount path into the shipped image).

   Still NOT wired, with a measured reason: **source-fetch mounts.** The clones
   are shallow (`Invoke-GitClone` passes `--depth`), so they cost minutes
   against compiles that cost hours. If you do it, cache the ARCHIVES/CLONES
   only, never the working tree — directory RENAMES fail on cache mounts and
   `Build-GstreamerFromSource.ps1` moves the extracted tree. Also raise the
   tier-0 `type==exec.cachemount` cap in `windows/buildkitd.toml` — it is
   **shared** by every cache mount plus local sources and git checkouts, and
   the sccache L0 (15G) and uv cache (10G) already claim most of it. Cache
   sizes and that cap are ONE decision, not two. (Since 2026-08-16 the L0 mount
   is attached but DORMANT — the chain defaults to WebDAV-only — so its 15G is
   reserved rather than consumed. Do not repurpose that headroom: the tier is
   meant to return, see #99.)

## Persistent compile cache (sccache)

Without BuildKit cache mounts a container-local sccache cache dies with the
layer, so the WebDAV remote is the only compile cache that survives a
container. **sccache is therefore REQUIRED by default for the media stages:
Build-Buildkit.ps1 fails fast when a media stage is requested and no reachable
endpoint is configured** (`-NoSccache` opts into a deliberate cache-less build). The
gate is media-only (`Assert-SccacheEndpoint`, `$compileStages = @('media')` in
`WindowsBuildDriver.Common.psm1`) — the toolchain stage (MSBuild/ClangCL
CPython) has no sccache wiring, so toolchain-only builds are never blocked on
an endpoint they would not use. One-time
host setup:

```pwsh
# one-time host setup (any WebDAV-capable server works; dufs is a single binary)
scoop install dufs
mkdir C:\sccache-cache
dufs C:\sccache-cache -A -p 5000

# then build with the endpoint (use an IP reachable from inside containers,
# e.g. the host's LAN IP — not localhost)
.\windows\Build-Buildkit.ps1 -Gpu -SccacheEndpoint http://192.168.1.10:5000
```

CMake-based builds (ONNX, GenAI, OpenCV, LiteRT, LiteRT-LM, TVM) then route
clang-cl through sccache, and since 2026-08-04 GStreamer (Meson) is cached too
(`Build-GstreamerFromSource.ps1` sets `CC`/`CXX` to `'sccache clang-cl'`
when the remote backend is configured). FFmpeg (MSVC/make) remains uncached.
The first build populates the cache; subsequent `--no-cache` rebuilds and
version bumps reuse unchanged object files.

**sccache is the OFFICIAL RELEASED 0.18.0 zip since 2026-09-18 — the source
build at `SCCACHE_GIT_REV` is retired.** `Install-RustToolchain.ps1` downloads
`sccache-v0.18.0-x86_64-pc-windows-msvc.zip`, verifies it against
`SCCACHE_WINDOWS_ZIP_SHA256`, and installs `sccache.exe` into `CARGO_BIN`,
which precedes the scoop shims on PATH. `Test-Toolchain.ps1` asserts the
version, which works now because 0.18.0 reports 0.18.0 — unlike
main-at-git-rev, which still said 0.17.0 and forced a path-based assert.

Why the source build existed, and what would bring a bare-nvcc exception back:

- **CUDA 13.3's `--simt-only` dryrun mis-parse.** Released sccache decomposes
  nvcc by parsing `nvcc --dryrun`; 13.3.33 emits `--simt-only` AFTER the input
  file, so the positional parser took the flag as the input, mis-grouped the
  cicc/ptxas device steps, and the per-arch `.cubin` files were never produced.
  The build died at the combine step with
  `fatbinary fatal : Could not open input file '<tu>.compute_80.cubin'`
  (measured here 2026-08-08 on ONNX's CUDA provider). Fixed by
  mozilla/sccache#2722, merged 2026-08-04 — five days AFTER v0.17.0 shipped.
- **#2811 (dryrun quote collapse).** `\"` escapes flattened before tokenization
  packed ~30 `-D` pairs into one 493-char token, so the cpp4 preprocess lost
  `USE_CUDA` & friends; that was the 2026-08-10 miscompile (dropped
  instantiations, `lld-link: undefined symbol`). Merged 2026-08-19.
- **#2816 (`--diag-suppress` separated form).** The OpenCV #115 blocker; merged
  2026-08-26.
- All three ship in **0.18.0 (released 2026-09-14)**, which is why the git-rev
  pin, the `windows/upstream/sccache-nvcc-quote-fix/` series and the
  `cargo install --git --rev` path are gone.
- **The cuda_llm scope (patch 006).** While the fix was in flight, ONNX's
  `onnxruntime_providers_cuda_llm` target was scoped to BARE nvcc, because
  sccache's server died deterministically on the cutlass-generated fused_moe
  GEMM launchers (~4910 s in, clients got `os error 10054`; #2808). Patch 006
  was retired 2026-08-18 with the #114 series: fused_moe compiles through the
  launcher and links green. If undefined fused_moe/QkvToContext symbols return,
  check the series still applies before resurrecting a bare-nvcc exception.
- **The canary bar.** Never point `CMAKE_CUDA_COMPILER_LAUNCHER` at a new
  sccache on the strength of a green compile: the miscompile class is invisible
  until the DLL link. A candidate must pass
  `windows/scripts/diagnostics/Test-CudaCache.ps1` (its in-container payload
  `verify-cuda-cache/Test-Cache.ps1` compiles the same `.cu` twice and asserts
  a cache hit AND a backend write) plus an ONNX canary through the fused_moe
  launchers before cuda_llm is re-wrapped.

**The CUDA launcher (`CMAKE_CUDA_COMPILER_LAUNCHER`) is ON BY DEFAULT since
2026-08-18** (`SCCACHE_CUDA_LAUNCHER="1"` in the media-core-built-onnx stage),
after a decision history worth keeping:

- The 2026-08-10 miscompile (dropped instantiations, `lld-link: undefined
  symbol`) was root-caused to sccache's Windows dryrun quote-collapse — `\"`
  escapes flattened before tokenization packed ~30 `-D` pairs into one
  493-char token, so the cpp4 preprocess lost `USE_CUDA` & friends. Fixed
  upstream (mozilla/sccache#2811, MERGED 2026-08-19). The `--diag-suppress`
  separated form (mozilla/sccache#2816) also merged upstream 2026-08-26; both
  ship in the released 0.18.0 the lane now installs.
- The three-canary bar passed on the evening of 2026-08-18: fused_moe compile
  green, providers_cuda link green COLD (153 CUDA device writes), link green
  on the HIT run at **100.00% CUDA/PTX/CUBIN hit rate** (207/816 hits) —
  onnx's CUDA portion drops from ~60 to ~33 min warm. The canaries are
  `Test-CudaCache.ps1` + a fused_moe compile + a full providers_cuda LINK —
  the miscompile class is invisible until link, which is why all three are
  required before trusting any new sccache with the launcher.
- The #2808 DEADLOCK separately proved to be #99 collateral (gone under a
  healthy backend). Patch 006 (bare fused_moe) was RETIRED 2026-08-18 (moe
  compiles through the launcher, link green).
- Opt out per run with `-BuildArg SCCACHE_CUDA_LAUNCHER=`; **never flip the
  default off silently.**

> **Note (.dockerignore):** The repo `.dockerignore` must NOT contain a `windows/` exclusion — the Windows Dockerfiles COPY from the `windows/scripts/` directory within the build context. If `windows/` is added to `.dockerignore`, the COPY steps will fail with "file not found in build context". This exclusion is safe for Linux builds (which use `linux/` context) but breaks Windows builds.
