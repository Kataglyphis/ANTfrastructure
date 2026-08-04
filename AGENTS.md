# Kataglyphis-ContainerHub

Agent context file. Build commands live in `README.md`; deep architecture in
`docs/`. This file captures the **guardrails** an LLM agent must follow to avoid
regressing the build.

## Container Architecture

Three build lanes. Supported Linux arches: `amd64`, `arm64`, `riscv64`. Windows: `windows/amd64`.

| Dockerfile | FROM | Produces |
|------------|------|----------|
| `Dockerfile.base` | `ubuntu:26.04` | `:base` |
| `Dockerfile.toolchain` | `:base` | `:cross-compiler-amd64` |
| `Dockerfile.sdk` | `:cross-compiler-amd64` | `:cross-sdk-<arch>` |
| `Dockerfile.media` | `:cross-sdk-<arch>` | `:cross-media-<arch>` |
| `Dockerfile.android` | `:cross-media-<arch>` | `:cross-android-<arch>` |
| `Dockerfile.package` | `:base` + `:cross-android-<arch>` | `:latest-cross-package-<arch>` |
| `Dockerfile.torch` | `:latest-cross-package-<arch>` | `:latest-cross-<arch>` |
| `Dockerfile.nvidia` / `Dockerfile.amd` | `:cross-sdk-<arch>` | optional GPU layer (CUDA or MIGraphX) |
| `windows/Dockerfile.*` | `windows/servercore:ltsc2025` | `:winamd64` |

### Windows-Specific Naming

The Windows lane uses local intermediate tags (`local/kataglyphis:windows-base`, `local/kataglyphis:windows-sdk`, `local/kataglyphis:windows-toolchain`, `local/kataglyphis:windows-media`) and publishes the final image as `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`. See `docs/windows-builds.md` § Build Commands for the full build sequence.

---

## Quick Reference

Build logs are written to `out/build-logs/` by passing `--log-dir` to `build-cross-chain.sh` or `build-cross-stage.sh` (the two orchestrators that tee each stage build; the Makefile wraps these). The other orchestrators (`build-cross-compiler.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`) do not accept `--log-dir` — capture their output with `2>&1 | tee ./out/build-logs/<name>.log`.

Most common build commands:

```bash
# Full cross-build chain (base -> compiler -> sdk -> media -> android -> runtime)
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Compiler image only (amd64-hosted, contains cross toolchains for all arches)
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64

# Compiler with custom image repo (matches --image-repo on the orchestrator)
./linux/scripts/build-cross-compiler.sh --image-repo ghcr.io/myorg/kataglyphis_beschleuniger --push

# Single cross stage — the canonical way to rebuild one stage for one arch.
# Handles parent digest pinning, build-arg assembly, log capture, and push.
# See docs/linux-cross-builds.md § "Single-Stage Builds" for details.
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push --log-dir ./out/build-logs
bash linux/scripts/build-cross-stage.sh --stage media --arch amd64 --push --log-dir ./out/build-logs
bash linux/scripts/build-cross-stage.sh --stage media --arch arm64 --push --log-dir ./out/build-logs

# Verify chain freshness without building
bash linux/scripts/build-cross-chain.sh --verify-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Standalone quick chain verification (lighter, no orchestrator flags)
bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64

# Print the full stage graph with tag names (no builds)
bash linux/scripts/build-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Dry-run: print all build commands without executing
bash linux/scripts/build-cross-chain.sh --dry-run --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Cheap packaging validation before publish (see docs/linux-cross-builds.md)
# Uses the `wrapper-smoke` target in Dockerfile.package

# Reinstall QEMU/binfmt after host reboot
nerdctl run --rm --privileged tonistiigi/binfmt --install all
```

> **See also:** [`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) for the full stage graph, digest pinning, and single-stage build details. [`docs/linux-build-basics.md`](docs/linux-build-basics.md) for build fundamentals, caching, and troubleshooting.

### Windows Container Build

All stages use **Ninja+clang-cl+lld-link** (not MSBuild/VS generator). The Windows container toolchain is **containerd + BuildKit + nerdctl** (preferred since 2026-08; full CPUs + real layer caching), with docker-classic run+commit as the always-working fallback. Role split — each tool where its pipe ACL allows:

| Task | Tool | Shell |
|---|---|---|
| Build the chain | `windows\build-buildkit.ps1` → `buildctl` (buildkitd pipe is docker-users) | non-admin |
| Inspect / run the `bk-*` images | `nerdctl --namespace buildkit` (containerd pipe is admin-only upstream — no `--group` option exists; never attempt pipe-ACL hacks) | **admin** |
| Publish via docker / classic-lane ops | Stevedore's `docker.exe` (`-FinalTar` bridges the containerd→docker store gap until registry push is wired) | non-admin |

**Isolation policy: process isolation is always preferred** — build.ps1's `-Isolation auto` (default) runs the ~10s commit probe (`windows/diagnostics/test-process-isolation-commit.ps1`, verdict cached per host build + docker version) and uses `--isolation process` for every `docker build`/`docker run` when the host can commit process-isolated layers (full CPUs everywhere); it falls back to `hyperv` with a warning on wcifs-skew hosts. **sccache is required by default for toolchain/media** (fail-fast when `-SccacheEndpoint`/`SCCACHE_WEBDAV_ENDPOINT` is missing or unreachable; `-NoSccache` overrides).

**BuildKit/containerd lane (PREFERRED, `windows/build-buildkit.ps1`):** probes on 2026-08-03 proved the wcifs commit bug and the 2-CPU cap are DOCKER-CLASSIC artifacts on this host — buildkitd+containerd commits process-isolated layers fine and RUN steps see all 32 CPUs; the chain was then run from base on this lane the same day (VS2026 install, CUDA, CPython, media compiles all as plain process-isolated layers). **Status 2026-08-04 (evening): the lane is GREEN end-to-end** — the host's snapshotter defect (`ExportLayer 0x3`, see Common Failure Modes) is neutralized by the warm/materialize solve pattern (heavy builds run in never-finalized warm solves, artifacts hand off via WebDAV tar, calm materialize solves export the images); `bk-winamd64` builds in ~44 min hot. Heavy-lane RUN steps bind-mount their script closures (per-file) instead of COPY. The driver builds the same Dockerfiles via buildctl, selecting the `*-built` targets (toolchain-builder `built`, media-builder `media-<branch>-built`, merge-builder `built`) that run the heavy compile scripts as plain LAYERS — no run+commit, real per-stage caching. **Getting it going (one-time setup + launch): see `docs/windows-builds.md` § BuildKit/containerd lane.** Requirements: buildkitd service (docker-users group) + `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` (without it RUN steps have no network) — and the conf's `ipam.subnet` MUST match the live `vEthernet (nat)` adapter: dockerd restarts recreate the nat HNS network on a new subnet and silently orphan the conf (containers then get unroutable IPs, "remote name could not be resolved" on the first download). `build-buildkit.ps1` now fail-fasts on that drift with the exact fix. Gotchas: results live in the CONTAINERD store as `docker.io/local/kataglyphis:bk-*` (fully-qualified on purpose — buildkit normalizes FROM refs to docker.io/ and stage handoff needs `--opt image-resolve-mode=local` to match); they are INVISIBLE to docker (separate windowsfilter store) — export with `-FinalTar`. The classic lane is unaffected: build.ps1 pins `--target builder`/`--target merge` so docker never executes the `built` stages.

The paragraph below describes the docker-classic HYPERV fallback state:

**`docker build` is capped at 2 CPUs on this host — the heavy media-core stage builds via `docker run --cpu-count N` + `docker commit` instead.** Hyper-V-isolated build containers get only **2 logical CPUs** (pinning `ninja -j` to 2, `Get-BuildJobCount = min(ProcessorCount, memGB/perJob)`), and `docker build` has **no working lever** to raise it: `--cpu-count` is rejected, `--cpuset-cpus` fails the build, and `--isolation process` exposes all CPUs but **cannot commit any layer** here (`hcsshim::ActivateLayer 0x20 "file used by another process"`, reproduced even for a 100 MB dummy layer; not Defender/Search/SysMain). `docker run`, however, **does** honor `--cpu-count` under Hyper-V (verified `NPROC=32`) and commits fine — so `build.ps1` builds every **CPU-bound** stage via a generic run+commit path (`Invoke-RunCommitStage`): **media-core** (`Dockerfile.media-builder --target media-core` + `build-media-core-all.ps1`), **toolchain**/CPython (`Dockerfile.toolchain-builder` + `build-toolchain-all.ps1`), and the **media merge / GStreamer** stage (`Dockerfile.media-merge-builder` + `build-gstreamer-from-source.ps1`; the fan-in `COPY --from` stays a `docker build` since `docker run` can't `COPY --from`, but the GStreamer compile runs+commits). `-MediaCoreCpus` defaults to `[Environment]::ProcessorCount` (32 here) — but parallelism is **memory-bound**: `min(cpu-count, memGB/perJob)`, so ONNX stays `~j12` at 48 GB regardless of cores. `base`/`sdk` stay at 2 CPUs by design (network/install-bound). The `litert`/`tvm` aux branches also run+commit at `-MediaCoreCpus` (`Dockerfile.media-builder --target media-litert` + `build-litert-all.ps1`; `--target media-tvm` + `build-tvm-from-source.ps1`) — media-core is already committed then, so the full CPU/RAM budget is free (`~j2`→`~j19`, still memory-bound). All three branch builders are targets of the ONE consolidated `Dockerfile.media-builder`, and the schedule is strictly sequential (a former `-ConcurrentMedia` overlap mode was removed — overlapping starved the media-core long pole).

**Mid-chain failure recovery (run+commit):** a non-transient failure inside a
run+commit stage now PRESERVES the container (only transient retries clean it
up) and prints a resume recipe: `docker commit <container> <tag>-partial`, then
re-run the payload from the partial image with `-ResumeFrom '<stage>'`
(`Invoke-SourceBuildChain -StartAt` skips the completed stages), then commit to
the real tag. Do NOT `docker start` the failed container — that re-runs the
whole chain from scratch.

**Determinism:** the final stage uses the versions.env `APP_REF` pin by
default; pass `-LatestApp` to build.ps1 to resolve the app repo's newest
release tag at build time (the old always-on behavior). All local intermediate
tags come from the `$script:ImageTag` table / `Get-MediaBranchTag` at the top
of build.ps1 — never type a `local/kataglyphis:windows-*` literal elsewhere.

**Orchestr-ANT-ion app stage (`windows/Dockerfile.torch`):** the Windows mirror
of `linux/Dockerfile.torch`, a real chain stage between media and final
(`media -> torch -> final`): it assembles the app env at `APP_REF` on the
windows-media image (tag `local/kataglyphis:windows-torch`, app-venv
healthcheck), and `windows/Dockerfile` (final) builds FROM it — the assembly
logic lives in exactly one place. App-only iteration:
`.\windows\build.ps1 -Stages torch,final` (minutes, never a compile-chain
rebuild); `-TorchBaseImage ghcr.io/...:winamd64` iterates on the published
image on hosts without local chain images.

See `docs/windows-builds.md` § Build Commands for the full 5-stage Windows build sequence and `docs/windows-builds.md` § Stevedore Setup Fixes for post-install fixes.

### Running Linux containers (Rancher Desktop)

**Rancher Desktop is the preferred Linux-container runtime on this host**, and
the way to reproduce a Linux CI failure locally instead of guessing through
pipeline round trips. It does not replace the Windows lane — Windows containers
still go through Stevedore's `docker.exe`. Full details:
[`docs/rancher-desktop-linux-containers.md`](docs/rancher-desktop-linux-containers.md).

```pwsh
$nerdctl = "C:\Program Files\Rancher Desktop
esources
esources\win32in
erdctl.exe"
& $nerdctl --namespace default run --rm alpine:3.20 uname -a   # expect ...WSL2... x86_64 Linux
```

- **Use `nerdctl`, not `docker`.** Rancher defaults to the **containerd** engine,
  and `docker.exe` ships in the same directory while talking to a different
  engine entirely — `docker info` on this host reports `OSType=windows`, because
  the default context is the Windows lane. Both CLIs are present; only one is
  talking to Linux. (Switching Rancher's engine to `dockerd (moby)` flips this —
  pick one and stay with it.)
- Pass `--namespace default` explicitly. containerd namespaces are real
  isolation, so an image pulled into another namespace is genuinely "not found".
- **Linux builds use `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`,
  in CI *and* locally.** Not `:latest` — that tag went unrebuilt from 2026-04-16
  while the cross lane was refreshed (2026-07-20). Both publish amd64/arm64/
  riscv64. `Linux.yml` sets `CONTAINER_IMAGE` to `:latest-cross`; if a local run
  uses a different tag, reproducing a CI failure proves nothing. Neither tag is
  digest-pinned, so both still float.

### Triggering the opt-in CI lanes

The Linux x86 lane runs on every push; **Windows and ARM are opt-in per commit**.
Put `[build-win]` and/or `[build-arm]` in the pushed HEAD commit message. A green
tick without `[build-win]` says nothing about Windows - the workflow reports
`skipped`. Full detail:
[`docs/ci-build-triggers.md`](docs/ci-build-triggers.md).

```
git commit -m "build: check every target [build-win][build-arm]"
```

### Reading CI status with the GitHub CLI

**Check the pipeline after every push, and again before starting unrelated
work.** `gh` is installed (winget) and authenticated; see
[`docs/github-cli-pipeline-monitoring.md`](docs/github-cli-pipeline-monitoring.md).

```pwsh
gh run list --limit 10
gh run view <run-id> --json jobs --jq '.jobs[] | .name + " => " + .conclusion, (.steps[] | select(.conclusion=="failure") | "   FAILED STEP: " + .name)'
```

Three things that will otherwise cost you an hour:

- **A shell opened before the winget install cannot find `gh`.** Use a new
  shell, or `C:\Program Files\GitHub CLI\gh.exe`. Prefer PowerShell — Git
  Bash may not see winget's user PATH at all.
- **Never open with `gh run view --log-failed`.** It dumps every failed job's
  full log — one antlr4 `llvm-ar` line alone is ~15 KB — and grepping it for
  `error` mostly returns the runner's apt-get cleanup echoes. Ask which STEP
  failed first (command above), then grep the log for `SUMMARY:` (sanitizers)
  or `[  FAILED  ]` (GoogleTest).
- **`skipped` is not a pass.** Gated workflows (the Windows container build
  wants `[build-win]` in the commit message) report `skipped`, which reads as
  success at a glance.

Green local tests do not imply green CI: the Linux lane runs ASan/UBSan fuzzing
that the Windows dev box does not, so some bugs are only ever observable there.
Fix what failed — do not edit the workflow to silence it.

### Contributing Reusable Work Here

Consumer projects are expected to push reusable work upstream rather than keep
local copies (BeschleunigerBallett's AGENTS.md states this as a rule).
Wiring a NEW project to this repo — submodule, module resolver, Windows and
Linux container builds, the agentic loop, launchers, CI actions — is a
checklist in [`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md);
read it before hand-rolling any of that in a consumer.

When adding here:

- PowerShell 7 (pwsh) is the standard shell. All `.ps1` scripts require `#Requires -Version 7.0`. Windows containers use pwsh as the default SHELL.
- PowerShell scripts go in `windows/scripts/modules/` with `Export-ModuleMember`, and
  consumers resolve it ContainerHub-first with a vendored fallback.
- Document the **symptom**, not just the fix — platform traps here are found by
  recognising an error message, not by reading code.
- Keep functions free of consumer-specific paths, preset names and build
  directories; pass those in as parameters.

### Reusable Module: WindowsContainerBuild.Reuse

`windows/scripts/modules/WindowsContainerBuild.Reuse.psm1` implements the
container-reuse pattern so consumers do not each reinvent it:

- `Get-ReusableBuildContainer` - reuse/start/recreate a named build container,
  recreating it when the image ID changes. Returns whether an existing
  container was reused.
- `Copy-IntoBuildContainer` / `Copy-FromBuildContainer` - tar-pipe transfers
  with exclusion support (mandatory for deep paths; one over-long path aborts
  the whole transfer).
- `Remove-StaleContainerSources` - prune non-build directories from a reused
  workspace (tar extracts over the tree but never deletes).
- `Initialize-ContainerPwsh` - ensure PS 7 exists in a running container
  (scoop install fallback).
- `Test-BuildArtifactsDelivered` - throw when a green build produced no
  executables or the outbound transfer silently delivered nothing.
- `Resolve-DockerExe`, `Get-ContainerIsolationArgs`, `Test-ContainerBindMount`,
  `Remove-BuildContainerSafe` - docker discovery, isolation args, bind-mount
  probing, wcifs-tolerant removal.

Consumers resolve it ContainerHub-first with a vendored fallback (see
BeschleunigerBallett's `Scripts/Windows/Resolve-BuildModule.ps1`).

### Building Projects Inside the Windows Image (performance)

Consumers building large projects in this image should read
`docs/windows-container-build-performance.md`. Measured on a ~690-object C++23
modules project: **9.6 s ninja / 44 s wall** for a no-change incremental build
vs **352-484 s** when every build got a fresh container. Headlines:

- **Reuse ONE container** (recreate it when the image ID changes); stream
  sources in and only executables/logs out - never the intermediate build tree.
- **Two transports, both supported**: tar-pipe (no host setup) and bind mount
  (needs an elevated `fsutil` allow-list plus a reboot on a Dev Drive). The
  bind mount measured *slower* on that host - 32.7 s ninja vs 9.6 s - because
  the build tree then sits behind a filesystem filter. Host-specific: measure
  before choosing. Setup for both is in the doc.
- **sccache does not work on C++20/23 modules builds** - measured 0.00 % hit
  rate, 0 bytes stored. It remains useful for non-module codebases.
- **A named volume cannot be a CMake build directory** - configure fails with
  `ninja: error: loading 'build.ninja'`, even with a fresh volume.
- **Deep paths abort tar transfers.** One over-long path (Rust `cxxbridge`
  output) fails the whole transfer with `Can't create ...: Invalid argument`;
  exclude such subtrees.

### Windows Build Invariants (do not regress)

Load-bearing fixes — preserve them or builds slow down / ship broken. Details in `docs/windows-builds.md`.

- **pwsh (PowerShell 7) everywhere — owner policy 2026-08-04.** Every SHELL
  directive, every in-container exec, every script runs pwsh 7. The ONLY
  sanctioned Windows PowerShell 5.1 context is the single bootstrap RUN in
  `Dockerfile.base` that installs pwsh itself (nothing else may run in that
  window). Never add `powershell`/`powershell.exe` invocations or `cmd`
  SHELL directives; `cmd.exe /c` may appear only inside
  `Invoke-ShieldedNative` and the documented bespoke sites.
- **Never put DOUBLE QUOTES inside shell-form RUN lines in the Windows
  Dockerfiles.** The dockerfile frontend strips embedded `"` from the command
  string before it reaches the pwsh SHELL (three incidents on 2026-08-04:
  `"$env:TEMP\*"` became bare `$env:TEMP\*` → ParserError; the pwsh-written
  Directory.Build.props lost its XML attribute quotes → MSB4024). Use single
  quotes / `''`-doubling / string concatenation instead; XML attributes may
  legally use single quotes.
- **The "unreferenced" `windows/scripts` modules are EXTERNAL-CONSUMER API —
  never delete (owner decision 2026-08-04).** Flutter/CMake/CodeQL/MSIX/
  Slang/Vulkan/PerfBaseline/WasmOpt/AppRunner/ContainerBuild.Reuse/Uv/
  Build.Common/WebDav/Toolchain/Config/Formatting plus `scripts/rust/` and
  `scripts/python/` are the shared build framework other Kataglyphis repos
  consume (this repo IS the upstream). Repo-internal reference audits will
  flag them as dead — they are library surface. Keep them lint-clean; do not
  rename exported functions without checking external consumers. Their
  build-cache cost is zero (per-file bind mounts on the BK lane).

- **media-core builds via run+commit for CPU parallelism — never re-add `--isolation process`.** `docker build` is 2-CPU-capped here and process isolation **cannot commit layers** (`hcsshim::ActivateLayer 0x20`, reproduced even for a 100 MB dummy). media-core builds via `docker run --isolation hyperv --cpu-count $MediaCoreCpus` + `docker commit` (`Invoke-RunCommitStage`), which is the only way to get >2 CPUs *and* a committable image. Regression symptoms: `-j2` in `out\windows-build-logs\media-core.log`, or `ActivateLayer` on any commit. Full rationale: `docs/windows-builds.md` § Build isolation and CPU parallelism. **Before assuming this is still needed after a Docker/Windows/base-image upgrade, re-check with `windows/diagnostics/test-process-isolation-commit.ps1`** — if it reports `BUG GONE`, process isolation for `docker build` is usable again and the workaround can be retired (see § Re-testing process isolation on new versions).
- **Rust: scoop is the sole provider — never install rustup.** A toolchain-less rustup drops proxy shims into `CARGO_BIN` that shadow scoop's real `cargo`/`rustc` on PATH and fail with "no default toolchain configured". `setup-scoop-tools.ps1` installs no rustup, `setup-rust-toolchain.ps1` uses `scoop install main/rust`, and `Dockerfile.base` keeps `CARGO_BIN` off any rustup path. Do **not** re-add rustup to "fix" Rust.
- **Parallelism is memory-bounded, not CPU-bounded — and the defaults ARE the max.** `Get-BuildJobCount = min(ProcessorCount, MEMORY_LIMIT_GB / MemGBPerJob)`; inside a run+commit stage, `ProcessorCount` = `--cpu-count` (default = all host logical processors, 32 here). ONNX is tuned to ~4 GB/job (its CUDA/AVX-512 TUs are the RAM-heaviest; the `-j2` incremental retry absorbs the occasional OOM) → ~`-j10` at the auto-detected `-MediaMemoryGb 39` (`61 GB usable − 22 GB host reserve`). **Do not "optimize" by raising the memory cap or cutting `-HostReserveGb`**: the verified maximum envelope for this host (32 CPUs / 39 GB; media-core bottomed the host at 0.2 GB free and survived; 53 GB deadlocked it) is documented in `docs/windows-builds.md` § Maximum resource envelope — average CPU of ~35–45 % during compiles is the expected memory-bound signature, not a tuning failure. **You cannot reach `-j32` on ONNX**: 32 heavy TUs need ~128+ GB — RAM per job, not core count, is the ceiling; the only real speed levers are more physical RAM or an sccache remote.
- **Preserve committed line endings when editing a COPY'd `.psm1`/`.ps1`.** Media modules are LF, some build scripts CRLF; `core.autocrlf=true` plus some editors can flip a whole file, busting the media layer cache. `.gitattributes` pins these `-text`; after editing, confirm `git diff` shows only your change, not a whole-file EOL flip.
- **`versions.env` is the single source of truth.** `build.ps1` forwards every version as `--build-arg`; the smoke test and scripts derive expected values from it (e.g. clang major from `LLVM_RELEASE`, CMake URL from `CMAKE_VERSION`). Don't hardcode versions in scripts or Dockerfiles.
- **AVX-512/AMX flags NEVER go in global CXX flags (final polarity, settled 2026-08-03).** Globally, clang may emit AVX-512 anywhere — the in-tree protoc AND `onnxruntime.dll`'s static initializers both crashed with `STATUS_ILLEGAL_INSTRUCTION` at run/load time on the AVX2-only build host (the import assert catches this). But entirely without the flags, MLAS's arch TUs fail to COMPILE (clang-cl gates intrinsics behind target features; MSVC doesn't). The settled design: `build-onnx-from-source.ps1` appends `Get-WindowsX86Avx512Flags` per-TU to exactly the MLAS arch `FLAGS =` lines in build.ninja post-configure (runtime-dispatched kernels — the only code allowed to assume the features) and logs the tagged count. Don't "simplify" in either direction.
- **Windows images have a HARD 125-layer cap — the classic builder pays a layer PER INSTRUCTION, metadata included.** The final stage died with `max depth exceeded` on 2026-08-03 because the merge Dockerfile carried ~28 separate `ENV` lines. Rule: in any Dockerfile on the classic chain, consolidate ENV/metadata into single instructions (see `Dockerfile.media-merge-builder`'s one big ENV, layers 114→86). When adding stages/instructions, check headroom: `docker inspect <tag> --format '{{len .RootFS.Layers}}'` chain-wide; final currently sits ~108/125.
- **Windows stage scripts must end with an explicit `exit 0`.** `pwsh -File` propagates the LAST native command's exit code: a fully green LiteRT-LM build was declared failed because the final cleanup `rmdir` exited 145 (`ERROR_DIR_NOT_EMPTY`). Real failures throw (EAP=Stop + gates); reaching the end IS success — say so explicitly.
- **A missing stage artifact is a THROW, not a warning.** media-litert once "completed" without `litert_lm_main.exe` (configure had failed; the script only warned) and the degraded image would have shipped through merge/final. Every stage's terminal artifact check must throw (debug escape hatches env-gated, e.g. `LITERTLM_KEEP_BUILD_TREE`).
- **vcpkg ships zlib ONLY (protobuf removed 2026-08-03).** Nothing consumed vcpkg protobuf — every source build brings its own (ONNX `_deps`, LiteRT-LM's `protobuf_external` + downloaded version-matched protoc), and LiteRT-LM even had to hide vcpkg's protobuf headers to avoid version skew. Don't re-add it "for convenience"; it costs ~15 min of base build and creates header-leak hazards.
- **Python bindings plumbing is load-bearing (added 2026-07-13; full detail in `docs/windows-builds.md` § python coverage).** (1) The `sitecustomize.py` shim written by `Initialize-PythonPlatformTag` fixes clang-built CPython's win32 platform misreport (pip pulls 32-bit wheels without it) AND registers native DLL dirs (`os.add_dll_directory`; python ignores PATH for pyd deps) — never remove it. (2) OpenCV must keep `WITH_MSMF=OFF` **and** `WITH_OBSENSOR=OFF`: both hard-import Media Foundation, absent on Server Core — either ON makes videoio and the cv2 pyd unloadable. (3) Always `@()`-wrap `Save-PythonWheel` results: PS unwraps a 1-element array so `[0]` becomes the first *character* and pip once installed the PyPI package literally named `c`. (4) Binding asserts go through `Test-PythonImport` (cmd.exe-shielded): tvm writes warnings to stderr on successful imports, which raw `&` under EAP=Stop turns into false failures. (5) Wheels live at `C:\runtime\wheels` (`PYTHON_WHEELS`); the Orchestr-ANT-ion torch step resolves the app's LATEST tag per build and its wheel-smoke suite gates the final docker build. (6) PyAV is built from sdist against OUR FFmpeg (`setup.py --ffmpeg-dir`) — PyPI's `av` wheel is unloadable on Server Core (bundled avdevice imports desktop-only `AVICAP32.dll`); in headless code request software encoders by name (`mpeg4`) — the generic `h264` alias resolves to the hardware `h264_d3d12va`. (7) IREE (media-tvm branch, TVM→IREE chain) is a shallow-submodule git clone (release tarballs lack LLVM); its wheels come from the ninja build tree's synthesized `compiler/`+`runtime` pip dirs with `--no-build-isolation` — plain `pip wheel` of the repo would rebuild all of LLVM in an isolated tree. Native tools at `IREE_ROOT` (`C:\runtime\iree`); CUDA HAL/target need no nvcc (PTX via NVPTX, driver dlopens nvcuda.dll).

### TensorRT Setup (Optional)

TensorRT is **not downloaded automatically** — it requires accepting NVIDIA's EULA. To include TensorRT:

1. Download from https://developer.nvidia.com/tensorrt (e.g., `TensorRT-11.1.0.106.Windows10.x86_64.cuda-13.3.zip`)
2. Place the zip in `windows/downloads/`
3. It will be auto-detected during the `Dockerfile.nvidia` build

If no zip is found, the build skips TensorRT gracefully (CUDA + cuDNN still work). The ORT build script auto-detects `$env:TENSORRT_ROOT` and enables the TensorRT EP when available.

### Windows Build Notes

| Component | Generator | Compiler | Notes |
|-----------|-----------|----------|-------|
| CPython 3.14 | `PCbuild\build.bat` | ClangCL (v145→ClangCL via Directory.Build.props) | Requires VS ClangCL toolset |
| ONNX Runtime 1.28.0 | Ninja | clang-cl, lld-link | DirectML EP **enabled** (`USE_DML=ON`) via 3 clang-cl source patches applied by `Invoke-OnnxDmlClangClPatch` in `WindowsSourceBuild.Common.psm1` (DirectMLHelpers incomplete-type out-lining, `.##Z` token-paste, `Dispatch<size_t>`). CUDA + TensorRT EPs enabled when the NVIDIA layer is the parent (CUDA 13.3 provider, includes crt/ workaround for nvcc). Patches build.ninja for MSVC-only `/experimental:external`. Runs under VsDevCmd for MASM (`.asm` files). **AVX-512/AMX: per-TU only** — global flags OFF (they crashed protoc AND ort's own DLL init at runtime on AVX2 hosts); the build script appends them to MLAS's runtime-dispatched arch TUs in build.ninja post-configure (see Windows Build Invariants). 1.28's `ScopedResource<INVALID_HANDLE_VALUE,...>` template arg (rejected by clang-cl) is bridged by an inline post-configure dep patch. Needs ~4 GB RAM/job — media-core runs with `--memory ${MediaMemoryGb}g`. |
| ONNX GenAI 0.15.0 | CMake (Ninja) | clang-cl, lld-link | Source-built directly via CMake (bypasses `build.py` which always builds examples). DirectML **enabled** (`USE_DML=ON`) — compiled straight into `onnxruntime-genai.dll` with 0 source patches (`src/dml` is clang-clean; the `RESTORE_PACKAGES` DXC nuget dep is pruned since shaders are pre-generated DXIL; the x64 `D3D12Core.dll` is staged beside the DLL). CUDA **enabled** (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll`; CUDA and DML are independent CMake blocks so they coexist. `-DENABLE_TELEMETRY=OFF` (0.15 defaults MS 1DS telemetry ON; its bundled zlib also breaks clang-cl under -Werror). VsDevCmd environment loaded for MSVC STL headers. |
| OpenCV 5.x | Ninja | clang-cl, lld-link | Global SIMD flags: AVX2, SSSE3, SSE4.1/4.2. CUDA auto-detected. Custom `CMAKE_AR` path fix. |
| LiteRT 2.1.6 | Ninja | clang-cl, lld-link | GPU delegate enabled (Vulkan + OpenCL backends). XNNPACK enabled. CUDA paths exposed for external delegate. |
| LiteRT-LM 0.14.0 | Ninja | clang-cl, lld-link | On-device LLM inference. CUDA support enabled when detected. Links against LiteRT from previous stage. **v0.14.0's OSS CMake export was never functional upstream** — the build script bridges it with 5 condition-gated, self-retiring patches: (1) INTERFACE stubs for the CMake-referenced-but-deleted `constrained_decoding` component + the header-only `preprocessor`; (2) host protoc pinned 31.1 (== its internal protobuf 6.31.1 — see `bump:hold` in versions.env); (3) the `support/` tree grafted from LiteRT `v2.1.6` (the `// from @litert` shim includes) + staged via PROJECT_ROOT-anchored globs; (4) ~15 orphaned sources (new `logits_processor` subsystem, support impls, `multimodal_processor_helper`) injected into the engine lib, with miniaudio/kissfft/stb wired (upstream fetches them but connects nothing); (5) upstream's prebuilt-only `libGemmaModelConstraintProvider` import lib linked on the exe + its DLL (and z.dll/kissfft-float.dll) staged beside `litert_lm_main.exe`. Exe smoke-RUN gated (missing artifact = throw). |
| TVM 0.25.0 | Ninja | clang-cl, lld-link | Auto-detects CUDA/Vulkan/LLVM. Builds a Python wheel. VsDevCmd environment loaded for MSVC STL headers. |
| FFmpeg `master` | MSYS2 `make` (MSVC toolchain) | clang-cl via `--toolchain=msvc` | Source build from the `master` branch (default in `versions.env`). `--enable-libonnxruntime` links FFmpeg's DNN filter against the source-built ONNX Runtime so ONNX models can run inside `ffmpeg` filters (DNN filters ship with the backend; no separate `--enable-dnn` flag). Disabled x86asm. Falls back to a BtbN pre-built GPL binary if the source build fails (the sentinel env var `FFMPEG_SOURCE_BUILD=0` is then set). |
| GStreamer 1.29.2 | Meson | clang-cl | Downloaded as tarball + subproject wraps. CUDA auto-detected. |

### Windows Scripts

| Script | Location | Purpose |
|--------|----------|---------|
| `build-onnx-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl build with build.ninja patching and VsDevCmd wrapper |
| `build-onnx-genai-from-source.ps1` | `windows/scripts/` | Source-built directly via CMake+clang-cl (bypasses `build.py` which always builds examples). Loads VsDevCmd via `vswhere`, clones git tag, runs `cmake`/`ninja` directly. CUDA disabled at build time. |
| `build-opencv-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl with global SIMD flags and mlas `<cstring>` patch |
| `build-litert-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl; GPU delegate (Vulkan+OpenCL), XNNPACK, external CUDA delegate |
| `build-litert-lm-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl; on-device LLM inference; links against LiteRT from previous stage. Carries the v0.14.0 export-bridge patch stack (`[LiteRTLM-winfix export-stubs]` / `[LiteRTLM-winfix support-graft]` / v0.14 orphans + deps blocks) — all gated on the breakage so they self-retire when upstream's CMake catches up |
| `build-tvm-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl; auto-detects CUDA/Vulkan/LLVM; builds Python wheel; VsDevCmd for MSVC STL headers |
| `build-ffmpeg-from-source.ps1` | `windows/scripts/` | MSYS2 `make` with `--toolchain=msvc`; `--enable-libonnxruntime` links against the source-built ONNX Runtime. Loads `versions.env` via `load-versions.ps1` for centralized branch config. Falls back to BtbN pre-built GPL binary on source-build failure (`FFMPEG_SOURCE_BUILD=0` sentinel). |
| `build-gstreamer-from-source.ps1` | `windows/scripts/` | Meson+clang-cl with wrap pre-extraction; loads `versions.env` via `load-versions.ps1` |
| `WindowsSourceBuild.Common.psm1` | `windows/scripts/modules/` | Reusable build helpers: `Invoke-GitClone`, `Invoke-CmakeConfigure`, `Get-SourceBuildVersion`, `Get-CudaRoot`, `Enter-VsDevCmdEnvironment`, `Invoke-SourcePatch` (idempotent, reverse-check, patch.exe fallback), `Edit-CppKeywordAlternatives`, `Update-NinjaFile`, `Initialize-SourceBuildEnvironment`, `Initialize-ToolchainPythonEnvironment`, `Get-GpuEnvironment`, `Resolve-TensorRtRoot`, `Get-WindowsX86SimdFlags`, `Get-WindowsX86Avx512Flags` |
| `setup-vs.ps1` | `windows/scripts/` | Installs VS Build Tools 18 with ClangCL toolset |
| `setup-scoop-tools.ps1` | `windows/scripts/` | Installs LLVM, ninja, sccache, uv, Rust, Flutter, Vulkan SDK via Scoop |
| `setup-vcpkg.ps1` | `windows/scripts/` | Bootstraps vcpkg for Windows |
| `setup-rust-toolchain.ps1` | `windows/scripts/` | Installs/verifies the Rust toolchain (rustc, cargo) |
| `setup-cuda.ps1` | `windows/scripts/` | Installs CUDA 13.3 + cuDNN; includes post-install verification (headers/libs/DLLs) |
| `setup-tensorrt.ps1` | `windows/scripts/` | Auto-detects a TensorRT zip in `windows/downloads/` and installs it |
| `load-versions.ps1` | `windows/scripts/` | Reads `C:\temp\versions.env` (COPY'd from `linux/scripts/01-core/versions.env`) and sets matching process env vars so Windows build scripts consume the same canonical versions as Linux |
| `finalize-container.ps1` | `windows/scripts/` | Enables git long paths and sets `core.longpaths` in the final image |
| `verify-toolchain.ps1` | `windows/scripts/` | Verifies clang-cl, lld-link, WiX, Flutter are present after base setup |
| `healthcheck.ps1` | `windows/scripts/` | Docker `HEALTHCHECK` script — verifies ONNX Runtime DLL, FFmpeg, GStreamer, CMake, clang-cl |
| `smoke-test-container.ps1` | `windows/scripts/` | Comprehensive container validation (18 test categories) |

For detailed build commands, see `docs/windows-builds.md`.

### Orchestrator Stage Selection

```bash
# Resume mid-chain (e.g., after rebuilding compiler)
bash linux/scripts/build-cross-chain.sh --from-stage sdk --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Build only one stage for one architecture
bash linux/scripts/build-cross-chain.sh --only media --target-arches arm64 --log-dir ./out/build-logs

# Build per-arch stages in parallel (faster on multi-core machines)
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --parallel-archs --log-dir ./out/build-logs

# Build a single cross stage standalone (with digest-pinned parent when --push)
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push --log-dir ./out/build-logs
```

### Runtime Helpers

```bash
# Build and push per-arch wrappers + manifest
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 \
  --artifact-image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-android \
  --push

# Build local artifacts only (no push)
bash linux/scripts/build-runtime-artifacts.sh \
  --image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64

# Dry-run: print what would be built without executing
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --dry-run

# Manifest repair (rebuild manifest from existing per-arch wrappers)
nerdctl manifest rm "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" >/dev/null 2>&1 || true
nerdctl manifest create "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-amd64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-riscv64"
nerdctl manifest push --purge "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"

# Or use the helper: rebuild just the manifest (no image rebuilds)
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --manifest-only --push-manifest

# Shorthand: --repair is an alias for --manifest-only
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --repair --push-manifest
```

---

## Build Workflow

```
build-cross-chain.sh → base → compiler → sdk → media → android → runtime → manifest
```

Stages 1-5 run on `linux/amd64`. Stage 6 (runtime) runs on the target platform per architecture (QEMU/binfmt for foreign arches), delegating to `build-runtime-manifest.sh`. Each stage's registry digest is pinned and fed to the next as `--build-arg BASE_IMAGE=<repo>@sha256:<digest>` to prevent stale cache reuse. The stage graph is defined in `linux/scripts/01-core/stage-defs.sh`. See `docs/linux-cross-builds.md` for the full pipeline details.

The **Windows lane** follows a separate staged build (`base → [nvidia] → toolchain → media → final`) driven by `windows/build.ps1`, which uses Stevedore's `docker.exe` for builds (`nerdctl build` has broken DNS on Windows). The `windows-sdk` tag is either a plain re-tag of `windows-base` (CPU lane, default) or the NVIDIA GPU stage `Dockerfile.nvidia` (`-Gpu` switch) for a CUDA-enabled image. See `docs/windows-builds.md` § Build Commands for the full build sequence and prerequisites.

### Prerequisites

- **nerdctl** with BuildKit backend
- **QEMU/binfmt** for foreign-architecture runtime builds. **Required before EVERY build** (registration is lost after host reboot):
  ```bash
  nerdctl run --rm --privileged tonistiigi/binfmt --install all
  ```
  Without this, riscv64 and arm64 builds under QEMU will fail with `exec format error` or silent exit code 1.
- **Registry access** (GHCR) for pushing intermediate and final images
- **Disk space**: ~50GB+ for full cross chain with all architectures
- **Python 3** for digest resolution (`registry-digest.py`)

### Windows Prerequisites (see `docs/windows-builds.md` § Prerequisites)

- **Stevedore** (`winget install stevedore` or `choco install stevedore`) — provides nerdctl + containerd for Windows Containers
- **Reboot** after Stevedore install to enable the Windows Containers feature
- **Docker Desktop or Rancher Desktop** can also be used with `docker` commands (swap `nerdctl` → `docker` in build commands)
- **DNS workaround**: Windows `nerdctl build` has broken DNS in BuildKit containers. Use Stevedore's bundled `docker.exe` for **both builds and runs**: `"D:\Stevedore\bin\docker.exe" build` / `... run --isolation process`. `nerdctl run` also fails on this host — it needs the Windows CNI `nat` plugin (not installed); `docker.exe` provides NAT networking natively. Run with `--isolation process` for the host's full CPU count (Hyper-V isolation is capped at 2 CPUs). See `docs/windows-builds.md` § Running the Image.

### Stevedore Fixes After Install

Apply the post-install fixes documented in `docs/windows-builds.md` § Stevedore Setup Fixes (Defender exclusions, daemon.json cleanup, default runtime change, verification). Those instructions are the canonical source — keep them in sync instead of duplicating here.

### Supported Platforms

| Component | Build platform | Target platforms |
|-----------|---------------|------------------|
| Cross lane (stages 1-5) | `linux/amd64` | `amd64`, `arm64`, `riscv64` (cross-compiled) |
| Runtime lane (stage 6) | Native or QEMU | `linux/amd64`, `linux/arm64`, `linux/riscv64` |
| Final manifest | N/A | Multi-arch: `amd64`, `arm64`, `riscv64` |
| Windows lane | `windows/amd64` | `windows/amd64` (native Windows Containers) |

### Expected Outputs

After a successful `build-cross-chain.sh` run:
- All cross-lane intermediate images pushed to GHCR
- Per-architecture wrapper images (`:latest-cross-<arch>`) pushed to GHCR
- Multi-arch manifest (`:latest-cross`) pushed to GHCR

---

## Repo Map

```
linux/scripts/
├── 01-core/             shared utilities (48 modules: versions.env, logging, platform, cross-env, cross-gcc, cross-meson, cross-apt, compiler-resolution, tag-naming, stage-defs, digest-pinning, build-helpers, cli-parsers, …)
├── 02-toolchain/        GCC, LLVM, Rust, Python, CMake, Vulkan builds
├── 03-media/            media library build scripts
│   ├── core/common.sh   single DRY bootstrap — sourced by every media script
│   ├── build/           per-library build scripts
│   │   ├── onnxruntime/   ONNX Runtime + GenAI (build/ steps, runtime/ pkgconfig, android/)
│   │   ├── litert/        LiteRT + TFLite C API (Critical Fix #2: abseil span.h copy in build-litert.sh)
│   │   ├── opencv/        OpenCV 5.x
│   │   ├── ffmpeg/        FFmpeg (build-ffmpeg.sh has fixed host compiler wrapper)
│   │   ├── gstreamer/     GStreamer monorepo (common/ has patch-gstreamer-sources.sh — Critical Fix #5)
│   │   └── libcamera/     libcamera
│   └── runtime/         artifact collection, runtime config, wheel repair, verification, media-env.sh (canonical ENV)
├── 04-runtime/          entrypoint + env scripts (gstreamer-env.sh, etc.)
├── 05-frameworks/       TVM, Torch, Flutter
└── 06-packaging/        assembly + smoke tests (smoke-media.sh, smoke-common.sh)
```

Top-level orchestrators: `build-cross-chain.sh`, `build-cross-compiler.sh`, `build-cross-stage.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`. Verification: `verify-cross-chain.sh`, `verify-critical-fixes.sh`, `verify-artifact-copy-parity.sh`.

Beyond `linux/scripts/`:

```
linux/scripts/lib/       consumer-facing bash libraries: agentic-loop.sh,
                         app-runner.sh (generic app launcher: arg parse, exe
                         discovery, LD_LIBRARY_PATH, per-profile hooks)
windows/scripts/         Windows lane: setup-*.ps1, build-*-from-source.ps1,
                         cargo-retry.cmd (transient file-lock retry wrapper),
                         certificates/ (MSIX cert generation + WebDAV
                         download_webdav_files.py — see its README.md),
                         modules/*.psm1 (reusable PS modules: SourceBuild,
                         Build.Common, ContainerBuild.Reuse, AgenticLoop,
                         CMake, Config, Formatting, Msix.{Common,Signing},
                         WebDav, Uv, Scripts.Shared, Toolchain, CodeQL,
                         ContainerImage, Flutter, Installer),
                         tests/ (harness + suites), shims/, diagnostics/
shared/agentic-loop/     cross-platform data: prompts/*.md — the single source
                         for the default planner/refactor-planner/executor task
                         prompts read by BOTH WindowsAgenticLoop.Common.psm1
                         and linux/scripts/lib/agentic-loop.sh
.github/actions/         composite actions consumers call @main:
                         cleanup-disk-space (Windows runners),
                         run-in-linux-container, run-in-windows-container
                         (see .github/actions/README.md)
```

`out/`: generated build artifacts (OCI layouts, rootfs exports). Excluded from Docker context via `.dockerignore`.

## Code Organization (key shared utilities)

- **Architecture resolution:** `platform.sh` → `canonical_target_arch()`, `canonical_resolve_arch()`. Single source of truth — never use ad-hoc `dpkg`/`uname -m`.
- **Architecture list resolution:** `artifact-common.sh` → `resolve_arch_list()`. Normalizes `TARGET_ARCHES` from canonical name + aliases with fallback. Use instead of 4-level fallback chains.
- **Dry-run guard:** `build-helpers.sh` → `is_dry_run()`, `_bool_truthy()`. Use instead of `[ "${DRY_RUN:-0}" -eq 1 ]`.
- **Module loading:** `modules.sh` → `source_modules_framework()`. Bootstrap pattern for sourcing 01-core.
- **Media bootstrap:** `03-media/core/common.sh` → `media_common_init <script_dir>`. Single DRY entry that sources the 01-core module framework. Every media build script sources this instead of duplicating a preamble block. Backward-compatible alias: `media_build_preamble_init`.
- **CC validation:** `validate-compilers.sh` → `_validate_cc_target()` (dumpmachine/ELF/cc1/link smoke).
- **Cross-chain tags:** `tag-naming.sh` → `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag()`, `cross_media_tag()`, `cross_android_tag()`, runtime tag functions. Never construct tags manually.
- **Stage graph:** `stage-defs.sh` → `CROSS_STAGE_ORDER` (base→compiler→sdk→media→android→runtime), `RUNTIME_STAGE_ORDER` (base→package→wrapper). Pin init: `cross_stage_init_pins()`. Validation: `cross_stage_validate_graph()`. Cross→runtime handoff: `cross_stage_ensure_parent_available()`.
- **Chain verification:** `chain-verify.sh` → `verify_cross_chain_staleness()`, `describe_cross_chain()`.
- **Cross-stage build:** `cross-stage-build.sh` → `cross_stage_run()`, `cross_stage_build_and_push()`, `cross_stage_build_local()`, `cross_stage_resolve_parent_pin()`, `cross_stage_assemble_runtime_helper_args()`.
- **Runtime flow init:** `runtime-flow-common.sh` → `init_runtime_flow_defaults()` (sourced directly by the two runtime scripts).
- **Retry logic:** `logging.sh` → `retry <max> <sleep> <desc> <cmd...>`.
- **Mirror args:** `build-helpers.sh` → `append_mirror_build_args_from_env()`.
- **Version forwarding:** `version-forwarding.sh` → `append_version_build_args()` (auto-discovers from `versions.env`).
- **CMake cache/linker:** `cmake-cache-linker.sh` → `append_cmake_cache_linker_args <array_ref>`. Sourced by `03-media/core/common.sh` automatically.
- **Install deps preamble:** `cross-apt.sh` → `install_deps_preamble [packages...]`.
- **Media ENV reference:** `03-media/runtime/media-env.sh` is the canonical definition of PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH/GI_TYPELIB_PATH. `Dockerfile.media` and `Dockerfile.package` ENV blocks must stay in sync with this file.
- **Media artifact verification:** `03-media/runtime/verify-media-artifacts.sh` validates each media build stage produced output. Called from `Dockerfile.media` RUN steps after every library build. Stages: `onnxruntime-cpu`, `onnxruntime-genai`, `onnxruntime-gpu`, `onnxruntime-pkgconfig`, `litert`, `litert-headers`, `opencv`, `opencv-core`, `ffmpeg`, `gstreamer`, `libcamera`, `app-wheels`, `media-inputs`.
- **Runtime stage elements:** `Dockerfile.torch` final stage is canonical for COPY of runtime scripts, WORKDIR, VOLUME, ENTRYPOINT, CMD, HEALTHCHECK, kataglyphis user, OCI labels.
- **Builder functions:** `run_nerdctl_build()` is the canonical nerdctl build wrapper (`BUILDKIT_HOST` support). Use instead of ad hoc `nerdctl build`.

### Module Loading Order

`artifact-common.sh` sources 01-core modules in dependency order:
1. `common.sh` 2. `tag-naming.sh` 3. `stage-defs.sh` 4. `digest-pinning.sh` 5. `chain-verify.sh` 6. `build-helpers.sh` 7. `cross-stage-build.sh` 8. `context-management.sh` 9. `version-forwarding.sh` 10. `cli-parsers.sh` 11. `runtime-build-fns.sh` 12. `compiler-resolution.sh` 13. `parallel-loop.sh`.

`runtime-flow-common.sh` is sourced directly by `build-runtime-artifacts.sh` and `build-runtime-manifest.sh` (after `artifact-common.sh`).

## Cross Chain Stage Handoff (do not regress)

The cross lane is a sequence of separate `nerdctl build` invocations where each
stage does `FROM ${BASE_IMAGE}`: `base → compiler → sdk → media → android →
package → torch → wrapper → manifest`. The base-image handoff MUST NOT rely on a
bare mutable tag, or a stage can silently consume a STALE locally-cached image.

`--output type=image,name=...,push=true` pushes the new digest but does not
reliably refresh the local containerd tag; BuildKit's default `FROM` prefers an
already-present local image. So rebuilding `media` then building `android` can
quietly reuse the old `media`.

Rules:

1. When ANY base image in the registry tag hierarchy is replaced, rebuild every
   downstream image from the replaced stage, OR verify the downstream images
   already contain the new content (e.g. check `/opt/gcc-16.1.0-native-arm64`
   exists in the pinned sdk digest).
2. `--from-stage` only controls where execution starts; it does NOT update the
   base image of the first stage. If the previous stage's tag was built from a
   stale upstream, your rebuild inherits that staleness.
3. After pushing a rebuilt compiler image, run from `--from-stage sdk` (not
   `media`) so the sdk is built from the new compiler.
4. Do NOT use `--from-stage android` unless you verified the media tag already
   contains the compiler's content (e.g. native GCC directories).
5. Prefer `linux/scripts/build-cross-chain.sh` — it captures each stage's
   registry digest after push and feeds it to the next as
   `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`, making stale reuse
   structurally impossible. Supports `--target-arches`, `--from-stage`,
   `--to-stage`, `--only`.
6. When driving manual `nerdctl` loops, pass `--pull=true` on every stage that
   consumes a `BASE_IMAGE` tag (weaker defense; digest pinning preferred).
7. Capture pinnable digests with `nerdctl manifest inspect --verbose <tag>` →
   `.Descriptor.digest` (the `registry_pin_ref` helper in
   `01-core/digest-pinning.sh`). Do NOT use `RepoDigests`: BuildKit pushes a
   converted `docker.v2+json` manifest whose digest differs from the local OCI
   manifest and is not registry-resolvable.

## Five Critical Fixes To Maintain

Always preserve these. The canonical reference is `docs/linux-cross-builds.md` § "Five Critical Fixes"; CI validates them via `linux/scripts/verify-critical-fixes.sh`.

## Linux Build Rules

- Use `nerdctl` first on this host. `buildctl`/`ctr` commonly fail with permission errors.
- Keep both the QEMU/binfmt multi-platform lane and the cross-build lane working.
- `build-cross-compiler.sh` builds one `linux/amd64` compiler image with cross toolchains for all arches. Not a multi-arch compiler manifest.
- Do not remove LLVM/Clang features to make foreign-arch builds pass. Foreign-arch runtime images must keep source-built `clang 22.1.8` (not Ubuntu `clang 22.1.2`). Source-built `gcc 16.1.0` at `/opt/gcc-16.1.0` is the default `cc`/`c++` on all arches. On `arm64`/`riscv64`, GCC is cross-compiled (Canadian cross) and swapped in at the Android stage via `Dockerfile.android`.
- Preserve optional runtime payloads and LLVM normalization in `Dockerfile.package`. Do not drop `/usr/local/lib/onnxruntime-*`, LiteRT/TensorFlow headers, pkg-config files, or `/usr/local/llvm-target` handling.

## Dockerfile.media BuildKit Strategy

`Dockerfile.media` uses a parallel multi-stage DAG (BuildKit runs independent stages concurrently):

```
base ─┬─ onnxruntime ───────┐
      ├─ litert ────────────┤
      ├─ opencv ────────────┼─ media-inputs ─ gstreamer ─ libcamera ─ final
      ├─ ffmpeg ────────────┤
      └─ app-wheelhouse ────┘
```

- `--mount=type=cache` (apt/ccache/sccache/uv/pip/cargo) keyed per-arch via `id=...-${TARGETARCH}`, `sharing=locked`.
- `--mount=type=bind,readonly` for per-library build scripts — no COPY layer, so editing one library's scripts invalidates only that RUN, not downstream layers.
- `--mount=type=tmpfs` for `/tmp` scratch (no layer bloat).
- `COPY --link` for layer-parallel copying from independent build stages.
- Shared/common files (`core/common.sh`, `activate-cross-python.sh`, `verify-media-artifacts.sh`, 01-core helpers) are COPY'd in the `base` stage (rarely change → stable cache).
- Runtime scripts are COPY'd only in the `final` stage (must persist in the published image; build scripts are NOT shipped).

## Push And Publish Rules

- `build-runtime-artifacts.sh --push` pushes only final per-arch wrapper images.
- `build-runtime-manifest.sh --push` pushes wrappers + final manifest.
- `--push-all` only when explicitly requested (publishes `base`/`package` intermediates).
- Final cross release: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.
- Before rebuilding expensive foreign-arch wrappers, inspect remote tags with `nerdctl manifest inspect`. If wrappers exist remotely, recreate the manifest directly instead of rebuilding.

## Validation

- **`bash linux/scripts/preflight.sh` is the single source of the no-build gate
  list** (shellcheck, script COPY coverage, critical fixes, patch integrity,
  artifact parity, ARG consistency, version snapshot, mirror consistency,
  runtime paths, Dockerfile lint via hadolint, workflow lint via actionlint,
  android stage parity, linux script unit tests). CI workflows and
  `.githooks/pre-commit` run SUBSETS of it via `PREFLIGHT_ONLY=<slugs>` /
  `PREFLIGHT_SKIP=<slugs>` — never copy the check list into a new caller.
  On Windows hosts: `PREFLIGHT_PYTHON="uv run --no-project python" bash linux/scripts/preflight.sh`.
- PowerShell gate: `pwsh -File windows/scripts/Invoke-Lint.ps1` +
  `pwsh -File windows/scripts/tests/Invoke-Tests.ps1` (also run in CI by
  `.github/workflows/windows-scripts.yml` on windows-latest).
- For runtime verification, check inside a container or inspect raw symlink targets. Do not use `readlink -f` against `out/linux-runtime/*/rootfs` (absolute symlinks resolve against host root).
- Confirm on all arches: `clang --version` reports `22.1.8`; `cc -dumpmachine` matches arch; `gcc --version` reports `16.1.0`; symlinks `cc/c++/gcc/g++ → /opt/gcc-16.1.0/bin/*`; `clang → /usr/local/llvm-target/bin/clang`; optional runtime payloads present.
- Use the `wrapper-smoke` target (see `docs/linux-build-basics.md`) for cheaper packaging validation before large publish runs.

## Common Failure Modes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `exec format error` | QEMU/binfmt not registered after host reboot | `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` |
| `no space left on device` | Disk full from cached images/artifacts | `nerdctl system prune -a -f && rm -rf out/local-*` |
| Stale downstream images | Base image rebuilt but downstream not refreshed | Use `--verify-chain` or rebuild from replaced stage |
| `registry_pin_ref` fails on fresh push | Registry hasn't propagated the new manifest | Now uses `retry()` with 5 attempts; wait a few seconds and retry |
| Terminal freeze during long build | Build output overwhelms terminal | Use `setsid` / `disown` for very long builds |
| nerdctl DNS failure in build | BuildKit container can't resolve hostnames on Windows without a CNI nat CONFIG (`--dns` and `--network host` unsupported) | Fixed 2026-08-03: install `0-containerd-nat.conf` into `C:\Program Files\containerd\cni\conf\` (nat.exe was already in ...\cni\bin) — buildkitd RUN steps then have full NAT+DNS. docker.exe remains the fallback. |
| `nerdctl ...`: `cannot access containerd socket ... Zugriff verweigert` (non-admin) | containerd's pipe is admin-only (its service lacks `--group docker-users`, unlike dockerd/buildkitd) | Use `docker.exe` (dockerd pipe) or `buildctl` (buildkitd pipe) — both are docker-users-accessible. nerdctl needs an elevated shell. |
| BK RUN steps: `The remote name could not be resolved` (and even direct-IP queries time out) | **CNI nat subnet drift**: dockerd restarts recreate the `nat` HNS network on a new subnet; the static CNI conf then hands out IPs whose gateway doesn't exist | Update `ipam.subnet`/`GW` in `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` to match the live `vEthernet (nat)` adapter (`ipconfig`), then `Restart-Service buildkitd -Force` (admin). `build-buildkit.ps1`'s preflight guard detects this and prints the fix. |
| BK compile step freezes silently minutes in (0 % CPU, zombie ninja, no log growth) right after `[output clipped, log limit 2MiB reached]` | **buildkitd step-log clip deadlock** (Windows buildkitd v0.32): after the 2 MiB clip the stdio pipe stops being drained; every process blocks on its next write. ONNX's warning flood hits the clip in ~3 min | Set service env `BUILDKIT_STEP_LOG_MAX_SIZE=-1` + `BUILDKIT_STEP_LOG_MAX_SPEED=-1` on buildkitd (registry MultiString `Environment`), `Restart-Service buildkitd -Force`. See docs/windows-builds.md § Getting it going, step 3b. |
| ANY weird hcsshim failure on the BK lane: `ExportLayer 0x3` (path not found) at finalize, spawn flakes (`'cmd.exe' is not recognized`), `ExportLayer 0x70` (disk full) | **Disk exhaustion in costume** — the bk image generations stack 30–40 GB per rebuild cycle; only 0x70 names the disease (all three hit on 2026-08-03) | Check free disk FIRST. `buildctl prune --all` + `docker image prune -f` (non-admin); bk-* image generations need admin. Full playbook: docs/windows-builds.md § Store GC. |
| BK lane, disk is FINE: `failed to reimport snapshot: hcsshim::ExportLayer ... (0x3)` at finalize of a heavy media layer (GenAI/OpenCV/TVM/GStreamer) — deterministic, every fresh snapshot, both finalize paths, survives host reboot | **Platform defect: the container loses its HCS shutdown notification** (containerd debug log 2026-08-04: shutdown times out 30 s, terminate times out 30 s, shim cleanup throws `HCS_E_INVALID_STATE`, the scratch is never released, every later finalize of that snapshot 0x3s). All silo processes DO exit — only the vmcompute→hcsshim callback is lost. A ~20-probe bisection falsified everything content-shaped (poisoned cache, depth, parent, file/dir content with fully-emptied diff, daemons, vctip, bare .NET CLR, pending-deletes, tree deletion, quiesce/service-stop tails, host reboot). Calm exits (ONNX ninja, cpython, LiteRT, torch, trivial layers) never trip it. | **SOLVED via the warm/materialize pattern** (BK lane green end-to-end, `bk-winamd64`): heavy builds run in a WARM solve with no exporter (BuildKit finalizes lazily — no exporter + no child step = never finalized = defect never fires), artifacts leave as one tar over the sccache dufs WebDAV (`Export-BuildHandoff`), and a calm materialize solve imports + exports the image (`Import-BuildHandoff`). Full pattern + transport pitfalls (no cache mounts, System32 tar/curl, parent-dir pre-create, per-stage ARG): docs/windows-builds.md § BuildKit/containerd lane. Classic docker lane (run+commit) was never affected. |
| `hcsshim::ActivateLayer failed (0x20)` during build | Windows Defender scanning new layer files + containerd snapshot contention | Exclude `C:\ProgramData\containerd`, `C:\ProgramData\nerdctl` from Windows Defender. Or use `docker.exe` instead of `nerdctl` for builds (Docker's layer manager is more resilient). |
| Stevedore docker build: `runtime "com.docker.hcsshim.v1" binary not installed` | Service default runtime uses `hcsshim-v1` shim which isn't shipped | Change to `runhcs-v1`: `sc config stevedore binPath="..." --default-runtime=io.containerd.runhcs.v1"` (see docs/windows-builds.md § Fix 2) |
| Stevedore docker build: `failed to create TTRPC connection` | Shim binary mismatch (runhcs copied as hcsshim) | Remove the bad shim copy: `del "C:\Program Files\Stevedore\bin\containerd-shim-hcsshim-v1.exe"`. Apply Fix 2 instead. |
| Stevedore service won't start (1053 timeout) | Windows Defender blocking dockerd.exe OR stale daemon.json from Docker Desktop | `Add-MpPreference -ExclusionProcess "dockerd.exe"` AND delete `C:\ProgramData\docker\config\daemon.json` |
| `error getting credentials - err: exit status 1` | wincred credential helper fails because dockerd runs as SYSTEM without interactive session | OK to ignore for public images (MCR, GitHub). Use `nerdctl pull` instead for images that need auth, or set `"credsStore":""` in docker config. |
| `failed to extract layer ... failed to find link target` when pulling servercore | containerd windows snapshotter can't handle certain Windows reparse points in the layer | Use `docker.exe pull` instead of `nerdctl pull`. Docker Engine's layer extraction handles reparse points correctly. |
| Windows media build crawls; `Building with ninja -j2` in `media-core.log` | media-core fell back to a 2-CPU `docker build` instead of the run+commit path | Ensure `Invoke-RunCommitStage` runs (`docker run --cpu-count $MediaCoreCpus`); `docker build` is 2-CPU-capped here and no flag raises it (§ Windows Build Invariants). |
| `hcsshim::ActivateLayer failed ... 0x20 "file used by another process"` on commit | `--isolation process` was used for a `docker build` — it cannot commit layers on this host | Never pass `--isolation process`. Use Hyper-V (the default) for `docker build`; for CPUs use the `docker run --cpu-count N` + `docker commit` path. Not Defender/Search/SysMain (all ruled out). |
| Rust smoke test fails: "rustup could not choose a version of cargo/rustc" | A toolchain-less rustup shadowing scoop's real Rust on PATH via `CARGO_BIN` | Do not install rustup; scoop is the sole Rust provider. Keep `CARGO_BIN` off any rustup path (§ Windows Build Invariants). |

---

## Version Bumping

**Single source of truth: `linux/scripts/01-core/versions.env`.** Update it first.

**Automated sweep: `python3 docs/scripts/bump_versions.py`** (report), `--write` (safe tier), `--write-all` (report tier + paired checksum extras — extras MUST be applied together with the version, see the CUDA-hash incident note in the script). Three tiers: SAFE / REPORT / MANUAL, plus a self-audit for unclassified keys.

**`bump:hold` marker:** a comment line containing `bump:hold <reason>` directly above a `KEY=` in versions.env blocks ALL automated writes for that key (reported as `HELD`). Use it for pins that are **slaved to another project's internals**, not independent software — e.g. `PROTOC_VERSION`/`PROTOBUF_VERSION` must match LiteRT-LM's internal `protobuf.cmake` pin (auto-bumping protoc to latest shipped gencode its runtime `#error`s on, 2026-08-03). Re-derive held keys manually when their master pin moves.

`common.sh` and `artifact-common.sh` source `versions.env` at load time with `set -a`. Per-Dockerfile ARG defaults are safety nets and should match.

After changing versions:
1. `python3 docs/scripts/sync_versions.py --write` (one pass now syncs Dockerfile
   ARGs BEFORE regenerating the snapshot — no second pass needed; `--check` to verify)
2. `python3 docs/scripts/generate-website-licenses.py --write` (regenerate website /openSourceLicenses page)
3. **Refresh the matching `*_SHA256` pins in versions.env** (pwsh zip / git installer /
   nuget / CUDA / cuDNN / ollama / binaryen / hadolint / actionlint — each key's comment
   documents its fetch command; GitHub releases expose per-asset digests on
   `https://api.github.com/repos/<owner>/<repo>/releases/tags/<tag>`)
4. Update `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, `docs/project-info.md`, and `AGENTS.md`
5. Verify ARG consistency: `bash linux/scripts/01-core/verify-arg-consistency.sh`
   (also enforces that every versions.env-named ARG has a safety-net default in its file)
6. Rebuild affected stages (base→tooling, compiler→sdk, media→libs, android→SDK/NDK)

Windows layer-cost note: `windows/Dockerfile.base` declares `VULKAN_VERSION`/
`CMAKE_VERSION` just above the scoop step (NOT at the top) so bumping them
re-runs scoop, never the hours-long VS Build Tools layer. Keep new version ARGs
below the VS layer unless they are consumed above it.

GPU constraints: when bumping CUDA/ROCm/MIGraphX, verify driver requirements and that `UBUNTU_CODENAME` ARG in `Dockerfile.amd` matches a supported Ubuntu codename (default `resolute`/26.04). MIGraphX packages currently come from the AMD ROCm noble (24.04) repo since no resolute builds exist yet.

## Development Rules

- Every script: `#!/usr/bin/env bash` + `set -euo pipefail`. Use `run()`/`run_quiet()` from `build-helpers.sh`.
- Source `artifact-common.sh` for shared utilities. Use `parse_shared_orchestrator_args()`/`parse_shared_runtime_args()`.
- Call `cross_stage_init_pins()` before the build loop.
- Use centralized helpers: `resolve_arch_list()`, `is_dry_run()`, `append_mirror_build_args_from_env()`, `append_version_build_args()`, `normalize_target_arches()`.
- New OS packages → `Dockerfile.base`. Compiler changes → `Dockerfile.toolchain`. SDK/frameworks → `Dockerfile.sdk`. Media libs → `Dockerfile.media` + `03-media/build/`. Android → `Dockerfile.android`. GPU → `Dockerfile.nvidia`/`Dockerfile.amd`.
- New architecture: add to `CROSS_DEFAULT_ARCHES` in `versions.env`, update cross-target lists, add triple mapping in `platform.sh`, add checksums in `versions.env`, verify QEMU/binfmt.

## `.dockerignore` Guardrail

**Never exclude the `linux/` directory from `.dockerignore`.** The Linux Dockerfiles
(`Dockerfile.base`, `Dockerfile.package`, `Dockerfile.torch`, etc.) use `COPY`
instructions that reference files under `linux/` (scripts, Vulkan manifests,
smoke-test scripts, etc.). A blanket `linux/` exclusion breaks every COPY step
with `failed to compute cache key: ... not found`.

Windows build contexts are sufficiently small already (they only reference
`windows/`). If the Windows lane needs a smaller context, add specific excludes
for large directories under `linux/` (e.g., `linux/out/`, `linux/build/`) rather
than blocking `linux/` itself.

`linux/.dockerignore` is a SEPARATE allowlist for builds whose context is
`linux/` (the compose-built webserver image): it admits only
`webserver/{nginx.conf,entrypoint.sh,dist/,license-assets/}`. `webserver/dist`
must stay INCLUDED there — the root file's `**/dist/` exclusion applies only to
root-context builds and must not be copied over.

## Reusable Sphinx Theme Package

The shared theme now lives in the **Kataglyphis-DocumANTation** repo, vendored here
as a submodule at `external/Kataglyphis-DocumANTation`. `requirements.txt` installs it
editable (`-e ./external/Kataglyphis-DocumANTation/sphinx-kataglyphis-theme`), so
`docs/conf.py` just imports it:

```python
from sphinx_kataglyphis import setup_theme
setup_theme(globals(), repository_url="https://github.com/org/repo")
```

`setup_theme()` provides all shared Sphinx config and loads the canonical CSS from the
package's `_static/` directory.

**For other projects** — add the DocumANTation submodule and the same `-e` line to
their `requirements.txt`, then use the `conf.py` snippet above.

The canonical CSS lives in the submodule at
`external/Kataglyphis-DocumANTation/sphinx-kataglyphis-theme/sphinx_kataglyphis/_static/css/custom.css`
— edit it **in the DocumANTation repo** to change the global look. The project's own
`docs/_static/css/` can hold additional per-project overrides.

## Documentation Maintenance

- **Pre-commit hooks:** Run `git config core.hooksPath .githooks` once after clone. The `.githooks/pre-commit` script runs version-staleness checks, arg consistency, and shell syntax before each commit — the same checks CI enforces.
- If Dockerfiles or Linux helpers change, update `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, `docs/project-info.md`.
- If Windows Dockerfiles/scripts change, update `docs/windows-builds.md`.
- If version defaults change, run `python3 docs/scripts/sync_versions.py --write` then `python3 docs/scripts/generate-website-licenses.py --write`.
- The canonical `custom.css` lives in the DocumANTation submodule at `external/Kataglyphis-DocumANTation/sphinx-kataglyphis-theme/sphinx_kataglyphis/_static/css/custom.css` — change it there (and commit in that repo). `docs/_static/css/custom.css` is only for per-project overrides. Run `cd docs && make html` to verify.
