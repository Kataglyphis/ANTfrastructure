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
| 1 | Script not COPY'd into a stage → sourced fn missing at runtime (`command not found`, exit 127) | `media_load_arch_flags` not found (03-media/core never COPY'd into Dockerfile.package) | `da41e19` | **sourced-scripts-present** static check (`verify-script-copy-coverage.sh`) |
| 2 | Relocated native GCC/G++ can't find `/usr/include` for source builds under QEMU — C *and* C++ (`#include_next`) | `string.h: No such file` (Pillow); `<cstdlib>`→`stdlib.h: No such` (numpy) | `3c623fa`, `349e32b`, `dc93d11` | **compile smoke test** (C + C++ `#include_next` + `jpeglib.h`) in `validate-compilers.sh` |
| 3 | Missing dev headers for QEMU source builds | `jpeglib.h` missing for Pillow (`libjpeg-dev`) | `3c623fa` | same compile smoke test (header presence probe) |
| 4 | Cross toolchain artifact wrong-arch / not runnable on host | `/opt/llvm-target` clobbered by shared compiler; non-runnable `llvm-config`; missing target linker | `8e66c5f`, `fb634a3`, `b1dd72e`, `312a4d8` | **`validate-compilers.sh`** per-arch ELF/machine check (exists) |
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
