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

**dxc is NOT a row, and the reason is not "host-only".** slang does not build
DXC here; it fetches a prebuilt x86_64 binary
(`_dxc_probe/dxc_v1.9.2602.tar.gz`) and `libdxcompiler.so` comes from that
tarball. The Canadian-cross pattern needs a host-built `clang-tblgen` from DXC's
own LLVM fork to point at, and no such binary exists on disk here. Cross-building
DXC means building it from source on the host first
(`SLANG_DXC_BUILD_FROM_SOURCE=ON`), which is an LLVM-sized build, not a table
row.

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
