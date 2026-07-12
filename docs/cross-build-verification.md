# Cross-build verification & failure-class catalog

This document catalogs the classes of failure hit during the base→`:latest-cross`
rebuild campaigns and maps each to the fast check that catches it *before* a
multi-hour QEMU build. It is the reference for the pre-flight verification
workflow (see "Pre-flight" below).

The guiding principle: **every error we debugged interactively should become a
check that fails in seconds, not after a 30–60 min emulated build.**

## Failure classes (from build history)

| # | Class | Representative bug(s) | Fix commit(s) | Caught early by |
|---|-------|----------------------|---------------|-----------------|
| 1 | Script not COPY'd into a stage → sourced fn missing at runtime (`command not found`, exit 127) | `media_load_arch_flags` not found (03-media/core never COPY'd into Dockerfile.package) | `da41e19` | **sourced-scripts-present** static check (`verify-script-copy-coverage.py`) |
| 2 | Relocated native GCC/G++ can't find `/usr/include` for source builds under QEMU — C *and* C++ (`#include_next`) | `string.h: No such file` (Pillow); `<cstdlib>`→`stdlib.h: No such` (numpy) | `3c623fa`, `349e32b`, `dc93d11` | **compile smoke test** (C + C++ `#include_next` + `jpeglib.h`) in `validate-compilers.sh` |
| 3 | Missing dev headers for QEMU source builds | `jpeglib.h` missing for Pillow (`libjpeg-dev`) | `3c623fa` | same compile smoke test (header presence probe) |
| 4 | Cross toolchain artifact wrong-arch / not runnable on host | `/opt/llvm-target` clobbered by shared compiler; non-runnable `llvm-config`; missing target linker | `8e66c5f`, `fb634a3`, `b1dd72e`, `312a4d8` | **`validate-compilers.sh`** per-arch ELF/machine check (build-time) **+ compile+link+RUN under qemu** in `smoke-runtime-image.sh` (`bcbd19d`) |
| 5 | venv/wheel install collision & bad seeding | apt numpy seeded into venv without dist-info → uv install `File exists` | `9f07334` | **torch-venv integrity** smoke (`smoke-torch-venv.sh`) |
| 6 | Undefined/typo'd bash function or quoting bug | `tvm-detect` undefined; verify-parity venv quoting | (dedup passes) | **shellcheck gate** (`-S error`) in pre-commit |
| 7 | Include-flag construction bugs | bare `-I -I -I` broke Abseil C++17 probe; missing pybind11/numpy include dirs | `ab3776b`, `5412ec4` | shellcheck + compile smoke test |
| 8 | Dockerfile ARG / mirror / cache drift | apt not `-y`; cache-to 400; ARG≠versions.env | `bf49676`, `4f27634` | `verify-arg-consistency.sh`, `verify-ubuntu-mirror-consistency.sh` (exist) |

## Existing infrastructure (reuse, don't duplicate)

- **Shared helper for class 2/3:** `01-core/common.sh` → `append_cross_idirafter <triplet>`
  already appends `-idirafter /usr/include{,/<triplet>}` to `CPPFLAGS/CFLAGS/CXXFLAGS`.
  Used by `build-libcamera.sh`, `build-gstreamer-monorepo.sh`. (The torch-venv fix
  should adopt this — see task #16.)
- **Compiler validation (class 4):** `06-packaging/validate-compilers.sh` emits
  `ARTIFACT COMPILER VERIFICATION PASSED for <arch>`; validates GCC 16.1.0 + Clang
  22.1.8 chain and per-arch ELF machine type. Extend here for the compile smoke test.
- **Smoke framework:** `06-packaging/smoke-common.sh` (`pass`/`fail`/`FAILURES`);
  smoke tests are `06-packaging/smoke-<thing>.sh` and `source smoke-common.sh`.
- **Static host verifiers wired into `.githooks/pre-commit`:** `verify-critical-fixes.sh`,
  `01-core/verify-arg-consistency.sh`, `sync_versions.py --check`, `bash -n`. The hook is
  the home for the new shellcheck gate and the sourced-scripts-present check.

## Pre-flight

Run **`linux/scripts/preflight.sh`** before `build-cross-chain.sh`. It runs every
fast (no-build) check in seconds/minutes so whole failure classes are caught
before a multi-hour QEMU rebuild. All checks run even if one fails; the script
exits non-zero if any did.

| Check | Script | Catches (class) |
|-------|--------|-----------------|
| shellcheck gate | `lint-shell.sh` | 6, 7 |
| script COPY coverage | `verify-script-copy-coverage.py` | 1 |
| critical fixes (incl. fix6) | `verify-critical-fixes.sh` | 2, 3 (+ prior fixes) |
| ARG consistency | `01-core/verify-arg-consistency.sh` | 8 |
| version snapshot | `docs/scripts/sync_versions.py --check` | 8 |
| ubuntu mirror consistency | `01-core/verify-ubuntu-mirror-consistency.sh` | 8 |
| runtime path consistency | `04-runtime/verify-runtime-paths.sh` | 8 |

Each is runnable standalone (same commands). The pre-commit hook
(`.githooks/pre-commit`) runs the shellcheck gate (staged files), script COPY
coverage, and critical-fixes checks on every commit.

### In-image smoke tests (need a built image, not part of preflight)

These validate a built/pulled image and also run during the build to fail fast:

- **Native source-build header preflight** — inside `setup-torch-venv.sh`
  (`verify_native_source_headers`): compiles tiny C / C++ / jpeglib probes with
  the same compiler+flags the pip build uses, so a header/sysroot regression
  (classes 2/3) aborts in <1s instead of after a ~9-min numpy/pillow compile.
- **Torch venv integrity** — `06-packaging/smoke-torch-venv.sh`: imports
  numpy/torch/torchvision/PIL/cv2/contourpy (+ torch↔numpy ABI bridge) from
  `/opt/venv` (class 5). Wired into `smoke-wrapper.sh`; skips cleanly if no venv.
  Run standalone: `VENV=/opt/venv smoke-torch-venv.sh`.
- **Runtime-image boot + functional smoke** — `06-packaging/smoke-runtime-image.sh
  <image> <arch>`, run per-arch by `build-runtime-manifest.sh` against the freshly
  built wrapper. Boots the actual published image and, under **binfmt/qemu for the
  cross arches**, runs real workloads *on-target*:
  - ML imports (`onnxruntime`, `numpy`, `torch`) + `ffmpeg -version` (pipefail-guarded
    so a missing `.so` can't pass silently); torch-less sentinel flagged.
  - **Native `/opt` `.so`-closure gate** — `ldd` over the ffmpeg/opencv5/libcamera/
    vulkan payload; any unresolved soname fails the gate. Generalises the ffmpeg
    check to the whole native stack (the class that shipped libopencore-amrwb.so.0-
    broken ffmpeg). Venv Python extensions are excluded (import-time lib paths defeat
    bare `ldd`; the import checks are their gate).
  - **GStreamer plugin health** (warn) — lists plugins whose runtime `.so` is absent
    (they degrade gracefully); surfaces app-critical regressions like
    `webrtcbin2`→`librice-proto.so.0`. **GStreamer core pipeline** (fail) —
    `videotestsrc ! videoconvert ! fakesink`.
  - **onnxruntime inference** (fail) — runs a tiny embedded Add model and asserts the
    output (proves the CPU EP executes, not just imports). **cv2 encode/decode**
    roundtrip. **Application import** — the shipped venv must `import orchestr_ant_ion`.
  - **Native compiler battery compile+link+RUN** — an 8-case battery with the image's
    `gcc`/`g++`, each running the resulting binary on-target: C hello (stdout),
    pthreads, libm, libatomic; C++ hello (libstdc++), **exceptions+STL** (throw/catch +
    `std::sort`), std::thread, and `-flto`. This is what upgrades class 4 from a static
    ELF/machine check to genuine **execution** proof: a cross arch's binary can't run
    on the x86_64 build host, so the shipped native GCC (esp. the riscv64
    `--with-isa-spec` toolchain) was previously never actually executed — under qemu
    here it is. The **exceptions+STL** case is the regression guard for the
    `swap-native-gcc.sh` **wrapper** fix (`c46da5f`): the compiler reaches the runtime
    image's system headers via command-line `-idirafter` wrappers, *not* an installed
    `specs` file — a specs file silently drops `-lgcc_s`/`--eh-frame-hdr` and makes
    every throwing C++ program terminate at runtime. Gate `RUNTIME_COMPILER_SMOKE=0` to skip just this;
    `RUNTIME_FUNCTIONAL_SMOKE=0` skips all functional checks; `RUNTIME_IMAGE_SMOKE=0`
    (in `build-runtime-manifest.sh`) skips the whole runtime-image smoke (e.g. a host
    without a qemu handler for a foreign arch).

### Foreign-arch execution needs QEMU binfmt — registered **without sudo**

The foreign-arch smokes above only mean something if the image's binaries can
actually *execute* on the build host. That requires a `binfmt_misc` QEMU handler.
**`build-runtime-manifest.sh` registers it automatically, with no sudo**, before the
smoke loop (`ensure_foreign_binfmt` → `linux/scripts/setup-rootless-binfmt.sh`).
Opt out with `RUNTIME_REGISTER_BINFMT=0` (e.g. a rootful/CI host where qemu is
already registered via `docker run --privileged tonistiigi/binfmt` or
`update-binfmts`).

Two dead-ends to know about, because both *look* like they work and don't:

- **`nerdctl run --privileged tonistiigi/binfmt --install …` (rootless)** registers
  binfmt inside the throwaway container's own user namespace, which `--rm` destroys.
  It prints "arch OK" but never reaches the namespace where builds/runs happen.
- **BuildKit's embedded `/dev/.buildkit_qemu_emulator`** only wraps the *top-level*
  process of a `RUN`. The shell starts, but its first *child* exec
  (`uname`, `mktemp`, `gcc`, `python`, `ffmpeg`) dies with **`Exec format error`** —
  so it cannot run any real multi-process smoke.

`setup-rootless-binfmt.sh` is the working no-sudo path on a rootless
containerd/BuildKit host: buildkitd runs `nsenter`'d into containerd's rootlesskit
namespace, so `nerdctl run` and `nerdctl build` **share one persistent namespace**.
The script extracts the static `qemu-<arch>` emulators from `tonistiigi/binfmt`,
enters that shared namespace via `containerd-rootless-setuptool.sh nsenter` (where
the mapped uid-0 *does* hold `CAP_SYS_ADMIN` over its own mounts — no host sudo), and
registers each with flags **`POCF`**. The **`F` (fix-binary)** flag is the crux: the
kernel opens the interpreter fd at registration time, so emulation is inherited into
the nested build/run namespaces where the qemu path isn't even mounted — which is
exactly what makes *child* execs work. Register once per boot (or install the
`systemd --user` unit with `--install-service`); verify with `--verify`.

## Dedup & factoring notes (2026-07)

The tree has been through several dedup passes already; remaining duplication is
largely **deliberate** and should not be "fixed":

- `cross_build_is_active` / `install_host_packages` etc. are re-defined as
  **fallbacks** in several modules so each can be sourced standalone. Removing
  them breaks isolated use.
- `build-libcamera.sh`'s inline `-idirafter /usr/include` (generic) plus its
  `append_cross_idirafter` call is a **native/cross fallback pair**, not a copy.
- The `-idirafter` logic in `setup-torch-venv.sh` + `swap-native-gcc.sh`
  duplicates the canonical helper `append_cross_idirafter` (`01-core/common.sh`).
  It is **inlined on purpose**: the torch/android stages do not COPY `common.sh`
  (nor its `load-versions-env.sh` chain), and pulling that in for six flag lines
  is not worth the surface on a verified critical path. The copies are
  cross-referenced to the helper and kept in sync by `verify-critical-fixes.sh`
  **fix6** — the pattern for necessary duplication: guard it, don't hide it.

## Hardening pass (2026-07) — landed + residuals

**Landed** (see `verify-critical-fixes.sh` **fix7** for the regression guards):

- **Build cache** — replaced the self-defeating registry `-buildcache` (whose
  `--cache-to` was gated out by `NO_CACHE_EXPORT`, so nothing ever cache-hit)
  with a **local** buildkit cache + inline cache on push. This is why full base
  rebuilds no longer recur on the same host.
- **Base cache scope** — base RUNs bind-mount only `01-core` (+ `02-toolchain`
  for shared tooling), so editing a media/android script no longer busts the
  base image.
- **Supply-chain** — the sole floating external base (`ubuntu:26.04`) is now
  digest-pinned by its multi-arch manifest-**list** digest (`UBUNTU_DIGEST`).
- **Non-root runtime** — `/workspace` is `chown`ed to `kataglyphis`;
  `PYTHONDONTWRITEBYTECODE=1`; the build-only fake `sudo` shim is stripped from
  the shipped image.
- **Robustness** — image-wide `apt` retries (`80-retries`); real-pipe +
  `PIPESTATUS` so a failing build's log tail is flushed and its true exit code
  returned; `parallel-loop.sh` names the failed arch.
- **Smokes** — every previously-orphaned smoke now runs: `smoke-toolchain`
  (toolchain), `smoke-vulkan`+`smoke-android` (android), `smoke-vulkan`+
  `smoke-torch-venv` (package wrapper-smoke), and host-side `smoke-runtime-image`
  (in `build-runtime-manifest.sh`, `RUNTIME_IMAGE_SMOKE=0` to skip).
- **Reproducibility (opt-in)** — `clone_or_update_repo` and `build-ffmpeg.sh`
  accept a 40-hex commit SHA; `OPENCV_COMMIT`/`OPENCV_CONTRIB_COMMIT`/
  `FFMPEG_COMMIT` (empty by default = track the bleeding-edge branch) freeze
  those sources to an immutable commit for a release build.
- **Attestations (opt-in)** — `BUILD_ATTEST=1` attaches SLSA provenance + SBOM
  to pushed images.

**Residual supply-chain gaps** (tracked, not yet closed — each is a known
`curl`/`wget` without a checksum; the fix is to route it through
`download_verified_file` with a new `*_SHA256` in `versions.env`):

| Source | Site | Note |
|--------|------|------|
| Flutter SDK tarball | `flutter/setup-flutter.sh` | per-arch sha; large |
| Android cmdline-tools zip | `android-sdk.sh` | NDK/build-tools are sdkmanager-verified |
| freetype source | `opencv/install-deps.sh` | swallows failure with `\|\| true` — tighten too |
| GStreamer-Android universal | `android/build-gstreamer.sh` | published sha256 available |
| `rustup-init` / NodeSource | `install-rust.sh`, `onnxruntime/build/10-deps.sh` | `curl \| sh` — pin the bootstrap binary by sha |

**Deliberate keep:** the `-dev` header packages in `setup-torch-venv.sh` land in
the final image. This is a cross-**dev** container that compiles Python wheels
from source under QEMU at build time, so the headers are load-bearing; splitting
build-deps from runtime-deps would risk the source-build path for marginal size
savings. Left as-is by design.
