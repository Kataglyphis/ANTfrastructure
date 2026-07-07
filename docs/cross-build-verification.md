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

_(populated by task #17 once the checks land)_ — a single entrypoint that runs all the
fast checks (shellcheck gate, script-copy coverage, arg/mirror consistency) in seconds so
whole failure classes are caught before committing to a multi-hour cross rebuild.
