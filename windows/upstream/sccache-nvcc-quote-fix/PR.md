# PR draft: nvcc (Windows): protect escaped quotes in dryrun lines before flattening backslashes

**Title:** `nvcc (Windows): protect escaped quotes in dryrun lines before flattening backslashes`

**Body:**

## Problem

On Windows, `nvcc --dryrun` prints string-valued defines with escaped quotes:

```
-D "FILE_NAME=\"onnxruntime_providers_cuda.dll\""
```

`fold_env_vars_or_split_into_exe_and_args` flattens `\` to `/` *before*
tokenizing the line (to normalize paths), which turns every `\"` into `/"`
and collapses the line's quote structure at the first such define.
`shlex::split` then packs everything after it into one giant token — on a
real ONNX Runtime v1.28.0 compile we measured a **493-character token
containing ~30 `-D` pairs** (`USE_CUDA=1`, `USE_FLASH_ATTENTION=1`,
`USE_MEMORY_EFFICIENT_ATTENTION=1`, `USE_FP8_KV_CACHE=1`, ...).

The host preprocess that produces `cpp4.ii` therefore runs **without** those
defines, `cudafe++` generates no stubs for the `#ifdef`-guarded explicit
instantiations, and the loss propagates silently through ptx/cubin into the
final object. It surfaces hours later as `lld-link: undefined symbol`
(`BiasSoftmaxImpl<double>`, `QkvToContext<*, __nv_fp8_e4m3>`,
`run_memory_efficient_attention`) — a silent miscompile, not a build error.
onnxruntime-genai's CUDA TUs fail hard (nvcc exit -2) through the same path.

Likely the mechanism behind long-standing Windows reports such as #1077, and
the remaining actionable half of #2808 (whose deadlock we could no longer
reproduce once our storage backend was healthy — see the issue addendum).

## Reproduction (single command)

ONNX Runtime v1.28.0, `onnxruntime/contrib_ops/cuda/math/bias_softmax_impl.cu`,
compiled with the exact command from ORT's build.ninja (extract via
`ninja -t commands`), CUDA 13.3.1, four `-gencode` archs, cl.exe host:

* bare nvcc: 3,189 defined symbols (identical numbers on ORT v1.29.0 - the trigger defines are version-independent)
* `sccache nvcc` (cold cache): 2,628 — every `double` instantiation's
  `__device_stub__` missing, float/half intact
* intermediates: `cudafe1.stub.c` ddd-marker counts 88 (bare) vs 0 (wrapped);
  the wrapped `cpp4.ii` lacks exactly the `#ifdef USE_CUDA` instantiation

## Fix

Protect the `\"` escapes with a sentinel (`\u{1}`) around the backslash
flatten and restore them afterwards, so `shlex` sees the original quoting.
One hunk in `fold_env_vars_or_split_into_exe_and_args`, plus a regression
test (`test_group_nvcc_subcommands_preserves_escaped_quotes_in_defines`)
that feeds an escaped-quote dryrun line through the grouping and asserts
every define survives as its own token (the giant-token fingerprint —
`" -D "` inside a single argument — is asserted absent).

With the patch, the reproducer's object matches bare nvcc symbol-for-symbol
(3,189 == 3,189; only 1:1-substituted `??_C@` string literals differ, the
expected module-id naming divergence).

**Posting notes (not part of the body):** branch
`fix/nvcc-dryrun-escaped-quotes-windows` on the Kataglyphis fork; reference
#2808 and #1077 in the description, do not claim to close #2808 (its
deadlock half is a separate finding).

---

# PR 2 draft (SEPARATE upstream PR - owner submits): nvcc diag-family flags

**Patch:** `0003-nvcc-accept-the-diag-error-diag-suppress-diag-warn-f.patch`
**Branch suggestion:** `fix/nvcc-diag-suppress-separated` from the pin.

**Title:** `nvcc: accept the --diag-error/--diag-suppress/--diag-warn family`

**Body** (written to read like a build-log war story, not a report - keep
this tone if editing):

While trying to get OpenCV's CUDA build cached on Windows I noticed that
none of its .cu files ever got cache hits. The server log shows every
single compile being rejected with:

```
CannotCache(multiple input files)
```

OpenCV passes `-Xcudafe --display_error_number --diag-suppress 1394,1388`
on every CUDA file. The problem: `--diag-suppress` (and its siblings
`--diag-error` / `--diag-warn`) are missing from the nvcc argument table.
nvcc accepts the value either attached (`--diag-suppress=1394,1388`) or as
a separate argument, and CMake/OpenCV happen to emit the separated form -
so sccache parses `1394,1388` as a bare token, takes it for a second input
file and refuses the compile.

Easy to reproduce with any single nvcc compile: add
`--diag-suppress 1394,1388` and the request is forwarded uncached
(`requests executed 0` in the stats), switch to `--diag-suppress=1394,1388`
and the same compile caches fine.

This adds the three flags in both their single- and double-dash forms
(`CanBeSeparated`, `PassThrough`) plus a regression test for the separated
form. With the patch applied, OpenCV's CUDA compiles (155 files in our
build) all cache.

Possibly related: #2726 reports the same `multiple input files` rejection
for another flag the parser doesn't know (`-Xcompiler "/openmp:llvm"`,
mis-split at the MSVC layer). Same failure mode, different argument table -
not fixed by this PR.

**Posting notes (not part of the body):** issue search 2026-08-19 found NO
existing report of the separated diag-suppress bug (fresh find). #1077
matches textually but is the attached `--diag_suppress=` underscore form
inside one -Xcudafe value - do not link it here. #2372 (hard fail on
uncacheable nvcc args) is optional context, not required. No pending PR
touches the diag family.
