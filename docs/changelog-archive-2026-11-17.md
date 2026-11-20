<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Changelog archive — 2026-11-10 … 2026-11-17

Entries moved from the root `CHANGELOG.md` on 2026-11-20 at a complete date
boundary. Original text is preserved; relative links are rebased to this directory.
The preceding history is in [the 2026-11-06 … 2026-11-12 archive](changelog-archive-2026-11-12.md).

## 2026-11-17 — `Write-CPackGeneratorLog` prints what a failed package step's generator said

- CPack reports a failed NSIS or WiX run only as "Problem running NSIS command" and points at a log inside the
  build tree, which a container lane never uploads. `WindowsCMake.Common`'s `Write-CPackGeneratorLog -BuildPath`
  writes the tail of every `*.log` under `_CPack_Packages` into the build log; a consumer calls it when its
  `--target package` step throws.

## 2026-11-17 — the NAS backup retries its mount, a failed run reaches the phone, AIO backs up again

- AIO's `daily_backup_time` on srv-1 was gone from 2026-10-27, so Nextcloud had no new archive for three weeks
  and every Saturday run failed its age check; nobody saw it, because the sensor only showed on the dashboard.
  The file is back at `02:00` UTC, and `linux/ansible/README.md` § *Backups to the NAS* says how to check it.
- `playbooks/backup.yml` retries the NAS mount up to 5 times, 30 s apart (`backup_nas_mount_retries`,
  `backup_nas_mount_delay`): a NAS waking its disks closed the one try of 2026-11-14 (`mount error(112)`).
  A share that still does not mount ends the run with a `BACKUP: FAILED the NAS share at: <step>` note.
- `packages/ansible_backup.yaml` pushes to the phone when a run ends failed or the sensor stays on for
  15 minutes, and clears the notice when a run is `ok` again.

## 2026-11-17 — the docs lock moves soupsieve 3.0.4 to 4.1.1 (GHSA, Dependabot alert 10)

- Soup Sieve before 4.0.0 takes polynomial time in the descendant combinator. `uv lock --upgrade-package soupsieve`
  in `docs/` moves it alone; the site builds with it.

## 2026-11-17 — the sccache module docs name the image's fixed build

- `windows-container-build-performance.md` § *sccache on a C++23 modules build* and `windows-build-resources.md`
  still called sccache 0.18.0 "the image's" and #2876 "not in the image". Both images ship the hub's
  `0.19.0+965c019.pr2809`, which carries it, and `Test-SccacheModuleSafe` already admits it; the cache-bypass
  advice now applies only to an older sccache.

## 2026-11-17 — Windows x64 source builds take the x86-64-v3 floor (CON265, in source)

- amd64's `SimdFlags` is `/clang:-march=x86-64-v3` instead of eight `-m` flags, and a new `RustFlags` carries
  `-C target-cpu=x86-64-v3` (owner decision 2026-11-17: Windows follows CON264). `Invoke-CmakeConfigure` passes
  the floor as `CMAKE_C/CXX_FLAGS_INIT` to every clang-cl configure (`Get-SourceCmakeIsaArgs`); ORT, OpenCV,
  GenAI, TVM, LLVM, GStreamer, gst-plugins-rs, FFmpeg (`/arch:AVX2` on its MSVC path) and its codecs, CPython,
  LiteRT and LiteRT-LM carry it. arm64 gets nothing. Nothing is built with it until the owner's
  go; `docs/amd64-x86-64-v3-baseline.md` § Windows x64 says where it lands and what it leaves out.

## 2026-11-17 — the raw-pin test passes on a host with bash 5.2 (CON278)

- `raw_pin_reader_tests.py` drops bash 5.2's `pop_var_context: head of shell_variables not a function context`
  line from the stderr it compares: 5.2 prints it when errexit unwinds a file sourced inside a function, 5.3 does
  not. On a Debian dev host the test failed 12 of 3081 assertions with unchanged code, so the commit and push hooks'
  `lib.raw-pin-rust-*` recipes read as vacuous and stopped every change to `install-rust.sh`.

## 2026-11-17 — mingw and the windows-gnu Rust target in the amd64 image (CON239, in source)

- The package stage asks for `gcc-mingw-w64-x86-64` by name on amd64, and `install-rust.sh` adds the
  `x86_64-pc-windows-gnu` target there (owner decision 2026-11-17, reversing 2026-11-03): OxidANT's push will
  type-check Windows on the GNU target, whose `ring` needs mingw's C. About 600 MB on amd64; arm64 and riscv64
  carry neither, which `test-setup-package-image.sh` holds. `docs/image-decisions.md` records it. A chain
  publishes it.

## 2026-11-17 — a host without a tool the image has runs the push suites in the image (CON277)

- The shared pre-push hook tees `scripts/linux/pre-push-checks.sh`'s output. When the run fails on
  `prerequisite missing:` and the clone sets `git config kataglyphis.imageRunner "<command> --"`, it runs the
  suites once more through that command, and that run decides (owner decision): a Raspberry Pi without node
  pushes OxidANT without `--no-verify`, through `pi-ci --`. A real failure, or a clone without the setting,
  stops the push as before. `test-consumer-hooks.sh` covers the four cases;
  `docs/adopting-in-a-new-project.md` § The git hooks, by reference says how.
- Proved on 2026-11-17: OxidANT 7a61e8a, pinned to f99f95a6, went from the Raspberry Pi without `--no-verify`;
  the host run failed on `prerequisite missing: node` and the run through `pi-ci --` passed. CON277 leaves the
  backlog.

## 2026-11-17 — cargo-mutants in the amd64 image at its pin (CON238, item 1)

- `versions.env` pins `CARGO_MUTANTS_VERSION=27.1.0`, the version OxidANT's mutation scores were taken with, and
  `CARGO_MUTANTS_LINUX_X86_64_SHA256` for upstream's one Linux binary (x86_64, glibc). `install_cargo_qa_tools`
  installs it on amd64 and notes its absence elsewhere; the smoke probe asks its version, and the `cargo-qa-tools`
  row expects `cargo-mutants=27.1.0` on amd64 and none on arm64. `bump_versions.py` tracks the pin. OxidANT's
  weekly `rust-mutants.yml` runs once a chain publishes it. Tests: the installer suite (amd64 lands it, aarch64
  does not) and the contract cases (both arches, both wrong ways).

## 2026-11-17 — `build-docs.yml` takes the publish job's limit (`publish-timeout-minutes`)

- The publish job's `timeout-minutes` comes from `publish-timeout-minutes` (default 30, unchanged). An upload the
  limit cuts off saves no sync state, so every later run uploads the same file again: BeschleunigerBallett's site
  has not published since 2026-11-15, when its WebGPU demo gained a 61 MB scene that the server takes at about
  74 kB/s (runs 43956352416, 43987817445 stopped on it at 30 min).

## 2026-11-17 — preserve OCI link receipts across later child exports

- New schema-2 parent-link receipts retain mandatory blob hashes, exact source/child inodes, size, mode, ownership and mtime while allowing ctime to advance when another child links the same bytes. Schema-1 receipts keep their original strict ctime policy and are never rewritten.
- Default amd64 Media and Android parents use explicit byte-proof statuses with the same stopped-export and full native OCI checks. This does not expand the private ROCm launch profiles or establish image/GPU acceptance.
- Real synthetic archives and links cover sibling/descendant replay, legacy refusal, malformed schema values, content changes with restored mtime, identical-byte inode replacements and every stable identity field.

## 2026-11-17 — select complete compiler image checks explicitly

- Current compiler inputs with `source_proofs` require `image_qualification_profile=compiler-cross-cpu` for image qualification and native OCI handoff. Both shell modes, all six wrappers and the original CPU/backend/loader checks remain mandatory; historical launcher profiles retain their behavior.
- Synthetic profile and launch transports cover the selector, unknown or missing profiles and both legacy/current incomplete-parent refusals. These controls do not prove actual image, GPU or consumer acceptance.
- The type driver retains the sibling roots needed by existing runtime, packaging and test modules, adds the local proof root, and keeps both image-profile modules in strict type and focused annotation coverage. Real-ty import, type and annotation fixtures guard the selection without scan exclusions.
- Early direct-suite assertion failures preserve their original failed status and logs while explicitly recording that the mutator never started; absent failure evidence or an inconsistent later preflight report refuses that failure classification.
- Compiler/runtime fixtures retain their declared mapping, timeout and required-review types when reached through the actual module roots; the generated gate table records the expanded mutation coverage.

## 2026-11-16 — a source tree beside a Python package gets its own coverage floor (CON250, third part)

- `ci_tests.sh` reads `PYTHON_COVERAGE_EXTRA` (`coverage-extra` on `python-ci-linux.yml`, comma-separated `DIR=MIN`):
  each tree is measured beside the package (`--cov=<workspace>/<dir>`), written to `coverage-<leg>-<dir>.xml` with
  `coverage xml --include` and gated by `verify-test-reports.py --label <dir>`; the package's
  `coverage-<leg>.xml` is rewritten with `--omit` of those trees, so its floor and the docs page read the package
  alone. A malformed pair, `..`, an absolute path or a missing directory stops the driver before any leg. On
  OrchestrANT in the image: `benchmarks/` 91.03 %, the package alone 71.01 %, both together 77.62 %, which would
  have let either fall unseen. Tests in `test-python-ci-defaults.sh`, `test-verify-test-reports.sh` and
  `test-reusable-linux-lane.sh`; mutation recipes `python.lane-coverage-extra-forwarded`,
  `python.package-floor-reads-the-package` and `python.extra-tree-floor-checked`, and
  `python.ci-tests-report-check-executed` names the first of the two verifier calls.

## 2026-11-16 — `ensure_wasm_bindgen` pins wasm-bindgen-cli to a Cargo.lock; the WebGPU flags are exported

- `lib/rust-toolchain.sh` gains `ensure_wasm_bindgen <Cargo.lock>` and `wasm_bindgen_lock_version <Cargo.lock>`:
  PATH's `wasm-bindgen` must be the lock's version, else `cargo install --locked wasm-bindgen-cli --version <v>`, then
  PATH is asked again, since cargo's bin directory is off the image's PATH. 1 on a missing lock or none naming
  wasm-bindgen, cargo's status on a failed install. BeschleunigerBallett's `docs-build-web.sh` and OxidANT's
  `webgpu-demo-browser.sh` each carried a copy (`docs/shared-script-libraries.md` § `rust-toolchain.sh`).
  `test-lib-wasm-tools.sh` stubs cargo and wasm-bindgen; six new `lib.wasm-bindgen-*` recipes.
- `webgpu-canvas-readback.js` exports its SwiftShader `WEBGPU_FLAGS`, frozen, beside `install` and `verdict`;
  OxidANT's demo check had copied them while they were private (`docs/docs-sites.md` § Proving a WebGPU page). Two
  new `docs-site.webgpu-readback-*` recipes.

## 2026-11-16 — retain required compiler-cache setup failures

- Python cache initialization directly precedes launcher resolution. The site check accepts strict raw-status propagation alongside the unchanged optional-core fallback, and a real removal mutation proves the parent setup remains mandatory. The command fixture also proves newly imported APIs publish in the compiling shell. These source checks do not prove compilation or cache hits.

## 2026-11-16 — scope Python compiler caches to build commands

- Linux packaging can opt into the canonical compiler-cache resolver for project syncs and GIL/free-threaded/cross wheel builds, with explicit compiler executables and temporary quoted prefixes. Package assembly retains the original compiler names.
- Shared fixtures cover callback publication, arguments, quoting, required APIs and raw failures; they do not prove compilation, cache hits or finished packages. The pure-wheel control uses its own distribution, so normal hooks also work on hosts without pip.

## 2026-11-16 — retain standalone entrypoint-module logging

- The bundle executable selector imports the shared logging bootstrap when sourced directly. Existing standalone-library assertions and a real import-removal mutation cover the contract; package/GPU execution remains a separate check.

## 2026-11-16 — select bundle application entry points explicitly

- Shared DEB, AppImage and Flatpak packaging accepts `APP_PACKAGING_BINARY_NAME` so an executable native helper cannot replace the declared application. Invalid or absent declared files fail without fallback.
- Regression controls exercise real AppRun dispatch and the rendered DEB wrapper with stub builders; actual package and GPU checks remain separate.
- Normal source-commit units retain system utility directories. The raw-readelf regression uses a real ELF and explicit package/cache stubs, so unrelated host multilib packages cannot fail its positive control; normal hooks and production dependency checks remain unchanged.

## 2026-11-16 — retain successful acceptance sources

- Both acceptance transports keep successful versioned consumer checkouts and recursive Git stores beside their logs.
- Independent preservation waits for completed source preparation and verifies clean, self-contained Git trees on reuse; real local Git regressions cover corruption and unsafe reuse.
- Source preservation proves committed bytes only, not build outputs, source authentication or GPU execution.

> **Older entries** are archived, newest archive first:
> [`2026-11-06 … 2026-11-12`](changelog-archive-2026-11-12.md) ·
> [`2026-11-05`](changelog-archive-2026-11-05.md) ·
> [`2026-10-23 … 2026-11-04`](changelog-archive-2026-11-04.md) ·
> [`2026-10-20 … 2026-10-22`](changelog-archive-2026-10-22.md) ·
> [`2026-10-19`](changelog-archive-2026-10-19.md) ·
> [`2026-10-13 … 2026-10-18`](changelog-archive-2026-10-18.md) ·
> [`2026-10-08 … 2026-10-12`](changelog-archive-2026-10-12.md) ·
> [`2026-10-01 … 2026-10-07`](changelog-archive-2026-10-07.md) ·
> [`2026-09-22 … 2026-09-30`](changelog-archive-2026-09-30.md) ·
> [`2026-09-08 … 2026-09-21`](changelog-archive-2026-09-21.md) ·
> [`2026-08-29 … 2026-09-07`](changelog-archive-2026-09-07.md) ·
> [`2026-08-14 … 2026-08-28`](changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.

## 2026-11-16 — retain successful runtime evidence after systemd unloads its unit

- Local FINAL acceptance can recover an actually unloaded successful runtime only from its original sealed storage guardian and fresh trusted same-boot journal lifecycle. Keep the actual process-exit timestamp separate from the manager finish event and label the historical observation explicitly.
- Verify original host/source, invocation and cleanup bindings before importing the guardian API, and recheck the journal and seal across all six consumers. Live, failed, unguarded and previous-boot producers still refuse; synthetic regression and mutation controls do not prove a real consumer, image, licence closure or GPU result.

## 2026-11-15 — the in-image mutation lane reaps (CON274 done)

- OrchestrANT 08f9c4b's `bench.agent-tree-survives-timeout` runs its test with `ORCHESTRANT_REQUIRE_REAPED=1`, under
  which a zombie counts as alive, so its unmutated run passes only where PID 1 reaps. In `mutation-gates.yml`'s
  in-image lane (`docker run --init`) it bit with that baseline green (run 43754387381); under a Python PID 1 without
  an init the same test fails. CON274 leaves the backlog.

## 2026-11-15 — docs sites type and gzip wasm and glTF

- `docs-site.htaccess` adds `AddType` for `.wasm` (`application/wasm`), `.glb` (`model/gltf-binary`) and `.gltf`
  (`model/gltf+json`), and `AddOutputFilterByType DEFLATE` for those three types inside `mod_filter` and `mod_deflate`,
  all FileInfo directives. The host gzips HTML, CSS and JavaScript itself but sent BeschleunigerBallett's 7 MB demo
  wasm whole; its 61 MB `Colosseum-web.glb` gzips to 30 MB (`docs/docs-sites.md` § The site's .htaccess).
  `test-docs-site-htaccess.sh` checks the types, the compressed set and both guards; six new `docs-site.*` recipes.

## 2026-11-15 — every detector follows the ORT thread rule (CON240 done)

- OxidANT 75d0155 gives its Rust detector the family's rule when `KATAGLYPHIS_ORT_THREADS` is unset (owner
  decision), so OrchestrANT, AccelerANTgine and OxidANT all take the usable CPUs but one, 1 to 8
  (`docs/onnxruntime-single-source.md` § The ORT thread rule). CON240 leaves the backlog; CON218 notes ObservANT's
  `llm_threads`.

## 2026-11-15 — `genai-model-threads.py --threads auto` (CON218)

- `--threads auto` copies a GenAI model with the family's ORT rule, the usable CPUs but one, 1 to 8: 7 on the Ryzen
  pinned to 8 CPUs, as the perf baselines used, and 3 on a Pi 5, where the consumers' fixed 7 oversubscribed four
  cores (34 tokens per second). On the Pi SmolLM2-135M took 161/92/73/72 ms to the first token and decoded
  109/92/80/71 tokens per second at 1/2/3/4 threads. New recipe `quality-report.perf-genai-threads-auto-unbounded`.

## 2026-11-15 — one hub command locks a consumer in the image (CON272)

- `linux/scripts/02-toolchain/python/uv-lock-in-image.sh [--no-build-isolation-package NAME]...` runs a consumer's
  `uv lock` with the image's `/opt/venv` as the project environment, after installing `setuptools<82` and `wheel`
  there when missing, so a git source like OrchestrANT's torchvision builds its metadata against the image's torch
  instead of an isolated environment that wants a PyPI torch the pinned Python has no wheel for. Proven on a Pi 5:
  OrchestrANT with `tomli-w` added locked in 849 s and the lock moved by that package alone
  (`docs/dependency-updates.md` § A consumer's uv lock in the image). `test-uv-lock-in-image.sh`. New CON276:
  ship setuptools and wheel in `/opt/venv`.
- New CON275: GCC 16's `_mm_loadl_epi64` fails UBSan's alignment check (AccelerANTgine worked around it).

## 2026-11-15 — the family's ORT thread rule is written once; the hub backlog catches up

- `docs/onnxruntime-single-source.md` § The ORT thread rule: a detector's intra-op pool takes the usable CPUs (the
  affinity mask) but one, 1 to 8, overrides kept; which consumer follows it (OrchestrANT, AccelerANTgine since
  6e35dad; OxidANT not yet) and the Ryzen and Pi 5 figures behind it, plus the one-thread rule for a language model
  beside a detector (OrchestrANT's `--describe-threads`).
- BACKLOG: CON240 open again with only OxidANT left; CON218 notes the Pi finding and the consumers' fixed
  `--threads 7` perf copies; CON236's recipe half is done.
- `mutation-gates.yml`'s in-image runner starts the container with `docker run --init`: `verify_mutations.py` was
  PID 1 and never reaped the orphans a test killed (OrchestrANT run 43657675126); the proof in a run is CON274.

## 2026-11-15 — Pester in the Linux image; a pwsh recipe goes to CI on a host without it (CON273)

- `install_pwsh` also installs Pester at the new pin `PESTER_VERSION=6.2.0` (windows-x64.yml's floor) from the
  PowerShell Gallery into `$PSHOME/Modules`, verified against `PESTER_NUPKG_SHA256` and failing the stage unless
  `pwsh` lists it at its pin. Proven in a throwaway container of `:latest` on arm64: the real nupkg installs and
  `Invoke-Pester` passes. `test-package-image-wiring.sh` covers the pin, the unpinned case and a wrong version.
- `verify_mutations.py --delegate-chrome` (the pre-push hook's mode) also hands an entry whose test needs `pwsh` to
  CI when this host has none (`mutation_push.host_has_pwsh`, asked only when such an entry is selected), printing
  `needs pwsh, which this host lacks`. Such an entry is set aside before the parse check, which needs `pwsh` for a
  PowerShell mutant, so the hook on the arm64 dev host no longer fails with `pwsh is not on PATH`. Pester does not
  decide it: recipes name harness suites only, which run without Pester. `test-mutation-push.sh` covers both hosts
  and a PowerShell target.
- `BuildKit.ConsumerDispatch.Tests.ps1` is a harness suite now, not a Pester one, so the Linux shards run it, and two
  recipes guard the consumer dispatch: `buildkit.push-tag-takes-the-repository` and
  `buildkit.dispatch-without-tag-runs` (CI's first run skipped the Pester suite and failed both, and
  `test-mutation-pester-targets.sh` refused them).

## 2026-11-15 — the pwsh delegation also covers suites that demand pwsh; Pester's pin follows its releases

- `mutation_push.needs_pwsh` also counts a test command that names a suite carrying
  `t_skip_unless "…" command -v pwsh` (`test-mutation-parse.sh`, `test-harness-suite-driver.sh`,
  `test-windows-icon-pe.sh`), so editing `verify_mutations.py` on the arm64 dev host no longer needs `--no-verify`.
- `PESTER_VERSION` is annotated `datasource=github-releases depName=pester/Pester`, which the versions.env
  customManager matches, and `bump_versions.py` moves `PESTER_NUPKG_SHA256` with it (`spec_pester`, from the
  gallery's nupkg).

## 2026-11-15 — review the exact GNU_UNIQUE compiler rebuild lineage

- Add an explicit compiler-planning profile for the reviewed `a4741df7` source and unchanged `60ce0c91` compiler repair. Verify compiler6's original input fingerprints, all seven deltas and the one narrow LLVM companion mount; keep GNU mounts, storage controls, disk reserve and publication guards unchanged.
- Share targeted-patch validation between planning and launch. The new source requires all matching normal-hook mutations under the existing sixteen-entry cap; earlier profiles retain their original scope and sixteen-hook requirement. Synthetic controls and actual mutations do not prove a completed source run, cache hit, compiler image or inference.

## 2026-11-15 — refuse underprovisioned local ROCm runtime imports

- Require the larger of 300 GiB and the original parent plan before the local ROCm runtime allocates outputs, prepares aliases or starts a unit. Runtime7 proved that a successful 204-GB admission plus required serial smoke can still exhaust disk during FINAL import. Shared stage minima and every production gate remain required.
- Record the actual selected byte requirement in the invocation. Boundary and larger-parent controls cover refusal and reporting, not a physical peak-space guarantee or finished image acceptance.

## 2026-11-15 — require the context-valid runtime exporter source

- The explicit source handoff now selects `2aa1a778`, which keeps the production smoke exporter and corrects its live-control fixtures. Only that exact source and its own complete current preflight may proceed; the failed intermediate `74f6be54` run cannot qualify it.
- The original Android/native parent, exact app, ordinary disk floor and invocation cleanup remain required. This host update does not establish a runtime, FINAL, GPU or complete binary-licence result.

## 2026-11-15 — select the reviewed runtime smoke-export source

- The explicit runtime source handoff now requires commit `74f6be54` and its own complete current preflight, covering both stable wheel contexts and smoke output without image import. Original Android ancestry, normal reserve, exact app and invocation cleanup remain required before a fresh runtime.
- Independent routing controls and a rollback mutation reject the earlier runtime pin. Targeted tooling checks do not prove the full source, a completed runtime, GPU inference, complete licences or FINAL acceptance.

## 2026-11-15 — bound complete local FINAL consumers and expose serial runtime smoke

- Preserve a launcher for the unchanged six-consumer local FINAL plan with exact source/producer bindings, invocation-labelled engine transport and preinstalled bounded cleanup. A passed stopped proof requires the real outer result, original receipt, successful cleanup and independent absence; failed outer results remain failed. Add explicit host `--serial-smoke` using the production lane's existing ordering option, with the same mandatory smoke and unchanged default overlap. Handle systemd retaining failed/PID0 after stopping a failed guardian, while retaining the original failed seal. Preserve recurring require-recipe preparation as a tested repo tool and keep canonical merge/actual mutations mandatory. Runtime5 proved successful package import after autonomous reclaim but concurrent smoke/wrapper contexts still failed ENOSPC; actual full runtime, FINAL consumers, GPU parity and complete licences remain open. See [local proof workflows](local-proof-workflows.md).

## 2026-11-15 — preserve a bounded runtime storage guardian

- Add a committed-source guardian for one already live ordinary runtime. Bind its invocation, PID/start ticks, source and worker hashes; use the existing canonical regular-layer worker synchronously when eligible pressure appears, retaining the 100-GB live-build budget, complete identity checks and failed producer status. Independent synthetic lifecycle and type-scope controls plus executable mutations cover the contract. Runtime4 actually failed with ENOSPC during package import; its late cleanup was insufficient to save that run. A separate idle cleanup removed two verified obsolete published Android copies, reclaimed 32,855,150,592 bytes and preserved all 42 cachemounts and 48 other images. Fresh admission, actual successful runtime and FINAL/hardware proofs remain required. See [storage observation](local-proof-workflows.md#bounded-runtime-storage-observation).

## 2026-11-14 — lavapipe 26.3.0 on Windows without the 256-bit pin; the delete guard says MIT

- `LAVAPIPE_VERSION` 26.2.6 → 26.3.0, both SHA256s self-measured and equal to the release's digests. Mesa 26.3
  deleted the BVH radix sort that needed 8-lane subgroups (`ebcfbe60`), so the Windows image,
  `Install-LavapipeHost.ps1` and `Test-Arm64Bundle.ps1` stop setting `LP_NATIVE_VECTOR_WIDTH=256`: each arch
  runs its native width, 128 bits on arm64, where 256 is the suspect of BeschleunigerBallett's intermittent
  arm64 lavapipe crash. `Test-Container.ps1` now fails an image that sets it. The Linux image keeps CON44's
  256 while its Mesa predates 26.3. Dependency table, website licence pages and curated SBOM regenerated.
- `.claude/hooks/guard-destructive-deletes.{ps1,py}` carry `SPDX-License-Identifier: MIT`, as `LICENSE`
  does; CON69's sweep skipped the hidden directory. Only that line changed (owner request, 2026-11-14), and
  the hook answers the same inputs identically.

## 2026-11-14 — Renovate 44.239.1; a `lockfile-only` skip is by design

- Renovate's uv processor now adds every package that only `uv.lock` names (`depType: uv.lock`,
  `skipReason: lockfile-only`). The planner listed each as NOT CHECKED, so every uv consumer's report exited 1
  and `--apply` refused all of its real updates: BeschleunigerBallett's 41 such rows blocked its 13 updates.
  `renovate_planner.py` counts the reason in `BY_DESIGN`. New case in `test-renovate-local.sh`, recipe
  `renovate.lockfile-only-skips-are-by-design`.
- The tracked Renovate baseline moves to 44.239.1: `tool-pins.env`, `renovate-npm/package.json`, and its lock
  regenerated under Node 24.22.2 and proven with `npm ci`. 44.239.1 still pins glob 13.0.6 and minimatch
  10.2.6, so both security overrides stay.

## 2026-11-14 — each mutation mirror names itself to its tests (`MUTATION_MIRROR`)

- `verify_mutations.py` hands every recipe test the mirror's directory name as `MUTATION_MIRROR`, so a recipe that
  keeps a build cache outside the mirror can keep one per mirror. OxidANT's 13 cargo recipes shared one
  `CARGO_TARGET_DIR`; cargo names a workspace member's artefacts without its absolute path, so parallel mirrors
  overwrote each other's fingerprints and a mutant ran the other mirror's unmutated binary (it survived in CI and
  bit with `--jobs 1`). `docs/code-quality-tooling.md` § One build cache per mirror names the trap; a case in
  `test-mutation-shards.sh` and recipe `mutations.mirror-name-unset`.

## 2026-11-14 — `FLET_VERSION`: one pin for Flet's SDK and client (CON103)

- `FLET_VERSION=1.0.5` in `tool-pins.env` (not `versions.env`: no early image stage reads it, and a key there
  would re-key the compiler image). `consumer_pins.py` holds OrchestrANT's `"flet[desktop]==…"`, `"flet-web==…"`
  and its viewer job's `--with "flet==…"` to it; `default.json` groups flet, flet-web and flet-desktop into one
  Renovate PR. Two cases in `test-consumer-pins-toml.sh`, recipe `version-snapshot.consumer-pins-flet-extras`.
  CON102's client build takes the same key.
- `BuildKit.ConsumerDispatch.Tests.ps1` (CON236) parses tags from a neutral `registry.example/owner/image` ref: the
  CI image ref gate refuses a spelled-out family image ref, and the suite was untracked when that gate last ran.

## 2026-11-14 — the Windows publish dispatches the consumers' lanes (CON236); CON273 found

- `windows/Build-Buildkit.ps1 -PushRef` now calls `dispatch-consumer-lanes.sh --tag <tag>` after its final push,
  as `build-runtime-manifest.sh` does after a promotion, so `:winamd64`, `:winarm64` and their GPU tags start
  every consumer's lanes too (owner decision: the existing script through Git Bash). `Invoke-BkConsumerDispatch`
  in `WindowsBuildKit.Common.psm1` runs it in a login shell; no Git Bash, a ref without a tag or a refused
  dispatch only warns with the command to run by hand. Suite `BuildKit.ConsumerDispatch.Tests.ps1`, proven in the
  image against four mutations with a throwaway Pester.
- New BACKLOG CON273: the CI image has `pwsh` but no Pester, and the arm64 host no `pwsh`, so no `pwsh` recipe can
  be proven off Windows.

## 2026-11-14 — `recipe-pytest.sh` runs pytest with its venv active; CON272 found

- `recipe-pytest.sh` exported nothing, so a test that starts `python3` itself (OrchestrANT's agent lane) found the
  image's `/opt/venv` first, which has no pytest. It now activates the recipe venv as the test leg does
  (`VIRTUAL_ENV`, its `bin` first on `PATH`). Case in `test-recipe-pytest.sh`, recipe
  `recipe-pytest.venv-not-active`.
- New BACKLOG CON272: a consumer's `uv lock` in the image needs setuptools in `/opt/venv` and a command no hub script
  holds yet (found adding pytest-timeout to OrchestrANT). CON234's second point is done (ModelANT `7b02dfb`).

## 2026-11-14 — `recipe-pytest.sh`: a consumer's mutation recipe on the pinned Python, from the hub

- `linux/scripts/02-toolchain/python/recipe-pytest.sh [--extra NAME]... [--] PYTEST_ARGS` runs a recipe's pytest
  on `DEFAULT_PYTHON_VERSION` with the venv the test leg's `uv_venv_create` and `uv_sync_project` build (chain ORT,
  no typed Python), synced once per Python, extras and lock under `$RECIPE_PYTEST_VENV_ROOT` behind a `flock`, and
  pytest started from the recipe's copy. OrchestrANT wrote it for itself first; the owner wants the hub as the one
  source of such scripts. Suite `test-recipe-pytest.sh`, recipes `recipe-pytest.*`, docs `python-ci.md`
  § Mutation recipes on the pinned Python.

## 2026-11-14 — consumer mutation recipes can run in the CI image, on the pinned Python

- `mutation-gates.yml` takes `in-image: true`: it pulls the family image (`prepare-linux-ci-host`, which reclaims
  disk first) and runs `verify_mutations.py` in it, mounted at the caller's own path, the image named from
  `IMAGE_REGISTRY_PREFIX` and `CI_IMAGE_LINUX_TAG` in `versions.env`. A recipe then gets the pinned `PYTHON_VERSION`
  (3.15.2) and the chain-built wheels; on the bare runner PyPI has no ORT or GenAI wheel for it, which kept
  OrchestrANT's recipes on 3.13 (owner decision of the day: the recipes use the hub's Python). Contract cases in
  `test-mutation-workflow.sh`; docs `code-quality-tooling.md` and `adopting-in-a-new-project.md`.

## 2026-11-14 — a test output that is not UTF-8 no longer crashes the mutation gate

- `verify_mutations.py` read a test's output as strict UTF-8, so a fuzz test that printed the raw input it failed on
  (AccelerANTgine's quoting property, one 0xA4 byte) ended the whole run with `UnicodeDecodeError` instead of a
  verdict. The output is now decoded with `errors="replace"`. Case in `test-mutation-gate.sh`, recipe
  `mutations.test-output-undecodable`.

## 2026-11-14 — bind local FINAL checks to their actual runtime producer

- Add explicit local FINAL acceptance with the entire canonical consumer plan, original source/submodule/lock and cleanup policies, exact manifest/config and completed producer bindings before and after consumer work. Reuse verified alias metadata and the host worker closure. Local schema-2 receipts cannot authorize registry promotion; public checks keep their existing path. Validate every receipt before pruning checkouts, so invalid metadata remains failed evidence. Synthetic controls cover supported lane schemas and refusals, while real FINAL consumers, GPU parity and complete binary licences remain required. See [local FINAL checks](image-acceptance.md#check-an-unpublished-local-final-wrapper).

## 2026-11-14 — distinguish repaired runtime sources from native Android parents

- Add an explicit paired runtime source/proof selector restricted to the reviewed stable-context repair. Require that checkout's exact complete source proof before tag lookup or engine preparation; retain Android's original source, invocation and native ancestry separately from the new runtime revision and proof hash. The default path and all normal runtime gates remain enabled. Synthetic source/command fixtures prove selection and refusal behavior, not a finished runtime or FINAL acceptance. See [ordinary local runtime](local-proof-workflows.md#ordinary-local-runtime).

## 2026-11-14 — use the verified tag for local runtime alias creation

- Retain the actual Android source tag for nerdctl image tagging while independently checking the immutable manifest, config and platform before runtime launch. This host accepts bare manifest inspection but refuses a bare manifest as an image-tag source. Preserve that raw failed attempt and start no unit on preparation failure; fixtures and the selector mutation hold the working command and all identity checks. Pass the cleanup CLI's mandatory CID-file argument alongside the invocation label; a real CLI regression with an empty engine double rejects the previously incomplete command. No source publication, image acceptance or hardware claim follows.

## 2026-11-14 — preserve ordinary Android-to-runtime transport

- Add a bounded ROCm amd64 runtime launcher that verifies native Android ancestry, pins the exact app commit and reserves every canonical output name before creating a local immutable Android alias. Reuse the ordinary runtime driver and default image wheel source with its smoke, input, content and ancestry gates enabled. A shared engine wrapper labels runtime containers without altering pulls or build arguments; install invocation-specific cleanup before launch and preserve raw exec status. Independent fixtures and executable mutations cover refusal and transport behavior. Actual runtime completion, fresh FINAL consumers, full binary licences and hardware inference remain separate required evidence. See [ordinary local runtime](local-proof-workflows.md#ordinary-local-runtime).

## 2026-11-14 — preserve native Android ancestry before runtime

- Add the persistent ROCm amd64 native Android export entry and profile. Share source, receipt and OCI ancestry checks with GPU/Media while retaining exact stage labels, required Media Wasm flags, original worker bindings, raw transport failures and ordinary disk admission. Synthetic native-byte controls and executable mutations reject unrelated or changed parents. This is a host handoff, not final wrapper, licence or hardware acceptance. See [native Android export](local-proof-workflows.md#native-android-export).

## 2026-11-14 — preserve native Media-to-Android handoff

- Bind the ordinary ROCm Media producer to its exact proven GPU source, required Wasm flags and native parent receipts. Reuse the bounded native exporter with distinct Media subjects, all GPU ancestry and raw transport statuses, then launch normal Android from that immutable Media layout. Shared stage/source metadata preserves the existing GPU/SDK contracts and refuses changed inputs or publication flags. Synthetic byte/command fixtures and executable mutations cover the boundaries; actual Media/Android completion, native/GIL/FT products, licences, runtime and FINAL consumers remain separate required proofs. See [the handoff workflow](local-proof-workflows.md#native-media-to-android-handoff).

## 2026-11-14 — retain live IREE wheelhouse cache inputs

- Extend the existing read-only Media log reader to the exact outer app-wheelhouse RUN, retaining its final-drain lifetime and mandatory input hashes. The stable four-file configure snapshot adds an explicit IREE target profile with matching Media unit/process and build-root checks; its default MIGraphX profile remains available. Independent file/process fixtures and executable guard mutations cover phase, CLI, owner and path refusals. These host tools preserve the live build and prove neither completed cache performance, error causes, linkage nor image/hardware acceptance. See [live configure snapshots](local-proof-workflows.md#live-configure-snapshots).

## 2026-11-14 — retain native ORT Media cache diagnostics

- Extend the existing bounded host readers to exact outer CPU, GPU/plugin and Wasm-build commands in the normal Media Dockerfile. Child commands, other phases, verify-only calls and wrong unit owners refuse; Media sealing requires the actual worker/profile hashes before writing a proof. Independent process/Dockerfile fixtures and executable mutations cover these boundaries. Old compiler/MIGraphX profiles and raw/partial statuses remain intact. These host tools leave the live producer unchanged and do not classify cache errors, prove a flavor or grant image/hardware acceptance. See [phase-scoped log retention](local-proof-workflows.md#live-cache-log-retention).

## 2026-11-14 — complete repaired GPU5 and verify its native handoff

- The ordinary frozen `8c4e13b0` GPU5 completes and loads all seven recorded source entry libraries. Its immutable local image and native OCI export match, all 43 layers rehash and all 41 SDK descriptors/diffIDs match; the bounded export has both raw statuses zero and is sealed/stopped. Final source counters retain 5,244 hits, one miss and eleven unclassified cache errors; the complete read-only log retention is zero bytes, which does not classify those errors. Authorized idle regular-layer cleanup preserves all cachemounts and 47 image identities and restores the unchanged reserve. The first normal ROCm Media unit is now running with both required Wasm flags; actual flavors, licences and finished-consumer/final-image acceptance remain open. See [the actual loader and native-handoff scope](linux-accelerator-images.md#source-backend-entry-library-loads).

## 2026-11-14 — reclaim obsolete published local images autonomously

- Record the owner's standing local container-cleanup authorization and the exact-tag workflow: first prove idle state and immutable registry/config availability, then remove only selected obsolete published copies, retain every unselected image/cachemount identity and recheck real disk admission. The actual four-image cleanup frees 121,229,893,632 bytes, preserves all 12 cachemounts and 46 other image entries, and admits the single prepared ordinary GPU5 from frozen `8c4e13b0`. No registry data, volume, checkout or receipt is deleted, and no new image/consumer acceptance is claimed. Reuse existing versioned probes and documented nerdctl commands; [host cleanup](linux-host-setup.md#b7-reclaiming-disk-without-losing-the-compile-caches) owns the mechanism.

## 2026-11-14 — qualify the repaired GPU source before its ordinary rebuild

- The frozen SQLite-loader source `8c4e13b0` passes all 6,246 mutations/42 default groups and 617 suites/32,480 assertions; the complete receipt binds exact IDs, successful cleanup, independent container absence and stopped test unit. Separate host selector tools `158daf7f` pass their affected-source and normal-hook checks. No repaired GPU image or Media acceptance follows: the fresh 180-GiB admission still refuses and the remaining regular cache cannot cover the gap. Preserve the original GPU4 runtime failure and all protected data. The actual configure snapshot also identifies vendor SQLite 3.51.3 and nlohmann/json 3.12.0; this is selection evidence, not completed binary licence review. See [the loader evidence and remaining scope](linux-accelerator-images.md#source-backend-entry-library-loads).

## 2026-11-14 — bind native GPU export to a checked local manifest selector

- The actual Docker-loaded local GPU4 image resolves by immutable manifest ID, while its digest-qualified repository name and inspected config ID do not resolve as local image selectors. Use the manifest for the bounded host export and independently require its lookup to match the tagged image's config and manifest. Preserve all native byte/SDK ancestry, source proof, raw status, disk and final-acceptance guards; Media keeps repository@digest with its native context. Command fixtures, refusal controls and executable mutations cover this selector boundary. The actual engine readback proves resolution only, not a completed export, rebuilt image or hardware inference. See [the observed local resolution failure](failure-modes.md#local-docker-loaded-gpu-image-does-not-resolve-by-repositorydigest).

## 2026-11-14 — require installed MIGraphX entry libraries to load

- Ordinary GPU4 builds and stages successfully, then its real core load exposes an unregistered vendor SQLite dependency. Discover the exact ROCm SQLite soname through the existing shared publisher, preserving source-first order and ASAN exclusion. The normal AMD producer now invokes `stage-backend-install.py verify-loads` after `ldconfig`, binding every selected entry's bytes to the install record and retaining real dynamic-loader failures. Native DSO, CLI, path and shell controls cover the new gate; the actual unchanged-image control fails and the disposable corrected-publisher replay loads all seven entries plus matching cold core/GPU bytes. Keep that diagnostic scope separate from a rebuilt image, complete ABI/licences and hardware inference. A new exact source profile binds this delta and retains both earlier profiles, SDK/HIP pins and complete-source admission. See [the failure and required follow-up](failure-modes.md#migraphx-core-cannot-find-rocm-sqlite).

## 2026-11-14 — preserve native GPU-to-Media handoffs

- Share the bounded native OCI export transport and add explicit ROCm amd64 GPU export/sealing and ordinary Media launch commands. Require the completed GPU producer, exact source/SDK receipts, current image identity, every native blob and matching SDK layer descriptors/diffIDs. Reuse verified parent layer links while retaining independent child metadata and raw producer/extractor failures. Media requires both Asyncify and JSPI through the normal build driver and unchanged disk/idle gates. Synthetic archive/command controls and executable mutations cover refusals; these tools do not authenticate receipts, prove binary licence closure, hardware inference or final acceptance. See [native GPU handoff](local-proof-workflows.md#native-gpu-to-media-handoff).

## 2026-11-14 — handle actual MIGraphX CMake installation

- Coalesce exact repeated CMake install rows while retaining normalized-alias, complete-tree and original-notice checks. Require each selected library exactly once in either the public or private ROCm library directory, check native ELF identities there, and give both directories priority over distro libraries in GPU/runtime environments and the shared loader configuration. The ordinary GPU source profile admits only these four reviewed production-file hashes with a fresh complete source proof and the original qualified SDK. Fixtures cover staging, ambiguity and path order; they do not establish a rebuilt image, full binary licence closure or GPU parity. See [the actual staging failure](failure-modes.md#migraphx-install-refused-repeated-normalized-install-path).

## 2026-11-14 — request raw HIP device output

- Request Clang's raw HIP device ELF before inspection and report non-ELF results explicitly. The kernel, pinned compiler, selected ROCm headers/device libraries and architecture remain required. The qualified SDK-to-GPU launcher can reuse the existing SDK for this exact isolated smoke repair with a separately verified complete source preflight; it records both revisions and rejects additional production changes. Fixture and mutation coverage grades flags, refusal boundaries and CLI forwarding, not actual ROCm compilation or GPU inference. See [early HIP check](linux-accelerator-images.md#early-hip-device-compiler-check) and [stage launch](local-proof-workflows.md#ordinary-sdk-and-gpu-stage-launch).

## 2026-11-14 — preserve local BuildKit cache transfer

- Replace recurring cache-copy command sequences with `seed-buildkit-cache.py` and its shared verifier. Require a successful stopped producer and current inactive unit, hash every referenced blob, hard-link only immutable CAS bytes and separately copy index/layout metadata into a fresh destination. Refuse overlaps, symlinks, other filesystems and existing outputs; partial failures retain evidence without a passed receipt. Real-file fixtures and executable mutations cover transport and receipt refusals. The next normal command still needs an explicit verified cache import; no cache hit or image acceptance follows from transport. See [cache transfer](local-proof-workflows.md#local-buildkit-cache-transfer).

## 2026-11-14 — preserve reviewed compiler plan profiles

- Extend the canonical compiler planner with an explicit native-AMDGPU profile: require the three LLVM changes plus the known OCI transport delta, prove that transport against its fixed ancestor commit, and retain every original/current fingerprint. All five storage controls, unchanged GNU mounts, manager restrictions, source/commit proofs, disk floor and publication refusals remain required. The default wrapper-repair profile keeps its three-file contract. Synthetic file/Git/manager fixtures and executable mutations cover these boundaries; preparation grants no build, provenance, cache-hit or image acceptance. See [compiler planning](local-proof-workflows.md#native-amdgpu-compiler-planning).

## 2026-11-14 — require native AMDGPU and early HIP device compilation

- Share native SDK/HIP argument and compiler setup in `native-check-common.sh`; preserve its companion in the narrow image closure and copied fixtures.

- Let rocMLIR and the full backend use the existing memory-capped heavy-C++ automatic worker count when `JOBS` is unset. Explicit requests retain the same cap; the memory budget is unchanged.

- Build the native source LLVM with AMDGPU beside its configured CPU targets and refuse installed prefixes missing a required backend. Compiler and SDK receipts require all four configured backends; older CPU-only receipts retain their historical scope. Before expensive MIGraphX source dependencies, compile a real offline HIP kernel with the pinned own Clang/GCC and selected ROCm headers/bitcode, then require an AMDGPU ELF object. Retain arguments, raw failures, diagnostics and object hash through the shared temporary-object lifecycle. Independent compiler/ELF doubles and executable mutations cover the gates; actual rebuilt compiler, backend and hardware acceptance remain separate. See [the early HIP check](linux-accelerator-images.md#early-hip-device-compiler-check).

## 2026-11-14 — preserve live configure snapshot functionality

- Preserve repeated CMake/Ninja diagnostic copying in a versioned bounded helper. Bind the actual live producer invocation, matching process/start identity and four named files; compare source hashes before/after copying and verify copied bytes. Refuse traversal, symlinks, overlap, stale outputs and size overruns. Independent file/process/unit fixtures and executable mutations cover the gates; a snapshot grants no build, source-authentication, linkage, licence or image acceptance. See [live configure snapshots](local-proof-workflows.md#live-configure-snapshots).

## 2026-11-14 — retain live MIGraphX cache diagnostics

- Extend the versioned read-only cache reader to the actual normal MIGraphX source-build process. Share phase/unit identity, retain compiler profiles, bind current worker/companion hashes and place each unit log beside its fresh invocation. Preserve existing log bytes through teardown and reject symlinks, inode replacement, oversized logs and reused outputs; timeout remains a partial observation. Synthetic process/command regressions and executable mutations establish these boundaries, without changing a producer or classifying cache errors. See [live cache log retention](local-proof-workflows.md#live-cache-log-retention).

- Preserve completed source-check failures when a mutation survives before quality starts: require the exact disjoint passed/survived IDs and matching failed summary, cleanup and independent absence; retain quality-failure checks and never create a successful source seal.

## 2026-11-14 — preserve ordinary GPU stage admission

- Add a versioned normal ROCm GPU launcher bound to the exact SDK invocation, native image, verified OCI blobs, compiler ancestry and complete source proof. Share SDK/GPU host admission and bounded transport, preserve raw launch failures and refuse collisions, ambient flags, concurrent work or insufficient disk. Independent synthetic fixtures and executable mutations cover the refusal gates; this starts the ordinary AMD Dockerfile and grants no backend, cache or final-runtime acceptance. See [ordinary stage launch](local-proof-workflows.md#ordinary-sdk-and-gpu-stage-launch).

## 2026-11-14 — share verified native OCI parent layers

- Keep recurring OCI validation/seeding logic in shared versioned modules. SDK exports bind the current worker bytes, rehash the sealed parent and hardlink only its immutable layer files into a fresh child context; child metadata remains independent. Preserve post-link identities through real tar extraction and retain every blob/ancestor check before sealing.
- Retain both producer and extractor statuses, including conditional callers and ordinary errexit; a valid archive followed by a producer failure cannot report success. Add synthetic OCI/real-tar refusal, metadata, failure and SDK launcher/sealer controls with executable mutations. Shared-byte counts do not waive the disk floor or prove image/GPU acceptance. See [verified parent layer reuse](local-proof-workflows.md#verified-parent-layer-reuse).

## 2026-11-14 — preserve explicit SDK qualification and ancestry profiles

- Extend the canonical image qualifier and native OCI handoff with an actual SDK invocation input. Bind the successful SDK producer, complete source, qualified compiler parent and original loader probe; retain the separate three-target compiler contract. Check native SDK aliases, C/C++ execution and default/login tool and loader selection, then hash every OCI blob and all compiler ancestor layers. Add shared binding checks, independent refusal fixtures, transport doubles and executable mutations. These component profiles do not prove foreign SDKs, complete C++ ABI, GPU inference or final runtime acceptance. See [SDK component qualification](local-proof-workflows.md#sdk-component-qualification).

## 2026-11-14 — align the independent image probe with the repaired wrappers

- Require the filesystem-root sysroot in all six image-probe wrapper contracts. Preserve independent positive fixtures and reject the old double-root layout for both foreign C/C++ drivers; actual mutations restore each obsolete foreign expectation. Keep the failed probe and retry the same immutable compiler image with fresh input hashes. This host-only correction grants no SDK or final runtime acceptance.

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
  a name still counts as absent, an older limit ([§ E](cross-build-verification.md#e-ort-single-source)).
- The entries reach the probe as paths below its `--root` (`/lib/glibc:/lib`), which is how it prints every path of
  a bundle; joined to the host path they would find nothing.
- `--help` and a usage error print the usage again: the function read `# Usage:` comment lines the file no longer has.
- `python-app-bundle.sh` is unchanged. A Python AMD bundle keeps the module in `onnxruntime/capi`, which no launcher
  path names; read in the scripts and seen on a fixture, its `libonnxruntime.so.1` is the closure's copy in
  `runtime/lib`, on the launcher's path only through the bundled loader and otherwise preloaded by
  `sitecustomize.py`. BACKLOG CON256 (i) holds the open point.
- `test-ort-census.sh` gains three cases; recipes `ort-census.library-path-*` (nine) and
  `ort-census.probe-ldpath-before-runpath` hold them, each seen to bite. Not run in the x64 rocm image or on a real
  `libmigraphx-ep.so`. Contract: [`consumer-image-contract.md`](consumer-image-contract.md#prove-your-bundle-ships-the-images-onnx-runtime).

## 2026-11-13 — match Cross-Clang's sysroot to the staged GNU layout

- Actual same-image baseline/control probes show Debian libc/libm linker scripts fail beneath a second `/usr/<triplet>` sysroot. Keep all wrappers at the filesystem root, matching source GNU, and require foreign staged target trees before writing them. Check generated wrapper arguments on every supported host/target combination. Fresh ordinary compiler, SDK and consumer acceptance remain required.

## 2026-11-13 — preserve actual linker errors and recurring diagnostic drivers

- Retain common compiler link stderr and raw failure statuses; fail invalid temporary allocation and cleanup. Add a 47-assertion fixture and six executable mutations; share invalid-allocation fixtures with the object lifecycle suite through the harness.
- Version the bounded failed-compiler prefix exporter, exact-image linker launcher, worker and fixture closure. Eleven exporter and twelve receipt/worker mutations exercise their independent refusal tests. Diagnostic images and sysroot overrides never qualify a normal compiler, SDK or final runtime; the mandatory production smoke remains required. See [local operational workflows](local-proof-workflows.md#failed-compiler-linker-diagnostics).

## 2026-11-13 — version recurring operational tools and their companions

- Preserve the recurring source-proof, compiler/SDK, cache-diagnostic and cleanup drivers under versioned script paths, with an inventory of their former session copies. Make machine and run inputs explicit while retaining original authorization, resource, ancestry, cleanup and receipt guards. Add a shared multi-run handoff updater and executable refusal regressions; historical evidence and frozen build sources stay preserved. See [local operational workflows](local-proof-workflows.md).

## 2026-11-13 — preserve the SDK compiler order in the AMD GPU environment

- Keep source MIGraphX first, the inherited GNU/source-LLVM PATH next and ROCm tools afterward. The old environment placed distro LLVM ahead of the qualified source compiler. An executable-resolution fixture expands the actual Dockerfile expression with spaces and conflicting tool names; three mutations remove or shadow the inherited tools. Actual rebuilt GPU/default/consumer acceptance remains required.

## 2026-11-13 — check the native architecture Clang wrappers explicitly

- Run both native architecture wrappers through the same exact-pin, object and link probes before the foreign-target loop, which intentionally skips the host. Bare host Clang is a separate command. The 50-assertion fixture includes explicit dispatch coverage and an executable removal mutant; real rebuilt-image acceptance remains required.

## 2026-11-13 — keep Cross-Clang wrappers on the pinned source compiler

- The exact e7ca source proof now passes all 42 groups, all 5,886 actual mutations and 604 suites with 32,301 assertions; successful terminal, canonical cleanup and independent container absence are sealed. Actual SDK2 completes materialization and Vulkan setup, then fails through the versioned distro Clang wrapper with an LLVM symbol lookup error. Preserve both SDK failures and the qualified compiler's narrower receipts.
- Publish cross wrappers after source building; prefer the existing native source prefix before the versioned bootstrap and refuse incomplete or dangling source trees. Build the native LLVM with its host and configured cross CPU backends; retain narrow foreign target-native trees.
- Require both Clang wrapper drivers to pass the exact successful pin and existing target object, link and QEMU smokes. The new selection/backend/dispatch/installation fixture has 49 assertions and 24 executable mutants; a fresh multi-target compiler and ordinary SDK/backend/consumer acceptance remain required.

## 2026-11-13 — preserve LLVM paths during SDK materialization

- The ordinary compiler now completes. Its actual image passes all 157 native tools, six compiler defaults and source LLVM loader selection in ordinary and SDK login shells; its native OCI matches the qualified manifest and original base ancestry.
- The first ordinary amd64 SDK fails verification because materialization removes the native LLVM prefix from PATH and loader references. Preserve this failure; restore the selected prefix as an alias and retain the native host tree for foreign targets. Filesystem regressions pass 67 assertions and all eight new mutations bite; fresh SDK and final consumer acceptance remain open.
- Source repair `e7ca4436` passes all 24 affected mutations, all 26 quality groups and 16 unchanged normal-hook controls; its exact committed patch matches the tested snapshot. Real disposable parent-image replays for amd64, arm64 and riscv64 preserve both Clang hashes, the native 157-tool inventory, compiler defaults and source LLVM loading in ordinary and SDK login shells. Every replay seals successful state, cleanup and independent container absence. This proves materialization only; the repaired source's complete 5,886-mutation preflight and ordinary SDK/backend/consumer acceptance are separate.
- Record standing owner permission for canonical Linux layer cleanup when disk admission fails. Keep compiler cachemounts and required images, compare identities and recheck the original guard; default to 120 GB retained layers with duplicate removal disabled.

## 2026-11-13 — record compiler-cache evidence limits

- Bind the original GNU counters to their preserved log and document the configured error-log path under the GNU RUN's tmpfs. Original log creation is unproved; any file written there would be temporary. A fresh query of the preserved compiler image finds no error log. The 186 cache errors remain unclassified; zero failed S3 writes is a separate result.
- Keep raw phase diagnostics as a requirement for the next naturally executed source/media build. Existing compiler inputs, caches, image receipts and the disk-admission floor stay unchanged; no rebuild or zero-error claim follows from this investigation.

## 2026-11-13 — publish native LLVM loader priority

- Read-only diagnostics show source Clang loading its own LLVM via RUNPATH while the default loader cache still prefers the distro's identical LLVM soname. Keep those separate findings.
- Reuse one loader-path publisher for the native compiler's late `000-llvm-native.conf` and the package's existing `000-llvm-target.conf`. Keep original default paths, shell options and raw config/cache failures; carry the companion in isolated package copies.
- Native probe schema 2 reads each original shared library's ELF SONAME with bounded successful `readelf -d`, distinguishes it from `llvm-config`'s linker alias, and requires a raw-cache-backed source winner. Missing, ambiguous or failed reports fail; this is no SDK ABI or inference proof.
- Local `6412e572` passes 309 Python methods, all 102 affected mutations (20 new), all 26 quality groups and 16 normal-hook controls. The exact committed patch matches the tested snapshot. A real image-bound red/green replay changes bare-soname loading from distro LLVM to the source file and verifies its hash; the original six compiler defaults remain correct. Fresh compiler/SDK and final GPU acceptance stay open behind disk admission.
- The earlier frozen `b7fab2ed` full preflight passes all 42 groups, all 5,844 actual mutations and 602 suites with 32,207 assertions. Its successful unit state, cleanup and independent container absence are retained; the newer frozen 6412 source run is separate and now passes all 42 groups, all 5,878 actual mutations and 603 suites with 32,234 assertions. Its exact mutator-byte slice, strict whole-manifest seal, successful LOADED state before stop, canonical cleanup and independent container absence are retained. This remains source evidence; fresh compiler/SDK, image-matrix and finished GPU acceptance stay open.

## 2026-11-13 — prefer every native source LLVM tool

- Local source `c215635d` passes 304 Python methods, all 47 affected mutations (14 new), all 26 normal quality groups and 16 unchanged hook controls. The real original fails status 1; the explicit candidate PATH passes all 157 tools and keeps GNU defaults. The next canonical build remains gated on disk admission; no fresh-image or SDK acceptance is claimed.
- The corrected compiler image passes the six ordinary compiler defaults, but broader inspection finds 153 of 157 source tools elsewhere on PATH; default `llvm-config` still reports distro 23.1.6 against source 23.1.5. Preserve that narrower pass and the failed SDK admission.
- Put the native LLVM bin directory behind Python and GNU after the expensive source builds. Carry the permanent probe in the compiler bundle and require every executable source tool to win PATH, a complete unique core inventory and the exact successful `llvm-config` pin.
- Keep this native tool-selection mode separate from the amd64 GNU default-ISA probe. Regression fixtures do not prove linked library versions, rebuilt-image admission or SDK/backend/GPU acceptance.

## 2026-11-13 — select the pinned native LLVM tree

- Source commit `b7fab2ed` passes 297 Python methods, all 75 affected mutations (20 new), all 26 normal quality groups and 16 normal-hook samples. An actual digest-bound selection replay proves both Clang aliases at 23.1.5 and all four GNU aliases at 16.2.0/v3/generic. The canonical rebuild reuses both expensive GNU/LLVM RUNs; final image qualification and the newer 5,844-mutation preflight remain open.
- Correct the compiler stage's alternatives to use its explicit native source prefix and refuse incomplete installs before updates. Keep GNU aliases and expensive compiler cache layers intact.
- Replace the Clang channel smoke with an exact successful first-line version check; wrong patches, prereleases and failed children fail the aggregate.
- Isolate the copied-installer fixture from inherited cross-image mode; retain missing, empty, partial and parse failure assertions.
- Preserve an amd64 installed-defaults probe with raw child evidence, exact GNU/LLVM pins and unforced v3/generic checks for every ordinary GNU alias. Synthetic tests and mutation recipes cover refusal; rebuilt-image and downstream acceptance remain required.

## 2026-11-13 — prepare executed WASM factory receipts

- Source preparation now passes 280 Python methods, 131 actual affected mutations, all 26 normal quality groups and the unchanged normal hook's 16 actual samples at local commit `031569f5`. Its full 42-group/5,824-mutation preflight now passes 600 suites and 32,176 assertions; actual instrumented WASM/image/consumer acceptance remains open.
- Reuse the native C API factory controls through an explicit linked-core WASM entry and a deferred CMake hook on the owning target; preserve native loader cleanup, operator hooks and the two core pass arguments.
- Require bounded Node execution, actual JSPI capability, numeric status, exact C success/negative controls and unchanged inputs. Bind both module and loader bytes plus per-flavor raw runtime receipts; add a fresh two-flavor replay.
- Carry the Hub probe's original MIT text with each instrumented WASM product and bind its exact bytes; reject altered or linked notice destinations.
- Advance the shared artifact pool to `-wgpu4` and bind all runtime/probe recipe companions. Fake host ABI/loader fixtures test refusal and transport; actual instrumented builds, the image matrix and finished consumer acceptance remain open.

## 2026-11-13 — reconcile the preserved Rust workspace proof

- Independently recheck the 11 November complete Rust test log: 912 passed cases in 64 summaries, zero failed, ignored or filtered; cleanup and container-absence receipts remain preserved.
- Compare its recorded source inventory with the verified newer prepared package snapshot. Declared Rust/Cargo/native/shader hashes match, while docs and test scripts differ and seven historic source-root files have drifted. Preserve the old evidence; fresh-image, recorded-pin and finished GPU/package acceptance remain open.

## 2026-11-13 — measure compiler-cache activity without rates or timings

- Limit the permanent sccache probe to aggregate integer request, hit and write counters. Falling hit rates and durations can no longer erase actual activity; subtotals and error rows cannot manufacture it.
- Retain raw stats failures and independent original-fails/corrected-passes fixtures. The corrected actual base replay records four cached compiler calls, two hits and two misses; its container matches the checked image. The old contradictory diagnostic remains preserved. This is bootstrap-cache evidence only; ordinary compiler/SDK/backend acceptance remains open.
- Keep host test TMPDIR outside Git checkouts, so isolated non-Git fixtures cannot accidentally inherit the parent repository index. The unchanged normal hooks pass there; their earlier baseline failure remains recorded.

## 2026-11-13 — bind selected script transport to its complete receipt hash

- Stage each named SDK/AMD script bundle under its full receipt SHA256 and a fixed files leaf. Validate and forward HUB_SCRIPTS_KEY; exact COPY and read-only selectors reject a missing namespace while preserving the legacy flat staging API.
- Keep deterministic modes/timestamps and exact source bytes. The permanent cache probe now uses an equal-length selected-source edit and saves raw child status before its strict step/artifact verdicts. The corrected real six-solve replay now passes for both transports: cold execution, an unchanged-byte cache hit and exact new bytes after an equal-length selected edit. Original inputs remain unchanged; this proves script transport only. The earlier stale-byte failure remains failed, and ordinary compiler/SDK/backend and finished GPU acceptance remain open.

## 2026-11-13 — preserve an actual selected-context cache probe

- The original flat SDK transport test detected stale receipt bytes after a selected source changed and correctly refused acceptance. Its failed evidence remains preserved; the subsequent namespace result is recorded above.

- Add a permanent amd64 BuildKit probe for the SDK COPY alias and AMD read-only context mount, with cold, unrelated-source and selected-source controls, exact plain-step markers and exported receipt-bound bytes.
- Derive one checked native OCI layout from the pinned input for nerdctl; retain original blobs, local OCI pins, unchanged original inputs and raw child failures. Fake-engine negative fixtures do not prove actual cache reuse or compiler/image/GPU acceptance.

## 2026-11-13 — wire the complete source backend into the normal AMD producer

- Keep AMD's apt SDK and build the complete pinned MIGraphX stack in its normal GPU stage. Install exact pybind11 first; SDK and AMD share a core manifest; the host driver stages a deterministic selected-file context and passes it as `hub-scripts`. The compile step consumes 76 selected source files with compiler/source/uv caches and the upload secret.
- Extend script-copy coverage to actual declared bundle transports and complete mounted inputs, retain real missing-script failures and reject false .sha256-to-.sh matches. SDK cold-import suites use the read-only declared-script map; namespace, deterministic-byte and mutation controls do not prove BuildKit hits.
- Share ROCm configuration publication between the GPU entry and runtime copier. Preserve source-first lib/lib64 ordering, required build/publication/ldconfig failures and the original build status during failure-time cache drain.
- Prefer the corrected prefix in GPU and conditional shipped-runtime PATH, pkg-config, Python, CMake and loader paths. Shell/transport/mutation controls do not prove a built image, actual ELF selection, complete licences or finished GPU consumer acceptance.

## 2026-11-13 — retain pybind11's original source-backend notice

- Require the builder-selected Python pybind11 version, one regular original distribution notice and the same configured CMake package before staging its original text and recording provenance.
- Preserve the exact 3.1.0 original notice fixture and policy hash; reject version/origin/path/duplicate/missing inputs before receipt publication. Complete binary licence review remains false.
- Genuine rocmlirTriton cold/warm build/install and host C API checks pass with 2,272 identical installed files and 44 original notices. The replay measures 3,169 hits and one successful coverage-probe miss; seven cache errors and two compiler failures are classified negative feature probes. Normal backend/image/consumer acceptance remains open.

## 2026-11-13 — preserve source MIGraphX priority in runtime loader paths

- Share ordered ROCm runtime directory enumeration through the existing packaging inventory companion. Source MIGraphX lib/lib64 precede retained distro/HIP paths, entries appear once, command-line ROCm links are followed and ASAN stays excluded.
- Resolve discovery and ordering successfully before replacing the runtime configuration; preserve raw failures and output errors under conditional callers. CPU and legacy layouts retain their policies.
- Filesystem, regular-publisher and mutation controls do not prove real ELF loader selection, normal source GPU-image construction or final image/consumer acceptance.

## 2026-11-13 — repair five full-preflight integration regressions

- Classify source MIGraphX package/API pins under their real manual owner and hold each slaved source hash; retain the existing checksum audits without adding exemptions.
- Keep guarded FT compiler-cache setup, each native helper's own logging bootstrap, and the narrow S3-drain mount and final drain on the FT dependency Dockerfile RUN.
- Keep cache fixture image paths inside the shared helper fixture and reject comment-only logging bootstrap references; the first image-based repair replay exposed both controls.
- Quote the SDK fixture log redirection and assert complete child argv. Unquoted space-containing paths previously passed ten tests while leaving a sibling file in the suite TMPDIR. The failed full run remains preserved; targeted source controls do not establish a full green preflight or final image acceptance.

## 2026-11-13 — launch the real rocMLIR component through the preserved proof transport

- Add a separately selected rocMLIR build mode invoking the existing complete builder and required external API consumer, with both original archives, normal offline entrypoint and canonical/exact 180GiB admission before freezing.
- Keep preparation at five minutes and parser builds at two jobs/6GiB/one hour; rocMLIR uses four jobs/12GiB/two hours. Executed worker environment, immutable inputs, raw failures and resource-refusal controls have mutation proofs. A transport proof does not establish a completed vendor build, normal image wiring or final acceptance.

## 2026-11-12 — the consumer hook pair: staged checks on a commit, the repo's full gates on a push; mutation staleness is a lint gate (CON243, CON244)

- `shared/linux/templates/git-hooks/` holds a `pre-commit` and a new `pre-push`. Both call the repo's own
  `scripts/linux/run-lint-gates.sh` when it has one and the bare aggregator only when it has none. The old
  `pre-commit` called the bare aggregator, so it dropped the wrapper's `--ratchets`, and with it the large-file
  check, and `--agents-drift`. It was also tracked as `100644`: git skips a hook that is not executable with one
  `hint:` line, so the template ran in no Linux clone. Both files are executable now.
- `pre-commit` runs the wrapper with `--staged --index <the index of this commit>`: the large-file check, behind
  `--ratchets`, and the secret scan over the staged blobs. `git commit -a` and `git commit <path>` are graded on the
  index git builds for them. One staged file took 2.4 and 2.7 s in a scratch clone of OxidANT on the Raspberry Pi 5.
- `pre-push` runs the wrapper, then `scripts/linux/pre-push-checks.sh` when the repo has that file; the contract is
  in [`adopting-in-a-new-project.md` § The git hooks, by reference](adopting-in-a-new-project.md#the-git-hooks-by-reference).
  A push took 130 s in the same clone beside another build, 188 s under more load: the shellcheck warning
  ratchet 60 s, shellcheck 32 s and gitleaks 26 s of the 130.
- `run-lint-gates.sh` has an eighth gate, `mutation staleness`, over every tracked
  `scripts/linux/tests/*mutations*.json`: a stale recipe fails with its id, in every consumer and in the reusable
  lint lane. It takes `--staged [--index <file>]`, and it prints one warning line when `core.hooksPath` is unset
  and `CI` is not set.
- `test-consumer-hooks.sh` drives both hooks with real commits and pushes in throwaway repos, over a hub copy whose
  downloaded linters are stubs; `test-lint-gates.sh` holds the gate. 22 recipes `lint-gates.*` hold the behaviour,
  each proved by hand. Not run: the full preflight, CI, and a push from a real consumer clone.
- A review ran both hooks in scratch clones of OxidANT and OrchestrANT, the hub tree copied over the submodule,
  pushing to throwaway bare remotes. A clean push passed (127 s and 84 s). A stale recipe and a shellcheck error
  each stopped the push by name in both, an oversized comment block in OxidANT, and a failing
  `pre-push-checks.sh` in both. A commit took 3 s, and 5 to 16 s with all four cores busy.
- Open, `BACKLOG.md` CON269: the four consumer wrappers still carry their own `--stale-check` loop, no hook
  checks line endings in a consumer, no gate lints the two hook files, and a linked worktree without the hub
  submodule has no hook and no line that says so. CON270: the hub's own `pre-commit` reads the old index under
  `git commit -a`.

## 2026-11-11 — record private NVIDIA producer and host acceptance

- Record the completed `a4d31ea5` private NVIDIA chain and image-bound five-run
  CPU/CUDA/TensorRT-plugin/DirectML evidence. Correct the older backlog claim
  that the complete chain and host inference were still unproved.
- Keep compiler-counter measurements, other lanes, consumer adoption and ARM64
  publication separate. This documentation does not move an image tag or approve
  the open CON228 notice draft.

## 2026-11-11 — share portable Torch refusal assertions

- Move the wrapped-refusal control into a portable suite and share its assertion
  with every native installer case. Its mutation runs without Windows batch tools
  on Linux while retaining the raw exit, normalized reason and no-download guards.
  Native installer and interpreter execution cases remain discovered separately.

## 2026-11-11 — run ORT census-path mutations on both hosts

- Extract the three census-path cases into a separately discovered portable suite,
  sharing the wheel-store fixture with native sync tests. Recognise either trailing
  path separator when mapping a Dockerfile directory destination. The Linux mutation
  command now exercises its intended cases without requiring a Windows drive.
- Preserve every native sync case and the inherited-twin negative control; a second
  mutation checks the directory mapping. These fixtures do not run real inference.

## 2026-11-11 — align the TensorRT installer reference

- Correct the script reference to describe the single CUDA-matched NVIDIA URL,
  ZIP signature, checksum check and fatal acquisition failure. The installer
  already follows this policy; the reference still described removed fallbacks.

## 2026-11-11 — isolate native Windows test fixtures

- Share captured child diagnostic normalization between Python CI and Torch
  refusal fixtures; wrapped ANSI error text retains status, reason and no-download
  assertions. The ORT census-path fixture clears inherited twin-wheel overrides
  and proves its own path with both overrides deliberately present.

## 2026-11-11 — Windows ROCm plugin lifetime corrections

- Apply the canonical AMD EP node-cleanup and registry-ownership patches before
  configuring the Windows plugin. Typed deletion keeps all six C ABI callback
  adjustments; registry creation is synchronized and its owner releases before
  data transfer. Only the EP RUN mounts the two shared patch files.
- Windows source fixtures cover application, idempotence, missing/stale patches,
  fatal child failures and build wiring. Separate native Windows controls show
  both original failures and 11 node/41 registry checks after correction. These
  controls do not replace the complete plugin build or physical GPU acceptance.
- Share recorded argument and source-order assertions across the AMD EP,
  TensorRT, disk-probe and chain-log suites. Preserve each caller's diagnostics;
  the shared checks retain count, value, argument selection and uniqueness controls.

## 2026-11-10 — require the cuDNN host API smoke control

- NVIDIA smoke now resolves the exact main cuDNN header, import library and
  versioned runtime with the shared recursive finder. Missing inputs fail
  instead of skipping after unset-variable errors. Native host-API execution
  and cross-target link/PE checks retain their existing policies.
- Four regression cases and six biting mutations cover discovery, required
  inputs and dispatch. These fixtures use fake compilation; real image SDK
  linkage, final-source CI and physical GPU acceptance remain separate checks.
  The corrected full live-script replay against the immutable NVIDIA image
  passes 319/0/2, including real cuDNN compilation, linkage and host API execution.

- Six existing smoke mutation commands now let the canonical test runner create
  result directories. This removes a Unix-only mkdir prefix that failed under
  Windows cmd before the unchanged test or mutant could run.
