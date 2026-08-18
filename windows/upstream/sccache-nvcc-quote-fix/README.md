# sccache nvcc quote-protection fix (Windows dropped-instantiation miscompile)

**Status 2026-08-18: fix VERIFIED on the reproducer, PR submitted: https://github.com/mozilla/sccache/pull/2811** (patch-verify probe:
bare 3189 == wrapped 3189 defined symbols; only 1:1-substituted `??_C@`
string literals differ, which is the expected module-id naming divergence).

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

`0001-nvcc-Windows-protect-escaped-quotes-in-dryrun-lines-.patch`: protect
`\"` with a sentinel around the backslash flatten so shlex sees the original
quoting. One hunk in `fold_env_vars_or_split_into_exe_and_args`.

## Verification

`windows/scripts/probe-sccache-patch-verify.ps1` (via
`Dockerfile.sccache-patch-verify`): builds the pin + patch in-container and
re-runs the single-TU replay (`probe-onnx-tu-replay.ps1`, which carries the
full forensic chain: symbol diff, define delta, intermediate stub counts,
tokenizer autopsy).

## Shipping (base-tier - do NOT land alone)

Production builds sccache via `setup-rust-toolchain.ps1` (`cargo install
--git --rev` in `Dockerfile.base`). Carrying this patch means switching that
step to clone + `git apply` + `cargo install --path .` (or pinning a fork
rev) - a BASE rebuild, so it rides the next base-tier batch (backlog #114).
After it ships: the three-canary bar (verify-cuda-cache, fused_moe compile,
full providers_cuda link) before flipping SCCACHE_CUDA_LAUNCHER on, plus a
cache-hit second run. Upstream: owner submits the patch as a PR (this dir is
the prepared package, hcsshim-teardown-timeout precedent).
