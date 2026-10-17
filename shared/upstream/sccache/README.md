# The hub's sccache build

Both lanes install sccache from the hub's release `sccache-v<SCCACHE_BUILD_ID>`, not from
mozilla's. Two bugs that cost cache hits are fixed upstream, and no release carries either fix
yet:

| Bug | Effect here | Fix |
|---|---|---|
| mozilla/sccache#2862: a PTX-only gencode (`code=compute_90`) fails with `Missing "cubin" file output` | ORT's `-virtual` targets, and every CUDA compile on a Blackwell arch list, had to run nvcc bare | mozilla/sccache#2809 (open, unreviewed), in [`patches/`](patches/) |
| clang-cl C++20 named modules: an importer's cache key ignored the interfaces it imports, so sccache served stale objects | no Windows lane could keep its cache across CI runs | mozilla/sccache#2876, merged 2026-10-17 into `main` |

`versions.env` pins the source: `SCCACHE_SOURCE_REV` (upstream `main` at #2876's merge) and
`SCCACHE_BUILD_ID`, which names the asset and the release. `sccache --version` prints
`0.18.0+1bd7432.pr2809`, so a log says which build ran.

## Building

```bash
bash shared/upstream/sccache/build-sccache.sh x86_64-unknown-linux-musl dist
```

[`sccache-release.yml`](../../../.github/workflows/sccache-release.yml) runs that for
x86_64, aarch64 and riscv64gc musl, in the musl cross containers upstream's own release uses,
pinned by digest, and for `x86_64-pc-windows-msvc`. It publishes the archives and a
`SHA256SUMS`, never as the hub's latest release. The asset names and layout are upstream's
(`sccache-v<id>-<target>.tar.gz` holding `sccache-v<id>-<target>/sccache`). The installers
therefore only change their download base and version.

## Verified (2026-10-17, CUDA 13.2, an RTX 2080)

- Unpatched `main` reproduces #2862 on Linux: `compute_80` passes, a PTX-only `compute_90`
  fails with the issue's message.
- With the patch, a kernel with an `__CUDA_ARCH__`-guarded template and a `-D`-guarded one
  was compiled for `sm_75`, `sm_86` and PTX `compute_90`: once bare, once cold (14 misses),
  once warm (14 of 14 hits). The cached objects' host symbols (`nm`), SASS and PTX were
  identical to the bare build's. The objects linked, and the kernels gave the right results
  on the GPU. That was the failure shape of 2026-08-10: missing instantiations, visible
  only at link time.

## Moving back to mozilla's releases

Once a release ships both #2876 and the #2862 fix, set `SCCACHE_LINUX_VERSION`,
`SCCACHE_WINDOWS_VERSION` and their SHA-256 sums to it, `SCCACHE_DOWNLOAD_BASE` to
`https://github.com/mozilla/sccache/releases/download/v`, and delete this directory with
the workflow. riscv64 then falls back to the distro package again, unless upstream ships one.
