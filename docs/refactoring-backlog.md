# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document. Every item here is OPEN. Completed/obsolete items and the
observation journal live in the archives:
[`…-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md),
[`…-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md),
[`…-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md),
[`…-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md),
[`…-archive-2026-09-02.md`](refactoring-backlog-archive-2026-09-02.md),
[`…-archive-2026-09-03.md`](refactoring-backlog-archive-2026-09-03.md),
[`…-archive-2026-09-07.md`](refactoring-backlog-archive-2026-09-07.md),
[`…-archive-2026-09-09.md`](refactoring-backlog-archive-2026-09-09.md),
[`…-archive-2026-09-17.md`](refactoring-backlog-archive-2026-09-17.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary (only the prefixes this OPEN file still uses): **F#**=the size and
duplication registers; **CON#**=an image gap a consumer lane hit.
Everything else is archive-only: **CON1–CON6** closed 2026-09-17/18 (the consumer
issues, the last one measured and aligned at Flutter 3.47.4), **EX** closed on
2026-09-07/09 (the extent gates scan `linux/llm-stack` and froze its rows),
**VK/AS** closed on 2026-09-17, **CC/CL/CS/AB/R#/YB/DISK/APP** on 2026-09-07,
**HT/GH** before them, **QW/TC/SMK** in the 2026-09-04 waves, and the rest long
before that.

Last groomed: **2026-09-18, after CON4's Windows half was measured, the
dependency wave landed and the two owner questions were answered** — every closed
narrative moved to
[`…-archive-2026-09-17.md`](refactoring-backlog-archive-2026-09-17.md) and the
CHANGELOG. What stays here is **two registers**, plus **four image gaps**
(CON7–CON10) opened on 2026-09-24. Every
earlier grooming's warning still applies: **re-derive; do not trust a number
here, including these.**

## OPEN

### F1. The extent queues — what is left after every row got a verdict [M each]

**`function-size.allow` and `code-complexity.allow` are the authority — do not
transcribe them here.** Both are fully reviewed: **24** function rows over 80 lines
and **59** `cc` rows over 15 (plus 1 nesting), every one carrying a verdict that says what its
number IS. Read the reasons, not the numbers — and re-derive the counts from
`verify_code_size.py` / `verify_code_complexity.py`, never from this line.

**Four measurement facts that decided most of the remaining verdicts**, and that a
future reader should not re-discover:

* **Heredoc payloads are not shell.** `assert_pinned_versions` is 44 lines of shell
  around a **312**-line embedded Python program — top of the size queue and the
  WORST candidate on it, because splitting the shell moves 44 lines and its `cc` is
  **7**. Same shape: `assert_app_venv_parity` (20 around 72),
  `_gst_xpy_write_config` (14 around 70), `ensure_meson_cross_file` (56 around a
  37-line Meson-ini template).
* **Much of the `cc` here is a TABLE, not tangle**: flag and subcommand parsers
  (`parse_tvm_args` 13 options, `append_tvm_cmake_args` 15, `setup-dependencies.sh`
  `main` 5 flags × 10 commands), feature tables (`_ffmpeg_probe_core_codecs` is
  sixteen `if probe; then --enable-<codec>` lines and nothing else), and two rows
  where the metric is simply literal — `dump_debug_info` (cc 23) contains no
  decision at all, just ~20 which-then-`--version` pairs each swallowed, and
  `_torch_run_setup_py` counts the size of torch's build environment.
* **Refusal matrices cost safety when flattened**: `_chain_prune_archived_logs`
  (every branch is a refusal to delete the wrong thing), `_manifest_wrapper_gate`
  (the cell that decides whether a manifest would MIX releases),
  `install_target_packages`, `override_soundtouch_codeberg_checksum`.
* **Precedence ladders where the ORDER is the contract**: `host_python_bin`,
  `install_abseil_headers`' five download/extract rungs, `_detect_gcc_cxxabi_header`,
  `configure_opencv_build_env`'s gstreamer-libdir search (the RV1-GST-PC ladder).

**One row still carries a KEEP verdict worth keeping:** `media_common_init` (29) —
a module loader whose load ORDER is load-bearing. A table plus a loop would read
shorter and say less; the ordering is the knowledge.

**The last outside-the-closure row closed on 2026-09-18.** `bump_versions.py
main` (160) is now 32: `linux/scripts/tests/test-bump-versions.sh` — 40
assertions over fake specs, in-process — was the coverage it was blocked on,
then the split into `_parse_args` / `_lookup` / `_sweep` / `_safe_row` /
`_report_row` / `_write_phase` and the reporting helpers. Its
`function-size.allow` and `code-complexity.allow` rows were deleted rather than
re-baselined. Every named row left in the two registers is inside the build
closure.

**Two rows carry a "do not do the obvious thing" verdict.** `verify_comment_size.blocks`
(nesting 6): the honest fix is importing `verify_code_size.scan` like every other
extent gate, but that WIDENS the scan to `docs/scripts` and NARROWS it by
`SKIP_DIRS 'patches'` — it changes the gate's scope and needs a fresh
`comment-size.allow` baseline, which is different work from a nesting trim. And
`verify_package_names.load_arch` (17): every branch is a way the gate must not
produce a FALSE verdict, the all-or-nothing partial-fetch refusal above all.

### F2. Files over ~800 lines [L each, low priority]

**`file-size.allow` is the authority — do not transcribe it here.** The gate
prints `files: 13 over 800 lines; 13 frozen`; read it there. All rows were
reviewed and all but the one historical split are NOT split targets, each with a
reason a stranger can act on.

**Two verdicts worth not re-litigating.** `build-app-wheelhouse.sh` is the
near-miss: the stage suites extract blocks from it **by line range**, so a file
split silently re-aims them. And `smoke-runtime-image.sh` — which every earlier
version of this entry nominated as THE one to split — is an explicit **NO**: its
91 functions are the `check_*` / `_probe_*` assertions and the probe-and-verdict
layer they share, all over one image through one `_rt_run` under one `main()`. Its
length is the number of assertions it makes about the shipped bytes, and that
number growing is the gate succeeding.

**`lib/app-packaging.sh` crossed 800 on 2026-09-17** (CON2's scope probe + CON6's
finish-args block, 797 → 851); the row carries the NOT-a-split reason and the seam
that kept it that way. Record in
[`…-archive-2026-09-17.md`](refactoring-backlog-archive-2026-09-17.md).

### CON7. The published arm64 image predates the native GCC's libsanitizer [S, ★★]

**Fixed in source, not shipped.** AccelerANTgine's `Linux arm64 · build + test`
(run 36045732850, 2026-09-24) fails its `gcc` job at `absl/base/internal/dynamic_annotations.h:369:10:
fatal error: sanitizer/common_interface_defs.h: No such file or directory`, and its
`clang` job in the same run passes. That is the symptom e2de5852 fixed
(`_gcc_extra_target_libs` in `linux/scripts/02-toolchain/build-gcc.sh`;
[`cross-build-verification.md` § The native GCC ships libsanitizer](cross-build-verification.md#the-native-gcc-ships-libsanitizer)),
at 2026-09-24 04:43 UTC. The newest published `:latest`/`:latest-cross` index is from
2026-09-23 01:18 UTC (`latest-arm64` 2026-09-22 20:57), so no published image has it.
**Close by** rebuilding and publishing the Linux images (a push: the owner's call),
then re-running that lane. Pass = its `gcc` job compiles the abseil TU and links ASan.

### CON8. arm64: CMake with the image's GCC does not find libX11 [M, ★★]

**Symptom.** BeschleunigerBallett's `Linux arm64 · build + test` (run 36042437555,
4905b935): both GNU 16.2.0 presets, `linux-profile-GNU` and `linux-debug-GNU`, stop at
configure with GLFW's `Including X11 support`, then `Could NOT find X11 (missing:
X11_X11_LIB)`. The same run's `linux-debug-clang` (Clang 23.1.1), same image, same
runner, prints `Found X11: /usr/include`. The library is there; the GCC configure misses it.
**Hypothesis, unverified.** FindX11's `find_library` searches `<prefix>/lib/<arch>`
only once CMake has derived `CMAKE_LIBRARY_ARCHITECTURE`, and it derives that from the
compiler's implicit link directories. arm64's `cc` is the Canadian-native GCC (CON7's
section), no hub GCC is configured with `--enable-multiarch`, and
`linux/scripts/01-core/cross-meson.sh` already sets `CMAKE_LIBRARY_ARCHITECTURE` by
hand for the hub's own cross builds. No lane configures X11 with amd64's GCC, so
whether amd64 shares this is unknown.
**First step, before choosing a fix:** in the arm64 image, configure a two-line
project (`project(p C)` and `message(STATUS "arch=${CMAKE_LIBRARY_ARCHITECTURE}")`)
once with `CC=gcc` and once with `CC=clang`, and read `gcc -print-search-dirs`. Then
choose between the compiler reporting the multiarch directory and consumers passing
`CMAKE_LIBRARY_ARCHITECTURE`.

### CON9. Windows: the patched LLVM ships no `clang_rt.profile` [M, ★]

`windows/scripts/build/Build-LlvmFromSource.ps1` sets `COMPILER_RT_BUILD_PROFILE=OFF`
("profile fails to compile under clang-cl"), so `-fprofile-instr-generate` cannot
link with the image's clang-cl. BeschleunigerBallett's ClangCL presets stopped at
`Coverage was requested, but the clang-cl profile runtime is missing` (run
36042436962) and turned coverage OFF on 2026-09-24. Coverage is now measured on the
Linux lanes only. **Close by** building the profile runtime (re-diagnose the compile
failure first), then set BeschleunigerBallett's `myproject_ENABLE_COVERAGE` in
`x64-ClangCL-Windows-Base` back to ON.

### CON10. Windows: the patched LLVM ships no clang-tidy [M, ★]

The same script's `LLVM_ENABLE_PROJECTS=clang;lld` builds no `clang-tools-extra`, so
no `clang-tidy.exe` sits beside the image's compiler, and a foreign one cannot read
its BMIs. AccelerANTgine run 36008508666 ran scoop's and failed with `module file
'…kataglyphis.config_loader.pcm' built from a different branch () than the compiler`.
AccelerANTgine now uses the compiler's own clang-tidy when there is one, and otherwise
skips every TU that imports a module, which leaves its six self-contained `.ixx`
interfaces. **Close by** adding `clang-tools-extra` to the project list (a longer
LLVM build), then check that AccelerANTgine's step picks the compiler's own tidy
and covers every TU.

**Standing context, not a block:** `git push` is the agent's (2026-09-06) via
`gh auth setup-git` + HTTPS remotes, and ten of the thirteen files in
`linux/scripts/lib/` source a sibling `lib/log-bootstrap.sh` — a consumer that
copied ONE `lib/*.sh` file out on its own breaks on its next CI run, not here.
