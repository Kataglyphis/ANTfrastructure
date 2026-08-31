<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# GEN1 — onnxruntime-genai on riscv64

The riscv64 cross lane builds `onnxruntime-genai` **from source**. Nobody else
does: upstream ships no riscv64 wheel in any version, runs no riscv64 CI (a
full-tree grep of v0.15.2 finds zero `riscv` matches), and
closed its one RISC-V field report as not-planned. This page is the engineering
reference for that lane — what was changed, what each gate proves, and what to
watch when the first real `media-riscv64` build finally runs it.

> **See also** — this page is the *how it works*. The other two halves:
> [`refactoring-backlog.md`](refactoring-backlog.md) (item A1) is the open
> **validation watch**;
> [`refactoring-backlog-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md)
> and [`../CHANGELOG.md`](../CHANGELOG.md) (2026-08-31 closure window) are the
> **history**. The one-screen summary lives in
> [`linux-cross-builds.md`](linux-cross-builds.md#onnxruntime-genai-on-riscv64-gen1-2026-08-31).

## Status: WIRED, UNVALIDATED

Wired ON 2026-08-31 by explicit user decision. **No riscv64 container build has
ever run this code.** Everything below that is not marked MEASURED is a
source-read conclusion. In particular, neither of these is proven:

* that the genai stage **compiles** under the GCC 16 riscv64 cross;
* that `generate()` produces **sane tokens**.

The second one has a live negative data point.
[onnxruntime-genai#594](https://github.com/microsoft/onnxruntime-genai/issues/594)
is a RISC-V build (Phi-3 int4 on a LicheePi4A / XuanTie C910) that **compiled,
imported, and then emitted nonsense**; it was closed as not-planned with no root
cause. Tiers 1–3 of this lane's smoke pass in exactly that state — see
[The smoke](#the-smoke-smoke_genai_py).

The backlog carried this as **GEN1** ("upstream ships none; IREE-style build
plausible", effort L) until the user asked for the lane to be on. The actual
effort was far below that estimate, for the reason in the next section.

## The lane at a glance

| File | Role in GEN1 |
| --- | --- |
| `linux/scripts/01-core/versions.env` | Declares `GENAI_ALLOW_RISCV64=true` (a feature toggle, not a version pin) |
| `linux/Dockerfile.media` | Matching `ARG GENAI_ALLOW_RISCV64=true` → `ENV` on the `onnxruntime` builder stage; mounts `linux/scripts/patches` into the genai `RUN` |
| `…/03-media/build/onnxruntime/build/60-build-genai.sh` | Producer: escape hatch, patch apply, `--use_guidance` preflight, cross allowlist `arm64\|riscv64`, cross-wheel ELF/`EXT_SUFFIX` assert |
| `linux/scripts/patches/onnxruntime-genai/001-riscv64-target-platform.patch` | The one upstream blocker, one hunk |
| `…/03-media/runtime/verify-media-artifacts.sh` (`onnxruntime-genai`) | Build-time artifact gate; reads the producer's `.gen1-lane-off` marker |
| `…/03-media/runtime/validate-media-runtime.sh` | `LIB_DIRS` root + unresolved-`NEEDED` scan over the genai lib dir |
| `…/03-media/runtime/assemble-torch-app.sh` | `prune_conflicting_onnx_wheels` — no longer deletes the CPU genai wheel |
| `…/06-packaging/smoke-common.sh` (`smoke_genai_py`) | The four-tier binding / `generate()` smoke payload |
| `…/06-packaging/smoke-runtime-image.sh` | `check_genai_binding`, `_rt_versions_env_pin`, the ARCH-PARITY table, the app-wheel floor |
| `…/06-packaging/smoke-torch-venv.sh` | The riscv64 genai pin policy (absence is now a FAILURE) |
| `linux/scripts/tests/test-smoke-arch-parity.sh` | Pins the new contract in both directions |

## Why the rest of the cross path needed no change

The arm64 cross path added by **GENAI-DRIFT** (2026-08-24) was already fully
arch-generic. It reads every architecture fact from `platform.sh`, and
`platform.sh` already mapped riscv64 completely:

| What the cross body reads | riscv64 value |
| --- | --- |
| `CROSS_TARGET_TRIPLET` | `riscv64-linux-gnu` |
| `CROSS_TARGET_PROCESSOR` (`arch_cmake_system_processor_for`) | `riscv64` |
| `CROSS_RUST_TARGET` | `riscv64gc-unknown-linux-gnu` |
| `cross_wheel_platform_tag` | `linux_riscv64` |
| `arch_elf_machine_grep_for` | `RISC-V` |
| `cross_target_python_include_dir` | target Python headers |

Three further facts made the lane plausible without new machinery:

* **The ORT it links against is already real on riscv64.** `30-build-native.sh`
  has no arch skip, and `verify-media-artifacts.sh onnxruntime-cpu` hard-gates
  `libonnxruntime.so*` plus the C API header on **every** arch, so
  `NATIVE_CPU_OUTPUT_DIR` is populated before the genai stage runs.
* **No SIMD/intrinsic blocker in the v0.15.2 tree.** The only `_mm_` intrinsic
  is `src/dml/dml_gpu_event.h` (Windows/DML); the only `__x86_64__` /
  `__aarch64__` switch is `src/telemetry/device_info.cpp`, whose whole TU is
  telemetry-gated and `--no_telemetry` is passed on every arch;
  onnxruntime-extensions' `ocos_target_platform` is MSVC-only; and `dlib` is
  pulled in with `SOURCE_SUBDIR not_set`, so its own SIMD detection never runs.
* **The cross allowlist is an explicit two-arm list**, `arm64|riscv64`, not a
  blanket "any cross target". Nothing else is validated, and an open allowlist
  would quietly have let a 386/powerpc target through.

> **Keep the two allowlists in lockstep.** `60-build-genai.sh`'s
> `case "${ARCH}" in arm64|riscv64)` and `verify-media-artifacts.sh`'s
> `onnxruntime-genai` arm are each other's *only* cross-check. Change one,
> change the other — otherwise either the producer builds something nothing
> verifies, or the verifier demands something the producer never built.

## The upstream patch: `cmake/target_platform.cmake`

`linux/scripts/patches/onnxruntime-genai/001-riscv64-target-platform.patch`.
One hunk, applied only when `ARCH=riscv64`.

### Why configure FATAL_ERRORs on riscv64

onnxruntime-genai v0.15.2's `cmake/target_platform.cmake`, Linux branch
(`:53-64`), matches only `^arm64` / `^aarch64` / `^(x86_64|amd64)$` /
`powerpc`, and otherwise:

```cmake
message(FATAL_ERROR "Unsupported architecture. CMAKE_SYSTEM_PROCESSOR: ${CMAKE_SYSTEM_PROCESSOR}")
```

It is reached from `CMakeLists.txt:45` → `cmake/global_variables.cmake:118` —
i.e. during **configure**, before a single object is compiled. This lane passes
`CMAKE_SYSTEM_PROCESSOR=riscv64`, so without the patch the stage dies in
seconds.

The patch adds one `elseif` arm:

```cmake
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^riscv64.*")
  set(genai_target_platform "riscv64")
```

### Why the added arm is inert everywhere else

`genai_target_platform` is dead weight on this lane. A full-tree grep of v0.15.2
finds exactly three consumers, all unreachable here:

| Consumer | Why it never fires |
| --- | --- |
| `src/python/CMakeLists.txt:97` | guarded by `USE_WINML AND WIN32` |
| `src/java/CMakeLists.txt:172-174` | `ENABLE_JAVA=OFF` |
| `cmake/msvc_security.cmake:63` | MSVC only |

So the patch is semantically inert everywhere except at the `FATAL_ERROR` it
removes.

The apply is gated on `ARCH=riscv64` so amd64/arm64 never even invoke
`apply-patch.sh`: their genai source tree stays byte-identical to upstream.
Precedent for a riscv64-only patch applied exactly this way:
`linux/scripts/patches/libcamera/001-riscv64-add-libtiff-dep.patch`, from
`build-libcamera.sh`.

### How it was proven to apply — MEASURED

Applied, and re-applied as a no-op, against a **real clone of the pinned tag
v0.15.2 (`ed5f4e87`)**. `apply-patch.sh` is idempotent by construction: it first
tries a reverse-apply `--check` (already applied → SKIP), then a forward
`--check` (→ APPLY), and errors loudly if neither works.

This is the only part of the patch story that is measured. That it makes the
*build* succeed is not.

### The rejected alternative: lying about `CMAKE_SYSTEM_PROCESSOR`

Passing `aarch64` for a riscv64 target would slip past the gate for the same
reason the patch is inert (`Rust_CARGO_TARGET` is explicit,
`ocos_target_platform` is MSVC-only). It was **not shipped** because it is:

* invisible in build logs;
* silently rotting on any upstream bump that starts reading the variable;
* directly at odds with the arch asserts this repo depends on
  (`assert_elf_arch`, the `EXT_SUFFIX` check).

### The patches bind-mount

The genai `RUN` in `Dockerfile.media` gained
`--mount=type=bind,source=linux/scripts/patches,target=/opt/scripts/patches`.
`apply-patch.sh` itself already arrived via the whole-`01-core` mount; only the
patch tree was missing. amd64/arm64 never read it. It does move that layer's
cache key — but so does any edit to `60-build-genai.sh`, since the whole
onnxruntime script dir is already mounted there.

The producer hard-errors if the patch file is not found, naming the mount as the
likely cause.

## `--use_guidance` on riscv64

**Decision: keep it on.** `--use_guidance` builds llguidance (pinned `94fa3912`
in `cmake/deps.txt`) through Corrosion — a real `cargo` build for the *target*
triple.

### The evidence behind keeping it

* `riscv64gc-unknown-linux-gnu` is a rustc **Tier-2-with-host-tools** target, so
  `rustup target add` delivers a prebuilt `std`.
* This repo does add it: `02-toolchain/install-rust.sh` `add_rust_target` runs
  over `for_each_cross_target --include-amd64` with `CROSS_TARGETS`, whose
  `Dockerfile.toolchain` default is `amd64,arm64,riscv64`.
* The crate graph Corrosion actually imports (`parser/Cargo.toml`: `toktrie`,
  `derivre`, `serde`, `anyhow`, `regex-syntax`, `indexmap`, `ahash`) is pure
  Rust — no `cc` crate, no `ring`, no `openssl-sys`, no `pyo3`. Those enter the
  workspace `Cargo.lock` only via `python_ext` / `sample_parser` /
  `toktrie_hf_*`, which this import does not build. `ahash` falls back to its
  portable path without AES.

Dropping the flag would also be the wrong trade: guidance is what *constrains*
generation, so a riscv64 wheel without it is a **different wheel** from the one
amd64/arm64 ship — and the ARCH-PARITY table could not tell the difference,
because it matches on the distribution name only.

### The riscv64-only preflight

The one way this can still bite is a **missing rustup `std` for the triple**,
where Corrosion `FATAL`s and kills a multi-hour stage. So the producer runs a
riscv64-only preflight that drops `--use_guidance` on **positive evidence of
absence only**:

* target triple from `CROSS_RUST_TARGET`, else `rust_target_triple_for_arch`;
* `rustup target list --installed` must run **and** produce output **and** not
  contain the triple → drop the flag with a loud `warn`;
* a missing `rustup`, or a `rustup` that cannot list, leaves the flag **on**.

That is the same "only a positive answer flips the verdict" rule the runtime
smokes use. On amd64/arm64 it is a literal no-op: `GENAI_GUIDANCE_ARGS` expands
to `--use_guidance` unless the riscv64 branch fires.

**It does not catch a *link* failure** — only a missing `std`. See
[the watch list](#what-to-watch-on-the-first-real-riscv64-build).

### Corrosion cross wiring, for reference

Two things in the cross define set exist for llguidance:

* `Rust_CARGO_TARGET=${CROSS_RUST_TARGET}` — Corrosion passes an explicit
  `--target` to cargo, which would otherwise silently override the
  `CARGO_BUILD_TARGET` exported by `setup_linux_cross_env`. Corrosion also wires
  `CARGO_TARGET_<T>_LINKER` to `CMAKE_C_COMPILER` (the cross gcc) itself.
* `unset LIBRARY_PATH` around the `build.py` invocation — the **HOST-LINK LEAK**
  found on the arm64 lane's first live run (wave7b, 2026-08-24):
  `setup_linux_cross_env` exports `LIBRARY_PATH` with the TARGET libdirs, and
  the host `cc` honours it for `-m64` links too, so cargo's *host* build scripts
  (`proc-macro2`, `anyhow`, `zerocopy`, `rustversion`…) died with
  "aarch64 `libgcc_s.so.1` is incompatible with elf64-x86-64" on every retry.

## The cross-wheel gate in the producer

On a cross build the **wheel is the whole point of the stage**, so a `build.py`
that "succeeded" without emitting one must fail *in `60-build-genai.sh`* — not
resurface hours later at app assembly as a silent fallback to the app lock's
PyPI genai (the GENAI-DRIFT bug). There is deliberately **no host `pip wheel`
fallback**: that would package an amd64 binding under a foreign platform tag.

The gate then proves the shipped bytes, not the build log:

* every `*.so` / `*.so.*` inside the unpacked wheel goes through
  `assert_elf_arch … "${ARCH}"`;
* the pybind module must be named `onnxruntime_genai${_GENAI_MODULE_EXT}`, i.e.
  carry the **target** `EXT_SUFFIX`.

**riscv64 flows through this unchanged, and that is the point.**
`assert_elf_arch` resolves riscv64 to the ELF machine string `RISC-V` through
`platform.sh` `arch_elf_machine_grep_for`, so the existing gate proves the
riscv64 bytes with no new code.

It is no longer the *only* net — `verify-media-artifacts.sh`'s
`onnxruntime-genai` arm used to SKIP every non-arm64 cross target and now gates
the riscv64 one too — but it is still the first and the most specific one.

## The escape hatch: `GENAI_ALLOW_RISCV64`

One knob turns the whole lane off and restores the **pre-GEN1 behaviour
exactly** — `60-build-genai.sh` creates its placeholder output tree and exits 0,
and every downstream gate agrees. No code edit required.

It is deliberately **riscv64-scoped**. The pre-existing `BUILD_GENAI` switch is
all-arch, so backing a riscv64 breakage out with *that* would also drop the
shipped amd64/arm64 genai wheels.

### Where it is declared, and how it reaches each consumer

| Consumer | How it gets there | Default when unset |
| --- | --- | --- |
| `versions.env` | the declaration: `GENAI_ALLOW_RISCV64=true` | — |
| `Dockerfile.media` | `ARG GENAI_ALLOW_RISCV64=true` → `ENV` on the `onnxruntime` stage. The ARG literal **must equal** the versions.env value (`verify-arg-consistency.sh` enforces it) | — |
| `60-build-genai.sh` (producer) | reads the ENV | `false` — conservative, for standalone runs |
| `verify-media-artifacts.sh` (verifier) | reads the ENV **and** the marker file | `false` (fallback only) |
| `smoke-torch-venv.sh` (in-container) | passed in with `-e` by `check_ml_version_pins` | `true` — armed |
| `smoke-runtime-image.sh` (host) | `_rt_versions_env_pin GENAI_ALLOW_RISCV64` reads `versions.env` host-side | empty = not asserted |

The script-side conservative default follows the shape of
`ORT_ENABLE_WEBGPU` / `ORT_WEBGPU_ALLOW_CROSS`: scripts default off for
standalone runs, `versions.env` opts the orchestrated image builds in. Concretely,
`60-build-genai.sh` reads `${GENAI_ALLOW_RISCV64:-false}` so that a bare
`bash 60-build-genai.sh` against a riscv64 target cannot walk into this
still-unvalidated multi-hour build by accident. The same reasoning is why
`GENAI_ALLOW_RISCV64` sits in `verify-arg-consistency.sh`'s
`SCRIPT_DEFAULT_DRIFT_ALLOW`: the script default is *meant* to differ from the
`versions.env` pin.

**Why the ARG is promoted to `ENV`, not just read from `versions.env`.** Two
different `RUN` steps need the value — the producer and the verifier — and the
verifier `RUN` (`verify-media-artifacts.sh onnxruntime-genai`) bind-mounts
**nothing but a tmpfs `/tmp`**: no `linux/scripts/01-core`, so it cannot
`load_versions_env` the file at all. A stage-level `ENV` is the only channel
that reaches both. That is also why the ARG literal and the `versions.env`
value must be kept equal by hand — `verify-arg-consistency.sh` is what catches
them drifting.

This toggle is **LINUX lane only**: no Windows build consumes it (same as
`ORT_ENABLE_WEBGPU` / `ORT_WEBGPU_ALLOW_CROSS`, and consistent with the
repo-wide rule that the Windows lane carries its own separate backlog).

Two defects in this wiring were found in review and fixed the same day:

1. **It never reached the in-container smoke.** `nerdctl run` inherits nothing
   from the host, and `GENAI_ALLOW_RISCV64` is ARG/ENV only on the
   `onnxruntime` **builder** stage — the media *final* stage is
   `FROM media-inputs`, so the shipped image does not carry it. The baked
   `smoke-torch-venv.sh` therefore always saw the toggle unset, its riscv64 arm
   defaulted to "genai expected", and the documented back-out **still red the
   gate**. `check_ml_version_pins` now forwards it explicitly with `-e`, reading
   the value out of `versions.env` host-side, so the smoke asserts the policy
   the build was configured with.
2. **Producer and verifier defaults disagreed in the failing direction**
   (`:-false` vs `:-true`). With the ENV out of scope, the producer skipped and
   the verifier then hard-failed on the placeholder tree the producer had just
   created. Fixed by the marker, below.

### The `.gen1-lane-off` marker

When the producer takes the escape hatch it writes an empty file
`${GENAI_OUTPUT_DIR}/.gen1-lane-off` beside the placeholder tree, and the
verifier prefers that file over re-deriving the policy.

The marker exists because the producer and the verifier **run in different
`RUN` steps**, so re-deriving the same decision twice from an environment
variable is a decision that can differ. Recording it as a *file* makes the
verifier read what actually happened rather than what it thinks should have
happened. The env check is kept only as a fallback for a tree written before the
marker existed, and now uses the *same* default as the producer.

**Hard requirement on the hatch: turning the lane off must not turn the build
red.** That is what all four toggle states are checked against.

### The four toggle states

| Lane | Producer | Verifier | `smoke-torch-venv` |
| --- | --- | --- | --- |
| riscv64, `true` | cross-builds the wheel, asserts ELF + `EXT_SUFFIX` | gates for a real artifact | genai **required** |
| riscv64, `false` | placeholder tree + `.gen1-lane-off`, exit 0 | SKIP (marker) | `~~ not installed … policy, not drift` |
| amd64/arm64, `true` | unchanged | unchanged | genai required (as before) |
| amd64/arm64, `false` | unchanged — the toggle is riscv64-scoped | unchanged | genai still required |

`test-smoke-arch-parity.sh` pins the last row explicitly: the hatch must not
silence amd64.

## The smoke: `smoke_genai_py`

Lives in `smoke-common.sh` beside the ONNX Add-graph fixture, for the same
reason — one source of truth, injected as an env var so the check also gates
images built *before* it existed. Driven by `check_genai_binding` in
`smoke-runtime-image.sh`, which runs on **every** arch: riscv64 motivated it,
but a host-suffixed or wrong-ELF binding is the same defect class on
amd64/arm64.

**Why an import check would not have been enough:** issue #594 is a build that
compiled *and imported* and then emitted nonsense. "The wheel is installed and
imports" is precisely the state that bug was in — the same toothless class as
the `onnxruntime` import check this file's ONNX section replaced in wave 5.

### Inputs

| Env var | Meaning |
| --- | --- |
| `GENAI_EXPECT_VERSION` | `ONNXRUNTIME_GENAI_VERSION` from `versions.env`; empty → version tier reports NOT ASSERTED |
| `GENAI_EXPECT_ARCH` | `amd64` / `arm64` / `riscv64`; empty → ELF tier reports NOT ASSERTED |
| `GENAI_MODEL_DIR` | optional real model directory — **arms tier 4** |
| `GENAI_MAX_LENGTH` | tier-4 `max_length`, default 16 |

### The four tiers

| Tier | What it does | What it PROVES |
| --- | --- | --- |
| 1 — version | `og.__version__`, falling back to `importlib.metadata` | the installed genai equals the `versions.env` build pin |
| 2 — ELF | reads 20 bytes of the **loaded** extension's header (`og.onnxruntime_genai.__file__`) and compares `e_machine` | the bytes actually executing are TARGET-arch — read from the file header, not inferred from the wheel tag |
| 3 — native code runs | pybind API objects exist; capability predicates (`is_cuda_available`/`is_webgpu_available`/`is_qnn_available`) execute; `og.Tensor(numpy)` round-trips a float32 buffer through `OgaTensor`; `og.Config()` on a non-model path is rejected **by the library** | native C++ code runs, dtype/shape mapping and the copy-back through the C API work, and the binding's ABI matches |
| 4 — `generate()` | encodes a prompt, generates, asserts on **token content** | that the model emits more than zero tokens and not one token repeated — the #594 nonsense signature |

`e_machine` values used: amd64 62 (X86-64), arm64 183 (AArch64), riscv64 243
(RISC-V), 386 3. Read from the header rather than shelling out to
`readelf`/`file`: neither is guaranteed in a runtime image, and the header is
20 bytes of well-specified wire format.

That header read is the **only I/O in the whole program**, and it is wrapped in
a `try`/`except OSError` for a specific reason: every other step degrades to an
`UNPROVEN` line or appends to `fails`, so an uncaught `OSError` here would be
the one path that exits non-zero having printed **no `GENAI-BIND` sentinel at
all**. `check_genai_binding`'s no-sentinel arm would then misdiagnose an
unreadable extension file as "the generated program did not run" — on every
arch. Caught, it becomes an ordinary `DEFECT` line.

Tier 3's `og.Config()` check discriminates *where* the rejection came from: a
`TypeError`/`AttributeError` means the **binding** refused it — a signature/ABI
mismatch, a FAIL. Any other exception (or none) means native code ran and made
the decision.

The program prints `PROVEN` / `UNPROVEN` / `DEFECT` lines itself, so a log
reader never has to take the accounting on trust.

### Tier 4 is UNARMED by default

**Token-level correctness is not proven.** No model ships in these images — the
smallest usable int4 decoder is hundreds of MB, and the riscv64 lane is
cross-built on an amd64 host, so it could not run one at build time anyway.
Without `GENAI_MODEL_DIR` the tier is **skipped and says so**
(`GENAI-GEN SKIP:`). Arm it by mounting a small model and setting
`GENAI_MODEL_DIR`.

### Installed-but-unimportable is a hard FAIL, not a SKIP

The exit codes:

| rc | Meaning | Driver's verdict |
| --- | --- | --- |
| 0 | ran and passed (`GENAI-BIND OK:`) | PASS |
| 1 | a real defect (`GENAI-BIND FAIL:`) | FAIL |
| 3 | genai legitimately absent (`GENAI-BIND SKIP:`) | SKIP, not a pass |
| 4 | `SMOKE_GENAI_PY` never crossed the container boundary (`GENAI-BIND ABSENT:`) | FAIL |

An import failure has **two very different causes** and they must not share an
exit code:

* *no wheel on this arch* — benign; whether the wheel is supposed to be here is
  the **ARCH-PARITY table's** judgement, not this smoke's, so an image whose
  GenAI lane is legitimately off must not turn red twice;
* *the wheel IS installed but its native library will not load* — a **defect**,
  and one that is invisible to every other gate. `smoke-torch-venv`'s
  `installed_version()` falls back to `importlib.metadata` when the import
  raises (so it happily reports the pinned version), and ARCH-PARITY only reads
  dist-info directory names.

Collapsing both into exit 3 made a broken riscv64 binding — an unresolved
`__atomic_*` or `NEEDED`, exactly the risk this lane carries — report as a green
SKIP. They are now distinguished by asking whether the *distribution* is
present.

### Exit status is not evidence

`check_genai_binding` demands the `GENAI-BIND` sentinel in the **output**, not
just `rc=0`. If `SMOKE_GENAI_PY` arrives empty, `python -` reads an empty
program and exits 0. A non-`OK` sentinel with `rc=0` is also an explicit FAIL:
a non-OK verdict must never pass.

The version pin reaches the check through `_rt_versions_env_pin`, a small
host-side `versions.env` reader hoisted out of `check_clang_llvm_release`'s
`LLVM_RELEASE` lookup. Env wins, then the file, empty on any miss — and every
caller must treat empty as "not asserted" rather than as a match. Its `|| true`
is load-bearing: under `set -euo pipefail` an absent key would abort the whole
smoke with no summary.

## Two adjacent defects fixed in the same window

Both are risk-reducing and were done deliberately *before* any rebuild, so the
rebuild is more likely to catch a real GEN1 failure than to ship one. Both are
**new gates on all three arches that have not been run against a real image.**

### The GenAI libraries were scanned by nothing

`validate-media-runtime.sh` checked unresolved `NEEDED` only over `ARTIFACTS`
(the gst / libcamera / ffmpeg binaries) plus the gst plugin dir; its `LIB_DIRS`
sweep checks ELF **machine** only and is advisory.
`/usr/local/lib/onnxruntime-genai/lib` appeared in **neither** list, so an
unresolved `NEEDED` in `libonnxruntime-genai*.so` would have reached a shipped
image unseen — precisely the riscv64 `-latomic` risk (GenAI's CMake, unlike
upstream ORT's, has **no** libatomic probe).

Two changes:

* the genai prefix joins `LIB_DIRS`, so it is a resolution root for other
  binaries *and* is covered by the advisory arch sweep;
* the lib dir is walked by `scan_plugin_directory` — misnamed but generic (it
  walks a dir's `*.so` and returns unresolved sonames), so it was reused rather
  than copied — feeding the existing `ALL_MISSING` repair/deny machinery.

Guarded by `[ -d ]`, so it is a no-op when the lane is off and the placeholder
tree has an empty `lib/`. amd64/arm64 are expected to resolve exactly as before,
because genai's own deps (`libonnxruntime.so` and friends) live in
`/usr/local/lib/onnxruntime-cpu/lib`, already a `LIB_DIRS` root.

### `prune_conflicting_onnx_wheels` deleted the wheel the same file needs

On the **default** `ONNX_PACKAGE=onnxruntime` path,
`assemble-torch-app.sh` ran `rm -f /opt/wheels/*genai*.whl`. That glob matches
the CPU wheel `onnxruntime_genai-<ver>-…whl` this media lane builds on every
arch — the very wheel `build_uv_sync_args` looks for ~60 lines later, and that
ARCH-PARITY now asserts must be installed. Ordering confirmed:
`install_project_environment` prunes (L441) **before** `build_uv_sync_args`
looks (L218), so a successful `rm` would have resurrected the GENAI-DRIFT bug —
no local wheel, silent fallback to the app lock's PyPI genai.

It was inert **only by accident**: `/opt/wheels` is a read-only bind mount
(`Dockerfile.torch:80`), so the `rm` fails and `|| true` swallows it. Making
that mount rw would have broken all three arches at once.

Narrowed to the GPU-flavoured variants the arm actually means — it sits beside
`*_gpu-*` and `*_migraphx-*` — i.e. `*genai_cuda-*`, `*genai_rocm-*`,
`*genai_directml-*`. **MEASURED:** verified against a fixture that the CPU wheel
and plain `onnxruntime-*` survive while `*_gpu-*` and `*genai_cuda-*` are
removed. GEN1 turned this from dormant to self-contradictory.

## What to watch on the first real riscv64 build

In the order they can bite:

1. **The genai stage compiling at all** under the GCC 16 riscv64 cross
   (onnxruntime-genai v0.15.2 + onnxruntime-extensions + dlib). Source-read
   only.
2. **`cross_target_python_dev_ready` returning true** inside the onnxruntime
   media container. If it does not, the producer warns and exits 0 with an empty
   tree, and the verifier then FAILS the build — loudly and correctly, but hours
   in. (Same gate the ORT cross wheel uses in `30-build-native.sh`: without
   target Python dev files the binding would compile against HOST headers.)
3. **llguidance / Corrosion actually LINKING** for
   `riscv64gc-unknown-linux-gnu`. The preflight only catches a *missing* rustup
   `std`, not a link failure. Back-out if it bites: drop `--use_guidance` for
   riscv64 only.
4. **The pybind `EXT_SUFFIX`** really being `.cpython-314-riscv64-linux-gnu.so`.
   Derived, not confirmed against a shipped riscv64 `/opt/venv` python the way
   the arm64 value was. It **fails safe** — the wheel assert turns a wrong
   suffix into a loud build error, never a silently-unimportable wheel — and the
   multiarch component is corroborated by `verify-wheels.sh`, which derives the
   same `.cpython-XY-<target triplet>.so` expectation from `TARGET_ARCH` and was
   written against a real riscv64 wheel that had leaked the HOST x86_64 suffix.
   Confirm cheaply by reading `EXT_SUFFIX` out of the shipped image.
5. **`-latomic`.** GenAI's CMake has no libatomic probe (upstream ORT does). Low
   probability; if it bites, the shared-library link dies on undefined
   `__atomic_*`. The new `validate-media-runtime.sh` scan is what would catch a
   surviving unresolved symbol at runtime.
6. **Then performance, not correctness** — see below.
7. **Network flake in the cargo fetch.** Deliberately left unfixed; owned as an
   open item by [`refactoring-backlog.md`](refactoring-backlog.md) section B.
   Note it if the riscv64 stage flakes.

Also deliberately left unraised: **the riscv64 app-wheel floor stays at 12.**
The lane now builds genai, and the app suite's `check_onnxruntime_genai` should
turn the riscv64 count into 13 — but "should" is not a measurement, and raising
a floor a run cannot reach reds the gate for the wrong reason. Raise it to 13
only once a real riscv64 run **prints** `13/… ok`. Until then the new component
is guarded by `check_genai_binding` and the ARCH-PARITY table instead.

### Performance: riscv64 MLAS is scalar

Not a correctness issue, but it shapes expectations and timeouts. ORT v1.29's
riscv64 MLAS falls back to the **scalar reference kernels** — including the int4
`MatMulNBits` kernel GenAI models want. The RVV kernels need
`onnxruntime_USE_RVV` plus an `-march=rv64gcv` compile probe, and this repo sets
**neither**. Expect `generate()` to need a generous timeout.

## Why ARCH-PARITY is deliberately red for existing riscv64 images

The `riscv64:onnxruntime_genai` exemption in `_parity_exempt` is **deleted**. It
used to read: *"upstream ships no riscv64 wheel and closed its one RISC-V
request as not-planned. Policy, not drift."* That was true of **upstream**; it
is no longer true of this repo.

Consequences, all intended:

* every **currently-shipped** riscv64 image now fails that assertion, and
  `smoke-torch-venv` reports `XX onnxruntime-genai NOT INSTALLED`;
* an image built with `GENAI_ALLOW_RISCV64` turned **off** also fails ARCH-PARITY
  — in that case the fix is to re-add the exemption arm *together with* the
  toggle.

**Do not "fix" this by re-adding the exemption.** The table's contract is that
every arm is a deletion candidate and may only encode a reason that is true
*today*, never "not built yet" — otherwise it becomes a wish list. An absence
nobody wrote down is drift, and drift must fail.

The parallel change in `smoke-torch-venv.sh` inverts the same policy. The old
carve-out (`STV_REQUIRE_GENAI`, added 2026-08-11 after the assert flagged the
documented absence as a pin failure) printed
`~~ not installed (documented riscv64 skip)` and passed **no matter why** the
wheel was missing. Now the riscv64 arm keys off `GENAI_ALLOW_RISCV64` instead:
armed unless the lane was explicitly turned off. One knob for the whole feature
on both the build and the smoke side, rather than a second smoke-only name
nobody would think to set.

`smoke-runtime-image.sh`'s transitional pre-2026-08-12-wrapper `elif` branch is
gone with it: keeping it would have printed the exact opposite story
("documented riscv64 exemption") on the first genuine riscv64 miss.

### The regression rows that pin this

`test-smoke-arch-parity.sh` gained rows in both directions — the riscv64 arm of
`assert_pinned_versions` had **no case at all** before, which is the blind spot
that let a "documented skip" outlive the thing it documented:

| Case | Asserts |
| --- | --- |
| `_parity_exempt riscv64 onnxruntime_genai` | now `t_assert_fails` (was `t_assert_ok`) — re-adding the exemption would silently un-gate the component GEN1 turned on |
| riscv64 image **without** genai | `onnxruntime-genai NOT INSTALLED`, `FAILURES>=1` |
| riscv64 image **with** the pinned genai | `FAILURES=0` |
| riscv64 + `GENAI_ALLOW_RISCV64=false` | `FAILURES=0`, and the message names the toggle |
| amd64 + `GENAI_ALLOW_RISCV64=false` | still `FAILURES>=1` — the hatch is riscv64-scoped |

`_stv_drive` grew a fourth parameter for one extra `VAR=VALUE`, because it
drives the smoke under `env -i` and the toggle therefore has to be handed in
explicitly.

## Backing the lane out

In increasing order of blast radius:

1. **Turn the lane off.** Set `GENAI_ALLOW_RISCV64=false` in
   `versions.env` **and** the matching `ARG` default in `Dockerfile.media` —
   both, in the same commit; `verify-arg-consistency.sh` requires them to agree.
   Then re-add the `riscv64:onnxruntime_genai` arm to `_parity_exempt` (the text
   to restore is preserved as an `NB` comment at that spot), or ARCH-PARITY will
   still red. `smoke-torch-venv` follows the toggle automatically.
2. **Drop only `--use_guidance` for riscv64**, if llguidance is the thing that
   breaks. The wheel then ships without guidance — a different wheel from
   amd64/arm64's; record that fact, because no gate can see it.
3. **Do not use `BUILD_GENAI=false`** to back out a riscv64 problem. It is the
   all-arch master switch and would drop the shipped amd64/arm64 genai wheels
   with it.

Removing the lane entirely would additionally mean deleting the patch, the
patches mount, and the riscv64 arm of both cross allowlists — but there is no
reason to prefer that over the toggle, which is verified to restore the
pre-GEN1 behaviour exactly.

## MEASURED vs REASONED

Honest separation, as of **2026-08-31**.

**MEASURED**

* The patch applies, and re-applies as a no-op, against a real clone of
  v0.15.2 (`ed5f4e87`).
* The arm64 cross lane really does produce a wheel — *"Created wheel for
  onnxruntime-genai: `onnxruntime_genai-0.15.2-cp314-cp314-linux_aarch64.whl`"*,
  `media-arm64.log`, 2026-08-27.
* The arm64 `EXT_SUFFIX` was verified against the shipped arm64 image's
  `/opt/venv` python.
* The narrowed prune globs were verified against a fixture.
* Static gates over the whole window: `make lint` clean (276 files),
  `make preflight` green, `make test-linux-scripts` 38 suites / 1001
  assertions.
* The source-reads of the v0.15.2 tree quoted above (the `FATAL_ERROR` branch,
  the three `genai_target_platform` consumers, the intrinsic survey, the
  llguidance crate graph) are observations of real source at the pinned tag.

**REASONED, never run**

* That the riscv64 genai stage compiles.
* That llguidance links for `riscv64gc-unknown-linux-gnu`.
* That the riscv64 `EXT_SUFFIX` is `.cpython-314-riscv64-linux-gnu.so`.
* Whether `-latomic` is needed.
* That `generate()` produces sane tokens (tier 4 is unarmed; #594 is the
  standing counter-example).
* The new `validate-media-runtime.sh` genai scan, on any arch.
* That the riscv64 app-wheel count becomes 13.
