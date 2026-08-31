# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-08-14 … 2026-08-28`](docs/changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.


## 2026-08-31 — Linux backlog closure window: ERR-trap bug, complexity queue, GEN1 riscv64 GenAI

Closed every open work item on the Linux refactoring backlog in one closure
window (A1 + GEN1). Gates: `make lint` clean (276 files), `make preflight`
green, `make test-linux-scripts` **38 suites / 1001 assertions** (up from 32
suites — six new suites). **No container build was run: everything below is
static-gate-proven only, and the riscv64 GenAI lane in particular is UNVALIDATED
until a real media-riscv64 build.**

### The bug: logging.sh ERR trap reported the wrong error (A1)

`_install_trap`'s `on_err` read its reporting action (`err`/`warn`) from a
`local` of the installer via **dynamic scope**. The trap fires long after the
installer returned, so under `set -u` the handler died with
`logging.sh: line 119: action: unbound variable` — which **replaced the real
error text** (it masked a parallel-GCC apt-lock failure during the 2026-08-30
rebuild) and meant the intended action never ran at all: `install_err_trap`
never exited 1, `install_warn_trap` never printed.

`on_err` is now a single top-level function and `_install_trap` bakes the
resolved action into the trap string with `printf -v '%q'`, keeping `LINENO` /
`BASH_COMMAND` escaped so they still expand **at fire time**. `_LOG_TRAP_ACTION`
covers `build-gcc.sh:709`, which re-arms the *bare* trap string by hand around
its configure step. New `test-logging-err-trap.sh` (30 assertions) fails 29/30
against the pre-fix file.

### Complexity queue (A1) — all decomposed, all behaviour-preserving

- `append_tvm_cmake_args`: 15 positionals → named options (a dropped or
  mis-ordered arg used to fail silently as wrong CMake flags, hours in).
- `_build_vulkan_targets` (137 lines) and `_llvm_cross_setup_and_build`
  (146 lines) decomposed along their real seams.
- `build_iree_wheels` split into nine `_iree_*` stages.
- `parse_options` (116-line nested case/while) collapsed to a data table, with
  the load-bearing asymmetries preserved (`--ports-url` `${2-}` vs
  `--archive-url` `${2:-}`; the `install-vulkan-runtime-files` passthrough).
- **`modules.sh` dir-walker: deliberately NOT changed.** All four suspected
  defects were probe-tested and refuted (the walk terminates for every input
  shape and cannot cycle; the `return 1` signal is consumed correctly;
  `BASH_SOURCE[1]` is right at any nesting depth). It is in the base/compiler/
  media closure and its last mistake SIGSEGV'd the media build — style churn
  there is a net negative. Do not re-flag.

### Two toothless-gate findings (the class this repo keeps getting bitten by)

- The new IREE suite claimed every `|| return 1` call site was covered; only
  2 of 5 were. While fixing it: (a) the fault injection silently did nothing
  because `grep` here is **ugrep**, which parsed a `--build …` pattern as an
  option — now `grep -qE -e`; (b) even with injection working, `rc==1` passed on
  all three mutations anyway, because `_iree_package_wheels` bails at its own
  `[ ! -d ]` guard and returns 1 — *the right answer for the wrong reason*, with
  a misleading diagnostic replacing the real configure failure. The cases now
  assert the packaging diagnostic is **absent**. All five call sites are
  mutation-verified.
- `smoke_genai_py` conflated "no wheel on this arch" with "wheel installed but
  its native library will not load" — both exited 3, reported as a benign SKIP.
  Every other gate is blind to the second case (`smoke-torch-venv`'s
  `installed_version()` falls back to `importlib.metadata` when the import
  raises; ARCH-PARITY only reads dist-info directory names), so a broken riscv64
  binding would have shipped green. An installed-but-unimportable distribution
  is now a hard FAIL.

### GEN1 — onnxruntime-genai riscv64 lane, built and wired ON

riscv64 now takes the same cross path arm64 takes; the hard arch guard is gone
and the allowlist is an explicit `arm64|riscv64`.

- **Upstream patch** `patches/onnxruntime-genai/001-riscv64-target-platform.patch`:
  `cmake/target_platform.cmake`'s Linux branch `FATAL_ERROR`s on any processor
  that is not arm64/x64/powerpc. One added `riscv64` arm fixes it, and
  `genai_target_platform` is read only under `WIN32` / `ENABLE_JAVA` / MSVC — so
  the patch is inert everywhere else. Proven to apply (and re-apply as a no-op)
  against a real clone of the pinned tag v0.15.2 (`ed5f4e87`).
- `--use_guidance` **kept** on riscv64 (auto-dropped with a WARN only if rustup
  lacks the std — see the A1 watch list): `riscv64gc-unknown-linux-gnu` is Rust
  Tier-2-with-host-tools, `install-rust.sh` adds its std for every
  `CROSS_TARGETS` arch, and the crate graph Corrosion imports is pure Rust.
- **Escape hatch `GENAI_ALLOW_RISCV64`** (versions.env → `Dockerfile.media`
  ARG/ENV) restores the pre-GEN1 placeholder-and-skip exactly. Two defects found
  in review and fixed: it never reached the in-container smoke (`nerdctl run`
  inherits nothing from the host, and the media *final* stage is
  `FROM media-inputs`), so the documented back-out still red the gate; and
  producer/verifier defaults pointed opposite ways (`:-false` vs `:-true`),
  disagreeing in the failing direction. The producer now drops a
  `.gen1-lane-off` marker and the verifier reads **the producer's actual
  decision** instead of re-deriving it.
- `smoke_genai_py()` added to `smoke-common.sh`, run on every arch: asserts the
  version against the versions.env pin, that the loaded extension's ELF machine
  is the target's, and that the pybind API objects exist. Tier 4 calls
  `generate()` **only when `GENAI_MODEL_DIR` is set — it is UNARMED by default,
  so token-level correctness is NOT yet proven.**

### Known-red until the next riscv64 build (by design)

Removing the `riscv64:onnxruntime_genai` ARCH-PARITY exemption means **every
currently-shipped riscv64 image now fails that assertion**. That is the table
working as intended, not a regression. The riscv64 app-wheel floor is
deliberately left at 12 (raise to 13 only after a real run *prints* it).

**Watch on the first media-riscv64 build:** the genai stage compiling at all
(GCC 16 cross, source-read only); `cross_target_python_dev_ready` returning true
there; llguidance actually *linking*; the pybind `EXT_SUFFIX` really being
`.cpython-314-riscv64-linux-gnu.so`; and possible `-latomic`. Upstream issue
\#594 is a RISC-V genai build that compiled, imported and emitted **nonsense** —
tiers 1-3 of the smoke pass in exactly that state.

### Two GEN1-adjacent defects fixed in the same window (risk-reducing, pre-rebuild)

- **The GenAI libraries were scanned by nothing.**
  `validate-media-runtime.sh` checks unresolved `NEEDED` only over `ARTIFACTS`
  (gst/libcamera/ffmpeg) plus the gst plugin dir; its `LIB_DIRS` sweep checks
  ELF *machine* only, advisory. `/usr/local/lib/onnxruntime-genai/lib` was in
  neither — so an unresolved `NEEDED` in `libonnxruntime-genai*.so` would have
  reached a shipped image unseen. That is precisely the riscv64 `-latomic` risk
  GEN1 flagged (GenAI's CMake, unlike upstream ORT's, has **no** libatomic
  probe). The prefix now joins `LIB_DIRS` *and* the lib dir is walked for
  unresolved NEEDED through the existing machinery. **New gate on all three
  arches; not yet run against a real image.**
- **`prune_conflicting_onnx_wheels` deleted the wheel the same file needs.** On
  the default `ONNX_PACKAGE=onnxruntime` path it ran
  `rm -f /opt/wheels/*genai*.whl` — matching the CPU wheel this lane now builds
  on every arch, which `build_uv_sync_args` looks for 60 lines later and which
  ARCH-PARITY now asserts. Prune runs first, so a successful `rm` would have
  resurrected GENAI-DRIFT (silent PyPI-genai fallback). Inert only by accident:
  `/opt/wheels` is a read-only bind mount and `|| true` swallowed the failure —
  making it rw would have broken all three arches at once. Narrowed to the
  GPU variants the arm actually means.

### Also

- `linux/qnn-sdk/README.md`: corrected a stale paragraph calling the
  `QNN_SDK_LINUX_ZIP_SHA256` pin "planned". It is implemented **and populated**
  with the proven QAIRT v2.49.0.260730 hash, so re-staging that exact version
  needs **no re-pin**; documented `QNN_SDK_LINUX_LIBDIR` as the single knob.


## 2026-08-31 — one Windows driver, and the module mount that re-keyed LLVM on every `.psm1` edit

### The DEFAULT toolchain target bind-mounted the WHOLE modules directory

`Dockerfile.toolchain-builder`'s `patched-llvm` RUN mounted
`windows/scripts/modules` as a directory, putting all ~40 modules into that
RUN's cache key. `patched-llvm` is the DEFAULT toolchain target
(`build-buildkit.ps1` picks it unless `-StockLlvm`), so editing ANY module — a
host-only driver module no container ever imports included — re-keyed a full
LLVM 23.1.0 compile plus every media lane that derives from
`bk-windows-toolchain`. It is now a per-FILE mount of exactly the six modules
`build-llvm-from-source.ps1` imports. Regression test:
`BuildKit.ModuleClosure.Tests.ps1` fails on a whole-directory modules mount in
any windows Dockerfile except `Dockerfile.probe` (exempt by design —
`PROBE_NONCE` busts that layer anyway, and its own header says so).

What the mount quietly falsified while it existed: AGENTS.md rule 5(b)
("TIERED in-container module closures so host-only module edits cannot bust a
compile layer") and `WindowsBuildDriver.Common.psm1`'s own "Edit cost: … cheap"
header. Both describe the tiering the Dockerfiles implement again. Second
correction in the same Dockerfile: the `BUILD_PATCHED_LLVM` comment still read
"OPT-IN … off by default" while `ARG BUILD_PATCHED_LLVM=1` and the driver have
defaulted it ON since #135.

### `windows/build.ps1` deleted — and the six functions only it called

The classic docker-build lane was retired 2026-08-26 and is now gone;
`build-buildkit.ps1` is the one driver. `WindowsBuildDriver.Common.psm1` lost
`Set-BuildDriverIsolation`, `Invoke-DockerWithRetry`, `Get-DockerBuildArgList`,
`Assert-ImageExists`, `Resolve-BuildIsolation` and `Assert-DockerDaemon`.
`Test-TransientDockerFailure` STAYS — `Invoke-TransientCooldown` classifies
against it and the BK driver calls that. `$script:BuildDriverContext` is down to
`TransientPattern`, and `Initialize-BuildDriverContext` takes only
`-TransientPattern` (Docker/LogDir/NoCache had no readers left).

Tests followed: `Driver.PreflightParity.Tests.ps1` (two drivers, one contract)
became `Driver.PreflightContract.Tests.ps1` (3 tests), `Driver.ClosureScope`
keeps the #40 closure rule but only for the surviving driver, and
`BuildDriver.Retry` lost 6 retry/build-arg tests. Suite is 773;
`Invoke-Tests.ps1`'s `$minTests` goes 763 → 762 — the first DOWNWARD move of
that floor, with the arithmetic recorded inline so it cannot read as hiding a
red run.

Stale `build.ps1` references were corrected in both `.dockerignore` files,
`Dockerfile.base` / `.nvidia` / `.torch` / `.toolchain-builder`, `versions.env`,
`bump_versions.py`, `sync_versions.py`, `windows/downloads/README.md`,
`Invoke-Lint.ps1`, the three `build-*-all.ps1` payload headers,
`build-toolchain-all.ps1`, `build-resource-sampler.ps1` and both diagnostics
probes. Two were not mechanical renames: `verify-host-setup.ps1` was a LIVE
CHECK reporting stevedore as the "classic fallback lane" and now reports it as
the publish/inspect tool (which is what `docker.exe` still is), and
`Dockerfile.torch`'s `-TorchBaseImage` recipe has NO BuildKit equivalent — the
BK driver has no such flag and pins the torch stage's `BASE_IMAGE` to the local
`windows-media` tag — so it is documented as not driver-supported rather than
renamed.

### `Set-StrictMode -Version Latest` on 7 scripts — 4 latent bugs, 1 already live

Added to `build-llvm-from-source`, `debug-litertlm-link`, `load-versions`,
`normalize-tensorrt-tree`, `stage-cuda-runtime`, `clean-sccache-mount` and
`bootstrap-pwsh`. On pwsh 7.6.5, `.Count` throws under StrictMode on a scalar
AND on an empty pipeline result, which is what made four sites bugs rather than
style:

- `debug-litertlm-link.ps1` — `(Get-Command 'llvm-nm.exe' -EA SilentlyContinue).Source`
  was ALREADY LIVE: its caller `build-litert-lm-from-source.ps1` sets StrictMode
  and `&`-invocation inherits it, so the "no llvm-nm" branch the script already
  had could never be reached. Bound first now.
- `normalize-tensorrt-tree.ps1` — `$dllDirs` was not `@()`-wrapped, so `.Count`
  threw on the NORMAL SUCCESS PATH (TensorRT 10+/11 ship the DLLs in `bin` only,
  leaving exactly one surviving dir).
- `stage-cuda-runtime.ps1` — same shape on `$roots`; would have re-broken the
  arm64/CPU merge lane the 2026-08-23 degrade-cleanly fix unblocked.
- `clean-sccache-mount.ps1` — `Measure-Object -Property` emits NOTHING for empty
  input, so the inline `.Sum` threw on an empty cache dir.

NOT added, on purpose: `WindowsFlutter.Common.psm1` and
`WindowsContainerLog.Common.psm1` (a module does not inherit its caller's strict
mode, so adding it is a real behaviour change downstream), and the dot-sourced
`Initialize-CiEnvironment.ps1` / `litert-lm-export-bridge.ps1` (strict mode
would leak into every caller).

### Two helper sets pushed down to their leaf modules

`Write-AssembledWheelDistInfo` and `Get-PyprojectDependencies` moved off the
`WindowsSourceBuild.Common.psm1` facade — mounted into all 11 media RUNs — into
`WindowsTvm.Common.psm1`, the `tvmmods` leaf only media-tvm mounts. Their sole
consumer is `build-tvm-from-source.ps1`.

The GStreamer wrap-git prefetch plus the libffi force-download (~64 lines of
phase 5) moved out of `build-gstreamer-from-source.ps1` (1575 → 1514 lines) into
`Invoke-GstWrapProvisioning` in `WindowsMeson.Common.psm1`, the merge-lane leaf.
It takes a `-Logger` scriptblock, accumulates failures in a LOCAL list and
RETURNS them; the caller keeps the #88 fail-closed throw so that gate stays
visible at the call site (inside a module `$script:` is MODULE scope, so a
caller reading its own accumulator would have seen zero failures). The libffi
version expression deliberately stayed in the stage script:
`SourceBuild.PinParity`'s W1c scanner keys the pin site by FILE NAME. New suite:
`SourceBuild.GstWrapProvisioning.Tests.ps1` (3 tests).

### `Assert-ShimPatch`'s fail-closed test could only pass on a host without Stevedore

The backlog #48 "throws when no shim is installed" test pointed at a missing
path, but the fallback probe then found the REAL shim under the Stevedore bin
root and the not-found branch never ran — so the test could only pass on a
machine that had never installed the toolchain, i.e. never on a build host.
`Assert-ShimPatch` gained an injectable `-AlternateRoot` (default unchanged);
`BuildDriver.HostGates.Tests.ps1` passes `-AlternateRoot @()`.

### Left standing on purpose

`Get-LlvmMasmCmakeArg` and four facade re-exports are dead in-tree but are
exported API for other Kataglyphis repos — the never-delete-on-a-zero-reference
audit rule in `docs/windows-builds.md`. `Export-BuildHandoff` /
`Import-BuildHandoff` stay on the facade because `bk-warm.ps1`'s header names
them the TESTED ROLLBACK PATH (restore the warm/materialize targets from
c9586c1^ and the payloads work unchanged) — but that recipe is ALREADY partially
stale: those retired targets mount the pre-#134 module set with no
`WindowsTvm.Common.psm1`, and `build-tvm-from-source.ps1` now throws without the
`tvmmods` mount. Worth repairing before anyone needs the rollback.
`.claude/settings.local.json` still holds 4 allowlist entries for `build.ps1`
invocations — permission config is the owner's call: flagged, not changed.

Docs: AGENTS.md rule 5(b) and the module-tier prose in `docs/windows-builds.md`
and `docs/windows-refactor-backlog.md` carry the per-file mount rule and the
one-driver reality; the in-tree headers listed above were corrected with the
code. Housekeeping: this file is past 2,300 lines against the "~700 lines"
archive rule in its own header — the split is a separate decision, not taken
here.


## 2026-08-31 — QNN SDK integrated into the arm64 cross build (#121 proven) + GStreamer compiler-rt self-heal (#135 follow-up)

### QNN EP build-time path PROVEN on the arm64 cross lane (#121)

The staged QAIRT SDK (qairt-2.44.0.260225, SHA-pinned) was exercised end-to-end
for the first time on a full `-TargetArch arm64` cross run:

- `Resolve-QnnSdk` verified the SHA, extracted the SDK and enabled
  `onnxruntime_USE_QNN=ON` with the `aarch64-windows-msvc` backend set
- ONNX Runtime built the QNN provider (symbol file `['cpu', 'qnn', 'dml']`),
  `QNN_SDK_ZIP_SHA256` forwarded driver → Dockerfile ARG → ENV → build script
- The run reached the merge stage (the last arm64 acceptance gate); the only
  failure was the unrelated GStreamer link below

### GStreamer cross-lane compiler-rt self-heal (#135 follow-up)

`C:\llvm-patched` (the source-built default toolchain) ships
`clang_rt.builtins-x86_64.lib` only, so the arm64 GStreamer link died on
`__udivti3` in the merge stage. `build-gstreamer-from-source.ps1` § 5d now
self-heals on the cross lane: it mines `clang_rt.builtins-aarch64.lib` from the
official LLVM release archive next to the x86_64 lib (same recipe as
`setup-scoop-tools.ps1`), then re-runs its candidate search. The first live
attempt used the GNU tar on PATH, which parses `C:\...` as a remote-host spec
("Cannot connect to C:") — the extract now forces System32's bsdtar (the same
trap build-llvm-from-source.ps1 already avoids). Chosen over adding the lib to
the toolchain layer because the media branches derive FROM
`bk-windows-toolchain` — that would have re-paid ~2 h of media compiles for one
lib. Regression test: `SourceBuild.GstreamerCompilerRt.Tests.ps1` (4 tests).
Docs: `docs/windows-cross-builds.md` § aarch64 compiler-rt;
`docs/windows-refactor-backlog.md` #135 follow-up.

The compiler-rt fix unmasked the speculative cross-lane opus intrinsics
enablement (added 2026-08-30), which had never reached a real compile: the RTCD
path applies `-mfpu=neon` (ARM32-only; clang-cl rejects it for aarch64) and its
CPU probe `celt/arm/armcpu.c` uses MSVC's `__emit` (absent from clang-cl).
REVERTED to the proven 2026-08-26 shape — `-Dopus:intrinsics=disabled` on both
lanes; the working enablement recipe (`intrinsics=enabled` + `rtcd=disabled`,
which needs a real-device smoke because it presumes NEON+dotprod) is recorded in
`docs/windows-cross-builds.md` and the backlog. Regression test extended to 6
assertions.

The arch-gate import walk then flagged the staged QNN runtime: the QAIRT HTP
stub DLLs import `libcdsprpc.dll`/`libadsprpc.dll` — Qualcomm's FastRPC
drivers, which ship in every Windows-on-Snapdragon OS image (never in the SDK
zip). Added to the gate's client-OS allowance (`ClientOsPattern`); regression
assertion in `SourceBuild.VerifyTargetArch.Tests.ps1`.


## 2026-08-31 — WSL2 RAM tuning: host gets ~20 GB back; 27B loads on GPU but stays impractical

The GenieX models run on the Windows host, but the host `.wslconfig` had capped
WSL2 at **30.3 GB of 31.6 GB**, and WSL contained ~4.3 GB of orphaned dead
weight. Both fixed:

- `.wslconfig`: `memory=10GB` + `autoMemoryReclaim=gradual` + `swap=4GB`
  (backup of the old file kept). WSL now reports ~9.7 GB total; the Windows
  host went from ~2 GB free to **~18–21 GB free**.
- WSL cleanup (elevated commands, documented): rootful `containerd.service`
  stopped+disabled (killed orphaned Elasticsearch + Collabora containers,
  ~2.5 GB) and `pkill` of orphaned clamd/freshclam + postgres (~1.1 GB).
  Containers from a running compose (llm-stack glances) kept.
- **What the RAM buy actually gives:** the 27B Q3_K_XL (13.1 GB) now *loads* on
  the Adreno GPU (was `CL_OUT_OF_RESOURCES`), but generation is still
  impractical there — 2.0 tok/s, 9.1 s first token, and the server hung under
  the first real request (HTTP 000, 14.4 GB RSS, killed to release RAM). The
  honest bottom line is now in the docs: on this machine, the GPU serves up to
  the 9B-Distill; the 27B stays CPU territory; the NPU serves 2B/4B fastest.
- New docs section "Making room: WSL2 RAM tuning" in
  [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md): the
  `.wslconfig` cap + `autoMemoryReclaim`, the elevated cleanup commands, and
  the reality check (what freed RAM did and did not buy).

## 2026-08-31 — hybrid actually measured: 9B distill runs at 7.5 tok/s (faster than GPU)

Tested `--compute hybrid` against every Qwen3.8-class model on this Snapdragon
X, with the surprise that **hybrid is the right path for models that straddle
the HTP budget**:

- **Qwen3.8-9B-Distill Q4_K_M (5.78 GB)** does not fit the ~3 GB HTP alone but
  runs on `--compute hybrid` at **7.5 tok/s — faster than the same model on the
  GPU (6.5 tok/s)**. Hybrid offloads the layers that fit the HTP and runs the
  rest on CPU.
- **Qwen3.8-27B Q4_0 crashes on hybrid too** (like pure NPU): the single HTP
  cannot even stage a fraction, so there is no partial-offload win. 27B stays
  CPU-only territory (or GPU Q3_K_XL at degraded quality).
- Full measured envelope table added to
  [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md): NPU
  16.9 (2B) / 15.2 (4B), hybrid 7.5 (9B), GPU 13.2 (4B) / 6.5 (9B). CPU numbers
  for 2B/4B/9B are marked as estimates; NPU/GPU/hybrid are all measured.
- Bottom line: **no single model combines GPU+NPU** (hybrid = NPU+CPU only);
  you cannot add the GPU to hybrid. Docs now state this plainly and recommend
  2B-Distill (NPU) / 4B (NPU) / 9B-Distill (hybrid) per task weight.

## 2026-08-31 — hybrid compute truth + Qwen3.8 model matrix

Clarified what GenieX v0.5.0 can and cannot do with all three accelerators, and
which Qwen3.8-class models fit this Snapdragon X — all verified live:

- **`--compute hybrid` is the per-tensor NPU scheduler, NOT "GPU+NPU at once".**
  The device alias resolves to `DeviceID:""` + `ngl != 0`, which the llama_cpp
  plugin classifies as NPU; the HTP runs the layers that fit and CPU takes the
  rest. Measured 14.1 tok/s on the 4B (pure NPU: 15.2). A single model runs on
  HTP(+CPU fallback) or GPU, never both simultaneously.
- **Multi-HTP device lists** (`--compute HTP0,HTP1,...` + `GGML_HEXAGON_NDEV`)
  spread a model across several HTP cores — but this X126100 has a single HTP
  (hwinfo `threads 4, hvx 4, hmx 1`), so the list degenerates to one device.
- **QAIRT bundles are NPU-only** — `--compute cpu/gpu` on one is coerced back
  to NPU with a warning.
- **Run both accelerators at once**: one `geniex serve` binds one default
  compute; run a second server on another port (`--host 0.0.0.0:18182`) and
  point the agent at the right base URL per model.
- **Qwen3.8 model matrix** (verified): `Qwen3.8-2B-Distill` Q4_K_M 1.31 GB →
  NPU 16.9 tok/s (fits ~3 GB HTP); `Qwen3-4B` Q4_0 → NPU 15.2 / GPU 13.2;
  `Qwen3.8-9B-Distill` Q4_K_M 5.78 GB → GPU only (over HTP budget);
  `Qwen3.8-27B` → CPU territory (see quant ladder); `Qwen3.8-Flash-Next` too
  large for this class of machine. Docs updated with the matrix and an
  NPU-first opencode provider example.

## 2026-08-31 — GenieX NPU FIXED by a Qualcomm Hexagon NPU driver update + NPU probe

**The NPU now works.** Updating the Qualcomm Hexagon NPU driver
(`libcdsprpc.dll` 30.0.0140.1000 → 30.0.0220.3000; Hexagon NPU device driver
30.0.220.3000, installed via Windows Update optional driver updates + reboot)
fixed both NPU backends. Root cause (documented in
[`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md) § The NPU
problem): the old driver's `libcdsprpc.dll` exported only the legacy FastRPC
API, not the `dspqueue_*` symbols GenieX v0.5.0's bundled llama.cpp
`ggml-hexagon` backend dlsyms (`dspqueue_create` etc. — verified per-symbol
with `GetProcAddress`). QAIRT/QNN showed a different symptom of the same root
cause: `Exception 0xc00000fd` (STATUS_STACK_OVERFLOW) in HTP runtime init.

- Measured after the fix: **4B on NPU at 15.2 tok/s (0.2 s first token)** —
  faster than the Adreno GPU (13.2 tok/s) and far faster than CPU. Verified
  end-to-end through the OpenAI server from WSL2.
- Remaining limit: the Hexagon HTP has ~3 GB vmem (`vmem 3145728000` in the
  load log), so the 27B fails at graph compute with `dspqueue_read failed:
  0x00000072` — a memory limit, not a driver bug (same class as
  ggml-org/llama.cpp#26123).
- New probe `windows/scripts/diagnostics/probe-geniex-npu-driver.ps1`: checks
  the **active** CDSP `libcdsprpc.dll` (matched by Hexagon-NPU device driver
  version, so stale DriverStore copies cannot falsify the verdict) for the
  `dspqueue_*` symbols. Reporting-only, never throws on a negative. Documented
  in `docs/windows-builds.md` § Script Reference.
- Docs updated: measured envelope now NPU-first; troubleshooting table covers
  the pre-fix `dlsym` failure, the QAIRT stack overflow, and the post-fix HTP
  memory limit.

## 2026-08-31 — GenieX on-device OpenAI server for Snapdragon (docs + host tooling)

New page [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md):
run Qualcomm GenieX (BSD-3-Clause) so a coding agent inside **WSL2** talks to a
local OpenAI-compatible API backed by the Windows host's **Adreno GPU** (or
Hexagon NPU). WSL2 has no NPU/GPU passthrough, so the server runs on Windows
and WSL2 reaches it at `127.0.0.1:18181` via mirrored networking.

- Deployed and measured live on a Lenovo Snapdragon X (2026-08-31): GPU 4B at
  13.2 tok/s, clean output, verified end-to-end through the OpenAI API; the
  27B's usable quant window on the Adreno is ≤ ~13 GB (Q4_0 @ 16 GB OOMs with
  `CL_OUT_OF_RESOURCES -5`; IQ3_S @ 12 GB loads but 3-bit quality is unusable —
  whitespace output).
- **NPU root cause documented** (not just "broken"): both NPU backends fail
  against the installed Qualcomm CDSP/FastRPC driver (1.0.4175.2700,
  20.11.2024; `libcdsprpc.dll` v30.0.0140.1000):
  - llama.cpp Hexagon backend: `failed to dlsym dspqueue_create` — the driver
    exports only the older FastRPC API (`remote_handle_open`), not the
    `dspqueue_*` symbols the bundled backend needs (verified per-symbol).
  - QAIRT/QNN backend: `Exception 0xc00000fd` (STATUS_STACK_OVERFLOW) in the
    QNN v2.45.0 HTP runtime init — same stale-driver family, different symptom.
  - Fix is a **Qualcomm CDSP/FastRPC driver update** (Windows Update optional
    updates / Lenovo driver page); GenieX v0.5.0 is already the latest release.
    Until then `--compute gpu` is the working accelerated path.
- Also handled: SoX install + user-PATH for the serve warning; non-interactive
  chipset config (`geniex config set chipset qualcomm-snapdragon-x-elite`);
  local cache copy across Windows/WSL2 to avoid re-downloading 16 GB; the WSL2
  localhost port-shadowing trap that prevents the Windows server from binding.
- Docs wiring: `docs/INDEX.md`, `docs/index.rst` (toctree), `README.md`,
  `AGENTS.md` § GenieX on Snapdragon, and a `deps.json` entry under Host Build
  Infrastructure (BSD-3-Clause) — licence pages and curated SBOM regenerated.

## 2026-08-30 — rebuild window: GCC_PARALLEL_TARGETS validated (2 bugs found+fixed), F2 media validation, launcher server-death gap fixed

The tasks that needed a real rebuild, run and closed:

### GCC_PARALLEL_TARGETS validation — PASS, and it surfaced two real bugs

- **92fb9646 — the launch flag was silently dropped (the real "missed four
  times" cause).** No `ARG GCC_PARALLEL_TARGETS` in Dockerfile.toolchain and no
  `--build-arg` in the compiler-stage args, so a launch-time
  `GCC_PARALLEL_TARGETS=1` never reached the container and the sequential path
  won every time. Fixed: ARG + ENV in Dockerfile.toolchain (mirrors
  `GCC_HOST_BOOTSTRAP`), `append_optional_build_arg` forwarding in
  stage-defs.sh's compiler case (only when set; Dockerfile defaults stay
  authoritative), pinned by test-stage-defs.sh. Dry-runs now emit
  `--build-arg GCC_PARALLEL_TARGETS=1` when set, absent when not.
- **5e8b2470 — the first parallel launch collided on the dpkg apt lock.**
  The concurrent per-target `build-gcc.sh` invocations each ran their own
  "Installing build dependencies..." apt_install; two apt-get at once die on
  `/var/lib/apt/lists/lock`. Fixed: `GCC_SKIP_BUILD_DEPS=1` gates build-gcc.sh's
  apt step (deps already installed by `build_host_gcc`, which runs first) and
  the parallel driver exports it after the serial pre-pass. Sequential path
  unchanged.
- **Result:** local compiler build with `GCC_PARALLEL_TARGETS=1` GREEN —
  amd64 linked serially, arm64 + riscv64 cross-GCC concurrent (JOBS=16 each),
  both OK; two cross targets in ~531s wall vs ~984s sequential (~30% GCC-RUN
  saving, as documented). Full toolchain smoke 41/41 PASS, image
  `cross-compiler-amd64` loaded. This also validated TG1/TG3 (trimmed per-RUN
  mounts) and F2's toolchain call sites (`sccache gcc/g++` live).
- Follow-up logged: the ERR-trap in logging.sh `_install_trap` fired with
  `action` unbound under set -u when triggered outside the function's dynamic
  scope, masking the real apt error. Not in this wave.

### F2 media validation — PASS (sdk→media→android, amd64)

Full chain from sdk pushed for amd64. The one-resolver cache consolidation was
exercised in every media RUN: `compiler cache enabled:
launcher=/opt/scripts/core/sccache-launcher.sh`, **100 % C/C++ cache-hit
rate**, 27 artifact-verify OK, android built and pushed. modules.sh reorder and
the QNN-off fan-out path (litert/tvm/app-wheelhouse/genai with no zip) all ran
the new code without regression.

### 0371d164 — sccache-launcher server-death gap FOUND live + FIXED

The validation build caught a second failure class the guarded launcher did
not handle: the sccache **server died mid-build** under full concurrent-media
load and sccache reported `sccache: error: failed to execute compile / caused
by: Failed to send data to or receive data from server / failed to fill whole
buffer`. The launcher only bypassed on `sccache: encountered fatal error` (the
TryCompile ENOENT class), so it handed the dead-server error to ninja as a REAL
failure and killed the TVM step. Fixed by widening the bypass classification to
any sccache-prefixed internal error (`sccache: (encountered fatal error|error:|
caused by:)`) — safe because sccache prefixes only its own failures with
`sccache:`; a real compiler error is echoed un-prefixed and passes through.
Pinned by the new tests/test-sccache-launcher.sh (8 assertions incl. a
mutation case proving the old narrow match would NOT have bypassed). The media
rebuild running after this lands re-validates the fix live and restores the
TVM wheel lost to the dead server (the failure was non-fatal by design).

### QNN-LINUX fan-out validation — BLOCKED on the login-gated SDK

The real QAIRT zip is not on the host (removed after the PROVEN build per the
qnn-sdk README discipline; /tmp/qnn-sdk-extract now holds only a synthetic test
stub). Re-staging is the owner's move (qpm.qualcomm.com, EULA), then re-pin
`QNN_SDK_LINUX_ZIP_SHA256`. The no-zip fail-safe path across every framework
was validated by the media builds above.

## 2026-08-30 — second pass: --no-push chains SAFE (OCI-layout handoff) + source_module recursion fix

Backlog item C is closed: **full `--no-push` chains are no longer refused** —
every stage built locally is exported to an OCI layout and handed to the child
via `--build-context <parent-tag>=oci-layout://<dir>`, so a child's FROM never
resolves against the registry (the 2026-08-08 stale-parent bug). The android
image is additionally exported for the runtime lane, and the mid-chain resume
case stays refused (no locally-built prefix to serve).

- `01-core/cross-stage-build.sh` — `cross_local_handoff_enabled()`,
  `cross_ensure_local_context_workdir()` (per-run
  `${CROSS_CONTEXT_ROOT:-~/.cache/opencode/cross-stage-contexts}/cross-flow.*`,
  age-based orphan sweep), `cross_stage_context_dir()`; parent resolution in
  `_cross_stage_run_resolve_parent` appends the `--build-context` when the
  parent was built this run; `cross_stage_run` exports every local stage after
  the build, and android to `<workdir>/android-artifacts/<arch>`.
- `build-cross-chain.sh` — guard relaxed (full chain allowed, mid-chain
  refused; `CROSS_LOCAL_CONTEXT_HANDOFF=0` reverts, `CROSS_NO_PUSH_FORCE=1`
  bypasses), parse-time message + `--no-push` usage text updated,
  `run_runtime_stage` passes `ARTIFACT_CONTEXT_ROOT`+`ARTIFACT_CONTEXT_MODE=oci`
  to the helper under `--no-push`, `_chain_on_exit` reclaims the workdir.
- `01-core/modules.sh` — `source_module` resolves FRAMEWORK dirs before
  `${caller_dir}/${name}`. The old order made a bare
  `source` of ONNX's `build/lib/common.sh` (SCRIPT_DIR unset) resolve
  `source_module "common.sh"` to that very file — an infinite re-source loop
  ending in a stack-overflow SIGSEGV. All `source_module` names are 01-core
  modules, so the caller-local slot is now only a last resort.
- New suites: `tests/test-cross-oci-handoff.sh` (15 assertions — parent-context
  append, registry fallback when unbuilt, push=1 never, guard matrix incl.
  mutation-style refusal cases) and `tests/test-module-resolution.sh`
  (5 assertions — order, the ORT recursion shape under timeout, caller-local
  last resort; mutation-verified against the pre-fix `modules.sh`: 3/5 fail).
- Live-proven on the host: two-stage test build — stage B's `FROM` resolved
  from the exported layout (`--pull=false`, content marker verified), never
  the registry.
- Docs: AGENTS.md quick-ref, `docs/linux-cross-builds.md` § "--no-push full
  chains: FIXED", backlog C closed, archive entry.

## 2026-08-30 — Backlog sweep: F-entries closed (OpenCV-sccache refuted), one-resolver cache consolidation, QNN-LINUX fan-out wired

Three parallel threads, one day: the two remaining F-section items are gone
from the open backlog, the cache launcher resolution has exactly one resolver,
and the QNN-LINUX framework fan-out (GenAI/LiteRT/TVM/IREE) is wired on the
shared SDK module — all fail-safe by construction (no zip = byte-identical
existing behavior).

### OpenCV-sccache entry REFUTED, F2 DONE (docs/refactoring-backlog-archive-2026-08-30.md)

- **"sccache caches NOTHING in the OpenCV step" — closed by REFUTATION.** Log
  forensics on the staged-media* and media-arm64 logs showed the 2359 bypass
  messages the entry cited were the pre-UDS wrong-server bug (concurrent
  BuildKit steps reaching each other's sccache server on the fixed TCP port;
  `caused by: No such file or directory (os error 2)` — exactly what
  docs/build-cache-tiers.md § 5.1 already recorded as fixed by
  b4078ad1 + 4aa92fb6), and that the faults appeared in the ORT step too —
  not OpenCV-exclusive as claimed. Every post-UDS run has 0 bypass messages,
  including the 2026-08-30 QNN-LINUX arm64 media build, where OpenCV compiled
  all 1660 objects through the launcher and the sibling ffmpeg step recorded a
  99.64 % hit rate. No code change needed; the misdiagnosis is archived with
  the evidence so it is not re-discovered.
- **F2 — compiler-cache abstraction consolidation: DONE.** New
  `_resolve_compiler_cache_launcher()` in `01-core/compiler-cache.sh` routes
  every launcher decision through common.sh's `compiler_cache_launcher()`
  (all media/ORT callers) with an inline bootstrap fallback for the android
  preamble, which sources compiler-cache.sh standalone. Both paths implement
  the identical decision (guarded launcher > sccache > ccache, never empty);
  `setup_ccache` and `setup_sccache` both consume it; the
  verify-critical-fixes.sh gate still passes without edits. Pinned by the new
  suite `linux/scripts/tests/test-compiler-cache.sh` (8 assertions, incl.
  mutation checks and the "Rust keeps sccache-class on a ccache verdict"
  property). Behavior-identical by construction; a media run validates the
  stats lines.

### QNN-LINUX framework fan-out WIRED (validation build pending)

- **NEW `01-core/qnn-sdk.sh`** — shared QAIRT resolution + runtime staging,
  moved out of ORT's lib/common.sh (which now sources it and hard-requires the
  two functions). Unit-tested end-to-end against a synthetic QAIRT zip:
  resolution, sha256 verification, `libQnn*.so` + `hexagon-v*` staging, and
  the arm64/no-zip gates.
- `03-media/core/common.sh` — `media_common_init` loads `qnn-sdk.sh`
- `60-build-genai.sh` — stage QNN backend libs beside the GenAI install
- `build-litert.sh` — `TFLITE_ENABLE_QNN=ON -DQNN_HOME=<home>` + NPU=ON when
  a zip is staged (else the NPU=OFF/`QNN=OFF` defaults), in BOTH the cmake
  configure and the wheel `EXTRA_CMAKE_FLAGS`, plus post-install staging
- `tvm-config.sh` / `tvm.sh` — `USE_QNN=ON -DQNN_HOME=<home>` (else explicit
  `-DUSE_QNN=OFF`) in `append_tvm_cmake_args`, post-install staging in main;
  `tvm.sh` loads the module
- `build-app-wheelhouse.sh` — `IREE_TARGET_BACKEND_QNN=ON -DQNN_HOME=<home>`
  (else `OFF`); no runtime staging on Linux (wheel-only cross lane)
- `Dockerfile.media` — `linux/qnn-sdk` bind mount added to the litert, tvm
  and app-wheelhouse RUNs (was cpu/genai only)
- Every path is gated on a staged zip: no zip = today's behavior byte-for-byte
  (verified per-arch by the module tests). The validation build (staged QAIRT
  v2.49 on arm64) answers whether all five flags stay green and the libs land.


## 2026-08-30 — QNN-LINUX: Qualcomm QAIRT/QNN EP wired + PROVEN for Linux ARM64 (Snapdragon)

Wired the ONNX Runtime QNN execution provider onto the Linux `arm64` lane,
targeting Snapdragon NPU inference. Same opt-in contract as the Windows QNN
EP (#121): login-gated SDK zip dropped by hand in `linux/qnn-sdk/`; no zip =
QNN off with a notice. Different SDK from Windows: Linux AArch64 extracts to
`lib/aarch64-oe-linux-gcc11.2/`, not `aarch64-windows-msvc`.

**PROVEN on real SDK (2026-08-30):** staged QAIRT v2.49.0.260730,
`cross-media-arm64` build GREEN. `libonnxruntime_providers_qnn.so` compiled
and linked; 45 `libQnn*.so` backend libs + 7 `hexagon-v*` skel dirs staged
beside ORT; `verify-media-artifacts.sh onnxruntime-cpu` PASS; smoke suite 0
failures. The upstream QNN_ARCH_ABI risk is RESOLVED: ORT CMake accepts
`-DQNN_ARCH_ABI=aarch64-oe-linux-gcc11.2` (cache var, not hardcoded).

- `linux/qnn-sdk/README.md` — opt-in drop point + contract
- `.gitignore` — `linux/qnn-sdk/*` rule (symmetric with `windows/qnn-sdk/*`)
- `versions.env` — `QNN_SDK_LINUX_ZIP_SHA256` pinned to the staged zip's sha256
  (`32de9b5b...`, `# noforward`)
- `onnxruntime/build/lib/common.sh` — `resolve_qnn_sdk` (locate/verify/extract
  the SDK, QNN_OP_STFT canary) + `stage_qnn_runtime` (copy `libQnn*.so` +
  `hexagon-v*` skel beside ORT install). `info()` redirected to `stderr` (>&2)
  inside both functions to keep `$(...)` capture clean.
- `30-build-native.sh` — `resolve_qnn_sdk` called after oneDNN block; if
  arm64 + zip present, appends `onnxruntime_USE_QNN=ON` +
  `onnxruntime_QNN_HOME=<root>` + `QNN_ARCH_ABI=aarch64-oe-linux-gcc11.2`;
  stages runtime after finalize
- `Dockerfile.media` — `linux/qnn-sdk` bind-mounted at `/opt/scripts/qnn-sdk`
  on the `--step cpu` and `--step genai` RUNs
- `verify-media-artifacts.sh` — `onnxruntime-cpu` stage: if QNN provider .so
  is present, asserts `libQnn*.so` are staged beside it
- `docs/linux-cross-builds.md` — QNN EP section in the toggles area
- `docs/refactoring-backlog.md` — `A2. QNN-LINUX` items 1-6 DONE+PROVEN;
  framework fan-out (GenAI, LiteRT, TVM, IREE) OPEN
4a3f379c05bd3affa3d9b2550f1b2cb4f9b3


## 2026-08-29 — #135 closed: patched LLVM is default, workarounds removed

### `BUILD_PATCHED_LLVM=1` is now the DEFAULT (#135 item 1+3 DONE)

The patched clang toolchain (llvm#219275 + #219276, the `EH_LABEL` size fix) is
now the default toolchain. Changes:

- `Dockerfile.toolchain-builder`: `ARG BUILD_PATCHED_LLVM=0` → `1`
- `build-buildkit.ps1`: `patched-llvm` is the default target; new `-StockLlvm`
  switch opts out (for patch debugging only); `-PatchedLlvm` kept as a no-op
  for backwards compatibility
- `build-opencv-from-source.ps1`: both AArch64 workarounds REMOVED — the
  `+force-32bit-jump-tables` flag and the per-TU `/Ob1` pass for
  `median_blur.dispatch` / `multiview_calibration`. The patched toolchain fixes
  the root cause (EH_LABEL under `/EHa` emits a 4-byte nop counted as zero by
  `getInstSizeInBytes`).
- `BuildKit.PatchedLlvm.Tests.ps1`: updated for the new default
- `SourceBuild.CrossHelpers.Tests.ps1`: removed the /Ob1 selector test (the
  selector it tested no longer exists)
- `docs/failure-modes.md`: updated the AArch64 codegen section — root cause
  found, workarounds removed, patched toolchain is the fix


## 2026-08-29 — amd64 acceptance build GREEN (#134 closed)

### #134 amd64 acceptance PASSED — three build fixes

The amd64 rebuild verified the `TVM_COMMIT` LLVM 23 fix and closed #134.
Smoke gate: **192 passed / 0 failed / 1 skipped**. Arch gate: **1134/0**.

Three bugs surfaced during the build, all fixed:

1. **`Invoke-GitClone` commit-hash support** — `git clone --branch <hash>`
   fails for commit hashes ("Remote branch not found"). Added commit-hash
   detection: clone without `--branch`, then `git fetch --depth 1 origin <hash>`
   + `git checkout <hash>`. Mirrors the Linux lane's tvm.sh approach.

2. **`SETUPTOOLS_SCM_PRETEND_VERSION` for TVM_COMMIT** — when `TVM_COMMIT`
   (a 40-char hash) wins over `TVM_REF` (a tag), the pretend-version was set
   to the hash, which crashes `packaging.version.InvalidVersion`. Now falls
   back to the tag's version (`0.26.0`) when the resolved version is a hash.

3. **`ARCH_GATE_MIN_INSPECTED` amd64 floor** — 950 was calibrated against the
   PE-binary count (1134) but the same value gates the import-walk count
   (701). Same miscalibration that was fixed for arm64 (840→580). Corrected
   to 650.

4. **Smoke section 10 CPU floor** — floor was 5 but the CPU lane produces
   exactly 4 assertions (the 5th is a GPU-only CUDA check). Corrected to 4.


