# Kataglyphis-ContainerHub

## Container Architecture

Three build lanes — **cross lane** (`linux/amd64` host, cross-compiles for all arches, tags `:cross-*`), **runtime lane** (native target platform via QEMU, tags `:latest-cross-*`), and **Windows lane** (native Windows Containers, tag `:winamd64`). Supported Linux architectures: `amd64`, `arm64`, `riscv64`. Windows target: `windows/amd64` only.

See `docs/linux-build-basics.md` for the image hierarchy diagram, `docs/overview.md` for the tag inventory, `docs/windows-builds.md` for Windows container details, and the intro tables below (Dockerfiles, naming) for quick reference.

### Dockerfiles

| Dockerfile | FROM | Produces |
|------------|------|----------|
| `Dockerfile.base` | `ubuntu:26.04` | `:base` |
| `Dockerfile.toolchain` | `:base` | `:cross-compiler-amd64` |
| `Dockerfile.sdk` | `:cross-compiler-amd64` | `:cross-sdk-<arch>` |
| `Dockerfile.media` | `:cross-sdk-<arch>` | `:cross-media-<arch>` |
| `Dockerfile.android` | `:cross-media-<arch>` | `:cross-android-<arch>` |
| `Dockerfile.package` | `:base` + `:cross-android-<arch>` | `:latest-cross-package-<arch>` |
| `Dockerfile.torch` | `:latest-cross-package-<arch>` | `:latest-cross-<arch>` |
| `Dockerfile.nvidia` | `:cross-sdk-<arch>` | (optional GPU layer) |
| `Dockerfile.amd` | `:cross-sdk-<arch>` | (optional GPU layer) |
| `windows/Dockerfile.base` | `mcr.microsoft.com/windows/servercore:ltsc2025` | `local/kataglyphis:windows-base` |
| `windows/Dockerfile.sdk` | `windows-base` | `local/kataglyphis:windows-sdk` |
| `windows/Dockerfile.toolchain` | `windows-sdk` | `local/kataglyphis:windows-toolchain` |
| `windows/Dockerfile.media` | `windows-toolchain` | `local/kataglyphis:windows-media` |
| `windows/Dockerfile` | `windows-media` | `ghcr.io/.../kataglyphis_beschleuniger:winamd64` |

### Windows-Specific Naming

The Windows lane uses local intermediate tags (`local/kataglyphis:windows-base`, `local/kataglyphis:windows-sdk`, `local/kataglyphis:windows-toolchain`, `local/kataglyphis:windows-media`) and publishes the final image as `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`. See `docs/windows-builds.md` § Build Commands for the full build sequence.

---

## Quick Reference

Most common build commands:

```bash
# Full cross-build chain (base -> compiler -> sdk -> media -> android -> runtime)
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64

# Compiler image only (amd64-hosted, contains cross toolchains for all arches)
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64

# Compiler with custom image repo (matches --image-repo on the orchestrator)
./linux/scripts/build-cross-compiler.sh --image-repo ghcr.io/myorg/kataglyphis_beschleuniger --push

# Single cross stage (e.g., rebuild just the sdk for arm64)
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push

# Verify chain freshness without building
bash linux/scripts/build-cross-chain.sh --verify-chain --target-arches amd64,arm64,riscv64

# Standalone quick chain verification (lighter, no orchestrator flags)
bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64

# Print the full stage graph with tag names (no builds)
bash linux/scripts/build-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64

# Dry-run: print all build commands without executing
bash linux/scripts/build-cross-chain.sh --dry-run --target-arches amd64,arm64,riscv64

# Cheap packaging validation before publish (see docs/linux-cross-builds.md)
# Uses the `wrapper-smoke` target in Dockerfile.package

# Reinstall QEMU/binfmt after host reboot
sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all
```

### Windows Container Build (see `docs/windows-builds.md`)

All stages use **Ninja+clang-cl+lld-link** (not MSBuild/VS generator). Use Stevedore's `docker.exe` for builds (nerdctl has DNS issues in BuildKit on Windows).

```powershell
# Install Stevedore (prerequisite for Windows Containers via nerdctl)
winget install stevedore   # or: choco install stevedore

# Stage 1: Windows toolchain base (VS Build Tools 18, Scoop tools, LLVM 22)
docker build --platform windows/amd64 --no-cache `
  -t local/kataglyphis:windows-base -f windows/Dockerfile.base .

# Stage 2: GPU SDK layer (CUDA 12.9 Toolkit + cuDNN 9.10, verified post-install)
docker build --platform windows/amd64 --no-cache `
  -t local/kataglyphis:windows-sdk `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-base `
  -f windows/Dockerfile.sdk .

# Stage 3: CPython 3.14 built from source with ClangCL toolset (not MSVC v143)
docker build --platform windows/amd64 --no-cache `
  -t local/kataglyphis:windows-toolchain `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-sdk `
  -f windows/Dockerfile.toolchain .

# Stage 4: Media layer — all source-built with Ninja+clang-cl:
#   - ONNX Runtime 1.26 (CPU-only; DirectML disabled due to VS 2026 STL hardening
#     + clang-cl incomplete-type incompatibility in DirectML helper headers)
#   - ONNX GenAI 0.13.1 (via NuGet package)
#   - OpenCV 5.x (with global AVX2/SSSE3/SIMD flags for clang-cl)
#   - GStreamer 1.29.1 (Meson+clang-cl, CUDA auto-detected)
docker build --platform windows/amd64 --no-cache `
  -t local/kataglyphis:windows-media `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-toolchain `
  -f windows/Dockerfile.media .

# Stage 5: Final developer image (VsDevCmd entrypoint)
docker build --platform windows/amd64 --no-cache `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-media `
  -f windows/Dockerfile .
```

### Windows Build Notes

| Component | Generator | Compiler | Notes |
|-----------|-----------|----------|-------|
| CPython 3.14 | `PCbuild\build.bat` | ClangCL (v145→ClangCL via Directory.Build.props) | Requires VS ClangCL toolset |
| ONNX Runtime 1.26 | Ninja | clang-cl, lld-link | DirectML disabled. Patches build.ninja for MSVC-only `/experimental:external`. Runs under VsDevCmd for MASM (`.asm` files). |
| ONNX GenAI 0.13.1 | `python build.py` | clang-cl (Ninja generator) | Source-built via `build.py --cmake_generator Ninja --cmake_extra_defines CMAKE_C_COMPILER=clang-cl CMAKE_CXX_COMPILER=clang-cl`. VsDevCmd environment loaded for MSVC STL headers. |
| OpenCV 5.x | Ninja | clang-cl, lld-link | Global SIMD flags: AVX2, SSSE3, SSE4.1/4.2. Custom `CMAKE_AR` path fix. |
| GStreamer 1.29 | Meson | clang-cl | Downloaded as tarball + subproject wraps. CUDA auto-detected. |

### Windows Scripts

| Script | Location | Purpose |
|--------|----------|---------|
| `build-onnx-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl build with build.ninja patching and VsDevCmd wrapper |
| `build-onnx-genai-from-source.ps1` | `windows/scripts/` | Source build via `python build.py` with Ninja+clang-cl (not NuGet). Loads VsDevCmd environment, clones git tag, runs official `build.py --cmake_generator Ninja`. |
| `build-opencv-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl with global SIMD flags and mlas `<cstring>` patch |
| `build-gstreamer-from-source.ps1` | `windows/scripts/` | Meson+clang-cl with wrap pre-extraction |
| `WindowsSourceBuild.Common.psm1` | `windows/scripts/modules/` | Reusable build helpers: `Invoke-GitClone`, `Invoke-CmakeConfigure`, `Invoke-CmakeBuild` |
| `setup-cuda.ps1` | `windows/scripts/` | Now includes cuDNN post-install verification (headers/libs/DLLs) |
| `smoke-test-container.ps1` | `windows/scripts/` | Comprehensive container validation (14 test categories) |

For detailed build commands, see `docs/windows-builds.md`.

### Orchestrator Stage Selection

```bash
# Resume mid-chain (e.g., after rebuilding compiler)
bash linux/scripts/build-cross-chain.sh --from-stage sdk --target-arches amd64,arm64,riscv64

# Build only one stage for one architecture
bash linux/scripts/build-cross-chain.sh --only media --target-arches arm64

# Build per-arch stages in parallel (faster on multi-core machines)
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --parallel-archs

# Build a single cross stage standalone (with digest-pinned parent when --push)
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push
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

The **Windows lane** follows a separate 3-stage build (`base → ai → final`) using nerdctl with Stevedore. See `docs/windows-builds.md` for the full build sequence and prerequisites.

### Prerequisites

- **nerdctl** with BuildKit backend
- **QEMU/binfmt** for foreign-architecture runtime builds (`tonistiigi/binfmt`)
- **Registry access** (GHCR) for pushing intermediate and final images
- **Disk space**: ~50GB+ for full cross chain with all architectures
- **Python 3** for digest resolution (`registry-digest.py`)

### Windows Prerequisites (see `docs/windows-builds.md` § Prerequisites)

- **Stevedore** (`winget install stevedore` or `choco install stevedore`) — provides nerdctl + containerd for Windows Containers
- **Reboot** after Stevedore install to enable the Windows Containers feature
- **Docker Desktop or Rancher Desktop** can also be used with `docker` commands (swap `nerdctl` → `docker` in build commands)
- **DNS workaround**: Windows `nerdctl build` has broken DNS in BuildKit containers. Use Stevedore's bundled `docker.exe` for builds: `"%ProgramFiles%\Stevedore\bin\docker.exe" build`. `nerdctl run` works fine for running containers.

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

- `linux/`: Linux Dockerfiles for base, toolchain, SDK, media, Android, package, Torch, and GPU accelerator images. `Dockerfile.torch` is the final wrapper (includes runtime scripts + entrypoint) and the canonical source for shared final-stage elements (entrypoint, labels, runtime scripts, WORKDIR, VOLUME, HEALTHCHECK, kataglyphis user).
- `linux/scripts/`: helper scripts organized by layer: `01-core/` (shared utilities), `02-toolchain/` (compiler builds), `03-media/` (library builds), `04-runtime/` (entrypoint and env), `05-frameworks/` (TVM, Torch), `06-packaging/` (assembly and validation). Top-level build orchestrators: `build-cross-chain.sh`, `build-cross-compiler.sh`, `build-cross-stage.sh`, `build-sdk-artifacts.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`. Verification: `verify-cross-chain.sh`, `verify-critical-fixes.sh`, `verify-artifact-copy-parity.sh`.
- `docs/`: the canonical build and troubleshooting instructions (including `docs/windows-builds.md` for Windows containers).
- `windows/`: Windows container images.
- `out/`: generated build artifacts (OCI layouts, rootfs exports). Subdirectories: `out/local-oci/android/<arch>`, `out/linux-sdk/<arch>`, `out/linux-runtime/<arch>`. Excluded from Docker build context via `.dockerignore`.
- `docs/scripts/sync_versions.py`: keeps the source-controlled version snapshot in `README.md` aligned with the Dockerfiles and setup scripts.

---

## Code Organization

Key shared utilities and where to find them:

- **Architecture resolution:** `platform.sh` provides `canonical_target_arch()` and `canonical_resolve_arch()` as the single source of truth for target architecture resolution. All scripts should use these instead of ad-hoc `dpkg` / `uname -m` chains.
- **Architecture list resolution:** `artifact-common.sh` provides `resolve_arch_list()` which normalizes `TARGET_ARCHES` from both the canonical variable name and common aliases (`TARGET_ARCH`, `ARCHITECTURES`) with a configurable fallback. Use this in top-level scripts that accept architecture lists instead of repeating 4-level fallback chains.
- **Dry-run guard:** `build-helpers.sh` provides `is_dry_run()` which returns 0 when `DRY_RUN` is set to a truthy value. Also provides `_bool_truthy()` for testing any value for boolean truthiness (used by `is_dry_run()` and shared across context-management.sh and cross-stage-build.sh). Use these instead of repeating `[ "${DRY_RUN:-0}" -eq 1 ]` or raw case-statement boolean checks across scripts.
- **Module loading:** `modules.sh` provides `source_modules_framework()` for the standard "find modules.sh in repo or container layout" bootstrap pattern. Call it after sourcing `modules.sh`.
- **CC validation:** `validate-compilers.sh` provides `_validate_cc_target()` which centralizes the dumpmachine/ELF/cc1-compile-to-object/link smoke checks used by both `validate_package()` and `validate_smoke()`.
- **Cross-chain tags:** `tag-naming.sh` provides `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag()`, `cross_media_tag()`, `cross_android_tag()`, and the runtime tag functions for consistent naming across orchestrators and helpers.
- **Stage graph:** `stage-defs.sh` defines the cross-lane stage chain (`base -> compiler -> sdk -> media -> android -> runtime`) declaratively as `CROSS_STAGE_ORDER`. The runtime lane chain (`base -> package -> wrapper`) is defined as `RUNTIME_STAGE_ORDER`. Each stage entry maps to its Dockerfile, parent stage, tag function, and per-arch flag. Both `build-cross-chain.sh` and `--verify-chain` consume this graph so the chain is defined in exactly one place. When adding or reordering stages, update `CROSS_STAGE_ORDER` or `RUNTIME_STAGE_ORDER` in this file. Pin variable initialization is handled by `cross_stage_init_pins()` (replaces the old manual pin declarations in the orchestrator). Internal consistency is checked by `cross_stage_validate_graph()` before every build. The cross→runtime handoff uses `cross_stage_ensure_parent_available()` (graph-driven, replacing the old `_refresh_android_images()`).
- **Chain verification:** `chain-verify.sh` provides `verify_cross_chain_staleness()` (used by both `build-cross-chain.sh --verify-chain` and `verify-cross-chain.sh`) and `describe_cross_chain()` (used by `--describe-chain`). This shared module eliminates the previously duplicated `_verify_link()` / `verify_chain()` logic.
- **Cross-stage build orchestration:** `cross-stage-build.sh` provides `cross_stage_run()`, `cross_stage_build_and_push()`, `cross_stage_build_local()`, `cross_stage_resolve_parent_pin()`, `resolve_pin()`, and `cross_stage_assemble_runtime_helper_args()` — the shared functions that the orchestrator uses to build each stage, push it, and capture the registry digest for pinning. `cross_stage_build_and_push()` and `cross_stage_build_local()` delegate to the shared `_cross_stage_build_impl()` to eliminate duplicated build logic. `cross_stage_run()` accepts a `push` flag (3rd argument, default `1`) so standalone scripts (`build-cross-stage.sh`, `build-cross-compiler.sh`) can use the same function for both push and local modes. `cross_stage_assemble_runtime_helper_args()` is the canonical source for the argument handoff between the orchestrator and `build-runtime-manifest.sh`. `build-cross-stage.sh` wraps these for single-stage rebuilds. `build-cross-compiler.sh` also uses them internally (delegating to the stage graph instead of duplicating build logic).
- **Runtime flow initialization:** `runtime-flow-common.sh` provides `init_runtime_flow_defaults()` — shared initialization for `build-runtime-artifacts.sh` and `build-runtime-manifest.sh`. Both runtime scripts source this directly (it is not included in `artifact-common.sh`'s sourcing chain since only those two scripts need it). Post-parse setup is handled by `runtime_post_parse_setup()` in `cli-parsers.sh`.
- **Retry logic:** `logging.sh` provides `retry <max_attempts> <sleep_sec> <description> <command...>` for standardized retry loops.
- **Mirror args:** `build-helpers.sh` provides `append_mirror_build_args_from_env()` to DRY the mirror argument fallback chain. Use this instead of repeating the `USE_FAST_UBUNTU_MIRROR` / `FAST_UBUNTU_MIRROR_URL` / `FAST_UBUNTU_PORTS_MIRROR_URL` expansion.
- **Version forwarding:** `version-forwarding.sh` auto-discovers version variables from `versions.env` and forwards them as `--build-arg` to all builds via `append_version_build_args()`.
- **Download checksums:** SHA256 checksums for Node.js and uv downloads live in `versions.env` (`NODE_AMD64_SHA256`, `NODE_ARM64_SHA256`, `UV_AMD64_SHA256`, `UV_ARM64_SHA256`, `UV_RISCV64_SHA256`).
- **Runtime stage elements:** `linux/Dockerfile.torch` final stage is the canonical source for the COPY of runtime scripts, WORKDIR, VOLUME, ENTRYPOINT, CMD, HEALTHCHECK, kataglyphis user, and OCI labels.
- **Artifact COPY list:** In `Dockerfile.package`, the `artifact-source` and `package-image` stages carry comments marking the canonical artifact COPY list that must be kept consistent. Run `linux/scripts/verify-artifact-copy-parity.sh` to check.
- **Orchestrator stale-check:** `build-cross-chain.sh --verify-chain` resolves all upstream registry digests and reports whether downstream images may be stale, without performing any builds. The standalone `verify-cross-chain.sh` provides the same check with a lighter footprint. `verify_cross_chain_staleness()` in `chain-verify.sh` is shared by both. Use `--dry-run` to audit stage transitions without executing. Use `--describe-chain` to print the full stage graph with tag names.
- **Builder functions:** `run_nerdctl_build()` is the canonical nerdctl build wrapper with `BUILDKIT_HOST` support. Use it instead of ad hoc `nerdctl build` command assembly.
- **CLI parsing:** `cli-parsers.sh` provides `parse_shared_orchestrator_args()` and `parse_shared_runtime_args()` with a dispatch pattern (`_DP_SHIFT`) shared across all build scripts. Global flags (`--dry-run`, `--parallel-archs`, `--max-parallel-archs`, and mirror flags) are handled automatically by both parsers via `_parse_global_flags()` and `_parse_mirror_flags()` — scripts no longer duplicate these in their local case statements.
- **Dry-run support:** All orchestrators and runtime helpers accept `--dry-run` to print build commands without executing. The cross-chain orchestrator, cross-stage builder, runtime manifest builder, and runtime artifacts builder all support this flag.

### Module Loading Order

`artifact-common.sh` sources 01-core modules in dependency order:
1. `common.sh` (versions.env, logging, platform, ubuntu-mirror, downloads, parallelism)
2. `tag-naming.sh` (cross-chain + runtime tag functions)
3. `stage-defs.sh` (declarative cross-lane stage graph)
4. `digest-pinning.sh` (registry digest resolution)
5. `chain-verify.sh` (cross-chain staleness verification + describe)
6. `build-helpers.sh` (nerdctl wrappers, build-arg helpers)
7. `cross-stage-build.sh` (cross-stage build orchestration: build, push, pin; includes `cross_stage_build_local()` for non-push builds)
8. `context-management.sh` (runtime context, OCI export, stage handoff)
9. `version-forwarding.sh` (auto-discovered --build-arg forwarding)
10. `cli-parsers.sh` (shared CLI argument parsing)
11. `runtime-build-fns.sh` (per-arch build chain functions)
12. `compiler-resolution.sh` (host compiler resolution for media builds)
13. `parallel-loop.sh` (per-architecture parallel build loop)

Additionally, `runtime-flow-common.sh` provides `init_runtime_flow_defaults()` — it is sourced directly by `build-runtime-artifacts.sh` and `build-runtime-manifest.sh` (after `artifact-common.sh`) to avoid polluting the broader sourcing chain.

---

## Linux Build Rules

- Use `nerdctl` first on this host. `buildctl` and `ctr` commonly fail here with permission errors.
- Keep both the QEMU/binfmt multi-platform lane and the cross-build lane working. Do not break one to fix the other.
- `linux/scripts/build-cross-compiler.sh` builds one `linux/amd64` compiler image that contains cross toolchains for `amd64`, `arm64`, and `riscv64`. It is not a multi-arch compiler manifest.
- Do not remove LLVM/Clang features just to make foreign-arch builds pass. Foreign-architecture runtime images must keep source-built `clang 22.1.6` and must not fall back to the Ubuntu `clang 22.1.2` packages. The source-built `gcc 16.1.0` at `/opt/gcc-16.1.0` is the default system `cc`/`c++` compiler on all architectures. On `amd64`, GCC is built natively. On `arm64` and `riscv64`, GCC is cross-compiled from source (Canadian cross) using the cross-compiler built in the same toolchain image; the resulting native GCC is swapped into `/opt/gcc-16.1.0` at the end of the Android stage via `Dockerfile.android`.
- Preserve the optional runtime payloads and LLVM normalization in `linux/Dockerfile.package`. Do not silently drop the `/usr/local/lib/onnxruntime-*` (includes `onnxruntime-cpu`, `onnxruntime-gpu`, `onnxruntime-genai`), LiteRT/TensorFlow headers, pkg-config files, or `/usr/local/llvm-target` handling.

---

## Cross Chain Stage Handoff (do not regress)

The cross lane is a sequence of separate `nerdctl build` invocations where each
stage's next stage does `FROM ${BASE_IMAGE}`: `base -> compiler -> sdk -> media
-> android -> package -> torch -> wrapper -> manifest`. The base-image handoff
between these stages MUST NOT rely on a bare mutable tag, or a stage can silently
consume a STALE locally-cached image instead of the one just built. Concretely:
`--output type=image,name=...,push=true` pushes the new digest to the registry
but does not reliably refresh the local containerd tag, and BuildKit's default
`FROM` resolution prefers an already-present local image (it does not re-pull).
So rebuilding `media` then building `android` can quietly reuse the old `media`.

### Stale-base propagation across orchestrator invocations (critical)

For a detailed walkthrough of how this manifests, see `docs/linux-cross-builds.md`
§ "Trap: stale-base propagation across orchestrator invocations".

Rules:

1. **Whenever ANY base image in the registry tag hierarchy is replaced,** you MUST
   either (a) rebuild every downstream image starting from the replaced stage, or
   (b) explicitly verify that the downstream images were already rebuilt from the
   new base by checking they contain the new content (e.g. verify
   `/opt/gcc-16.1.0-native-arm64` exists in the pinned sdk digest).
2. **The `--from-stage` flag only controls where execution starts; it does NOT
   update the base image of the first stage it runs.** If the existing registry
   tag for the stage BEFORE your `--from-stage` was built from a stale upstream,
   your rebuild inherits that staleness.
3. **After pushing a rebuilt compiler image**, run the orchestrator from
   `--from-stage sdk` (not `media`) so the sdk is built from the new compiler
   before media inherits it.
4. **Do NOT use `--from-stage android`** unless you have verified the media tag
   already contains the content the compiler provides (e.g., the native GCC
   directories).
5. To run the full cross chain, prefer the orchestrator `linux/scripts/build-cross-chain.sh`.
   It captures each cross stage's registry-resolvable manifest digest after push and
   feeds it to the next stage as `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`,
   so stale reuse is structurally impossible. It supports `--target-arches`,
   `--from-stage`, `--to-stage`, and `--only` for partial/per-arch runs.
6. When you must drive the manual `nerdctl` cross loops instead, pass `--pull=true`
   on every stage that consumes a `BASE_IMAGE` tag so it re-pulls the freshly
   pushed base. This is the weaker defense; digest pinning is preferred.
7. Capture pinnable digests with `nerdctl manifest inspect --verbose <tag>` ->
   `.Descriptor.digest` (the `registry_pin_ref` helper in
   `linux/scripts/01-core/digest-pinning.sh`). Do NOT use the local image store's
   `RepoDigests`: on this host BuildKit pushes a converted `docker.v2+json`
   manifest whose digest differs from the local OCI manifest, so `RepoDigests` is
   not registry-resolvable and will fail to pin.

---

## Verified Runtime Packaging Path On This Host

- Prefer helper scripts over ad hoc `nerdctl build` sequences (see Quick Reference above).
- The runtime helpers accept `--target-arches`, `TARGET_ARCHES`, and `TARGET_ARCH` for architecture selection.
- For local foreign-architecture runtime rebuilds, prefer saved OCI layouts under `out/local-oci/android/<arch>`.
- When reusing saved local artifacts, use:
  - `ARTIFACT_CONTEXT_ROOT="$PWD/out/local-oci/android"`
  - `ARTIFACT_CONTEXT_MODE=oci`
  - `RUNTIME_CONTEXT_ROOT="$PWD/out/local-oci/runtime-contexts"`
- The working host workaround is mixed context types: keep `runtime_artifact` as an `oci-layout://...` build context and keep `runtime_base` as a plain rootfs directory context. Do not switch both named contexts to OCI in one build on this host.
- The repo-root `.dockerignore` excludes `out/local-oci`, `out/local-android-dir`, `out/linux-sdk`, `out/linux-runtime`, and `out/runtime-repair-*` so large exported artifacts do not get sent back as later Docker build contexts.
- Prefer the saved OCI layouts over the plain directory exports in `out/local-android-dir/<arch>`. The plain directory path is much larger and previously dropped runtime payload during OCI-to-directory conversion.

---

## Five Critical Fixes To Maintain

Always preserve these five vital fixes to prevent build/runtime regressions.
See `docs/linux-cross-builds.md` § "Five Critical Fixes" for full implementation details.

1. **gst-python staged libpython** — `rewrite_staged_python_pc()` in `build_python.sh`
2. **libcamera abseil** — copy `absl/types/span.h` in `build-litert.sh`
3. **cross lib-dynload dangling symlinks** — `cp -a -L` + `find -xtype l` guard in `build_python.sh`
4. **cross GCC architecture guard** — three-layer ELF + dumpmachine + cc1 smoke check in `Dockerfile.package`
5. **OpenCV 5 GStreamer compat** — `patch_gstreamer_opencv5_compat()` in `patch-gstreamer-sources.sh`

---

## Push And Publish Rules

- For the runtime helpers, `build-runtime-artifacts.sh --push` should push only the final per-architecture wrapper images.
- `build-runtime-manifest.sh --push` should push those final wrapper images plus the final manifest.
- Use `--push-all` only when the user explicitly wants the `base` and `package` intermediates published too.
- Final cross release target: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.
- Before rebuilding expensive foreign-architecture wrappers, inspect the remote tags with `nerdctl manifest inspect`. If the per-architecture wrapper images already exist remotely, recreate the final manifest directly instead of rebuilding them.

---

## Development Rules

### Where New Base Images Belong

- OS-level changes go in `Dockerfile.base` (Ubuntu version, system packages, CMake, Node, uv).
- Compiler/toolchain changes go in `Dockerfile.toolchain` (GCC, LLVM/Clang, Rust, Python interpreter).
- SDK/framework changes go in `Dockerfile.sdk` (Vulkan SDK, TVM).
- Media library changes go in `Dockerfile.media` (ONNX Runtime, LiteRT, OpenCV, GStreamer, libcamera).
- Android platform changes go in `Dockerfile.android` (SDK, NDK, native GCC swap).
- GPU accelerator layers go in `Dockerfile.nvidia` or `Dockerfile.amd`.

### Where New Toolchains Belong

Scripts under `linux/scripts/02-toolchain/` build the compiler toolchain:
- `build-gcc.sh` / `gcc.sh` — GCC from source
- `build-clang.sh` / `llvm.sh` — LLVM/Clang from source
- `install-rust.sh` — Rust toolchain
- `vulkan.sh` — Vulkan SDK setup
- `cmake.sh` — CMake bootstrap
- `bootstrap.sh` — initial build dependencies

### How New Architectures Are Added

1. Add the architecture to `CROSS_DEFAULT_ARCHES` in `versions.env`
2. Update cross-target lists in `build-cross-compiler.sh` and `build-cross-chain.sh` defaults
3. Add cross-compilation triple mappings in `platform.sh` (`canonical_target_arch()`)
4. Add arch-specific download checksums in `versions.env` (Node, uv)
5. Verify QEMU/binfmt support for the new architecture
6. Update `TARGET_ARCHES` defaults in orchestrator `CROSS_DEFAULT_ARCHES` (all scripts use `resolve_arch_list()` for centralized resolution)

### How Tags Should Be Generated

- Use the centralized tag functions in `tag-naming.sh` — never construct tags manually.
- Cross lane: `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag() <arch>`, `cross_media_tag() <arch>`, `cross_android_tag() <arch>`
- Runtime lane: `runtime_base_tag() <arch>`, `runtime_package_tag() <arch>`, `runtime_wrapper_tag() <arch>`
- To change the registry prefix, set `IMAGE_REPO` or `IMAGE_REGISTRY_PREFIX`.
- All scripts that build images accept `--image-repo` to override the default registry prefix.

### How Scripts Should Be Structured

- Every script must start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Use `run()` from `build-helpers.sh` for echoing and executing commands. Use `run_quiet()` for secret-bearing args.
- Use `nerdctl` build wrappers: `run_nerdctl_build()` with `BUILDKIT_HOST` support, `pull_platform_image()`.
- Source `artifact-common.sh` for access to all shared utilities (tag naming, digest pinning, build helpers, CLI parsing, runtime functions).
- For orchestrator scripts, use the dispatch pattern with `parse_shared_orchestrator_args()` or `parse_shared_runtime_args()`.
- Call `cross_stage_init_pins()` once before the build loop to declare all digest-pin variables from the stage graph.
- Mirror configuration goes through `append_mirror_build_args_from_env()`.
- Version forwarding goes through `append_version_build_args()`.
- Architecture normalization goes through `normalize_target_arches()`.
- Use `resolve_arch_list()` (in `artifact-common.sh`) instead of writing `TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${ARCHITECTURES:-${CROSS_DEFAULT_ARCHES}}}}"` chains.
- Use `is_dry_run()` (in `build-helpers.sh`) instead of `[ "${DRY_RUN:-0}" -eq 1 ]`.

---

## Maintenance Rules

### Dependency Update Procedure

1. Update version numbers in `linux/scripts/01-core/versions.env` (single source of truth)
2. Run `python3 docs/scripts/sync_versions.py --check`; if drift, run `--write`
3. Update `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, `docs/project-info.md`, and `AGENTS.md`
4. Verify version references in Dockerfile ARG defaults match (they are safety nets only)
5. Run `linux/scripts/01-core/verify-arg-consistency.sh` to check ARG consistency
6. Rebuild the affected stages of the cross chain:
   - **Base tooling** (CMake, Node, uv) → rebuild from `base`
   - **Compiler toolchain** (GCC, LLVM, Python) → rebuild from `compiler`, then `--from-stage sdk`
   - **Media libraries** (ONNX, LiteRT, OpenCV, GStreamer) → rebuild from `media`
   - **Android** (SDK, NDK) → rebuild from `android`

### Image Deprecation Procedure

- Cross-lane intermediates (`:cross-sdk-*`, `:cross-media-*`, `:cross-android-*`) are ephemeral — each new full build replaces them.
- Runtime intermediates (`:latest-cross-base-*`, `:latest-cross-package-*`) are internal — only pushed with `--push-all`.
- The public `:latest-cross` manifest and its per-arch wrappers are the stable API.
- Old versions are cleaned by the `ghcr-cleanup` GitHub Action (keeps last 3 per tag, 14-day safety net).

### Release Procedure

1. Run `bash linux/scripts/build-cross-chain.sh --verify-chain` to check freshness
2. Run `bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64` to build and publish
3. Run `python3 docs/scripts/sync_versions.py --check` to verify docs are in sync
4. Validate with `wrapper-smoke` target (see `docs/linux-build-basics.md`)
5. Update `CHANGELOG.md`

---

## Validation

- For runtime verification, check inside a container or inspect raw symlink targets. Do not use `readlink -f` against `out/linux-runtime/*/rootfs`, because absolute symlinks resolve against the host root.
- Confirm all of the following for runtime image validation:
  - `clang --version` reports `<!-- generated:llvm -->22.1.6<!-- /generated:llvm -->` on all architectures
  - the reported target triple matches the architecture (`cc -dumpmachine`)
  - On all architectures: `gcc --version` reports `<!-- generated:gcc -->16.1.0<!-- /generated:gcc -->`, and:
    - `/usr/bin/cc -> /etc/alternatives/cc -> /opt/gcc-<!-- generated:gcc -->16.1.0<!-- /generated:gcc -->/bin/gcc`
    - `/usr/bin/c++ -> /etc/alternatives/c++ -> /opt/gcc-<!-- generated:gcc -->16.1.0<!-- /generated:gcc -->/bin/g++`
    - `/usr/bin/gcc -> /etc/alternatives/gcc -> /opt/gcc-<!-- generated:gcc -->16.1.0<!-- /generated:gcc -->/bin/gcc`
    - `/usr/bin/g++ -> /etc/alternatives/g++ -> /opt/gcc-<!-- generated:gcc -->16.1.0<!-- /generated:gcc -->/bin/g++`
  - `/usr/bin/clang -> /etc/alternatives/clang -> /usr/local/llvm-target/bin/clang`
  - the optional runtime payloads are still present
  - See `validate-compilers.sh` for the shared `_validate_cc_target()` used by both the `package` hard-fail and `smoke` modes.
- Use the `wrapper-smoke` target (documented in `docs/linux-build-basics.md` and `docs/linux-cross-builds.md`) for cheaper packaging validation before large publish runs.
- Current automated validation is documentation-focused. Do not claim there is already a single full end-to-end CI workflow.

---

## Host Constraints

- QEMU/binfmt works for `arm64` and `riscv64` on this host. It may need to be reinstalled after a host reboot. If foreign-architecture builds (or even simple `nerdctl run --platform linux/arm64 alpine uname -m`) fail with `exec format error`, run `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` in a terminal first before resuming the agentic session.
- Plain local image tags such as `docker.io/library/opencode-local:*` may be treated like remote registry references here. Do not rely on them as reusable `FROM` sources for the runtime packaging chain.
- Disk pressure is common during runtime rebuilds. When free space is tight, build and push one architecture at a time. To free space: `nerdctl system prune -a -f && rm -rf out/local-* out/linux-*`.
- `gh` may be unavailable on this host. Use `nerdctl` and regular git commands unless GitHub CLI is actually installed.
- Rootless BuildKit on this host is already tuned for fast build-time downloads. Do not regress these settings. Full details in `docs/project-info.md`.

### Common Failure Modes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `exec format error` | QEMU/binfmt not registered after host reboot | `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` |
| `no space left on device` | Disk full from cached images/artifacts | `nerdctl system prune -a -f && rm -rf out/local-*` |
| Stale downstream images | Base image rebuilt but downstream not refreshed | Use `--verify-chain` or rebuild from replaced stage |
| `registry_pin_ref` fails on fresh push | Registry hasn't propagated the new manifest | Now uses `retry()` with 5 attempts; wait a few seconds and retry |
| Terminal freeze during long build | Build output overwhelms terminal | Use `setsid` / `disown` for very long builds |
| nerdctl DNS failure in build | BuildKit container can't resolve hostnames on Windows (`--dns` and `--network host` unsupported) | Use Stevedore's bundled `"%ProgramFiles%\Stevedore\bin\docker.exe" build` instead — same containerd backend, working DNS. `nerdctl run` works fine for running containers. |

---

## Version Bumping

### Centralized Version File

**The single source of truth for ALL versions is `linux/scripts/01-core/versions.env`.** Update it first, then verify the downstream consumers are in sync.

`common.sh` and `artifact-common.sh` both source `versions.env` at load time with `set -a`, so all build scripts automatically receive the canonical values. Orchestrator scripts inherit versions through `artifact-common.sh`. The old per-Dockerfile ARG defaults are kept as safety nets and should match `versions.env`.

### Version Map

| Software | Where defined |
|----------|---------------|
| **All Linux versions** | `linux/scripts/01-core/versions.env` (canonical) |
| **BuildKit syntax** | `# syntax=docker/dockerfile:1.24.0` line 1 in every `linux/Dockerfile.*` |
| **LLVM/Clang** | `versions.env` -> `Dockerfile.toolchain`, `Dockerfile.sdk`, `Dockerfile.package` |
| **GCC** | `versions.env` -> `Dockerfile.toolchain`, `Dockerfile.android`, `Dockerfile.package` |
| **Python** | `versions.env` -> `Dockerfile.toolchain`, `Dockerfile.package` |
| **CMake** | `versions.env` -> `Dockerfile.base` |
| **Node.js** | `versions.env` -> `Dockerfile.base` |
| **uv** | `versions.env` -> `Dockerfile.base` |
| **Vulkan SDK** | `versions.env` -> `Dockerfile.base`, `Dockerfile.sdk` |
| **ONNX Runtime** | `versions.env` -> `Dockerfile.media` |
| **ONNX Runtime GenAI** | `versions.env` -> `Dockerfile.media` |
| **LiteRT** | `versions.env` -> `Dockerfile.media` |
| **OpenCV** | `versions.env` -> `Dockerfile.media` |
| **GStreamer** | `versions.env` -> `Dockerfile.media`, `Dockerfile.package` |
| **CUDA** | `versions.env` -> `Dockerfile.nvidia` |
| **cuDNN** | `versions.env` -> `Dockerfile.nvidia` |
| **TensorRT** | `versions.env` -> `Dockerfile.nvidia` |
| **ROCm** | `versions.env` -> `Dockerfile.amd` |
| **Apache TVM** | `Dockerfile.sdk` only (ARG TVM_REF) |
| **Android SDK** | `versions.env` -> `Dockerfile.android`, `Dockerfile.package` |
| **Android NDK** | `versions.env` -> `Dockerfile.android`, `Dockerfile.package` |
| **Android Build Tools** | `versions.env` -> `Dockerfile.android`, `Dockerfile.package` |
| **Android CMake** | `versions.env` -> `Dockerfile.android`, `Dockerfile.package` |
| **Android SDK/API** | `versions.env` -> `Dockerfile.android`, `Dockerfile.package` |
| **Ubuntu** | `FROM ubuntu:...` in `Dockerfile.base` and `webserver/Dockerfile` |
| **Webserver Ubuntu** | `FROM ubuntu:...` in `linux/webserver/Dockerfile` |

### Version Verification Sources

Check these URLs for the latest versions:
- LLVM/Clang: `https://github.com/llvm/llvm-project/releases`
- Python: `https://www.python.org/downloads/`
- Node.js: `https://nodejs.org/en/download`
- CMake: `https://cmake.org/download/`
- uv: `https://github.com/astral-sh/uv/releases`
- Vulkan SDK: `https://vulkan.lunarg.com/sdk/home`
- ONNX Runtime: `https://github.com/microsoft/onnxruntime/releases`
- ONNX Runtime GenAI: `https://github.com/microsoft/onnxruntime-genai/releases`
- LiteRT: `https://github.com/google-ai-edge/LiteRT/releases`
- GStreamer: `https://gstreamer.freedesktop.org/releases/`
- CUDA: `https://developer.nvidia.com/cuda-toolkit-archive`
- ROCm: `https://repo.radeon.com/rocm/apt/` (browse directory listing)
- TVM: `https://github.com/apache/tvm/releases`
- Android SDK/NDK: `https://developer.android.com/studio#command-line-tools-only`
- Docker BuildKit: `https://github.com/moby/buildkit/releases`

### Post-Bump Steps

After changing any versions:
1. Run `python3 docs/scripts/sync_versions.py --check`. If it reports drift, run `--write`.
2. Update version references in `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, `docs/project-info.md`, and `AGENTS.md`.
3. Update cross-file consistency: several versions appear in multiple Dockerfiles (e.g., GCC, Python, Android SDK, Vulkan, GStreamer). Make sure they stay in sync.

### GPU Version Constraints

When bumping CUDA or ROCm, verify:
- CUDA: minimum driver requirement (check NVIDIA release notes)
- ROCm: the `UBUNTU_CODENAME` ARG in `Dockerfile.amd` must match a supported Ubuntu codename for that ROCm version. Default is `plucky` (26.04). The same codename variable is used in `Dockerfile.nvidia` for the CUDA keyring URL.
- Both: confirm the repo URL format (`repo.radeon.com/rocm/apt/${ROCM_VERSION}`) is still valid

---

## Documentation Maintenance

- If Dockerfiles or Linux build helpers change, update these docs in the same commit:
  - `docs/linux-cross-builds.md`
  - `docs/linux-build-basics.md`
  - `docs/project-info.md`
- If Windows Dockerfiles or scripts change, update `docs/windows-builds.md`.
- If source-controlled version defaults change, run `python3 docs/scripts/sync_versions.py --write`.
- For verification-only checks, run `python3 docs/scripts/sync_versions.py --check`.
