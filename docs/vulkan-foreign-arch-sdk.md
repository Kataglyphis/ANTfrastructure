# The foreign-arch Vulkan SDK is built, not downloaded

LunarG ships the Vulkan SDK for x86_64. For `arm64` and `riscv64` there is no
download, so the chain builds the target prefix from the SDK's own source tree.
The install root is versioned and split by architecture:

```
/opt/vulkan/<ver>/x86_64     the LunarG SDK as downloaded — BUILDER arch
/opt/vulkan/<ver>/aarch64    cross-built — what an arm64 image runs
/opt/vulkan/<ver>/riscv64    cross-built — what a riscv64 image runs
/opt/vulkan/<ver>/source     the checkout the cross builds read
/opt/vulkan/active           symlink to the prefix this image runs
```

`x86_64/bin` holds 52 tools (and, since VK4, so should the foreign prefixes —
see below), but inside an arm64 image every one of them is an
x86-64 ELF: `vulkaninfo` there exits 127. It is build scaffolding. Only the
own-arch prefix is usable at runtime, and `VULKAN_SDK` points at it.

## What the target build produces, and why it used to produce almost nothing

`_build_vulkan_targets` in `linux/scripts/02-toolchain/vulkan.sh` cross-builds:

| Component | Gives you |
| --- | --- |
| headers | `vulkan/vulkan.h` and the registry |
| Vulkan-Loader | `libvulkan.so.1` — the ICD loader |
| SPIRV-Tools | `libSPIRV-Tools*` **and** `spirv-opt`, `spirv-val`, `spirv-dis`, `spirv-as`, `spirv-link`, `spirv-lint`, `spirv-reduce` |
| glslang | `glslang` / `glslangValidator` |
| Vulkan-Headers, SPIRV-Headers, Vulkan-Utility-Libraries | the `find_package(CONFIG)` packages the layers resolve through |
| SPIRV-Cross, SPIRV-Reflect | `spirv-cross`, `spirv-reflect` |
| Vulkan-ValidationLayers | `VkLayer_khronos_validation.so` + its JSON — you cannot develop a Vulkan app without it |

The target build was originally written for one consumer: TVM needed to *link*
`libSPIRV-Tools.a`. It therefore passed `-DSPIRV_SKIP_EXECUTABLES=ON`, and no
component beyond the four it needed was ever attempted. The result shipped a
prefix with full libraries and **two** binaries — enough to link against, not
enough to use. Building applications against the container needs the tools, so
the flag is `OFF` and the remaining components are built.

## Failures here are non-fatal on purpose

`_vulkan_target_install_component` counts an attempt and tolerates a failure: a
component that will not cross-build leaves the prefix poorer, it does not fail
the lane. `_vulkan_target_verdict` fails only when *every* attempt failed, which
is the shape of a broken cross toolchain rather than one awkward component.

## The host build must not inherit the cross pkg-config path

`./vulkansdk` builds HOST (x86_64) tools, and `_vulkan_run_vulkansdk` already
saved and restored `CC`, `CXX` and the `CMAKE_*_COMPILER` variables so CMake would
use the host compiler. pkg-config was left out of that, and the omission cost four
components.

`_vulkan_setup_cross_pkgconfig` builds a `PKG_CONFIG_LIBDIR` with the TARGET
triplet FIRST, and the vulkansdk run is `sudo --preserve-env`'d with it intact:

```
Using cross pkg-config search path
  /usr/aarch64-linux-gnu/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:...
```

So a host tool asking pkg-config for `xcb` was handed the aarch64 module, and
`XCB_LIBRARY_DIRS=/usr/lib/aarch64-linux-gnu` became a `find_library` HINT that
resolved to an absolute foreign path:

```
x86_64-linux-gnu-ld.bfd: /usr/lib/aarch64-linux-gnu/libxcb.so:
    error adding symbols: file in wrong format
```

`vkcube` linked in the same run: `ld` skips an incompatible library found through
`-l`, and cannot skip one handed to it as an absolute path. The x86_64 dev package
was installed the whole time — this was search order, nothing else.

`_vulkan_run_vulkansdk` now swaps `PKG_CONFIG_LIBDIR` to the host half for the
duration of the host build and restores the cross value afterwards, exactly as it
already did for the compilers. The host half is exported once by
`_vulkan_setup_cross_pkgconfig` as `VULKAN_HOST_PKG_CONFIG_LIBDIR`, so the
multiarch triplet is worked out in one place.

With that fixed, nothing is skipped for being a cross lane. `slang` remains
skipped on riscv64 alone, which is an upstream port gap rather than a build-host
problem.

`_VK_TARGET_COMPONENTS` is the table of what gets cross-built, one row per
component: label, checkout candidates, extra CMake args. LunarG's directory names
do not all match the component name — `shaderc` keeps its CMake project one level
down in `src/`, which is why `glslc` looked unbuildable at first — so a row may
name several candidates. `_vulkan_fetch_source_only` is the safety net for a
component whose checkout is absent but whose target build is still wanted.

## The target needs its own dev packages

`install_vulkan_prereqs` installs two package sets: the host set that
`./vulkansdk` builds against, and `target_pkgconfig_packages` as `:${arch}` for
the cross builds — WSI, compression and XML. A third set,
`target_optional_packages` (`libgl-dev`, `libglx-dev`, `libopengl-dev`,
`libegl-dev`, `qt6-base-dev`), goes through `install_optional_target_packages`,
so a ports arch that lacks one degrades a component instead of sinking the stage.

Installing them is not enough on its own, and this is the part that reads like a
missing package but is not one. The 2026-09-05 arm64 lane had
`libx11-dev:arm64`, `libzstd-dev:arm64` and the whole XCB set unpacked, and
gfxreconstruct still configured with:

```
-- Could NOT find ZSTD (missing: ZSTD_LIBRARY)
-- Could NOT find X11 (missing: X11_X11_LIB)
-- Could NOT find OpenGL (missing: OPENGL_opengl_LIBRARY OPENGL_glx_LIBRARY)
-- Could NOT find JsonCpp (missing: JsonCpp_INCLUDE_DIR JsonCpp_LIBRARY)
```

Multiarch puts those libraries in `/usr/lib/<triplet>`, and CMake only looks
there when `CMAKE_LIBRARY_ARCHITECTURE` says so — `find_library` appends it to
every search directory. `_cross_build_sdk_component` passes it for every row, so
the target's own libraries are findable the way the host's are. It cannot make a
host library reachable by accident: `/usr/lib/aarch64-linux-gnu` holds nothing
else. `CMAKE_INSTALL_LIBDIR=lib` is passed explicitly, which is what keeps
`GNUInstallDirs` from relocating the install into `lib/<triplet>` in reply.

## amd64 is the reference: all three arches build the same set

`./vulkansdk` is NOT invoked with `all` here — it is handed an explicit component
list, and what it really builds is **20**: SPIRV-Headers, SPIRV-Tools, glslang,
Vulkan-Headers, Vulkan-Utility-Libraries, Vulkan-Loader, Vulkan-ValidationLayers,
Vulkan-ExtensionLayer, volk, Vulkan-Tools, jsoncpp, valijson, shaderc, SPIRV-Cross,
GFXreconstruct, SPIRV-Reflect, Vulkan-Profiles, VulkanMemoryAllocator,
VulkanCapsViewer, slang. `VulkanTools`, `yaml-cpp`, `CrashDiagnosticLayer` and
`DirectXShaderCompiler` are in the vendor script's `build_all()` but are never
cloned here, so reading that function is misleading — read the log.

The cross path matches it exactly: three hardwired (`loader`, `SPIRV-Tools`,
`glslang`) plus the seventeen `_VK_TARGET_COMPONENTS` rows is the same 20 names.

**No component is skipped for the target arch, and one used to be.** `slang` was
skipped on riscv64 as *"not yet ported upstream"* — never measured, and gating the
wrong thing: that list drives the HOST x86_64 build, which is byte-identical in
every lane. Skipping it took the CHECKOUT with it, and `source/` is what every
target build reads, so riscv64 could not even attempt the cross build: 19 host
components against arm64's 20, 15 cross attempts against 16.

Upstream does document x86_64 and aarch64 only, so the guess may yet prove right —
but a component that cannot cross-build now says so as
`slang unavailable on riscv64` with a reason from the log, and the failure is
non-fatal. A measured verdict beats an assumption in a comment.

The optional target packages were the other parity worry and they are NOT a gap:
`libgl-dev`, `libglx-dev`, `libopengl-dev` and `libegl-dev` are in ports `main` for
riscv64 and `qt6-base-dev` is in `universe`, which `ubuntu-mirror.sh` enables for
the foreign arch (`Components: main universe restricted multiverse`).

## VK4: the components the vendor builds and we did not

Measured 2026-09-09 inside a container, from the pushed sdk digest — both
directories listed, not derived from a log:

| | `x86_64` | `riscv64` | only x86_64 |
| --- | --- | --- | --- |
| `bin/` | 52 | 37 | **15** |
| `lib/` | 118 | 52 | **72** |
| `share/vulkan/explicit_layer.d` | 9 | 6 | **4** |

`riscv64/bin` is a strict subset — nothing exists there that x86_64 lacks. The
gap is not a build failure: it is three components LunarG's own `./vulkansdk`
builds under `all` and this repo's HOST list never named, so nothing was ever
checked out and **no row was even counted as attempted**. The same silent shape
that cost riscv64 slang, and the reason the arch-skip comment above exists.

Read the vendor script for the recipe — it is in the image at
`/opt/vulkan/<ver>/vulkansdk`, and it is the authority, not upstream READMEs:

| vendor name | `<ver>/source/` | delivers |
| --- | --- | --- |
| `dxc` | `DirectXShaderCompiler` | `dxa dxc dxl dxopt dxr dxv` ×2 (a plain and a `-3.7` alias) + `llvm-tblgen` = **13 binaries**, plus the `libLLVM*.a`/`libclang*.a`/`libdxcompiler.so` half of the 72-file `lib/` gap |
| `vulkantools` | `VulkanTools` | `vkconfig`, `vkconfig-gui` = **2 binaries**, and 3 of the 4 missing layers (`api_dump`, `monitor`, `screenshot`) |
| `cdl` | `CrashDiagnosticLayer` | the 4th layer. **No binaries** — it does not move the 52 |
| `yaml-cpp` | `yaml-cpp` | nothing shipped; `cdl` will not configure without it |

13 + 2 = 15, so the table is now 21 rows + 3 hardwired = **24**, which is exactly
the number of `BUILD_*` flags the vendor's `build_all` sets. That equality is the
cheapest check that nothing else is missing.

Three of the four need PATHS, so they are arms of `_vulkan_target_dynamic_args`
rather than table columns:

* **`vulkantools`** takes the same pair the caps viewer needed — `QT_HOST_PATH`
  for `vkconfig-gui`'s moc, and `VULKAN_LOADER_INSTALL_DIR` because the layers
  resolve the loader by raw path. The foreign prefixes keep `libvulkan.so*` FLAT
  in `<arch>/lib` while amd64 has it under `lib/VulkanLoader/`, so the vendor's
  own `${LIBDIR}/VulkanLoader/` would be wrong here.
* **`crash-diagnostic-layer`** wants `GLSLANG_INSTALL_DIR` and
  `YAML_CPP_INSTALL_DIR`; both resolve to the target prefix.
* **`dxc`** needs two things a table cannot hold. Its `-C
  cmake/caches/PredefinedParams.cmake` is a path into the checkout, and **most of
  its option set does not exist until that file is read**. And it is a fork of
  **LLVM 3.7**, so `LLVM_TABLEGEN` and `CLANG_TABLEGEN` must point at the host
  build's `build/bin` — the same Canadian cross `llvm-cross.sh` and slang already
  do. Without them the cross build links the generators for the target and runs
  them: exit 127.

**The risk to watch on the next bump, and on riscv64 in particular:** LLVM 3.7
predates RISC-V entirely. Nothing in DXC needs a RISC-V *backend* — it emits DXIL
and SPIR-V — but its host-triple detection has never seen `riscv64`. aarch64 is
the safer of the two. A failure here is non-fatal by contract (`dxc` is not in
`_VK_REQUIRED_COMPONENTS`), so the tell is the count, not an error: the stage
reports `N/24` and ships.

## The DXC prune mirrors the vendor's own

VK4 gave the foreign prefixes `dxc`, and with it 1 378 new entries under
`<ver>/<arch>/` — counted from the `cmake --install` manifest of the 2026-09-09
runs (`vk4-arm64-20260909-134356`, `vk4b-rv64-20260909-112950`), identical on
both arches: **13** binaries, **1 283** headers, **58** `lib/` entries, 24 under
`share/`.

LunarG's `./vulkansdk` runs `clean_nonsdk_files` at the end of every invocation
(`CLEAN_NONSDK_FILES=1` is the default), and its `BUILD_DXC` arm deletes eight
paths from the prefix it just built. The tarball amd64 unpacks is that script's
output, so **amd64 has never carried them**; our cross build installs into
`<arch>/` *after* `./vulkansdk` has finished and its clean has run, so the
foreign prefixes kept them. Every path is arch-relative — the vendor's
`INCLUDEDIR` and `LIBDIR` are `${SDKDIR}/$(uname -m)/{include,lib}` — so nothing
shared is involved:

| pruned | what it is | on aarch64 |
| --- | --- | --- |
| `include/clang/`, `include/clang-c/` | the LLVM 3.7 fork's clang headers | 480 + 8 files |
| `include/llvm/`, `include/llvm-c/` | ditto, LLVM | 769 + 21 files |
| `lib/libdxil.so` | the DXIL validator, `dlopen`ed by name and never a `NEEDED` | — |
| `lib/libdxcvalidator.a`, `lib/libLLVMDxilHash.a`, `lib/libLLVMDxilValidation.a` | its static halves, already linked into `dxv` | — |

**What stays is everything amd64 has**: all 13 binaries, `include/dxc/` (the
public `dxcapi.h`/`WinAdapter.h` API), `lib/libdxcompiler.so` and the other 54
`lib/` entries — the `libLLVM*.a`/`libclang*.a` half of the 72-file `lib/` gap the
VK4 table names. Dropping those would swap one asymmetry for the opposite one.

**Disk is not the reason.** The four header trees are 14.8 MiB at the pinned DXC
commit (`a107ba61`, measured through the GitHub tree API) plus the tablegen output
the install adds, so call it low tens of MB per foreign arch against a prefix that
measured 60 MB on arm64 and 88 MB on riscv64 before VK4. The reasons are the other
two:

* **Parity.** VK4/VK5 closed on "the sets are identical, not merely equal in
  size". This was the one remaining direction of difference, and keeping it means
  any future prefix diff has to carry an exception list.
* **An LLVM 3.7 `llvm/` tree inside a directory that goes on the include path.**
  `_vulkan_setup_sdk_includes` exports `<archdir>/include` into `CPATH`,
  `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH` and `CMAKE_INCLUDE_PATH`, and
  `find_package(Vulkan)` hands the same directory to every consumer as
  `Vulkan_INCLUDE_DIR`. It resolves to the `x86_64` prefix today only because
  `install_vulkan_sdk` `rm -rf`s the version dir before each extract, so
  `<archdir>` does not exist yet when that function runs — an ordering accident,
  not a guard. A `#include <llvm/IR/…>` that reaches those headers ahead of LLVM
  23 is the TVM build, and it would not fail anywhere obvious.

`_vulkan_target_prune_nonsdk_dxc` (`02-toolchain/vulkan.sh`) runs from
`_build_vulkan_targets`, which only the foreign lanes reach, immediately after
`_vulkan_target_build_sdk_rest` — `dxc` is the **last** row of
`_VK_TARGET_COMPONENTS`, and the install manifest confirms the row is the sole
writer of all eight paths. It no-ops unless `<archdir>/include/dxc/dxcapi.h` is
there: that file is the vendor's own marker that a dxc install landed *here*, and
it is what stops the helper being pointed at `/opt/llvm-target`, whose
`include/llvm` is 41 MB of the real LLVM 23 headers.

### The other three arms are NOT mirrored

`clean_nonsdk_files` has three more arms, and the foreign prefixes trip all of
them. They are left alone deliberately:

| arm | what the foreign prefixes carry | why it stays |
| --- | --- | --- |
| `BUILD_SPIRV_HEADERS` | `include/spirv/{1.0,1.1,1.2}` (13 files each) + `spir-v.xml` | 40 legacy-grammar files, harmless, and `spir-v.xml` is the grammar a consumer may actually read |
| `BUILD_VUL` | `include/vulkan/layer/` (2 files) | the layer-authoring headers; free |
| `BUILD_EXTENSION_LAYERS` | `lib/libVkLayer_khronos_timeline_semaphore.so` + its `explicit_layer.d` manifest | this is **functionality**, and it is why the foreign arches show 10 layer manifests against amd64's 9. Mirroring here would delete a working layer to match a prefix that is poorer |

VK7 named the DXC arm; that is the arm the code mirrors. If the owner ever wants
byte-for-byte vendor parity instead, the first two rows are cheap and the third
is a regression.

## Upstream patches: recheck on every SDK bump

`_vulkan_patch_component` applies these to the pinned SDK source before the cross
build. Each one exists because the pinned revision predates an upstream fix, so
**each becomes droppable the moment the SDK ships a revision that carries it.**
Check this table whenever `VULKAN_VERSION` moves in `versions.env`.

| patch | upstream | droppable when |
| --- | --- | --- |
| `slang/001-riscv64-arch-detection.patch` | [shader-slang/slang#12305](https://github.com/shader-slang/slang/pull/12305), merged 2026-08-01 | the SDK's slang ref is ≥ `v2026.16` (2026-08-20 is the first release carrying it) |

**How to check it in one command**, once the new source is on disk:

```bash
grep -e '__BYTE_ORDER__' <sdk>/source/slang/include/slang.h && echo "PR #12305 is in -- drop the patch"
```

`apply-patch.sh` fails loudly rather than silently skipping if a patch stops
applying, so a bump that makes one obsolete announces itself. Delete the patch
file, its `case` arm in `_vulkan_patch_component`, and this row together.

### Why the slang one exists

SDK 1.4.357.0 pins slang to `vulkan-sdk-1.4.357` = commit `84792eb15`
(2026-07-11), three weeks before the fix merged. At that revision `include/slang.h`
derives pointer size and byte order from a hand-maintained architecture whitelist
with no `__riscv` arm, and riscv64 therefore hits **two** defects at once —
verified by running the pinned header's macro block through the preprocessor with
the x86 macros off and `__riscv` on:

```
VORHER   #error "Couldn't determine endianness"
         PTR64=(0 | 0 | 0)  PTR32=1  LE=0  BE=0
NACHHER  PTR64=1            PTR32=0  LE=1  BE=0
```

The `#error` is the loud half. The silent half is worse: `SLANG_PTR_IS_64` was an
**unconditional** `#define` over that whitelist, so it reads 0 on a 64-bit target
and `SlangInt` narrows to `int32_t` — and being unconditional, `-DSLANG_PTR_IS_64=1`
on the command line cannot override it. Patching only the endianness would produce
a slangc that links and then misbehaves. The backport also adds a
`sizeof(void*)` static_assert so that half can never be silent again.

Gentoo's `dev-util/shader-slang-2026.16.ebuild` carries `KEYWORDS="~amd64 ~arm64
~riscv"` — the first version with the fix is also the first anyone keyworded for
riscv, which is the independent confirmation that nothing else blocks the arch.

## Components that need a host tool

Two rows are Canadian crosses, the shape `02-toolchain/llvm-cross.sh` already
uses for `clang-tblgen`: something has to EXECUTE on the build host while the
rest compiles for the target. `_vulkan_target_dynamic_args` carries the flags a
static table cannot, because they are paths.

**slang.** Its build runs its own generators (`slang-embed`, `slang-generate`,
`slang-fiddle`, …). Cross-built, they are target binaries the build host cannot
run, and the lane died on exactly that:

```
FAILED: [code=127] prelude/slang-cpp-host-prelude.h.cpp
```

The host `./vulkansdk` run has already built them into
`source/slang/build/generators/Release/bin`, so the cross configure is pointed
there with `SLANG_GENERATORS_PATH`. `SLANG_SLANG_LLVM_FLAVOR=DISABLE` and
`SLANG_ENABLE_DXIL=OFF` keep the same build from fetching x86_64 prebuilts.

**vulkanCapsViewer.** Needs Qt6 for the target (`qt6-base-dev:${arch}` above) and
Qt's own host tools — `moc`, `rcc`, `uic` — from the build host, which is what
`QT_HOST_PATH=/usr` names.

**dxc IS a row now (VK4, 2026-09-09), and what changed is the premise.** This
paragraph used to say the Canadian cross had no host-built `clang-tblgen` to
point at, "and no such binary exists on disk here". That was true only because
the HOST list never named `dxc`. Naming it makes `./vulkansdk` clone and build
DXC on x86_64 first, which is exactly what produces `build/bin/llvm-tblgen` and
`build/bin/clang-tblgen` — the same shape slang's generators already have. The
cost is real and worth stating: it is an LLVM-sized build, it now runs on every
foreign lane, and the clone is `--recurse-submodules` with no `--depth`.

What slang does is unrelated and unchanged: it fetches a prebuilt x86_64
`_dxc_probe/dxc_v1.9.2602.tar.gz`, which is why its row keeps
`-DSLANG_ENABLE_DXIL=OFF`.

## VK_LAYER_PATH pointed at a directory that has never existed

`Dockerfile.package` and `04-runtime/runtime-paths.env` both set

```
VK_LAYER_PATH=/opt/vulkan/active/etc/vulkan/explicit_layer.d
```

and SDK 1.4.357 has no `etc/` under any arch prefix at all: the explicit layers
install to `<arch>/share/vulkan/explicit_layer.d`. Both now name that path.

Two things about it are worth knowing before treating the variable as live. The
entrypoint sources LunarG's `setup-env.sh`, which UNSETS `VK_LAYER_PATH` and
exports `VK_ADD_LAYER_PATH` instead — measured: the variable is **empty in every
running image**, so this is the value a consumer that does NOT source that script
gets. And a foreign arch only has layers to point at because the cross build
installs them; before VK1 there were none, which is why nobody noticed the path
was wrong.

## The toolset floor only ratchets up

The prefix shipped **2 of 52** tools for months. Nothing caught it because
`check_vulkan_toolset` required six names and *warned* about the rest, and a WARN
in a green run is invisible. `smoke-runtime-image.sh` now asserts three things
about `${VULKAN_SDK}` in the running image:

* `_VK_REQUIRED_TOOLS` — the twenty names both foreign lanes shipped on
  2026-09-05/07 (nineteen installs plus the `glslangValidator` alias). A missing
  one fails the lane.
* `_VK_TOOLSET_FROZEN` — `<arch>:<tools>:<layer manifests>`, floors measured on
  shipped bytes: `amd64:>=52:>=1`, `arm64:>=20:>=4`, `riscv64:>=20:>=4`. Below a
  floor fails; above it the gate prints `RATCHET: floor 20 -> N, record it`, so a
  gain is written down instead of drifting. An arch with no row fails rather than
  inheriting silence.
* the validation layer manifest, by name. That one moved from WARN to FAIL:
  developing a Vulkan application without the layers is the thing this whole
  exercise was for.

`_VK_REPORTED_TOOLS` keeps its job as the bucket one step behind the floor: it
now holds what VK2's four components add (`gfxrecon-*`, `slangc`,
`vulkanCapsViewer`). They warn until a lane proves them, and then they are
promoted into the required set and the floors are re-recorded — once, after the
chain that lands them, not twice.

The same idea runs one stage earlier, where it costs minutes instead of hours.
`_VK_REQUIRED_COMPONENTS` names the six whose loss is not optionality —
`vulkan-loader`, `spirv-tools`, `glslang`, `shaderc`, `vulkan-tools`,
`vulkan-validationlayers` — and `_vulkan_target_verdict` fails the SDK stage when
one of them was attempted and failed, rather than letting the runtime smoke find
it much later. `VULKAN_CROSS_REQUIRED=''` hands that decision back to the
operator. Every other row stays non-fatal exactly as before.

## The source tree does not ship

`source/` is 3.9 GB of checkouts and builder-arch objects. It is read by the
cross builds above and by nothing after them, so it is dropped in the same run —
see `docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs`.
Dropping it does not weaken the target prefix: what you compile an application
against is the installed prefix, not the SDK's own sources.
