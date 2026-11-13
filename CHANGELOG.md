# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-11-07 … 2026-11-12`](docs/changelog-archive-2026-11-12.md) ·
> [`2026-11-05 … 2026-11-06`](docs/changelog-archive-2026-11-06.md) ·
> [`2026-10-23 … 2026-11-04`](docs/changelog-archive-2026-11-04.md) ·
> [`2026-10-20 … 2026-10-22`](docs/changelog-archive-2026-10-22.md) ·
> [`2026-10-19`](docs/changelog-archive-2026-10-19.md) ·
> [`2026-10-13 … 2026-10-18`](docs/changelog-archive-2026-10-18.md) ·
> [`2026-10-08 … 2026-10-12`](docs/changelog-archive-2026-10-12.md) ·
> [`2026-10-01 … 2026-10-07`](docs/changelog-archive-2026-10-07.md) ·
> [`2026-09-22 … 2026-09-30`](docs/changelog-archive-2026-09-30.md) ·
> [`2026-09-08 … 2026-09-21`](docs/changelog-archive-2026-09-21.md) ·
> [`2026-08-29 … 2026-09-07`](docs/changelog-archive-2026-09-07.md) ·
> [`2026-08-14 … 2026-08-28`](docs/changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.

## 2026-11-13 — run TVM-FFI metadata mutation tests on Linux

- Use shared harness fixtures with case-scoped cleanup instead of Pester-only
  lifecycle keywords; Linux mutation shards do not install Pester. Keep real
  metadata checks, callbacks and all negative cases unchanged.

## 2026-11-13 — preserve the vendored TVM-FFI release metadata

- Share source-version selection across Windows native and cross builds; scope
  the GIL/twin SCM override to FFI and restore the environment on failure.
- Reject incorrect installed or archived metadata, with real metadata fixtures
  and mutation coverage. Source pins stay unchanged; product qualification remains open.
- Invoke two existing TVM mutation runners directly; they already create result
  directories. This preserves their assertions on both Windows and Linux.

## 2026-11-13 — preserve native Git root spelling in consumer-hook tests

- Compare the fallback hook's root argument with Git's canonical fixture path.
  This retains the full commit/push assertions on Git Bash, where `/tmp/...`
  and `C:/...` can name the same fixture. Hook behavior and gate coverage stay
  unchanged.

## 2026-11-13 — scrub temporary QNN SDK payloads before Windows export

- Remove the default extracted QNN SDK after source-chain runtime staging.
  Preserve cached archives, copied runtime and CPython; refuse relative roots,
  reparse metadata, removal errors and leftovers before layer export.
- Add private-tree regression and mutation checks. The earlier `0a822337`
  TVM/IREE compile and wheel gates passed, but its image import exhausted disk
  while copying unused Android SDK files; the corrected producer remains to be
  qualified.

## 2026-11-13 — bind private Windows results and the public ARM64 replay

- Record frozen `5bd443ea` CPU, ARM64 cross, NVIDIA and ROCm image evidence,
  retaining disk-stopped raw exits and hardware skips. The ROCm three-part audit
  checks 21 digest handoffs and rejects 87 invalid-evidence controls.
- Keep the actual 6,304-hit CUDA compiler repeat separate from layer reuse and
  cumulative counters. Record the negative Pad/MaxPool controls and complete
  ARM64 ZIP transport without claiming final-source device acceptance.
- Verify the public `7c575e34` ARM64 image's later native run 43154553839: all
  22 cases pass, including real ONNX frames; DirectML reports no adapter and
  supplies no GPU inference proof. The private newer image remains unpromoted.
- The ordinary ROCm runtime's complete tar transport and host hash checks pass
  after the original client was lost across a host reboot. A separate native probe
  compiles against its real ORT/HIP headers and passes five independently profiled
  CPU runs, with five corrupt-model and three invalid-setting refusals. The AMD
  invocation reports no ROCm-capable device; AMD execution remains open. CON228
  stays open and its text remains a draft for qualified review.

## 2026-11-13 — preserve explicit zero padding before Windows MIGraphX MaxPool

- Apply the shared source patch to the pinned MIGraphX tree before dependencies
  configure. Keep average and max pads explicit while preserving LP-norm folding.
- Mount only the patch in the MIGraphX RUN and forward its path; retain the
  original source pin, archive checksum and separate EP cache boundary.
- Add real upstream source fixtures, required-failure and wiring checks, and
  mutation recipes. Share parameter-default and build-mount assertions with the
  existing harness consumers, retaining their broader filename exclusivity.
  The seven-case upstream C++ reference proof is recorded in
  the ROCm and upstream patch pages. Corrected Windows compilation and AMD device
  acceptance remain pending.

## 2026-11-13 — BACKLOG CON256: what the first complete AMD package build on `:latest-rocm` showed

- OxidANT's candidate lane (run 43345664993, hub pin ed3d170): the census passes with `--library-path lib/glibc:lib`;
  registering the packaged module on a runner without a card fails with HIP error 100, is refused by name and
  leaves `auto` on the CPU; the tarball and the DEB pass the wheel proof. It stops at
  `verify-ort-appimage-payload.sh`, which asks an AMD AppImage for the wheel's exact bytes although the image strips
  its CPU core. CON256 (a) and (i) record both; the fix needs an x86-64 host for the suite's AMD leg.

## 2026-11-13 — the bundle census takes the launcher's library path (`--library-path`)

- `check-ort-provenance.sh --library-path DIR[:DIR...] <bundle>` states the library path the bundle's launcher hands
  the loader, relative to the bundle root, and the probe searches it where `ld.so` searches `LD_LIBRARY_PATH`. Two
  hub gates contradicted each other in OxidANT run 43314831939 (2026-11-12): a native AMD package keeps
  `libmigraphx-ep.so` byte for byte the image's (`ort_assert_plugin_module`), so the module has no run path, and G6
  called its `libonnxruntime.so.1` import UNRESOLVED. What an import resolves to is graded as before, and without
  the option no caller sees a difference. An absolute path, a `..`, an empty entry, a directory the bundle lacks, an
  entry that is a link out of the bundle and the option beside `--image` are usage errors; the PASS and FAILED lines
  name the path.
- On a stated path a file of the import's name that is a link out of the bundle, a link loop or a directory ends
  the search unproven, as the loader's open would, and the finding names it. On an importer's own RUNPATH list such
  a name still counts as absent, an older limit ([§ E](docs/cross-build-verification.md#e-ort-single-source)).
- The entries reach the probe as paths below its `--root` (`/lib/glibc:/lib`), which is how it prints every path of
  a bundle; joined to the host path they would find nothing.
- `--help` and a usage error print the usage again: the function read `# Usage:` comment lines the file no longer has.
- `python-app-bundle.sh` is unchanged. A Python AMD bundle keeps the module in `onnxruntime/capi`, which no launcher
  path names; read in the scripts and seen on a fixture, its `libonnxruntime.so.1` is the closure's copy in
  `runtime/lib`, on the launcher's path only through the bundled loader and otherwise preloaded by
  `sitecustomize.py`. BACKLOG CON256 (i) holds the open point.
- `test-ort-census.sh` gains three cases; recipes `ort-census.library-path-*` (nine) and
  `ort-census.probe-ldpath-before-runpath` hold them, each seen to bite. Not run in the x64 rocm image or on a real
  `libmigraphx-ep.so`. Contract: [`consumer-image-contract.md`](docs/consumer-image-contract.md#prove-your-bundle-ships-the-images-onnx-runtime).
