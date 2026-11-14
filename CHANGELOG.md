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

## 2026-11-14 — retain standalone HailoRT cache evidence

- Give the direct Windows HailoRT stage the shared cache-session start before
  CMake, advanced stderr counters after Ninja and an upload drain before cleanup.
- Guard unconditional calls, ordering and statistics flags with mutations and
  verify the existing module APIs in a cold process. Actual new compiler counts
  and device execution still require product-build evidence.

## 2026-11-14 — isolate runtime probe fixture discovery

- Run synthetic consumer probes with native utility paths and their explicit fixture
  tools, keeping the actual probe and all existing assertions. Inherited Windows PATH
  discovery could exceed the mutation baseline's unchanged 300-second limit.
- Add a host-tool marker assertion and a mutation that injects its directory. Preserve
  the outer runner's PATH and QNN space-path coverage; no live image or GPU proof is implied.

## 2026-11-14 — reject invalid Renovate wrappers before probing help

- Refuse syntax and delegation failures before executing a wrapper. A wrapper that
  dropped arguments previously turned the help probe into a live Renovate run,
  which could leave node-gyp files behind during fixture cleanup.
- Keep valid-wrapper help checks mandatory. A controlled marker reproduces the old
  execution and proves the refusal without registry access or tool installation;
  the registered mutation restores the old guard and must fail.

## 2026-11-14 — prove the promotion boundary before consumer dispatch

- Exercise a promotion refusal under a conditional shell caller and require both failure and no
  consumer dispatch. The correct guard survived the older fixture's mutation test; the new case
  must reject its removal. Preserve the existing advisory policy after a successful promotion.
- Document the dispatch boundary and its fixture limits; the source route and image inputs stay unchanged.

## 2026-11-14 — QNN fixture environment argument boundaries

- Keep PATH, SDK cache and extraction directories as individually quoted environment values in
  `test-qnn-community-zip.sh`; an inherited WSL PATH containing spaces previously stopped `env`
  before the resolver ran. Production QNN SDK code and dependency pins are unchanged.
- Preserve the original selection cases, exercise plain and spaced layouts, and verify the fake
  cache bytes and complete downloader arguments: 24 assertions and three valid unquoting mutants.
  Controlled clean-PATH diagnostics do not turn the earlier failed full preflight green.

## 2026-11-13 — after a publish, the consumers' lanes run on the new image (CON236, CON235)

- Owner decision of the day: `linux/scripts/dispatch-consumer-lanes.sh --tag TAG` dispatches each consumer's
  `on-request.yml` with the lanes that image changes, and for `:latest` its `linux-x64.yml`, from the plan
  `shared/config/image-consumer-lanes.json`. `build-runtime-manifest.sh` calls it after a promotion; a refused
  dispatch prints its command and a warning, and the promotion stands. The Windows publish does not call it yet (CON236 stays for that).
  Suites `test-dispatch-consumer-lanes.sh` and `test-manifest-acceptance.sh`, recipes `dispatch-lanes.*`, docs
  `image-acceptance.md`.
- CON235 is done: one default score threshold, 0.25, in every detector and in ModelANT's `contracts/README.md`
  (OxidANT, OrchestrANT, ModelANT b108dd4).

## 2026-11-13 — a refused download of the earlier measurements is tried again (CON271)

- Owner decision of the same day: `quality_report_github.download` tries a download three times, 5 s apart, and
  only the last failure is `Broken`; the module's "never retries" rule goes. A refusal by the artifact store made
  OmniAccelerANT's quality-report lane red (run 43453000910). An API lookup is still not tried again.
  `bench-history.py fetch` keeps its own loop and asks the helper for one try per call.
- Tests: three `Download` cases in `quality_report_tests.py`; recipes `quality-report.download-*` and
  `bench-history.download-tries-once-per-loop`.
- BACKLOG: CON235 and CON236 carry the owner's decisions of the day (one default score threshold of 0.25; every
  consumer's lanes once after each image publish).

## 2026-11-13 — BACKLOG: CON234 cut down to what is left, with the day's consumer evidence

- CON234 named four steps; three are done in ModelANT and the consumers (decode cases and their replay, the
  metadata keys in the contract, and since today the check of those keys in C++ and Rust). The entry now holds the
  lossless `two_cats` copy and the note on where the no-suppression rule has a recipe.
- CON271, new: a refused download of the earlier measurements made OmniAccelerANT's quality-report lane red (run
  43453000910); the helper never retries by its own rule, so the entry asks the owner.

## 2026-11-13 — `run-in-ci-image.sh` takes a volume, an environment variable and `--privileged` (CON242)

- `--volume NAME:/PATH` and `--env NAME=VALUE` (both repeatable) and `--privileged`: a local test run with warm
  caches is one command through the helper. A named volume is handed to the run's user by one short root container
  when that user is not root; without `--user` the image's own user is read from the local copy, pulled first when
  there is none. A malformed value is refused before any engine call.
- Under a rootless engine on Linux the helper passes `--user 0:0` and `TAR_OPTIONS=--no-same-owner` by itself; an
  explicit `--user` and a caller's `TAR_OPTIONS` are kept. Rootful Docker, CI and Windows hosts are unchanged.
- Every run prints `run-in-ci-image.sh: image <ref>, local copy created <date>` (or `no local copy`) on stderr.
- Four tests on the recording engine and fifteen recipes (`host.run-image-*`); each path also ran once for real
  on the rootless arm64 dev host, as root and as uid 1001 on a fresh volume. The adoption page's cargo-cache run uses
  the helper. Left in CON242: no consumer documents its local test run through it yet.
- **CON256 (j), new:** OrchestrANT's first AMD bundle on the plugin-only image stops in the bundle's library
  closure, before the registration gate (run 43409294907).

## 2026-11-13 — three small gate faults: the hub hook under `git commit -a`, a section number in prose, one failed download (CON270, CON251, CON255)

- **CON270.** `linux/host-config/git-hooks/pre-commit` reads the staged list once, from the index git names in
  `GIT_INDEX_FILE`, before it unsets the variable for everything it starts. Under `git commit -a` and
  `git commit <path>` git builds the commit's index in a lock file, so the hook's staged `shellcheck`, its doc gates
  and its mutation sample saw no file and said OK. A list that cannot be read now stops the commit.
  `test-precommit-hook.sh` commits for real with `-a`, with a path and plain. OmniAccelerANT's own hook already
  reads the list before its `unset`.
- **CON251.** `verify_doc_links.py` passes a `§` reference that goes on as a sentence after a section number
  ("`AGENTS.md` § 5 re-records the golden") when the page it names has a numbered heading with that number. A
  number no section carries still fails, and so does a renamed heading cited by name. Not covered: the words behind
  a number that still exists are not compared.
- **CON255.** `bench-history.py fetch` tries the download of one earlier record three times, `--retry-pause` (5 s)
  apart, and goes on without a record that still fails: a `Benchmark history incomplete` warning names it and the
  count line ends in `, <n> left out`. An artifact list that cannot be read still exits 2. Consumers take it at
  their next pin bump.
- Ten recipes hold the three (`pre-commit.*`, `doc-links.numbered-mention-*`, `bench-history.*`), each proved on the
  arm64 dev host. Details in `docs/code-quality-tooling.md`.
- **CON269** loses its first item: none of the four consumer wrappers holds a `--stale-check` loop any more.
- **CON130** is closed by its run: AccelerANTgine's `linux-riscv64.yml` passed on 2026-11-13 (run 43403278204, hub
  pin `ed3d1707`), the first run since 2026-10-15 and the first after both fixes. CMake resolved GStreamer through
  pkg-config, 239 of 239 tests passed under QEMU, and the log has no `x86_64-linux-gnu` line and no plugin that
  failed to load. AccelerANTgine does not build gtk4, so no `gtk4.pc` was there to resolve.

## 2026-11-13 — retain standalone OpenCV plugin cache evidence

- Report OpenCV GStreamer plugin counters and complete the sccache server before
  deleting its source, preserving the preceding GStreamer log. Add portable
  regression and mutation checks for the lifecycle wiring.
- Bind the incoming benchmark-history fetch replay to its Bash fake explicitly,
  preventing Windows Python from falling through to an installed GitHub CLI.
  Retain every fetch, retry and report assertion and allow repeated fixture setup.
- Document that retained cache-log copies must use a consumed ARG nonce instead
  of `--no-cache`, which can reset even read-only cache-mount associations.
  Keep actual prefix counters separate from pending producer/device evidence.

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
