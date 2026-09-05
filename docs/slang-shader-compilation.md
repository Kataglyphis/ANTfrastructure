<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Slang shader compilation (SPIR-V + WGSL)

Two behaviourally identical drivers compile a Slang shader tree:

| Lane | File |
|---|---|
| Linux / POSIX | `linux/scripts/lib/slang-compile.sh` |
| Windows | `windows/scripts/modules/WindowsSlang.Common.psm1` |

**They must be kept in step.** Both are project-agnostic — nothing about a
specific project is hard-coded. A thin wrapper sets the path variables, sources
the library, and calls `slang_compile_main`. Everything else is data, read from
a manifest JSON the wrapper points at.

The shell library deliberately does not set `-e`/`-u`/`-o pipefail`, so sourcing
it cannot change the caller's shell options; wrappers run under
`set -euo pipefail` themselves.

## Caller variables

**Required:**

| Variable | Meaning |
|---|---|
| `SLANG_COMPILE_MANIFEST` | the manifest JSON (schema below) |
| `SLANG_COMPILE_SOURCE_ROOT` | root of the `.slang` tree; every manifest path and every `-I` include path resolves against it |

**Optional** (default in the right column):

| Variable | Meaning | Default |
|---|---|---|
| `SLANG_COMPILE_SPIRV_OUTPUT_ROOT` | where `spirv` targets are written | `<source root>/build/spirv` |
| `SLANG_COMPILE_WGSL_OUTPUT_ROOT` | where `wgsl` targets are written | `<source root>/build/wgsl` |
| `SLANG_COMPILE_COMBINED_OUTPUT_DIR` | staging dir for the combined WGSL emit, before validation and copy | `<source root>/build` |
| `SLANG_COMPILE_DEST_ROOT` | root the manifest's `wgslMap` `dst` paths resolve against, i.e. the consuming repo root | `$PWD` |

## Manifest schema

Keys starting with `_` are documentation and ignored.

| Key | Shape | Meaning |
|---|---|---|
| `manifest[]` | `{ file, entry, stage, targets[], disabled? }` | one row per (entry point, target). `file` is relative to the source root; `targets` is any mix of `"spirv"` and `"wgsl"`; `disabled` rows stay as documentation without being compiled |
| `wgslMap[]` | `{ src, out, dst }` | the combined (whole-module) WGSL emit |
| `depthTexturePatches` | `{ "<out>": [ { pattern, replacement } ] }` | post-emit regex patches applied to that combined emit |
| `minSlangcVersionForWgsl` | `"MAJOR.MINOR"` | toolchain floor for the combined emit |

## Return codes from `slang_compile_main`

| Code | Meaning |
|---|---|
| 0 | success — also when the source root is absent and there is nothing to do |
| 1 | a `slangc` invocation failed, or an emit was rejected by the WGSL validator |
| 2 | a prerequisite is missing (`python3`, the manifest, or `slangc` itself) |

Code 2 is deliberately **not** a silent skip: a missing `slangc` once let CI pass
green with no compiled shaders at all.

## The combined-emit outcomes

`_slang_emit_one_wgsl` handles one `wgslMap` row and reports which of four
things happened; `slang_compile_combined_wgsl` owns the counters and turns them
into the summary line and the exit code.

| Return | Meaning | What the caller does |
|---|---|---|
| 0 | emitted, patched, validated, copied to `dst` | counts it into `SLANG_COMPILE_WGSL_EMITTED_COUNT` |
| 1 | `slangc` itself failed | records the source in the emit-failed WARN block; the run still exits 0 |
| 2 | the emit has a varying struct member with neither `@builtin` nor `@location` | records it in `SLANG_COMPILE_INVALID_EMITS`, which makes `slang_compile_main` exit 1 |
| 3 | the row names a source file that is not in the tree | nothing — a row can point at a shader another repo owns |

The asymmetry between 1 and 2 is deliberate. A failed `slangc` is a build
problem the log already shows; an emit that *succeeded* and is structurally
wrong is the regression this guard exists for, because the only thing standing
between it and a committed, naga-rejected shader is that exit code. In both
cases the destination file is left exactly as it was: nothing is copied until
the validator has passed.

A `depthTexturePatches` pattern that matches nothing is a WARNING, not a
refusal — it means `slangc`'s output moved under the pattern, which is worth
seeing but is not itself proof the emit is wrong.

## Staleness

An output is reused only when it is newer than its source **and** every `.slang`
file under the source tree **and** the manifest file itself. That is
conservative on purpose — an import or a manifest edit rebuilds every dependent.
