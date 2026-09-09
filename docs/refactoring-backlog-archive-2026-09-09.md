<!-- Closed Linux refactor items, archived 2026-09-09. OPEN work lives in refactoring-backlog.md. -->

# Refactoring backlog archive — 2026-09-09

Closed on 2026-09-09 and moved out of
[`refactoring-backlog.md`](refactoring-backlog.md), which is OPEN-only.
Each entry keeps the evidence that closed it.

**One entry, and a build closed it.** VK2 had been open since 2026-09-05 with the
standing note that only a real chain could settle it. Two sdk runs settled it:
`sdk-20260908-132426` for aarch64 and `sdk-rv64-20260908-211949` for riscv64.

**Read the numbers here as dated, not current.** Two of the figures in the first
draft of this entry did not survive an adversarial re-derivation — the
`x86_64/bin` count and the composition of its delta were both quoted before
either directory had been listed. Both were re-measured against the pushed
digest before this file was written; the method is stated with each.

---

## VK2. CLOSED — 20/20 on both foreign arches, and a fifth defect nobody had named [M, ★★★]

**What closes this entry**, as the entry itself required: `<arch>/bin` carrying
everything `x86_64/bin` does that is not structurally host-only.

    #20 4328.1 [INFO] Vulkan cross-targets riscv64: 20/20 component(s) built
    #20 3705.1 [INFO] Vulkan cross-targets aarch64: 20/20 component(s) built

riscv64 at `out/build-logs/sdk-rv64-20260908-211949/sdk-riscv64.log:20826`
(a live 4328 s build, pushed `@sha256:09a4d255`); aarch64 at
`out/build-logs/sdk-20260908-132426/sdk-arm64.log:21316` (3710 s, pushed
`cross-sdk-arm64@sha256:de6eaad2`). 20 = the 17 `_VK_TARGET_COMPONENTS` rows plus
the three hardwired ones (loader, SPIRV-Tools, glslang); the counter has exactly
four increment sites and the logs carry 20 distinct `Cross-building <label>`
lines, name for name.

### The four named defects: all four diagnoses held, all four fixes landed

1. **`vulkan-profiles` / jsoncpp PIC** — `-DCMAKE_POSITION_INDEPENDENT_CODE=ON`
   moved into `_cross_build_sdk_component`'s fixed args rather than the one row,
   since any archive handed to the SDK can end up inside a layer `.so`.
2. **`gfxreconstruct` header bridge** — `_vulkan_setup_sdk_includes` now bridges
   `X11 xcb GL KHR EGL GLES2 GLES3`. `KHR` was not optional: `GL/gl.h` and
   `glcorearb.h` include `<KHR/khrplatform.h>`.
3. **`vulkancapsviewer` / raw loader path** — `-DVULKAN_LOADER_INSTALL_DIR="${archdir}"`
   in the `vulkancapsviewer)` arm of `_vulkan_target_dynamic_args`. The
   "still unproven" note in the open entry — that AUTOMOC/AUTORCC under
   `QT_HOST_PATH=/usr` had never run on a foreign arch — is now proven both ways:
   `[2/17] Automatic RCC for vulkancapsviewer.qrc` on riscv64,
   `[17/17] Linking CXX executable vulkanCapsViewer` on aarch64.
4. **`slang` / vendor copy step** — `_xbuild_extra_targets+=(copy-gfx-slang-modules)`,
   the helper extension the entry called the largest of the four.

**Two of the entry's own diagnoses had been wrong** and are recorded as such: slang
was never a Canadian-cross problem (it was a prebuilt Dawn WebGPU zip upstream ships
for x86_64 and aarch64 only, whose arch cascade `FATAL_ERROR`s on riscv64 even with
the backend off), and vulkancapsviewer was never missing target Qt6 in the way the
entry described.

### The fifth defect, which no route in VK2 had named

riscv64 sat at **19/20** through two further runs after all four fixes were in.
`vulkancapsviewer` alone kept failing, at `find_package(Qt6)`, traced to

    install_target_packages: 'qt6-base-dev:riscv64' apt-get exited 100
    libappstream5:riscv64 : Depends: libcurl3t64-gnutls:riscv64 (>= 7.63.0) but it is not going to be installed
    libproxy1v5:riscv64   : Depends: libcurl3t64-gnutls:riscv64 (>= 7.16.2) but it is not going to be installed

Every package in that message existed in ports at a satisfying version, so the
error named a symptom and not a cause. The cause was a **host/target apt pocket
asymmetry**: the compiler stage wrote `ubuntu.sources` for amd64 **without**
`-security` and `ubuntu-ports.sources` **with** it. `libcurl3t64-gnutls` is
`Multi-Arch: same`, so amd64 topped out at `8.18.0-1ubuntu2.4` while riscv64's
candidate was `8.18.0-1ubuntu2.5`, and no common version existed in apt's view.

A/B on `ghcr.io/kataglyphis/kataglyphis_beschleuniger:base`, same image, one line
different:

| amd64 stanza | amd64 candidate | riscv64 candidate | `qt6-base-dev:riscv64` |
| --- | --- | --- | --- |
| without `-security` | 8.18.0-1ubuntu2.4 | 8.18.0-1ubuntu2.5 | `E: Broken packages` |
| with `-security`    | 8.18.0-1ubuntu2.5 | 8.18.0-1ubuntu2.5 | installs |

Nothing about it was Qt-specific or riscv64-specific: it disabled **every**
`Multi-Arch: same` library that has ever had a security-only upload. The full
account, including why `archive.ubuntu.com` made the `0` cost-free, is
[`cross-build-verification.md#host-and-target-apt-sources-must-expose-the-same-pockets`](cross-build-verification.md#host-and-target-apt-sources-must-expose-the-same-pockets).

**Why aarch64 reached 20/20 without the fix**: its run ended 16:39, before the
skew had anything to bite on for that lane. It was timing, not immunity — the
same host file, the same `Multi-Arch: same` rule. That is why VK5 (below, in the
live file) asks for one confirming aarch64 run rather than treating the earlier
20/20 as current.

### What the shipped bytes say

Both `bin` directories listed inside a container from the pushed
`@sha256:09a4d255` — not derived from the log, which never enumerates the
tarball-seeded x86_64 tree:

* `x86_64/bin` **52** entries, `riscv64/bin` **37**.
* riscv64 is a strict **subset**: zero entries exist there that x86_64 lacks.
* The 15-entry delta is exactly `dxa dxa-3.7 dxc dxc-3.7 dxl dxl-3.7 dxopt
  dxopt-3.7 dxr dxr-3.7 dxv dxv-3.7 llvm-tblgen vkconfig vkconfig-gui`.
* `spirv-remap` is in **neither** tree, so `-DENABLE_SPVREMAPPER=OFF` on the cross
  glslang costs no parity. (It was raised as a concrete reason to doubt
  subset-ness before the directories were listed; listing them settled it.)
* Spot-checked ELF machine in `riscv64/bin`: `vulkanCapsViewer`, `slangc`,
  `gfxrecon-info`, `vulkaninfo` — all **RISC-V**.

The 15 are what LunarG's prebuilt x86_64 tarball carries and **no** arch builds
from source: `vkconfig`, `Vulkan-Configurator` and `dxc` appear nowhere in
`vulkan.sh` (0 hits, case-insensitively, in 912 lines). That is a never-asked
question rather than a regression, and it is now VK4 in the live file.

### What this cost, and the lesson

Four rebuild attempts of the sdk stage. The three that ended 19/20 each had a
green static battery behind them. **No gate in this repo can see this class**: the
two sources files are individually valid, the skew is invisible to a same-arch
build, and it only bites once a `Multi-Arch: same` package receives a
security-only upload. The `mirror-consistency` gate now asserts the pair rather
than either file, and `cross_align_host_apt_pockets` repairs an inherited skew at
the point of use so a stage need not be rebuilt to benefit.

---

## VK4 + VK5. CLOSED — all three arches ship 52 binaries [S, ★★]

**Measured on the pushed digests, both directories listed inside a container.**
Not derived from a log.

| | amd64 | arm64 `@sha256:6eefc3c3` | riscv64 `@sha256:1bdfbb3a` |
| --- | --- | --- | --- |
| `bin/` | 52 | **52** | **52** |
| `share/vulkan/explicit_layer.d` | 9 | **10** | **10** |
| entries amd64 has and the arch lacks | — | **0** | **0** |

The sets are *identical*, not merely equal in size — zero entries in either
direction. `dxc`, `vkconfig`, `vkconfig-gui` and `llvm-tblgen` report ELF machine
AArch64 and RISC-V respectively, so nothing is a copied host binary. Both foreign
arches are AHEAD on layers: only they ship `VkLayer_khronos_timeline_semaphore`.

`Vulkan cross-targets riscv64: 24/24` and `aarch64: 24/24`, with zero
`unavailable on <arch>` lines in either log.

### The gap was a question nobody had asked

LunarG's `./vulkansdk` builds **24** components under `all`. The HOST list in
`_vulkan_build_components` named **18**. A component not named there is never
checked out, and `_vulkan_target_install_component` returns at its `-d` test
*before* incrementing `_vk_attempted` — so the three missing ones were never
counted as attempted, and the verdict line read a clean `N/N`. That is why it
survived months of green runs.

The fix was four table rows (`dxc`, `vulkantools`, `crash-diagnostic-layer`,
`yaml-cpp`) plus three dynamic-arg arms, and the count now equals the vendor's
own `build_all` flag count: 21 rows + 3 hardwired = 24.

### Two traps that would have faked success

* **`vulkantools` would have reported BUILT with no vkconfig in it.** Upstream
  does `find_package(Qt6 ... QUIET)` and, when Qt6 is missing, skips the entire
  configurator with a `message()` and **exits 0**. `_vk_ok` would have
  incremented. `-DCMAKE_REQUIRE_FIND_PACKAGE_Qt6=TRUE` turns that into an honest
  failure; the shipped ELF proves Qt6 really was found.
* **`dxc` failed the first run, and NOT because of riscv64.** Configure
  completed — LLVM 3.7 does know the host triple, upstream PR #4894 carries. It
  died compiling `external/SPIRV-Tools/source/util/timer.h` on GCC 16's
  `-Warray-bounds`, promoted by `-Werror`. `_vulkan_target_build_spirv_tools` in
  the same file had carried `-DSPIRV_WERROR=OFF` for that identical warning since
  it was first diagnosed; DXC vendors its **own** copy of SPIRV-Tools, which
  never saw the flag.

**That fix saved both lanes, not one.** The rebuild logged 164 `array-bounds`
warnings on riscv64 and **93 on aarch64** — arm64 would have died at the same
header. It only surfaced on a foreign arch because GCC inlines differently on
x86_64, where the host build passed.

### What it cost, and what it leaves

Four sdk builds. VK5 is closed in the same breath: arm64's previous 20/20 was
measured against a tree that no longer existed, and the rebuild settles it on the
current one.

Left behind, both small and both owner decisions: **VK6** (13 shared libraries
the foreign arches do not get, caused by our own `ENABLE_OPT=OFF` /
`SPIRV_CROSS_SHARED` flags) and **VK7** (11 DXC files the foreign arches ship
that the vendor prunes from the tarball).
