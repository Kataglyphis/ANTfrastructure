# Windows Build Image

> Building a large project **inside** this image and want it to be fast?
> See [Windows Container Build Performance](windows-container-build-performance.md)
> — measured results for incremental builds, plus the approaches that do not
> work (sccache on C++23 modules, named volumes as build directories).

> **Important (Antivirus):** On Windows, **exclude your development folder from antivirus scanning**. Real-time protection can lock files during builds (especially during CMake FetchContent and cargo builds), causing intermittent failures with errors like "Failed to remove directory" or "(os error 32)". Add your project directory to your antivirus exclusion list.

## Source Patch Policy

This repository applies a **patch-first** policy to upstream sources on the Windows lane. **Default: extract upstream modifications into a reviewable `.patch` file** under `windows/scripts/patches/<component>/NNN-<slug>.patch`, applied via the canonical idempotent helper `Invoke-SourcePatch` (`windows/scripts/modules/WindowsSourceBuild.Common.psm1`). Every `.patch` file:

- Is a standard `git diff` / unified diff (`a/`/`b/` prefix, `-p1` strip).
- Applies idempotently: `Invoke-SourcePatch` runs `git apply --reverse --check` first and skips if already applied; falls back to `patch.exe -p1` for non-git tarball extractions; throws loudly with the patch file's first 40 lines on failure.
- Targets a *pinned* upstream version (e.g. the file header references the git tag in `linux/scripts/01-core/versions.env`).

**Exceptions (inline patches are intentional and documented):**

1. **Generated build files** — patches targeting FFmpeg's generated `ffbuild/*.mak`, `library.mak`, `subdir.mak`, `Makefile`, `ffbuild/config.mak` (post-configure output; content varies per `./configure` invocation) AND the `Update-NinjaFile` calls in `build-onnx-from-source.ps1` / `build-onnx-genai-from-source.ps1` that strip MSVC-only flags from CMake-generated `build.ninja` (same family — generated content varies per CMake configure). Inline `-replace` on invariant sub-sequences (`-showIncludes`, `EXTRALIBS-lib*=`, `/experimental:external`, `/Qspectre`) is the canonical form for both.

2. **Fetched third-party deps whose pinned version floats** — `Edit-CppKeywordAlternatives` walks CUTLASS headers fetched by ONNX Runtime's ExternalProject at configure time, AND the companion `_udiv128 → udiv128` substitution on `cutlass/uint128.h` (clang-cl lacks the MSVC-only intrinsic). The CUTLASS fetched SHA varies with the provider's `cutlass-src` ExternalProject pointer; a static `.patch` against a pinned tag would silently rot. The helper form + the targeted inline regex are canonical.

3. **Multi-file conditional substitutions** — LiteRT's `proto/CMakeLists.txt` disable loop (`build-litert-from-source.ps1`) walks ~17 files under `$tfliteSrc` and skips files whose content already lacks `protobuf_generate|protoc`. A static `.patch` against a pinned LiteRT tag cannot express the per-file predicate and would only cover a fraction of the proto directories. Similarly, the OpenCV mlas `<cstring>` prepend loop (`build-opencv-from-source.ps1`) walks every `3rdparty/mlas/**/*.cpp` and skips files that already include `<cstring>` — same canonical-form rationale.

4. **Installed toolchain headers (not the upstream source tree)** — `build-onnx-genai-from-source.ps1` patches the installed MSVC STL `yvals_core.h` (wrapping the single `_EMIT_STL_ERROR` define in `#ifdef __clang__`, which no-ops *every* STL error code — STL1009/1010/1011, etc. — under clang-cl, so no per-header patch such as one for `<experimental/coroutine>` is needed). The MSVC toolset version floats (resolved via `Get-MsvcToolsRoot`), so a static `.patch` against a pinned MSVC build would only work for one toolset version; the edit is guarded by a drift-assertion that fails the build loudly if a future toolset changes the macro's format.

5. **Binary byte-filter edits** — `onnxruntime.rc` non-ASCII byte stripping (`-le 127`) is a byte filter, not a textual diff. Not expressible as unified diff.

6. **Single-file regex edits on aggressively-changing generated-as-schema upstream files** — The OpenCV `add_extra_compiler_option(-include cstring)` removal (plus surrounding CMake add-to-flags lines on `cmake/OpenCVCompilerOptions.cmake`) is kept inline *not* because a `.patch` couldn't be authored today, but because the upstream context drifts enough between minor releases that a static `.patch` would need re-generation on every tag bump:
   - `build-opencv-from-source.ps1` — `cmake/OpenCVCompilerOptions.cmake` `-include cstring` removal

7. **Upstream export-gap bridges (LiteRT-LM v0.14.0)** — Google ships LiteRT-LM
   tags whose CMake layer lags the source restructure (v0.14.0's was never
   buildable anywhere: it references the deleted `constrained_decoding`
   component, pins a LiteRT from *before* the `support/` tree its own shim
   headers `#include " from @litert"`, and compiles none of the new
   `logits_processor`/support subsystems). `build-litert-lm-from-source.ps1`
   bridges this with condition-gated blocks (`[LiteRTLM-winfix export-stubs]`,
   `[LiteRTLM-winfix support-graft]`, the v0.14-orphans + v0.14-deps blocks):
   stub CMakeLists are *generated*, the `support/` tree is *sparse-cloned from
   LiteRT at the version this container already ships* (`LITERT_VERSION`), and
   orphaned sources are injected into the engine lib. Static `.patch` files
   cannot express "graft a tree from another repo at a configurable tag" or
   "only when the referenced dir is missing" — and every block is gated on the
   breakage itself, so a future tag with a fixed export takes upstream's files
   untouched and the bridge self-retires. The Gemma constraint provider is
   upstream's prebuilt-only DLL component: its import lib is linked on the exe
   and the DLL staged beside `litert_lm_main.exe` (with `z.dll` +
   `kissfft-float.dll`, found via `llvm-objdump -p` after the exe died
   0xC0000135 without them).

Every inline substitution in a build script carries a `# Inline patch (kept inline, NOT a .patch file):` block comment explaining the canonical-form rationale. The current `.patch` inventory:

| Component | Patch | Upstream target | Purpose |
|-----------|-------|-----------------|---------|
| FFmpeg | `001-allow-msys-builds.patch` | `configure` | Replace `die` with `echo` for MSYS2 build env |
| GStreamer | `001-ges-commit-rename.patch` | `subprojects/gst-editing-services/ges/ges-validate.c` | `#define _commit ges__commit` to dodge `-FIio.h` macro collision |
| ONNX Runtime | `001-softmax-clangcl-keywords.patch` | `core/providers/cuda/math/softmax.cc` | Change the one real ISO-646 `or` → `\|\|` on the dispatch `if` (clang-cl in MS-compat mode treats `or` as an identifier); comments left as upstream |
| ONNX Runtime | `002-disable-cuda-pch.patch` | `cmake/onnxruntime_providers_cuda.cmake` | Disable CUDA EP `target_precompile_headers` (CUDA 13.x CCCL broken with clang-cl) |
| ONNX Runtime | `003-dml-clangcl-compat.patch` | DirectML EP (5 files under `core/providers/dml/`) | clang-cl + `USE_DML=ON`: out-of-line `AbstractOperatorDesc` members past `OperatorField` (incomplete-type), drop the `.##Z` token-paste, widen `Dispatch<uint32_t>` → `size_t` |
| OpenCV | `001-cmake-clang-cl-compat.patch` | `CMakeLists.txt` + `cmake/FindONNX.cmake` | CMP0146/CMP0148 OLD→NEW + clang-cl/CUDA detection compat |
| OpenCV (contrib) | `001-cudev-windows-llp64.patch` | `cudev/.../common.hpp` | Add `ulong`/`longlong`/`ulonglong` typedefs for Windows LLP64 |

`ffmpeg/makedef` is **not** a patch — it is a whole-file replacement script staged over FFmpeg's `makedef` (a byte swap, not a diff), so it is not in the table above.

When bumping any upstream version, audit these `.patch` files before letting the orchestrator loose: run `windows/scripts/tests/Test-PatchesApplyClean.ps1`, which clones each pinned upstream and runs the exact `git apply --check` the build uses (see `windows/scripts/patches/README.md`). If a patch no longer applies, regenerate with `git diff` against the new tag and update the inventory above.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake 4.4.2, VS Build Tools 18, LLVM/Clang 22, Rust, Flutter, WiX 4).
- `windows/Dockerfile.nvidia` (optional GPU layer) layers CUDA 13.3 + cuDNN 9.25.0.15 + TensorRT 11.1.0.106 on top of the base image and is tagged `windows-sdk`. If skipped, the base image is tagged `windows-sdk` directly (`docker tag`; the former no-op `Dockerfile.sdk` shim was removed) and downstream stages perform CPU-only builds (CUDA auto-detection falls back to `CPU-only build`). `windows/build.ps1` handles this automatically via its `-Gpu` switch.
- The toolchain stage builds CPython 3.14 from source (matching the canonical versions.env) via `windows/Dockerfile.toolchain-builder` + `build-toolchain-all.ps1` (run+commit for full cores; the former standalone `Dockerfile.toolchain` was removed as dead code — it duplicated the builder without the nuget pre-seed fix).
- The **media stage fans out into three branch images** by `windows/build.ps1`, built **sequentially** (media-core first — it alone gets the whole RAM budget, maximizing ONNX parallelism). All three branches share ONE multi-stage builder, `windows/Dockerfile.media-builder`, selected per branch via `--target <name>`; then the stage fans in:
  - **media-core** (`--target media-core` + `build-media-core-all.ps1`, run+commit) — the ONNX dependency chain, sequential: ONNX Runtime 1.28.0 (source build; CUDA EP enabled when the NVIDIA layer was used, DirectML EP always via the clang-cl patch) → ONNX GenAI 0.15.0 (CMake+clang-cl, bypassing `build.py`; built with `USE_DML=ON` + `USE_CUDA=ON`, telemetry off) → OpenCV 5.x (CMake+Ninja+clang-cl, CUDA auto-detected, detects the source-built ONNX Runtime) → FFmpeg `n9.0` (pinned release tag, `FFMPEG_VERSION` in versions.env since 2026-08-04; MSVC toolchain via MSYS2 bash; `--enable-libonnxruntime` links FFmpeg's DNN filters against the source-built ONNX Runtime — note there is no separate `--enable-dnn` flag; DNN filters come with the backend).
  - **media-litert** (`--target media-litert` + `build-litert-all.ps1`) — LiteRT 2.1.6 → LiteRT-LM 0.14.0 (independent of ONNX; v0.14.0's broken OSS CMake export is bridged by `litert-lm-export-bridge.ps1`, see § Source Patch Policy #7).
  - **media-tvm** (`--target media-tvm` + `build-media-tvm-all.ps1`) — TVM 0.25.0 → IREE (both LLVM-heavy ML compilers; each installs its Python wheels into the source-built CPython; IREE native tools land at `C:\runtime\iree`, `IREE_ROOT`/`IREE_BIN`).
  - **merge** (`Dockerfile.media-merge-builder`): `COPY --from` fan-in of the three branch trees into one `C:\runtime` + canonical env layout, then GStreamer 1.29.2 built via `build-gstreamer-from-source.ps1` in the run+commit step (Meson + clang-cl; auto-detects CUDA, OpenCV, ONNX and FFmpeg from the merged tree).
- `windows/Dockerfile.torch` assembles the Orchestr-ANT-ion app env on the media image (`media → torch → final`; tag `local/kataglyphis:windows-torch`), and `windows/Dockerfile` produces the final developer image FROM that torch image (VsDevCmd entrypoint).

## Prerequisites

> **Provisioning a FRESH machine?** Follow the ordered checklist in
> [Fresh Windows Host Bring-Up](windows-host-setup.md) — it sequences
> everything on this page (Stevedore install, CNI conf, debug flags, GC
> policy, Defender exclusions, dufs/sccache, gate tooling) into one
> admin/non-admin-marked path with a verify command per step.

Install [Stevedore](https://github.com/slonopotamus/stevedore):

```pwsh
# WinGet (recommended)
winget install stevedore

# WinGet — custom install directory (e.g. D: NVMe dev drive)
winget install stevedore --custom="INSTALLDIR=D:\Stevedore"

# or Chocolatey
choco install stevedore
```

If you used a custom `INSTALLDIR`, substitute `D:\Stevedore\bin\docker.exe` for `"%ProgramFiles%\Stevedore\bin\docker.exe"` in all commands below.

Reboot after installation. This enables the Windows Containers feature and adds your user to the `docker-users` group.

**Tool roles on this host.** Stevedore's bundled `docker.exe` is the
classic-lane tool for builds, runs and publishing: Docker Engine provides NAT
networking natively, no CNI plugin needed. Since 2026-08-03 the CNI `nat`
**conf** (`C:\Program Files\containerd\cni\conf\0-containerd-nat.conf`; the
`nat.exe` binary always shipped in `...\cni\bin`) is installed on this host —
see § Getting it going, step 2, including the subnet-drift trap — so
containerd-side networking works too, and `nerdctl` runs the `bk-*` images
fine. `nerdctl` needs an **admin** shell (containerd's pipe is admin-only
upstream); the pre-conf state where `nerdctl run` failed with `needs CNI
plugin "nat"` and `nerdctl build` had broken DNS is historical.

| Tool | Build | Run |
|------|-------|-----|
| `"D:\Stevedore\bin\docker.exe"` (non-admin) | ✅ classic lane | ✅ Works (NAT + DNS + process isolation) |
| `buildctl` via `windows\build-buildkit.ps1` (non-admin) | ✅ preferred lane | n/a |
| `nerdctl` (**admin shell only**) | ✅ Works (verified 2026-08-07) — but the chain still uses `buildctl` on purpose, see § nerdctl lane | ✅ Works — needs the CNI nat **conflist**, see § nerdctl lane |

## Build Commands

> **Preferred since 2026-08: the BuildKit/containerd lane** —
> `.\windows\build-buildkit.ps1 -Gpu` builds the same Dockerfiles with **process
> isolation** (full host CPUs, no Hyper-V 2-CPU cap, no run+commit) and real
> per-stage layer caching. One-time host setup + launch: see § BuildKit/containerd
> lane below. The `build.ps1` commands here are the docker-classic fallback lane
> (Hyper-V + run+commit) and remain fully supported.

Use the driver script from the repository root. It parses `linux/scripts/01-core/versions.env`
and passes every version as `--build-arg` (the Dockerfile ARG defaults are only
fallbacks), builds the stages in order, and applies the correct tags:

```pwsh
# CPU lane (default): base -> tag sdk -> toolchain -> media -> torch -> final
.\windows\build.ps1

# GPU lane: base -> nvidia (CUDA + cuDNN + TensorRT, tagged sdk) -> toolchain -> media -> torch -> final
# Requires a TensorRT zip in windows/downloads/ (see AGENTS.md § TensorRT Setup).
.\windows\build.ps1 -Gpu

# Iterate on a single stage (layer cache makes this cheap):
.\windows\build.ps1 -Gpu -Stages media,final

# Deliberate clean rebuild (only when you really need it — this discards ALL layer
# caching and rebuilds everything from scratch, which takes many hours):
.\windows\build.ps1 -Gpu -NoCache

# Orchestr-ANT-ion app stage (windows/Dockerfile.torch, mirror of linux/Dockerfile.torch):
# a chain stage between media and final (media -> torch -> final) — it assembles the
# app env at APP_REF on windows-media, and the final image builds FROM it. An APP_REF
# bump therefore rebuilds torch + the cheap final tail only (minutes, network-bound):
.\windows\build.ps1 -Stages torch,final               # versions.env APP_REF pin
.\windows\build.ps1 -Stages torch,final -LatestApp    # newest release tag
# On a host WITHOUT local chain images, iterate on the published image instead:
.\windows\build.ps1 -Stages torch,final -TorchBaseImage ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
# Tags: torch -> local/kataglyphis:windows-torch (-TorchTag overrides; final builds FROM it).
```

Docker layer caching is **on by default**: the Dockerfiles are ordered so that
editing one build script only rebuilds that script's stage and later ones.
`-Docker` overrides the docker.exe path (default: `$env:DOCKER_EXE`, then the
Stevedore install locations, then `docker` on PATH). Set
`KEEP_BUILD_ARTIFACTS=1` (e.g. via a temporary `ENV` line in a media
Dockerfile) to keep the `C:\temp\*-src` build trees for debugging; by default
each build script removes its source tree after installing so the trees don't
bloat the image layers.

### Build isolation and CPU parallelism

**Policy (build.ps1 `-Isolation`, default `auto`): process isolation is always
preferred and used automatically wherever the host can support it.** `auto`
runs the ~10s commit probe (`windows/diagnostics/test-process-isolation-commit.ps1`)
once per (host build, docker version) — verdict cached in
`out\windows-build-logs\isolation-probe-cache.json` — and:

- **probe passes** → every `docker build` and `docker run` gets
  `--isolation process`: full host CPUs everywhere, no 2-CPU cap. (This is the
  normal state on a Windows **Server** host whose build matches the base image
  — the recommended build environment.)
- **probe fails** (the wcifs layer-commit bug, present on client-build hosts
  mismatched against the Server base image) → falls back to `hyperv` with a
  loud warning, and everything below applies.

`-Isolation process|hyperv` forces either mode (forcing `process` on a host
where the probe fails will kill every stage at its first layer commit).

Under Hyper-V, build containers are given only **2 logical CPUs**, so
`Get-BuildJobCount` — `min(ProcessorCount, memGB / memPerJob)` — pins every
in-container `ninja -j` to 2 no matter how many cores the host has. That is the
difference between a ~1-hour and a ~6-hour ONNX/CUDA compile, so the heavy
**media-core** stage does **not** use `docker build` at all.

### BuildKit/containerd lane (PREFERRED, `windows/build-buildkit.ps1`)

**This is the lane to use from 2026-08 on** — full host CPUs on every stage,
process-isolated layer commits, and real per-stage layer caching, with the
docker-classic run+commit lane kept as the always-working fallback. **Status
2026-08-06: GREEN end-to-end and DE-WARMED** — the host snapshotter defect
(`ExportLayer 0x3`) is fixed at the root by a patched runhcs shim, so the
lane runs DIRECT solves everywhere and the warm/materialize pattern is
retired (full writeup, proof and maintenance rule in the Roadmap section's
entry; the shim is a LOCAL patch that every Stevedore update reverts).
`bk-winamd64` builds in ~44 min hot, and heavy RUN steps bind-mount their
per-file script closures instead of inheriting COPY layers. Probes on
2026-08-03 established that BOTH docker-classic limits are absent on the
buildkitd+containerd path on this same host (and the chain was then rebuilt
from base on this lane the same day — VS2026, CUDA, CPython and the media
compiles all ran as plain process-isolated layers):

| Probe | Result |
|---|---|
| process-isolated RUN + layer commit via buildctl | **works** (the wcifs `ActivateLayer 0x20` bug is a docker-writer artifact) |
| CPUs visible in a buildkit RUN step | **NPROC=32** (no 2-CPU cap) |
| container networking | none by default → **works after installing the CNI nat conf** (`C:\Program Files\containerd\cni\conf\0-containerd-nat.conf`; `nat.exe` ships in `...\cni\bin`) |
| stage handoff (`FROM` a locally built image) | **works** with fully-qualified store names (`docker.io/local/...`) + `--opt image-resolve-mode=local` (buildkit normalizes bare names to docker.io/ and otherwise tries the real registry) |

Consequences: every stage can be a plain build — the heavy compiles run as
`*-built` Dockerfile targets (toolchain-builder `built`, media-builder
`media-<branch>-built`, merge-builder `built`) with real per-stage layer
caching, and the run+commit machinery is unnecessary on this lane. The classic
lane is untouched: `build.ps1` pins `--target builder` / `--target merge`, so
docker never executes those targets.

#### Getting it going — Stevedore + BuildKit host setup (from scratch)

> The end-to-end fresh-machine sequence (including the GC-policy deploy, the
> permanent debug flags, and the repo-gate tooling that this section does not
> cover) lives in [Fresh Windows Host Bring-Up](windows-host-setup.md).

[Stevedore](https://github.com/slonopotamus/stevedore) ships the whole engine
family in one install: `docker.exe`/`buildctl.exe` under
`C:\Program Files\Stevedore\bin\`, plus the `stevedore` (dockerd), `containerd`
and `buildkitd` services. Everything below is one-time, admin unless noted.

0. **Install Stevedore** (MSI from the releases page) and put yourself in the
   **`docker-users`** local group (log out/in afterwards) — dockerd's and
   buildkitd's named pipes are ACL'd to that group, which is what makes
   non-admin builds possible. containerd's own pipe stays admin-only (only
   `nerdctl` needs it; `docker`/`buildctl` don't).

1. **Services**: all three must run; set them to delayed-auto so reboots
   self-heal:

   ```powershell
   Get-Service stevedore, containerd, buildkitd | Set-Service -StartupType AutomaticDelayedStart
   Start-Service stevedore, containerd, buildkitd
   ```

   buildkitd's service must carry `--group docker-users` in its ImagePath
   (Stevedore's default registration does:
   `buildkitd.exe --run-service --service-name buildkitd --group docker-users`).

   **Known dockerd boot-failure pitfall:** a stale
   `C:\ProgramData\docker\config\daemon.json` whose `hosts` entry conflicts
   with the service's `--host` flags prevents the `stevedore` service from
   starting at all (took a debugging session to find, 2026-08-03). If dockerd
   won't start, rename that file first.

2. **CNI networking** (without it every RUN that downloads anything fails with
   "remote name could not be resolved"): `nat.exe` already ships in
   `C:\Program Files\containerd\cni\bin`; install the conf (admin):

   Install it as a **`.conflist`** (plugin-LIST form). containerd and BuildKit
   read either form, but nerdctl cannot parse a bare `.conf` — it indexes
   `plugins[0]` with no length check and PANICS (`index out of range [0] with
   length 0`), so the single-plugin form silently costs you the whole nerdctl
   lane. Measured and converted 2026-08-07; see § nerdctl lane.

   ```jsonc
   // C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist
   {
       "cniVersion": "0.3.0",
       "name": "nat",
       "plugins": [
           {
               "type": "nat",
               "master": "Ethernet",
               "ipam": {
                   "subnet": "<subnet of the vEthernet (nat) adapter>",   // e.g. 172.31.32.0/20
                   "routes": [ { "GW": "<that adapter's IPv4>" } ]        // e.g. 172.31.32.1
               },
               "capabilities": { "portMappings": true, "dns": true }
           }
       ]
   }
   ```

   After writing it, verify with BOTH clients — a BuildKit RUN step that fetches
   something, and `nerdctl --namespace buildkit run --rm --network nat
   <image> cmd /c ipconfig` (admin). The second is the picky one and therefore
   the better test of this file.

   **Subnet drift warning:** dockerd recreates the `nat` HNS network with a NEW
   subnet on service restarts, silently orphaning this conf (containers then get
   unroutable IPs). `build-buildkit.ps1` fail-fasts on the mismatch at preflight
   with the exact fix; re-sync the conf to `ipconfig`'s `vEthernet (nat)` values
   and `Restart-Service buildkitd -Force` (plain `Restart-Service` refuses when
   dependent services exist).
3. **Windows Defender exclusions** for `C:\ProgramData\containerd` (and the
   buildkit state dir) — layer extraction races the scanner otherwise.
4. **REQUIRED for the compile stages: disable the per-step log limit.**
   buildkitd clips each RUN step's log at 2 MiB (`[output clipped, log limit
   2MiB reached]`) — and on Windows buildkitd v0.32 this is not cosmetic: after
   the clip the container's stdio pipe stops being drained, every process
   blocks on its next write, and the step **deadlocks silently** (reproduced
   twice on 2026-08-03: media-core froze ~3 min in, right at the clip, with two
   zombie ninja processes at 0 % CPU). ONNX's warning flood alone exceeds 2 MiB
   in minutes, so heavy stages cannot survive the default. One-time (admin; do
   it while no build is running — the restart kills in-flight solves, though
   buildkitd's layer cache survives):

   ```powershell
   Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd `
     -Name Environment -Type MultiString `
     -Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1','BUILDKIT_STEP_LOG_MAX_SPEED=-1')
   Restart-Service buildkitd -Force
   ```

   (`-1` = unlimited; the driver tees everything to per-stage files under
   `out\windows-build-logs\` anyway, so disk is the only cost.)
5. **sccache** (non-admin): serve a cache dir over WebDAV — e.g.
   [dufs](https://github.com/sigoden/dufs): `dufs C:\sccache-cache -p 5000 -A`
   — and export `SCCACHE_WEBDAV_ENDPOINT=http://<host-LAN-IP>:5000`; the
   compile scripts pick it up inside RUN steps (same endpoint serves both
   lanes, so the classic chain pre-warms BK builds and vice versa).
   **dufs does NOT survive reboots** (cost a failed run on 2026-08-04, and
   the warm/materialize handoff also rides this server — without it the BK
   media solves fail fast). Make it logon-persistent once:
   `schtasks /Create /TN dufs-sccache /TR "\"%USERPROFILE%\scoop\shims\dufs.exe\" C:\sccache-cache -A -p 5000" /SC ONLOGON`
   — or restart manually after a reboot and verify
   `(Invoke-WebRequest http://<host-LAN-IP>:5000 -Method Head).StatusCode`
   returns 200. Verified:
   BK's NAT'd containers reach the host's LAN IP fine.

6. **Verify** before the first long build (non-admin):

   ```pwsh
   & "$env:ProgramFiles\Stevedore\bin\buildctl.exe" --addr npipe:////./pipe/buildkitd debug workers   # worker: windows/amd64
   # network smoke: any tiny Dockerfile whose RUN resolves a hostname; or just start
   # the chain - build-buildkit.ps1's preflight guards (buildkitd reachability +
   # CNI subnet drift) fail fast with the exact fix if something is off.
   ```

Launch:

```pwsh
$env:SCCACHE_WEBDAV_ENDPOINT = 'http://<host>:5000'
.\windows\build-buildkit.ps1 -Gpu                        # full chain from base
.\windows\build-buildkit.ps1 -Stages toolchain           # one stage
.\windows\build-buildkit.ps1 -Gpu -FinalTar out\bk-winamd64.tar  # + docker-loadable export
```

Remaining gotchas (why the classic lane still exists): images land in the
CONTAINERD store (`docker.io/local/kataglyphis:bk-*`) and are invisible to
docker's windowsfilter store — running/pushing via docker needs the `-FinalTar`
export (or push straight from the BK lane with `-PushRef <ref>`, which needs a
prior `docker login` in the invoking shell). **Inspecting, running and even
building them works via Stevedore's nerdctl in an ELEVATED shell** — the full
recipe set is § nerdctl lane below.

When validating lane parity, compare each `bk-*` image's payload against the
classic tag (the same scripts and Dockerfile targets run in both lanes).

Housekeeping and sharing:

- **Store GC — treat as MANDATORY OPS, not housekeeping.** buildkitd's store
  grows unbounded by default; iterating on the chain stacks full image
  generations (30–40 GB each) in the containerd store on every rebuild cycle.
  On 2026-08-03 disk exhaustion sabotaged one day THREE ways, each wearing a
  different costume: `hcsshim::ExportLayer 0x3` ("path not found") at snapshot
  finalize, a process-spawn flake surfacing as `'cmd.exe' is not recognized`,
  and finally an honest `ExportLayer 0x70` (disk full) — only the last one
  names the disease. If a Windows BK build fails in ANY weird hcsshim way,
  **check free disk first.** Cleanup levers, non-admin first:
  `buildctl prune --all` (build cache only), `docker image prune -f` (the
  classic lane's dangling generations — 91 GB reclaimed that day); the bk-*
  image generations themselves need admin (`nerdctl --namespace buildkit rmi`,
  or stop buildkitd+containerd and delete their state dirs for a full reset —
  dockerd may stop with containerd: `Start-Service stevedore` afterwards).
  **WIRED 2026-08-04, ACTIVE ON THIS HOST since 2026-08-05** (service
  re-registered with `--config`, rules verified via `buildctl debug workers
  -v`: reservedSpace ≈215 GB / minFree ≈27–32 GB / cachemount tier 21 GB/168h).
  Same admin session also added Defender exclusions for `buildkitd.exe`,
  `containerd.exe`, `C:\ProgramData\containerd` and `C:\ProgramData\buildkitd`
  — the 2026-08-05 night grind traced a family of finalize/export sharing-
  violation flakes to something racing the hcs scratch dirs (see the BK retry
  bullet in the roadmap). Originally wired after GC evicted the VS Build
  Tools layer between two runs (root cause, from `buildctl debug workers -v`:
  with no config file
  buildkitd runs computed defaults — `maxUsedSpace 100GB`, `minFreeSpace
  187GB`; the warm chain's cache is ~237GB on a 91%-full disk, so BOTH
  triggers fired on every GC pass and everything reclaimable — including the
  multi-hour VS layer — was evicted the moment a build's references dropped).
  The policy lives in the repo at `windows/buildkitd.toml` (three tiers; the
  load-bearing knob is `reservedSpace = 200GB`, below which GC never prunes —
  that is what protects the ~35GB VS-class layers; v0.32 key names are
  `reservedSpace`/`maxUsedSpace`/`minFreeSpace`, NOT the legacy
  `gckeepstorage`). Deploy/refresh it with
  `windows\scripts\apply-buildkitd-gcpolicy.ps1` from an ADMIN shell — it
  copies the toml to `C:\ProgramData\buildkitd\`, re-registers the service
  with `--config` (keeping `--debug`) and restarts buildkitd, so NEVER run it
  while a build is solving (it refuses when it sees a live buildctl unless
  `-Force`). Verify with `buildctl debug workers -v`. Keep real disk headroom
  by pruning the classic docker lane (`docker image prune -f`), not by
  shrinking `reservedSpace`. Manual fallback between chains:
  `buildctl --addr npipe:////./pipe/buildkitd prune --keep-storage 200000`.
  **Unit trap (cost a command on 2026-08-06):** `--keep-storage` is a `float`
  in **MB** and buildctl v0.32 accepts NO unit suffix — `200gb`/`250GB` die
  with `invalid value ... strconv.ParseFloat: invalid syntax`. 200 GB is
  `200000`. Same for `--keep-storage-min` and `--free-storage`. Confirm with
  `buildctl prune --help` before scripting it.
- **`--keep-storage` is the WRONG lever here — use `--free-storage`
  (measured 2026-08-06).** On buildkitd v0.32/WCOW,
  `prune --keep-storage 200000` against a 445.61 GB store returned
  `Total: 0B` — nothing deleted at all, despite `du` reporting
  `Reclaimable: 445.61GB` and every record `InUse: false`. The flags map to
  the same knobs as the gcpolicy (`--keep-storage` → maxUsedSpace,
  `--keep-storage-min` → reservedSpace, `--free-storage` → minFreeSpace) and
  only **`--free-storage`** actually drove a prune. Working invocation:

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd prune --free-storage 240000    # MB
  ```

- **`--free-storage` is a MINIMUM-FREE TARGET, not an amount to delete
  (measured 2026-08-06/07 night).** The daemon prunes until the host has that
  many MB free and then stops — so on a disk that ALREADY exceeds the target
  it deletes nothing, however much is reclaimable. Measured: at 198.5 GB free
  with 150.5 GB `Private` in the store, `prune --free-storage 200000` removed
  **77 MB**; the identical command with `900000` (more than the disk can ever
  offer) removed the full **150.48 GB**. This is also why the earlier runs
  looked like the flag "stops at the Private slice" — they were hitting their
  target, not a ceiling. **Rule: to drain everything unpinned, ask for more
  free space than the disk physically has.** It cannot over-delete: `Shared`
  records stay pinned regardless (next bullet), so an absurd target is safe.

- **Prune can only ever take the `Private` slice — `Shared` is pinned by the
  image tags.** Same run: 445.61 GB → 371.77 GB, i.e. **exactly the 73.84 GB
  that `du` called `Private`**, and it stopped there (C: 31.6 → 93.3 GB free).
  The remaining 371.77 GB were all `Shared` — held by the ten `bk-*` stage
  tags in the containerd namespace, not by each other. Freeing those means
  `nerdctl --namespace buildkit rmi` (admin) FIRST, and that is not free
  disk: those tags are the hot chain, so deleting them buys GB at the price
  of a cold 5–6 h rebuild. Decide deliberately. Diagnose before pruning with

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd du --format '{{json .}}'   # then sort by Size, read Shared/InUse
  ```

  A healthy store looks like this one did: `InUse: 0` everywhere (nothing
  pinned by a live solve) but most bytes `Shared: true` (pinned by tags).
  Note also that a single chain generation is NOT waste — the "iterating
  stacks 30–40 GB generations" failure mode means DUPLICATE generations of
  the same stage tag; ten distinct stage tags of one chain are the asset.

- **A SUPERSEDED lineage hides whole duplicate copies of your most expensive
  layers — the single biggest reclaim on this host (266 GB, 2026-08-06/07
  night).** After a cache-bust rebuilds `base`/`sdk`/`toolchain`, the older
  stage tags downstream of the OLD base still exist and still pin their own
  full copy of every layer beneath them. They look innocent (distinct tag
  names, no duplicates in `nerdctl images`) because the duplication is one
  level down, in the RECORDS. Measured with 10 tags and a 384 GB store:

  ```text
  setup-cuda.ps1          109.5 GB  in 3 copies
  setup-scoop-tools.ps1    88.5 GB  in 3 copies
  setup-vs.ps1             69.1 GB  in 2 copies
  ```

  One copy per cache-bust — 267 GB of the 384 GB was the base spine held
  three times over. **Diagnose** by grouping the verbose record list by the
  script each record ran and reading `Last used`: records from a superseded
  lineage carry an older date than the current chain's rebuild.

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd du -v     # group by Description, read "Last used"
  ```

  **Fix:** admin `nerdctl --namespace buildkit rmi` on the stage tags of the
  superseded lineage, wait ~30 s for the containerd GC, then prune. Identify
  them by lineage, not by age: a stage tag is dead when its ancestor stage was
  rebuilt after it (compare image IDs against the current chain, and the stage
  logs in `out\windows-build-logs\` for the rebuild times). Deleting them costs
  nothing that a failed chain was not going to rebuild anyway. **Before
  deleting a tagged FINAL image, verify the registry copy** —
  `docker manifest inspect ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`
  — so the local one is not the only one. Sequence that produced the 266 GB:
  prune (42.4 GB) → drop canary tags + prune (15.7 GB) → drop the 6 superseded
  stage tags + prune (109.7 GB) → prune with a target above disk capacity
  (150.5 GB). C: 4.8 → 271.3 GB free, with the current lineage untouched.
- **VHDX-backed checkouts — the reclaim lever that is NOT the store.** When the
  repo (or the store) lives on a dynamically-expanding VHDX, that file only
  ever grows: deleting data inside the guest leaves the blocks allocated in the
  host file. Measured on the reference host 2026-08-06: **270.1 GB physical for
  16.1 GB of live data**, i.e. ~254 GB of dead blocks that no `buildctl prune`
  can ever touch — while C: had silently fallen to **11.7 GB free**, deep
  inside the "hcsshim gets weird before it admits disk-full" band. Lever
  (ADMIN, never while a build solves):

  ```pwsh
  pwsh -File windows\scripts\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx -ReportOnly   # look first
  pwsh -File windows\scripts\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx               # then act
  ```

  **ReFS caveat — measured, do not re-probe:** `Optimize-VHD -Mode Full` ran 42 s
  on that disk, reported success, and reclaimed **0.2 GB**. Compaction can only
  release blocks the guest reports free via UNMAP/TRIM; NTFS guests do that
  reliably, ReFS guests essentially do not. The script detects the guest
  filesystem and warns BEFORE spending the downtime. On ReFS the only reliable
  reclaim is rebuilding the VHDX around its live data (12 GB copy on this host).
  The same run still freed **19.4 GB on C:** — from killing a wedged `buildctl`
  and stopping buildkitd/containerd, which released pinned scratch. That half
  works on any filesystem, which is why the script does both.

  **When compaction returns ~nothing, rebuild instead:**
  `windows\scripts\rebuild-host-vhdx.ps1` creates a fresh disk, mirrors the
  live data into it, compares file count AND byte totals, and only then hands
  over the drive letter. It runs in two phases on purpose, because they have
  very different requirements:

  ```pwsh
  pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -ReportOnly
  pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -CopyOnly    # safe with everything open
  pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -SwapOnly `
       -VerifyPath D:\GitHub\Kataglyphis-ContainerHub -LogPath C:\rebuild.log -RetireOld
  ```

  The COPY phase touches nothing live. The SWAP phase detaches the volume and
  therefore requires that NOTHING holds a handle on it — no shell whose current
  directory is on it, no editor with the checkout open, no agent session. Run
  it from a shell on another drive, and give it a `-LogPath` off the volume.
  **This is not hypothetical:** an unattended `wsl --unmount`/detach on this
  disk on 2026-08-06 pulled D: out from under a running session and killed it.
  The script therefore refuses rather than forces the detach, and keeps the
  verified copy for a later `-SwapOnly` run. The old disk is kept as `.old`
  unless `-RetireOld` is passed — until it is deleted, NO space is reclaimed.
- **Cross-host / CI cache**: `build-buildkit.ps1 -ExportCacheRef <registry-ref>`
  / `-ImportCacheRef <ref>` wire buildkit's registry cache (`mode=max`) once
  registry auth works from buildkitd — a second machine then rebuilds the chain
  from cache instead of from source.

## nerdctl lane (admin): run, inspect, build

**Both possibilities exist and both are supported.** Verified end-to-end on the
reference host 2026-08-07. Use whichever fits the job:

| | `buildctl` (via `build-buildkit.ps1`) | `nerdctl` |
|---|---|---|
| Shell | **non-admin** | **admin, always** |
| Builds the chain | ✅ this is the production lane | ✅ works, but see "why the chain still uses buildctl" |
| Run / exec into an image | ✗ | ✅ the reason to reach for it |
| Image store admin (`images`, `rmi`) | ✗ | ✅ only way to reach the containerd store |

### One-time host requirements

1. **The CNI nat config must be a `.conflist`** — see host-setup § A5. With a
   bare `.conf`, nerdctl PANICS (`index out of range [0] with length 0`); it is
   the single thing that made nerdctl unusable here until 2026-08-07.
2. **Admin shell.** Not negotiable and not a configuration mistake: nerdctl
   opens `\\.\pipe\containerd-containerd`, which is Administrator-only.
   `buildkitd` ships `--group docker-users` (which is exactly why `buildctl`
   runs unelevated); **containerd has no equivalent** — verified against its
   full flag set and default config, `--address` only moves the pipe, it does
   not change who may open it. nerdctl opens that client for *every* subcommand,
   including `build --output type=tar`, so no output mode avoids it.
   **Do not attempt pipe-ACL hacks**: the ACL is recreated on every containerd
   restart, and containerd access is effectively machine-admin. The legitimate
   route is an upstream containerd feature request.
3. **A fresh shell.** `C:\Program Files\Stevedore\bin` is on the MACHINE PATH,
   so shells opened before Stevedore was installed will not find `nerdctl`.
   Reopen the window rather than patching `$env:Path`.
4. **`--namespace buildkit` on every command.** The `bk-*` images live in
   containerd's `buildkit` namespace; the default namespace looks empty.

### Recipes

```powershell
# --- inspect the store -------------------------------------------------------
nerdctl --namespace buildkit images
nerdctl --namespace buildkit ps -a

# --- interactive shell INSIDE a finished image (the main win) -----------------
# NOTE: no trailing command. The final image's ENTRYPOINT (entrypoint.cmd) loads
# VsDevCmd and then starts pwsh by itself.
nerdctl --namespace buildkit run --rm -it --network nat docker.io/local/kataglyphis:bk-winamd64

# once inside: verify what actually shipped
#   python -c "import cv2, onnxruntime; print(cv2.__version__)"
#   where.exe nvcc ; gst-inspect-1.0 --version

# --- one-shot command in an image WITHOUT an entrypoint ----------------------
nerdctl --namespace buildkit run --rm --network nat docker.io/local/kataglyphis:bk-windows-base cmd /c ipconfig

# --- one-shot command in an image WITH an entrypoint: override it -------------
nerdctl --namespace buildkit run --rm --entrypoint pwsh --network nat docker.io/local/kataglyphis:bk-winamd64 -NoProfile -Command "python -c 'import cv2; print(cv2.__version__)'"

# --- build (admin) -----------------------------------------------------------
# BUILDKIT_HOST is REQUIRED on Windows: nerdctl has no unix-socket default to
# fall back to, and without it the build fails to reach buildkitd.
$env:BUILDKIT_HOST = 'npipe:////./pipe/buildkitd'
nerdctl --namespace buildkit build -t local/kataglyphis:my-tag --progress plain <context-dir>

# --- housekeeping (the 266 GB lever) -----------------------------------------
nerdctl --namespace buildkit rmi docker.io/local/kataglyphis:<obsolete-tag>
```

### Why the chain still uses `buildctl`

`nerdctl build` is a wrapper that hands the solve to the same `buildkitd`. Using
it for the chain would cost, and gain nothing:

- **every build would need elevation** — the background/unattended runs this
  project depends on are non-admin today;
- **`--opt image-resolve-mode=local`** is load-bearing for stage handoff (the
  `bk-*` tags resolve from the containerd store instead of attempting a registry
  pull) and is not exposed by `nerdctl build`;
- the driver's transient-retry engine, per-stage logs and preflight gates
  (`Assert-DiskHeadroom`, `Assert-ShimPatch`) are keyed to `buildctl`.

So: **`buildctl` builds the chain, nerdctl inspects and runs its results.**

### Traps (each one cost time on 2026-08-07)

- **Passing a command to an image that has an `ENTRYPOINT`** appends it as
  entrypoint ARGUMENTS. On `bk-winamd64` that exits `255` immediately. Use no
  command, or `--entrypoint`.
- **A killed `nerdctl run` leaves a zombie**, and `nerdctl rm -f` on it can then
  BLOCK for up to 45 minutes — the patched shim waits for teardown instead of
  force-terminating (correct for builds, painful interactively). Recovery:
  `Get-Process containerd-shim-runhcs-v1,CExecSvc | Stop-Process -Force`, then
  `rm -f` again. Safe only when the container did no real filesystem work.
- **Exit code `3221225786`** (`0xC000013A`) means the container was Ctrl+C'd,
  not that the image is broken.
- **Two harmless warnings** on every run: `default network named "nat" does not
  have an internal nerdctl ID` (true — containerd created it) and
  `failed to remove hosts file` at exit. Ignore both.
- **Diagnosing a "hung" nerdctl**: check `containerd-debug.log` for the task's
  exit Span before assuming the container is stuck — it has usually exited
  already and only cleanup is blocked.

Roadmap (**mounts PROBED WORKING on Windows buildkitd v0.32, 2026-08-03** —
both `--mount=type=bind` and `--mount=type=cache` execute correctly in RUN
steps; the remaining work is the Dockerfile surgery):

- **`RUN --mount=type=bind` for build scripts**: DONE 2026-08-04 (single-file
  mounts probed working on WCOW buildkitd v0.32). The BK lane's `*-bk` stages
  in Dockerfile.media-builder + the merge builder's warm/built stages carry NO
  script/patch COPY layers — every RUN bind-mounts exactly its transitive
  script closure at `C:\bkmnt` and passes `-ScriptDir C:\bkmnt`. Editing a
  build script now re-runs ONLY the RUNs that mount it (an OpenCV fix no
  longer re-pays the 75-minute ONNX layer). Modules are mounted PER FILE too
  (2026-08-04): the in-container closure is exactly SourceBuild.Common +
  Shared + SourceBuild.Patches + SourceBuild.Cuda + Native.Common (plus
  Installer.Common for GStreamer) — the earlier whole-dir `modules/` mount
  let edits to the 24 host-only modules (BuildDriver, BuildKit, Flutter, …)
  bust every compile RUN. `load-versions.ps1` is mounted into every build RUN
  so the freshly COPY'd versions.env is re-read instead of the base image's
  baked (possibly stale) Machine env. The classic targets keep their baked
  COPYs (classic docker cannot `--mount`).
- **Concurrent aux branch solves**: available OPT-IN via
  `build-buildkit.ps1 -ConcurrentAux` (2026-08-04) — media-core stays the
  sequential long pole, then litert + tvm build side by side via child
  drivers on half the media memory budget each. Measure host RAM headroom
  before making it the default. Two costs to know: (a) children run a single
  media branch, so the GStreamer merge is gated on all three branches being
  requested and runs only in the parent (children print `[bk:merge] skipped`);
  (b) `MEMORY_LIMIT_GB` is baked as ENV in the media `common` stage, so
  TOGGLING -ConcurrentAux (which halves the aux budget) changes that ENV and
  invalidates the aux branches' compile RUNs — pick a mode and stay in it.
- **Registry push**: available via `build-buildkit.ps1 -PushRef <ref>`
  (2026-08-04) — re-solves the final image from cache with a push exporter;
  needs a prior `docker login` in the invoking shell (buildctl forwards the
  client credential store).
- **`RUN --mount=type=cache` for a local sccache dir** (WebDAV stays as the
  cross-lane L2): kills the HTTP round-trip on ~5000 compiles per stage.
  Probed working; wiring = set SCCACHE_DIR to the cache mount in the `*-built`
  RUNs. CAUTION (2026-08-04): cache mounts get CLONED whenever the record is
  locked — fine for an L1 compile cache (worst case: cold clone, WebDAV L2
  still hits), but never rely on two solves seeing the same instance.
- **sccache for the merge/GStreamer builder**: DONE 2026-08-04 —
  build-gstreamer-from-source.ps1 sets `CC/CXX='sccache clang-cl'` for meson
  when the remote backend is configured (this build previously ran fully
  uncached, ~30 min hot, because the merge builder never wired the endpoint).
- **Automatic transient retry in the BK driver**: DONE 2026-08-04, extended
  2026-08-05 — Invoke-BkStage retries once on `Activate/PrepareLayer 0x20` /
  ttrpc / shim-task / `rpc Unavailable` failures AND on the hcs-temp
  finalize/export flake family discovered in the 2026-08-05 night grind:
  `failed to reimport snapshot` (GetFileAttributesEx not-found variant) and
  `failed to write compressed diff` (SystemTemp\hcs* sharing violation — the
  retry saved the sdk export live that night). Two hard-won caveats:
  (a) `ImportLayer 0xb7 "already exists"` on IDENTICAL source/target
  chain-IDs across attempts is NOT transient — it is persistent snapshotter
  debris from an earlier low-disk finalize failure; non-admin remedy is a
  deliberate CACHE-BUST of the layer above it (any content change to the
  COPY'd/mounted file → new chain-IDs sidestep the debris; see
  setup-scoop-tools.ps1's 2026-08-05 header comment for the live example).
  (b) disk-full also surfaces as `failed to write compressed diff` — check
  free space before trusting the transient classification. Root causes
  addressed since: gcpolicy active + Defender exclusions for
  buildkitd/containerd (below) + ≥40 GB free-disk discipline.
- **Per-library media-core split**: DONE, and escalated on 2026-08-04 from
  4 RUN layers to **4 chained SOLVES** (targets `media-core-built-onnx` →
  `-opencv` → `-ffmpeg` → `media-core-built`, image handoffs via the
  `MEDIA_CORE_*_IMAGE` ARGs; build-buildkit.ps1 drives them in order). An
  FFmpeg-only change still recompiles nothing else — and each library's
  export is now independent of the others' finalize behavior.
- **🎯 DEFECT SOLVED (2026-08-06, patched runhcs shim).** ROOT CAUSE: the
  entire ExportLayer-0x3 family was hcsshim's hardcoded
  `const tearDownTimeout = 30 * time.Second` in
  `cmd/containerd-shim-runhcs-v1/task_hcs.go` (`close()`: shutdown wait +
  terminate wait; plus the 30 s "waiting for task to be closed" in
  `DeleteExec`). Heavy-churn WCOW silo teardown needs MINUTES — measured
  **117 s** for the OpenCV specimen (HcsShutDownComputeSystem 01:16:08 →
  notification 01:18:05) — so the stock shim terminated mid-hive-flush and
  left the scratch vhdx permanently unexportable. FIX DEPLOYED: shim built
  from hcsshim@main (81e2e01) with the constants raised to 45 min/100 min
  (zero cost on the happy path — the timer only matters when it would have
  killed the build), installed to `C:\Program Files\Stevedore\bin\
  containerd-shim-runhcs-v1.exe` (original preserved as `.exe.orig`;
  replacement needs admin + no running shim processes; containerd itself
  needs NO restart — the shim spawns per container). PROOF: first-ever
  direct OpenCV finalize+export on this host (`bk-canary-shim-opencv`,
  28.6 s export, no 0x3), confirmed per the 3× OPENCV canary rule
  (`bk-canary-shim-opencv{,2,3}` all clean, --no-cache). The lane is
  DE-WARMED since 2026-08-06: direct solves everywhere, warm/materialize
  retired (payload scripts kept in tree as the rollback path, c9586c1^).
  **MAINTENANCE:** any Stevedore/containerd update overwrites the patched
  shim — after every update compare the binary size (patched 25 332 736 for
  the env-var build currently deployed, 25 329 664 for the fixed-constant
  build, vs stock 23 279 616) and re-install if reverted; use
  `windows\scripts\deploy-shim-patch.ps1 -ReportOnly` for the check and the
  same script to re-install. Rebuild recipe: scoop go + `git clone
  microsoft/hcsshim` + apply the in-tree patch + `go build
  .\cmd\containerd-shim-runhcs-v1`. **Upstream submission is FILED as a DRAFT
  PR: [microsoft/hcsshim#2855](https://github.com/microsoft/hcsshim/pull/2855)**,
  materials in-tree at `windows/upstream/hcsshim-teardown-timeout/` (issue
  text, PR description, `git format-patch`). It makes all four fixed 30 s
  limits in the binary configurable — the two in `task_hcs.go` plus the
  crash-recovery wait in `delete.go` — with **defaults unchanged at 30 s**.

  **ENV VAR NAMES — get these exactly right:**

  ```text
  CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT    e.g. 45m
  CONTAINERD_SHIM_RUNHCS_V1_TASK_CLOSE_TIMEOUT  optional; defaults to 2x teardown + 30s
  ```

  They follow the shim's existing house convention (`..._WAIT_DEBUGGER`). An
  earlier draft of this document named them `HCSSHIM_TASK_*` — those were
  INVENTED and never existed in any build. Setting a wrong name is silent:
  the shim falls back to 30 s and the defect returns with no error anywhere.
  Set them on the containerd SERVICE (the shim inherits its environment);
  `deploy-shim-patch.ps1 -ServiceEnvironment` merges them in. Note the
  upstream patch is NOT the same as a fixed-constant build: with the defaults
  it behaves exactly like stock, so a shim built from it and no env var set
  is a shim with the bug. Verify BEHAVIOURALLY with an OpenCV canary — the
  shim logs its effective timeout at Debug level, which does not reach
  containerd's log, so a quiet log proves nothing. Getting the PR merged is
  what retires the binary-size check after every Stevedore update.
  The historical bullets below are preserved for diagnosis value.
- **DEFECT PARTIALLY TAMED, NOT GONE (2026-08-05, de-warming attempted and
  ROLLED BACK same evening).** Sequence of record: (1) with the Defender
  exclusions active, a fresh `--no-cache` heavy TVM→IREE canary FINALIZED
  AND EXPORTED CLEAN (`bk-canary-0x3` — a finalize class that used to fail);
  (2) on that evidence the lane was de-warmed to direct solves; (3) the
  FIRST direct OpenCV finalize failed `ExportLayer 0x3` with the original
  signature, deterministic across retries → **OpenCV/GenAI-class churn
  still trips the defect; TVM was the wrong canary specimen.** The Defender
  exclusions remain load-bearing (they cured the hcs-temp finalize/export
  FLAKE family and evidently moved TVM-class finalizes to reliable) but do
  NOT cure the core defect. The warm/materialize pattern was RESTORED from
  git history within minutes — the preserved rollback path worked exactly
  as designed. LESSON: any future de-warming attempt must canary with
  **OpenCV** (the deterministic trigger), not TVM: same recipe as below but
  `--opt target=media-core-warm-opencv` + `--opt
  build-arg:MEDIA_CORE_ONNX_IMAGE=<current onnx tag>`; clean export three
  times in a row before touching the architecture.
  **Canary recipe (after any AV/OS/hcsshim change):**
  `buildctl build ... --opt filename=Dockerfile.media-builder --opt
  target=media-core-warm-opencv --no-cache --output
  type=image,name=docker.io/local/kataglyphis:bk-canary-0x3 --opt
  build-arg:BASE_IMAGE=docker.io/local/kataglyphis:bk-windows-toolchain
  --opt build-arg:MEDIA_CORE_ONNX_IMAGE=docker.io/local/kataglyphis:bk-windows-media-core-onnx
  --opt build-arg:MEMORY_LIMIT_GB=16 --opt
  build-arg:SCCACHE_WEBDAV_ENDPOINT=<endpoint>` (plus the standard --local/
  --opt image-resolve-mode=local flags). Clean export = that class is safe;
  `ExportLayer 0x3` at "exporting layers" = defect present, keep
  warm/materialize. Historical writeup below preserved for diagnosis value.
- **IN-CONTAINER MITIGATIONS EXHAUSTED (2026-08-05 late night, two more
  OpenCV canaries).** The shim injects `WaitToKillServiceTimeout=2147483647`
  into every container; overriding it to 5 s at payload start (probe R1)
  changed nothing — exit 0 is published instantly, `HcsShutDownComputeSystem`
  returns in ms, and the shutdown AND terminate notifications are still lost
  (30 s + 30 s timeouts in the containerd debug log), then `ExportLayer 0x3`.
  Probe R2 additionally stopped/killed every non-baseline resident before
  exit (sccache server, msdtc, AggregatorHost, SysMain, DiagTrack, UsoSvc,
  WinRM + 7 more services — verified stopped in the exit dump): same loss,
  same 0x3. Together with the earlier settle falsification this proves the
  hang is HOST-side (silo/wcifs teardown of heavy-churn scratches), not
  anything running inside the container. Upstream fingerprint:
  microsoft/Windows-Containers#547 (ltsc2025 process isolation, ~10-min
  shutdown, resources stay locked, closed unresolved). NOTE (corrected
  2026-08-06): Win11 24H2+ hosts running ltsc2025 images process-isolated
  is OFFICIALLY SUPPORTED per the version-compatibility doc (the strict
  build-match rule was relaxed for this combination) — so this is a
  reportable platform bug in a supported configuration, not an off-label
  artifact; #547 saw the same hang on a matched-build 26100 host.
  CONSEQUENCE: warm/materialize is the standing architecture on this class
  of host, not a temporary workaround. Do NOT burn more canaries on
  in-container theories; the only genuine escape hatches are a platform fix
  (Windows CU) or the containerd 2.x CimFS/UnionFS snapshotter lane (bypasses
  wcifs entirely — experimental for WCOW, unproven with the BuildKit worker).
  UPDATE 2026-08-06: the CimFS lane was TESTED AND FALSIFIED on containerd
  v2.3.3 (plugin+differ both "ok"): buildkitd with
  `--containerd-worker-snapshotter=cimfs` dies on the FIRST build step with
  `scratch snapshot without any parents isn't supported` — the cimfs
  snapshotter cannot create parentless scratch snapshots, which BuildKit
  needs even to load the Dockerfile context. CimFS is pull/run-only today;
  do not retry until a containerd release notes BuildKit/build support.
  The teardown probe remains in `bk-warm.ps1` (harmless, ~1.5 s, keeps exits
  quiet and preserves the diagnostic exit dump; removing it would cache-bust
  every warm layer for zero gain).
- **HISTORICAL (2026-08-04, worked around via warm/materialize) —
  GenAI/OpenCV snapshot finalize
  (`ExportLayer 0x3`, disk fine)**: those two layers deterministically fail BOTH finalize paths on
  buildkitd v0.32/containerd, on every fresh snapshot. A 17-probe bisection
  (2026-08-04) falsified: poisoned cache records, layer depth (14 stacked
  trivial layers export fine), defective ONNX parent (trivial layers on it
  export fine), file/dir content (a GenAI layer whose ENTIRE diff was deleted
  before step end still fails), lingering compiler daemons, vctip, bare
  .NET-Framework CLR (`MSBuild -version` layer exports clean), pending-delete
  zombies, and build-tree deletion (`KEEP_BUILD_ARTIFACTS=1` still fails).
  Clean under identical conditions: ONNX (ninja, 100-min layer), cpython
  (MSBuild), LiteRT (bazel), every trivial probe. TVM+IREE joined the failing
  set later the same morning (cmake+ninja like the clean ONNX — no build-system
  pattern survives).

  **Root-cause finding (containerd debug log, 2026-08-04 07:59):** the snapshot
  commit RACES a failing container teardown. Timeline: task exits → shim
  cleanup starts → an HCS operation inside that cleanup fails with
  `HCS_E_INVALID_STATE` (0xC0370105, "Containervorgang ist im aktuellen
  Zustand ungültig") → containerd logs `commit snapshot` **70 ms after** the
  cleanup began → 13 s later `ExportLayer` fails 0x3. The scratch VHDX is
  never cleanly released by the half-failed teardown, so the export finds no
  layer paths. Fits the clean/toxic split: layers whose containers exit with
  residual processes + heavy dirty IO (15–25-min compiles) hit the bad
  teardown state; calm exits don't.

  **How to capture the debug evidence again (admin):** set the service
  ImagePaths via registry (sc.exe quoting mangles them in PowerShell):
  `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\containerd' -Name
  ImagePath -Value '"C:\Program Files\Stevedore\bin\containerd.exe"
  --run-service --service-name containerd --log-level debug --log-file
  C:\ProgramData\containerd\containerd-debug.log'` (analog `buildkitd` with
  `--debug` before `--run-service`), `Restart-Service containerd -Force`,
  `Start-Service buildkitd, stevedore`, and
  `icacls <log> /grant "<user>:(R)"` to read it non-elevated. **Policy: debug
  logging stays PERMANENTLY ON on this host** (owner decision 2026-08-04) so
  the next snapshotter incident carries its evidence immediately. The log
  grows unbounded — if it gets large, truncate it (admin:
  `Clear-Content C:\ProgramData\containerd\containerd-debug.log`) rather than
  disabling the flags.

  **All host-level mitigations were exhausted (2026-08-04):** quiesce tail,
  msdtc/WMI stops, and a **full host reboot with a fresh container** all hit
  the identical double-timeout + 0x3 signature. Host processes show the
  container's processes DO die — the HCS shutdown *notification* is what
  never arrives (vmcompute → hcsshim callback), after which the scratch is
  never cleanly released. buildkitd v0.32 has no Hyper-V isolation option.
  **Genuine platform defect** (Win11 host 26200 + ltsc2025 + process
  isolation + heavy-churn layers; GenAI/OpenCV/TVM/GStreamer-class builds
  trip it — ONNX/cpython/LiteRT/torch never did). Worth reporting upstream:
  hcsshim (lost shutdown notification) + buildkit (commit proceeds into a
  known-failed teardown).

  **WORKING SOLUTION — the warm/materialize pattern (BK lane is GREEN
  end-to-end since 2026-08-04, `bk-winamd64` built in 44 min hot):** exploit
  BuildKit's LAZY finalization — a snapshot is only finalized when a child
  step or an exporter needs it. Per heavy library:
  1. **Warm solve** (`media-core-warm-<lib>` / merge `warm`; driver runs it
     via `Invoke-BkStage -NoOutput`): the build runs normally on the scratch;
     the artifact delta (C:\runtime + cpython site-packages, CreationTime >
     step start) leaves as ONE tar over the sccache dufs server
     (`Export-BuildHandoff`). No exporter + no child step ⇒ the toxic
     snapshot is never finalized ⇒ the defect never fires.
  2. **Materialize solve** (`media-core-built-<lib>` / merge `built`,
     exported as the handoff image): a calm seconds-long container downloads
     + extracts the tar (`Import-BuildHandoff`) — clean teardown, clean
     finalize, clean image export.
  Hard-won transport constraints baked into the helpers
  (WindowsSourceBuild.Common.psm1): cache mounts are NOT usable as the
  handoff channel (BuildKit clones them under lock — warm and materialize
  are not guaranteed the same instance; also directory RENAMES fail on
  them); call System32 tar/curl by full path (scoop-git's MSYS GNU tar
  resolves first and parses `C:\` as a hostname); pre-create every parent
  directory before extracting (bsdtar's long-path mode does not, and
  C:\runtime does not exist in a fresh materialize container); stage-local
  `ARG SCCACHE_WEBDAV_ENDPOINT` + ENV in every warm/materialize stage (ARGs
  do not cross FROM boundaries). ONNX/LiteRT keep their direct solves — they
  never trip the defect. Re-test the direct path after host OS or
  buildkitd/hcsshim upgrades: a 15-min tvm direct solve is the canary.
  Upstream issue: ready-to-file draft + preserved debug-log evidence in
  `docs/upstream/hcsshim-lost-shutdown-notification-issue.md` (+
  `containerd-debug-evidence-2026-08-04.log`).
- **Concurrent branch solves** (litert + tvm in parallel buildctl calls) —
  RAM-gated; both branches are memory-bound, so measure before enabling.

### The 125-layer budget (classic lane)

Docker's layer-chain depth is hard-capped at **125**; exceeding it fails with
`max depth exceeded` when the FIRST container of the next stage is created —
i.e. the failure lands one stage *after* the image that overspent. The classic
builder emits a layer **per instruction, metadata included** (28 separate `ENV`
lines in the merge Dockerfile cost 28 layers; consolidating them into one big
`ENV` took the merge builder from 114 → 86 layers on 2026-08-03, and the final
image from a 125 cap-hit to ~108).

Rules of thumb:

- One consolidated `ENV` per Dockerfile stage (same-instruction `${}` refs
  don't resolve — write derived paths as literals).
- Batch flat-file `COPY`s with multi-source form when the destination matches.
- After adding instructions anywhere in the chain, audit headroom:

  ```pwsh
  docker inspect <tag> --format '{{len .RootFS.Layers}}'   # per chain image
  ```

The BuildKit lane is far less exposed (metadata instructions are config-only
there), but the exported images still obey the cap when loaded into docker.

**Why `docker build` can't be fixed on this host.** The classic Windows builder
offers no working CPU lever, all verified with a ~6-second repro (a Dockerfile
that writes a dummy layer):

| Attempt | Result |
|---|---|
| `docker build --cpu-count N` | rejected — "unknown flag" |
| `docker build --cpuset-cpus 0-15` | build fails |
| `docker build --isolation process` | container sees all 32 CPUs **but cannot commit any layer** — `hcsshim::ActivateLayer failed 0x20 "file used by another process"`, even for a 100 MB dummy layer |

The `ActivateLayer` failure is **not** Windows Defender, Windows Search, or
SysMain — all were ruled out by disabling each and re-running the repro. It is a
container-filter / Docker-Engine level defect with process isolation on this
host, so `--isolation process` is unusable for building (every build dies at the
first commit). Hyper-V isolation commits reliably but is stuck at 2 CPUs. **Do
not add `--isolation process` to any `docker build`.**

**The run+commit path (how media-core gets its cores).** `docker run` — unlike
`docker build` — *does* honor `--cpu-count` under Hyper-V (verified: `docker run
--isolation hyperv --cpu-count 16` → `NUMBER_OF_PROCESSORS=16`), and a Hyper-V
container commits fine via `docker commit`. So `build.ps1` builds media-core as:

1. `docker build` a thin **builder image** (`Dockerfile.media-builder --target media-core`) —
   toolchain + all media-core scripts/patches, no heavy RUN, so its cheap COPY
   layers commit fine under Hyper-V.
2. `docker run --isolation hyperv --cpu-count $MediaCoreCpus --memory
   ${MediaMemoryGb}g <builder> pwsh -File build-media-core-all.ps1` — runs
   the whole ONNX → GenAI → OpenCV → FFmpeg chain in one container at the full
   CPU count. `Get-BuildJobCount` sees `--cpu-count` as `ProcessorCount`, so ONNX
   compiles at `min(cpu-count, memGB/4)` (e.g. `-j14` at `-MediaCoreCpus 16
   -MediaMemoryGb 56`).
3. `docker commit` the container to `local/kataglyphis:windows-media-core` — a
   drop-in replacement for the old `Dockerfile.media-core` output.

`Invoke-MediaBranchRunCommit` in `build.ps1` implements this via the generic
`Invoke-RunCommitStage` helper; tune it with `-MediaCoreCpus` (default: the host's
logical processor count, `[Environment]::ProcessorCount`) and `-MediaMemoryGb`
(default 0 = auto-detect from host RAM minus `-HostReserveGb`).

**Which stages use run+commit.** The same `Invoke-RunCommitStage` path is used for
every **CPU-bound** stage, so they all build at `-MediaCoreCpus` cores instead of
the 2-CPU `docker build` cap:

| Stage | Builder Dockerfile | Run step (the heavy compile) |
|-------|--------------------|------------------------------|
| toolchain | `Dockerfile.toolchain-builder` (clones CPython + writes props) | `build-toolchain-all.ps1` (`PCbuild\build.bat`) |
| media-core | `Dockerfile.media-builder --target media-core` | `build-media-core-all.ps1` (ONNX→GenAI→OpenCV→FFmpeg) |
| media-litert | `Dockerfile.media-builder --target media-litert` | `build-litert-all.ps1` (LiteRT→LiteRT-LM) |
| media-tvm | `Dockerfile.media-builder --target media-tvm` | `build-media-tvm-all.ps1` (TVM → IREE) |
| media merge | `Dockerfile.media-merge-builder` (fan-in `COPY --from` + env) | `build-gstreamer-from-source.ps1` |

The **merge stage splits**: the fan-in (`COPY --from` of the three branch trees)
*must* be a `docker build` because `docker run` can't `COPY --from`, but it is only
IO so 2 CPUs is fine; the CPU-bound GStreamer compile then runs via run+commit.
`docker commit` preserves the builder image's ENV, so each result image is a
drop-in replacement for the old single-Dockerfile output.

The `litert`/`tvm` aux branches **also** run+commit at `-MediaCoreCpus` cores (via
their `Dockerfile.media-builder` targets): media-core is already committed when they
run, so the whole CPU/RAM budget is free — e.g. `~j19` at 32 CPU / 39 g on this host
(still memory-bound per the note below). `base`/`sdk` are the only stages that never
exceed 2 CPUs — they're network/install-bound (no benefit from more).

> **NOTE — parallelism is memory-bound, not core-bound.** `Get-BuildJobCount =
> min(cpu-count, MEMORY_LIMIT_GB / per-job-GB)`. ONNX is ~4 GB/job, so at 48 GB it
> runs `~j12` whether you give it 16 or 32 cores; extra cores only speed the
> lighter TUs (FFmpeg, CPython, GStreamer). True `j32` on ONNX needs ~128 GB RAM,
> which this host does not have — so on the ONNX long pole, **RAM is the ceiling,
> not cores.**

**Trade-off:** a single `docker run` has no per-stage layer cache, so a mid-chain
failure used to re-run the whole chain (unlike a multi-`RUN` `docker build`, where
each completed step is cached). The persistent **sccache** remote (below) covers
recompilation, so in practice only uncached objects rebuild. Regression symptom
for the whole mechanism: `ninja -j2` in `out\windows-build-logs\media-core.log`,
or an `ActivateLayer` error on any commit.

**Resume after a mid-chain failure:** on a non-transient run failure, build.ps1
now PRESERVES the container (it holds every completed stage's output in
`C:\runtime`) and prints the recovery recipe:

```powershell
docker commit <container> <result-tag>-partial
docker container rm -f <container>
docker run --isolation hyperv --cpu-count <N> --memory <M>g --name <container> `
    <result-tag>-partial pwsh -NoProfile -ExecutionPolicy Bypass `
    -File C:\temp\scripts\<payload>.ps1 -ResumeFrom '<failed stage>'
docker commit <container> <result-tag> ; docker container rm -f <container>
```

`-ResumeFrom` (all three `build-*-all.ps1` payloads → `Invoke-SourceBuildChain
-StartAt`) skips the stages before the named one; an unknown name throws instead
of silently rebuilding from scratch. Pick the stage from the last
`=== <label> stage: ... ===` banner in the run log. Do NOT `docker start` the
failed container — that re-runs the original chain command from the beginning.

**Root cause (fully diagnosed).** The commit failure is the **`wcifs`** minifilter
(Windows Container Isolation FS) refusing to detach the process-isolation layer on
container teardown — dockerd's `panic.log` shows
`hcsshim::UnprepareLayer failed ... ERROR_FLT_DO_NOT_DETACH (0x801f0010)`, which
leaves the layer files locked so the subsequent commit's `ActivateLayer` fails
`0x20`. The trigger is an **OS-class mismatch**: the host is a Windows **client**
build (26200 / 25H2) but the only base image is Windows **Server** `servercore:ltsc2025`
(build 26100). A client-kernel `wcifs` will not detach a Server layer. This is
below Docker *and* below containerd — it reproduces identically for `docker build`,
`docker run`+`commit`, the containerd snapshotter, and `nerdctl commit`, on the
newest stack (Docker 29.5.3 / containerd 2.3.1 / hcsshim 1.2.1). It is **not**
contradicted by Microsoft's host≥image compatibility matrix: the matrix governs
whether the image can *run* under process isolation (it does — the `RUN` step
executes), not layer *commit/teardown*. The only real fixes are environmental:
build on a **matching build-26100 host** (Windows 11 24H2 or Windows Server 2025),
or wait for a Windows/hcsshim fix.

### Re-testing process isolation on new versions (is the bug gone yet?)

After **any** Docker Engine / containerd / hcsshim / Windows / base-image upgrade,
re-check whether `docker build --isolation process` can commit a layer again — if
it can, the *entire* Windows build (not just media-core) could run at full CPU
count and the run+commit workaround could be retired. A durable, self-contained
probe lives under `windows/diagnostics/`:

```pwsh
.\windows\diagnostics\test-process-isolation-commit.ps1
```

It records the current Docker/containerd/host build numbers, runs a `docker run
--isolation process` control (expected: PASS), then builds a tiny ~100 MB probe
layer with `docker build --isolation process` (`Dockerfile.isolation-probe`) and
prints a clear verdict:

- **`BUG GONE` (exit 0):** the commit succeeded — process isolation is usable for
  `docker build`. Follow the on-screen next steps (switch heavy stages to
  process isolation, re-run the full build to confirm parity, then retire
  `Invoke-RunCommitStage` and update this doc + the host-quirks notes).
- **`BUG PRESENT` (exit 1):** the known `wcifs`/`ActivateLayer 0x20` failure still
  occurs — keep the run+commit workaround.
- **exit 2:** the build failed with a *different* signature — investigate; do not
  assume it is fixed.

To test a hypothetical newer *matching-build* base image, pass `-Base <image>`.
Baseline as of Docker 29.5.3 / containerd 2.3.1 / host build 26200 with
`servercore:ltsc2025`: **BUG PRESENT**.

### Run-side wcifs symptoms (process isolation)

The same `wcifs` filter that breaks layer *commits* on this host/base skew also
breaks **runtime file operations inside image-layer directories** of
process-isolated containers (surfaced 2026-07 building
Kataglyphis-Inference-Engine inside the image):

- **Create-then-rename of fresh files fails `ERROR_PATH_NOT_FOUND`**
  (deterministic in hot paths). This breaks `git init/clone/checkout` (*"could
  not write config file"*, *"unable to write new index file"*) and Dart's
  `File.renameSync` (e.g. the sqlite3 package's native-asset hook).
- Plain **copies and tar extractions** in the same directories succeed.
- Directories **created fresh in the sandbox** (e.g. `C:\foo`) are unaffected.
- **Bind mounts avoid the layer FS but are NOT a full fix** (verified 2026-07-16):
  on mounted paths, plain writes and cmd `copy`/`ren` work, but **Dart's
  `copySync`/`renameSync` fail with errno 3** (`bindFlt` rejects the Dart
  runtime's two-path file operations on this skewed host). Consumer recipe:
  bind-mount the sources, then junction the Dart/Flutter write dirs
  (`.dart_tool`, `build`) from the mounted workspace to **container-local**
  dirs (`mklink /J`, run inside the container) — Dart ops work in fresh
  sandbox dirs. A **Dev Drive** source additionally needs
  `fsutil devdrv setfiltersallowed bindFlt, wcifs` once (elevated), then a
  remount.
- **The bind-mount target must NOT already exist in the image** (verified
  2026-07-16): `--mount target=C:\workspace` (a baked image dir) fails at
  container creation with `hcs::CreateComputeSystem ... Die Anforderung wird
  nicht unterstützt`, while the same source mounted to a fresh target
  (`target=C:\ws-mnt`) works. Version-matched CI runners mount over existing
  dirs fine — consider not pre-creating `C:\workspace` in the image, or adopt a
  fresh-target convention on skewed hosts.
- `docker cp` into a **running** Windows container silently copies nothing, and
  against a **stopped** container it triggers the ActivateLayer lock. Use
  `tar -cf - . | docker exec -i <container> tar -xf - -C <dir>` instead.

The run-side variant has its own "is the bug gone yet?" probe, mirroring the
commit-side one — re-run it after any Docker / containerd / hcsshim / Windows /
base-image upgrade:

```pwsh
.\windows\diagnostics\test-layer-rename.ps1
```

It renames files in a fresh sandbox dir (CONTROL, expected PASS) and in an
image-layer dir (`C:\Windows\Temp`; VERDICT, **expected FAIL today**) and prints
**BUG GONE** (exit 0) / **BUG PRESENT** (exit 1) / unexpected-signature (exit 2).
Pass `-Base <image>` to probe the built developer image's own layers.

### GPU acceleration in containers (DirectML on the host GPU)

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
upgrade with the self-contained probe under `windows/diagnostics/`:

```pwsh
.\windows\diagnostics\test-gpu-passthrough.ps1
```

It prints host/image builds and partitionable GPUs, runs a process-isolation control,
attaches the GPU device, compiles + runs a DXGI adapter enumerator inside the
container, and gives a verdict: **PASSTHROUGH WORKS** (a HARDWARE adapter is visible),
**BLOCKED** (build-skew `CreateComputeSystem` failure), or **DEVICE-NOT-INJECTED**
(started but only WARP). Note the DML probes in `smoke-test-container.ps1` validate
that the provider is *built and registered* (`GetAvailableProviders` → `dml=1`, plus
the x64 `D3D12Core.dll` PE-machine check); they do **not** create a device, so they
pass under either isolation regardless of whether a hardware adapter is present.

### Rust toolchain (rustup WITH a default toolchain — never toolchain-less rustup)

Rust is provisioned **exclusively via rustup** (`setup-rust-toolchain.ps1` runs
`rustup-init.exe -y --default-toolchain stable --profile minimal`), and
`flutter_rust_bridge_codegen` is baked alongside so Flutter+Rust consumers skip a
minutes-long cold `cargo install` per fresh container.

rustup is **required**, not merely tolerated: Flutter's **Cargokit** (the build
glue used by `flutter_rust_bridge`-style plugins, e.g. `rust_builder/cargokit` in
Kataglyphis-Inference-Engine) enumerates toolchains/targets via rustup and aborts
with *"rustup not found in PATH."* otherwise — a scoop-only Rust (the previous
setup) failed every Flutter+Rust consumer build at the CMake install step.

The failure mode the old "never rustup" rule guarded against is real but
**narrower than the rule**: a **toolchain-less** rustup (`rustup-init
--default-toolchain none`) drops proxy shims (`cargo.exe`, `rustc.exe`, …) into
`CARGO_BIN` that resolve **no** toolchain and fail with *"rustup could not choose
a version of cargo … no default is configured"*. A rustup installed **with a
default toolchain** resolves fine — and because `Dockerfile.base` points
`CARGO_HOME`/`CARGO_BIN` at `C:\Users\ContainerAdministrator\.cargo`, which sits
ahead of scoop's shim dir on `PATH`, the proxies winning is now the *correct*
outcome. Keep exactly one Rust provider: no `scoop install main/rust` alongside.

Rust is DELIBERATELY unpinned on this lane (`stable` at build time;
versions.env's `RUST_VERSION` pins only the Linux lane). The smoke test asserts a
well-formed rustc version, the Cargokit probe shape (`rustup show
active-toolchain`, `rustup which cargo`), `flutter_rust_bridge_codegen
--version`, and a compile/link/run probe — never the versions.env value.

### Media fan-out and memory budgeting

**Media scheduling is sequential** (media branch logs land in
`out\windows-build-logs\media-core.log` / `media-litert.log` / `media-tvm.log`,
plus `gstreamer.log` for the merge). Sequential gives media-core the *whole* host
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

media-core, toolchain, and the merge/GStreamer stage all build via the run+commit
path (see § Build isolation and CPU parallelism) at `-MediaCoreCpus` CPUs. The
litert/tvm aux branches run+commit at `-MediaCoreCpus` too — the full budget is
free once media-core has committed.

### Maximum resource envelope (verified 2026-07-12)

The defaults ARE the maximum for this 64 GB / 32-thread host — there is no
faster configuration to unlock, and the full-chain rebuild of 2026-07-12
(base → sdk → toolchain → media → final, phase-tagged resource CSV) is the proof:

| Phase        | Minutes | AvgCpuPct | MaxCpuPct | MinFreeGB |
|--------------|---------|-----------|-----------|-----------|
| media-core   | 111     | 37        | 100       | **0.2**   |
| media-litert | 18      | 38        | 100       | 24.9      |
| media-tvm    | ~25     | 42        | 100       | 41.8      |

- **CPUs: 32/32 on every heavy stage.** `docker run --cpu-count 32` (run+commit)
  is the only >2-CPU path on this host; every compile stage uses it. `docker
  build` stages are pinned at 2 CPUs by the host defect — that is why they carry
  only cheap COPY/clone layers.
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

**Per-run resource log.** Every `build.ps1` run samples host CPU / free RAM /
commit charge / container-VM (`vmmem`) size every 20 s into
`out\windows-build-logs\resources-<timestamp>.csv`, tagged with the current build
phase (`build:<dockerfile>`, `run:<stage>`, `commit:<stage>`), and prints a
per-phase exhaustion summary at the end — including on failure. Re-analyze any
run later with
`pwsh -File windows/scripts/build-resource-sampler.ps1 -Summarize -CsvPath <csv>`;
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

### Persistent compile cache (sccache)

Without BuildKit cache mounts a container-local sccache cache dies with the
layer, so the WebDAV remote is the only compile cache that survives a
container. **sccache is therefore REQUIRED by default for the media stages:
build.ps1 fails fast when a media stage is requested and no reachable endpoint
is configured** (`-NoSccache` opts into a deliberate cache-less build). The
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
.\windows\build.ps1 -Gpu -SccacheEndpoint http://192.168.1.10:5000
```

CMake-based builds (ONNX, GenAI, OpenCV, LiteRT, LiteRT-LM, TVM) then route
clang-cl through sccache, and since 2026-08-04 GStreamer (Meson) is cached too
(`build-gstreamer-from-source.ps1` sets `CC`/`CXX` to `'sccache clang-cl'`
when the remote backend is configured). FFmpeg (MSVC/make) remains uncached.
The first build populates the cache; subsequent `--no-cache` rebuilds and
version bumps reuse unchanged object files.

> **Note (.dockerignore):** The repo `.dockerignore` must NOT contain a `windows/` exclusion — the Windows Dockerfiles COPY from the `windows/scripts/` directory within the build context. If `windows/` is added to `.dockerignore`, the COPY steps will fail with "file not found in build context". This exclusion is safe for Linux builds (which use `linux/` context) but breaks Windows builds.

## Stevedore Setup Fixes

After installing Stevedore, apply these post-install fixes. They are the canonical source and are maintained in lockstep with the project's CI requirements.

### Fix 1: Remove stale Docker Desktop daemon.json

If Docker Desktop was previously installed, its daemon config at `C:\ProgramData\docker\config\daemon.json` may specify a hosts pipe (`docker_engine_windows`) that conflicts with Stevedore's `docker_engine` pipe. Remove it:

```pwsh
if (Test-Path "C:\ProgramData\docker\config\daemon.json") { Remove-Item "C:\ProgramData\docker\config\daemon.json" }
```

### Fix 2: Change default runtime from hcsshim to runhcs

Stevedore's service defaults to the `com.docker.hcsshim.v1` runtime, but only the `io.containerd.runhcs.v1` shim binary (`containerd-shim-runhcs-v1.exe`) ships with Stevedore. Update the service binary path:

```pwsh
sc config stevedore binPath="\"C:\Program Files\Stevedore\dockerd.exe\" --run-service --service-name stevedore --group docker-users --host npipe:////./pipe/dockerDesktopWindowsEngine --host npipe:////./pipe/docker_engine --containerd=npipe:////./pipe/containerd-containerd --default-runtime=io.containerd.runhcs.v1"
```

Then restart:

```pwsh
net stop stevedore /y
net start stevedore
```

### Fix 3: Windows Defender exclusions for containerd data

Add exclusions for containerd's snapshot directories (prevents hcsshim layer commit errors — `hcsshim::ActivateLayer failed (0x20)`):

```pwsh
Add-MpPreference -ExclusionPath "C:\ProgramData\containerd"
Add-MpPreference -ExclusionPath "C:\ProgramData\nerdctl"
Add-MpPreference -ExclusionPath "C:\temp"
```

### Fix 4: docker.exe vs nerdctl (historical — pre-CNI-conf state)

Before the CNI `nat` conf was installed (2026-08-03), `nerdctl build` lacked
DNS resolution and `nerdctl run` failed outright on this host (`failed to
create default network: needs CNI plugin "nat" to be installed in CNI_PATH` —
the conf, not the binary, was missing), so `docker.exe` was the only working
tool. Current state: with `0-containerd-nat.conf` installed (see § Getting it
going, step 2) `nerdctl` works from **admin** shells; builds go through
`build-buildkit.ps1`/buildctl on the preferred lane. Stevedore's `docker.exe`
remains the classic-lane tool and needs no CNI plugin:

```pwsh
"D:\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache -t local/kataglyphis:windows-base -f windows/Dockerfile.base .
```

## Running the Image

Run with **process isolation** to get the host's full CPU count (Hyper-V
isolation, the Windows default, exposes only 2 logical CPUs). Process isolation
is allowed here because the host build (26200) is ≥ the container base build
(`servercore:ltsc2025`, 26100):

```pwsh
& "D:\Stevedore\bin\docker.exe" run --memory 48g -it --rm --isolation process `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

Drop `--isolation process` to fall back to Hyper-V isolation (stronger boundary,
but capped at 2 CPUs on this host). NAT networking and DNS work in both modes.

## Smoke Testing

After building, run the container smoke test to verify all components:

```pwsh
# Run smoke tests inside the built container. On a GPU (nvidia-lane) image,
# ALWAYS pass -ExpectGpu: without it a broken/missing CUDA_ROOT env silently
# SKIPS the whole CUDA section instead of failing it (the gate otherwise
# cannot distinguish a legitimate CPU-only image from a damaged GPU image).
& "C:\Program Files\Stevedore\bin\docker.exe" run --memory 48g -it --rm --isolation process `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  pwsh -File C:\temp\scripts\smoke-test-container.ps1 -ExpectGpu
```

The smoke test validates 22 categories including CUDA Toolkit 13.3, ONNX Runtime with CUDA, ONNX GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with CUDA, TVM (source-built), IREE (source-built; native MLIR→vmfb compile + local-task execution, a CUDA-target compile-only assert on the GPU lane, and a python `iree.compiler`→`iree.runtime` end-to-end), FFmpeg (source-built with DNN/ONNX integration), compiler integration, environment-pointer integrity, and Python bindings. **Current baseline (2026-07-14, GPU lane): 167 passed / 0 failed / 1 skipped** — the single skip is GPU device passthrough, blocked by the host/base OS-build skew. Growth over the 153 baseline: the PyAV asserts (staged `av-*.whl` + an in-memory mpeg4 encode through the container-built FFmpeg) and the IREE suite (section 22 native compile+run incl. a CUDA-target compile-only assert, wheel-pin + `--version` asserts, section 20 staged-wheel + python end-to-end asserts, section 19 `IREE_ROOT`/`IREE_BIN` pointers).

### What is verified: native vs. Python

**Native (C++/CLI) functionality is verified end-to-end.** The suite does not stop
at existence checks: it compiles, links, and *runs* probe programs against the
source-built libraries — ONNX Runtime (C API ABI + a real inference session over
an embedded 63-byte Identity model on the CPU EP), OpenCV (core API call), TVM
(full dependent-DLL chain load), LiteRT-LM (its `litert_lm_main.exe` smoke-run is
a hard gate of the media build itself), FFmpeg (a real lavfi→null filter graph),
GStreamer (a live `videotestsrc ! videoconvert` pipeline), plus clang-cl /
CMake+Ninja / MSBuild integration builds. Version pins (cmake, python, gstreamer)
are asserted against versions.env to catch stale baked layers.

**Python bindings are built, shipped, and functionally verified (since
2026-07-13).** The media branches build python bindings for every source-built
library that supports them and stage the wheels centrally at
**`C:\runtime\wheels`** (`PYTHON_WHEELS` env): `onnxruntime` (CUDA+TRT+DML EPs,
`ENABLE_PYTHON=ON`), `onnxruntime-genai-cuda` (`BUILD_WHEEL=ON`),
`apache-tvm` (scikit-build-core), `iree-base-compiler` + `iree-base-runtime`
(built from the IREE ninja tree's synthesized `compiler/`+`runtime` pip dirs
with `--no-build-isolation` so the wheels pack the existing LLVM objects
instead of rebuilding them), and `av` (PyAV compiled from sdist against
the source-built FFmpeg via `setup.py --ffmpeg-dir` — PyPI's own av wheel is
structurally unloadable on Server Core because its bundled avdevice imports
the desktop-only `AVICAP32.dll`; note the generic `h264` encoder alias
resolves to `h264_d3d12va`, so headless code should request software codecs
like `mpeg4`/`libx264` by name). `FFMPEG_VERSION` is pinned to the release tag
`n9.0` since 2026-08-04 (it previously tracked `master`, which is when an
upstream drop moved `avformat.lib` et al. from `lib\` to `bin\` overnight —
2026-07-13, PyAV died with LNK1181). `build-ffmpeg-from-source.ps1` still
normalizes the import-lib layout after `make install` as a guard across tag
bumps: every `.lib`/`.def` is
harvested into `lib\`, missing import libs are regenerated from their `.def`
via `lib.exe`, and the PyAV step logs the lib inventory up front so the next
layout drift fails loudly with data. `cv2` ships installed into CPython's
site-packages (the opencv repo has no wheel machinery — opencv-python is a
separate upstream project); LiteRT has no python bindings on this lane
(bazel-only python package). All bindings are pre-installed with their PyPI
deps, so `python -c "import onnxruntime, onnxruntime_genai, cv2, tvm, av"`
works out of the box. Smoke section 20 verifies wheels + `win_amd64` tags, real
python-side ONNX inference, a cv2 PNG round-trip, and genai/tvm imports.
Load-bearing plumbing (do not remove): the `sitecustomize.py` shim fixes the
clang-built CPython's win32 platform misreport AND registers the image's
native DLL homes via `os.add_dll_directory` (CUDA 13/cuDNN 9 keep their
runtime DLLs in `bin\x64`; python 3.8+ ignores PATH for pyd dependencies);
OpenCV builds with `WITH_MSMF=OFF` *and* `WITH_OBSENSOR=OFF` because both
hard-import Media Foundation, which Server Core does not ship.

### The torch step (Orchestr-ANT-ion app environment)

The final image bakes the runtime orchestrator at
**`C:\opt\Kataglyphis-Orchestr-ANT-ion`** (`TORCH_APP_DIR`), assembled by
`windows/scripts/assemble-torch-app.ps1` (mirror of the linux
`assemble-torch-app.sh` stage) during the final `docker build`:

- **Ref**: `build.ps1` uses versions.env's **`APP_REF` pin by default** (the
  same commit always builds the same final image); pass `-LatestApp` to opt
  into resolving the app repo's newest release tag at build time via a live
  `git ls-remote` (the old always-on behavior). The resolved ref reaches the
  Dockerfile as the `APP_REF` build-arg, so moving the app busts exactly the
  torch-step layer.
- **Environment**: `uv sync` on the source-built CPython (extras `ml-ai`,
  `docs`, `pytorch-cpu`, `test`; the wxPython GUI extra excluded, like linux),
  then a reconcile so this lane's wheels always win: PyPI onnx/genai/opencv
  families are uninstalled, `C:\runtime\wheels` force-installed `--no-deps`
  (genai-cuda's metadata names `onnxruntime-gpu`, which our combined wheel
  replaces), and `cv2` + `tvm_ffi` + the sitecustomize shim staged from base
  site-packages into the venv.
- **Known limitation**: `ai-edge-litert` is skipped
  (`--no-install-package`) — its pinned version ships no cp314 wheel and the
  LiteRT python package is bazel-only on Windows, so the app's LiteRT code
  path is unavailable in this venv.
- **Gates**: the docker build itself fails unless the venv passes the import
  battery (numpy/cv2/torch/onnxruntime with a CUDA-EP build assert/genai/tvm)
  **and the app's own wheel-smoke suite** (`python -m orchestr_ant_ion.smoke`
  — real torch/torchvision/ORT-inference/OpenCV work). The check inventory is
  the app's per-tag choice, so the expected pass count moves with `APP_REF`;
  the rule on this lane is: **all checks pass except a single WARN for the
  litert skip** (the `ai-edge-litert` limitation above), plus any checks the
  pinned app tag does not yet ship (e.g. an iree check counts only once a tag
  includes it). Smoke section 21 re-runs the same verification offline on
  every suite run.
- **Usage**: `C:\opt\Kataglyphis-Orchestr-ANT-ion\.venv\Scripts\python.exe`
  (or `uv run` from `TORCH_APP_DIR`) is a ready environment where
  `import onnxruntime, onnxruntime_genai, cv2, tvm, torch` all resolve to the
  source-built wheels plus the app's locked PyPI dependency set.
