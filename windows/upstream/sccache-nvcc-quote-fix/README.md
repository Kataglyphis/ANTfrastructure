# sccache nvcc quote-protection fix (Windows dropped-instantiation miscompile)

**Status 2026-08-19: PR https://github.com/mozilla/sccache/pull/2811 MERGED
upstream (ffac4a5, merged by sylvestre).** SCCACHE_GIT_REV bumped to the
merge commit; 0001/0002 deleted (upstream carries them). The series now
holds only `0003` (--diag-suppress separated form, OpenCV #115) - local
until its own PR lands (draft in PR.md, owner submits). 0003 was
`git apply --check`ed against ffac4a5 before the bump.

(2026-08-18 verification, for the record: patch-verify probe bare 3189 ==
wrapped 3189 defined symbols; only 1:1-substituted `??_C@` string literals
differ, which is the expected module-id naming divergence.)

## The bug (mozilla/sccache, present at pin e9b15a3 / post-#2722)

`nvcc --dryrun` on Windows prints string-valued defines with escaped quotes:

    -D "FILE_NAME=\"onnxruntime_providers_cuda.dll\""

`src/compiler/nvcc.rs` flattens `\` to `/` BEFORE tokenizing the line, so
every `\"` becomes `/"` and the quote structure collapses at the first such
define. `shlex::split` then packs everything after it into one giant token
(measured: 493 chars containing ~30 `-D` pairs, incl. `USE_CUDA=1`,
`USE_FLASH_ATTENTION=1`, `USE_MEMORY_EFFICIENT_ATTENTION=1`,
`USE_FP8_KV_CACHE=1`). The host preprocess producing `cpp4.ii` runs without
those defines, cudafe++ generates no stubs for the `#ifdef`-guarded
instantiations, and the final object silently loses them — surfacing hours
later as `lld-link: undefined symbol` (ONNX Runtime v1.28.0:
`BiasSoftmaxImpl<double>`, `QkvToContext<*, __nv_fp8_e4m3>`,
`run_memory_efficient_attention`; onnxruntime-genai's CUDA TUs fail hard).

## The fix

The quote fix itself (formerly 0001/0002 here) MERGED upstream in
mozilla/sccache#2811 — those files are deleted, the pinned rev carries them.
What remains on disk is `0003-nvcc-accept-the-diag-error-family-...patch`:
accept the space-separated `--diag-suppress <n>` / `--diag-error <n>` forms
nvcc emits in dryrun lines (upstream PR mozilla/sccache#2816, open).

## Verification

`windows/scripts/diagnostics/probe-sccache-patch-verify.ps1` (via
`Dockerfile.probe` with `-ProbeScript probe-sccache-patch-verify.ps1`): builds the pin + patch in-container and
re-runs the single-TU replay (`probe-onnx-tu-replay.ps1`, which carries the
full forensic chain: symbol diff, define delta, intermediate stub counts,
tokenizer autopsy).

## Shipping — CURRENT STATE (2026-08-21)

SHIPPED: production builds sccache from the merged upstream rev via
`setup-rust-toolchain.ps1` (SCCACHE_GIT_REV pin in versions.env = ffac4a5,
clone + git apply of 0003 + `cargo install --path .`). The pre-merge plan
this section used to describe (backlog #114 base-tier batch) is done.
Standing rule unchanged: CUDA compiles stay BARE nvcc — the launcher-default
question is CLOSED (miscompile is storage-independent; see the #99/P0b
verdict in docs). 0003 rides until mozilla/sccache#2816 merges, then this
whole directory retires like 0001/0002 did.
