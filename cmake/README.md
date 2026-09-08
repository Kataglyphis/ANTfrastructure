<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Shared CMake modules

Reusable CMake modules, consumed by every Kataglyphis C++ project that vendors
this repo as a submodule. Adopted here on 2026-08-07 from a consumer that had
carried its own copies (see the `Kataglyphis-CMakeTemplate` note at the bottom).

## Consuming them

Put this directory on `CMAKE_MODULE_PATH` and include modules **by name** — never
by path. That is what lets a module move between the consumer and this repo
without its callers changing:

```cmake
set(KATAGLYPHIS_CONTAINERHUB_CMAKE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/ContainerHub/cmake")
if(NOT EXISTS "${KATAGLYPHIS_CONTAINERHUB_CMAKE_DIR}/Sanitizers.cmake")
  message(FATAL_ERROR "ContainerHub submodule not checked out. Run: git submodule update --init --recursive")
endif()

# Local first, so a project can override any module by dropping a same-named
# file in its own cmake/ without editing this repo.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake" "${KATAGLYPHIS_CONTAINERHUB_CMAKE_DIR}")

include(PreventInSourceBuilds)
include(Sanitizers)
```

The explicit existence check matters: without it a missing submodule surfaces as
`include could not find requested file: Sanitizers`, which reads like a typo
rather than an uninitialised checkout.

## What is here

| Module | Provides |
| --- | --- |
| `Cache.cmake` | `myproject_enable_cache` — ccache/sccache launcher wiring |
| `CompilerBuildFlags.cmake` | `myproject_apply_compiler_build_flags` + flag-strip helpers; owns the clang-cl `-fms-compatibility-version` pin and applies it to Debug, Release **and RelWithDebInfo** (which is what every `*-Profile` preset actually resolves to) |
| `CompilerWarnings.cmake` | `myproject_set_project_warnings` — the per-compiler warning set |
| `CPackCommon.cmake` | `kataglyphis_cpack_common` — the CPack *wiring*: generator selection per platform, the architecture-normalised package name, and the NSIS, WiX, DEB and AppImage blocks. A **macro**, because CPack reads `CPACK_*` out of the scope that runs `include(CPack)`. Every per-product value is an argument; `VENDOR` and `WIX_UPGRADE_GUID` are mandatory, the latter because the two consumers it was hoisted from were carrying the *same* MSI upgrade code |
| `Doxygen.cmake` | `enable_doxygen` — configures `Doxyfile.in` from the caller's source dir |
| `GTestDiscovery.cmake` | `kataglyphis_register_gtest_target` — the one way to register a GoogleTest binary with CTest: `gtest_discover_tests` normally, an `add_test` + explicit-`PATH` fallback where clang-cl discovery dies with `0xc0000135`, and opt-in `WORKING_DIRECTORY`. Includes `GoogleTest` itself |
| `Hardening.cmake` | `myproject_enable_hardening` |
| `InterproceduralOptimization.cmake` | `myproject_enable_ipo` |
| `KataglyphisAppImage.cmake` | `kataglyphis_provision_appimagetool`, `kataglyphis_appimagetool_pin` — appimagetool from the immutable release tag pinned in `linux/scripts/01-core/versions.env`, checksum-verified, **fatal** on mismatch or download failure |
| `KataglyphisCMakeHelpers.cmake` | `kataglyphis_collect_module_interfaces` — globs C++20 module interface units |
| `PreventInSourceBuilds.cmake` | in-source build guard |
| `SanitizerSupport.cmake` | `myproject_supports_sanitizers`, `myproject_default_debug_sanitizers` — what this toolchain can run, and Debug defaults |
| `Sanitizers.cmake` | `myproject_enable_sanitizers` — applies the selected set to a target, Debug-gated; clang-cl runtime story: [`../docs/windows-clang-cl-sanitizers.md`](../docs/windows-clang-cl-sanitizers.md) |
| `Speedup.cmake` | parallel build level from the detected core count |
| `StandardProjectSettings.cmake` | build-type default, colour diagnostics, IPO probe |
| `StaticAnalyzers.cmake` | `myproject_enable_clang_tidy` (optional 3rd arg: `--header-filter` regex; report-only, never `--fix`), `myproject_enable_cppcheck` (probes the binary, disables with a warning if unusable) |
| `Tests.cmake` | `myproject_enable_coverage` — per-compiler coverage flags (GNU, clang, clang-cl incl. explicit `clang_rt.profile` linkage); every build type except Release |

The `myproject_` prefix is the upstream cpp-best-practices convention these
modules came from. It is kept deliberately: renaming would touch every call site
in every consumer for no behavioural gain.

## What does NOT belong here

Anything encoding one project's *policy* rather than a reusable *mechanism*:
the option list and its defaults, the language standard, whether exceptions are
on, whether C++ modules are mandatory, packaging *values*, dependency lists.
`CPackCommon.cmake` is the worked example of that line rather than an exception
to it: the branch structure is here, while the icons, the installer copy, the
MSI upgrade code and the `.desktop` name stay in the consumer and arrive as
arguments.
Those stay in the consumer's own `cmake/` — typically a `ProjectOptions.cmake`
that includes the modules above and composes them.

The dividing question is the same one the repo-wide rule asks: *would another
project want this verbatim?* A sanitizer-support probe, yes. "This project
disables exceptions", no.

## Relationship to Kataglyphis-CMakeTemplate

`Kataglyphis-CMakeTemplate` holds diverged copies of several of these modules.
It is a fork-once project template, not a consumed library — so drift there is
expected and is not reconciled from here. When a fix applies to both, land it
here first; this copy is the one real builds consume.
