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

## Nothing is skipped

`_vulkan_build_components` used to drop `vulkan-tools`, `gfxreconstruct`, `vcv` and
`slang` on a cross lane, and carried nine more skip rows that the consuming loop
never read. Both are gone. Skipping a component skips its **checkout**, and
`source/` is what every target build reads — so a skip that looked like it only
saved host build time was silently deciding what the target arch could never have.

`_VK_TARGET_COMPONENTS` is the table of what gets cross-built, one row per
component: label, checkout candidates, extra CMake args. LunarG's directory names
do not all match the component name (`shaderc` keeps its CMake project one level
down in `src/`, which is why `glslc` looked unbuildable at first), so each row may
name several candidates.

The heavy tail — `gfxreconstruct`, `slang`, `vulkanCapsViewer` — is attempted like
everything else. `slang` needs host LLVM `tblgen` and `vulkanCapsViewer` needs Qt
for the target, so both may well fail to configure; they fail fast, non-fatally, and
the build log says so rather than a comment asserting it.

## The source tree does not ship

`source/` is 3.9 GB of checkouts and builder-arch objects. It is read by the
cross builds above and by nothing after them, so it is dropped in the same run —
see `docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs`.
Dropping it does not weaken the target prefix: what you compile an application
against is the installed prefix, not the SDK's own sources.
