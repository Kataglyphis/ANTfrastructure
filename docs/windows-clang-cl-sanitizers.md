<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# clang-cl sanitizers on Windows — the runtime choices behind `Sanitizers.cmake`

Everything here was learned by running an instrumented /MD Flutter app end to
end on Windows, not from release notes (AccelerANTgine, 2026-07-16).
[`cmake/Sanitizers.cmake`](../cmake/Sanitizers.cmake) encodes the conclusions;
this page carries the reasoning its two-line comment ceiling keeps out of the
module.

All of it is Debug-only: every sanitizer compile flag, define and runtime link
the module adds is wrapped in `$<$<CONFIG:Debug>:...>`, so a multi-config
generator (Visual Studio, Ninja Multi-Config) never instruments its Release
config, and single-config non-Debug builds are byte-identical with sanitizers
requested or not.

## Dynamic ASan runtime: `/clang:-shared-libsan`

clang-cl's `/fsanitize=address` defaults to the **static** ASan runtime. Static
runtime objects stamp `MT_StaticRelease` `failifmismatch` records into every
object file, and those collide at link with any /MD (dynamic CRT) build — which
is the whole Flutter/plugin world. `-shared-libsan` makes the compiler emit
dynamic-ASan link directives instead, matching /MD.

## UBSan: trap mode when ASan is absent

There is no /MD UBSan runtime on Windows — `clang_rt.ubsan_standalone` is built
/MT and failifmismatch-es against /MD builds. So the module splits by case:

* **UBSan together with ASan**: the dynamic-CRT ASan runtime provides the UBSan
  handlers and prints rich reports; nothing extra to link.
* **UBSan alone**: `-fsanitize-trap=undefined` — no runtime needed; undefined
  behavior raises an immediate debugger break / fast-fail at the offending
  instruction.

This split is also why the module passes no `-fsanitize=` flags at link for
clang-cl: lld-link does not understand them, trap mode needs no runtime, and
the ASan runtime is linked explicitly (next section).

## Microsoft's ASan runtime, not LLVM's

Runtime choice matters for a full app, not just standalone test exes. LLVM's
`clang_rt.asan_dynamic` loads **after** `ucrtbase` in the dependency graph, so
allocations made during CRT/COM startup are unhooked; when `combase`/`ole32`
later free them through ASan's interceptors, LLVM's runtime aborts with an
unsuppressible bad-free and the app never renders a frame. Microsoft's ASan
runtime (shipped with VS BuildTools) tracks Windows heap ownership correctly
and passes those foreign frees through, so the instrumented app runs clean.

Both toolchains name the import lib and thunk identically
(`clang_rt.asan_dynamic-x86_64.lib`,
`clang_rt.asan_dynamic_runtime_thunk-x86_64.lib`) and clang's instrumentation
interface is a subset of Microsoft's runtime exports, so the module keeps
clang's instrumentation and simply points the link search at Microsoft's
`lib/x64`. Selection order:

1. `$ENV{VCToolsInstallDir}/lib/x64` — set by vcvars / VS developer shells.
2. A glob over
   `C:/Program Files*/Microsoft Visual Studio/*/BuildTools/VC/Tools/MSVC/*/lib/x64`.
3. Fallback with a WARNING: LLVM's own `clang_rt` dir from
   `--print-resource-dir` — fine for standalone test/fuzz exes, but a full app
   aborts on startup as described above.

**Run-time staging is the consumer's job.** The exe links against the import
lib; the matching `clang_rt.asan_dynamic-x86_64.dll` from the same
`VC\Tools\MSVC\<ver>` must sit next to the app exe (or on PATH) at launch. Each
consumer's app-launch script stages it — the module cannot, because it never
knows where the final exe lands.
