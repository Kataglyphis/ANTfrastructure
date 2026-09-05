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

`x86_64/bin` holds 52 tools, but inside an arm64 image every one of them is an
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

## The source tree does not ship

`source/` is 3.9 GB of checkouts and builder-arch objects. It is read by the
cross builds above and by nothing after them, so it is dropped in the same run —
see `docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs`.
Dropping it does not weaken the target prefix: what you compile an application
against is the installed prefix, not the SDK's own sources.
