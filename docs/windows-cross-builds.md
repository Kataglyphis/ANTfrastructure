# Windows cross builds (arm64)

The Windows twin of [`linux-cross-builds.md`](linux-cross-builds.md). It covers the
`aarch64-pc-windows-msvc` target lane: why it is shaped the way it is, what it can and cannot
produce, and which gates keep it honest.

> **Status (2026-08-23): the lane builds; nothing it produces has ever been run.**
>
> Shipped: the arch-fact module (`WindowsTargetArch.Common.psm1`), `-TargetArch` on the **BuildKit
> driver only** (`build-buildkit.ps1`) — the classic `build.ps1` has no arm64 support at all and
> never sees `WINDOWS_TARGET_ARCH`, so the cross lane is BuildKit-only,
> `ARG WINDOWS_TARGET_ARCH` from the media stage onward, per-arch tags, the base-image ARM64
> readiness checks, the MLAS kernel-flag floor, and the `verify-target-arch.ps1` PE gate wired
> into the merge stage.
>
> **The chain completes end to end: `base → sdk → toolchain → media-core → merge → final` produces
> `:winarm64`.** Cross-built for `aarch64-pc-windows-msvc`: the whole media core — ONNX Runtime
> (CPU; DML off; 25 MLAS fp16 TUs tagged), ONNX GenAI (`ENABLE_PYTHON=OFF`), FFmpeg
> (`--disable-asm`) and OpenCV (five upstream portability fixes, see below) — plus GStreamer with
> its ~4960 targets and the out-of-tree `opencv_videoio_gstreamer` plugin, all in the merge stage.
>
> **The PE architecture gate has run and passed:** `389 binaries inspected, 0 violations`
> (`verify-target-arch.ps1` over all of `C:\runtime`, floor raised to 100 on this lane). That is
> the only positive evidence that exists — and it is worth noting what it ruled out: four separate
> paths could have put host-arch artifacts into the bundle (arch-blind compiler-rt selection, the
> x64 `vulkan-1.lib`, the x64 OpenSSL, and meson emitting `/MACHINE:x64`), and each would have
> produced a "successful" bundle that fails to load on real hardware.
>
> **Cannot be cross-built at all:** `media-litert` and `media-tvm` — LiteRT-LM links a prebuilt
> x86_64-only static library, and TVM builds its own LLVM with `X86;NVPTX` targets only. Both are
> replaced by an empty stand-in; see "The merge stage on arm64". A target CPython is not attempted,
> which is why no lane component builds Python bindings or wheels. There is no `windows-11-arm` CI
> job — the repo owner declined one.
>
> **Never verified:** no arm64 binary produced by this repo has ever been executed, anywhere.
> Every arm64 signal here is a static PE machine-type check. A green build is evidence that the
> code compiles and links for the target, and nothing more.

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
   the reverse). Every "run it and see" smoke in `smoke-test-container.ps1` is unavailable here,
   which is why the static gates below carry so much weight.

## Why clang-cl makes this cheap

The whole Windows media chain already builds with **Ninja + clang-cl + lld-link** and explicit
`-DCMAKE_C(XX)_COMPILER=` — there is no Visual Studio generator anywhere in the tree
(`CMAKE_GENERATOR_PLATFORM` and `-A ARM64` have zero occurrences). clang-cl cross-targets aarch64
natively, so this lane is a **target-triple change, not a toolchain replacement**.

The rule is absolute: **clang-cl for every compile, lld-link for every link**, plus `llvm-lib`,
`llvm-rc`, `llvm-mt`, `llvm-readobj`. On arm64 that costs nothing extra, because the one place the
amd64 lane deliberately falls back to `cl.exe` — as **nvcc's host compiler**, since nvcc rejects
clang-cl — does not exist here: there is no CUDA for Windows-on-ARM.

**The MSVC ARM64 component is still required, but not for its compiler.** clang-cl targets the
MSVC ABI, so an aarch64 link needs Microsoft's ARM64 CRT and import libraries
(`VC\Tools\MSVC\<ver>\lib\arm64`), which ship only with
`Microsoft.VisualStudio.Component.VC.Tools.ARM64`. Its `Hostx64\arm64\cl.exe` rides along unused.
This is why `setup-vs.ps1` and `verify-toolchain.ps1` assert the **library** directories rather
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
`$VULKAN_SDK\Lib-ARM64`. `setup-scoop-tools.ps1` adds it explicitly through the SDK's Qt Installer
Framework `maintenancetool.exe`.

**That step warns, it does not fail — deliberately.** Every arm64 prerequisite in the base
(Vulkan `Lib-ARM64`, the MSVC `lib\arm64` CRT, the Windows SDK `um\arm64` libs) is checked
warn-only, because `base` is **shared by both lanes**: a hard failure over an arm64-only
prerequisite would block the amd64 build too, and the `maintenancetool` invocation has never yet
been executed against a real base image. An unverified installer call must not be able to kill the
chain's most expensive layer.

Set **`WINDOWS_ARM64_STRICT=1`** to turn all of them into hard gates — the same opt-in shape as
`CUDA_STACK_STRICT=1` on the Linux side. Use it once the arm64 lane is real; it is the flag that
says "this image claims a complete arm64 toolchain".

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
the same group as `verify-toolchain.ps1` — its only consumer there. The host provisioning scripts
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
  is provably unchanged.

It is re-exported through `WindowsSourceBuild.Common.psm1` on the same terms as
`WindowsNative.Common.psm1`, so build scripts get it with their usual import. **Ship it in every
Dockerfile COPY list that carries the module set** — an incomplete COPY list is a known failure
mode, guarded here by a throwing stub.

## SIMD: the failure that hides inside a green build

`Get-WindowsX86Avx512Flags` was never an ordinary flag helper. `build-onnx-from-source.ps1`
injects it **per-TU into `build.ninja` post-configure**, onto exactly the MLAS kernels matched by
`qgemm_kernel_amx|intrinsics/avx512`. Globally-enabled AVX-512 was field-proven to crash protoc
and `onnxruntime.dll`'s static initializers with `STATUS_ILLEGAL_INSTRUCTION`; entirely without
the flags those TUs fail to compile. Per-TU is the only correct answer, because the kernels are
runtime-dispatched.

**On aarch64 that x86 pattern matches nothing — and a patch that matches nothing succeeds.** The
build would go green with MLAS's NEON/dotprod/i8mm kernels compiled without their features:
unoptimised at best, absent at worst, and undetectable from the build host.

So the pattern is arch-parameterized (`Get-MlasKernelTuPattern`) alongside a **minimum match
count** (`Get-MlasKernelTuMinimum`), and `build-onnx-from-source.ps1` **throws** when the tagged-TU
count falls below that floor. The floor is the actual guard; the pattern alone is not — a warning
there would have preserved exactly the failure mode this exists to prevent.

Note the asymmetry in the baseline flags: amd64 enables a broad SSE/AVX2 set globally, arm64
enables **nothing** globally. AArch64 already mandates NEON, and its optional features
(dotprod/i8mm/SVE) fault on hardware that lacks them — the same class of failure as AVX-512.
Optional AArch64 features belong only on dispatched kernels.

## Verification

With nothing runnable on the build host, verification is layered:

| Gate | Where | What it proves |
|---|---|---|
| `verify-toolchain.ps1` arm64 section | base image | clang-cl emits aarch64 objects; MSVC/SDK/Vulkan arm64 libraries present |
| `verify-target-arch.ps1` | any staged tree | every shipped `.dll`/`.exe` (optionally `.lib`) has PE machine `0xAA64`, with a **minimum inspected floor** |
| `TargetArch.Common.Tests.ps1` | `Invoke-Tests.ps1` | the arch table, the amd64 byte-identity guarantee, and the MLAS pattern behaviour |

The one gate that does **not** exist yet is native execution: a `windows-11-arm` CI job would be
the only proof the artifacts actually **run**. Until it exists, treat every arm64 output as
unvalidated — see the prose below.

`verify-target-arch.ps1` is the Windows twin of the Linux lane's ELF check in
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
windows\scripts\build\verify-target-arch.ps1 -Path C:\runtime -Arch arm64 -MinInspected 20

# permit genuinely host-arch build tools that never ship to the target
windows\scripts\build\verify-target-arch.ps1 -Path C:\runtime -Arch arm64 `
    -HostToolPattern 'protoc\.exe|flatc\.exe|\\_deps\\'
```

Free native validation is available: this repo is public, so GitHub's `windows-11-arm` runners
cost nothing. They are Windows 11 **client**, not Server Core — a caveat to state rather than a
problem to solve, since no Server Core arm64 exists.

## Sequencing: rebuild base twice, on purpose

`setup-vs.ps1` deliberately does **not** SHA-pin the VS bootstrapper (the installer refreshes
within a channel every few weeks; the hash is logged for provenance instead). Adding the ARM64
component therefore also pulls whatever newer VS servicing build is current — and any regression
it carries will look exactly like "the arm64 change broke the build".

**Rebuild the base with no change at all first, confirm it is green, and only then add the
components.** It is the single highest-value sequencing decision in this work.

## Upstream portability fixes this lane carries

None of these are configuration mistakes — they are code paths that **only compile on ARM**, so
no amount of amd64 testing could have surfaced them. Each is scoped to the cross branch so the
amd64 command line stays byte-identical. All were measured on 2026-08-23 against LLVM 22.1.8.

| Fix | Why it is needed |
|---|---|
| `/D_USE_MATH_DEFINES` (OpenCV) | `hal/carotene`, OpenCV's ARM NEON HAL, is compiled **only** for ARM targets. It uses `M_PI`, which the C standard does not mandate and the MSVC CRT withholds unless this macro is defined — carotene assumes POSIX. Symptom: `phase.cpp(121,5): use of undeclared identifier 'M_PI'`. |
| `softfloat.cpp` typedef → macro (OpenCV) | **Genuine upstream bug**, see below. |
| `WITH_IPP=OFF`, `BUILD_IPP_IW=OFF` (OpenCV) | IPP is Intel's x86-only primitives library; no AArch64 build exists. OpenCV still resolved and unpacked `3rdparty/ippicv/ippicv_win`, putting its headers on every core TU's include path, and the staged `.lib` is x64 COFF that lld-link would reject against an arm64 image. |
| `WITH_DIRECTML=OFF` (OpenCV), `USE_DML=OFF` (GenAI) — but `USE_DML=ON` for ONNX Runtime | **The original justification was wrong and is retracted:** the nuget *does* ship an arm64 import library. `Microsoft.AI.DirectML` 1.15.4 contains `bin/arm64-win/DirectML.lib`, a COFF import archive whose machine field is `0xAA64`. The real defect was a **case mismatch inside ONNX Runtime's own CMake**: `cmake/external/dml.cmake` declares the download's outputs with a lower-case `bin/arm64-win`, while `cmake/onnxruntime_providers_dml.cmake` composes its consumer paths as `bin/${onnxruntime_target_platform}-win` — and `onnxruntime_target_platform` is the verbatim, upper-case `ARM64`. The two spellings never meet, so the arm64 lane failed with `bin/ARM64-win/DirectML.lib ... missing and no known rule to make it`, and that was misread as "no arm64 package". A cross-scoped inline patch lower-cases the redist directory once (`string(TOLOWER … onnxruntime_dml_redist_platform)`) and routes both consumers through it. OpenCV and GenAI stay off for now purely as sequencing — GenAI links ORT, so a half-enabled DML there produces confusing link errors; both are re-evaluated only once ORT's arm64 DML is green. |
| `USE_CUDA=OFF` forced by **target**, not host (GenAI) | `Get-GpuEnvironment` probes the x64 *build host*. On a GPU-equipped host it answers "yes" and would switch nvcc on for an aarch64 target. There is no CUDA for Windows-on-ARM at all, so this decision belongs to the target. |
| `BUILD_WHEEL=OFF` (GenAI), Python bindings off (ONNX, OpenCV), PyAV skipped (FFmpeg) | Every wheel links the **target** CPython, and no aarch64 CPython exists in this image — `Get-SourceBuildPython` is host-pinned by design. |
| `-mllvm -aarch64-enable-compress-jump-tables=false` (OpenCV) | An **LLVM AArch64 codegen limitation**, not a bug in any of the affected libraries. Switch-heavy TUs overflow a one-byte compressed jump-table entry. Full `/O2` is retained. See below. |
| MLAS skip re-gated on `WIN32` alone (OpenCV, patch `003`) | The existing Windows skip was gated on `WIN32 AND _MLAS_REQUIRES_ASM`, and upstream derives that flag from `MLAS_X86_64` / `MLAS_ARM64` / … — whose detection does **not** fire for a `CMAKE_SYSTEM_PROCESSOR=ARM64` cross configure. The skip silently did nothing on the arm64 lane, MLAS built a C++-only subset whose objects still referenced the GAS-only assembly kernels, and it failed at **link** with `undefined symbol: MlasGemvFloatKernel` / `MlasHGemmSupported`. amd64 is unchanged — `_MLAS_REQUIRES_ASM` is TRUE there, so both forms of the condition fire identically, and that lane already skipped MLAS. |
| `mlasi.h` MSVC intrinsic remap guarded by `!defined(__clang__)` (OpenCV) | Bundled MLAS assumes *"`_M_ARM64` implies the MSVC compiler"* and remaps two ACLE reduction intrinsics onto MSVC's private spellings: `#define vmaxvq_f32(src) neon_fmaxv(src)`. clang-cl defines `_M_ARM64` too, but implements the ACLE names and has no `neon_fmaxv` at all. The upstream `#ifndef vmaxvq_f32` guard does not help — clang provides it as a *function*, not a macro, so the guard is true and MLAS shadows the real intrinsic. The condition being corrected is *which compiler*, not *which architecture*, so each `#define` is wrapped rather than deleted. |
| `have_sse`/`have_sse2` gated on `cpu_family` (gst-plugins-base) | **Upstream bug.** Its MSVC branch assumes *"not `x86_64`" means "x86 32-bit"* and never considers ARM64, so aarch64 falls into the `else` and gets `sse_args = '/arch:SSE'`. It then decides purely on `cc.has_argument(sse_args)` — and **clang-cl accepts `/arch:SSE` for an aarch64 target completely silently**, so the x86 SSE resampler sources are compiled for ARM and die in `mmintrin.h`. `have_sse41` already carries the `cpu_family` guard; the fix just extends it to its two siblings. Nothing is fixable on the meson side: `ClangClCompiler.has_arguments` already appends `-Werror=unknown-argument`, `-Werror=unknown-warning-option` **and** `-Werror=unused-command-line-argument`. |
| Vulkan lib dir follows `host_machine` (gst-plugins-bad) | **Upstream bug, same class: the wrong machine is asked.** `vulkan/meson.build` picks `join_paths(vulkan_root, 'Lib')` when `build_machine.cpu_family() == 'x86_64'` — the machine doing the compiling, which is x86_64 here no matter the target. Because the directory is passed **explicitly** via `cc.find_library('vulkan-1', dirs: …)`, no `LIB` ordering can override it. meson itself already gets this right (`VulkanDependencySystem` maps build `x86_64` + host `aarch64` → `Lib-ARM64`); gst-plugins-bad simply computes the path by hand instead of using it. |
| `-FIio.h` → assembly-safe shim (GStreamer) | meson hands `c_args` to `.S` files too, so a force-included C header lands in an **assembly** translation unit and is parsed as instructions (`vadefs.h: unrecognized instruction mnemonic — typedef char* va_list;`). The shim wraps the include in `#ifndef __ASSEMBLER__`, which clang defines only for `.S`. Beyond openh264 this matters for dav1d, libvpx and x264, which all ship aarch64 `.S` as well — fixing the flag beats disabling one subproject at a time. |
| `--disable-asm` (FFmpeg) | aarch64 GAS assembly needs `gas-preprocessor.pl` driving `armasm64`. Correct but slower; enabling it is tracked follow-up work, not a blocker. |

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

The fix is one arm64-only flag that keeps **full `/O2`** — uncompressed jump tables are larger, not
slower:

```
-mllvm -aarch64-enable-compress-jump-tables=false
```

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

## The merge stage on arm64

The merge fans three branch trees into one install prefix, builds GStreamer from source, and then runs the
PE architecture gate. Two branches cannot exist on this lane at all:

| Branch | Why it cannot be cross-built |
|---|---|
| `media-litert` | LiteRT-LM's **active build path is Bazel**, and its `.bazelrc` carries no windows-arm64 configuration at all. **Corrected 2026-08-23:** this line previously blamed the prebuilt `libGemmaModelConstraintProvider.lib` — the first plausible blocker spotted in the file, but the wrong one. That blob is *optional*; upstream's CMake path compiles `cmake/patches/stubs/gemma_model_constraint_provider.cc` in its place. Plain **LiteRT** (not `-LM`) is a separate question — see the backlog. |
| `media-tvm` | TVM builds its own minimal LLVM with `-DLLVM_TARGETS_TO_BUILD=X86;NVPTX` (`build-tvm-from-source.ps1:141`), so its codegen cannot emit aarch64 at all. |

`Dockerfile.media-merge-builder` copies from both with **unconditional** `COPY --from=media-litert` /
`--from=media-tvm`, and a Dockerfile cannot make a `COPY` conditional. So the arm64 lane points both
`LITERT_IMAGE` and `TVM_IMAGE` at a `media-branch-absent` stage that provides exactly those paths, empty.
Copying an empty directory succeeds and contributes nothing, which is the intent. It also drops an
`ABSENT-ON-ARM64.txt` into each, so somebody who opens the bundle and finds an empty `litert` directory
gets the reason on the spot instead of assuming the build silently lost something.

**The mandatory GStreamer plugin contract is arch-aware in ONE place.** `Get-RequiredGstPlugin -Arch`
drops `tflite` on arm64, because its entire dependency (LiteRT) is the empty stand-in above — the plugin is
not *missing*, it is structurally unavailable. That filtering lives in the contract rather than in the
GStreamer build, because the contract has three consumers (build gate, smoke test, healthcheck) and
*them disagreeing is the documented 2026-07-11 regression* that shipped an image without plugins. On amd64
the filter is provably a no-op: no entry carries an `amd64` key, so all four entries come back in the same
order.

### Verification cannot mean "run it"

Eight of the nineteen blockers found in the merge/final audit were the same class: **code that executes
arm64 binaries on the x64 build host.** The GStreamer post-install gate runs `gst-inspect-1.0.exe`; the
smoke test `LoadLibraryW`s every shipped DLL, compiles-and-runs a native probe, and calls `ffmpeg -version`.
None of those are checks that *fail* on arm64 — they are checks that **cannot exist** there, all failing for
the same uninformative reason.

So on the cross lane:

- The GStreamer gate asserts the plugin **DLL was produced**, and says so explicitly (`cross lane - load
  probe impossible on an x64 host`). Whether it is the right machine is `verify-target-arch.ps1`'s job.
- The whole smoke gate is reported **NOT APPLICABLE**, not "passed".
- `meson install` runs with `--destdir` so meson skips post-install scripts that would have to run
  target binaries — see the DESTDIR section below.
- The shipped image's **`HEALTHCHECK` short-circuits.** `windows/Dockerfile` declares it
  unconditionally (a Dockerfile cannot branch on an ARG) and the same file produces `:winarm64`, so
  without this the bundle would sit permanently `unhealthy`, retrying failing checks every five
  minutes forever. `healthcheck.ps1` reads the baked `WINDOWS_TARGET_ARCH`, reports that this is a
  cross-compiled **artifact bundle, deliberately not runnable**, and exits 0.

**The smoke floors are deliberately not lowered for arm64.** A reduced `-SmokeMinPassed` would leave a
number that a later amd64 change could quietly be measured against — which is exactly how the gate
documented at backlog #44 became decorative once before.

### Two silent failure modes the audit caught

Both would have produced a **green** result:

1. **compiler-rt was selected arch-blind.** The old code took `Select-Object -First 1` over every
   `*builtins*.lib` and handed the path straight to `lld-link`. LLVM ships one per target, and on the cross
   lane the x86_64 one sorts first — so an aarch64 image would have been linked against the host's runtime.
   The selection is now filtered by target, and when no match exists the lane links *nothing* rather than
   the wrong thing. See the next section: the gap turned out to be real, and it is now filled.
2. **The arch gate's coverage floor could silently disable itself.** It arrives as
   `-MinInspected ([int]$env:ARCH_GATE_MIN_INSPECTED)`, and `[int]$null` is `0`, which switches the floor
   off entirely — so a dropped build-arg would turn the gate into a clean pass over whatever it happened to
   find. "No floor" is now an explicit `-AllowEmptyTree` opt-in, and the cross lane raises the floor to 100
   (the Dockerfile default of 10 is far below what a complete bundle contains, and could not detect losing
   a whole component).

## aarch64 compiler-rt is a base prerequisite

scoop's `main/llvm` is the **x64** Windows release, and LLVM ships compiler-rt for the host architecture
only: the install contains `clang_rt.builtins-x86_64.lib` and nothing else. `probe-arm64-prereqs.ps1` Q5
has checked for the aarch64 counterpart since this lane was designed, and reported `[FAIL]` the whole time.

That is not cosmetic. clang lowers 128-bit integer arithmetic to compiler-rt libcalls on aarch64, so the
first component that does 64×64→128 math fails at **link**, not compile:

```
lld-link: error: undefined symbol: __udivti3
>>> referenced by gstutils.c:670 (gst_util_uint64_scale)
```

ONNX Runtime, FFmpeg and OpenCV happen not to need it. GStreamer does — which is why the gap stayed
invisible until the merge stage.

`setup-scoop-tools.ps1` now fetches the official
`clang+llvm-<ver>-aarch64-pc-windows-msvc.tar.xz`, extracts **only**
`clang_rt.builtins-aarch64.lib` (280 KB out of a 704 MB archive), drops it beside the host library, and
deletes the archive. Measured on the build host: 0.8 min to download, 0.4 min to extract.

Three details worth keeping:

- **The destination is derived from the host library's own directory**, never hardcoded. That is by
  construction the directory clang and every consumer already search, so no discovery logic has to learn a
  new path.
- **It installs unconditionally**, like the MSVC ARM64 toolset and the Vulkan ARM64 component. Gating it on
  an arch ARG would re-pay the chain's most expensive layers on every lane switch. It sits *after*
  `setup-vs.ps1` in `Dockerfile.base`, so adding it does not invalidate the VS layer.
- **The URL must encode the `+` as `%2B`.** That is the canonical `browser_download_url` the GitHub release
  API returns, and the unencoded form 404s. Note also that GitHub refuses **HEAD** on release assets, so a
  failed HEAD is *not* evidence the asset is missing — verify with a ranged GET instead.

## aarch64 OpenSSL is a base prerequisite too

scoop installs **one architecture per app**, and that is the host's — so the image carries
`lib\VC\x64\MD\libcrypto.lib` and nothing else. Four GStreamer targets link OpenSSL and all four
failed identically: `ext/hls` (HTTP Live Streaming), `ext/dtls` (WebRTC), `ext/aes`, and
glib-networking's OpenSSL TLS backend.

`setup-scoop-tools.ps1` now installs the arm64 build **beside** the x64 one, using the same
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

| Component | Status |
|---|---|
| CUDA / cuDNN / TensorRT | **Excluded.** No Windows-on-ARM support; CUDA 13.4 is an RTX-Spark-only developer preview. `Dockerfile.nvidia` is skipped and the arm64 lane always takes the CPU alias path. |
| DirectML | **No longer excluded — the "packaging gap" verdict recorded until 2026-08-23 was mistaken and is retracted.** That entry claimed the nuget ships no arm64 import library. Byte inspection refutes it: `Microsoft.AI.DirectML` 1.15.4 contains `bin/arm64-win/DirectML.lib`, machine `0xAA64`. The failure was an upper/lower-case mismatch when ONNX Runtime composes the redist path from `onnxruntime_target_platform`; see the portability table above. ONNX Runtime is therefore configured `USE_DML=ON` on **both** lanes as of backlog #113. GenAI and OpenCV remain off until ORT's arm64 DML is proven green, and *that* build has not yet run — treat DML-on-arm64 as *fix applied, unverified*. Microsoft's Snapdragon guidance still points at the **QNN** provider for NPU work, which would pull in the Qualcomm AI Engine SDK this stack does not integrate; that part is unchanged. |
| LiteRT-LM | **Blocked upstream — but not for the reason recorded until 2026-08-23.** The blocker is that the active path is **Bazel** and LiteRT-LM's `.bazelrc` has no windows-arm64 configuration. The prebuilt `libGemmaModelConstraintProvider.lib` that this table used to blame is *optional* (the CMake path compiles an upstream stub instead) and was never the obstacle. Whether plain **LiteRT** can be cross-built without `-LM` — which would also restore the `tflite` GStreamer plugin — is tracked in the backlog. |
| Flutter | **Not cross-compilable.** windows-arm64 needs a native arm64 host; cross support is not upstream. |
| PyTorch / the torch app stage | **Structurally impossible here.** `uv sync` must *run* the target interpreter. Independently, `PYTORCH_VERSION=v2.13.0` publishes no `win_arm64` wheel, the Windows-Arm wheels exist only as `+cpu` builds on `download.pytorch.org`, and upstream does not build them for Python 3.14 — which this repo pins. |

Everything in that table is a **product gap to document, not an engineering problem to route
around**. Where a coverage floor can encode it (CUDA sections in the smoke floors), encode it, so
it can never be silently "fixed" by a skip.
