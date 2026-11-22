# Changelog archive: 2026-11-15 … 2026-11-17

Preserved entries from the Linux and Windows integration. Later entries are in
[the current changelog](../CHANGELOG.md); preceding entries are in
[the 2026-11-13 … 2026-11-14 archive](changelog-archive-2026-11-14.md).

## 2026-11-17 — preserve readable module closures and resume completed media builds

- Add explicit `media-merge` selection after completed media branches, checking
  all three reused parents before the normal merge, without replaying branch
  builds or changing the default pipeline.
- Give every reused media-parent publish check a distinct phase/log label;
  retain all three receipts alongside final publication. The regression
  fails on the real collision, and a live mutation restores that failure.
  Parent labels retain the ordinary publish-probe disk floor; the real
  misclassification and a live resource-policy mutation are checked too.
- Keep reused-parent failure and live-mutation case execution in bounded test
  helpers; preserve all cases and the strict complexity limits.
- Keep compiler-cache and ROCm stale-parent checks armed for that selection.
  Functional fixtures cover partial fan-in, failed parents and ordinary builds;
  executable mutations prove the new checks without claiming image or device
  acceptance.

- End shared media, TVM-private, merge and ROCm module-copy stages with a
  readable source view, preserving narrow closures and product image parents.
- Guard all five stages, COPY/view order and scan coverage with regression
  checks and executable mutations. Full image and device acceptance remain
  separate from structural checks and module-read probes.
- Invoke the existing LiteRT mutation runner directly on Windows; its report
  directory is created by the shared runner, without a POSIX shell prefix.
- Keep module-view mutations in the existing portable mount harness so Linux
  shards prove them without Pester; retain the separate full module-closure suite.
- Redeclare the target-architecture argument in all four external module-view
  stages and prove each declaration with a portable mutation.
- Parse ROCm module closures and compiling-stage pin defaults through shared
  Dockerfile stage readers, retaining missing-module and missing-pin failures.
  Shared structural fixtures run on Linux and Windows; native DLL tests stay
  in the complete Windows suites.

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

## 2026-11-16 — include the PyTorch adapter in Windows patch drift checks

- Check the torchvision host-cache patch against its actual PyTorch upstream at
  the existing `PYTORCH_VERSION` pin. Retain full catalogue coverage, Git and GNU
  patch checks, source-pin loading and explicit diagnostic override precedence.
- Cover missing mappings, wrong upstream ownership and ignored source pins with
  local accounting tests and three executable mutation recipes.

## 2026-11-16 — declare the ROCm torchvision patch root

- Give the torchvision entry its own canonical asset-root resolver before it
  imports the Torch builder. The existing parity gate retains its checks and
  catches deletion of the declaration in an isolated Windows mutation proof.

## 2026-11-16 — keep portable-bundle mutation baselines host-portable

- Run callback output/failure mutations through a cold, portable harness suite
  on Linux and Windows, sharing the install fixture with the Windows suite.
- Retain native Windows CMake/batch coverage in full Windows discovery; preserve
  the original failing Linux baseline without changing production bundle code.

## 2026-11-16 — preserve portable bundle results after package checks

- Keep successful MSI/ZIP checker output in the build log and return only the
  portable bundle object, preserving fatal package-check failures.
- Cover chatty callbacks and rejected installers with valid output-routing and
  failure-propagation mutations. Real package validation remains separately tested.

## 2026-11-16 — keep the torchvision patch fixture within Python quality gates

- Load the patched temporary module through runpy with explicit compiler and
  environment facts; preserve launcher selection, reverse-apply and drift cases.
- Declare fixture parameter/return types and subprocess failure policies explicitly.
  Keep the original lint failures as negative evidence; full qualification remains
  required after the correction is committed.

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

## 2026-11-15 — keep mutation fixtures native on Git Bash

- Pass shard cost-log paths through Python argv and compare the planner's actual
  host-path spelling, preserving the exact diagnostic and complete shard accounting.
- Force only the synthetic host-skip fact; retain the real platform so Windows
  executable lookup can still find bash.exe for mandatory mutant parsing.
- Preserve the two original failing merge-hook baselines and existing skip policy;
  the production mutation gate is unchanged.

## 2026-11-15 — wire the Windows ROCm torchvision host compiler cache

- Apply a required, pinned PyTorch patch only in the disposable torchvision build
  venv and supply the sccache path as a separate host-CXX launcher. Keep real
  compiler paths for ABI probes and preserve HIP compilation and link rules.
- Mount the patch only in the torchvision RUN; a patch edit keeps the torch layer.
- Record a real SDK one-file compile/repeat: one miss then one hit, no cache or
  compiler errors. Complete changed-source wheel/lane qualification remains open.
- Add launcher, patch-drift, optional-cache and call-order regression coverage.

## 2026-11-15 — record private Windows737 producers and AMD test limits

- Bind all four private software producers to source737; retain ROCm's three
  raw results, full ancestry, exact smoke summary and extra HIP-load skip.
- Record private AMD export provenance and both five-run local CPU controls;
  keep the Linux-booted AMD machine's Windows inference unaccepted.
- Preserve the measured torchvision zero-request cache gap and the pinned
  upstream wrapper limitation; no compiler-cache fix is claimed.
- Keep final-source integration/CI, ARM device22 and publication open.

## 2026-11-15 — record the completed Windows CUDA-cache repeat

- Bind the complete d9 diagnostic repeat to its source, five exported image
  identities and parent chains, retained compiler-cache IDs and raw exit zero.
- Publish the full stage ledger and primary typed CUDA counters; preserve reused
  layers, direct compilers and unexplained counters as distinct coverage limits.
- Keep final-source CI, device acceptance and later product lanes separate.

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
