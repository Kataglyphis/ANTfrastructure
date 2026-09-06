# Windows cross builds (arm64)

The Windows twin of [`linux-cross-builds.md`](linux-cross-builds.md). It covers the
`aarch64-pc-windows-msvc` target lane: why it is shaped the way it is, what it can and cannot
produce, and which gates keep it honest.

> **Status — re-measured 2026-08-28 (arm64 acceptance run `bk-20260828-171914`).**
> The current tree — module-closure refactor (#134), forced clang-cl 23.1.0,
> per-TU AArch64 codegen workarounds (#135) — built end to end and reached
> RUNTIME PARITY with `:winamd64`. Every gate below hit its target on the
> current HEAD. Nothing the lane produces has ever been *executed* — wheels
> ship staged, not installed, and every verdict is a static check.
>
> **The amd64 lane had a TVM-vs-LLVM-23.1.0 blocker, now fixed (needs rebuild).**
> The Windows build used the tag (`v0.26.0`) without the LLVM 23 guards; it now
> uses `TVM_COMMIT=994e0216` (upstream main, with the guards). See
> `docs/windows-refactor-backlog.md` #134.
>
> Same media and inference surface: GStreamer with
> an identical plugin set (200 linked plugin DLLs, all six contract plugins incl. `webrtc`/`nice`,
> plus `gst-ptp-helper`), ONNX Runtime + GenAI with DirectML, OpenCV 5 (NEON dispatch:
> `NEON_DOTPROD NEON_FP16 NEON_BF16`), FFmpeg with NEON asm + PyAV, LiteRT with the `tflite`
> plugin, and the TVM/IREE **runtimes together with their python packages** — 6 wheels, the same
> count as amd64.
>
> | Gate (arm64 `bk-20260828-171914`) | Result | amd64 (run 8, blocked at TVM) |
> | --- | --- | --- |
> | PE arch gate over `C:\runtime` + host site-packages | **992 inspected / 0 violations** | 1134 / 0 |
> | Import walk (`-ImportWalk`, unpacks staged wheels) | **606 walked / 0 unresolved** (3 allowlisted, 6 device-OS) | report-only |
> | Target python deps | **12 wheels / 0 unresolved requirement edges** | installed natively |
> | Mandatory GStreamer plugins | **6 / 6** | 6 / 6 |
> | Smoke | 97 passed / 0 failed / 15 skipped (floors 66/25) | 222 / 0 / 0 |
>
> **Absent by construction, each named inside the bundle** (`ABSENT-ON-ARM64.txt` /
> `COMPILER-ABSENT-ON-ARM64.txt`): the TVM and IREE **compilers** and `iree.compiler` — they need
> an LLVM cross-built for aarch64-windows, with no upstream precedent (PyPI ships `win_amd64`
> only); **LiteRT-LM**, whose active Bazel path has no windows-arm64 config and default-links an
> x86_64-only prebuilt (upstream's CMake path with its constraint-provider stub is an unattempted
> port, backlog #133(d)); **CUDA/cuDNN/TensorRT**, which do not exist for Windows-on-ARM (#122);
> and the **torch app stage**, because `uv sync` must execute the target interpreter. Two
> GStreamer pieces are absent on BOTH lanes and so are not parity gaps: the optional `gdkpixbuf`
> plugin (arm64: `glib-compile-resources`; amd64: `rst2man`) and anything needing `cargo-cbuild`.
>
> **Never verified — the asymmetry that outranks every number above:** no arm64 binary produced
> by this repo has ever been *executed*, anywhere. Its wheels ship **staged, not installed**; the
> smoke gate runs only host-toolchain sections (1-6, 14-16, 19, arch-filtered), and sections
> 14/15 compile **for** the target and assert the produced PE machine rather than run anything.
> A green build proves the code compiles and links for the target, and nothing more. The
> `windows-11-arm` runner remains the only path to execution proof; the repo owner declined one.
>
> How the lane got here, run by run (#116, #128, #131, #133 narratives, including the three meson
> build-only-subproject defects and the seven fix-and-rerun cycles of the runtime-python work):
> [`windows-backlog-archive-2026-08-26.md`](windows-backlog-archive-2026-08-26.md). Open items:
> [`windows-refactor-backlog.md`](windows-refactor-backlog.md).

## The constraint everything follows from

**There is no arm64 Windows container base image, and there is no arm64 Windows Server.**
`mcr.microsoft.com/windows/servercore` and `nanoserver` are published for amd64 only; Microsoft's
tracking issue ([Windows-Containers#586](https://github.com/microsoft/Windows-Containers/issues/586))
closed without one.

So the question "build an arm64 Windows image" has no answer. What this lane does instead:

- The build **host** and container stay `windows/amd64`.
- Only the compile **target** changes, via `clang-cl --target=aarch64-pc-windows-msvc` + `lld-link`.
- The product is a **versioned artifact bundle** (import libs, DLLs, headers), consumed on real
  ARM64 Windows hardware — not a runnable container.

Two corollaries worth stating plainly, because both have already been guessed wrong:

1. **Never tag or push the output with `--platform windows/arm64`.** The image carrying the
   payload is a `windows/amd64` image; an arm64 platform descriptor on it produces a manifest
   nothing can run, and someone will `pull` it onto a Windows-on-ARM box and file a bug.
2. **arm64 binaries cannot execute on the build host.** Windows x64 has no ARM64 emulation (only
   the reverse). Every "run it and see" smoke in `Test-Container.ps1` is unavailable here,
   which is why the static gates below carry so much weight.

## Why clang-cl makes this cheap

The whole Windows media chain already builds with **Ninja + clang-cl + lld-link** and explicit
`-DCMAKE_C(XX)_COMPILER=` — there is no Visual Studio generator anywhere in the tree
(`CMAKE_GENERATOR_PLATFORM` and `-A ARM64` have zero occurrences). clang-cl cross-targets aarch64
natively, so this lane is a **target-triple change, not a toolchain replacement**.

The rule is absolute: **clang-cl for every compile, lld-link for every link**, plus `llvm-lib`,
`llvm-rc`, `llvm-mt`, `llvm-readobj`. On arm64 that costs nothing extra, because the one place the
amd64 lane deliberately falls back to `cl.exe` — as **nvcc's host compiler**, since nvcc rejects
clang-cl — does not exist here: this lane ships no CUDA. (Windows-on-ARM CUDA is no longer
fiction — see the exclusion table — but wiring it is backlog work, and until then nvcc never runs
on this lane.)

**The MSVC ARM64 component is still required, but not for its compiler.** clang-cl targets the
MSVC ABI, so an aarch64 link needs Microsoft's ARM64 CRT and import libraries
(`VC\Tools\MSVC\<ver>\lib\arm64`), which ship only with
`Microsoft.VisualStudio.Component.VC.Tools.ARM64`. Its `Hostx64\arm64\cl.exe` rides along unused.
This is why `Install-Vs.ps1` and `Test-Toolchain.ps1` assert the **library** directories rather
than the compiler binary — a `cl.exe` probe would pass even when the libraries, the part that is
actually load-bearing, are absent.

## Vulkan needs an optional component

LunarG ships the aarch64 import libraries **inside the x64 Windows SDK**, but as an optional
component the default install does not select:

```
com.lunarg.vulkan.arm64   ARM64 binaries for cross compiling on Windows x86_64
Lib-ARM64 / Bin-ARM64     for cross compiling from Intel based development environments
```

scoop installs the SDK with the manifest's default component set, so a stock base image has **no**
`$VULKAN_SDK\Lib-ARM64`. `Install-ScoopTools.ps1` adds it explicitly through the SDK's Qt Installer
Framework `maintenancetool.exe`.

**That step warns, it does not fail — deliberately.** Every arm64 prerequisite in the base
(Vulkan `Lib-ARM64`, the MSVC `lib\arm64` CRT, the Windows SDK `um\arm64` libs) is checked
warn-only, because `base` is **shared by both lanes**: a hard failure over an arm64-only
prerequisite would block the amd64 build too, and the `maintenancetool` invocation has never yet
been executed against a real base image. An unverified installer call must not be able to kill the
chain's most expensive layer.

Set **`WINDOWS_ARM64_STRICT=1`** to turn them into hard gates — the same opt-in shape as
`CUDA_STACK_STRICT=1` on the Linux side. **All of them except one** (this sentence said "all"
until 2026-08-24, disagreeing with AGENTS.md): `Install-Vs.ps1`'s MSVC `lib\arm64` check runs in a
RUN that sits *above* the `ARG WINDOWS_ARM64_STRICT` declaration in `Dockerfile.base` and
therefore never sees the flag — that one check stays warn-only regardless. Use STRICT once the
arm64 lane is real; it is the flag that says "this image claims a complete arm64 toolchain".

It is plumbed as a real `ARG` in `Dockerfile.base` and forwarded as a script parameter. That
matters: a bare `$env:` read is unreachable from `docker build`, and buildctl silently discards
`--build-arg` for undeclared ARG names — an earlier version of this gate had an escape hatch that
could not actually be set from anywhere.

## Cache discipline: the base image is shared

`base` / `sdk` / `toolchain` install **host** tooling (VS, LLVM, scoop, vcpkg, rust, host CPython).
None of it is target-specific, so **one base serves both lanes** and the arch fan-out starts at
`media`:

```
base ─ sdk ─ toolchain ──┬─ media(amd64) ─ torch ─ final  → :winamd64  (image)
   (shared, x64 host)    └─ media(arm64) ───────────────  → winarm64 artifact bundle
```

Consequently **`WINDOWS_TARGET_ARCH` is never declared in `Dockerfile.base`, `.nvidia`, or
`.toolchain-builder`.** It first appears in `Dockerfile.media-builder`'s `common` stage. This is
the file's own documented ARG discipline (`Dockerfile.base` — "every RUN after an ARG declaration
keys its cache on the ARG's value"): declaring the arch ARG in base would re-pay the VS Build
Tools install — the chain's most expensive layer — on **every lane switch**.

For the same reason `WindowsTargetArch.Common.psm1` is COPY'd into base *below* the VS layer, in
the same group as `Test-Toolchain.ps1` — its only consumer there. The host provisioning scripts
(`setup-scoop-tools`, `setup-vcpkg`) spell their few arm64 facts inline and import just the three
modules that precede the VS layer. Placing the module higher invalidated scoop, vcpkg **and** the
~30-minute rust layer on every edit to a file whose whole point is that adding a target is a
one-line table edit.

The one-time cost is a single base rebuild for the VS ARM64 component + the Vulkan component.
**Batch them**, and see the sequencing warning below.

## Where arch facts live

`windows/scripts/modules/WindowsTargetArch.Common.psm1` is the single source of truth — the
Windows twin of `linux/scripts/01-core/arch-mapping.sh`. It maps, per target: clang triple,
VsDevCmd `-arch`, PE machine type, vcpkg triplet, MSVC lib/bin subdirs, Vulkan `Lib-ARM64`,
CPython `-p` platform and `PCbuild\<dir>`, wheel tag, rust triple, NuGet RID, ffmpeg `--arch`,
`lib /machine`, SIMD flag sets, and the CMake cross arguments.

Two behaviours are deliberate and tested:

- **An unknown arch throws.** Silently degrading to amd64 would emit an x64 build labelled arm64,
  which no downstream gate would catch.
- **`Get-CMakeCrossArgs` returns nothing for amd64**, so the existing lane's configure command line
  is provably unchanged. (Since 2026-08-24 the cross args also cover the **ASM** language —
  `CMAKE_ASM_COMPILER_TARGET` / `CMAKE_ASM_FLAGS_INIT`; see the LiteRT machinery section for the
  failure that forced it.)

It is re-exported through `WindowsSourceBuild.Common.psm1` on the same terms as
`WindowsNative.Common.psm1`, so build scripts get it with their usual import. **Ship it in every
Dockerfile COPY list that carries the module set** — an incomplete COPY list is a known failure
mode, guarded here by a throwing stub.

## SIMD: the failure that hides inside a green build

The kernel SIMD flags were never an ordinary flag helper's output. `Build-OnnxFromSource.ps1`
injects them **per-TU into `build.ninja` post-configure** — via `Get-WindowsTargetKernelSimdFlags
-Arch`; the old `Get-WindowsX86Avx512Flags` survives only as a zero-caller compat shim — onto
exactly the MLAS kernels matched by `Get-MlasKernelTuPattern`. Globally-enabled AVX-512 was field-proven to crash protoc
and `onnxruntime.dll`'s static initializers with `STATUS_ILLEGAL_INSTRUCTION`; entirely without
the flags those TUs fail to compile. Per-TU is the only correct answer, because the kernels are
runtime-dispatched.

**On aarch64 that x86 pattern matches nothing — and a patch that matches nothing succeeds.** The
build would go green with MLAS's NEON/dotprod/i8mm kernels compiled without their features:
unoptimised at best, absent at worst, and undetectable from the build host.

So the pattern is arch-parameterized (`Get-MlasKernelTuPattern`) alongside a **minimum match
count** (`Get-MlasKernelTuMinimum`), and `Build-OnnxFromSource.ps1` **throws** when the tagged-TU
count falls below that floor. The floor is the actual guard; the pattern alone is not — a warning
there would have preserved exactly the failure mode this exists to prevent.

**And on 2026-08-24 the amd64 lane demonstrated the same failure with the floor present but too
low.** The x86 pattern (`qgemm_kernel_amx|intrinsics[\\/]avx512`) predated ONNX Runtime v1.29.0,
which keeps six more AVX-512 kernel TUs directly in `mlas/lib/` (`q4gemm_avx512.cpp`, the
`sqnbitgemm_kernel_avx512*` family, `qkv_quant_kernel_avx512vnni.cpp`). The stale pattern matched
5 lines, the floor was 4, so `5 >= 4` sailed through — and five TUs then failed to *compile*
(`always_inline function '_mm512_set1_ps' requires target feature 'avx512f'`). The aarch64 pattern
had been re-measured against v1.29.0 on 2026-08-23; the amd64 one had not, and it was the amd64
regression run for the cross-lane changes that surfaced it. Fix: pattern extended with a
`\.cpp`-anchored third alternative (the anchor makes it structurally impossible to tag a MASM
`FLAGS` line — `-match` is case-insensitive and `lib/amd64/` is full of `*KernelAvx512*.asm`),
floor raised 4→8. The floor rule this hardens: **a floor only earns its keep if the previous
broken state would trip it** — the old pattern's 5 matches now fail an 8-floor loudly. Verified:
11 TUs tagged, all five previously failing TUs compiled, full media-core green on both lanes.

Note the asymmetry in the baseline flags: amd64 enables a broad SSE/AVX2 set globally, arm64
enables **nothing** globally. AArch64 already mandates NEON, and its optional features
(dotprod/i8mm/SVE) fault on hardware that lacks them — the same class of failure as AVX-512.
Optional AArch64 features belong only on dispatched kernels.

## Verification

With nothing runnable on the build host, verification is layered:

| Gate | Where | What it proves |
|---|---|---|
| `Test-Toolchain.ps1` arm64 section | base image | clang-cl emits aarch64 objects; MSVC/SDK/Vulkan arm64 libraries present |
| `Test-TargetArch.ps1` | any staged tree | every shipped `.dll`/`.exe` (optionally `.lib`) has PE machine `0xAA64`, with a **minimum inspected floor** |
| `TargetArch.Common.Tests.ps1` | `Invoke-Tests.ps1` | the arch table, the amd64 byte-identity guarantee, and the MLAS pattern behaviour |

The one gate that does **not** exist yet is native execution: a `windows-11-arm` CI job would be
the only proof the artifacts actually **run**. Until it exists, treat every arm64 output as
unvalidated — see the prose below.

`Test-TargetArch.ps1` is the Windows twin of the Linux lane's ELF check in
`validate-media-runtime.sh`. Three design points, each learned from a gate that could not fail:

- **A minimum inspected count.** A mis-pathed or empty tree otherwise passes green with zero files
  checked — the failure `Dockerfile.smoke-gate`'s `MIN_PASSED` floor exists for. Allowlisting
  everything therefore *also* fails, because it drives the inspected count to zero.
- **`.lib` archives are not PE files.** A naive `bytes[0x3C]` walk over a COFF archive reads
  whatever sits at that offset and can compare equal by accident. Archives are decoded from their
  first member header, including the short-import header form.
- **The host-tool allowlist is printed.** An over-broad allowlist is itself a defect, and the only
  way to notice is to see what it swallowed.

Usage:

```powershell
# strict: every binary must be arm64, at least 20 inspected
windows\scripts\build\Test-TargetArch.ps1 -Path C:\runtime -Arch arm64 -MinInspected 20

# permit genuinely host-arch build tools that never ship to the target
windows\scripts\build\Test-TargetArch.ps1 -Path C:\runtime -Arch arm64 `
    -HostToolPattern 'protoc\.exe|flatc\.exe|\\_deps\\'
```

Free native validation is available: this repo is public, so GitHub's `windows-11-arm` runners
cost nothing. They are Windows 11 **client**, not Server Core — a caveat to state rather than a
problem to solve, since no Server Core arm64 exists.

## Sequencing: rebuild base twice, on purpose

`Install-Vs.ps1` deliberately does **not** SHA-pin the VS bootstrapper (the installer refreshes
within a channel every few weeks; the hash is logged for provenance instead). Adding the ARM64
component therefore also pulls whatever newer VS servicing build is current — and any regression
it carries will look exactly like "the arm64 change broke the build".

**Rebuild the base with no change at all first, confirm it is green, and only then add the
components.** It is the single highest-value sequencing decision in this work.

## Upstream portability fixes this lane carries

None of these are configuration mistakes — they are code paths that **only compile on ARM**, so
no amount of amd64 testing could have surfaced them. Each is scoped to the cross branch so the
amd64 command line stays byte-identical. All were measured on 2026-08-23 against LLVM 22.1.8.

Of the OpenCV patches, **four are live and one is dead** (audited 2026-08-24): the `mlasi.h`
intrinsic remap below never compiles, because patch `003`'s `WIN32`-gated `return()` removes MLAS
from the OpenCV build before that header is ever reached. Its row stays as a record of a real
collision, flagged dead where it appears.

- [`/D_USE_MATH_DEFINES` (OpenCV)](#d_use_math_defines-opencv) · [`softfloat.cpp` typedef → macro (OpenCV)](#softfloatcpp-typedef--macro-opencv) · [`WITH_IPP=OFF`, `BUILD_IPP_IW=OFF` (OpenCV)](#with_ippoff-build_ipp_iwoff-opencv) · [`USE_DML=ON` (ONNX Runtime, and GenAI since #118), `WITH_DIRECTML=ON` (OpenCV) — all three initially OFF on this lane](#use_dmlon-onnx-runtime-and-genai-since-118-with_directmlon-opencv--all-three-initially-off-on-this-lane) · [`USE_CUDA=OFF` forced by **target**, not host (GenAI)](#use_cudaoff-forced-by-target-not-host-genai) · [Python bindings **ON** everywhere since #120 step 2 (2026-08-24 evening): ORT wheel, GenAI wheel, `cv2`, PyAV — built for the target, **staged, never imported**](#python-bindings-on-everywhere-since-120-step-2-2026-08-24-evening-ort-wheel-genai-wheel-cv2-pyav--built-for-the-target-staged-never-imported) · [`-mllvm -aarch64-enable-compress-jump-tables=false` (OpenCV)](#-mllvm--aarch64-enable-compress-jump-tablesfalse-opencv) · [MLAS skip re-gated on `WIN32` alone (OpenCV, patch `003`)](#mlas-skip-re-gated-on-win32-alone-opencv-patch-003) · [`mlasi.h` MSVC intrinsic remap guarded by `!defined(__clang__)` (OpenCV)](#mlasih-msvc-intrinsic-remap-guarded-by-defined__clang__-opencv) · [`have_sse`/`have_sse2` gated on `cpu_family` (gst-plugins-base)](#have_ssehave_sse2-gated-on-cpu_family-gst-plugins-base) · [Vulkan lib dir follows `host_machine` (gst-plugins-bad)](#vulkan-lib-dir-follows-host_machine-gst-plugins-bad) · [`-FIio.h` → assembly-safe shim (GStreamer)](#-fiioh--assembly-safe-shim-gstreamer) · [`--as=clang --target=aarch64-pc-windows-msvc` (FFmpeg)](#--asclang---targetaarch64-pc-windows-msvc-ffmpeg)

### `/D_USE_MATH_DEFINES` (OpenCV)

`hal/carotene`, OpenCV's ARM NEON HAL, is compiled **only** for ARM targets. It uses `M_PI`, which the C standard does not mandate and the MSVC CRT withholds unless this macro is defined — carotene assumes POSIX. Symptom: `phase.cpp(121,5): use of undeclared identifier 'M_PI'`.

### `softfloat.cpp` typedef → macro (OpenCV)

**Genuine upstream bug**, see below.

### `WITH_IPP=OFF`, `BUILD_IPP_IW=OFF` (OpenCV)

IPP is Intel's x86-only primitives library; no AArch64 build exists. OpenCV still resolved and unpacked `3rdparty/ippicv/ippicv_win`, putting its headers on every core TU's include path, and the staged `.lib` is x64 COFF that lld-link would reject against an arm64 image.

### `USE_DML=ON` (ONNX Runtime, and GenAI since #118), `WITH_DIRECTML=ON` (OpenCV) — all three initially OFF on this lane

**The original justification was wrong and is retracted:** the nuget *does* ship an arm64 import library. `Microsoft.AI.DirectML` 1.15.4 contains `bin/arm64-win/DirectML.lib`, a COFF import archive whose machine field is `0xAA64`. The real defect was a **case mismatch inside ONNX Runtime's own CMake**: `cmake/external/dml.cmake` declares the download's outputs with a lower-case `bin/arm64-win`, while `cmake/onnxruntime_providers_dml.cmake` composes its consumer paths as `bin/${onnxruntime_target_platform}-win` — and `onnxruntime_target_platform` is the verbatim, upper-case `ARM64`. The two spellings never meet, so the arm64 lane failed with `bin/ARM64-win/DirectML.lib ... missing and no known rule to make it`, and that was misread as "no arm64 package". A cross-scoped inline patch lower-cases the redist directory once (`string(TOLOWER … onnxruntime_dml_redist_platform)`) and routes both consumers through it. The sequencing hold has since cleared: as of #118 (2026-08-24) GenAI builds `USE_DML=ON` on both lanes and stages `D3D12Core.dll` through a target-derived filter, and OpenCV's `WITH_DIRECTML` is ON on both lanes — it feeds contrib G-API's ONNX DirectML EP, not `cv::dnn`.

### `USE_CUDA=OFF` forced by **target**, not host (GenAI)

`Get-GpuEnvironment` probes the x64 *build host*. On a GPU-equipped host it answers "yes" and would switch nvcc on for an aarch64 target. This lane ships no CUDA (wiring the Windows ARM64 CUDA preview is backlog work, see the exclusion table) — and even then the decision belongs to the target, never to a host GPU probe.

### Python bindings **ON** everywhere since #120 step 2 (2026-08-24 evening): ORT wheel, GenAI wheel, `cv2`, PyAV — built for the target, **staged, never imported**

Every wheel links the **target** CPython (`C:\runtime\python`, #120 step 1) while the **host** interpreter runs the build — `Get-TargetBuildPython` returns exactly that split (`.Exe` host, `.Include` arch-neutral, `.Lib`/`.LibDir` target) and `Get-SourceBuildPython` stays host-pinned. Wheels go through `Invoke-PythonWheelBuild -CrossStage` (one call for both lanes: on cross it appends the target `--plat-name`, stages, and hands the wheel to `Assert-WheelTargetArch` (PE machine **and** `EXT_SUFFIX` name tag of every native member); cv2 gets a static gate on `cv2.cp314-win_arm64.pyd` in the target site-packages. The `sitecustomize` shim pins `EXT_SUFFIX` to the target on this lane (the name a target interpreter will import) while `get_platform()` stays host (what pip resolves downloads with). See § "#120 step 2" below for the three findings this took.

### `-mllvm -aarch64-enable-compress-jump-tables=false` (OpenCV)

An **LLVM AArch64 codegen limitation**, not a bug in any of the affected libraries. Switch-heavy TUs overflow a one-byte compressed jump-table entry. **REPLACED on LLVM 23.1.0 (2026-08-26)**: the current setting is `-Xclang -target-feature -Xclang +force-32bit-jump-tables`, the subtarget feature the pass itself consults. It **disables the compression pass exactly as this flag does** — byte-identical output, verified 2026-08-27 — and is preferred only because a target feature is a supported spelling where `-mllvm` is a debug knob. The separate branch-range failure in `median_blur.dispatch.cpp` is handled per-TU with `/Ob1` and by no jump-table setting at all. Heading kept as a live anchor target; see below and `failure-modes.md` § AArch64 cross compile aborts. **ROOT CAUSE, corrected 2026-08-28 — the two failures are ONE defect, not two.** An earlier version of this paragraph claimed they were unrelated and that a toolchain move to LLVM `main` would retire `/Ob1`; **both halves were wrong**, and the correction is recorded rather than deleted because the wrong story was acted on. `AsmPrinter` emits a NOP after an `EH_LABEL` under async EH (`/EHa`, which OpenCV passes) while `getInstSizeInBytes` reports `EH_LABEL` as a zero-size meta-instruction, so every MIR-level block-size estimate is 4 bytes short per label. The two consumers of that estimate then each pick an encoding the assembler rejects: `AArch64CompressJumpTables` (`value evaluated as <N>`) and `BranchRelaxation` (`fixup value out of range`). That is the under-counted instruction this paragraph used to say was unidentified. Fixed by `windows/scripts/patches/llvm/001-aarch64-ehlabel-size.patch` (+ `002` for SEH pseudos) on the **pinned 23.1.0**, filed upstream as [llvm#219275](https://github.com/llvm/llvm-project/pull/219275) and [llvm#219276](https://github.com/llvm/llvm-project/pull/219276). **Claimed but unlogged:** a `NINJA_KEEP_GOING=1` census is recorded as having built all **1,869** objects green with BOTH `OPENCV_NO_JUMPTABLE_WORKAROUND=1` and `OPENCV_NO_OB1_WORKAROUND=1` on a compiler containing no llvm#202716 — but it ran by hand in the container and left no log, and no file in `out/windows-build-logs/` mentions either knob. Re-run it through the driver before acting on it. #202716 remains a real upstream defect either way; the evidence that it is not this lane's cause is the patch set that DID fix the lane, not this census. **Both settings stay until the patched toolchain is the DEFAULT** — `Dockerfile.toolchain-builder` still ships `ARG BUILD_PATCHED_LLVM=0`, so a stock image still needs them. Full evidence: [`windows-refactor-backlog.md`](windows-refactor-backlog.md), backlog item #135.

### MLAS skip re-gated on `WIN32` alone (OpenCV, patch `003`)

The existing Windows skip was gated on `WIN32 AND _MLAS_REQUIRES_ASM`, and upstream derives that flag from `MLAS_X86_64` / `MLAS_ARM64` / … — whose detection does **not** fire for a `CMAKE_SYSTEM_PROCESSOR=ARM64` cross configure. The skip silently did nothing on the arm64 lane, MLAS built a C++-only subset whose objects still referenced the GAS-only assembly kernels, and it failed at **link** with `undefined symbol: MlasGemvFloatKernel` / `MlasHGemmSupported`. amd64 is unchanged — `_MLAS_REQUIRES_ASM` is TRUE there, so both forms of the condition fire identically, and that lane already skipped MLAS.

### `mlasi.h` MSVC intrinsic remap guarded by `!defined(__clang__)` (OpenCV)

Bundled MLAS assumes *"`_M_ARM64` implies the MSVC compiler"* and remaps two ACLE reduction intrinsics onto MSVC's private spellings: `#define vmaxvq_f32(src) neon_fmaxv(src)`. clang-cl defines `_M_ARM64` too, but implements the ACLE names and has no `neon_fmaxv` at all. The upstream `#ifndef vmaxvq_f32` guard does not help — clang provides it as a *function*, not a macro, so the guard is true and MLAS shadows the real intrinsic. The condition being corrected is *which compiler*, not *which architecture*, so each `#define` is wrapped rather than deleted. **Dead code (audited 2026-08-24):** patch `003`'s `WIN32` `return()` fires first, so OpenCV never compiles MLAS — or this header — on either lane; the patch is retained as documentation of the collision, not as a live fix.

### `have_sse`/`have_sse2` gated on `cpu_family` (gst-plugins-base)

**Upstream bug.** Its MSVC branch assumes *"not `x86_64`" means "x86 32-bit"* and never considers ARM64, so aarch64 falls into the `else` and gets `sse_args = '/arch:SSE'`. It then decides purely on `cc.has_argument(sse_args)` — and **clang-cl accepts `/arch:SSE` for an aarch64 target completely silently**, so the x86 SSE resampler sources are compiled for ARM and die in `mmintrin.h`. `have_sse41` already carries the `cpu_family` guard; the fix just extends it to its two siblings. Nothing is fixable on the meson side: `ClangClCompiler.has_arguments` already appends `-Werror=unknown-argument`, `-Werror=unknown-warning-option` **and** `-Werror=unused-command-line-argument`.

### Vulkan lib dir follows `host_machine` (gst-plugins-bad)

**Upstream bug, same class: the wrong machine is asked.** `vulkan/meson.build` picks `join_paths(vulkan_root, 'Lib')` when `build_machine.cpu_family() == 'x86_64'` — the machine doing the compiling, which is x86_64 here no matter the target. Because the directory is passed **explicitly** via `cc.find_library('vulkan-1', dirs: …)`, no `LIB` ordering can override it. meson itself already gets this right (`VulkanDependencySystem` maps build `x86_64` + host `aarch64` → `Lib-ARM64`); gst-plugins-bad simply computes the path by hand instead of using it.

### `-FIio.h` → assembly-safe shim (GStreamer)

meson hands `c_args` to `.S` files too, so a force-included C header lands in an **assembly** translation unit and is parsed as instructions (`vadefs.h: unrecognized instruction mnemonic — typedef char* va_list;`). The shim wraps the include in `#ifndef __ASSEMBLER__`, which clang defines only for `.S`. Beyond openh264 this matters for dav1d, libvpx and x264, which all ship aarch64 `.S` as well — fixing the flag beats disabling one subproject at a time.

### `--as=clang --target=aarch64-pc-windows-msvc` (FFmpeg)

**Assembly is ENABLED, and this row used to say the opposite.** Until 2026-08-24 the lane passed `--disable-asm` on the assumption that aarch64 GAS needed `gas-preprocessor.pl` driving `armasm64`. It does not: clang's *integrated* assembler accepts FFmpeg's aarch64 GAS directly, so pointing `--as` at clang with the target triple is the whole fix. The precondition that makes it safe on a host which cannot execute aarch64 is that `--enable-cross-compile` disables configure's runtime probes — configure only ever *assembles* its test fragments. Measured: `NEON enabled yes`, and 99 distinct `aarch64/*.o` objects built through real `AS` steps. `gas-preprocessor.pl` + `armasm64` remains the documented fallback if a future FFmpeg lands a `.S` file clang rejects; reaching for a different toolchain does not. **amd64 is untouched by this row because the flag lives in a cross-only branch.** When this row was written amd64 had no assembler path of its own (`--disable-x86asm` was appended unconditionally; nasm served only GStreamer's openh264); backlog #119 closed that asymmetry the same day by enabling nasm-assembled x86asm on the amd64 lane, while the cross lane keeps `--disable-x86asm` explicitly — it is an x86-only knob.

### The OpenCV softfloat / NEON collision

Worth spelling out, because the fix looks like a stylistic nit and is not.

`modules/core/src/softfloat.cpp:163` does, **inside `namespace cv`**:

```cpp
typedef softfloat  float32_t;
typedef softdouble float64_t;
```

`intrin_neon.hpp` also lives in `namespace cv`, so unqualified lookup for `float32_t` finds
`cv::float32_t` *before* the `::float32_t` (= `float`) that clang's `arm_neon.h` declares. Since
clang 16 the NEON lane accessors are macros of the form

```c
__ret = __builtin_bit_cast(float32_t, __builtin_neon_vgetq_lane_f32(__s0, __p1));
```

and `cv::softfloat` has a user-provided copy constructor, so it is **not trivially copyable** —
exactly what `__builtin_bit_cast` requires. Every `v_extract_n` instantiated in that translation
unit fails with `'__builtin_bit_cast' destination type must be trivially copyable`. x86 is
unaffected because the SSE intrinsics never mention `float32_t`, which is why this stayed
invisible on the amd64 lane.

The fix converts the two typedefs into **object-like macros**, and that distinction *is* the
mechanism: `intrin_neon.hpp` is textually preprocessed at `#include "precomp.hpp"` on line 66,
long before line 163, so the template bodies keep a bare `float32_t` token that a later `#define`
can no longer rewrite. Removing the typedef leaves nothing named `cv::float32_t`, so that token
resolves to `::float32_t` as clang intends — while every use *after* line 163, i.e. all of the
ported Berkeley SoftFloat code, still expands to `softfloat` exactly as the typedef did. The file
has no `#include` after line 163, so the macro cannot leak into a header.

The patch carries a **throwing** drift assertion rather than a warning: a silent no-op here
resurfaces as a wall of confusing `bit_cast` errors deep inside `arm_neon.h`, which is precisely
the failure mode worth spending an explicit `throw` on.

### AArch64 compressed jump tables

Switch-heavy translation units abort the compile with a diagnostic that names **no source file**:

```
generated_message_reflection.cc: error: value evaluated as 284 is out of range.
descriptor.cc:                   error: value evaluated as 262 is out of range.
grfmt_tiff.cpp:                  error: value evaluated as 256 / 272 is out of range.
gapi serialization.cpp:          error: value evaluated as 259 is out of range.
```

`AArch64AsmPrinter::emitJumpTableImpl` emits a *compressed* jump-table entry as `(LBB - Base) >> 2`
through `MCObjectStreamer::emitValueImpl` with `Size = 1`, and that is the only producer of this
message in LLVM. Every value measured lands just past `255 * 4 = 1020` bytes of table span:

| Reported | × 4 | vs. 1020 |
|---|---|---|
| 256 | 1024 | just over |
| 259 | 1036 | just over |
| 262 | 1048 | just over |
| 272 | 1088 | just over |
| 284 | 1136 | just over |

Under **LLVM 22** the fix was one arm64-only flag that keeps **full `/O2`** — uncompressed jump
tables are larger, not slower:

```
-mllvm -aarch64-enable-compress-jump-tables=false
```

> **SUPERSEDED on LLVM 23.1.0 (2026-08-26); this note CORRECTED 2026-08-27.** The flag above is no
> longer set; the lane now passes `-Xclang -target-feature -Xclang +force-32bit-jump-tables`
> instead, which reaches the same end state by a supported spelling. The measurement table above
> still describes a real mechanism — it is simply no longer the one being suppressed.
>
> **Two claims this note used to make were disproved on 2026-08-27, and both had cost runs:** that
> the feature and the `-mllvm` flag differ in what they leave enabled, and that the difference
> explained a second failure in OpenCV's largest dispatch TUs. It did not — that failure is a
> branch-range defect with no jump table in it, fixed per-TU with `/Ob1`.
> **`failure-modes.md` § AArch64 cross compile aborts owns the whole account**: both diagnostics,
> what each flag actually does to the pass, the four "do NOT"s and the local-reproduction recipe.
> Read it there rather than trusting a summary here.

> **This corrects an earlier, wrong diagnosis recorded here.** The first explanation blamed an
> 8-bit *Code Words* field in the `.xdata` unwind record, and the workaround was a per-TU `/Od`
> pass over `build.ninja`. That story was refuted from primary source: `MCWin64EH.cpp` reports the
> Code-Words ceiling as `report_fatal_error("SEH unwind data splitting is only implemented for
> large functions ...")` — a different message entirely, and the string `is out of range` does not
> appear in that file at all.
>
> The jump-table explanation also accounts for something the unwind story never did. Escalating
> `/Ob2` → `/Ob1` → `/Ob0` kept *moving* which TU overflowed instead of fixing it, and only `/Od`
> cleared every one. That is because `AArch64CompressJumpTables` is added only when
> `getOptLevel() != None`: `/Od` disabled the pass as a **side effect** of turning optimisation off
> wholesale, while the `/Ob*` levels merely reshuffled codegen. The right conclusion from that
> measurement was "something only `/Od` switches off", not "something inlining drives".
>
> The observation that every offender was serialisation, parsing or decoding code was correct but
> incidental: the common thread is **big `switch` statements**, not when the code runs.

## The meson cross file: `--target` belongs in `[binaries]`

The single most load-bearing line in the GStreamer cross setup is easy to get wrong, and getting it
wrong produces a **green configure** followed by machine-type conflicts everywhere:

```ini
[binaries]
c   = ['sccache', 'clang-cl', '--target=aarch64-pc-windows-msvc']
cpp = ['sccache', 'clang-cl', '--target=aarch64-pc-windows-msvc']
```

`[host_machine] cpu_family` does **not** drive `/MACHINE` — that was the wrong assumption, and it
only steers the `meson.build` tree's own arch branches. What actually decides is the triple the
**compiler reports**. Verified against meson 1.12.0:

| Where | What it does |
|---|---|
| `compilers/detect.py:439` | runs `<exelist> --version` and parses `^Target: (.*?)-` |
| `compilers/mixins/visualstudio.py:114` | `elif 'aarch64' in target: self.machine = 'arm64'` |
| `compilers/mixins/visualstudio.py:123` | `self.linker.machine = self.machine` — the dynamic linker inherits it |
| `compilers/detect.py:224` | `VisualStudioLinker(linker, env, getattr(compiler, 'machine', None))` — and so does the archiver |

With `--target` only in `-Dc_args`, `clang-cl --version` reports the **host** triple, meson
canonicalises that to `x64`, and every static archive and DLL is built `/MACHINE:x64` while the
objects are aarch64:

```
libgnulib.a.p/asnprintf.c.obj: file machine type arm64 conflicts with library machine type x64
```

Note meson skips `/MACHINE` entirely when the machine is unknown (`ClangClDynamicLinker.get_output_args`:
*"If we're being driven indirectly by clang just skip /MACHINE, as clang's target triple will handle
the machine selection"*), so a **missing** `/MACHINE` is fine — a **wrong** one is not.

The duplicate `--target` in `-Dc_args`/`-Dcpp_args` stays deliberately: those keep the compile
flags correct even for subprojects that rebuild the command line, and the command line beats a
machine file's `[built-in options]`, which is why the triple cannot live there.

## The target CPython is built from source (#120 step 1)

Since 2026-08-24 the media-core stage builds CPython itself for the target — `PCbuild\build.bat
-e -p ARM64` under the repo's ClangCL props plus `/p:PreferredToolArchitecture=x64` — and stages
2864 files to `C:\runtime\python`: the interpreter, `python314.lib`, headers and the stdlib. The
whole build took ~91 s including the externals fetch, and `python.exe`'s PE machine (`0xAA64`)
is verified **in-stage**, not left for the merge gate to find.

This answers #114's Phase-0 Q1 **positively**: VS 18 does ship the ClangCL PlatformToolset for
ARM64. The proof is pythoncore's own warning — "Toolset ClangCL is not used for official builds"
— firing, which requires the toolset to have resolved.

One host-arch artifact still got in, and the extended arch gate earned its keep catching it:
`vcruntime140_1.dll` has **no ARM64 edition by design** — it exists solely to carry the x64 FH4
exception helpers, and ARM64 keeps everything in `vcruntime140.dll`. MSBuild's host-blind redist
copy dropped the **x64** one into the ARM64 output; the gate flagged it as the single violation
in a 932-binary run, and the stage now self-polices every staged binary's PE machine and drops
exactly that file, under a tightly-guarded rule rather than a pattern that could grow.

**What this deliberately did not include at first: the consumers.** They followed the same
evening as step 2.

## The Python consumers are built for the target (#120 step 2)

Since 2026-08-24 evening (arm64 run 3) the four consumers build against the target CPython:
`onnxruntime-1.29.0-cp314-cp314-win_arm64.whl` (4 native members), `onnxruntime_genai_directml-0.15.2-cp314-cp314-win_arm64.whl`
(3), `av-18.1.0-cp314-cp314-win_arm64.whl` (49) — all members `0xAA64`, all staged in
`C:\runtime\wheels` — and `cv2.cp314-win_arm64.pyd` installed into `C:\runtime\python\Lib\site-packages`.
None of it is installed into, or imported by, any interpreter in the build: the only interpreter
that can run here is x64.

**The split that makes it correct.** One interpreter *runs* the builds (host, x64 — pybind11 and
numpy probes execute it, `bdist_wheel` zips with it); a different one is *linked* (target —
`python314.lib` from `PCbuild\arm64`). `Get-TargetBuildPython` encodes that as `.Exe` (host),
`.Include` (arch-neutral headers), `.Lib`/`.LibDir` (target) with an `.Available` guard, and every
consumer passes exactly those. On amd64 the accessor collapses to the host values, so the native
lane is byte-identical.

**Three findings from the two failed runs before the green one — each now pinned in code or test:**

1. **ORT's CMake reads `Python_*`, not `Python3_*`.** The `Python3_EXECUTABLE/INCLUDE_DIR/LIBRARY`
   hints passed for months were ignored on *every* lane — CMake printed "Manually-specified
   variables were not used by the project" each time — and amd64 only worked because FindPython
   auto-detected the host interpreter and its numpy. Cross had no luck to fall back on: `Target
   "onnxruntime_pybind11_state" links to Python::NumPy but the target was not found`. The script now
   passes `Python_*` plus an explicit `Python_NumPy_INCLUDE_DIR` probed by running the host
   interpreter. GenAI needs **both** spellings: `Python_*` for its own `find_package(Python)`, and
   the legacy `PYTHON_*` trio for its vendored pybind11 in classic mode (`FindPythonLibsNew.cmake:
   Python libraries not found` without it). `SourceBuild.FindPythonPrefix.Tests.ps1` pins the
   spellings **case-sensitively** (`-cmatch` — PowerShell's `-match` would call `Python_` and
   `PYTHON_` the same name).
2. **`if (Test-WindowsCrossTarget -and -not $tpy.Available)` is parsed in command mode.** A
   condition whose first token is a command name makes `-and`, `-not` and `$tpy.Available` *arguments*
   of that command; no error, the branch fires. Run 2 reported "6. python wheel 0s" with the bindings
   ON. Fix: a variable first (`$onnxCross -and …`). Probed and confirmed on the host before fixing.
3. **The host-pinned `sitecustomize` shim stamped the host `EXT_SUFFIX` on target modules.**
   `cv2.cp314-win_amd64.pyd`, machine `0xAA64` — right bytes, a name no arm64 interpreter will ever
   import (`_imp.extension_suffixes()` there is `.cp314-win_arm64.pyd` / `.pyd`). The shim now sets
   `sysconfig.get_config_vars()['EXT_SUFFIX']` to the target suffix on the cross lane and leaves
   `get_platform()` host-pinned, because those are two different facts: the first names what this
   interpreter *builds*, the second what pip may *download* for it. Verified standalone under a host
   python (`EXT_SUFFIX = .cp314-win_arm64.pyd`, `get_platform = win-amd64`, import suffixes untouched)
   before the run, and `Assert-WheelTargetArch` + the cv2 gate now check the name tag as well as the
   machine field.

Two more facts worth keeping: PyAV is a setuptools extension, so it is compiled by **`cl.exe`** via
setuptools' `x86_arm64` vcvars spec (`build_ext --plat-name win-arm64` selects it) — the documented
PyAV-shaped hole in the clang-cl rule, on both lanes; and the `-CrossStage` staging path is the cross
lane's replacement for `Install-StagedPythonWheel`/`Test-PythonImport`, which stay mandatory on amd64
(the same switch takes that native path there).

## Cross machinery the LiteRT branch added

Plain LiteRT (#115) went green on 2026-08-24 — the merge now carries its 146 staged libs,
including an aarch64 `tensorflowlite_c.lib`. The fixes that got it there generalize; each is
recorded with its one-line "why".

**Two host tools, both from pinned sources.** Cross-compiling LiteRT needs a host `flatc` and a
host `protoc`. `flatc` is built natively from the **same vendored tree** (the `flatbuffers-flatc`
target, with a per-call `-TargetArch host` override at the choke point) — because generated code
and schema compiler must come from the same flatbuffers version. `protoc` is the 21.9 GitHub
release zip, its version derived from the **vendored** protobuf commit (`90b73ac3` = C++ runtime
3.21.9) — **not** the LM lane's `PROTOC_VERSION=31.1`, whose generated code includes
`google/protobuf/runtime_version.h`, a header 3.21.9 does not ship. The vendored runtime picks
the protoc family; nothing else may.

**XNNPACK gets the MLAS-class per-TU treatment** (`Build-LitertFromSource.ps1`). 569 C
microkernel TUs are tagged **per feature family** in `build.ninja` post-configure — families
completed against upstream's `PROD_*` source lists: scalar `fp16arith`, `neonfp16`,
`neonfp16arith`, `neondot`, `neondotfp16arith`, `neonbf16`, `neoni8mm`, `neoni8mmbf16`; SME
skipped — with a floor of 100. The 335 hand-written aarch64 `.S` kernels instead get a
**full-union** in-source directive, `.arch armv8.2-a+fp16+dotprod+i8mm+bf16`, floor 10. The
asymmetry is the point: an assembler only *validates* — it never emits an instruction the source
does not contain, so the union is byte-neutral for asm — while a compiler may auto-vectorize, so
C must stay per-family. Same reason MLAS is per-TU: these kernels are runtime-dispatched.

**The ASM language now gets the target triple — chain-wide.** `Get-CMakeCrossArgs`
(`WindowsTargetArch.Common.psm1`) also sets `CMAKE_ASM_COMPILER_TARGET` and
`CMAKE_ASM_FLAGS_INIT`. Before that, any project enabling the ASM language assembled with the
**x64 default** target (`brackets expression not supported on this target`), and an aarch64
`-march` handed to that x86-targeting driver was misread as a CPU name (`unknown target CPU
'armv8.2-a+fp16'`) — diagnostics that sent the first analysis chasing a driver gap that does not
exist. One choke-point line fixes every ASM-enabling project at once; amd64 is untouched because
its cross args stay empty.

**The `tflite` plugin is presence-driven, and the cross gate now proves plugin-ness.**
GStreamer's configure gets `-Dgst-plugins-bad:tflite=enabled` when LiteRT is staged — never
`auto`, because `auto` degrades a missing dependency into a silently absent mandatory plugin.
The hardened cross plugin gate walks each plugin's dependency tree (`dumpbin`) **and** asserts
the per-plugin export marker `gst_plugin_<name>_get_desc` — because a DLL with the right name is
not yet a plugin. Measured recalibration (2026-08-24): modern GStreamer (per-plugin registration
since 1.14) exports `gst_plugin_<name>_get_desc` + `_register`, **not** the legacy
`gst_plugin_desc` this gate first asserted — that first version failed all four plugins,
including three amd64-proven ones, and was recalibrated from the dumped export tables.

**Iteration honesty.** The litert+merge green took **eight** iterations with named fixes. Two
were self-inflicted (a PowerShell plus-sign-outside-parameter binding bug; the wrong legacy
export-symbol assumption above); the rest were genuine cross gaps — per-TU kernel features, the
ASM triple, the host `flatc`, the host `protoc` and its version family, and the vcruntime redist
copy from the CPython section.

## The merge stage on arm64

The merge fans three branch trees into one install prefix, builds GStreamer from source (~4965
targets on this lane), and then runs the PE architecture gate — over `C:\runtime` **and** the
host CPython's `C:\temp\cpython\Lib\site-packages`, with `-IncludeArchives`. Measured 2026-08-24:
**931 binaries inspected, 0 violations**, the 58 host `.pyd`s reported as allowlist skips. That
is the whole-image statement backlog #117 asked for, and it resolves #117's gate-scope half; the
other half — "is `C:\temp` payload?" — is settled by #120: the **shipped** interpreter on arm64
is `C:\runtime\python`, and the host CPython stays build tooling.

Since 2026-08-24 (#115) `media-litert` is a **real branch on this lane** — plain LiteRT
cross-builds; see the machinery section above. Inside it, the LiteRT-**LM** stage self-skips
(its two real Bazel blockers are recorded in the exclusion table) and stages the empty
`litert-lm` stand-in tree itself — `Build-LitertAll.ps1`'s skip path — so the merge's
unconditional `COPY` still finds every path it expects. **No branch is absent any more** (2026-08-24
evening): `media-tvm` — which also carries **IREE** — cross-builds runtime-only (#116, see its own
section), so the merge fans in three real images on both lanes. History of this paragraph, kept
because it was wrong twice: the first version said TVM's codegen "cannot emit aarch64" (false — the
LLVM target list is this repo's own array), the second said the branch was blocked on executing
`llvm-config` (true for the *compiler*, irrelevant for the *runtime* the lane now ships).

`Dockerfile.media-merge-builder` copies from both with **unconditional** `COPY --from=media-litert` /
`--from=media-tvm`, and a Dockerfile cannot make a `COPY` conditional. Until 2026-08-24 evening a
`media-branch-absent` stand-in stage stood in for whatever the lane could not build (first both
branches, then only `media-tvm`), providing the expected paths empty plus an `ABSENT-ON-ARM64.txt`
marker in each. **That stage is retired** (#116 made `media-tvm` real, runtime-only — see the next
section): `$script:MergeRequiredBranches` is the same three-branch list on both lanes, and the
surviving convention is that **a branch which cannot build a component ships its own empty,
marker-carrying tree** — `Build-LitertAll.ps1` does exactly that for LiteRT-LM, and
`Build-TvmFromSource.ps1` / `Build-IreeFromSource.ps1` drop `COMPILER-ABSENT-ON-ARM64.txt` next to
their runtime installs. The merge's pointer contract is unchanged: `TVM_LIBRARY_PATH` / `IREE_BIN`
must resolve on both lanes, and smoke section 19 asserts it (the first arm64 smoke run found
exactly that pair dangling).

## TVM and IREE cross-build runtime-only (#116, 2026-08-24)

The blocker recorded for `media-tvm` was real but narrower than "the branch": `USE_LLVM=<path>`
makes TVM **execute** `llvm-config` at configure time and link target-arch LLVM libraries into
`tvm_compiler.dll`, and IREE's compiler needs its in-tree LLVM for the target too. Neither is needed
to **run** compiled modules. So the cross lane builds the runtimes and names the compilers absent:

| Component | arm64 cross build | Shipped | Named ABSENT |
|---|---|---|---|
| TVM | `USE_LLVM=OFF`, `TVM_BUILD_PYTHON_MODULE=OFF`, `ninja tvm_runtime` only (the `-Targets` parameter added to `Invoke-NinjaBuildWithRetry` for this), manual stage: `lib\tvm_runtime*.dll/.lib`, `lib\tvm_ffi*.dll/.lib`, `include\{tvm,dlpack,dmlc}`; Vulkan lib dir arch-aware (`Get-VulkanLibDirName`) | `C:\runtime\lib\tvm\{lib,include}` — every DLL PE-gated in-stage | `tvm_compiler.dll`, the `tvm`/`tvm_ffi` python packages (`COMPILER-ABSENT-ON-ARM64.txt`) |
| IREE | **Two configures of the same tree**, upstream's documented recipe: (A) a native x64 runtime-only build into `build-host\`, installed, asserted to contain `iree-flatcc-cli.exe` + `iree-c-embed-data.exe`; (B) the target configure with `IREE_HOST_BIN_DIR=<A>/install/bin`, `IREE_BUILD_COMPILER=OFF`, python OFF, Vulkan HAL ON | `C:\runtime\iree\{bin,lib,include}` — every `.exe`/`.dll` under `bin\` PE-gated in-stage (a host tool leaking into the target install is the failure this catches) | `iree-compile.exe`, `iree.compiler` / `iree.runtime` wheels (`COMPILER-ABSENT-ON-ARM64.txt`) |

The functional compile+run gate (`iree-compile` → `iree-run-module`, `abs(-5)=5`) runs only on
amd64; on arm64 it is replaced by the static PE gate, and the execution proof stays owed to a
native host like every other arm64 signal.

Four findings from the first runs (3–6), each fixed in code and, where it is a rule, in a test:

- **TVM 0.26 header layout:** `dmlc-core` is gone, `dlpack` lives inside the `tvm-ffi` submodule's
  own `3rdparty`, and `c_runtime_api.h` no longer exists (its C surface is `tvm\ffi\c_api.h`). The
  copy is layout-searched and asserts `tvm\runtime\c_backend_api.h`, `tvm\runtime\device_api.h`,
  `tvm\ffi\c_api.h`, `dlpack\dlpack.h`.
- **The host pass needs the HOST's `LIB`, not just the host target.** VsDevCmd `-arch=arm64`
  leaves `LIB` on the ARM64 CRT, CMake invokes lld-link directly (no clang-driver auto-detection),
  and the first try-compile died with `msvcrtd.lib(exe_main.obj): machine type arm64 conflicts
  with x64`. `Invoke-WithHostArchLibraryEnvironment` rewrites the arch segment of every
  `LIB`/`LIBPATH` entry for the block and restores it (`SourceBuild.HostArchLibEnv.Tests.ps1`).
  Exactly the "necessary but not sufficient" the choke point's comment predicted for
  `-TargetArch (Get-WindowsHostArch)`.
- **IREE 3.x host tool names:** `iree-c-embed-data.exe`, not `generate_embed_data`.
- **Upstream gap — `IREE_HOST_BIN_DIR` on a Windows host:** IREE composes
  `${IREE_HOST_BIN_DIR}/iree-flatcc-cli` without `.exe`, and ninja wants that exact file
  (`missing and no known rule to make it`). The script stages a suffix-less twin beside each host
  `.exe`; `CreateProcess` appends `.exe` for an extension-less full path, so both names run the
  same bytes. Draft issue: `out/upstream-issue-iree-host-bin-dir-exe.md`.
- **IREE's arm_64 ukernels need per-TU feature flags under clang-cl** — the third instance of the
  MLAS/XNNPACK class. Upstream hands `mmt4d_arm_64_{fullfp16,fp16fml,bf16,dotprod,i8mm}.c` their
  `-march=armv8.2-a+<feat>` via `iree_select_compiler_opts(CLANG_OR_GCC …)`; clang-cl is
  classified as MSVC there, the flags vanish, and the kernels die with `always_inline function
  'vfmaq_f16' requires target feature 'fullfp16'`. `mmt4d_arm_64_fp16fml.c` additionally uses the
  bare GNU `asm` keyword, which MS compat turns off. Post-configure `build.ninja` tagging appends
  `/clang:-march=armv8.2-a+<feat>` to exactly those five TUs (floor 5; the pre-fix state tags 0)
  and `-Dasm=__asm__` to every arm_64 ukernel TU.
- **Upstream bug — `ARM64` matches `MATCHES 64`:** `hal/local/elf/CMakeLists.txt` adds the
  x86-64 MASM trampoline object (`arch/x86_64_msvc.obj`) whenever `MSVC_C_ARCHITECTURE_ID MATCHES
  64`, so the ARM64 archive got an x64 object (`file machine type x64 conflicts with library
  machine type arm64`). Same "MSVC implies x86" class as gst-plugins-base's `have_sse`. Inline
  patch to an exact x64 match, on both lanes, verified after applying. Draft issue:
  `out/upstream-issue-iree-elf-arch-arm64-msvc.md`.
- **C99 `inline` linkage in one ukernel:** with everything compiled, the tools failed to link on
  `iree_uk_mmt4d_tile_s8s4s32_1x8x16_arm_64_i8mm` — the single non-static C `inline` definition
  in the arm_64 set (checked file by file), whose address the entry point takes; C99 inline
  semantics emit no external symbol for it. `-fgnu89-inline` on that TU did not help under
  clang-cl (run 10); the definition is inline-patched to a plain external function (`inline`
  buys nothing for a function used by address), verified post-patch. (How upstream links this
  on Linux/clang was not verified — a question, not a claim.)

**First full run: 2026-08-24 evening (arm64 run 11) — see the status banner for the result.**

## QNN execution provider (#121, 2026-08-24; SDK staged + multi-framework 2026-08-29)

The Qualcomm AI Engine Direct SDK is login-gated, so the wiring is **opt-in by staging a zip**:
drop it into `windows/qnn-sdk/` (git-ignored except its README; bind-mounted into the
media-core `onnx`, `genai`, `litert`, and `tvm` RUNs at `C:\temp\qnn-sdk`), optionally pin
it with `QNN_SDK_ZIP_SHA256` in `versions.env`. `Resolve-QnnSdk` (in
`WindowsSourceBuild.Common.psm1`) extracts it, anchors the SDK root on
`include\QNN\QnnInterface.h`, asserts `lib\<arch>\QnnCpu.dll` exists for the target, and
checks version compatibility against the ORT build (QNN_OP_STFT canary — falls back to
QNN-off if the SDK is too old). `Copy-QnnRuntime` stages the per-arch backend DLLs
(`QnnHtp*.dll`, `QnnCpu.dll`, `QnnSystem.dll`) plus `hexagon-v*` skel dirs beside each
framework's install.

The QNN SDK gives a build-time flag to **ONE framework** (corrected 2026-08-31, backlog #154 — the other three rows record what was wrong):

| Framework | CMake flag | What it enables |
|---|---|---|
| **ONNX Runtime** | `onnxruntime_USE_QNN=ON` | ORT QNN execution provider — NPU inference for ONNX models |
| **ONNX Runtime GenAI** | (inherits from ORT) | QNN runtime DLLs staged beside GenAI install |
| **LiteRT** | *(none — see #154)* | Nothing. `TFLITE_ENABLE_QNN` was invented; the real switch is `LITERT_ENABLE_QUALCOMM` in the `litert/` tree, which this lane does not configure |
| **TVM** | *(none — see #154)* | Nothing. TVM has no QNN option at all; its `qnn` is the Quantized-Neural-Network dialect, and its Snapdragon path is the separate Hexagon SDK |
| **IREE** | *(none — see #154)* | Nothing. IREE has never had a Qualcomm backend |

**No zip = QNN off with one notice** on every framework. A version-mismatch (SDK too old
for the framework version) also falls back to QNN-off gracefully. The SDK staged on this
host is QAIRT 2.44.0.260225 (QNN API 2.33.0), which carries `QNN_OP_STFT`,
`QNN_OP_RANDOM_UNIFORM_LIKE`, and `QNN_OP_SCATTER_ELEMENTS_REDUCTION_MAX` — all required
by ORT 1.29. The QNN EP should now build. The verification ceiling is DirectML's: a green
build proves the right bytes ship, never NPU execution.

**The mandatory GStreamer plugin contract demands all four plugins on BOTH lanes again.** The
`UnavailableOn.arm64` entry that dropped `tflite` while LiteRT was a stand-in was deleted on
2026-08-24 (#115) — the plugin is mandatory once more, and the green run proves it present. The
arch-filter mechanism stays where it always was: in `Get-RequiredGstPlugin -Arch`, ONE place,
because the contract has three consumers (build gate, smoke test, healthcheck) and
*them disagreeing is the documented 2026-07-11 regression* that shipped an image without plugins.
With no entry carrying an arch key any more, the filter is provably a no-op on both lanes: all four
entries come back in the same order.

### Verification cannot mean "run it"

Eight of the nineteen blockers found in the merge/final audit were the same class: **code that executes
arm64 binaries on the x64 build host.** The GStreamer post-install gate runs `gst-inspect-1.0.exe`; the
smoke suite — 22 sections, ~100 assertions — is dominated by payload execution: `LoadLibraryW` over every
shipped DLL, compile-and-run native probes, `ffmpeg -version` and its kin. None of those are checks that
*fail* on arm64 — they are checks that **cannot exist** there, all failing for the same uninformative
reason.

So on the cross lane:

- The GStreamer gate asserts the plugin **DLL was produced**, walks its dependency tree with
  `dumpbin`, and asserts the per-plugin export marker `gst_plugin_<name>_get_desc` (see the
  machinery section for its measured recalibration) — and still says explicitly (`cross lane - load
  probe impossible on an x64 host`) why it stops there. Whether it is the right machine is
  `Test-TargetArch.ps1`'s job.
- Since 2026-08-24 the smoke gate's **host-toolchain sections (1-6, 14-16, and 19, arch-filtered:
  `TORCH_APP_DIR` is dropped) run on this lane** against their own floors — measured **97 passed /
  0 failed / 15 skipped** on the green run — and the payload sections are skipped **as sections**,
  reported **NOT APPLICABLE**, not "passed". (Until then the whole gate was NOT APPLICABLE.)
  Sections 14/15 were **not** "unchanged, they just run": the final image bakes
  `VSDEVCMD_ARCH=arm64`, so a bare `clang-cl` — x64 default target — fought the ARM64 environment
  libraries, measured as the first arm64 smoke run's 90/7/13. They now compile **for the target**
  and assert the produced PE machine instead of running the probe; ASAN is skipped (LLVM's
  win-x64 package ships no aarch64-windows ASAN runtime), and the arm64 floor for section 14 is
  the measured 2.
- `meson install` runs with `--destdir` so meson skips post-install scripts that would have to run
  target binaries — see the DESTDIR section below.
- The shipped image's **`HEALTHCHECK` skips payload execution.** `windows/Dockerfile` declares it
  unconditionally (a Dockerfile cannot branch on an ARG) and the same file produces `:winarm64`, so
  without this the bundle would sit permanently `unhealthy`, retrying failing checks every five
  minutes forever. `Test-Health.ps1` reads the baked `WINDOWS_TARGET_ARCH`; since 2026-08-24 it
  still runs its four host-tool checks on arm64 and skips **only payload execution**, reporting
  that the payload is a cross-compiled **artifact bundle, deliberately not runnable**.

**The amd64 smoke floors are deliberately never lowered for arm64.** Since 2026-08-24 the arm64 lane
carries its **own floor column** — a third column in the floor table, sized for the host-toolchain
sections it actually runs (floors 66/25; the green run measured 97/0/15) — and the amd64 numbers
stay untouched. A shared, reduced `-SmokeMinPassed`
would leave a number that a later amd64 change could quietly be measured against — which is exactly
how the gate documented at backlog #44 became decorative once before.

### Two silent failure modes the audit caught

Both would have produced a **green** result:

1. **compiler-rt was selected arch-blind.** The old code took `Select-Object -First 1` over every
   `*builtins*.lib` and handed the path straight to `lld-link`. LLVM ships one per target, and on the cross
   lane the x86_64 one sorts first — so an aarch64 image would have been linked against the host's runtime.
   The selection is now filtered by target, and when no match exists the lane links *nothing* rather than
   the wrong thing. See the next section: the gap turned out to be real, and it is now filled.
   **The mirror-image bug then bit amd64 (2026-08-24):** the first fix filtered only the cross branch, on
   the rationale that this "keeps the amd64 selection exactly what it is today" — written while the x86_64
   lib was the only one installed. Once the base started shipping `clang_rt.builtins-aarch64.lib` (the
   #113 ride), amd64's alphabetical `-First 1` flipped to **a**arch64, and the first amd64 merge on that
   base died linking `gstreamer-1.0-0.dll` with `machine type arm64 conflicts with x64` — caught by the
   full-chain amd64 regression run, exactly what it exists for. The pick is now target-filtered on BOTH
   lanes; a selection that depends on what happens to be installed is not a selection.
2. **The arch gate's coverage floor could silently disable itself.** It arrives as
   `-MinInspected ([int]$env:ARCH_GATE_MIN_INSPECTED)`, and `[int]$null` is `0`, which switches the floor
   off entirely — so a dropped build-arg would turn the gate into a clean pass over whatever it happened to
   find. "No floor" is now an explicit `-AllowEmptyTree` opt-in, and the cross lane raises the floor to 100
   (the Dockerfile default of 10 is far below what a complete bundle contains, and could not detect losing
   a whole component).

## aarch64 compiler-rt is a base prerequisite

scoop's `main/llvm` is the **x64** Windows release, and LLVM ships compiler-rt for the host architecture
only: the install contains `clang_rt.builtins-x86_64.lib` and nothing else. `Test-Arm64Prereqs.ps1` Q5
has checked for the aarch64 counterpart since this lane was designed, and reported `[FAIL]` the whole time.

That is not cosmetic. clang lowers 128-bit integer arithmetic to compiler-rt libcalls on aarch64, so the
first component that does 64×64→128 math fails at **link**, not compile:

```
lld-link: error: undefined symbol: __udivti3
>>> referenced by gstutils.c:670 (gst_util_uint64_scale)
```

ONNX Runtime, FFmpeg and OpenCV happen not to need it. GStreamer does — which is why the gap stayed
invisible until the merge stage.

`Install-ScoopTools.ps1` now fetches the official
`clang+llvm-<ver>-aarch64-pc-windows-msvc.tar.xz`, extracts **only**
`clang_rt.builtins-aarch64.lib` (280 KB out of a 704 MB archive), drops it beside the host library, and
deletes the archive. Measured on the build host: 0.8 min to download, 0.4 min to extract.

Three details worth keeping:

- **The destination is derived from the host library's own directory**, never hardcoded. That is by
  construction the directory clang and every consumer already search, so no discovery logic has to learn a
  new path.
- **It installs unconditionally**, like the MSVC ARM64 toolset and the Vulkan ARM64 component. Gating it on
  an arch ARG would re-pay the chain's most expensive layers on every lane switch. It sits *after*
  `Install-Vs.ps1` in `Dockerfile.base`, so adding it does not invalidate the VS layer.
- **The URL must encode the `+` as `%2B`.** That is the canonical `browser_download_url` the GitHub release
  API returns, and the unencoded form 404s. Note also that GitHub refuses **HEAD** on release assets, so a
  failed HEAD is *not* evidence the asset is missing — verify with a ranged GET instead.

### The patched-LLVM toolchain (#135) does not carry it — GStreamer self-heals

`BUILD_PATCHED_LLVM=1` (the default since 2026-08-29) builds clang/LLVM from source, and that build emits
compiler-rt builtins for the **host** arch only (`-DLLVM_ENABLE_RUNTIMES=compiler-rt`), so
`C:\llvm-patched\lib\clang` holds `clang_rt.builtins-x86_64.lib` and nothing else. The arm64 GStreamer link
then fails exactly as above — found on the 2026-08-30 arm64 cross run (merge stage, `__udivti3` undefined
linking `gstreamer-1.0-0.dll`), with the script's own warning naming the cause.

Rather than rebuild the whole chain to add the lib to the toolchain layer (the media branches derive FROM
`bk-windows-toolchain`, so one added layer re-pays ~2 h of media compiles), the **GStreamer merge stage
self-heals**: `Build-GstreamerFromSource.ps1` § 5d, on the cross lane only, mines
`clang_rt.builtins-aarch64.lib` from the official release archive (same URL/recipe as
`Install-ScoopTools.ps1`) next to the x86_64 lib, then re-runs its candidate search. The existing
warn-and-link-without policy stays for the case the fetch fails. Regression: `SourceBuild.GstreamerCompilerRt.Tests.ps1`.
The toolchain-level fix (builtins in the `patched-llvm` stage) is a tracked follow-up for the next natural
toolchain rebuild.

### opus NEON intrinsics stay DISABLED on the cross lane (enablement reverted 2026-08-31)

The speculative cross-lane enablement (`-Dopus:intrinsics=enabled`, added 2026-08-30) was proven broken
twice once the compiler-rt fix let the GStreamer build actually reach opus. Under clang-cl aarch64, the
RTCD path (default) applies `-mfpu=neon` — an ARM32-only flag clang-cl rejects for aarch64
(`unsupported option '-mfpu='`), and the RTCD CPU probe `celt/arm/armcpu.c` uses MSVC's `__emit`
intrinsic, which clang-cl does not implement. The lane is back on the 2026-08-26 proven shape:
`-Dopus:intrinsics=disabled` on BOTH lanes (the scalar opus codec is fully functional).

The working enablement recipe for a future dedicated test window: `-Dopus:intrinsics=enabled
-Dopus:rtcd=disabled` — with RTCD off, a clang-cl aarch64 build *presumes* SIMD (`opus_can_presume_simd
= true`), so no `-mfpu=` args are applied and the `__emit`-based `arm_armcpu.c` is not compiled. The
tradeoff to verify on a real device: dotprod and NEON are presumed unconditionally, so the image is
Snapdragon-class-only (all current Windows-on-ARM devices qualify, but it is not a universally-safe
default). Re-enable only with a smoke-tested device run. Tracked in
`docs/windows-refactor-backlog.md` #135 follow-up.

The staged QNN runtime also extended the merge gate's knowledge: the QAIRT HTP
stub DLLs (`QnnHtpV*Stub.dll`, `calculator*.dll` — staged beside every
framework by `Copy-QnnRuntime`) import `libcdsprpc.dll`/`libadsprpc.dll`,
Qualcomm's FastRPC ADSP/CDSP drivers. Those are device-OS libraries: present in
every Windows-on-Snapdragon image, never in the SDK zip and never on the
Server Core reference host — so `Test-TargetArch.ps1`'s `ClientOsPattern`
now allows them, and the arch gate reports the QNN payload as inspected PE +
resolved imports instead of 63 phantom unresolved edges.

## aarch64 OpenSSL is a base prerequisite too

scoop installs **one architecture per app**, and that is the host's — so the image carries
`lib\VC\x64\MD\libcrypto.lib` and nothing else. Four GStreamer targets link OpenSSL and all four
failed identically: `ext/hls` (HTTP Live Streaming), `ext/dtls` (WebRTC), `ext/aes`, and
glib-networking's OpenSSL TLS backend.

`Install-ScoopTools.ps1` now installs the arm64 build **beside** the x64 one, using the same
upstream artifact and the same SHA256 that scoop's own `openssl` manifest pins for its `arm64`
entry. Three things about that step are load-bearing:

- **Extract, never run.** The manifest is marked `"innosetup": true`, which is exactly how scoop
  installs it — with `innounp`. Running the installer silently was tried first and is what *not*
  to do: the whole step took 11.8 s including the 218 MB download, exited **0**, and produced no
  files at all. A silent no-op that looks like success is the failure mode this repo exists to
  gate against, and it was only caught because the step searches for `libcrypto.lib` afterwards
  instead of trusting the exit code.
- **Declare the dependency, don't inherit it from order.** `innounp` reaches this image only as a
  side effect of scoop installing some innosetup package, and `scoop install main/openssl` runs
  *later* in the same file (measured: this block at 349 s, openssl at 406 s). The block installs
  `main/innounp` explicitly so it is position-independent.
- **Find the layout, never compose it.** innounp extracts InnoSetup payloads under a literal
  `{app}` directory, so the real paths are `…\{app}\lib\VC\arm64\MD\libcrypto.lib` and
  `…\{app}\include\openssl\opensslv.h`. Both the lib dir and the include dir are located by
  searching for a known file; a `Join-Path $root 'include'` would silently point at nothing.

The package ships **no** `.pc` files, so the GStreamer build authors `libcrypto`, `libssl` and
`openssl` with `Write-PkgConfigFile` — the same helper OpenCV and ONNX Runtime already need for
the same reason — and puts that directory **first** on `PKG_CONFIG_PATH` so it wins over the
image's x64 `openssl.pc`.

### `meson install` needs DESTDIR on the cross lane

The last thing between a fully compiled GStreamer and an installed one is a **post-install script**:

```
ERROR: Failed to run install script gio-querymodules: Executable was not found
ERROR: Install scripts failed to run
```

`gio-querymodules` indexes GIO modules, and doing that means **executing an aarch64 binary** on this
x64 host — the same class as the `gst-inspect` gate and the smoke test. meson already has the escape
hatch, and it is keyed on DESTDIR (`minstall.py:709-713`, `:729-731`):

```python
if not destdir and len(failing_scripts) > 0:  raise MesonException('Install scripts failed to run')
if destdir and (isinstance(i, InstallScriptFailure) or i.skip_if_destdir):
    self.log('Skipping custom install script because DESTDIR is set')
```

DESTDIR is meson's *"this is a staged/packaging install, do not try to run target binaries"* signal.

**`--destdir C:\` is chosen so the files land exactly where they always did**, with no staging tree
to move afterwards. From `mesonbuild/scripts/__init__.py`:

```python
def destdir_join(d1, d2): return str(PurePath(d1, *PurePath(d2).parts[1:]))
```

`PureWindowsPath('C:\runtime\bin').parts` is `('C:\','runtime','bin')`, so `parts[1:]` drops the
drive and `PurePath('C:\', 'runtime', 'bin')` is once again `C:\runtime\bin` — byte-identical to the
non-DESTDIR path. amd64 keeps the plain invocation: there every install script *can* run, and
skipping `gio-querymodules` would ship an unindexed GIO module directory.

## Three resilience fixes the merge stage needed

Neither is arm64-specific; both were found by the arm64 work and apply to **both** lanes.

**`win-pkgconfig` is the one subproject that fetches with no fallback.** Its `download-binary.py`
has a single `MIRROR_URL`, one `urlopen`, and zero retries. When `gstreamer.freedesktop.org`
returned `HTTP Error 503`, win-flex-bison fell back to GitHub and nasm to nasm.us — and this
alone killed the merge, **four separate runs**. The same script opens with
`if os.path.isfile(dest_path) and sha256 matches: sys.exit(0)`, so the archive is pre-placed in
phase 5 and verified against the **same** hash meson checks. Version and hash are parsed out of the
subproject's `meson.build` rather than hardcoded.

**Retries were the wrong answer, and that took three failures to see.** Four attempts with
exponential backoff still lost to a sustained outage — backoff helps against a blip, not against a
server that is down for minutes. The fix is the one the repo already uses for the Vulkan SDK
(*"Preseed the … exe onto the LAN webdav so containers never pull it from the vendor"*): the archive
is fetched from `$SCCACHE_WEBDAV_ENDPOINT/preseed/` **first**, with upstream only as fallback — and
whichever source works, it is PUT back to the preseed path, so the first successful run immunises
every later one. Every step is fail-open: a preseed miss is not an error, and meson still has its
own attempt. This must never become the thing that breaks a build.

**A failed download wears a deterministic error's costume.** `meson setup`'s retry logic
short-circuits on `meson.build:LINE:COL: ERROR`, correctly — a real configure error repeats
identically and a retry costs a full wrap re-download. But a download failure is reported in
exactly that form, so the classifier now also looks for a **network signature**
(`HTTP Error …`, `Failed to download`, `URLError`, timeouts, refused connections) and retries when
it finds one, without weakening the short-circuit for genuine errors.

## What this lane cannot produce

Components with no arm64 story, and what stands in their place.

- [CUDA / cuDNN / TensorRT](#cuda--cudnn--tensorrt) · [DirectML](#directml) · [LiteRT-LM](#litert-lm) · [Flutter](#flutter) · [PyTorch / the torch app stage](#pytorch--the-torch-app-stage)

### CUDA / cuDNN / TensorRT

**Excluded — but the blanket reason recorded here until 2026-08-24 ("no Windows-on-ARM support") was wrong, and the 421 MB figure recorded here was never re-fetched.** The cuDNN 9.25.0.15 windows-arm64 archive exists at this repo's exact pin (ranged GET: HTTP 200, **~90 MB** re-measured 2026-08-28 — the 421 MB was wrong; see backlog #122, CLOSED), `lib/arm64` inside). CUDA itself, however, has no `windows-arm64` redist or installer at 13.4 or any 12.x/13.3.x (NVIDIA's redist manifest lists only `windows-x86_64` for Windows; #122 probe, 2026-08-28). Classic TensorRT does remain genuinely x64-only — no ARM64 row in NVIDIA's support matrix — but TensorRT-RTX publishes Windows-on-Arm packages for CUDA 13.4. Wiring CUDA here is backlog work, not fiction; until it lands, `Dockerfile.nvidia` is skipped and the arm64 lane always takes the CPU alias path.

### DirectML

**No longer excluded — the "packaging gap" verdict recorded until 2026-08-23 was mistaken and is retracted.** That entry claimed the nuget ships no arm64 import library. Byte inspection refutes it: `Microsoft.AI.DirectML` 1.15.4 contains `bin/arm64-win/DirectML.lib`, machine `0xAA64`. The failure was an upper/lower-case mismatch when ONNX Runtime composes the redist path from `onnxruntime_target_platform`; see the portability table above. ONNX Runtime is therefore configured `USE_DML=ON` on **both** lanes as of backlog #113, and that build has now run (2026-08-24): the DML EP compiled and linked (`onnxruntime_providers_dml.lib` at ninja step 1116/1118), `DirectML.dll` was staged into `C:\runtime\lib\onnxruntime-source\bin`, and the merge-stage arch gate reported **390 binaries inspected, 0 violations** with no allowlist skips (the whole-image scan has since grown to **931/0** with the litert branch and the target CPython aboard) — since the gate's root is `C:\runtime`, `.dll` is in its extension set and the merge copies that whole tree, the shipped DirectML is necessarily arm64. #118 landed 2026-08-24: GenAI builds `USE_DML=ON` on both lanes (staging `D3D12Core.dll` through a target-derived filter) and OpenCV's `WITH_DIRECTML` is ON on both lanes, feeding contrib G-API's ONNX DirectML EP rather than `cv::dnn`. **The limit worth stating plainly:** this proves the right bytes ship, not that the EP runs — nothing arm64 executes on this x64 host, so only the `windows-11-arm` CI job can show that. Microsoft's Snapdragon guidance still points at the **QNN** provider for NPU work, which would pull in the Qualcomm AI Engine SDK this stack does not integrate; that part is unchanged.

### LiteRT-LM

**Blocked upstream — and the 2026-08-23 correction recorded here over-corrected (corrected again 2026-08-24).** That correction called the prebuilt `libGemmaModelConstraintProvider.lib` "optional... never the obstacle". On the active **Bazel** path that is wrong: `gemma3_data_processor` puts the x86_64-only prebuilt in the **default** Windows dependency graph, severable only via the `litert_lm_fst_constraints_disabled` config_setting (`model_data_processor/BUILD:26-33`). Both blockers are real: no windows-arm64 configuration in `.bazelrc` AND the prebuilt in the default graph (the upstream stub belongs to the non-active CMake path). Plain **LiteRT** (not `-LM`) has neither problem — pure CMake, no prebuilt — and **#115 is done (2026-08-24): it cross-builds**; `media-litert` is a real branch on this lane and the `tflite` GStreamer plugin is back among the mandatory four. The host-tool requirement was met with a natively built `flatc` from the same vendored tree plus a pinned host `protoc` 21.9 (see the LiteRT machinery section). Only LiteRT-**LM** stays excluded; its stage self-skips and stages the empty `litert-lm` stand-in tree for the merge.

### Flutter

**Not cross-compilable.** windows-arm64 needs a native arm64 host — native engine builds landed on beta/stable in March 2026 ([flutter/flutter#176385](https://github.com/flutter/flutter/pull/176385)) — but cross-compiling from an x64 host is still not upstream ([flutter/flutter#179777](https://github.com/flutter/flutter/issues/179777) tracks the remaining stable-channel gaps).

### PyTorch / the torch app stage

**Still dropped — but "structurally impossible", recorded here until 2026-08-24, overstated two things.** `download.pytorch.org` *does* publish `win_arm64` `+cpu` wheels, and `uv` can cross-**resolve** into a directory without executing the target interpreter (`uv sync` proper does run it). The binding constraint is this repo's own cp314 pin: upstream builds no `win_arm64` wheel for Python 3.14 at `PYTORCH_VERSION=v2.13.0`. The stage stays dropped; only the reasons changed.

Everything in that table is a **product gap to document, not an engineering problem to route
around**. Where a coverage floor can encode it (CUDA sections in the smoke floors), encode it, so
it can never be silently "fixed" by a skip.
