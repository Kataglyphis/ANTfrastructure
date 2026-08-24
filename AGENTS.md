# Kataglyphis-ContainerHub

Agent context file. Build commands live in `README.md`; deep architecture in
`docs/`. This file captures the **guardrails** an LLM agent must follow to avoid
regressing the build.

## Project priorities (owner directive — optimize for ALL THREE, always)

1. **Fastest possible build.** Cache-first engineering: BuildKit layer cache
   with narrow per-file closures, local cache exports, ccache wired end-to-end
   (and MEASURED — emit stats to stderr, the stream the 2MiB step-log clip
   never truncates), pinned buildkitd GC budget, parallelism levers
   (`GCC_PARALLEL_TARGETS`, `--parallel-archs`) taken when proven safe. The
   resource monitor showed peak CPU at 42% — idle cores are the standing
   wall-clock reserve. Speed that risks a silently wrong image is not speed
   (the `--no-push` handoff lesson): correctness bounds every shortcut.
2. **Maximum stability.** Digest-pinned handoffs, machine-checked ancestry,
   verified version pins (checksums from official sources), the five shell
   bug classes (§ Shell safety conventions) never reintroduced, and gates
   that FAIL LOUDLY — an assertion-free PASS ("will work at runtime") or an
   inner warning swallowed by an outer green is a defect, not a success.
3. **Many tests.** Every fix ships with a regression test where testable:
   unit suites under `linux/scripts/tests/` (auto-discovered by the
   pre-commit `script-tests` gate), lint gates (shellcheck, IFS-safety,
   hadolint, actionlint, ruff via `lint-python.sh`, gitleaks via
   `lint-secrets.sh`), preflight checks, and smoke assertions that assert
   real behavior against `versions.env` pins.
4. **Docs always follow the change — in the same work unit.** Any behavior,
   flag, workflow, or invariant change updates AGENTS.md (rules/quick-ref),
   README.md (user-facing pointers), the relevant `docs/` page, and
   `CHANGELOG.md` before the work is called done. A mechanism that only the
   git history knows about does not exist for the next session.

## Container Architecture

Three build lanes. Supported Linux arches: `amd64`, `arm64`, `riscv64`. Windows **host**:
`windows/amd64` only; Windows **targets**: `amd64` (image, production) and `arm64`
(cross-compiled artifact bundle — plumbing landed 2026-08-22 and the lane **BUILDS** since
2026-08-23; **nothing it produces has ever been RUN**, because Windows x64 has no ARM64 emulation,
so every arm64 signal is a static PE machine-type check. `build-buildkit.ps1 -TargetArch arm64`
just works: `torch` is dropped from the DEFAULT stage list with a notice (asking for it
**explicitly** still throws — it runs `uv sync`, which must execute the target interpreter).
Which components are through is tracked in the status banner of `docs/windows-cross-builds.md` —
do not restate it here, it moves).

> **There is no arm64 Windows container image, and there cannot be one.** Microsoft publishes no
> arm64 `servercore`/`nanoserver` base image and Windows Server has no arm64 release
> ([Windows-Containers#586](https://github.com/microsoft/Windows-Containers/issues/586)). The
> Windows arm64 lane is therefore a **cross build out of the same `windows/amd64` container**
> (`clang-cl --target=aarch64-pc-windows-msvc` + `lld-link`), and its product is an artifact
> bundle, not a runnable image. Never pass `--platform windows/arm64` on its output — that
> produces an unrunnable manifest.
>
> **The base carries FOUR arm64-only prerequisites, all installed unconditionally** (gating them
> on an arch ARG would re-pay the chain's most expensive layers on every lane switch): the MSVC
> `VC.Tools.ARM64` CRT/import libs, Vulkan's optional `Lib-ARM64` component, `clang_rt.builtins-aarch64.lib`
> (clang lowers 128-bit integer math to compiler-rt libcalls — without it GStreamer fails at link on
> `__udivti3`), and an aarch64 OpenSSL beside the x64 one (scoop installs one arch per app; four
> GStreamer targets link OpenSSL). `probe-arm64-prereqs.ps1` reports on all four. Each is
> **warn-only** in the base because that layer is shared and an arm64-only prerequisite must never
> break the amd64 build — but the GStreamer build **throws** on the ones it actually needs, so a
> base missing them fails in the merge stage rather than shipping a bundle without them.
> `WINDOWS_ARM64_STRICT=1` promotes the base checks to hard gates — **except `setup-vs.ps1`'s MSVC
> `lib\arm64` check**, whose RUN sits above the `ARG WINDOWS_ARM64_STRICT` declaration in
> `Dockerfile.base` and therefore never sees it. It must also be passed as a build-arg
> (`-BuildArg WINDOWS_ARM64_STRICT=1`); a host env var alone does nothing. Details and the traps in
> `docs/windows-cross-builds.md`.

| Dockerfile | FROM | Produces |
|------------|------|----------|
| `Dockerfile.base` | `ubuntu:26.04` | `:base` (stable apt deps only; copies no project scripts — stays cache-stable) |
| `Dockerfile.toolchain` | `:base` | `:cross-compiler-amd64` |
| `Dockerfile.sdk` | `:cross-compiler-amd64` | `:cross-sdk-<arch>` |
| `Dockerfile.media` | `:cross-sdk-<arch>` | `:cross-media-<arch>` |
| `Dockerfile.android` | `:cross-media-<arch>` | `:cross-android-<arch>` |
| `Dockerfile.package` | `:base` + `:cross-android-<arch>` | `:latest-cross-package-<arch>` |
| `Dockerfile.torch` | `:latest-cross-package-<arch>` | `:latest-cross-<arch>` |
| `Dockerfile.nvidia` / `Dockerfile.amd` | `:cross-sdk-<arch>` | optional GPU layer (CUDA or MIGraphX) |
| `windows/Dockerfile.*` | `windows/servercore:ltsc2025` | `:winamd64`, or `:winarm64` under `-TargetArch arm64` — still a `windows/amd64` image, carrying an aarch64 artifact bundle; **never publish it with `--platform windows/arm64`** |

### Windows-Specific Naming

The Windows lane uses local intermediate tags (`local/kataglyphis:windows-base`, `local/kataglyphis:windows-sdk`, `local/kataglyphis:windows-toolchain`, the media fan-out branch tags `local/kataglyphis:windows-media-<branch>` for `media-core`/`media-litert`/`media-tvm` (plus `-builder` variants; see `Get-MediaBranchTag`), the merged `local/kataglyphis:windows-media`, and `local/kataglyphis:windows-torch` for the app stage) and publishes the final image as `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`. See `docs/windows-builds.md` § Build Commands for the full build sequence.

---

## Quick Reference

Build logs are written to `out/build-logs/` by passing `--log-dir` to `build-cross-chain.sh` or `build-cross-stage.sh` (the two orchestrators that tee each stage build; the Makefile wraps these). The other orchestrators (`build-cross-compiler.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`) do not accept `--log-dir` — capture their output with `2>&1 | tee ./out/build-logs/<name>.log`. To stop a running chain cleanly (reaps the orphaned nerdctl/buildctl child subtree — never `pkill` the orchestrator, that orphans them), use `bash linux/scripts/stop-cross-chain.sh` (finds the run via its pidfile, falling back to a bracket-trick pgrep). Cache knobs (three distinct, do not conflate): `NO_CACHE=1` disables ALL `--cache-from` (local + registry) for the whole chain; `RUNTIME_NO_CACHE=1` gates `--no-cache` on only the runtime package+wrapper builds (`runtime-build-fns.sh`) — a targeted guarantee against BuildKit worker-cache reuse of a stale `COPY /opt/ffmpeg` layer; `CROSS_NO_LOCAL_CACHE_EXPORT=1` only stops WRITING the local buildcache but STILL reads the registry inline cache. **Verify the shipped BYTES, never the push** (backlog RTCACHE3): the 2026-08-15 S2 saga shipped `:latest-cross` STALE five times with every static gate and all smokes GREEN — the manifest, smokes, and push were all byte-identical to a prior run. The real cause was the `--output type=image` tagging bug (see "Cross Chain Stage Handoff"), NOT a cache; media+android were always fresh. This is now GATED automatically: `verify-shipped-wrapper.sh` runs in `build-runtime-manifest.sh`'s per-arch loop BEFORE the manifest is assembled — it lists each wrapper's rootfs (`nerdctl export | tar -t`, arch-agnostic, no emulation) and asserts the `/opt/ffmpeg` lib set matches the versions.env toggles (`FFMPEG_ENABLE_TF` → `libtensorflow` present/absent, ffmpeg intact). A mismatch aborts before `:latest-cross` goes live. `WRAPPER_CONTENT_GATE=0` makes it advisory. `MEDIA_STRIP=0` disables the media-prefix symbol-strip pass (`strip_media_prefixes`, default ON, wired into build-ffmpeg/build-gstreamer-stage/build-libcamera; uses the cross `${STRIP}` and `--strip-all` which keeps `.dynsym` so runtime linking is unaffected). **:latest-cross was re-shipped 2026-08-16** (fresh amd64 `509027696e16` / arm64 `bdb46c953954` / riscv64 `28e3ded96f72`) carrying the Batch-2 fixes; that full-media rebuild flushed out two bugs the runtime-lane validations miss because they skip smoke-media — (1) smoke-media's native cv2 import must be gated on numpy being importable (numpy is a /opt/venv packaging dep, absent in the media BUILD sandbox → defer to the runtime smoke, like onnxruntime), and (2) `configure-runtime.sh` runs a SECOND time in the package stage, so its gstreamer-multiarch resolver must drop/skip the pre-existing `lib/multiarch` symlink before resolving or it re-points it at itself — and its dev-surface check must be a WARN, not a fail-loud exit (a script that runs twice must not carry a build-breaking assert; the pkg-config `verify_consumer_dev_surface` gate is the authority). To spot-check by hand: pull the wrapper and grep for the expected lib set. Two sibling gates default to advisory (WARN) and promote to fatal only on opt-in: `VULKAN_CROSS_STRICT=1` (all three Vulkan cross-components — loader/SPIRV-Tools/glslang — failed, an env-shaped toolchain cause; `vulkan.sh`) and `WHEEL_SOABI_STRICT=1` (a vendored wheel's native `.cpython-*.so` carries a SOABI for a different arch than the target triple — a host-SOABI leak that only fails at `import`; `verify-wheels.sh`, triple derived from `TARGET_ARCH` not the running interpreter).

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

# ⚠️ --no-push FULL-CHAIN runs are broken on OCI-worker hosts (this host):
# the FROM handoff resolves against the REGISTRY, silently building each stage
# on the last PUSHED parent (verified live 2026-08-08 — two runs lost). Use
# --no-push ONLY for single-stage validation:
bash linux/scripts/build-cross-chain.sh --only media --target-arches amd64 --no-push --log-dir ./out/build-logs
# Correct full-chain flow: push mode to android, then the runtime lane with
# --skip-manifest so a partial-arch run cannot clobber the public manifest —
# see docs/linux-cross-builds.md § "The flow that is correct today".

# Opt-in: build the per-target cross GCCs concurrently inside the compiler
# stage (~30% off the GCC RUN at 3 targets; default 0 = sequential).
GCC_PARALLEL_TARGETS=1 bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Verify chain freshness without building (real FRESH/STALE verdicts for images
# that carry the org.kataglyphis.parent-digest ancestry annotation)
bash linux/scripts/build-cross-chain.sh --verify-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Partial runs (--from-stage after base) auto-assert the ancestor chain against
# the registry and REFUSE to build on a stale ancestor. Deliberate override:
#   --no-verify-ancestry   (or CROSS_VERIFY_ANCESTRY=0)

# Standalone quick chain verification (lighter, no orchestrator flags)
bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64

# Print the full stage graph with tag names (no builds)
bash linux/scripts/build-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Dry-run: print all build commands without executing
bash linux/scripts/build-cross-chain.sh --dry-run --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Cheap packaging validation before publish (see docs/linux-cross-builds.md)
# Uses the `wrapper-smoke` target in Dockerfile.package

# Reinstall QEMU/binfmt after host reboot OR containerd restart (rootless:
# the tonistiigi/binfmt --install container does NOT work — wrong namespace)
linux/scripts/setup-rootless-binfmt.sh --arches arm64,riscv64 --install-service
```

**Fresh Linux host?** GPU driver + CUDA install, the NVIDIA default-runtime `daemon.json`, CPU/GPU performance mode, and GRUB recovery are `docs/linux-host-setup.md` — the Linux counterpart to `docs/windows-host-setup.md`.

> **See also:** [`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) for the full stage graph, digest pinning, and single-stage build details. [`docs/linux-build-basics.md`](docs/linux-build-basics.md) for build fundamentals, caching, and troubleshooting.

### Windows Container Build

**Fresh Windows machine?** The ordered host bring-up (Stevedore, CNI conf, debug flags, GC policy, Defender exclusions, dufs/sccache, gate tooling) is `docs/windows-host-setup.md` — follow it instead of reconstructing the sequence from the sections below. Once the interactive steps are done (Stevedore + reboot + docker-users + repo clone), the **scriptable half of bring-up is ONE elevated run**: `windows/scripts/host/setup-new-host.ps1` authors the CNI `.conflist` from the **live** `vEthernet (nat)` subnet (magic subnet literals are gone from the docs), derives the `.conf`, applies containerd config + GC policy + step-log env, builds+deploys the patched runhcs shim when missing (Go via scoop), and installs/starts/registers dufs + the machine `SCCACHE_WEBDAV_ENDPOINT`. Run `-ReportOnly` first; it is idempotent and refuses while a build is live.

All stages use **Ninja+clang-cl+lld-link** (not MSBuild/VS generator). The Windows container toolchain is **containerd + BuildKit + nerdctl** (preferred since 2026-08; full CPUs + real layer caching), with docker-classic run+commit as the always-working fallback. Role split — each tool where its pipe ACL allows:

| Task | Tool | Shell |
|---|---|---|
| Build the chain | `windows\build-buildkit.ps1` → `buildctl` (buildkitd pipe is docker-users) | non-admin |
| Inspect / run the `bk-*` images | `nerdctl --namespace buildkit` (containerd pipe is admin-only upstream — no `--group` option exists; never attempt pipe-ACL hacks) | **admin** |
| Publish via docker / classic-lane ops | Stevedore's `docker.exe` (`-FinalTar` bridges the containerd→docker store gap; registry push directly from the BK lane is available via `build-buildkit.ps1 -PushRef <ref>`, needs a prior `docker login`) | non-admin |

**Isolation policy: process isolation is always preferred** — build.ps1's `-Isolation auto` (default) runs the ~10s commit probe (`windows/scripts/diagnostics/test-process-isolation-commit.ps1`, verdict cached per host build + docker version) and uses `--isolation process` for every `docker build`/`docker run` when the host can commit process-isolated layers (full CPUs everywhere); it falls back to `hyperv` with a warning on wcifs-skew hosts. **TRUST THAT WARNING ONLY AFTER READING THE PROBE LOG** (`out\windows-build-logs\isolation-probe.log`): on 2026-08-21 the probe reported "cannot commit" for a reason that had nothing to do with wcifs — its Dockerfile set `SHELL ["pwsh", ...]` on the PUBLIC servercore base, which ships Windows PowerShell 5.1 only, so every RUN died with `hcs::System::CreateProcess ... The system cannot find the file specified` and the driver read a manufactured verdict as a host defect. Cost: silent Hyper-V fallback, i.e. **2 CPUs on a 32-core host**. The probe log prints `BUILD FAILED (exit 1) but NOT with the known signature -- investigate` for exactly this case; that line means the verdict is worthless, not that the host is broken. After the fix the same host probed **BUG GONE — process isolation commits fine**. Guarded now by `windows/scripts/tests/Dockerfile.ProbeShell.Tests.ps1` (no `pwsh` SHELL on a public base before pwsh is installed; comments do not count as an install). A stale verdict lives in `out\windows-build-logs\isolation-probe-cache.json` — delete it to force a re-probe. **sccache is required by default for the media stages** (fail-fast when `-SccacheEndpoint`/`SCCACHE_WEBDAV_ENDPOINT` is missing or unreachable; `-NoSccache` overrides). The gate is media-only (`Assert-SccacheEndpoint`'s `$compileStages = @('media')` in `WindowsBuildDriver.Common.psm1`) — the toolchain stage (MSBuild/ClangCL CPython) has no sccache wiring, so toolchain-only builds are not blocked on an endpoint they never use. **AMD RDNA4-GPU hosts (RX 9xxx): the BK preflight also runs `Assert-NoActiveRdna4Gpu`** — an ENABLED RDNA4 dGPU makes every process-isolated RUN-layer finalize fail (`ActivateLayer 0x20`, docker/for-win#14977; A/B-proven 2026-08-10), so the chain builds with the dGPU disabled (`toggle-rdna4-gpu.ps1 -Disable` → build → re-enable; display falls back to the iGPU; the toggle resolves ALL RDNA4 hazard SKUs by default and takes `-NoPrompt` for automation). A verified-healthy host (green `probe-build-copy.ps1 -Heavy` with the dGPU enabled, e.g. after a driver fix) can bypass just this gate via `-SkipRdna4Gate` — unlike `-SkipHostChecks` it leaves the disk/shim gates armed. **The BK preflight also runs `Assert-BuildkitdStepLogEnv`**: it refuses to launch while the buildkitd service env lacks `BUILDKIT_STEP_LOG_MAX_SIZE=-1` (a Stevedore repair once wiped it and the 2 MiB step-log clip buried verdicts for a day — never swallow logs); fix elevated between runs via `setup-new-host.ps1` or the registry Multi-String + `Restart-Service buildkitd`; `-SkipStepLogGate` bypasses ONLY this gate for one launch when no admin is at hand (the 2 MiB clip then stays active — restore ASAP). Details + the wedge-cascade warning: § Common Failure Modes "AMD Radeon host" row.

**LANE REALITY CHECK (measured 2026-08-21, after a Stevedore reinstall — read this before choosing a lane):**
- **The classic lane can no longer build `base`. It is not a fallback any more.**
  Twelve `windows/Dockerfile.*` (base, nvidia, torch, toolchain-builder,
  media-builder, media-merge-builder, smoke-gate, probe, and the four probe/
  cache-mount helpers) use `RUN --mount=type=bind` for their script closures,
  and `build.ps1` never sets `DOCKER_BUILDKIT` — so the legacy builder dies at
  `Dockerfile.base` step 8 with *"the --mount option requires BuildKit"*. The
  older claim that "the classic lane is unaffected" is about the `built`
  targets ONLY; it does not mean the classic lane can bootstrap a chain. Use
  `build-buildkit.ps1`. Reviving the classic lane means either a
  BuildKit-enabled dockerd or COPY fallbacks in twelve Dockerfiles — decide
  deliberately, do not "just add -SkipHostChecks".
- **The BK lane cannot bootstrap `base` from an EMPTY/damaged containerd
  content store.** Every stage is solved with `--opt image-resolve-mode=local`
  (`build-buildkit.ps1`), which is right for stage handoff but also forbids
  buildkit from going to mcr for the PUBLIC pinned base. A missing or
  half-written record surfaces as
  `failed to resolve source metadata ... blob sha256:<config> ... blob not
  found`. Repair (ADMIN, containerd's pipe is admin-only):
  `nerdctl --namespace buildkit pull mcr.microsoft.com/windows/servercore:ltsc2025@<WINDOWS_BASE_DIGEST>`
  — then re-run the lane. Killing a `docker build` mid-pull is one way to
  produce that half-written record.
- **After a Stevedore REINSTALL the patched shim has NO local rollback.** The
  `.exe.orig` and every `.exe.bak-*` are stock-sized too (measured: all four
  copies 23 279 616 B, identical timestamps), so `deploy-shim-patch.ps1
  -Restore` has nothing patched to restore — it must be REBUILT:
  `scoop install go`; clone `microsoft/hcsshim` at **`81e2e01`** (the verified
  base); `git apply windows/upstream/hcsshim-teardown-timeout/local-45min-deployed.patch`;
  `go build -o containerd-shim-runhcs-v1.exe ./cmd/containerd-shim-runhcs-v1`
  (~15 s; produced 25 937 920 B with Go 1.27.0 — size drifts with the Go
  release, which is exactly why the gate keys on the RECORDED SHA256 and not
  on a size table); then elevated `deploy-shim-patch.ps1 -ShimPath <built exe>`.
- **A Stevedore reinstall also wipes the buildkitd service `Environment`**
  (`BUILDKIT_STEP_LOG_MAX_SIZE=-1`) and the **dufs `dufs-sccache-l2` scheduled
  task plus its `%USERPROFILE%\sccache-cache` serve directory**. The step-log
  one is gated (`Assert-BuildkitdStepLogEnv`); re-create the serve directory
  BEFORE running `setup-dufs-service.ps1`, or it has nothing to serve and the
  media gate keeps failing on an endpoint that never comes up.

**BuildKit/containerd lane (PREFERRED, `windows/build-buildkit.ps1`):** probes on 2026-08-03 proved the wcifs commit bug and the 2-CPU cap are DOCKER-CLASSIC artifacts on this host — buildkitd+containerd commits process-isolated layers fine and RUN steps see all 32 CPUs; the chain was then run from base on this lane the same day (VS2026 install, CUDA, CPython, media compiles all as plain process-isolated layers). **Status 2026-08-06: the lane is GREEN end-to-end and DE-WARMED — direct solves everywhere, warm/materialize retired.** The `ExportLayer 0x3` defect is fixed AT THE ROOT: the runhcs shim's hardcoded `tearDownTimeout = 30s` terminated the heavy-churn silo teardown mid-hive-flush (OpenCV teardown measured at **117 s**), permanently poisoning the scratch vhdx; a patched shim gives the teardown room. Proven by five consecutive clean `--no-cache` OPENCV canaries (exports 28.6/28.6/28.1/27.1/27.1 s), the fifth built from the upstream env-var patch — see Common Failure Modes and `docs/windows-builds.md` § roadmap. **SUPERSEDED — do not act on it:** the 2026-08-05 verdict "root cause was Windows Defender" was falsified the same evening when the first direct OpenCV finalize still hit 0x3 (TVM had been an insufficient canary specimen). The Defender exclusions stay because they cure the hcs-temp FLAKE family, but they never touched the core defect. **MAINTENANCE: every Stevedore/containerd update overwrites the patched shim** — `Assert-ShimPatch` fails the BK lane's preflight on it, comparing the live binary's SHA256 against the hash `deploy-shim-patch.ps1` recorded at install time (`C:\ProgramData\kataglyphis\shim-patch.json`; the old size table — patched 25 332 736 env-var / 25 329 664 fixed-constant vs stock 23 279 616 — is now only the fallback for hosts that have not re-run the deploy script). Check with `deploy-shim-patch.ps1 -ReportOnly` and re-run one OPENCV canary after any update. Rollback path if it ever 0x3s again: warm/materialize from git history (`c9586c1^`), payload scripts still in tree. `bk-winamd64` builds in ~43 min hot. Heavy-lane RUN steps bind-mount their script closures (per-file) instead of COPY. The driver builds the same Dockerfiles via buildctl, selecting the `*-built` targets (toolchain-builder `built`, media-builder `media-<branch>-built`, merge-builder `built`) that run the heavy compile scripts as plain LAYERS — no run+commit, real per-stage caching. **Getting it going (one-time setup + launch): see `docs/windows-builds.md` § BuildKit/containerd lane.** Requirements: buildkitd service (docker-users group) + `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` (without it RUN steps have no network) — and the conf's `ipam.subnet` MUST match the live `vEthernet (nat)` adapter: dockerd restarts recreate the nat HNS network on a new subnet and silently orphan the conf (containers then get unroutable IPs, "remote name could not be resolved" on the first download). `build-buildkit.ps1` now fail-fasts on that drift with the exact fix. Gotchas: results live in the CONTAINERD store as `docker.io/local/kataglyphis:bk-*` (fully-qualified on purpose — buildkit normalizes FROM refs to docker.io/ and stage handoff needs `--opt image-resolve-mode=local` to match); they are INVISIBLE to docker (separate windowsfilter store) — export with `-FinalTar`. The classic lane is unaffected: build.ps1 pins `--target builder`/`--target merge` so docker never executes the `built` stages.

The paragraph below describes the docker-classic HYPERV fallback state:

**`docker build` is capped at 2 CPUs on this host — the heavy media-core stage builds via `docker run --cpu-count N` + `docker commit` instead.** Hyper-V-isolated build containers get only **2 logical CPUs** (pinning `ninja -j` to 2, `Get-BuildJobCount = min(ProcessorCount, memGB/perJob)`), and `docker build` has **no working lever** to raise it: `--cpu-count` is rejected, `--cpuset-cpus` fails the build, and `--isolation process` exposes all CPUs but **cannot commit any layer** here (`hcsshim::ActivateLayer 0x20 "file used by another process"`, reproduced even for a 100 MB dummy layer; not Defender/Search/SysMain). `docker run`, however, **does** honor `--cpu-count` under Hyper-V (verified `NPROC=32`) and commits fine — so `build.ps1` builds every **CPU-bound** stage via a generic run+commit path (`Invoke-RunCommitStage`): **media-core** (`Dockerfile.media-builder --target media-core` + `build-media-core-all.ps1`), **toolchain**/CPython (`Dockerfile.toolchain-builder` + `build-toolchain-all.ps1`), and the **media merge / GStreamer** stage (`Dockerfile.media-merge-builder` + `build-gstreamer-from-source.ps1`; the fan-in `COPY --from` stays a `docker build` since `docker run` can't `COPY --from`, but the GStreamer compile runs+commits). `-MediaCoreCpus` defaults to `[Environment]::ProcessorCount` (32 here) — but parallelism is **memory-bound**: `min(cpu-count, memGB/perJob)`, so ONNX stays `~j12` at 48 GB regardless of cores. `base`/`sdk` stay at 2 CPUs by design (network/install-bound). The `litert`/`tvm` aux branches also run+commit at `-MediaCoreCpus` (`Dockerfile.media-builder --target media-litert` + `build-litert-all.ps1`; `--target media-tvm` + `build-media-tvm-all.ps1`, the TVM → IREE chain) — media-core is already committed then, so the full CPU/RAM budget is free (`~j2`→`~j19`, still memory-bound). All three branch builders are targets of the ONE consolidated `Dockerfile.media-builder`, and the schedule is strictly sequential (a former `-ConcurrentMedia` overlap mode was removed — overlapping starved the media-core long pole).

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

See `docs/windows-builds.md` § Build Commands for the full Windows build sequence (base → [nvidia/sdk] → toolchain → media → torch → final) and `docs/windows-builds.md` § Stevedore Setup Fixes for post-install fixes.

### Running Linux containers (Rancher Desktop)

**Rancher Desktop is the preferred Linux-container runtime on this host**, and
the way to reproduce a Linux CI failure locally instead of guessing through
pipeline round trips. It does not replace the Windows lane — Windows containers
still go through Stevedore's `docker.exe`. Full details:
[`docs/rancher-desktop-linux-containers.md`](docs/rancher-desktop-linux-containers.md).

```pwsh
$nerdctl = "C:\Program Files\Rancher Desktop\resources\resources\win32\bin\nerdctl.exe"
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
  riscv64. `python-ci-linux.yml` sets `CONTAINER_IMAGE` to `:latest-cross`; if a local run
  uses a different tag, reproducing a CI failure proves nothing. Neither tag is
  digest-pinned, so both still float.

### LLM Stack (Ollama + Open WebUI)

A standalone serving stack lives in `linux/llm-stack/` (docs in its own
README). CPU-only is the compose default; an opt-in GPU override
(`linux/llm-stack/docker-compose.gpu.yml`, `docker compose -f docker-compose.yml
-f docker-compose.gpu.yml up -d`) grants the Ollama service all NVIDIA GPUs and
raises `OLLAMA_CONTEXT_LENGTH`. **VRAM caveat:** the context Ollama lists is the
model's max, not what fits — ~19 GB of weights + ~104 KB/token q8_0 KV means a
28 GB stack (e.g. 12 GB + 16 GB GPUs) caps at ~64K, and 256K needs >45 GB VRAM.
Requires the nvidia-container-toolkit on any host that wants GPU mode.

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

### Where does knowledge belong? (docs, not just code)

The reuse rules below are about code. The same discipline applies to **what you
write down**, and one question decides it:

> **Would this still be true in a different project?**

- **Yes** → it belongs here, and the consumer LINKS to it.
- **No** → it belongs in the consumer.

Most topics split down the middle. "Allow the `bindFlt`/`wcifs` filters on a Dev
Drive" is ours; "Dart's `copySync` fails on a bind mount" is
Kataglyphis-Inference-Engine's, because it only matters for a Flutter app.

**Why linking rather than restating.** On 2026-08-11 the Dev Drive filter
command existed in three places — `docs/windows-builds.md` here, plus
Inference-Engine's `AGENTS.md` and `docs/source/platforms.md`. All three were
wrong the same way (unquoted filter list, missing `/volume`) while
`windows-container-build-performance.md` had it right the whole time *and*
warned that people get it wrong exactly that way. Restating produced three
broken copies.

[`docs/INDEX.md`](docs/INDEX.md) maps topic → owning document. Consumers link
one hop through it, so reorganising docs here means editing that page instead of
hunting links across seven repositories.
[`shared/templates/AGENTS.md.template`](shared/templates/README.md) is the
consumer-side skeleton that keeps the split visible.

One caution against automating this: a keyword check ("this consumer doc
mentions wcifs") cannot tell *restating* from *applying*. Inference-Engine's
AddressSanitizer section legitimately discusses image-level runtimes, because
which ASan runtime a Flutter/COM app can survive is a property of that app. A
human has to read it.

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
  consumers resolve it ContainerHub-first with a vendored fallback. The resolver
  itself is a copied template:
  [`shared/windows/templates/Resolve-BuildModule.ps1`](shared/windows/templates/README.md).
- **The two-consumer test.** If a second consumer needs it, it belongs here — not
  vendored twice. That test is what moved `WindowsTesting.Common` (test-exe
  discovery, ctest driving, scoped ASAN_OPTIONS, ASan-runtime discovery) and
  `WindowsClang.Common` (clang-tidy driving) upstream on 2026-08-11. When moving
  one, turn its project-specific values into parameters whose DEFAULTS preserve
  the original behaviour, so the vendoring consumer can delete its copy without
  any behaviour change.
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
BeschleunigerBallett's `scripts/windows/Resolve-BuildModule.ps1`).

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
- **Every BK chain ends with a MANDATORY smoke gate — do not route around it.**
  `build-buildkit.ps1` solves `windows/Dockerfile.smoke-gate` against the
  finished image after `final`, and a failure fails the chain (backlog #44).
  Since 2026-08-21 the CLASSIC driver gates too — as `docker run` with a
  DIRECTORY mount of `windows\scripts` (its dockerd has no BuildKit
  `RUN --mount`, and Windows containers reject single-FILE binds outright;
  `docker run` also enters through the ENTRYPOINT naturally). Before
  2026-08-14 neither driver ran the smoke test at all, so every chain
  shipped unverified. Three rules when touching it: it must run **through
  `entrypoint.cmd`** (a bare `RUN` bypasses ENTRYPOINT and loses VsDevCmd + the
  ASAN runtime dir — that alone made six assertions fail against a good image);
  it **bind-mounts** the current script rather than the image's baked copy, so a
  smoke-test fix is re-verifiable without an image rebuild; and it enforces
  **coverage floors** (`-SmokeMinPassed`/`-SmokeMaxSkipped`, exit 3), because a
  run that asserted nothing used to print "All smoke tests passed!" and exit 0.
  `-SkipSmokeGate` is for chain iteration only.
  **On `-TargetArch arm64` the gate is arch-SPLIT (2026-08-24; the 2026-08-23
  doctrine here declared the whole gate inapplicable — right for the payload
  sections, too broad for the rest).** `smoke-test-container.ps1` mostly
  verifies by EXECUTING the staged binaries (`ffmpeg -version`, `gst-inspect`,
  `LoadLibraryW` over every shipped DLL, a compile-and-run native probe,
  `import cv2`), and Windows x64 has no ARM64 emulation, so every payload
  assertion fails for the same uninformative reason whether the bundle is good
  or not — those sections keep floor 0 on arm64 and the driver reports them
  `NOT APPLICABLE`, never "passed". But the suite (22 sections, ~100
  assertions) is not all payload: since 2026-08-24 the arm64 lane RUNS the
  host-toolchain sections (1-6, 14-16, and 19 arch-filtered: `TORCH_APP_DIR`
  dropped) with its OWN floor column, and the healthcheck likewise runs its 4
  host-tool checks on arm64, skipping only payload execution. Sections 14/15
  were NOT "unchanged" by that split: the final image bakes
  `VSDEVCMD_ARCH=arm64`, so a bare `clang-cl` (x64 default target) fought the
  ARM64 env libs — measured in the first arm64 smoke run (90/7/13). They now
  compile FOR the target and assert the produced PE machine instead of
  running (arm64 floor for section `14` = 2, measured), and ASAN is skipped
  there (LLVM's win-x64 package ships no aarch64-windows ASAN runtime). The
  gate went fully green on arm64 on 2026-08-24: **97 passed / 0 failed / 15
  skipped** against the arm64 floors `-SmokeMinPassed 66` /
  `-SmokeMaxSkipped 25`. **Never lower the amd64 floors**
  toward the arm64 column: a reduced `-SmokeMinPassed` would leave a number a
  later amd64 change could quietly be measured against, which is exactly how
  this gate became decorative once before. The cross lane's execution-side
  verification is `verify-target-arch.ps1` (PE machine type over `C:\runtime`
  AND the fanned-in site-packages, `.lib` archives included, inside the merge
  stage, floor raised to 100 there; the 2026-08-24 green run measured 931
  binaries / 0 violations, the 58 host `.pyd`s as REPORTED allowlist skips)
  plus the fact that every artifact linked
  at all — neither proves the code RUNS, and nothing available on this host
  can.
- **Never cross a pwsh process boundary with an array parameter.** `& pwsh
  -File script.ps1 -Param 'a','b'` delivers ONE literal string INCLUDING the
  quote characters, not a two-element array. Cost (2026-08-18): the deadlock
  repro's `-BuildArg` pair reached buildctl as one mangled undeclared ARG
  name, buildctl silently discarded it, and an 88-minute repro measured
  nothing while reporting success. Invoke repo scripts DIRECTLY (`&
  'windows\build-buildkit.ps1' …`) when already in pwsh 7;
  `build-buildkit.ps1` now throws on non-identifier `-BuildArg` keys so the
  flattened form fails loudly instead of vanishing downstream.
- **TVM builds its OWN minimal LLVM (#47, 2026-08-17) — do not "simplify" it
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
- **freedesktop/videolan GitLab downloads MUST go through
  `Invoke-WrapDownload`** (curl-native UA + gzip/bzip2 magic-byte check, in
  `build-gstreamer-from-source.ps1`) — the Anubis anti-scraper in front of
  those hosts answers browser UAs without JS with an HTTP-200 HTML challenge
  page, which is exactly what the shared `Invoke-DownloadWithRetry` sends.
  Also strip `.git` from GitLab `/-/archive/` URLs (with it, GitLab serves
  HTML even to curl). Both burned a merge run each on 2026-08-17; do not
  "unify" wrap fetching back onto the shared helper.
- **graphene builds only with `-Dgraphene:sse2=false` plus the post-setup
  meson.build patch** dropping its `-Werror=undef` (it outranks our c_args —
  last flag wins; clang-cl defines no `__GNUC__`, and its MSVC SIMD path
  calls SSE4.1 intrinsics unguarded). graphene entered the build for the
  FIRST time when #88 made every wrap actually arrive — expect more
  first-ever subprojects to surface clang-cl corners after wrap fixes.
- **Never rewrite upstream sources with a bare `string(REPLACE)`.** Use
  `patch_replace_required` / `patch_regex_replace_required` from
  `patches/litert-lm/patch-assert.cmake`, which `FATAL_ERROR`s when the pattern
  matched nothing (backlog #56). The old pattern printed "Patched …"
  unconditionally, so an upstream reformat silently restored the defect the
  patch existed to fix — for sentencepiece's duplicate `ABSL_FLAG(minloglevel)`
  that means a link-clean `litert_lm_main.exe` that aborts on every run.
  `Patches.CmakeNoOpGuards.Tests.ps1` fails any unguarded replace; a genuine
  non-source replace opts out with a `patch-assert-exempt` marker AND a reason.
- **When a probe says the product is broken, suspect the probe first — and
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
- **A probe that reproduces the ENVIRONMENT does not necessarily reproduce the
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
- **A probe can destroy its own experiment — read the setup output, not just the
  verdict.** The same script sweeps anything in the cache root that is not a hex
  bucket off the mount as debris; that quietly deleted the inheritance fixture a
  later section depended on, and the run reported "0 files inherited" — which
  reads as "the cache mount lost 250 objects", i.e. exactly backwards.
  The directory listing printed at the top of the log is what exposed it. Keep
  fixtures on an explicit allow-list (`$probeOwned`), and when a probe's result
  is surprising, check what the probe DID to the system before believing what it
  says about the system.
- **Aggregate evidence has a SHELF LIFE — check the newest sample's timestamp
  against the last fix.** The log forensics concluded "sccache has never
  worked" from 0 hits / 189,861 failed writes across 94 stat blocks. Every one
  of those samples predated the dufs SYSTEM-service migration on the same day,
  and no run since had exercised sccache — a direct probe showed
  miss → store → HIT with 0 write errors. Confident conclusions about a state
  that no longer exists are the failure mode of corpus-wide aggregation; date
  the newest sample before trusting the aggregate.
- **A daemon's log is only as durable as its last flush — stop the server before
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
- **Never put a log inside a directory some OTHER tool owns and prunes.**
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
- **A build log written inside the build dir DIES WITH THE SOLVE — always use
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
- **Never put DOUBLE QUOTES inside shell-form RUN lines in the Windows
  Dockerfiles.** The dockerfile frontend strips embedded `"` from the command
  string before it reaches the pwsh SHELL (three incidents on 2026-08-04:
  `"$env:TEMP\*"` became bare `$env:TEMP\*` → ParserError; the pwsh-written
  Directory.Build.props lost its XML attribute quotes → MSB4024). Use single
  quotes / `''`-doubling / string concatenation instead; XML attributes may
  legally use single quotes.
- **`Import-Module X -Force` is safe ONLY at ENTRY-script top level — never in
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
- **Never splat a string ARRAY containing `-Param`-shaped tokens onto a
  PowerShell script/function — array splatting binds strictly BY POSITION.**
  `& $script @('-ResumeFrom','OpenCV')` delivers `-ResumeFrom` as the VALUE of
  parameter 1 (silently wrong without CmdletBinding, "positional parameter
  cannot be found" with it) — this killed the opencv warm solve on 2026-08-04
  and reproduces identically on host pwsh 7.6. Route such argv through a child
  process instead (`& pwsh -NoProfile -File $script @argv` — native argv is
  re-parsed into named parameters; `bk-warm.ps1` is the reference), or splat a
  HASHTABLE. Splatting arrays onto native executables stays fine.
- **NEVER swallow logs — display may truncate, persistence must not (owner
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
- **Two more pwsh traps, both found live 2026-08-10 in `probe-build-copy.ps1`
  (regression pin: `windows/scripts/tests/Native.ArgQuoting.Tests.ps1`):**
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
- **Scratch must be scrubbed INSIDE the layer that created it — image layers
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
- **`Invoke-BkStage -MaxAttempts` defaults to 3; the media MERGE stage passes
  5.** It fans in three branch images, so it does far more mount work than any
  other stage and flakes proportionally — 2026-08-06 it burned its whole
  3-attempt budget (two `failed to mount {windows-layer}` failures, green only
  on the last try). Retries are cheap: completed RUN vertices stay cached, only
  the failed finalize/export re-runs. Raise the per-stage budget rather than
  the global default.
- **BOTH lanes are supported: `buildctl` (NON-ADMIN) builds the chain, `nerdctl`
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
  there). Recipes + traps: `docs/windows-builds.md` § nerdctl lane.
- **Never pass a command to a nerdctl `run` of an image that has an
  `ENTRYPOINT`** — it is appended as entrypoint ARGUMENTS, not substituted. On
  `bk-winamd64` that exits `255` instantly and leaves a container whose
  `rm -f` then BLOCKS for up to 45 minutes, because the patched shim waits for
  a teardown instead of force-terminating (right for builds, painful
  interactively). Use no command (the final image's `entrypoint.cmd` starts
  pwsh itself) or `--entrypoint`. Zombie recovery, safe only when the container
  did no real filesystem work:
  `Get-Process containerd-shim-runhcs-v1,CExecSvc | Stop-Process -Force` then
  `rm -f` again. Exit `3221225786` = `0xC000013A` = the container was Ctrl+C'd.
- **The CNI nat config must exist as BOTH `0-containerd-nat.conf` AND
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
- **The classic docker lane's "always-working fallback" needs a RUNNING
  daemon, and on a Stevedore host that daemon is the `stevedore` SERVICE.**
  `stevedore` IS dockerd (`...\Stevedore\dockerd.exe --run-service
  --service-name stevedore --host npipe:...dockerDesktopWindowsEngine
  --containerd=npipe:...`). Found **Stopped** on 2026-08-07 while the BuildKit
  lane ran happily — i.e. the documented fallback was unavailable and nothing
  said so. `docker.exe` sitting on PATH proves nothing; `build.ps1` now
  fail-fasts via `Assert-DockerDaemon`. Starting it is NOT a safe reflex:
  a dockerd start recreates the nat HNS network and can move the subnet out
  from under `0-containerd-nat.conf`, leaving BuildKit containers with
  unroutable IPs — so start it deliberately, then RE-CHECK the CNI subnet
  (`build-buildkit.ps1` fail-fasts on that drift with the exact fix).
- **In `RUN --mount=...,from=<stage>` the SOURCE path is Unix-style with NO
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
- **The "unreferenced" `windows/scripts` modules are EXTERNAL-CONSUMER API —
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
  build-cache cost is zero (per-file bind mounts on the BK lane).

- **media-core builds via run+commit for CPU parallelism — never re-add `--isolation process`.** `docker build` is 2-CPU-capped here and process isolation **cannot commit layers** (`hcsshim::ActivateLayer 0x20`, reproduced even for a 100 MB dummy). media-core builds via `docker run --isolation hyperv --cpu-count $MediaCoreCpus` + `docker commit` (`Invoke-RunCommitStage`), which is the only way to get >2 CPUs *and* a committable image. Regression symptoms: `-j2` in `out\windows-build-logs\media-core.log`, or `ActivateLayer` on any commit. Full rationale: `docs/windows-builds.md` § Build isolation and CPU parallelism. **Before assuming this is still needed after a Docker/Windows/base-image upgrade, re-check with `windows/scripts/diagnostics/test-process-isolation-commit.ps1`** — if it reports `BUG GONE`, process isolation for `docker build` is usable again and the workaround can be retired (see § Re-testing process isolation on new versions).
- **Rust: rustup WITH a default toolchain is the sole provider — never a toolchain-less rustup, never a second provider (no scoop rust).** Polarity INVERTED by the Flutter-Cargokit fix: Cargokit (flutter_rust_bridge-style plugins) hard-requires rustup and aborts with "rustup not found in PATH." otherwise, so `setup-rust-toolchain.ps1` runs `rustup-init -y --default-toolchain stable --profile minimal` and `setup-scoop-tools.ps1` installs NO rust. `CARGO_BIN` (= `...\.cargo\bin`, the rustup proxy dir) sits ahead of scoop's shims on PATH **by design**. The failure the old "never rustup" rule guarded against was narrower than the rule: a **toolchain-less** rustup (`--default-toolchain none`) drops proxy shims that resolve no toolchain ("no default toolchain configured"); installed WITH a default they resolve correctly. Do not re-add `scoop install main/rust` alongside — one provider only. Details: `docs/windows-builds.md` § Rust toolchain.
- **Parallelism is memory-bounded, not CPU-bounded — and the defaults ARE the max.** `Get-BuildJobCount = min(ProcessorCount, MEMORY_LIMIT_GB / MemGBPerJob)`; inside a run+commit stage, `ProcessorCount` = `--cpu-count` (default = all host logical processors, 32 here). ONNX is tuned to ~4 GB/job (its CUDA/AVX-512 TUs are the RAM-heaviest; the `-j2` incremental retry absorbs the occasional OOM) → ~`-j10` at the auto-detected `-MediaMemoryGb 39` (`61 GB usable − 22 GB host reserve`). **Do not "optimize" by raising the memory cap or cutting `-HostReserveGb`**: the verified maximum envelope for this host (32 CPUs / 39 GB; media-core bottomed the host at 0.2 GB free and survived; 53 GB deadlocked it) is documented in `docs/windows-builds.md` § Maximum resource envelope — average CPU of ~35–45 % during compiles is the expected memory-bound signature, not a tuning failure. **You cannot reach `-j32` on ONNX**: 32 heavy TUs need ~128+ GB — RAM per job, not core count, is the ceiling; the real speed levers are more physical RAM and the sccache WebDAV remote. **The local L0 disk tier is DISABLED BY DEFAULT since 2026-08-16 — and the fault is BuildKit, not sccache.** A BuildKit cache mount on Windows loses writes once its directory holds objects an EARLIER RUN wrote: 158 of 250 failed on the mount vs 0 of 250 into a plain container directory, same program, same moment; a FRESH directory on the same mount takes all 250. That is why opencv/genai (which inherit onnx's cache dir) failed ~100 % of writes while onnx, filling its own, failed 1.9 %. `SCCACHE_MULTILEVEL_CHAIN` is an ARG defaulting to `""` in BOTH media Dockerfiles; restore `disk,webdav` only after re-verifying against a newer buildkit (recipe + full measurement in `docs/windows-builds.md` #99). Do not "fix" this in sccache.
- **Preserve committed line endings when editing a COPY'd `.psm1`/`.ps1`.** Media modules are LF, some build scripts CRLF; `core.autocrlf=true` plus some editors can flip a whole file, busting the media layer cache. `.gitattributes` pins these `-text`; after editing, confirm `git diff` shows only your change, not a whole-file EOL flip.
- **`versions.env` is the single source of truth.** `build.ps1` forwards every version as `--build-arg`; the smoke test and scripts derive expected values from it (e.g. CMake URL from `CMAKE_VERSION`; `LLVM_RELEASE` pins the LINUX clang, `LLVM_WINDOWS_VERSION` the Windows one — separate on purpose). Don't hardcode versions in scripts or Dockerfiles. **Anything that produces or shapes compiled output belongs here**; tools the build merely invokes may float, and `setup-scoop-tools.ps1` splits its installs into exactly those two blocks.
- **AVX-512/AMX flags NEVER go in global CXX flags (final polarity, settled 2026-08-03).** Globally, clang may emit AVX-512 anywhere — the in-tree protoc AND `onnxruntime.dll`'s static initializers both crashed with `STATUS_ILLEGAL_INSTRUCTION` at run/load time on the AVX2-only build host (the import assert catches this). But entirely without the flags, MLAS's arch TUs fail to COMPILE (clang-cl gates intrinsics behind target features; MSVC doesn't). The settled design: `build-onnx-from-source.ps1` appends `Get-WindowsTargetKernelSimdFlags -Arch` per-TU (the name this line carried until 2026-08-24, `Get-WindowsX86Avx512Flags`, survives only as a zero-caller compat shim) to exactly the MLAS arch `FLAGS =` lines in build.ninja post-configure (runtime-dispatched kernels — the only code allowed to assume the features) and **asserts the tagged count against `Get-MlasKernelTuMinimum` — a THROW, not a log**. Two field lessons shape that floor: on aarch64 the x86 pattern matches nothing and a no-match patch *succeeds* (why the pattern is arch-parameterized), and on 2026-08-24 the amd64 lane broke with the floor PRESENT but too low — ORT v1.29.0 added six AVX-512 TUs outside `intrinsics/`, the stale pattern still matched 5 ≥ floor 4, and five kernels failed to compile. Floor rule: **it must be high enough that the previous broken state trips it** (now 8 against 11 matched; the stale pattern's 5 fails loudly). When bumping `ONNXRUNTIME_VERSION`, re-measure BOTH arches' patterns against the new MLAS tree — the 1.29 bump re-measured only aarch64 and amd64 paid for it. Don't "simplify" in either direction.
- **CMake cross configures must carry the ASM language target too (2026-08-24).** `Get-CMakeCrossArgs` (`WindowsTargetArch.Common.psm1`) sets `CMAKE_ASM_COMPILER_TARGET`/`CMAKE_ASM_FLAGS_INIT` alongside the C/CXX pair, and it OWNS them — never hand a project ad-hoc ASM cross flags. Before it did, any project enabling the ASM language assembled with clang's X64 default target — signature: `brackets expression not supported on this target` on aarch64 `.S` sources — and an aarch64 `-march` handed to that x86-targeted driver was misread as a CPU name (`unknown target CPU 'armv8.2-a+fp16'`), which sent the first diagnosis chasing a nonexistent driver gap. amd64 is untouched: the cross args stay empty there.
- **Windows images have a HARD 125-layer cap — the classic builder pays a layer PER INSTRUCTION, metadata included.** The final stage died with `max depth exceeded` on 2026-08-03 because the merge Dockerfile carried ~28 separate `ENV` lines. Rule: in any Dockerfile on the classic chain, consolidate ENV/metadata into single instructions (see `Dockerfile.media-merge-builder`'s one big ENV, layers 114→86). When adding stages/instructions, check headroom: `docker inspect <tag> --format '{{len .RootFS.Layers}}'` chain-wide; final currently sits ~108/125.
- **Two guards added 2026-08-07 that change how the BK driver behaves — know they exist before debugging around them.** (1) `Invoke-TransientCooldown` now takes `-PreviousTail` and **refuses to retry a byte-identical failure**: a flake changes between attempts, a poisoned snapshot does not, and the old behaviour burned the whole retry budget on `ImportLayer 0xb7`. The comparison strips buildkit's per-line elapsed-time prefixes, which differ every attempt. (2) `Invoke-BkStage` gates **disk per stage** with a stage-aware floor (CUDA 60 GB, media 80, merge 60, toolchain 45, else 40) because the start-of-run check passed at 164 GB while the chain still walked to 23 GB inside one heavy stage. Both honour the existing override switches; neither changes classic-lane behaviour.
- **The CNI `.conf` is DERIVED from the `.conflist`, not hand-edited (2026-08-07).** `apply-containerd-config.ps1` rewrites it via `ConvertFrom-CniConfList` whenever the two differ, so the two forms the clients each require cannot drift in content. Edit the **`.conflist`** and re-run that script; a multi-plugin conflist is refused rather than truncated to `plugins[0]`.
- **`docker commit` inherits the container's `Cmd` — always commit with `--change 'CMD ["pwsh"]'` (classic lane, fixed 2026-08-07).** The run+commit stages launch the container with a build-script argv, and `commit` captures it as the image's `CMD`: `local/kataglyphis:windows-media` and `windows-torch` shipped a `CMD` that RE-RUNS the GStreamer build, so `docker run -it local/kataglyphis:windows-media` starts recompiling over `C:\runtime` instead of opening a shell. The FINAL image was never affected (a Dockerfile `ENTRYPOINT` resets an inherited `CMD`), which is why it hid for months. Any new run+commit site must carry the same `--change`.
- **A committed layer can never be shrunk later, so scrub INSIDE the container.** Both lanes pass `-ScrubAfter` to the media branch and merge/GStreamer runs (`Clear-BuildScratch`: pip cache, `~\.nuget`, `%TEMP%`, INetCache); the classic lane was missing it until 2026-08-07, so its images carried debris the BK lane's did not. Source trees are a separate mechanism — each leaf script calls `Remove-SourceBuildTree` itself. The toolchain stage is excluded on purpose: its CPython tree at `C:\temp\cpython` IS the deliverable.
- **Windows stage scripts must end with an explicit `exit 0`.** `pwsh -File` propagates the LAST native command's exit code: a fully green LiteRT-LM build was declared failed because the final cleanup `rmdir` exited 145 (`ERROR_DIR_NOT_EMPTY`). Real failures throw (EAP=Stop + gates); reaching the end IS success — say so explicitly.
- **The mandatory GStreamer plugin set is a CONTRACT, never `auto` (2026-08-07).** `Get-RequiredGstPlugin` (`WindowsGstPlugins.Common.psm1` — it moved out of `WindowsScripts.Shared.psm1`, which this line named until 2026-08-08; Shared is in the compile closure of all three media branches, and this set changes far too often to sit there) is the single definition of which integrations must exist — `libav`, `opencv`, `onnx`, `tflite` — and it is enforced at four points that previously disagreed: a pkg-config pre-flight in `build-gstreamer-from-source.ps1`, meson features set to `enabled`, a post-install `gst-inspect` gate that throws, and smoke-test assertions that fail. Meson's `auto` means **skip silently**, which is exactly how the published `winamd64` shipped without opencv and libav while the healthcheck printed `[PASS]` for them. Three separate root causes, all fixed: OpenCV and ORT ship no `.pc` at all (now emitted by the merge stage from the canonical env contract — NOT by the ~30/~75-minute OpenCV/ONNX layers, which are not worth invalidating for a text file), and `subprojects/FFmpeg.wrap` + `-Dwrap_mode=forcefallback` **forced** gst-libav onto a wrap-pinned FFmpeg 7.1.1 instead of the `n9.0` this image builds (the wrap is now disabled before configure). `tflite` is a FOURTH mechanism — it consults no pkg-config at all (`cc.find_library('tensorflowlite_c')` + `cc.has_header('tensorflow/lite/c/c_api.h')`), and that header path is the PRE-rename TensorFlow one while LiteRT stages the post-rename `tflite/` layout, so the pre-flight mirrors a `tensorflow/lite/` alias tree and puts LiteRT's include/lib on `INCLUDE`/`LIB`. `tensorfilter` is an NNStreamer element, not a GStreamer plugin — never add it to the set. Deliberate exception: `-SkipPluginGate`, which marks the image unshippable. **The 2026-08-23 arch-aware carve-out lasted one day — since 2026-08-24 the contract demands the same FOUR on BOTH lanes again.** `Get-RequiredGstPlugin -Arch` dropped `tflite` on `arm64` via an `UnavailableOn.arm64` key on the claim "LiteRT is not built on that lane at all" — true when written, OBSOLETE since 2026-08-24: plain LiteRT builds on arm64 now (#115 done, § Windows Build Notes below), the `UnavailableOn.arm64` entry is DELETED, and the tflite integration block runs on cross too, with the meson flag presence-driven `-Dgst-plugins-bad:tflite=enabled` — never `auto`; the 2026-08-24 arm64 merge delivered all four, tflite included. Any arch filtering lives in the CONTRACT, never in a caller: the four enforcement points are exactly the things that must not disagree, so teaching only one of them about an arch would recreate the 2026-07-11 regression. amd64 is provably unchanged — no entry carries an `amd64` key, so the same four objects come back in the same order. Two of the four enforcement points are still arch-conditional on cross (an aarch64 binary cannot execute on this x64 host): the smoke-test payload assertions do not run on arm64 (see the smoke-gate entry below), and the post-install gate cannot `gst-inspect` — since 2026-08-24 it is HARDENED beyond its first "DLL was produced" form: it walks each plugin's dependency tree (`dumpbin`) AND asserts the per-plugin export marker `gst_plugin_<name>_get_desc`. That marker is itself a measured correction: modern GStreamer (>= 1.14 per-plugin registration) exports `gst_plugin_<name>_get_desc` + `_register`, NOT the legacy `gst_plugin_desc` the gate's first version asserted — that version failed all four plugins, three of them amd64-proven, and was recalibrated from the dumped export tables.
- **A missing stage artifact is a THROW, not a warning.** media-litert once "completed" without `litert_lm_main.exe` (configure had failed; the script only warned) and the degraded image would have shipped through merge/final. Every stage's terminal artifact check must throw (debug escape hatches env-gated, e.g. `LITERTLM_KEEP_BUILD_TREE`).
- **vcpkg ships zlib ONLY (protobuf removed 2026-08-03).** Nothing consumed vcpkg protobuf — every source build brings its own (ONNX `_deps`, LiteRT-LM's `protobuf_external` + downloaded version-matched protoc), and LiteRT-LM even had to hide vcpkg's protobuf headers to avoid version skew. Don't re-add it "for convenience"; it costs ~15 min of base build and creates header-leak hazards.
- **Python bindings plumbing is load-bearing (added 2026-07-13; full detail in `docs/windows-builds.md` § python coverage).** (1) The `sitecustomize.py` shim written by `Initialize-PythonPlatformTag` fixes clang-built CPython's win32 platform misreport (pip pulls 32-bit wheels without it) AND registers native DLL dirs (`os.add_dll_directory`; python ignores PATH for pyd deps) — never remove it. (2) OpenCV must keep `WITH_MSMF=OFF` **and** `WITH_OBSENSOR=OFF`: both hard-import Media Foundation, absent on Server Core — either ON makes videoio and the cv2 pyd unloadable. (3) Always `@()`-wrap `Save-PythonWheel` results: PS unwraps a 1-element array so `[0]` becomes the first *character* and pip once installed the PyPI package literally named `c`. (4) Binding asserts go through `Test-PythonImport` (cmd.exe-shielded): tvm writes warnings to stderr on successful imports, which raw `&` under EAP=Stop turns into false failures. (5) Wheels live at `C:\runtime\wheels` (`PYTHON_WHEELS`); the Orchestr-ANT-ion torch step resolves the app's LATEST tag per build and its wheel-smoke suite gates the final docker build — both amd64-lane facts: on arm64 the wheel store is EMPTY today even though `PYTHON_WHEELS` is advertised — but the INTERPRETER ships since 2026-08-24 (#120 step 1: target CPython built from source, `PCbuild\build.bat -e -p ARM64` with the repo's ClangCL props + `/p:PreferredToolArchitecture=x64`; `python.exe` PE `0xAA64` verified in-stage; 2864 files at `C:\runtime\python` — interpreter, `python314.lib`, headers, stdlib); the CONSUMERS (ORT wheel, GenAI bindings, cv2, PyAV) are #120 step 2, deliberately sequenced after that green. (6) PyAV is built from sdist against OUR FFmpeg (`setup.py --ffmpeg-dir`) — PyPI's `av` wheel is unloadable on Server Core (bundled avdevice imports desktop-only `AVICAP32.dll`); in headless code request software encoders by name (`mpeg4`) — the generic `h264` alias resolves to the hardware `h264_d3d12va`. (7) IREE (media-tvm branch, TVM→IREE chain) is a shallow-submodule git clone (release tarballs lack LLVM); its wheels come from the ninja build tree's synthesized `compiler/`+`runtime` pip dirs with `--no-build-isolation` — plain `pip wheel` of the repo would rebuild all of LLVM in an isolated tree. Native tools at `IREE_ROOT` (`C:\runtime\iree`); CUDA HAL/target need no nvcc (PTX via NVPTX, driver dlopens nvcuda.dll).

### TensorRT Setup (Optional)

TensorRT is **not downloaded automatically** — it requires accepting NVIDIA's EULA. To include TensorRT:

1. Download from https://developer.nvidia.com/tensorrt (e.g., `TensorRT-Enterprise-11.2.1.2-Windows-amd64-cuda-13.3-Release-external.zip`).
   **OWNER DIRECTIVE: always take the NEWEST release.** Never resolve a
   pin-vs-zip mismatch by lowering `TENSORRT_VERSION` — stage a newer zip.
2. Place the zip in `windows/downloads/` and **delete the superseded one**. The
   extract step version-sorts and takes the highest (a `[version]` cast, so
   `11.10.0.1` beats `11.2.1.2` — plain string sort gets that backwards), but a
   stale ~2 GB zip still bloats the `COPY downloads` layer.
3. Set `TENSORRT_ZIP_SHA256` in `versions.env` to the new zip's hash
   (`Get-FileHash -Algorithm SHA256 windows\downloads\TensorRT-*.zip`,
   lowercase). It was EMPTY until 2026-08-14, so ~2 GB of EULA-gated payload
   entered the image unverified. A stale hash now fails the build loudly — that
   is intended, not a bug.
4. It is auto-detected during the `Dockerfile.nvidia` build. `TENSORRT_VERSION`
   never derives a **filesystem** path — the tree is resolved from disk and
   normalized to `current` — and is otherwise used for drift REPORTING. One
   exception, so the claim is not read as absolute: `setup-tensorrt.ps1` still
   builds its NVIDIA CDN fallback URLs out of the pin, used only when no zip is
   staged.

If no zip is found, the build **skips TensorRT gracefully** (CUDA + cuDNN still work; `setup-tensorrt.ps1` warns and returns, ORT auto-disables the TensorRT EP, and the smoke test's `TENSORRT_ROOT` pointer passes on the guaranteed-empty `C:\tensorrt`). This zip-less configuration is the NORMAL state of this host's GPU lane. Do NOT re-harden this into a fail-fast: a 2026-08-04 "fail-fast" variant (premised on the wrong claim that the smoke test would reject a TensorRT-less nvidia image) broke the first hardened `-Gpu` rebuild and was reverted on 2026-08-05. The ORT build script auto-detects `$env:TENSORRT_ROOT` and enables the TensorRT EP when available.

**A PRESENT zip is a different matter and now fails CLOSED.**
`normalize-tensorrt-tree.ps1` (bind-mounted into the `trt-extract` stage)
renames the extracted `TensorRT-<version>` tree to a stable **`current`** and
throws if it carries no runtime DLLs. Absent zip = supported; half-extracted
tree = build failure. `Resolve-TensorRtRoot` prefers `current` and falls back to
the versioned glob for older images.

**Why `current` exists — two silent defects, both green for their whole life
(fixed 2026-08-14, backlog #38):** `Dockerfile.nvidia` used to build the runtime
PATH as `$TENSORRT_ROOT\TensorRT-$TENSORRT_VERSION\lib`, which was wrong twice
over. (1) The VERSION came from the pin, so it named a nonexistent directory the
moment the pin and the staged zip disagreed. (2) The DIRECTORY was `lib\` —
**TensorRT 10+ ships the runtime DLLs in `bin\`; `lib\` holds only link-time
`.lib` import libraries** (measured: 14 DLLs vs 6 `.lib`). So even a correctly
pinned image could never load the EP. Neither failed a build, because ORT
resolves its BUILD-time root with a glob and compiles the EP fine — only the
RUNTIME lookup broke, and ORT drops an EP with unreachable DLLs **silently**.
PATH now carries `current\bin` first, `current\lib` after it for the 8.x/9.x
layout. **Never derive that PATH from the pin again**, and note a Machine-PATH
write inside a RUN cannot substitute: `Dockerfile.base` sets `ENV PATH=` and the
image config wins.

### Windows Build Notes

The Windows lane source-builds the media stack with Ninja + clang-cl + lld-link (exceptions: CPython via `PCbuild\build.bat` with the VS ClangCL toolset; FFmpeg via MSYS2 `make` with `--toolchain=msvc`; GStreamer via Meson; LiteRT-**LM** via Bazel/bazelisk, `build-litert-lm-bazel.ps1`): CPython in the toolchain stage; ONNX Runtime → ONNX GenAI → OpenCV → FFmpeg in media-core; LiteRT (Ninja) → LiteRT-LM (Bazel) in media-litert; TVM → IREE in media-tvm; GStreamer in the merge stage. **That is the amd64 chain.** On `-TargetArch arm64`, `media-core` AND `media-litert` build — the "only `media-core` is buildable" this line said until 2026-08-24 fell with #115 that day; only `media-tvm` (IREE rides that branch and drops with it — it went unnamed here until 2026-08-24, a silent casualty) is still refused up front (`$crossBlockedBranches` in `build-buildkit.ps1`). The blocker history: LiteRT-LM's Bazel path has TWO real blockers (the original claim blamed only the prebuilt; a 2026-08-23 correction blamed only the bazelrc; both halves are real): upstream's `.bazelrc` defines no windows-arm64 config (only android/macos/ios arm64), AND the prebuilt **x86_64-only** `libGemmaModelConstraintProvider` sits in the default Windows dependency graph via `gemma3_data_processor` — but that prebuilt is severable with the `litert_lm_fst_constraints_disabled` config_setting (`model_data_processor/BUILD:26-33`), so "not fixable" overstated it. Neither blocker touches plain LiteRT (pure CMake, no Bazel, no prebuilt); its host-tools obstacle — backlog #115, RESOLVED 2026-08-24 — turned out to be TWO host tools, both provided from pinned sources: flatc built natively from the SAME source tree (`flatbuffers-flatc` target, per-call `-TargetArch host` override on the choke point; the note here used to name only the `TFLITE_HOST_TOOLS_DIR` flatc half) and protoc 21.9 (github release zip; version derived from the VENDORED protobuf commit `90b73ac3` = C++ runtime 3.21.9 — NOT the LM lane's `PROTOC_VERSION=31.1`, whose gencode needs `google/protobuf/runtime_version.h` that 3.21.9 does not ship). On arm64 the `media-litert` branch therefore runs with LiteRT-LM self-skipping — it reports the two Bazel blockers and stages the empty litert-lm stand-in tree for the merge COPY. The TVM half ("its own LLVM is `X86;NVPTX` only — not fixable in this repository") was WRONG outright: `LLVM_TARGETS_TO_BUILD` is an array `build-tvm-from-source.ps1` fully controls, so adding AArch64 is a one-token edit; the REAL remaining cross cost is that `USE_LLVM=<path>` must EXECUTE `llvm-config.exe` (needs a host-tools/target-libs split, backlog #116), and upstream IREE supports `IREE_HOST_BIN_DIR` for the same split. The merge's unconditional `COPY --from=media-tvm` is satisfied by the `media-branch-absent` stage, which stages those paths **empty** (a Dockerfile cannot branch on an ARG) — plus the bare `tvm\lib` and `iree\bin` dirs, because the merge bakes `TVM_LIBRARY_PATH`/`IREE_BIN` pointing there and the smoke pointer checks assert them (the first arm64 smoke run's two pointer failures, 2026-08-24) — so `$MergeRequiredBranches` is `media-core` + `media-litert` on that lane ("media-core alone" until 2026-08-24). All version pins come from `linux/scripts/01-core/versions.env` — never restate versions here (the duplicated tables this section used to carry drifted, e.g. the GenAI/LiteRT-LM labels).

- **Per-library reference** (generator/compiler per component, EP/delegate flags, patch stacks, RAM budgets, fallback paths): the authoritative table is `docs/windows-builds.md` § Component Build Matrix.
- **Per-script reference** (every build/setup/verify and HOST-maintenance script, with flags, gotchas and refusal conditions): the authoritative table is `docs/windows-builds.md` § Windows Script Reference.
- Build sequence and commands: `docs/windows-builds.md` § Build Commands; container validation: § Smoke Testing there.

Update those tables in `docs/windows-builds.md` — this section stays a pointer. The Windows Build Invariants above remain here because they are agent-behavioral rules, not reference data.

### Orchestrator Stage Selection

```bash
# Resume mid-chain (e.g., after rebuilding compiler)
bash linux/scripts/build-cross-chain.sh --from-stage sdk --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Build only one stage for one architecture
bash linux/scripts/build-cross-chain.sh --only media --target-arches arm64 --log-dir ./out/build-logs

# Build per-arch stages in parallel (faster on multi-core machines).
# PAR4 (VALIDATED through wave-4, 2026-08-21): cross_build_mem_divisor
# multiplies the arch count by PAR_INTRA_STEP_BUDGET (default 2) for
# PER-ARCH stages, and uses divisor 1 for SHARED stages (base/compiler run
# alone — the ×budget throttled the compiler to 1/3 jobs once). Across ~12
# parallel media rounds: ONE isolated OOM kill, absorbed by retries. If a
# lane OOMs repeatedly raise PAR_INTRA_STEP_BUDGET=3 or use
# PARALLEL_STAGES=sdk,android. Details: docs/build-parallelism-memory-tuning.md.
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

The **Windows lane** follows a separate staged build (`base → [nvidia] → toolchain → media → torch → final`; torch assembles the Orchestr-ANT-ion app env, `local/kataglyphis:windows-torch`, and final builds FROM it) driven by `windows/build.ps1`, which uses Stevedore's `docker.exe` for builds (`nerdctl build` has broken DNS on Windows). The `windows-sdk` tag is either a plain re-tag of `windows-base` (CPU lane, default) or the NVIDIA GPU stage `Dockerfile.nvidia` (`-Gpu` switch) for a CUDA-enabled image. See `docs/windows-builds.md` § Build Commands for the full build sequence and prerequisites.

### Prerequisites

- **nerdctl** with BuildKit backend
- **QEMU/binfmt** for foreign-architecture runtime builds. Registration is lost
  on host reboot **and on `systemctl --user restart containerd`** (it lives in the
  rootlesskit namespace — that's how it silently vanished on 2026-08-08 after the
  shim-failure restart). On this rootless host the privileged
  `tonistiigi/binfmt --install` container does NOT work (wrong namespace); use:
  ```bash
  linux/scripts/setup-rootless-binfmt.sh --arches arm64,riscv64 --install-service
  ```
  `--install-service` installs a systemd --user unit so re-registration is
  automatic. Without registration, foreign-arch execs fail with `exec format
  error` — including wrong-arch NATIVE tool sub-builds inside "no-emulation"
  cross stages (the IREE tblgen failure mode).
- **Registry access** (GHCR) for pushing intermediate and final images
- **Disk space**: ~50GB+ for full cross chain with all architectures
- **Python 3** for digest resolution (`registry-digest.py`)

### Windows Prerequisites (see `docs/windows-builds.md` § Prerequisites)

- **Stevedore** (`winget install stevedore` or `choco install stevedore`) — provides nerdctl + containerd for Windows Containers
- **Reboot** after Stevedore install to enable the Windows Containers feature
- **Docker Desktop or Rancher Desktop** can also be used with `docker` commands (swap `nerdctl` → `docker` in build commands)
- **CNI nat conf (historical note)**: before 2026-08-03 `nerdctl run` failed on this host (no CNI `nat` **conf**) and `nerdctl build` had broken DNS, so docker.exe was the only working tool. Since 2026-08-03 `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` is installed (see `docs/windows-builds.md` § Getting it going, step 2 — including the subnet-drift trap) and nerdctl works — from **admin** shells only (containerd's pipe is admin-only). Stevedore's `docker.exe` remains the classic-lane tool and needs no CNI plugin. Run with `--isolation process` for the host's full CPU count (Hyper-V isolation is capped at 2 CPUs). See `docs/windows-builds.md` § Running the Image.

### Stevedore Fixes After Install

Apply the post-install fixes documented in `docs/windows-builds.md` § Stevedore Setup Fixes (Defender exclusions, daemon.json cleanup, default runtime change, verification). Those instructions are the canonical source — keep them in sync instead of duplicating here.

### Supported Platforms

| Component | Build platform | Target platforms |
|-----------|---------------|------------------|
| Cross lane (stages 1-5) | `linux/amd64` | `amd64`, `arm64`, `riscv64` (cross-compiled) |
| Runtime lane (stage 6) | Native or QEMU | `linux/amd64`, `linux/arm64`, `linux/riscv64` |
| Final manifest | N/A | Multi-arch: `amd64`, `arm64`, `riscv64` |
| Windows lane | `windows/amd64` | `windows/amd64` (native Windows Containers) |
| Windows cross lane | `windows/amd64` | `arm64` artifact bundle (clang-cl `aarch64-pc-windows-msvc`; **not** a container image) |

### Expected Outputs

After a successful `build-cross-chain.sh` run:
- All cross-lane intermediate images pushed to GHCR
- Per-architecture wrapper images (`:latest-cross-<arch>`) pushed to GHCR
- Multi-arch manifest (`:latest-cross`) pushed to GHCR

---

## Repo Map

```
linux/scripts/
├── 01-core/             shared utilities (59 as of 2026-08-14 — `ls linux/scripts/01-core/*.sh | wc -l`; the literal said 48 for long enough that README repeated it, so treat any count here as indicative: versions.env, logging, platform, cross-env, cross-gcc, cross-meson, cross-apt, compiler-resolution, tag-naming, stage-defs, digest-pinning, ancestry, build-helpers, cli-parsers, …)
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
                         discovery, LD_LIBRARY_PATH, per-profile hooks),
                         cmake-build.sh, code-quality.sh, coverage.sh,
                         slang-compile.sh, wasm-opt.sh, ctest-run.sh (ctest
                         runner + perf-baseline comparator), docs-build.sh
                         (Sphinx build helper), rust-toolchain.sh — the last
                         three had NO doc entry anywhere until the 2026-08-08
                         orphan sweep; nothing in-repo invokes lib/, it is a
                         consumer surface shipped into the images
linux/scripts/02-toolchain/rust/   cargo_* helpers (test/bench/fmt+clippy/
                         security/coverage/release/update/doc via
                         _cargo_wrapper.sh) — consumer surface COPY'd into the
                         toolchain/sdk/package images; nothing in-repo calls
                         them (the redundant zero-ref Build-Linux.sh duplicate
                         was deleted 2026-08-08)
linux/scripts/02-toolchain/python/ci_*.sh   Python CI helpers (tests, static
                         analysis, packaging, docs) — same consumer-surface
                         status as rust/
linux/scripts/01-core/setup-host-deps.sh    hand-run host bootstrap (rootless
                         nerdctl/buildkit prerequisites); intentionally not
                         wired into CI or builds
linux/scripts/06-packaging/package_archive.sh   tar/deb/AppImage/Flatpak
                         assembly — consumer surface. Called from
                         Kataglyphis-RustProjectTemplate's
                         .github/workflows/rust_ubuntu24_04.yml release job.
                         Deleted by the 2026-08-08 orphan sweep as
                         "zero-reference" and restored 2026-08-11: the sweep
                         searched only THIS repo, so a consumer's CI lane was
                         broken silently. Grep the consumer repos before
                         deleting anything under lib/, rust/, python/ or
                         06-packaging/.
windows/scripts/         Windows lane, GROUPED since #108 (2026-08-20):
                         build/ (chain components: build-*-from-source.ps1,
                         *-all wrappers, smoke-test-container, load-versions),
                         host/ (setup-*/apply-*/repair-*/reset-* + elevated
                         maintenance), diagnostics/ (probe-*/test-* + the
                         run-diagnostic-probe runner; settled one-shots in
                         diagnostics/archive/, still runnable via
                         -ProbeScript archive/<name>.ps1). Container mounts
                         stay FLAT (C:\bkmnt, C:\temp\scripts) — the
                         $scriptAssetRoot resolver bridges both layouts and
                         is gated by ScriptAssetRoot.Parity.Tests.
                         Ungrouped residents BY DECISION (#131):
                         Invoke-Lint.ps1, entrypoint.cmd, cargo-retry.cmd
                         (consumer-CI suspect — never delete unverified),
                         certificates/ (MSIX cert generation + WebDAV
                         download_webdav_files.py — see its README.md),
                         python/ + rust/ (consumer CI-lane drivers).
                         modules/*.psm1 (reusable PS modules: SourceBuild,
                         Build.Common, ContainerBuild.Reuse, AgenticLoop,
                         CMake, Config, Formatting, Msix.{Common,Signing},
                         WebDav, Uv, Scripts.Shared, Toolchain, CodeQL,
                         ContainerImage, Flutter, Installer,
                         HostMaintenance, SmokeTest, GstPlugins, …),
                         tests/ (harness + suites), shims/
windows/upstream/        prepared upstream submissions (not build inputs):
                         hcsshim-teardown-timeout/ = ISSUE.md + PR.md +
                         format-patch making the shim teardown timeouts
                         configurable, plus the deployed 45min local patch
                         and the rebuild recipe (see its README.md);
                         sccache-nvcc-quote-fix/ = the 0003 diag-family
                         patch riding until mozilla/sccache#2816 merges
                         (0001/0002 merged upstream in #2811; the dir is
                         ALSO a build input — setup-rust-toolchain applies
                         0003 on top of the pinned rev)
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

## Shell safety conventions (five bug classes, all found live 2026-08-08)

Every one of these killed or falsified a real build before being fixed. The
full stories are in `CHANGELOG.md` (2026-08-08); `tests/test-ifs-safety.sh`
lint-gates class 3. When writing or reviewing bash in this repo:

1. **No `trap … RETURN` inside functions** — the trap survives the function and
   fires again on the CALLER's return, where the locals are gone (`set -u`
   abort AFTER a green run). Capture rc with `|| rc=$?`, clean up explicitly.
2. **Guard every pipeline whose empty result is legitimate** — `grep`/`find`/
   `ls`/`du`/`pgrep`/`dpkg -S`/`readelf` in `$(...)` under `set -euo pipefail`
   needs `|| true` when the code below handles the empty case. `find | head -1`
   additionally dies of SIGPIPE (rc 141) on multiple matches.
3. **Split comma lists with `IFS=',' read -r -a arr <<< "$list"`** — never
   `${list//,/ }` or `$(... tr ',' ' ')`: under a script's `IFS=$'\n\t'` those
   do not split and the loop runs once with the whole list as one bogus item.
   Sourced 01-core functions run under the CALLER's IFS. The two list helpers
   (`arch_list_to_words`, `smoke_arch_words`) emit NEWLINE-separated words
   since 2026-08-08 precisely so `for x in $(...)` splits under any IFS —
   keep that property if you touch them (test-smoke-arch-parity.sh pins it).
4. **Source vendor scripts (SDK setup-env, venv activate) with nounset
   suspended** — `case $- in *u*) …; set +u;; esac` … `set -u` after. LunarG's
   setup-env.sh reads `$1` unguarded.
5. **Never end a function with a bare `[ cond ] && action`** — the false case
   becomes the function's return value 1; under `set -e` the HEALTHY path kills
   the caller. End with `|| true`, `; return 0`, or an `if`.

## Caching discipline (do not regress)

Full map: `docs/linux-build-basics.md` § Caching Layers. Toggles: `USE_CCACHE`,
`USE_SCCACHE`, `USE_LLD` accept `0/false/no/off` to disable (since 2026-08-08 —
previously ONLY the literal `false` worked and `USE_CCACHE=0` was silently
ignored); `ENABLE_SCCACHE_RUST`/`ENABLE_SCCACHE_CUDA` are strict `0/1`.
The rules an agent must never violate:

1. **Closure freeze between runs that should cache-hit.** Editing ANY file in
   the base/toolchain closure changes the compiler image digest and forces
   sdk/media/android to rebuild from scratch on the next run. Since 2026-08-08
   (A1 applied, commit 5d7a318) **`Dockerfile.base` mounts a traced 15-file
   closure**, not whole directories — the closure is now: those 15 files
   (13× `01-core` + `cmake.sh` + `packaging-deps.sh`; the lists live in
   Dockerfile.base itself), `versions.env`, `python/build_python.sh`, the
   three bundled `06-packaging/smoke-*` scripts, `Dockerfile.base`,
   `Dockerfile.toolchain`. Editing 01-core files OUTSIDE those lists no longer
   busts base — but a file NEWLY needed by a base RUN must be ADDED to the
   per-file mount lists (closure = source edges + **exec/`bash` edges**; the
   A1 validation build caught exactly such a miss). Batch closure edits;
   apply them in ONE commit at
   a planned rebuild boundary. Files in a not-yet-started stage's closure are
   free to fix until that stage begins (each `nerdctl build` snapshots its
   context at stage start).
2. **`~/.config/buildkit/buildkitd.toml` pins the GC budget** (`gckeepstorage`)
   so the multi-hour layers survive between runs. Restart buildkitd only
   BETWEEN runs (`systemctl --user restart buildkit`), never while a build
   solves. Do not delete this file.
3. **The compiler-cache HYBRID is doctrine, keep it wired**: ccache for C/C++
   (GCC via `--ccache` in `gcc.sh`'s three `build-gcc.sh` call sites, LLVM via
   cmake launchers + the ccache/sccache cache mounts on BOTH heavy RUNs in
   `Dockerfile.toolchain`), sccache for Rust + the GPU
   compilers (`ENABLE_SCCACHE_RUST`, `ENABLE_SCCACHE_CUDA` — gated until
   validated; ccache can wrap neither rustc nor nvcc/hipcc, while sccache's
   plain-C/C++ path loses to ccache's direct mode). Never "simplify" to a single tool; see
   docs/linux-build-basics.md § Why the HYBRID. The failure mode
   this replaced (mount without wiring, wiring without mount) was invisible —
   builds stayed green, just slow. When touching these paths, verify with
   `grep -c ccache <stage>.log` on the next build.
4. **Never edit a running orchestrator's main script** (`build-cross-chain.sh`
   while a chain runs): bash reads it incrementally by byte offset; an edit can
   corrupt the in-flight process. Sourced library files are safe to edit for
   FUTURE runs (the running process holds them in memory) but see rule 1.
5. **The WINDOWS chain caches differently — do not assume rules 1-4 apply.**
   It relies on (a) deliberate layer ORDERING — `setup-vs.ps1` sits ABOVE the
   `versions.env` COPY in `Dockerfile.base` so a pin bump cannot re-pay VS
   Build Tools (confirmed live 2026-08-08: 4 of 16 base steps CACHED through a
   PYTHON_VERSION bump, and they were the expensive ones), (b) a five-file
   in-container module closure so host-only module edits cannot bust a compile
   layer, and (c) sccache. **Preserve (a) and (b) in any Dockerfile edit** —
   moving a COPY above the VS layer, or widening the module COPY, costs hours
   per bump.

   **Wired 2026-08-08** (this list said "not wired" the same morning — it is
   current as of that afternoon):
   - **sccache — WebDAV remote ONLY since 2026-08-16.**
     `SCCACHE_MULTILEVEL_CHAIN` is an ARG defaulting to `""` in
     `Dockerfile.media-builder`'s `common` stage AND in the merge builder (not a
     descendant, so the ENV is repeated — change BOTH or neither). The two-tier
     layout `disk,webdav` is what it *was*, and the owner wants it back once
     WCOW cache mounts mature; it is off because **BuildKit cache mounts on
     Windows lose writes** once the directory holds objects an EARLIER RUN
     wrote (158 of 250 vs 0 of 250 into a plain directory; a fresh dir on the
     same mount is fine). Note this is the same family as the already-known
     "directory RENAMES fail on cache mounts" caveat further down this rule.
     Full measurement + the two-step re-verification recipe: `docs/windows-builds.md` #99.
     `SCCACHE_DIR` ALONE DOES NOTHING — without the chain variable sccache is in
     single-level mode, and with a remote configured that means remote-only.
   - **sccache is BUILT FROM SOURCE** at `SCCACHE_GIT_REV`, not installed from
     scoop, and this is load-bearing: released sccache cannot wrap nvcc on CUDA
     13.3 — it parses `nvcc --dryrun` positionally, 13.3.33 moved `--simt-only`
     after the input file, and the build DIES with `fatbinary fatal: Could not
     open input file '<tu>.compute_80.cubin'` (mozilla/sccache#2722, merged
     2026-08-04, five days AFTER v0.17.0 shipped). `verify-toolchain.ps1`
     asserts sccache resolves from `CARGO_BIN`, because `--version` cannot tell
     the fixed and broken builds apart — main still reports 0.17.0.
   - **`CMAKE_CUDA_COMPILER_LAUNCHER` is ON BY DEFAULT since 2026-08-18**
     (`SCCACHE_CUDA_LAUNCHER="1"` in the media-core-built-onnx stage): the
     2026-08-10 miscompile (dropped instantiations, `lld-link: undefined
     symbol`) was root-caused to sccache's Windows dryrun quote-collapse —
     `\"` escapes flattened before tokenization packed ~30 `-D` pairs into
     one 493-char token, so the cpp4 preprocess lost `USE_CUDA` & friends —
     fixed upstream (mozilla/sccache#2811, MERGED 2026-08-19 =
     SCCACHE_GIT_REV ffac4a5); the local series in
     `windows/upstream/sccache-nvcc-quote-fix/` now carries only 0003
     (--diag-suppress separated form, OpenCV #115 — its own PR is drafted,
     owner submits), applied by the base rust layer (#114). The
     three-canary bar passed 2026-08-18 evening: fused_moe compile green,
     providers_cuda link green COLD (153 CUDA device writes), link green on
     the HIT run at **100.00% CUDA/PTX/CUBIN hit rate** (207/816 hits) —
     onnx's CUDA portion drops from ~60 to ~33 min warm. The #2808 DEADLOCK
     separately proved to be #99 collateral (gone under a healthy backend).
     Patch 006 (bare fused_moe) was RETIRED 2026-08-18 (moe compiles
     through the launcher, link green). Opt out per run with
     `-BuildArg SCCACHE_CUDA_LAUNCHER=`;
     never flip the default off silently, and never bump SCCACHE_GIT_REV
     without checking the patch series still applies (the rust layer THROWS
     if not).
   - **uv/pip wheel cache** in `Dockerfile.torch`, set INSIDE the RUN (an `ENV`
     would bake a build-only mount path into the shipped image).

   Still NOT wired, with a measured reason: **source-fetch mounts.** The clones
   are shallow (`Invoke-GitClone` passes `--depth`), so they cost minutes
   against compiles that cost hours. If you do it, cache the ARCHIVES/CLONES
   only, never the working tree — directory RENAMES fail on cache mounts and
   `build-gstreamer-from-source.ps1` moves the extracted tree. Also raise the
   tier-0 `type==exec.cachemount` cap in `windows/buildkitd.toml` — it is
   **shared** by every cache mount plus local sources and git checkouts, and
   the sccache L0 (15G) and uv cache (10G) already claim most of it. Cache
   sizes and that cap are ONE decision, not two. (Since 2026-08-16 the L0 mount
   is attached but DORMANT — the chain defaults to WebDAV-only — so its 15G is
   reserved rather than consumed. Do not repurpose that headroom: the tier is
   meant to return, see #99.)

## Code Organization (key shared utilities)

- **Architecture resolution:** `platform.sh` → `canonical_target_arch()`, `canonical_resolve_arch()`. Single source of truth — never use ad-hoc `dpkg`/`uname -m`.
- **Architecture list resolution:** `artifact-common.sh` → `resolve_arch_list()`. Normalizes `TARGET_ARCHES` from canonical name + aliases with fallback. Use instead of 4-level fallback chains.
- **Dry-run guard:** `build-helpers.sh` → `is_dry_run()`, `_bool_truthy()`. Use instead of `[ "${DRY_RUN:-0}" -eq 1 ]`.
- **Module loading:** `modules.sh` → `source_modules_framework()`. Bootstrap pattern for sourcing 01-core.
- **Media bootstrap:** `03-media/core/common.sh` → `media_common_init <script_dir>`. Single DRY entry that sources the 01-core module framework. Every media build script sources this instead of duplicating a preamble block. (The old `media_build_preamble_init` alias no longer exists — zero callers and zero definition remain.)
- **CC validation:** `validate-compilers.sh` → `_validate_cc_target()` (dumpmachine/ELF/cc1/link smoke).
- **Cross-chain tags:** `tag-naming.sh` → `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag()`, `cross_media_tag()`, `cross_android_tag()`, runtime tag functions. Never construct tags manually.
- **Stage graph:** `stage-defs.sh` → `CROSS_STAGE_ORDER` (base→compiler→sdk→media→android→runtime), `RUNTIME_STAGE_ORDER` (base→package→wrapper). Pin init: `cross_stage_init_pins()`. Validation: `cross_stage_validate_graph()`. Cross→runtime handoff: `cross_stage_ensure_parent_available()`.
- **Chain verification:** `chain-verify.sh` → `verify_cross_chain_staleness()`, `describe_cross_chain()`. Informational only — it prints digests, it does not gate a build.
- **Stage ancestry (gating):** `ancestry.sh` → `ancestry_output_annotations()`, `ancestry_recorded_parent()`, `ancestry_assert_chain()`. Every pushed cross stage records the parent ref it was built FROM as the OCI manifest annotation `org.kataglyphis.parent-digest`; a run with `--from-stage` after `base` walks that chain and HARD-FAILS when a parent was re-pushed after the child that would be inherited. Read path: `manifest-annotation.py` (annotations live in the base64 `Raw` field of `manifest inspect --verbose`). Absent annotation = warn (predates the mechanism); present + mismatch = fail. Escape hatch: `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0`.
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
1. `common.sh` 2. `tag-naming.sh` 3. `stage-defs.sh` 4. `digest-pinning.sh` 5. `chain-verify.sh` 6. `ancestry.sh` 7. `build-helpers.sh` 8. `cross-stage-build.sh` 9. `context-management.sh` 10. `version-forwarding.sh` 11. `cli-parsers.sh` 12. `runtime-build-fns.sh` 13. `compiler-resolution.sh` 14. `parallel-loop.sh` 15. `abseil-headers.sh` 16. `path-helpers.sh`.

`runtime-flow-common.sh` is sourced directly by `build-runtime-artifacts.sh` and `build-runtime-manifest.sh` (after `artifact-common.sh`).

**Which loader a NEW script should use (the dual-loader rule):** scripts that
also execute INSIDE containers (bind-mounted or COPY'd — base-image, 02-toolchain,
03-media, 06-packaging) load via `modules.sh` / `source_module`, which resolves
both the repo layout and the `/opt/scripts` container layout. Host-only
orchestration (`build-cross-*.sh`, runtime flows) sources `artifact-common.sh`
directly. Do not mix: a container-capable script hard-sourcing repo paths breaks
at `/opt/scripts`. (Known wart: `modules.sh` hardcodes a `../02-toolchain`
search path — a 01-core file encoding stage-2 layout; fold a fix into any
future `modules.sh` touch. The layer order itself is frozen by
`tests/test-layer-order.sh`.)

## Cross Chain Stage Handoff (do not regress)

The cross lane is a sequence of separate `nerdctl build` invocations where each
stage does `FROM ${BASE_IMAGE}`: `base → compiler → sdk → media → android →
package → torch → wrapper → manifest`. The base-image handoff MUST NOT rely on a
bare mutable tag, or a stage can silently consume a STALE locally-cached image.

`--output type=image,name=...` does not reliably refresh the local containerd
tag; BuildKit's default `FROM` prefers an already-present local image. So
rebuilding `media` then building `android` can quietly reuse the old `media`.
**This is not just a `FROM` hazard — it broke the runtime wrapper's OWN tag.**
On this rootless nerdctl host, `nerdctl build --output type=image,name=X`
creates NO local tag X at all (verify: `--output type=image,name=X` → X absent
from `nerdctl images`; `-t X` → present). The runtime lane used the annotated
`--output type=image,name=<tag>,annotation.*` exporter to tag the wrapper, so
the freshly built wrapper was invisible and `nerdctl push <tag>` +
`nerdctl manifest create <tag>` resolved the STALE pre-existing tag — shipping
`:latest-cross` byte-identical five times (2026-08-14/15, amd64 frozen at
`35c1f1df`). FIXED: `runtime-build-fns.sh append_runtime_image_output` now uses
plain `-t` on both paths (reliably creates AND overwrites the tag). Do NOT
reintroduce the `--output type=image,name=` exporter for a tag you then push or
index — use `-t`. (The dropped ancestry annotations never reached the registry
anyway; re-embedding them is a tracked follow-up.)

Rules:

0. **The chain now checks this for you.** A run starting after `base` asserts the
   recorded ancestry of every stage it inherits (`01-core/ancestry.sh`) and
   refuses to build on a parent that was re-pushed after its child. Rules 1-4
   below describe what that check enforces and what its failure message asks you
   to do — they are no longer yours alone to remember. Bypass only deliberately,
   with `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0`. Images built before
   this mechanism carry no annotation and only warn, so a chain that predates it
   still needs rules 1-4 applied by hand until each stage has been rebuilt once.
1. When ANY base image in the registry tag hierarchy is replaced, rebuild every
   downstream image from the replaced stage, OR verify the downstream images
   already contain the new content (e.g. check `/opt/gcc-16.2.0-native-arm64`
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
- Do not remove LLVM/Clang features to make foreign-arch builds pass. Foreign-arch runtime images must keep source-built `clang 22.1.8` (not Ubuntu `clang 22.1.2`). Source-built GCC (`GCC_VERSION`, currently 16.2.0) at `/opt/gcc-${GCC_VERSION}` is the default `cc`/`c++` on all arches. On `arm64`/`riscv64`, GCC is cross-compiled (Canadian cross) and swapped in at the Android stage via `Dockerfile.android`.
- **Supply-chain discipline (audit 2026-08-08).** Every network fetch is verified: trust anchors (CUDA keyring, ROCm key), toolchains (Vulkan SDK, Android cmdline-tools, Flutter, rustup/uv installers) and header tarballs carry sha256 pins in versions.env; `download_verified_file` is the default fetch, `download_file` needs a reason. Python **build executors** (meson/ninja/cython/pybind11/setuptools/wheel/auditwheel/patchelf — anything that runs code at build time or rewrites shipped binaries) are pinned via the `PY_*_VERSION` family; bump them TOGETHER, deliberately, with a real build — never let an install site float back to `-U pkg`. Never `curl | sh`; clone at tags with `--depth 1 --branch` and hard-fail on a missing tag rather than falling back to a branch.
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
  list.** The authoritative check inventory is its `KNOWN_SLUGS` array (do NOT
  enumerate it here — this very paragraph went stale by three slugs once);
  `tests/test-preflight-slugs.sh` enforces that every slug has a registered
  check and vice versa. Newest additions: `python-lint` (ruff, hard on
  real-error classes, advisory rest), `secret-scan` (gitleaks, enforcing,
  false positives via `.gitleaksignore` with justification), `stage-graph`.
  CI workflows and `.githooks/pre-commit` run SUBSETS of it via
  `PREFLIGHT_ONLY=<slugs>` / `PREFLIGHT_SKIP=<slugs>` — never copy the check
  list into a new caller.
  On Windows hosts: `PREFLIGHT_PYTHON="uv run --no-project python" bash linux/scripts/preflight.sh`.
- **Linux host config is code**: `linux/host-config/` carries the canonical
  rootless-BuildKit `buildkitd.toml` (gc keep-budget + cachemount-sparing
  gcpolicy pair + max-parallelism) and the systemd drop-in.
  `apply-host-config.sh` installs (refuses while a chain runs; daemon restart
  is a printed operator step), `verify-host-config.sh` warn-diffs live vs
  repo. Exists because a live-only toml edit silently regressed once —
  reconcile drift through the repo, never by editing `~/.config` alone.
- **Linux disk reclaim: `linux/host-config/prune-safe.sh`, NEVER
  `nerdctl builder prune -f`** (CACHE1, 2026-08-17). The -f prune deletes
  `type==exec.cachemount` records — ccache/sccache/uv/cargo/llvm-src, hours
  of compile time in a few GB — together with the cheap-to-regenerate layer
  cache (measured 207 GB vs 4.9 GB); one run paid ~1.5-2 h of cold LLVM
  rebuilds for it. prune-safe.sh prunes `type==regular` only via buildctl's
  `--filter` (nerdctl has none), takes `PRUNE_KEEP_GB`/`DRY_RUN`, and proves
  cachemount survival before/after. Battle-proven through wave-4: 12
  invocations, ~1 TB reclaimed, 0 cachemount losses. Mid-run, use
  `PRUNE_KEEP_GB>=100` — smaller budgets evict the IN-FLIGHT lanes' fresh
  layers and buy recompile churn; the kata-buildcache media slugs
  (rewritten every round) are the better lever when the store runs lean. Mid-run lever ORDER:
  (1) prune-safe.sh, (2) `nerdctl rmi` of specific already-pushed tags
  (refuses in-use ones — safe), (3) `nerdctl system prune` NEVER while a
  chain runs — "unused" means not-container-referenced, so it deletes TAGGED
  cross-stage locals too (2026-08-18: cross-media-* vanished mid-run; the
  registry-digest-pinned handoffs survived via re-pull, costing ~25 min).
- **ghcr REGISTRY hygiene: `linux/host-config/ghcr-prune-package.sh`**
  (2026-08-24). The container package accumulates one untagged version per
  re-pushed moving tag; it had grown to 771 versions (~85% dead). NEVER
  "delete all untagged" by hand — the per-arch entries of a multi-arch index
  are themselves untagged manifests, and a chain that is pushing creates
  untagged manifests seconds before tagging them. The script's keep-set is
  tags + every index CHILD (resolved live, abort on any unresolvable tag) +
  the digest each tag currently resolves to + everything younger than
  `KEEP_DAYS` (default 7). Dry-run by default; `GHCR_PRUNE_CONFIRM=1`
  deletes, re-checking each version's tags immediately before its DELETE.
  First confirmed run: 604 deleted, 0 failed, `:latest-cross` + all
  cross-stage tags verified 200 afterwards, running build untouched. Known
  pre-existing damage it did NOT cause: legacy tags android/compiler/latest/
  media/sdk/torch were already dangling (children 404) before the tool
  existed.
- **HOST DISK RECLAIM IS ALLOW-LISTED AND DEFAULT-DRY —
  `windows/scripts/host/free-disk-space.ps1`, and NOTHING ad hoc** (2026-08-21,
  the worst incident this repo has produced). A "let's free some space"
  command was composed on the spot, handed over for an elevated shell, and did
  not stop at the container stores: it walked into the installed programs and
  the user profile and took the host with it — editor, VCS, GPU driver stack,
  container runtime, the PowerShell 7 this repo's whole gate suite needs, all
  reinstalled by hand. Nothing in the loop said no, because a blanket delete
  rule had been allow-listed in `.claude/settings.local.json`. The rules now:
  - **The reclaim script is the only sanctioned path.** It cleans exactly the
    regenerable classes — unused container layers (via the daemon's own GC),
    dead `*.bak-<stamp>` store husks, user + Windows TEMP, rotated host logs,
    repo `out/` scratch — resolved from an ALLOWLIST, reports by default, and
    needs `-Apply` to touch anything. Every live-directory rule is AGE-GATED
    (`-TempOlderThanDays`, default 7) so nothing in flight is deleted. It
    aborts the WHOLE run — not just the one target — if any resolved candidate
    lands on a protected root, because a candidate that lands there means the
    resolution logic is wrong and the rest of the plan is untrustworthy too.
  - **A name is not a target.** A candidate containing a junction or symlink is
    skipped: every path check reasons about names, and a reparse point is
    exactly where a name stops predicting what a recursive delete reaches — a
    cleared candidate could otherwise tunnel straight into the profile.
  - **The compile caches are NOT cleanup targets.** sccache/ccache/cargo/uv
    read as "cache" and are the most expensive bytes on the disk (CACHE1: a
    prune once traded ~1.5–2 h of cold LLVM rebuilds for a few GB). The
    reclaim script never lists them, and neither should you.
  - **Daemon levers before filesystem levers, always.** `buildctl prune
    --free-storage`, `docker image prune`, the store-GC sequence in
    `docs/windows-builds.md` § Store GC. They hand back far more and they know
    what is still referenced. Filesystem reclaim is a last resort limited to
    dead `*.bak-<stamp>` husks.
  - **Protected roots are OFF LIMITS to the agent, permanently**: `C:\Program
    Files`, `C:\Program Files (x86)`, `C:\Windows`, `C:\ProgramData` outside
    the container stores, any user profile under `C:\Users`, `AppData`,
    per-user tool directories (`.vscode`, `.ssh`, `scoop`, `.claude`), drive
    roots, and every installed-package or driver store. Not with a flag, not
    with a force switch, not "just this once". Space that only comes back by
    reaching in there is a reinstall, not a cleanup — and it is the user's
    call, run by the user, outside the agent.
  - **Uninstalling the user's software is never the agent's move.** No package
    manager removals, no MSI removals, no appx removals. Suggest, never do.
  - **The gate is mechanical, not advisory.**
    `.claude/hooks/guard-destructive-deletes.ps1` runs as a `PreToolUse` hook
    (registered in both `.claude/settings.json` and the user-level settings, so
    one broken path cannot silently disarm it). It DENIES — a decision no
    prompt can override — any command touching a protected root, and it scans
    file CONTENT on Write/Edit too, because the 2026-08-21 vector was a script
    written for the user to paste, not a command the agent ran. Outside the
    protected roots it downgrades to a prompt rather than a block.
    `windows/scripts/tests/Guard.DestructiveDeletes.Tests.ps1` is the incident
    in executable form; it also fails if a settings file ever re-introduces a
    blanket delete permission. If a guard regex ever needs relaxing, that is a
    reviewed repo change with a test — never a bypass in the moment.
- PowerShell gate: `pwsh -File windows/scripts/Invoke-Lint.ps1` +
  `pwsh -File windows/scripts/tests/Invoke-Tests.ps1` (also run in CI by
  `.github/workflows/windows-scripts.yml` on windows-latest). The suite is
  zero-dependency and guards *classes* of defect, not just instances — e.g.
  `Driver.ClosureScope.Tests.ps1` walks the AST of both drivers and fails any
  `.GetNewClosure()` block inside a function that reads a top-level `param()`
  variable, because that silently resolves to EMPTY and broke the scripted
  resume for months (backlog #40). Same shape elsewhere:
  `Dockerfile.EolAttributes.Tests.ps1` walks the real COPY instructions and
  fails any COPY-reachable file with no frozen git EOL attribute (#55);
  `Patches.CmakeNoOpGuards.Tests.ps1` fails unguarded source rewrites (#56);
  `Pins.CanonicalValues.Tests.ps1` pins CUDA_ARCHITECTURES at versions.env
  itself rather than at a code fallback the real build path never reaches, and
  compares every merge-builder ARG default against the pin (#58, #60). Each
  carries a rot guard so a moved target cannot make it pass vacuously.
  When you fix a bug here, prefer a guard for its class.
  Note the linter also exits **2** for an INFRASTRUCTURE failure — PSScriptAnalyzer
  1.25.0 throws intermittently (~2 in 9 runs) and an exception is not a finding;
  files are retried once and never silently skipped (#82). And CI currently runs
  the linter WITHOUT `-FailOnAnalyzer` while `main` is not branch-protected, so
  this gate is advisory (backlog #59).
- For runtime verification, check inside a container or inspect raw symlink targets. Do not use `readlink -f` against `out/linux-runtime/*/rootfs` (absolute symlinks resolve against host root).
- Confirm on all arches: `clang --version` reports `22.1.8`; `cc -dumpmachine` matches arch; `gcc --version` reports `16.2.0`; symlinks `cc/c++/gcc/g++ → /opt/gcc-16.2.0/bin/*`; `clang → /usr/local/llvm-target/bin/clang`; optional runtime payloads present.
- Use the `wrapper-smoke` target (see `docs/linux-build-basics.md`) for cheaper packaging validation before large publish runs.

## Common Failure Modes

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Windows-container build `COPY`/layer commit dies `hcsshim::ActivateLayer 0x20` (buildkit `failed to import/reimport snapshot`, on ANY layer writing into an existing parent dir; docker-classic legacy dies `mkdir \\?\Volume{<GUID>}\C:.` invalid dir name) | **RESOLVED 2026-08-10: an ENABLED AMD RDNA4 dGPU (RX 9xxx + Adrenalin) locks freshly-written container layers** (upstream docker/for-win#14977, open) — same-boot A/B on the RX 9070 XT host: dGPU disabled → tiny AND heavy RUN-layer finalize green first try; enabled → red. Severity tracks the WINDOWS PATCH LEVEL (post-KB5101684 even 10-byte RUN layers trip; COPY-only layers never do — no container involved). Failed finalizes additionally WEDGE hcs state until a REBOOT (survives service bounces + vmcompute restart). The 2026-08-09 verdicts ("Adrenaline reinstall fixed it", "in-place repair fixed it", "GPU-disable is NOT the fix") are SUPERSEDED — each coincided with a patch-level/reboot change that moved the trigger threshold. | Order on any weird host: (1) `windows\scripts\diagnostics\probe-build-copy.ps1 -Heavy` (the committed probe; only `-Heavy`-green counts), (2) RDNA4 dGPU present? elevated `toggle-rdna4-gpu.ps1 -Disable` → re-probe `-Heavy` → build → re-enable (the `Assert-NoActiveRdna4Gpu` preflight in `build-buildkit.ps1` enforces this), (3) after ANY red finalize: REBOOT before further A/Bs — a wedged host falsifies every experiment. Full evidence: the "AMD Radeon host" row below. |

|---------|-------------|-----|
| `exec format error` | QEMU/binfmt not registered after host reboot | `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` |
| `no space left on device` | Disk full from cached images/artifacts | In order: (1) `linux/host-config/prune-safe.sh` (spares compile caches), (2) `nerdctl rmi` of specific already-pushed tags, (3) `nerdctl system prune -a -f` ONLY with no chain running — it deletes ALL non-container-referenced images INCLUDING tagged cross-stage locals (bit us mid-run 2026-08-18; registry-pinned handoffs survived via re-pull) |
| Stale downstream images | Base image rebuilt but downstream not refreshed | Use `--verify-chain` or rebuild from replaced stage |
| `no active session` / `grpc: the client connection is closing` / `DeadlineExceeded` mid-chain (cache reads, layer export, pushes) | buildkitd session rot after ~1-2 h of parallel load (BKD1, bit 6× on 2026-08-19/20) | Let the worker retries absorb one-offs; on a repeat: stop chain → `systemctl --user restart buildkit.service` → relaunch (cache mounts provably survive; builds fast-forward) |
| `registry_pin_ref` fails on fresh push | Registry hasn't propagated the new manifest | Now uses `retry()` with 5 attempts; wait a few seconds and retry |
| Terminal freeze during long build | Build output overwhelms terminal | Use `setsid` / `disown` for very long builds |
| nerdctl DNS failure in build | BuildKit container can't resolve hostnames on Windows without a CNI nat CONFIG (`--dns` and `--network host` unsupported) | Fixed 2026-08-03: install `0-containerd-nat.conf` into `C:\Program Files\containerd\cni\conf\` (nat.exe was already in ...\cni\bin) — buildkitd RUN steps then have full NAT+DNS. docker.exe remains the fallback. |
| `nerdctl ...`: `cannot access containerd socket ... Zugriff verweigert` (non-admin) | containerd's pipe is admin-only (its service lacks `--group docker-users`, unlike dockerd/buildkitd) | Use `docker.exe` (dockerd pipe) or `buildctl` (buildkitd pipe) — both are docker-users-accessible. nerdctl needs an elevated shell. |
| BK RUN steps: `The remote name could not be resolved` (and even direct-IP queries time out) | **CNI nat subnet drift**: dockerd restarts recreate the `nat` HNS network on a new subnet; the static CNI conf then hands out IPs whose gateway doesn't exist | Update `ipam.subnet`/`GW` in `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` to match the live `vEthernet (nat)` adapter (`ipconfig`), then `Restart-Service buildkitd -Force` (admin). `build-buildkit.ps1`'s preflight guard detects this and prints the fix. |
| BK compile step freezes silently minutes in (0 % CPU, zombie ninja, no log growth) right after `[output clipped, log limit 2MiB reached]` | **buildkitd step-log clip deadlock** (Windows buildkitd v0.32): after the 2 MiB clip the stdio pipe stops being drained; every process blocks on its next write. ONNX's warning flood hits the clip in ~3 min | Set service env `BUILDKIT_STEP_LOG_MAX_SIZE=-1` + `BUILDKIT_STEP_LOG_MAX_SPEED=-1` on buildkitd (registry MultiString `Environment`), `Restart-Service buildkitd -Force`. See docs/windows-builds.md § Getting it going, step 3b. |
| BK lane: a stage fails instantly with `exit code: 1` and **ZERO container output** — no script banner, no stderr, deterministic across retries | **Two solves racing on the same freshly-invalidated ancestor stage.** Measured 2026-08-07: a second `build-buildkit.ps1` was started while the main chain ran, right after a change to the `common` stage invalidated it for BOTH. Each solve tried to build the same new snapshot chain; one died before its process ever started, hence no output. NOT a script bug — a probe running the identical mounts, module import and `Initialize-SourceBuildScript` against the same base passed cleanly. | Do not run a second solve that shares an ancestor stage you just invalidated. `-ConcurrentAux` is safe because its two branches sit on an ALREADY-BUILT common ancestor. Wait for the running chain, then start the second build. If you must parallelise, first build the shared ancestor once on its own. |
| BK lane: `failed to commit … during finalize: failed to reimport snapshot: hcsshim::ImportLayer failed in Win32: cannot create a file when that file already exists` (**0xb7**), DETERMINISTIC — identical snapshot IDs on every attempt, burns the driver's whole retry budget | **A half-committed snapshot is in the way.** Prime cause, measured 2026-08-07: **killing `buildctl` mid-finalize leaves exactly this debris** (a chain was aborted deliberately at 23 GB free to escape the disk danger band, and the next run died three times on the same IDs). `prune` does NOT clear it — it is not a reclaimable BK cache record (495 MB returned, nothing relevant); the transient-retry engine cannot help either, because the failure is deterministic, not a flake. | **`-NoCache` on the affected stage only** — e.g. `.\windows\build-buildkit.ps1 -Gpu -Stages sdk -NoCache`. Re-running the RUN yields a NEW layer digest (its output is not bit-identical), hence fresh chain IDs downstream, and the poisoned snapshot is simply no longer in the path. **Verified 2026-08-07:** the stage that had failed 3× exported cleanly, `Done in 00:17:10`. Prefer this over the in-file `CACHE-BUST` comment technique (`setup-scoop-tools.ps1`, `build-toolchain-all.ps1`): same effect, costs one stage re-run, leaves NO trace in the source. Only reach for a source-level cache-bust when the debris sits in a layer you cannot isolate with `-Stages`. Corollary: **prefer letting a doomed solve fail cleanly over killing it** — a clean finalize failure leaves no debris, a kill does. |
| BK lane, seconds into the first downloading RUN: `Could not resolve host: github.com` / `git clone failed (exit 128)` | **The CNI `.conf` is missing** — buildkitd then gives the container NO NETWORK ADAPTER AT ALL (not a DNS fault). Confirm in 30 s with a probe RUN: `ipconfig` prints nothing and a raw TCP connect to a literal IP fails *"unreachable network"*; the containerd debug log shows the `HcsCreateComputeSystem` spec with no networking block. Usual cause: someone "converted" `0-containerd-nat.conf` → `.conflist` to fix nerdctl (2026-08-07, cost a launched chain). The subnet-drift guard does NOT catch this and stays green. | Restore it (admin): `Copy-Item '…\0-containerd-nat.conflist' '…\0-containerd-nat.conf'`, edit to the single-plugin form, `Restart-Service buildkitd -Force`. **Keep BOTH files** — buildkitd needs `.conf`, nerdctl needs `.conflist`. `build-buildkit.ps1` now fail-fasts (`Get-CniConfFormIssue`) and `verify-host-setup.ps1` FAILs on a missing `.conf`. |
| ANY weird hcsshim failure on the BK lane: `ExportLayer 0x3` (path not found) at finalize, spawn flakes (`'cmd.exe' is not recognized`), `ExportLayer 0x70` (disk full) | **Disk exhaustion in costume** — the bk image generations stack 30–40 GB per rebuild cycle; only 0x70 names the disease (all three hit on 2026-08-03) | Check free disk FIRST. `buildctl prune --all` + `docker image prune -f` (non-admin); bk-* image generations need admin. Full playbook: docs/windows-builds.md § Store GC. |
| BK lane, disk is FINE: `failed to reimport snapshot: hcsshim::ExportLayer ... (0x3)` at finalize of a heavy media layer (GenAI/OpenCV class) — deterministic, every fresh snapshot, both finalize paths, survives host reboot | **ROOT CAUSE FOUND & FIXED 2026-08-06: the runhcs shim's hardcoded `tearDownTimeout = 30s`** (`cmd/containerd-shim-runhcs-v1/task_hcs.go`) terminates the heavy-churn silo teardown mid-hive-flush (real duration: **117 s measured** for OpenCV), permanently poisoning the scratch vhdx. Calm exits (ONNX ninja, cpython, LiteRT, torch) finish teardown under 30 s and never tripped it. | **SOLVED at the root: patched shim** (hcsshim@main, constants 45 min/100 min) deployed to `C:\Program Files\Stevedore\bin\containerd-shim-runhcs-v1.exe` (stock backup: `.exe.orig`); lane de-warmed to DIRECT solves after 3× consecutive clean OpenCV canaries. **MAINTENANCE: every Stevedore/containerd update overwrites the patched shim** — `Assert-ShimPatch` gates it by SHA256 against the hash `deploy-shim-patch.ps1` recorded at install (size check only as a fallback: patched 25 329 664 vs stock 23 279 616), re-install + re-run one OPENCV canary after any update. Rollback path if it ever 0x3s again: warm/materialize from git history (`c9586c1^`), payload scripts still in tree. 0x3 stays EXCLUDED from the driver's transient-retry pattern — it must fail loudly. |
| `hcsshim::ActivateLayer failed (0x20)` during build | Windows Defender scanning new layer files + containerd snapshot contention | Exclude `C:\ProgramData\containerd`, `C:\ProgramData\nerdctl` from Windows Defender. Or use `docker.exe` instead of `nerdctl` for builds (Docker's layer manager is more resilient). |
| Stevedore docker build: `runtime "com.docker.hcsshim.v1" binary not installed` | Service default runtime uses `hcsshim-v1` shim which isn't shipped | Change to `runhcs-v1`: `sc config stevedore binPath="..." --default-runtime=io.containerd.runhcs.v1"` (see docs/windows-builds.md § Fix 2) |
| Stevedore docker build: `failed to create TTRPC connection` | Shim binary mismatch (runhcs copied as hcsshim) | Remove the bad shim copy: `del "C:\Program Files\Stevedore\bin\containerd-shim-hcsshim-v1.exe"`. Apply Fix 2 instead. |
| Stevedore service won't start (1053 timeout) | Windows Defender blocking dockerd.exe OR stale daemon.json from Docker Desktop | `Add-MpPreference -ExclusionProcess "dockerd.exe"` AND delete `C:\ProgramData\docker\config\daemon.json` |
| `error getting credentials - err: exit status 1` | wincred credential helper fails because dockerd runs as SYSTEM without interactive session | OK to ignore for public images (MCR, GitHub). Use `nerdctl pull` instead for images that need auth, or set `"credsStore":""` in docker config. |
| `failed to extract layer ... failed to find link target` when pulling servercore | containerd windows snapshotter can't handle certain Windows reparse points in the layer | Use `docker.exe pull` instead of `nerdctl pull`. Docker Engine's layer extraction handles reparse points correctly. |
| Windows media build crawls; `Building with ninja -j2` in `media-core.log` | media-core fell back to a 2-CPU `docker build` instead of the run+commit path | Ensure `Invoke-RunCommitStage` runs (`docker run --cpu-count $MediaCoreCpus`); `docker build` is 2-CPU-capped here and no flag raises it (§ Windows Build Invariants). |
| `hcsshim::ActivateLayer failed ... 0x20 "file used by another process"` on commit | `--isolation process` was used for a `docker build` — it cannot commit layers on this host | Never pass `--isolation process`. Use Hyper-V (the default) for `docker build`; for CPUs use the `docker run --cpu-count N` + `docker commit` path. Not Defender/Search/SysMain (all ruled out). |
| **AMD Radeon host (any Windows build) where `COPY`-into-layer fails in BOTH lanes, every time** — buildkitd `failed to reimport snapshot: hcsshim::ActivateLayer ... 0x20` (identical IDs across fresh solves, survives `-NoCache` + service restart + Defender + full store reset + reboot) and docker-classic `mkdir \\?\Volume{<GUID>}\C:.` — "Der Verzeichnisname ist ungültig" (invalid dir name), under process AND Hyper-V isolation. Minimal 3-layer probe: `FROM servercore:ltsc2025` + `RUN` commits, the first `COPY` never does. | NOT Defender/no-cache/isolation/stores — reproduces on a rebuilt store after a cold boot. The Linux cross lane + repo gates are unaffected. **FINAL 2026-08-09 (measured): the BK build lane is UNUSABLE ON THE DISCOVERED HOST** - the reimport/double-activation 0x20 persists identically on buildkit 0.32.0 AND a throwaway v0.32.2 daemon (instrumented A/B, pristine Stevedore reinstall, every host lever tried incl. AMD GPU disable + driver/chipset reinstall). Host-level hcs/windows-snapshotter behavior, NOT engine/config/OS-version (the working machine is the same 26200 build). dockerd (classic lane) commits the same shapes fine on this host. => BK build here = no; classic lane + the working host are the paths. nerdctl run of pre-built images is unaffected.  **POST-WINDOWS-REPAIR (in-place setup.exe, same build 26200): the layer-COMMIT wall is FIXED - all layers (incl. writing into existing dirs) now commit on the buildkit lane (verified); only the final EXPORT reimport of a committed snapshot still trips ActivateLayer 0x20, and MsMpEng (Defender engine) is unkillable-by-design, so the Defender truly off condition is unreachable here - residual host hcs behavior at export remains. Runner-up practical note: 0.32.x includes the upstream retry fix (#5885); it does not help a persistently-held VHD here.**HVCI/Memory Integrity also falsified (off + reboot + retest = identical 0x20). Host-level hardware/platform incompatibility with the windows snapshotter on this box remains the only consistent explanation; the working PC (same Stevedore + same build) proves the stack is fine there. | **[2026-08-09 verdict — SUPERSEDED by the RESOLVED 2026-08-10 A/B later in this cell; kept as history]** it read: root cause = a faulty AMD Adrenaline installation, NOT the RDNA GPU; GPU-disable never cured it; `toggle-rdna4-gpu.ps1` obsolete. The same-boot A/B of 2026-08-10 inverted this — the enabled RDNA4 dGPU IS the holder, and the 08-09 "cures" coincided with patch-level/reboot changes that moved the trigger threshold. The right first check on any new or weird host stays `pwsh -File windows\scripts\diagnostics\probe-build-copy.ps1 -Heavy` (the committed probe; assets in windows/scripts/diagnostics/probe-build-copy — it was how this was isolated). Diagnostics note that remains valid: while build-COPY fails in BOTH engines (ApplyDiff), `docker run` + `docker commit` still works (CommitLayer OK) — so the classic lane's run+commit stages stay viable once a FROM image exists; full bootstrap still needs a healthy host (every repo Dockerfile has a COPY). **2026-08-10 status on the discovered host: LIGHT-probe-green but NOT chain-green.** The fixed 3-layer probe (now exporting `type=image,...,unpack=true`, the same output path as `build-buildkit.ps1`) passes commit + export + unpack — but the real chain's first COPY after the heavy pwsh-install RUN dies deterministically (`ActivateLayer 0x20` at child finalize/reimport, FRESH snapshot IDs under `-NoCache` — not poisoned cache). **RESOLVED 2026-08-10 by same-boot A/B: the holder is the ENABLED RDNA4 dGPU itself (RX 9070 XT + Adrenalin), upstream docker/for-win#14977 (RDNA3.5/4, open).** Disable the dGPU → tiny AND heavy RUN-layer finalize green, first try; enable → red. Severity tracks the WINDOWS PATCH LEVEL: pre-KB5101684 only heavyweight RUN layers tripped (light probes green — why the host looked probe-healthy while the chain died), post-KB5101684 even 10-byte RUN layers fail. COPY-only layers finalize fine either way (no container involved). Falsified on the way, all still-red: Defender (full exclusion set incl. snapshotter root + `MsMpEng.exe`; realtime-off blocked by tamper protection), WSearch/SysMain, daemon bounces, vmcompute restart, non-core minifilter detaches (no third-party filters exist on C:), fresh IDs under `--no-cache`, settle delays, reboots, nanoserver base, split solves. Failed finalizes additionally WEDGE hcs state (after one, even tiny RUN finalizes fail until reboot — this cascade is what made every earlier session's A/Bs contradict each other). **Workflow on RDNA4 hosts: elevated `toggle-rdna4-gpu.ps1 -Disable` → build (display falls back to the iGPU; DirectML-on-host is unavailable during the window) → re-enable.** `build-buildkit.ps1` preflight now gates on it (`Assert-NoActiveRdna4Gpu`, `-SkipHostChecks` overrides); probe verdict discipline: only `-Heavy`-green counts. The 2026-08-09 Adrenaline-reinstall and in-place-repair "fixes" are SUPERSEDED as root-cause claims — they coincided with patch-level/reboot changes that shifted the trigger threshold. The docker-classic legacy builder's `COPY` defect on that host is presumably the same interaction (untested with GPU off). Note the probe itself had two pwsh bugs masking all of this until 2026-08-10 (§ Windows Build Invariants, ArgQuoting traps). |
| Rust smoke test fails: "rustup could not choose a version of cargo/rustc" | A **toolchain-less** rustup (proxy shims in `CARGO_BIN` that resolve no toolchain) — e.g. `rustup-init --default-toolchain none`, or an image from before the Cargokit fix | rustup WITH a stable default toolchain IS the sole provider (`setup-rust-toolchain.ps1`); `CARGO_BIN` on the rustup path is by design. Fix with `rustup default stable`; never add a second provider (no scoop rust) (§ Windows Build Invariants). |
| BK lane: `failed to reimport snapshot` / `failed to write compressed diff` at finalize/export | hcs-temp flake family (2026-08-05): realtime scanner racing `C:\WINDOWS\SystemTemp\hcs*` scratch, and/or low disk (<~25 GB free makes hcsshim "weird" before disk-full) | Auto-retried by the BK driver's transient pattern. Root remedies (applied 2026-08-05): Defender exclusions for buildkitd/containerd + their ProgramData dirs; keep ≥40 GB free; gcpolicy active. ALWAYS check free disk first — disk-full mimics the same message. |
| `buildctl` local export of a Windows image dies `error from receiver: write ...\Boot\Fonts\<font>.ttf: file already closed` (nondeterministic file; every layer had already committed) | The `type=local` exporter cannot receive a full Windows rootfs client-side — NOT a host/commit defect (measured 2026-08-10 on a host whose `type=image,...,unpack=true` export of the same solve was green) | Export `type=image` (what `build-buildkit.ps1` and, since 2026-08-10, `probe-build-copy.ps1` do) or the tar-stream `type=docker,dest=<file>` (`-FinalTar`); never judge host health from a `type=local` export of a Windows image. |
| A download from gitlab.freedesktop.org / code.videolan.org "succeeds" (HTTP 200) but is a few KB and extraction fails — e.g. GStreamer wraps "downloaded but extraction into X failed" | **Anubis anti-scraper**: browser User-Agents without JS get an HTML challenge page as a 200 (the shared `Invoke-DownloadWithRetry` sends a browser UA). Second variant: `.git` left in a GitLab `/-/archive/` URL serves HTML even to curl. Both burned a merge run on 2026-08-17. | Fetch via `Invoke-WrapDownload` (curl-native UA + gzip/bzip2 magic-byte check) and strip `.git` from GitLab archive URLs. Diagnosis in 10 s: read the first bytes — `<!doctype html>` = challenge page, not a corrupt archive. |
| tvm stage: `TVM: llvm-config.exe not found on PATH` (#47 gate) | Scoop LLVM never ships llvm-config or dev libs — TVM was silently USE_LLVM=OFF (no CPU codegen) until 2026-08-17. NOT a broken PATH. | The self-heal in `build-tvm-from-source.ps1` builds a pinned minimal LLVM from source (§ Windows Build Invariants). If the gate throws, check the heal's download/SHA pin for the current `LLVM_WINDOWS_VERSION` — do NOT fall back to the official /MT dev tarball or USE_LLVM=OFF. |
| Compile fully green, then `lld-link: error: undefined symbol` for template instantiations (`QkvToContext<...>`, `BiasSoftmaxImpl<double>`) at the DLL link — identical on every retry AND on a fresh cache mount | **the sccache nvcc path produced objects lacking arch/define-guarded instantiations during REAL compiles** — runs 10+11 with launcher failed identically, runs 5+12 bare-nvcc linked green. Poisoning is excluded on BOTH levels (run 11: fresh L0 mount; L2 turned out to hold only 9 probe entries — the chain's write-through never fed it). Minimal wrapped-vs-bare nm-diff repros (define-guard + arch-guard shapes; plain, ORT-ish and `--options-file` command lines, fresh disk-only cache) are all CLEAN — the loss needs real-ORT invocation complexity (untested: `-MD/-MF` depgen, `-forward-unknown-to-host-compiler`, quoted rsp defines, client concurrency). Same machinery also crashed the server on fused_moe (10054, upstream family #1098) and produced the `Severity::k0` phantom; arch-guard×preprocessing has upstream history (#2299) | CUDA is bare BY DEFAULT since 2026-08-10 night — the launcher is OPT-IN at the wiring site (`Invoke-CmakeConfigure` adds `CMAKE_CUDA_COMPILER_LAUNCHER` only under `SCCACHE_CUDA_LAUNCHER=1`; the earlier per-script opt-out env var leaked process-wide on the classic lane, review find). NEVER export that opt-in on a new sccache without all THREE canaries: verify-cuda-cache.ps1 + fused_moe compile + a full providers_cuda LINK (the miscompile is invisible until link). C/CXX launcher stays safe. |
| BK lane: `hcsshim::ImportLayer failed ... (0xb7) "already exists"` on the SAME chain-IDs across retries | Persistent snapshotter debris from an earlier low-disk finalize failure — NOT transient, `buildctl prune` cannot reach it (0B reclaimable) | Non-admin sidestep: cache-bust the layer above (any content change to the COPY'd/mounted file → new chain-IDs; live example in `setup-scoop-tools.ps1`'s 2026-08-05 header). Admin fix: prune/GC under the active gcpolicy. |
| `buildctl prune` returns `Total: 0B` no matter what you pass | **CHECK `du -v` FOR `Shared: true` FIRST — that is almost always the answer.** `Shared` records are pinned by containerd IMAGE TAGS and NO prune flag can take them; prune only ever gets the `Private` slice. Measured 2026-08-08: a 109.06 GB store reporting `Reclaimable: 109.06GB` under a 42.95 GB reserve — i.e. well ABOVE the reserve, everything nominally reclaimable — still pruned **0 B**, because every record was `Shared: true`. `Reclaimable` describes the LEASE state, not what prune will hand back. Earlier the same day I twice blamed `reservedSpace` for this and twice wrote it into the docs; both times the real holder was tag-pinning. **`reservedSpace` is a red herring for this symptom.** The lever for `Shared` is an admin `nerdctl --namespace buildkit rmi` (or `image prune -f` for untagged generations) — and note that freeing it means deleting stage images you may want, so decide deliberately rather than reflexively. Otherwise: refs pinned by BUILD HISTORY (every record incl. failed attempts pins its refs indefinitely — 2026-08-05: 414 GB store, 0B reclaimable, ~10 grind-run histories) and/or by named `bk-*` image generations | If Total < reservedSpace, the ONLY levers are (a) admin `nerdctl --namespace buildkit rmi` on dead stage tags — that frees the **containerd image store**, a SEPARATE store (measured: 66.5 → 85.0 GB while buildkit's 207.63 GB did not move a byte), or (b) lower `reservedSpace` in `windows/buildkitd.toml` and re-apply with an admin **pwsh 7** `apply-buildkitd-gcpolicy.ps1` (it `#requires -Version 7.0` and refuses silently-looking under 5.1). Size the reserve against space actually AVAILABLE to buildkit, not total disk: `reservedSpace` + the highest stage disk floor (60 GB) must fit, or the chain starves with GC unable to help — that is what made a run die at 53.5 GB mid-media and read as a disk problem. Otherwise (non-admin, safe while a build runs): `buildctl prune --free-storage <MB>` — the lever that works WHEN the store is above the reserve; released 63.8 GB mid-build on 2026-08-07 without disturbing the running solve. **`prune-histories` is NOT a reliable first step any more:** on 2026-08-07 it aborted with `error: lease "ref_...": not found` and freed 0 bytes, against the 289 GB it released on 2026-08-05 — a stale lease from a killed run poisons it. Try it second, not first, and never rely on it while the disk is already critical. Both leave pinned fresh images + active-solve leases alone. Obsolete named generations additionally need an ADMIN shell: `nerdctl --namespace buildkit rmi docker.io/local/kataglyphis:bk-<old>`. Durable fix: the `[history] maxAge/maxEntries` section in windows/buildkitd.toml (active after the next service restart). The classic docker lane is separate (`docker rmi` works non-admin; verify a registry copy exists before deleting tagged finals). **`--free-storage` is a MINIMUM-FREE TARGET, not an amount** (2026-08-06/07): the daemon prunes until the host has that many MB free and stops, so on a disk already above the target it deletes nothing — measured 77 MB at `200000` with 198.5 GB free and 150.5 GB Private, vs the full 150.48 GB at `900000`. To drain everything unpinned, ask for more free space than the disk physically has; it cannot over-delete, `Shared` stays pinned. **A SUPERSEDED lineage is the big hidden reclaim:** after a cache-bust rebuilds base/sdk/toolchain, the old downstream stage tags still pin a FULL copy of every layer beneath them — measured 3× `setup-cuda` (109.5 GB), 3× `setup-scoop-tools` (88.5 GB), 2× `setup-vs` (69.1 GB), i.e. 267 GB of a 384 GB store. Spot it with `buildctl du -v` grouped by the script in `Description`, reading `Last used` (superseded records predate the current chain's rebuild); kill by lineage not by age, admin `rmi` the dead stage tags, wait ~30 s for the containerd GC, then prune. Full sequence and numbers (266 GB, C: 4.8 → 271.3 GB) in `docs/windows-builds.md` § Store GC. |

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

Windows LLVM bump note: bumping `LLVM_WINDOWS_VERSION` also requires adding the
new version's SHA256 to `$llvmSrcSha` in `build-tvm-from-source.ps1` (the #47
mini-LLVM heal pins the llvm-project source tarball per version and THROWS on
an unknown one — deliberately, unpinned downloads are forbidden).

Windows layer-cost note: `windows/Dockerfile.base` declares `VULKAN_VERSION`/
`CMAKE_VERSION` just above the scoop step (NOT at the top) so bumping them
re-runs scoop, never the hours-long VS Build Tools layer. Keep new version ARGs
below the VS layer unless they are consumed above it. Same trap for modules:
`WindowsScripts.Shared.psm1` (plus `WindowsContainerImage.Common.psm1` and
`WindowsInstaller.Common.psm1`) sit in `Dockerfile.base`'s PRE-VS module COPY —
editing any of them re-pays the VS Build Tools layer, so batch such edits
deliberately.

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
