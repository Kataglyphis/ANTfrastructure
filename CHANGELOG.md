# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-11-05`](docs/changelog-archive-2026-11-05.md) ·
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

## 2026-11-19 — CON218 is done: the perf baselines record the shipped text default

- OxidANT, AccelerANTgine and OrchestrANT build their perf model with `genai-model-threads.py --threads text`, the
  owner's text rule of 2026-11-17, so a baseline quotes the default the apps ship. OxidANT's Raspberry Pi 5 baseline
  (e893433) measured 115 tok/s and a 171 ms first token with it. `fleet-health.md` now says that a lane run through
  `on-request.yml` counts its debt from its last direct run.

## 2026-11-19 — the text contract's schema case is typed once, and the page names each binding's backends (CON237 items 1, 2)

- `tiny-genai-model.py` writes `schema_case` into `fixture.json`: the schema `{"enum": [7]}` and its answer, which the
  successor rule never predicts, so only a live guidance mask yields it. `genai-guidance-smoke.py` reads it from
  there in place of its own copy; it printed `genai-guidance-schema-ok 7` in `:latest` on 2026-11-19.
- `language-ai.md`: `:winamd64` ships llguidance (its smoke gate runs the schema case), LAI-H2 is done, and a table
  names each binding's backends; AccelerANTgine's C++ and C have no endpoint client.
- `verify_mutations.py` without `--delegate-chrome` names a selected recipe whose test starts `pwsh` on a host
  without it (`FAIL: pwsh is not on PATH, so …`) instead of running it into exit 127, a vacuous bite. The commit hook
  reruns its sample in the image on that line (CON279), but now proves the rest on the host (`--delegate-chrome`)
  and sends only the named pwsh tests to the image: a host-only test, such as the process-tree kill of
  `test-mutation-gate.sh`, fails in the container for the container's reasons.

## 2026-11-19 — what CON269 left: the `--index` refusal's recipe and two commits through the hook pair

- `lint-gates.index-needs-staged` proves that `run-lint-gates.sh` refuses `--index` without `--staged`. Its mutant ran
  the downloaded linters inside `test-lint-gates.sh`; `test-consumer-hooks.sh` holds the case now, over its hub copy's
  stub linters, so the mutant ends in seconds. The same suite commits through the hook pair: a staged CRLF script
  stops the commit, and an unstaged deletion beside a clean commit does not. CON269 is done.

## 2026-11-19 — fleet-health shows lane debt, reruns and contract drift (CON247 items 1 to 3)

- `lane.<workflow>.commits_since_green`: develop commits after the head of each workflow's newest green develop run,
  so debt from a lane that runs on request shows. `ci.<workflow>.rerun_rate`: the share of the last 20 runs that
  needed a second attempt, without the reruns `retry-disk-refusal.yml` starts on purpose.
- `shared_facts.contract_inference_v1` and `shared_facts.contract_text_generation_v1`: ModelANT's two contracts as
  OxidANT, AccelerANTgine and OrchestrANT see them (lock row, tracked copy or gitlink blob), distinct digests minus
  one. All three agreed on 2026-11-19.
- Items 4 to 6: `sibling_pin.<repo>.lag_commits` for OmniAccelerANT's OxidANT and AccelerANTgine gitlinks;
  `bench_history.<artifact>.days_since_sample`, `stale` above 14 days; and `image_lag.lanes_without_run`, the lanes
  whose newest develop run is older than the image tag they pull, from the package versions (`fleet-health.yml`
  gains `packages: read`). CON247 is done.
- Found by the first record with these rows (run 44558849413): in OxidANT, AccelerANTgine and OrchestrANT the newest
  green run's head comes from before a history rewrite, so `compare` answered 404 and took every `ci.*` row of the
  repo with it. The refusal stays in that lane's debt row now, not collected, and the other rows stand.

## 2026-11-19 — what CON248 and CON249 had left: a real auto-commit suite and uv's floor

- My BACKLOG removals of CON248 and CON249 had left their last paragraphs behind, and those named two parts not yet
  built. `windows/scripts/tests/AgenticLoop.Commit.Tests.ps1` runs `Invoke-GitAutoCommit` against a real repository:
  a 1 MB binary, a small binary and a 501 KiB file stay out and are logged, and a commit a hook refuses returns
  `$false`, each with a fault control. `consumer_pins.py` reads `[tool.uv] required-version`: a lower bound at or
  below `UV_VERSION`; an exact pin or a higher floor fails. OrchestrANT and AccelerANTgine (`>=0.11.3`) pass.

## 2026-11-19 — a consumer documents its local test step through `run-in-ci-image.sh` (CON242)

- OrchestrANT's AGENTS.md names `run-in-ci-image.sh . --volume orchestrant-uv-cache:/root/.cache/uv -- bash
  scripts/linux/ci_tests.sh` (a0cff92) in place of a commented `nerdctl run`. It ran once on 2026-11-19 in the same
  image and volume, through the Raspberry Pi's capped runner: 3410 passed, 37 skipped, 579 s.

## 2026-11-19 — a read-only doctor names what is stale in a dev checkout (CON249)

- A month-old local image, a uv older than the lock format and a tree about 100 commits behind each cost an hour of
  wrong debugging, and nothing said so. `linux/scripts/dev-doctor.sh <repo-root>` prints one line each for origin's
  develop (by `git ls-remote`, nothing fetched), the submodules, `core.hooksPath`, the local CI image's age and uv
  against `versions.env`, and exits 1 on any. On the Raspberry Pi dev host on 2026-11-19 it named a 10-day-old
  image and uv 0.11.3 against the pin 0.13.7. See [`dev-doctor.sh`](docs/shared-script-libraries.md#dev-doctorsh--what-is-stale-in-a-dev-checkout).

## 2026-11-19 — `cargo_test.sh` records every test as JUnit (CON250 item 2)

- `cargo_test.sh` ran `cargo test` and wrote no result file, so only OxidANT, through its own converter, recorded test
  counts and failures. Its `cargo-test-junit.py` moved to `02-toolchain/rust/`, and `cargo_test.sh` writes
  `logs/test-results/cargo-test.txt` and `cargo-test.xml` for every Rust consumer (`CARGO_TEST_RESULTS_DIR`, empty
  writes neither). The status is cargo's; a log with no test binary in it fails. Stable libtest prints no per-test
  time, so each binary keeps only its total.
- OxidANT calls it since d1bcd2c and deleted its own converter, so CON250 is done.

## 2026-11-19 — a hung C++ test ends named (CON250 item 1)

- `ctest-run.sh` set no per-test limit, so a hung test ended at the lane's 60 to 150 minutes without a name. It passes
  `--timeout 1500` (CTest's own default) unless the caller sets one: `--timeout`, `CTEST_TIMEOUT`,
  `CTEST_RUN_DEFAULT_TIMEOUT` or a `--timeout` after `--`; `0` sets none.

## 2026-11-19 — the agentic loop reads git's exit code and stages by rule (CON248)

- `invoke_git_auto_commit` and `Invoke-GitAutoCommit` ran `git add -A` and `git commit` and read neither exit code,
  so a refused commit was silent and a core file or test output would have gone in. Both stage tracked changes
  (`git add -u`) and new text files of at most 500 KiB (the large-files limit), log each file they leave out, and
  return a refusal: the queue drain stops with exit 1 before the build. Nothing to commit is no failure. The
  executor prompt says to stage changed files by name, never `git add -A`.
- `git.commitGate` (CON248 item 3) is a command both twins run before each auto-commit, for example
  `bash scripts/linux/run-lint-gates.sh`. A failure keeps the task uncommitted, and
  `intervals.maxConsecutiveGateFailures` (3) failures in a row stop the queue with exit 1, like the build cap.
- `verify_stdout_returns.py` read a one-line function (`f() { …; }`) to the next column-0 brace, so a later function's
  log lines counted as its own; a one-line body now ends on its line, and the loggers' own definitions are exempt.

## 2026-11-19 — the consumer hooks path is absolute (CON269 item 5)

- A relative `core.hooksPath` resolves inside each working tree, so a linked worktree without the hub submodule ran
  no hook and git said nothing; a 1 MB binary went in that way. Owner decision: the adoption page's line is absolute
  (`"$PWD/third_party/ANTfrastructure/shared/linux/templates/git-hooks"`), and every local gate run warns a clone
  that still has the relative line, naming the absolute one.

## 2026-11-19 — a consumer's shell line endings are a gate (CON269 item 1)

- The hub's `crlf-guard` was a function of `preflight.sh` over the hub's own files, so no consumer hook checked line
  endings. `linux/scripts/verify-shell-eol.sh [<root>] [--staged]` holds it; preflight calls it, and
  `run-lint-gates.sh` runs it in the full gates (git's `w/` column) and in the staged checks (`i/`, the bytes the
  commit carries). Every consumer passed on 2026-11-19.

## 2026-11-18 — the large-files gate grades the index, not the working tree (CON269 item 4)

- `verify_large_files.py --root` refused a tracked file missing from disk, so a deletion not staged yet stopped every
  commit until it was (AccelerANTgine's clone, 2026-11-12). The size already came from the blob; the NUL sniff now
  reads the blob too, so the gate grades the index alone and a missing working-tree file is no partial tree.

## 2026-11-18 — the consumer hook templates are linted (CON269 item 2)

- `lint-shell.sh` without arguments swept `linux/` only, so `shared/linux/templates/git-hooks/*` and the copied
  `antfrastructure.sh`, which every consumer runs, were linted by hand. The default sweep takes `shared/linux`;
  the files were clean and the warning ratchet holds at 35.

## 2026-11-18 — the Windows detector parity run is one hub copy (CON252)

- OxidANT's and OmniAccelerANT's `scripts/windows/check_gpu_detector_parity.py` shared about 110 lines, the
  photo's hash typed into each. `shared/python/check_detector_parity.py` holds the run: three clean child
  processes, their profiles and the pairwise comparisons, the photo digest, the confined runtime and the
  DirectML adapter. The launcher command is an argument. See
  [detector parity](docs/gpu-artifact-receipts.md#detector-parity).
- Both consumers call it: OxidANT `16890ff` and OmniAccelerANT `85eddd8` keep only their launcher and model check.

## 2026-11-18 — a new oversized Rust, Dart or C++ function reads `regressed` (CON246)

- `functions_over_80_lines_extra_languages` was class `report`, so `quality-report.sh --compare` never graded it and
  fleet-health showed a rise as `moved`. It is graded now (class `code`). A Dart `main()` in a `*_test.dart` file
  (`lang_units.is_test_body`) is counted apart as `oversized_test_bodies`: about 22 of the 76 oversized functions in
  OxidANT, AccelerANTgine and OmniAccelerANT were such bodies, whose length is the number of tests. The scanner's own
  exit status does not change. See
  [extra-language readers](docs/code-quality-tooling.md#extra-language-readers-report-only).

## 2026-11-18 — a `quality-report.toml` pattern row with `max` fails the lint gates (CON245)

- A `kind = "pattern"` row was counted and reported only, so an AGENTS.md rule that is one pattern held by habit.
  `verify_pattern_limits.py` fails when a row with `max` matches more often and prints `file:line` of each match;
  `run-lint-gates.sh` runs it as its ninth gate. A `max` that is no whole number of zero or more fails too.
  See [pattern limits](docs/code-quality-tooling.md#pattern-limits-pattern-limits).
- The two sampled consumer rules bind: OxidANT `ef2cad1` (no `[features]` table) and
  AccelerANTgine `bee101b` (no direct stdout diagnostic in `Src/`), each with a row, a planted-tree test and a recipe.

## 2026-11-18 — a workspace Cargo license is staged under its file name alone

- `stage-cargo-licenses.py` copied a `workspace` policy text to `<name@version>/workspace/<its repo path>`.
  OxidANT's `profiling` texts sit at `packaging/licenses/cargo/aclysma-profiling-8271551172eb/`, which put
  BeschleunigerBallett's NSIS source path at 268 characters and stopped makensis on Windows. The text now lands
  at `<name@version>/workspace/<file name>`; two workspace texts of one package with the same name fail.

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

## 2026-11-18 — pytest-timeout in the arm64 wheel store (CON238, step 2, in source)

- The `:winarm64` wheel store's pinned pytest stack gains pytest-timeout 2.4.0 (`PYTEST_WINDOWS_ARM64_PYTEST_TIMEOUT_*`,
  the version OrchestrANT's lock runs on x64, PyPI's SHA256). `Copy-Arm64TorchWheels.ps1` stores it and
  `Test-Arm64Bundle.ps1` installs and imports it offline, so a consumer's pytest timeout works on the device. A
  `:winarm64` publish carries it.

## 2026-11-18 — the patch-drift gate tells a vanished upstream from a drifted patch (CON280)

- `Test-PatchesApplyClean.ps1`: when a clone fails and the upstream page answers 404, the patch is `NOT CHECKED
  (upstream answers 404)` and the job prints a warning naming the repos, instead of failing; a reachable upstream
  that refuses the clone, and every patch that does not apply, still fail. Since 2026-11-17 22:20Z
  `github.com/microsoft/onnxruntime` answers 404, which turned every hub commit's Windows lane red (owner decision
  2026-11-18). `Patches.ApplyClean.Tests.ps1` covers both cases.

## 2026-11-18 — the pre-commit mutation sample runs in the image on a host without pwsh (CON279)

- The hook's sampled `verify_mutations.py` run is teed; when it fails because the host lacks the `pwsh` or
  `bash` a mutant is parsed with, and `git config kataglyphis.imageRunner` names a runner, the same sample runs
  once more through it and that run decides, as pre-push does since CON277. `test-precommit-hook.sh` covers
  the runner's pass and fail, a clone without it and a real survivor.

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
  in [`adopting-in-a-new-project.md` § The git hooks, by reference](docs/adopting-in-a-new-project.md#the-git-hooks-by-reference).
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

## 2026-11-12 — set the amd64 baseline to x86-64-v3 (not built yet)

- Owner decision CON264: the amd64 GCC is configured `--with-arch=x86-64-v3 --with-tune=generic`
  on the native, cross and Canadian paths; OpenCV asks for `CPU_BASELINE=AVX2` and its configure
  fails without it. No chain has run with it: the published images are unchanged.
- New gates: a critical-fix pin, the configure-line cases in `test-native-gcc-multiarch.sh`,
  `check_amd64_isa` in the runtime smoke (`test-amd64-isa-gate.sh`) and an entrypoint check that
  refuses a CPU below the baseline (`test-cpu-baseline-check.sh`), each with mutation recipes. Not
  covered: clang, Rust, Windows x64 and each shipped ELF.
  [`amd64-x86-64-v3-baseline.md`](docs/amd64-x86-64-v3-baseline.md).

## 2026-11-12 — add Intel's free GPU user space to the amd64 package stage (not built yet)

- Owner decisions CON258 and CON259: `setup-package-image.sh` installs `intel-media-va-driver`,
  `libmfx-gen1.2` and `intel-opencl-icd` on amd64, in every variant; never the multiverse
  `-non-free` driver. FFmpeg gets `--enable-libvpl` on amd64 behind its own configure check.
  `check_intel_gpu_userspace` fails an amd64 image without the driver files or the `h264_qsv`
  encoder. Nothing has run on an Intel GPU.
- The riscv64 and amd64 ISA gates now live in `06-packaging/check-arch-isa.sh` and share one
  verdict renderer and one arch guard in `smoke-common.sh`; `smoke-runtime-image.sh` only wires them.
  [`linux-accelerator-images.md`](docs/linux-accelerator-images.md#intel-gpu-user-space).

## 2026-11-12 — the profile check knows the plugin MIGraphX EP by its name; BACKLOG CON234 to CON256

- `shared/python/verify_ort_profile.py --device migraphx` requires nodes of the provider `MIGraphX`. AMD's plugin
  reports the name it is registered under, the contract fixes `MIGraphX`, and the check still expected the removed
  in-tree `MIGraphXExecutionProvider`, so no consumer package could have passed a profile check on the plugin
  (owner, 2026-11-12: the family's name is `MIGraphX`). A test holds that the old name no longer passes, and
  recipe `packaging.ort-profile-migraphx-plugin-name` holds the mapping. Not run against a profile from a card.
- `docs/consumer-image-contract.md` names the Rust call that exists, `Environment::register_ep_library`
  (`ort` 2.0.0-rc.13 has no `register_execution_provider_library`), gives Rust its second step, and says what was
  read in AMD's source: one device, the option `device_id`, and an unknown option fails the session.
- `BACKLOG.md`: CON234 to CON253 from the audit of the four consumers, CON254 (`New-PortableBundle` leaks its package
  check's output), CON255 (one failed download fails the benchmark-history step) and CON256 (what the consumers'
  move onto the plugin left open on the hub side). CON231's step 2 names the order and the name the owner chose.

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

## 2026-11-10 — preserve MIGraphX node and registry ownership

- The pinned plugin's C ABI node pointer now reaches an owning virtual base at release; both ordinary and cached nodes retain correct pointer adjustment in all six callbacks.
- Seven compiled ASan cases cover both node types and callbacks, registry lifetime, failed creation/retry, twelve concurrent callers and stale-patch refusal. Original type-mismatch and registry-leak controls must fail.
- The factory now owns its cached kernel registry and serializes initialization; release precedes data-transfer destruction. The source phase stops on either ownership-patch failure before seeding.
- Existing images retain their old module until rebuilt; standalone module, full consumer and package acceptance remain separately required.

## 2026-11-10 — share native ORT plugin registration policy

- `shared/native/ort_plugin_eps.hpp` registers through the supplied owning C API/environment,
  caches only successful calls, refuses name/path conflicts and selects fresh V2 devices while
  retaining provider options and native failure text. Callers share its registry for that environment's lifetime.
- The exact native asset and compiled fake-callback suite cover path precedence, retries, separate
  environments, concurrency and status cleanup, with a mandatory failing assertion control.
  Real SDK object compilation checks API shape; consumer builds, packages and hardware profiles remain separate.

## 2026-11-10 — share Python ORT plugin registration and device selection

- `shared/python/ort_plugin_eps.py` resolves advertised plugin roots before a bundled fallback,
  caches only successful native registrations per owning binding, serializes concurrent callers
  and rejects a changed module behind an already registered name. Availability is enumerated fresh.
- The exact shared asset can live inside an installed consumer package; reports name only successful
  registrations. Fake-binding and shared-copy controls do not prove real ORT loading or GPU inference;
  consumer integration and hardware profiles remain required.
- Keep the canonical module compatible with strict consumer lint without adding suppressions.
  A delayed native-call mutation requires the shared lock. Python sessions attach devices through
  options and omit constructor provider overrides; registration itself needs GPU visibility.

## 2026-11-10 — keep compiler argument fixtures portable across temporary roots

- The optional compiler-tool fixture now normalizes probe filenames independently of `/tmp`,
  so ordinary pre-push checks also work under a task-owned `/var/tmp` root. A synthetic
  path containing spaces and its mutation preserve this without depending on the host layout.
- The two previously blocked ORT-cache mutations still test the same producer behavior;
  no cache policy, quality threshold or build behavior changes.

## 2026-11-10 — ship and check a native WebGPU C API registration probe

- CPU and NVIDIA build a versioned executable using their core's configured compiler, toolchain,
  flags and absolute C API header, with the shared compiler-cache resolver and configured-cache gate.
  Required-helper, configure, build or installation failures stop the producer before its receipt.
- Runtime checks every selected native core in its own process: legacy compiled WebGPU is refused,
  the CPU baseline is required, and environment registration needs the first unregister plus the exact
  missing-key control. Raw API errors and failed resource/loader cleanup cannot produce success.
- The native phase binds the core/probe bytes and source/mode before and after execution; the image
  smoke runs it alongside the separate GIL check. Fake-ABI executable tests and a compile against
  verified official headers do not complete actual ORT factories, target-image acceptance or inference.
- Callback fixtures retain absent, empty and existing cache-pin bindings; TensorRT's default case
  clears an inherited opt-out inside its child so image build flags cannot change the fixture's inputs.

## 2026-11-10 — check WebGPU factories in each delivered Python environment

- The runtime gate binds the imported native extension to one completed GIL/FT delivery, its actual
  source/mode and final manifest. Pending repairs, ambiguous prefixes and matching native cores without
  the matching Python bytes fail before any factory call.
- Enabled mode requires successful factory unregistration followed by ORT's precise missing-library
  control; disabled mode requires absence twice. The FT interpreter must keep the GIL disabled before
  and after import and execution. The GIL smoke and actual installed FT store invoke the shared gate.
- ONNX/GenAI probe transport moves into a shared companion without changing its failure policy, shrinking
  the runtime driver's frozen size. Stub-binding fixtures do not prove real ORT, native-core registration,
  adapter availability or inference; actual image and consumer acceptance remain open.

## 2026-11-10 — retain WebGPU product identity through wheel repair

- The existing ORT manifest check/follow transport now binds WebGPU build receipts before rewriting and
  records final wheel hashes only after source/mode, native core, manifest and wheelhouse checks agree.
  Original hashes and continuous checked delivery history remain preserved.
- The shared bounded ELF reader proves loaded code/data continuity, normalizing measured patchelf metadata
  relocation and dynamic symbol indices. Real stripping, RPATH and needed-library rewrites remain supported;
  foreign code/data, changed symbol names and section-only copies of the original data fail.
- The complete media finalization sequence moves into a preserved driver, shrinking the Dockerfile's
  frozen budget while retaining narrow mounts, phase ordering and native-fatal/cross-advisory install policy.
- Media and package closures carry the canonical build/ELF companions. Fingerprints do not prove loader
  metadata safety, actual factory registration or inference; the real media/acceptance and consumer matrix remains open.

## 2026-11-10 — bind WebGPU build modes to each native and Python product

- CPU and NVIDIA record native core/GIL bytes before free-threaded reconfiguration; the FT pass records
  its own wheel extension after the configured verdict and successful store. The preserved Python tool
  writes `ort-webgpu-build.json` with source identity, mode flags, configuration digest and product hashes.
- Missing/ambiguous/non-ELF products, duplicate or mistyped flags, another FT source/mode and changed
  earlier GIL products fail the build. Explicit no-wheel builds retain their native-only path; publication
  is atomic and failures stay fatal. Functional fixtures exercise both producer tails and the shared recorder.
- These records precede stripping/auditwheel repair. Checked delivery mappings and actual factory
  registration remain open, together with the media/acceptance matrix and CON231 consumer parity.

## 2026-11-10 — gate configured WebGPU modes on native and WASM builds

- CPU, NVIDIA and free-threaded ORT builds require the actual WebGPU/static-plugin/EP-adapter/Dawn flags;
  explicit native and cross opt-outs prove OFF. The free-threaded gate retains the original build failure
  before its verdict can run, and configured mismatches stop output collection.
- Both C++ WASM WebGPU flavors select `static_plugin` with integrated Dawn and check their configured
  flags under the existing optional/required failure policy. Shared completed assets move to `-wgpu3`
  so the new build cannot reuse legacy in-tree EP binaries from the old cache.
  The artifact-cache key also separates build configurations. One shared flavor driver retains each
  pass's argument order; shared CMake entry checks retain first-value launcher and strict Boolean policies.
- The full isolated c238a510 check found an embedded-Python resource warning and a noncanonical cache
  launcher environment call in the new OpenCV probe. Both are corrected without gate exceptions.
  Actual image/runtime registration and consumer parity proofs remain open under CON233/CON231.

## 2026-11-10 — repair classic FindCUDA cache wiring and prepare native WebGPU

- OpenCV's legacy CUDA rules use a preserved executable wrapper and the pinned CMake environment API;
  configuration fails when its cache or any generated CUDA object rule bypasses that wrapper. Toolkit-root
  invalidation, target compiler, architecture selection and explicit cache opt-outs remain intact.
- The reusable `probe-opencv-cuda-cache.sh` and its source fixture retain a private-cache cold/repeat proof.
  The real SBSA replay records twelve cold misses then twelve CUDA/device/PTX/CUBIN hits, zero repeat misses
  and no errors. One dependency-only `-M` scan and one outer nvcc driver remain explicitly uncached.
  This does not prove a full OpenCV rebuild, remote-cache reuse or GPU inference.
- Native ORT selects `--use_webgpu static_plugin` with external Dawn, including free-threaded replay.
  Its argument fixtures pass on amd64, arm64 and riscv64 with opt-outs retained; configured/runtime proof,
  the separate media chain and consumer acceptance remain open under CON233.

## 2026-11-10 — publish NVIDIA plugin images after amd64 and native arm64 acceptance

- Runtime run `20261110-013045-b0a6f8cb` completed from hub
  `9f4e6bd2c0d416057224c585d5a34b7abbdb813d` after both wrapper, content and
  runtime-image gates passed. The accepted index, now `:latest-nvidia`, is
  `sha256:d2df9e170fadc7f2abbc22e004b615a7f8a4f41ee9c810c4f06ad7229ecace70`;
  exact remote wrapper children are amd64
  `sha256:3b9cf1c6a211d5b6b9e317da4081e3510b963fd1fb94cd33326716b307b73268`
  and arm64 `sha256:33b92fa2e4e1f926fbdbd09e446ed4449f51b41376daf9ad2cf815c036565af7`.
- All six amd64 consumers passed in
  `logs/image-acceptance/20261110-013045-b0a6f8cb/receipt.json`; independent checks
  matched log/lock hashes, cleanup records and both wrapper children. The first ARM
  attempt failed GoogleTest discovery under QEMU at 05:58Z; its original failed receipt
  `logs/image-acceptance/20261110-013045-b0a6f8cb-arm64/receipt.json` stays preserved.
- Native ARM [run 42781812889, attempt 1](https://github.com/Kataglyphis/ANTfrastructure/actions/runs/42781812889/job/129713397881) passed the complete six-consumer
  contract on the same immutable image and frozen source snapshots, with every command,
  timeout and sanitizer policy retained. The original receipt is
  `logs/image-acceptance/20261110-013045-b0a6f8cb-arm64-native-42781812889-1/receipt.json`;
  SHA-256 `273d04ddb2ad00c0aeada936a969682cb85c14dcaaa002be5b520a08b6469359`. The downloaded artifact
  13747964666 matches `sha256:065c3aee5798015d690ff29cbe69215515a585c0af45ca690484bf90dc6ecf1d`.
  Actual logs prove 215 C++ tests with no skips, 875 Rust tests with none ignored/filtered,
  all Flutter consumers and the stable WebDavClient tests/benchmark; experimental Python
  and profiling retain the existing advisory policy. Every log/lock binding, twelve
  cleanup records and the successful empty remote engine query were checked.
- Canonical promotion completed at 2026-11-10T09:09:51Z; independent public readback binds the
  accepted index and both wrapper children while preserving amd64 and arm64.
- Added the opt-in native ARM CI lane and versioned proof configuration. Driver head
  `3cab7a83734b0aeb86600141149f1088f5697bf7` passed all five source CI workflows; its PR merge has the identical
  Git tree. Actual logs prove 550 suites / 31,339 assertions and all
  4,688 distinct mutations without omissions, duplicates, skips or delegation.
  The Windows archive digest, 3,027 passing tests and all 15 coverage floors were verified.
  The [proof guide](docs/image-acceptance.md#native-ci-proofs) retains original receipt bytes,
  maps downloaded logs and explains removing the start label before later PR updates.
- Cache documentation separates proved ORT CUDA subcommand hits from the uncached
  outer nvcc driver, OpenCV classic FindCUDA's direct nvcc route, non-x86 Torch's
  direct compiler selection and the shipped image's empty Rust wrapper. The latter
  was observed in the real amd64 Rust consumer; these findings do not establish
  whole-image cache coverage or a remote cache readback. Follow-up belongs to the
  next media work; [details](docs/build-cache-tiers.md#per-target-detail).
- Preserved all nine complete 2026-11-05 entries and their relative-link targets in
  the [dated archive](docs/changelog-archive-2026-11-05.md), registered in both docs
  indexes. No physical NVIDIA inference is established by these image/consumer checks.

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


## 2026-11-09 — repair Linux TensorRT cross builds and CUDA cache parsing

- NVIDIA ARM64 run `20261109-102131-e69f48d7` ended with exit 1 at 17:02:20Z.
  Both CUDA Python variants and QNN's module/export/HTP checks passed; TensorRT
  then configured nvcc with native g++ because CUDAHOSTCXX captured CXX before
  target setup. Select target CXX first and retain setup failures. The real old
  CMake/NVCC control fails; the fixed control compiles an AArch64 object with all
  five production GPU architectures.
- Native ldd returned 1 for the ARM module while the old closure gate passed.
  Closure checks now retain transport errors; TensorRT's SBSA check runs the
  target loader under bounded QEMU with explicit chain and target SDK paths.
  The complete isolated TensorRT build passes with both exports, five original
  licence texts and G2. Its repeat records 329 cache hits (317 C/C++, 12 CUDA
  subcompilations), zero misses/errors and one uncached internal compilation.
  This uses the target CPU ORT core; final GPU media/runtime and inference
  remain separate required proofs. The existing TensorRT-major mutation now
  targets the revised guard and tests a resolved closure linked to the wrong
  major, preserving its rejection independently of inspector failure.
- Linux ORT applies `003-cuda-standard-sccache.patch` through the existing patch
  driver to both CUDA source branches, then rejects partial or drifted options
  before configuration. Tarball/Git controls keep raw bytes and isolated newline policy.
  A private-cache NVCC replay reproduces `multiple input files` with the old
  separated option; the joined option yields 12 repeat hits across CUDA,
  device code, PTX and CUBIN, zero cache errors and one uncached internal step.
  The new guards have 17 biting mutations; no full CUDA-core or remote-cache
  repeat, final image or consumer receipt is inferred from these controls.

## 2026-11-09 — keep TensorRT protobuf C++ flags out of rc.exe

- The TensorRT plugin build now scopes protobuf 21.12's compiler options to
  C/C++ before configuration. This keeps `/bigobj` and other compiler flags out
  of `rc.exe` and its `cmcldeps` preprocessor without dropping C/C++ options or
  the resource. Regression controls cover drift, missing inputs, idempotence and
  unconditional ordering; native compilation remains a separate chain result.
  Mixed already-scoped blocks now reject appended bare, quoted or unknown
  arguments, and unknown original options fail before rewriting input bytes.
  The real protobuf warning block exposed closing parentheses inside comments
  that truncated the old matcher. Comments are now preserved as text, and all
  result checks run before writing. LF/CRLF, commented-command and atomic
  refusal controls pass; all twelve affected patch mutations bite. File-byte
  assertions share `Assert-FileUnchanged`, with separate callback, changed-byte
  and literal-path fault controls. The actual pinned
  input and native RC/C++ before/after controls pass; full plugin acceptance
  remains separate. ROCm guidance also reflects independent NVIDIA tags and
  supported-base GPU limits instead of treating old build skew as current.
- Shared Windows plugin C++ flags retain `/EHsc`. Replacing the CMake flag
  string had dropped the platform exception default and made TensorRT plugin
  sources fail with `cannot use throw with exceptions disabled`. The policy
  keeps the ORT C++ API's throwing semantics and existing warning flags.
  A later full lane and GPU execution remain separate acceptance requirements.
- ONNX CUDA generator options now use `SHELL:-std=c++20` in both branches.
  The separated long option made the pinned cache parser reject all 605 CUDA
  commands in the measured run. A replay of the actual argument policy keeps
  every warning and all five GPU targets, reproduces that refusal and then
  records CUDA, PTX, CUBIN and device-code hits with the joined option. This
  local one-kernel control does not replace the full plugin/remote repeat.
  The later whole-plugin pass at `6737933a` records real CUDA/CUBIN hits and
  zero rejected cache calls; its product run then stops at the protobuf
  comment defect above. This supplies no final image or forced-repeat receipt.
  Source fixtures check both branches, exact tokens, atomic drift refusal and
  preserved line endings; all four new mutations bite. File I/O uses the
  canonical patch API, and source fixtures share the harness regex counter
  and directory staging instead of copying those operations.
  Git Bash gate instructions require native symlinks; default file copies
  fail the unchanged QNN fixture instead of proving its library links.
  Structural tests share unconditional-call and source-order assertions in the
  harness, preserving the IREE scratch lifecycle checks without copied logic.
  The existing harness byte-verdict mutation now uses a shell-neutral Python
  subprocess transport while retaining all 45 required results and failure checks.
  The three lifted-fixture recipes use the same portable transport and retain
  their original minimum, equal passed/total, and empty failure/skip requirements.
  Four older cache, text, pip and QNN mutations call the result-writing runner
  directly, avoiding Unix-only directory setup before a native Windows test.

## 2026-11-09 — verify acceptance cleanup and publish the plugin-only ROCm wrapper

- Acceptance checks each consumer and ownership-helper container through a successful engine query
  after removal. A remaining exact name or failed query refuses a passed receipt. Already-auto-removed
  containers remain idempotent; logs retain both raw command statuses and diagnostics. Ownership
  restoration still runs after consumer-removal failure, and original consumer statuses remain intact.
  The offline suite passes 29 tests and all 11 new mutations bite; no host-process or GPU proof is added.
- ROCm runtime run `20261109-081137-973f29cc` from clean hub
  `7f97f31c122241a6eea8ba62229bbbc56c00444c` completed with amd64 wrapper
  `sha256:e9fc824e6129670a06a4e81980676e4d7a1effb3013726f844cd12d5d097c55f` and index
  `sha256:4e76aa2a75e104570794be965034bcc3276bb5ba78c98ab863659ed6630ca8de`.
  All six default consumers passed on `linux/amd64`; the exact receipt is
  `logs/image-acceptance/20261109-081137-973f29cc/receipt.json`. Every recorded log hash matches,
  and an independent post-run engine query confirms all of this run's named containers absent.
  The accepted index was promoted to `:latest-rocm` with its runtime platform preserved. This run
  preceded the stricter removal helper above; it proves the plugin-only image, not fresh GPU inference.
- NVIDIA ARM64 media/android recovery run `20261109-102131-e69f48d7` started from fully proved
  `bf4c7d47` after ROCm actually ended. Main remains frozen during that chain; the additional
  acceptance fix is isolated in the worktree and requires its own complete source preflight.

## 2026-11-09 — retry QNN configuration without losing raw failures or diagnostics

- NVIDIA ARM64 media run `20261109-002505-d3b3c0b7` reached QNN configuration after the CUDA
  build, then GitHub returned HTTP 504 for the fork's pinned protoc archive. Its QAIRT SDK hash
  check passed. The failed shared RUN produced no final media image, wrapper or consumer receipt.
  NVIDIA amd64 media/android had already passed in run `20261108-180128-c3904567`.
- QNN configuration now uses the existing three-attempt retry with ten-second delays, retains all
  stdout/stderr in `build.log` and returns the last raw failure after exhaustion. Compilation stays
  outside the retry. The 100-assertion offline QNN suite and eight biting mutations prove transport,
  limits, logs and failure propagation; an actual corrected rebuild and acceptance remain pending.
  Its fake build driver is a tracked Bash fixture, carried into mutation mirrors and checked as shell.
  [Failure and scope](docs/failure-modes.md#qnn-configure-loses-a-completed-cuda-build-to-a-transient-protoc-download).

## 2026-11-09 — keep perf transport and interrupted proof records accurate

- The first full preflight of the permanent runner reached the complete script suite, where the
  perf-report fake engine misread the required nerdctl AppArmor option as its image. The fixture
  now consumes that option pair; production security, uid assertions and grading checks remain.
  A mutation removes this parsing to prove the existing perf-report tests fail. The failed full
  run and its partial mutation results remain preserved; they are not a complete preflight proof.
- Interrupted isolated preflights leave an unobserved command exit null and record the interruption
  exit separately, while still cleaning only their own containers. A transport fixture proves the
  raw interruption, failed verdict and restored report mode without starting a real container.

## 2026-11-09 — preserve recurring proof tools and isolate mutation startup caches

- Regular isolated-preflight, unit-monitoring and native-plugin drivers now live in the repo,
  with retained source snapshots and run inputs under `logs/`. Existing scratch drivers were
  archived with their paths and hashes. The preflight runner binds frozen source read-only,
  removes only its own containers and retains raw failure and cleanup evidence. Observer timeouts
  leave builds running. Native probes reuse the production loader and preserve its extracted body;
  a real TensorRT probe passed loading and both exports, without registration or inference.
- Consumer acceptance can materialize a no-replace platform plan while retaining the entire
  validated consumer contract. Plan creation alone proves no consumer execution.
- Full local preflight at `0f77ee06` passed the other 41 jobs and 545 script suites, but failed two
  mutation baselines after one PowerShell startup abort: 4597/4599 mutations were proved. Unix
  mutation commands now get private XDG caches until child reaping, matching the upstream shared
  startup-profile failure. The failed run remains failed; a new full proof is still required.
  Regression fixtures and mutations cover cache lifetime and the new operational refusal paths.

## 2026-11-09 — record Windows cache evidence and accepted ARM64 publication

- The resource guide now describes the pinned hub sccache binary and its source,
  patch and checksum path, replacing stale instructions for upstream 0.18.0.
  The #2862 report remains open; #2809 merged on 2026-11-02. Per-stage gaps and
  the missing CUDA-plugin repeat measurement stay open in CON229.
- GPU notes distinguish the earlier AMD reference-host result from the native
  RTX 2080 driver probe of 2026-11-08. Driver discovery, container file checks and
  actual plugin inference retain separate evidence requirements.
  They also retain Microsoft's supported-base requirement: Server Core and Nano
  Server are excluded, and matching host/image builds alone cannot prove GPU
  support or execution.
- The dated ARM64 media/cache result records the initial disk refusal and the
  successful full retry after selected cleanup: 152 smoke assertions, zero
  failures, 17 cross-lane skips and a passing publish gate at `7c575e34`.
  Its subsequent candidate device run 42579941215 passed 22/22, including real ONNX
  frames and the cp315t IREE twin. The owner-approved `:winarm64` tag now points to
  `sha256:9ee61e2f49b5e59624d4ed4a4de3ec86c985f9f71567d175b5e320d85bbac137`,
  preserving its runtime platform; the cross-build guide records the receipt.
  The normal public-tag follow-up run 42583681115 also passed 22/22.
  CUDA-plugin cache and GPU execution measurements remain separate requirements.
- The NVIDIA patched-LLVM RUN records 4,233 compiler requests and WebDAV hits,
  without misses or cache errors. This is compiler-cache coverage for that stage;
  CUDA-plugin initial/repeat and hardware inference remain open.

## 2026-11-08 — runner-default fixtures isolate the outer worker cap

- The full local mutation run exposed `ordered-jobs.default-one-per-cpu` surviving when the outer
  preflight exported `RUN_TESTS_JOBS=4`. The copied runner fixture now clears that inherited value
  before applying explicit case arguments; serial and invalid inherited caps exercise its default.
  The existing default mutation and a new fixture-isolation mutation prove the rendezvous controls.
  These fixtures check scheduling and verdicts, not the coverage of the suites they invoke.

## 2026-11-08 — wheelhouse receipt probes keep their recorded diagnostic locale

- A full Linux preflight under `LC_ALL=C` exposed locale-dependent GNU find quotes in the wheelhouse
  failure fixture. Its child probes now use `C.UTF-8` and compare the original receipts under both parent
  locales. The original bytes and statuses stay checked; `lib.wheelhouse-receipt-locale` restores inherited
  locale selection to prove the regression. These are offline fixture checks, with no wheel or image build.

## 2026-11-08 — accept a Windows ARM64 image by digest before changing its tag

- The ARM64 workflow accepts an optional lowercase SHA256 digest. Both container
  actions use the same image, while default runs keep the shared image selector.
  Export records the actual image/config/revision, ZIP hash and CI source/run/attempt;
  the device checks that binding before its full existing gate and uploads a
  passed or failed receipt with the raw status. Manual runs have isolated concurrency.
  Fourteen mutations cover input, platform, identity, byte and status refusals plus
  actual workflow/module transport. Fixtures do not authenticate receipts or prove
  hardware execution. No image tag is promoted by this workflow.
- Device run42525202720 at cb2b8db6 now passes onnxinference:21/22 device steps pass;
  only the older published IREE free-threaded twin still fails. Image acceptance
  and the new workflow's CI remain separate required evidence.
- Windows run42525202620 exposed a cold module-call failure (#250): the export's
  required import loop omitted filename suffixes, so the existing closure scan
  could not discover OrtPayload. The loop now lists concrete module filenames;
  the same complete cold suite fails before and passes after the correction.
  Failure details remain on one line so the CI report retains the missing names.

## 2026-11-08 — the ARM64 export carries app-local chain ORT DLLs

- Device run42521429496 at d63c982d reached the real ONNX frame probe but loaded
  ORT1.17.1/API17 while gstonnx requested API31, then crashed with 0xC0000005.
  The ZIP now carries the chain core, provider bridge and DirectML beside its
  executables, ahead of the client's System32 lookup. A small temporary overlay
  preserves the image tree; duplicate archive paths fail. Native ZIP/hash tests
  fail before the fix, portable PE staging covers both architectures, and two
  mutations prove omission and duplicate-path refusal. Device execution remains
  pending; this does not accept the older published IREE twin or prove GPU use.

## 2026-11-08 — the ARM64 device-gate export carries the GStreamer module's shared sibling

- The ARM64 device job in run 42489063718 could not reach its WebRTC and ONNX frame probes: the
  exported GStreamer module required `WindowsScripts.Shared.psm1`, but the export omitted it.
  The export now carries that sibling; tests check all exported module hashes and import
  the exported GStreamer module in a fresh child session. The regression fails before the fix,
  and `lib.arm64-export-shared-module` removes the sibling to prove the guard through a
  host-portable copy-loop suite; native ZIP tests remain in the Windows suite. Device execution
  and the previously reported ONNX crash still require a passing ARM64 device run.

## 2026-11-08 — the IREE cross twin gives nanobind its ABI through SKBUILD_SOABI

- The arm64 chain at 2ef097ca stopped in media-tvm on `IREE twin: build.ninja builds no nanobind-static-*-ft library`.
  The gate was right: CMake 4.4.5's cross FindPython queries no interpreter and sets `Python_SOABI` to an empty normal
  variable, which hides the `-DPython_SOABI` cache value the first fix passed. The twin now passes `SKBUILD_SOABI`, which
  nanobind 2.9.0 reads first; a two-pass configure with 4.4.5's FindPython gives `NB_ABI=cp315t-win_arm64`
  (`lib.iree-twin-cross-soabi` now puts the dead spelling back).

## 2026-11-08 — the Windows plugin EP builders share their steps; develop's gates green again

- b89caee3 turned five hub gates red: code duplication (eight pairs), comment size, PowerShell complexity
  (`Get-MediaBranchVersionArg` at 86 lines), the version snapshot's pinned builder count and, through them, a mutation
  shard. The QNN and TensorRT builders now share `Save-VerifiedSourceArchive`, `Get-OrtChainPrefixFile`,
  `Get-OrtPluginEpCmakeArgs`, `Invoke-CmakeConfigureLogged` and `Install-NativeFileStage`; the four CMake G2 consumers pass
  `Assert-ChainOrtOnly -CmakeBuildDir`; media-core's pins are a key list; the suites share `Import-TestRepoModule`,
  `Invoke-TestPluginStage` and `New-TestOrtChainPrefix`. No allowance was added, and the Test-Container/Install-Cuda row
  left `code-dupes.allow` as it fell under the threshold.
- G2 reads a plugin EP's own `onnxruntime_ep_*` binaries and its `Microsoft.ML.OnnxRuntime.EP.*` C# package as a
  consumer's, as the Linux gate does, so the TensorRT plugin's gate can pass (`lib.g2-plugin-ep-*`).

## 2026-11-08 — the plugin EP stages create their directory

- The third arm64 chain stopped in the QNN plugin's staging with `Could not find a part of the path
  'C:\runtime\lib\onnxruntime-ep-qnn\bin'`: `Reset-SourceBuildDirectory` removes the directory, so the next
  `Copy-Item` wrote the DLL as a file under the directory's name. Both plugin builders (QNN, TensorRT) recreate it
  first; install tests over a stale tree and `lib.qnn-ep-stage-dir` / `lib.trt-ep-stage-dir` hold it.

## 2026-11-08 — `:latest` ships Qualcomm's plugin QNN EP on arm64 (CON232 proved)

- The seventh proof chain (runtime stage, three arches, run 20261108-131033) published `:latest` with arm64 at
  `sha256:19b99d3f4d02…`: the plugin module, 48 QAIRT backends, `ORT_QNN_EP_ROOT`, no in-tree QNN provider, all smokes
  and the acceptance receipt green. That receipt covers the six `linux/amd64` consumers; it does not claim
  arm64 or riscv64 consumer runs. The sixth chain had failed only on GitHub's 503 for the HailoRT tarball, now mirrored.

## 2026-11-08 — Linux: the CUDA EP is the plugin, the TensorRT EP NVIDIA's plugin, the in-tree TensorRT and MIGraphX EPs are gone (CON233, CON231 step 3)

- Owner decision (second of the day): "sofort komplett, inklusive Entfernen" on both lanes. The nvidia ORT GPU build
  passes `onnxruntime_BUILD_CUDA_EP_AS_PLUGIN=ON` and no `--use_tensorrt`; `assert_onnx_cuda_plugin_ep` fails a module
  that still exports `GetProvider` (the in-tree module exports the two plugin entry points too, so only the bridge
  tells) or an in-tree TensorRT EP beside it, the GPU verify stage repeats both, and the
  runtime smoke's `gpu_cuda_plugin_verdict` also wants `cuda-plugin-ep=1` in the venv wheel's build info.
- `37-build-tensorrt-plugin-ep.sh` builds NVIDIA's plugin TensorRT EP at `ORT_TENSORRT_EP_COMMIT` with its four git
  dependencies seeded from pinned release archives (`ORT_TENSORRT_EP_{PROTOBUF,ONNX,GSL,FLATBUFFERS}_*`), an `ORT_HOME`
  shim over the chain GPU prefix and a `TENSORRT_HOME` tree over the apt runtime; it ships at
  `/usr/local/lib/onnxruntime-ep-tensorrt` with `ORT_TENSORRT_EP_ROOT`, G2-stamped, in the census contract, verified by
  its media stage and by `gpu_tensorrt_plugin_verdict`. Four in-image runs found and fixed: the seed gate lower-cased the
  repository too, `grep -q` on a 4000-symbol module killed `readelf` under `pipefail`, G2 read the module and its C#
  package as ORT, and a bare verify call had no `TENSORRT_VERSION`.
- The rocm variant: `30-build-native-amd.sh`, `--use_migraphx`, the `onnxruntime-migraphx` wheel and patches 003/004 are
  gone; the plugin MIGraphX EP builds over the CPU prefix, the wrapper takes the CPU `onnxruntime` wheel, and an image
  with `libonnxruntime_providers_migraphx.so` fails its runtime smoke.
- Packaging: `stage_ort_runtime amd` stages the plugin module from `ORT_AMDGPU_EP_ROOT`; Python AMD bundles copy it beside
  the chain core, prove it against the image's copy and require `MIGraphX` in the self-test's `registered_plugin_eps`
  (`--require-registered-plugin`); the venv TensorRT provider and its optional host imports are gone
  (`# PYTHON_APP_PLUGIN_EP_API=1` replaces the TensorRT marker; `python-ci-linux.yml` checks it and passes `MIGraphX`).
- Suites: `test-tensorrt-plugin-ep.sh` (new), and the GPU runtime, G2, census, bundle, AppImage, package and self-test
  suites moved with the code; 29 recipes in the `onnx-ep-tensorrt`, `gpu-runtime`, `provenance` and `packaging` families.
- Align the ROCm overview, wheel selection and MIGraphX prefix lookup with the plugin-only CPU-prefix build; remove
  the obsolete native AMD entry point and wheel from the setup instructions.
- Replace the app-venv's stale in-tree MIGraphX/TensorRT availability assertions with native plugin loading and
  both factory exports, while retaining the ORT Python import and Torch HIP/CUDA checks. The new fixture suite covers missing modules,
  exports and roots, both selected call sites and the CPU path; GPU registration and inference remain separate.
- ROCm proof run `20261108-161535-562db2ce` (`rebuild-sequence-36`) passed media and android but stopped at that
  stale app-venv assertion. No fresh runtime wrapper or acceptance receipt was produced; the successful package
  smoke alone does not prove the wrapper or the removal from the shipped image.

## 2026-11-08 — Windows nvidia: the CUDA and TensorRT EPs are plugins (CON233)

- Owner: "Windows sofort komplett". The nvidia lane builds CUDA as ORT's plugin
  (`onnxruntime_BUILD_CUDA_EP_AS_PLUGIN`, same DLL and EP name) and no in-tree TensorRT EP. Patch 008 keys the plugin
  CMake's force-includes on the MSVC frontend variant, so clang-cl gets `/FI`; the in-tree CUDA CMake and its PCH patch 002
  are gone. `Assert-OrtCudaPluginEp` fails a staged DLL that still exports the provider bridge's `GetProvider`.
- `Build-OrtTensorRtEpFromSource.ps1` builds `onnxruntime/onnxruntime-ep-tensorrt` at `ORT_TENSORRT_EP_COMMIT` in the ORT
  RUN (amd64): an `ORT_HOME` shim over the chain, its protobuf, onnx, GSL and flatbuffers as SHA256-pinned seeds
  (`ORT_TENSORRT_EP_*`), downloads disconnected, a G2 stamp as consumer `tensorrt-ep`, licence texts and provenance in
  `C:\runtime\lib\onnxruntime-ep-tensorrt` (`ORT_TENSORRT_EP_ROOT`). `Get-SevenZipSkippedLink` moved beside
  `Expand-SourceTarball` so both plugin builders share it.
- The smoke grades both plugins by their file contract (`Get-OrtNvidiaPluginFinding`, the shared
  `Get-OrtPluginEpExportGap`) and the build info (`cuda-plugin-ep=1`); registration runs only where `nvcuda.dll` loads.
  `SourceBuild.OrtTensorRtEp.Tests.ps1` and 20 new mutation recipes (`lib.trt-ep-*`, `lib.ort-cuda-plugin-*`,
  `lib.nvidia-smoke-*`, `lib.plugin-ep-export-gap-bridge`) hold it. Not proven yet: an nvidia chain build, and registration or inference on an NVIDIA host.

## 2026-11-08 — the QNN plugin EP stages its link output

- The second arm64 chain compiled the QNN plugin and stopped in its staging: the fork's POST_BUILD copies
  `onnxruntime_providers_qnn.dll` into its wheel tree, so a recursive search found two. `Get-OrtQnnEpBuiltDll` takes the
  link output at the build root (`lib.qnn-ep-link-output`).

## 2026-11-08 — the QNN plugin EP compiles under clang-cl

- The first arm64 chain with the QNN plugin stopped in its compile: the fork passes ORT's MSVC-only
  `/experimental:external` under warnings-as-errors. `Update-NinjaFile -OrtMsvcOnlyFlags` now owns ORT's three MSVC-only
  strip patterns, and both the ORT build and the fork run it after configure (`lib.qnn-ep-ninja-msvc-only`,
  `lib.ninja-msvc-only-wx`).

## 2026-11-08 — every ORT EP with a plugin moves to it, consumers first (owner directive)

- Owner decision: every ONNX Runtime EP that has a plugin moves to the plugin system on both lanes, at its newest
  version, and the in-tree paths go. Order: plugins that need no consumer change first, then one registration helper
  per language and every consumer (CON231 step 2), then the CUDA switch and the in-tree TensorRT/MIGraphX removals.
  The evidence and links: `logs/reports/` of the 2026-11-08 deep research, summarised in BACKLOG CON233.
- Windows rocm: the WebGPU EP is the plugin code linked into `onnxruntime.dll` (`onnxruntime_USE_EP_API_ADAPTERS` and
  `onnxruntime_WEBGPU_STATIC_PLUGIN`, ORT 1.31), still registered as `WebGpuExecutionProvider` with no consumer call.
  The configure gate fails a build without both switches; `Ort.WebGpuStaticPlugin.Tests.ps1` holds it on both hosts.
- `ORT_TENSORRT_EP_COMMIT` / `ORT_TENSORRT_EP_SOURCE_SHA256` pin onnxruntime/onnxruntime-ep-tensorrt at its newest commit
  (6403f3c; the repo has no release yet) for the TensorRT plugin, built beside the in-tree EP on the nvidia lanes.

## 2026-11-08 — the ARM64 device gate's two red steps (issue 236)

- IREE's cross `cp3XYt` twin re-enabled the GIL on the device (`first by iree._runtime_libs._runtime`):
  FindPython runs no interpreter on the cross lane, `Python_SOABI` stayed empty, and nanobind configured
  without free-threading. The twin passes `Python_SOABI=cp3XYt-<tag>` (`Get-IreeTwinSoabi`) and
  `Assert-IreeTwinFreeThreadedNanobind` fails a configure without a `nanobind-static-*-ft` library.
- `onnxinference` exits `0xC0000005` on the device, and the gate lost the output to PowerShell's native-exit
  error. `Assert-GstOnnxInferenceRun` keeps it and bisects a failure (frames alone, `ORC_CODE=backup`,
  `GST_DEBUG=onnx*:6`), restoring the environment after each probe. The crash itself stays open until a device run.
- `SourceBuild.IreeTwin.Tests.ps1` and `Gst.OnnxInferenceRun.Tests.ps1` gain the cases, with five new recipes
  ([failure-modes.md](docs/failure-modes.md#the-gil-was-re-enabled-first-by-iree_runtime_libs_runtime-on-an-arm64-device)).

## 2026-11-08 — Windows builds the QNN plugin EP in the ORT RUN (CON232)

- Windows amd64 and arm64 build Qualcomm's plugin EP from the pinned fork, as the `QNN plugin EP` stage of the ORT
  RUN (`Build-OrtQnnEpFromSource.ps1`). `-Donnxruntime_ORT_HOME` points at a shim holding the chain's
  `onnxruntime.dll/.lib` and `onnxruntime_providers_shared.dll/.lib`; the fork's `ort_core` headers are copied
  flat into it after configure. The build fails on an ORT core in its tree that is not the chain's bytes, and on a
  module without `CreateEpFactories`/`ReleaseEpFactory` or with an import outside the chain, QAIRT and the OS.
- `C:\runtime\lib\onnxruntime-ep-qnn` holds the DLL, the QAIRT backends, both licence sets and a provenance
  manifest; `ORT_QNN_EP_ROOT` names it. ORT and GenAI lose the in-tree EP and its staged QAIRT DLLs, and
  `Resolve-QnnSdk` no longer returns CMake switches.
- The ORT census counts the fork tree as a chain root and the plugin directory as a chain reference; the smoke
  gate checks the file contract (`Get-OrtQnnPluginFinding`). `SourceBuild.OrtQnnEp.Tests.ps1` and seven
  `lib.qnn-*` mutations hold it ([windows-cross-builds.md](docs/windows-cross-builds.md#the-qnn-plugin-ep)).

## 2026-11-08 — the QNN EP is Qualcomm's plugin EP (CON232)

- Owner decision: the QNN execution provider moves to Qualcomm's plugin EP on both lanes. Linux arm64 builds
  [onnxruntime/onnxruntime-qnn](https://github.com/onnxruntime/onnxruntime-qnn) v2.7.0 from its pinned tag
  tarball (`ORT_QNN_EP_VERSION`, `ORT_QNN_EP_SOURCE_SHA256`) in the media stage's accelerator RUN
  (`36-build-qnn-plugin-ep.sh`): the fork's `build.py` with `--ort_home` over a shim of the chain prefix, so it
  builds no ORT core and links nothing but the chain's library (it compiles against its own `ort_core` headers); the module lands in `/usr/local/lib/onnxruntime-ep-qnn` with
  the QAIRT backends, licences and provenance beside it, and `ORT_QNN_EP_ROOT` names it on arm64 only. The in-tree
  QNN EP leaves the ORT CPU build and GenAI's staging; `verify-media-artifacts.sh` fails a provider in the CPU prefix
  and checks the plugin tree on arm64; the plugin root is a census REF (a chain root, not a G2 consumer, since its
  source is an ORT fork); the wrapper's runtime probe judges root, exports and backends per arch. Pins, SBOM row,
  suite (`test-qnn-plugin-ep.sh`), seven recipes and the pages ([qnn-linux.md](docs/qnn-linux.md#the-plugin-ep),
  [contract](docs/consumer-image-contract.md#qualcomms-plugin-qnn-ep),
  [single-source rule](docs/onnxruntime-single-source.md#a-plugin-ep-built-from-an-ort-fork-is-a-chain-root)).
  Proof in the image follows with the next default chain; Windows arm64 follows in the Windows lane.

## 2026-11-07 — the TensorRT EP smoke check passes a complete runtime

- The first nvidia chain with TensorRT staged failed its smoke gate on
  `ORT TensorRT EP finds every TensorRT DLL it loads ... missing from the shipped TensorRT runtime:`, naming
  nothing. `Get-TensorRtEpGap` had found no gap; its empty result, assigned through `if`/`else`, bound
  `Assert-Test -Finding` as `$null`, which `@()` counts as one finding. `Assert-Test` now treats a `$null`
  finding list as empty, and `Test-Container.ps1` wraps the gap in `@()`. A Smoke.FindingVerdict case and the
  `lib.smoke-finding-empty-if-result` mutation hold it
  ([failure-modes.md](docs/failure-modes.md#a-smoke-check-fails-and-names-no-finding)).
## 2026-11-07 — `:latest-rocm` ships AMD's plugin MIGraphX EP (CON231, step 1)

- CON153 is proved inside a RUN: the fourth rocm proof chain's media stage logged `asset-mirror| hit` for all ten
  plugin-EP archives that `fill-asset-mirror.sh --apply` had mirrored from the previous run's misses. The entry
  shrinks to its leftover, a chain-start line that says when the secret is absent.
- `:latest-rocm` ships the plugin since 2026-11-08 01:25 UTC (wrapper `sha256:796e6abed4d3…`): the sixth proof chain
  passed every gate, failed only the acceptance step on a dirty hub tree, and the manifest-only replay accepted and
  promoted the pushed candidate (six consumer checks passed).
- The proof chains found six gaps in the first integration, each now held by a suite case and a recipe:
  the seed reads ran under the media scripts' `IFS` and fetched `'' ''` (shell safety class 3); the export
  check missed the version script's `CreateEpFactories@@VERS_1.0`; and the media merge stage never COPYed
  the plugin tree, so the pinned media image lacked it while every in-branch gate was green; and the seed loop
  reused the source's `sha`, so `provenance.txt` named abseil's hash (the `:latest-rocm` of 2026-11-07 carries
  that line until its next publish); and the module reached the wrapper without a chain-only ORT gate (G2) or a census
  entry, so SHIPPED-TRUTH E stopped the fourth chain with `UNREGISTERED`, as designed. The build now ends in
  `ort_assert_chain_only amdgpu-ep` over its work tree, records and configure log, the census contract names the
  module and its stamp, and `F11_GATE_CALLS` holds the call; and the gate then read the CPU-only DNNL provider
  linked into `/usr/local/lib` as foreign because it knew only the GPU prefix, so it takes both chain prefixes. The plugin step
  now runs on every chain and leaves an empty tree where it does not build, and the merge stage copies it
  ([failure-modes.md](docs/failure-modes.md#a-media-artifact-is-built-and-verified-and-the-merged-image-does-not-carry-it)).
- Owner decision: the Linux rocm variant moves to AMD's out-of-tree plugin EP. The media stage builds
  `libmigraphx-ep.so` from the pinned `onnxruntime/onnxruntime-ep-amdgpu` commit (`35-build-migraphx-plugin-ep.sh`:
  every FetchContent seeded from a sha256-pinned archive, `FETCHCONTENT_FULLY_DISCONNECTED`, an imported
  `onnxruntime::onnxruntime` over the chain's library, the two exports and the closure checked), the package
  stage ships it under `/usr/local/lib/onnxruntime-ep-amdgpu` and sets `ORT_AMDGPU_EP_ROOT`, and the runtime
  smoke's GPU gate judges it (`gpu_plugin_ep_verdict`). The shared `ORT_AMDGPU_EP_COMMIT` moves to the commit the
  spike proved on an RX 9070 XT (4 ms per frame, detector parity). The built-in provider stays until every
  consumer registers the plugin ([contract](docs/consumer-image-contract.md#amds-plugin-migraphx-ep)).
  `test-migraphx-plugin-ep.sh` (27) and `test-gpu-runtime-check.sh` (82) hold it; recipes `onnx-ep-amdgpu.*` and
  `gpu-runtime.plugin-ep-*` bite.

## 2026-11-07 — CUDA compute capability 7.5 joins the build (CON217)

- Owner decision: `CUDA_ARCHITECTURES` is `75;86;87;89;120`, so T4 and RTX 20xx cards get a cubin from ONNX Runtime
  and OpenCV instead of `cudaErrorNoKernelImageForDevice`. Moved together, as AGENTS.md requires: the pin, the
  Windows canonical-value and resolver suites, `test-version-forwarding.sh`, the mutation recipe, the ORT and
  OpenCV fallbacks, the media-builder ARG and the PowerShell default, and the pages that quote the set. The next
  nvidia chain compiles every CUDA kernel five times instead of four.
- CON169: the owner keeps one pipeline per arch opt-in until a run has reclaimed disk under pressure.

## 2026-11-07 — one pipeline per arch ran on a chain

- CON169: `CROSS_ARCH_PIPELINE=1` ran the default chain's media and android stages for amd64, arm64 and riscv64
  as three lanes; amd64 started its android stage while the other two were still in media, nothing was removed
  under a running build, and the chain passed in 2 h 06 min. The cold media stages (the versions.env merge
  re-keyed them) measured ONNX Runtime at 98-99 % sccache hits and `-j3` per arch, IREE's host LLVM at 24 min on
  arm64 with riscv64 reusing it, a peak of 34 compiler processes and 26 GB of free memory: CON165 and CON168 close.
  The mode stays opt-in until the owner decides its default.

## 2026-11-07 — the asset mirror answers from the build host

- CON153: with the keys installed, the chain's download helper served a pinned asset from the Garage bucket on the
  first try, and the running chain passes the `asset_mirror` secret to every stage build. The three pinned
  sccache 0.19.0 Linux tarballs are mirrored by hand (`fill-asset-mirror.sh --apply --url … --sha …`), since the
  2026-10-27 fill predates that pin. The in-RUN `asset-mirror| hit` line waits for a cold download.

## 2026-11-07 — two ONNX Runtime PRs prepared for the MIGraphX EP

- `linux/upstream/` is the Linux lane's index of prepared upstream submissions, as `windows/upstream/` is the
  Windows lane's. First entries: the MIGraphX EP fix that stages a strided partition output and makes it dense
  through a cached one-op `contiguous` program (with a unit test; the mechanism proved standalone on gfx1201 by
  `proof.cc`), and the one-line `GridSample` addition to the EP's op list. Neither is filed: AMD declared the
  built-in EP unmaintained (onnxruntime#32571), MIGraphX fixed the root cause (AMDMIGraphX#5345, `standardize_outputs`),
  and AMD's plugin EP sets that option, refuses a non-standard output otherwise and lists every op MIGraphX parses.
  CON225 closes; CON231 moves the Linux rocm variant to the plugin EP once a ROCm carries #5345. The two
  directories were removed the same day at the owner's request (the patches stay in git at 2a819d85);
  `linux/upstream/README.md` keeps the reasons.

## 2026-11-07 — between runs the disk guard spends the image lever first

- Owner decision: `_chain_runtime_lane_disk_gate` and `_chain_stage_disk_guard` remove dangling images and the
  stage tags the run does not need BEFORE they trim cache exports, restart buildkitd for stale records or prune
  the buildkit store; the image lever costs no rebuild time and freed 363G on 2026-11-06. The in-stage sampler
  is unchanged. `test-chain-lifecycle.sh` pins both orders (`disk-guard.lane-images-first`,
  `disk-guard.stage-images-first`); [build-cache-tiers.md § 3.2.2](docs/build-cache-tiers.md#322-the-image-store-lever-disk3).

## 2026-11-07 — the Linux AMD packages pass on the RX 9070 XT; comgr keys its cache on `TMPDIR`

- CON224 item 1 and CON225: on the packages rebuilt on the patched `:latest-rocm`, OxidANT, AccelerANTgine,
  OrchestrANT and OmniAccelerANT pass `compare_detector_parity.py` on MIGraphX. OmniAccelerANT's AppImage lane
  first hit its 180 s launch timeout: comgr keys its kernel cache on `TMPDIR`, which that lane randomizes, so
  every AppImage run compiles the detector's kernels again (370 s cold, 84 s warm). OmniAccelerANT 179d532 gives
  the launch 900 s (`PROFILE_GPU_TIMEOUT`); [failure-modes.md](docs/failure-modes.md#an-appimage-gpu-profile-times-out-while-the-deb-passes).
- The build host's asset-mirror keys are installed (`set-asset-mirror.sh --check` green); CON153's proof comes
  with the next chain.

## 2026-11-07 — the CUDA cache probe runs again and proves a write

- `Test-CudaCache.ps1` and `Test-Rdna4LayerLock.ps1` computed the repo root one level short and
  stopped at `Import-Module` (`windows\windows\scripts\modules`). `Diagnostics.ModulePaths.Tests.ps1`
  evaluates every diagnostic script's repo root and module import, with two mutations.
- The probe's nonce sat in a comment, which preprocessing strips from sccache's key, so a warm
  cache hit twice; sccache 0.19 also prints no write count. The nonce is now code, and the probe
  requires a miss, then a hit (`Diagnostics.CudaCacheProbe.Tests.ps1`, two mutations).
  It passed on `bk-windows-toolchain-nvidia`: 4 misses, then 4 hits (CON229).

## 2026-11-06 — IREE builds outside the 20 GB RUN scratch

- The amd64 media-tvm stage failed with `No space left on device` in IREE's compiler wheel while
  the host had 65 GB free: every Windows RUN gets a sandbox of about 20 GB, and IREE with LLVM
  in-tree left 0.3 GB. Its build tree now lives on the RUN's `iree-build-winamd64` cache mount at
  `C:\iree-build`, emptied before configure and after the wheels; a checkout run keeps the old tree.
  Each wheel logs the free space it starts with. `SourceBuild.IreeScratch.Tests.ps1` and six
  mutations hold the path on both sides, the resolver and both resets.

## 2026-11-06 — develop is green again after the Windows image fixes

- The push of `b2b906d8` turned Linux preflight, eight mutation shards and the Windows patch-drift
  job red (#234, #235). The Windows suites behind the new recipes failed on Linux pwsh, where CI
  proves them: the meson provenance case and the MSVC notice suite now use separators and an
  interpreter every host has, and the cases that need Windows (cmd.exe, VsDevCmd, the twin builds)
  moved to `TorchApp.SdistCompilerVs.Tests.ps1`, leaving the recipes on `SourceBuild.IreeTwin.Tests.ps1`.
- `LIBVPX_MESON_SHA256`, `DIRECTML_NUPKG_SHA256` and `LIBVPX_VERSION` are classified in
  `bump_versions.py`; `genai-guidance-smoke.py` passes ty. New duplication was refactored away rather
  than budgeted: `Get-BinDllProvenanceEntry` (OpenSSL and the MSVC runtime), `Add-IreeNinjaTuFlag`,
  and `WindowsPythonApp.Common` re-exporting the notice API. Two allowlist rows became stale and left.
- The drift check maps `002-libvpx-clangcl-simd-flags.patch` to the libvpx meson port at
  `LIBVPX_MESON_COMMIT`, which the wrap applies it to, instead of GStreamer's tree.
- The libvpx patch's repo now lives in the drift check's one repo map (`Patches`), not a second table
  whose parameter duplicated another suite's signature; the TensorRT and MSVC-notice recipe families
  are declared in `gate-proofs.allow`.
- `wsl-quality.sh check` hands the suites one absolute interpreter path: 108 of them run
  `"${PREFLIGHT_PYTHON}"` quoted, so the multi-word `uv run ... python` exited 127 in each.
- Still red until `:winarm64` is published again (#236): the device gate runs the published bundle,
  which predates libvpx (`no element "vp8enc"`) and the onnxinference wide-path fix (0xC0000005).

## 2026-11-06 — Windows packages carry the MSVC runtime's notice

- A ZIP, MSIX or MSI that carries the VC++ runtime ships `licenses/msvc-runtime/Redist.txt` and a
  `README.txt` with the end-user notice and the learn.microsoft.com link; the wording is a draft for
  review. CPack installs both and adds the notice to the WiX licence page; `New-PortableBundle` and
  the Python app bundle stage them; `Assert-PackageMsvcRuntimeNotice` fails a finished package with
  the runtime and without the notice (`WindowsMsvcRuntimeNotice.Common.psm1`, CON228;
  `Msvc.RuntimeNotice.Tests.ps1`, `test-cmake-windows-arch.sh`, four `msvc-notice` recipes).

## 2026-11-06 — ORT's LLM kernels compile through sccache on Windows

- `onnxruntime_providers_cuda_llm`, the last CUDA target on bare nvcc, keeps the sccache launcher:
  `Get-OrtPtxLauncherExemptArg` and `sccache-ptx-exempt.cmake` are gone. The hub's sccache build
  carries mozilla/sccache#2809, and in the nvidia toolchain image it compiled `sm_86` plus PTX-only
  `compute_120` without `Missing "cubin" file output`, warm 5 of 5 from the cache.
  `SourceBuild.OrtCudaLauncher.Tests.ps1` refuses an exemption's return
  (`lib.ort-cuda-launcher-no-exemption`, `sccache.ptx-only-pass-runs-uncached`). The chain proof
  (provider link from hits, smoke gate, `Test-Cache.ps1`) comes with the next nvidia chain.
- v0.19.0 is exactly `SCCACHE_SOURCE_REV` and carries #2876; #2809 merged on 2026-11-02 and is in no
  release yet, so the hub's build stays (`shared/upstream/sccache/README.md`).

## 2026-11-06 — The Windows nvidia lane downloads TensorRT and fails without it

- `Install-Tensorrt.ps1` guessed the pre-11.x file names, which 404 for TensorRT 11, so every
  `-Gpu` image shipped without TensorRT while the log read "Continuing WITHOUT TensorRT". It now
  downloads `TensorRT-Enterprise-<ver>-Windows-amd64-cuda-<cuda>-Release-external.zip` from
  `developer.nvidia.com/downloads/compute/machine-learning/tensorrt/`, for the image's CUDA line
  only, and grades it with the unchanged `TENSORRT_ZIP_SHA256`: the 11.4.0.106 zip fetched on the
  host on 2026-11-06 hashed to the pin. A staged zip in `windows/downloads/` still wins.
- No TensorRT now fails the nvidia lane (owner, 2026-11-06): the installer and `Set-TensorrtTree.ps1`
  throw, and the smoke gate fails an `-ExpectGpu` image with an empty `TENSORRT_ROOT`
  (`host.trt-url-tensorrt11-scheme`, `host.trt-missing-throws`, `smoke.trt-required-expect-gpu`).
  The runtime-only rule is unchanged. Windows arm64 TensorRT stays off as an owner decision (CON230).
## 2026-11-06 — QNN's Hexagon skeletons are DSP payload, and NVIDIA's gst plugins are recorded

- The first green arm64 nvidia package stage reached the runtime-image smoke, which failed on 107 QDSP6 objects
  under `onnxruntime-cpu/lib/hexagon-v*/`: the HTP backend's skeletons, run by the DSP, never by the image's
  loader. The tree-arch scanner skips those dirs and names machine 164 `QDSP6` (`tree-arch.hexagon-skels-are-dsp-payload`,
  `tree-arch.hexagon-filter-is-narrow`). The five `libgstnv*.so` plugins that need the driver's `libcuda.so.1` are
  recorded per arch in `_PARITY_GST_KNOWN_BROKEN` (`runtime-smoke.nvidia-gst-plugins-recorded`,
  [failure-modes.md](docs/failure-modes.md#tree-arch-usrlocallibonnxruntime-cpu-ships-107-em164-objects-on-arm64)).

## 2026-11-06 — A required `rustup … add` is retried under qemu-user

- The arm64 package stage of the nvidia chain died in `rustup component add rustfmt` with a qemu-user SIGABRT
  mid-download, a step the three runs before had passed. `rustup_required` in `install-rust.sh` runs each of the
  four required adds up to three times and fails the installer after the third (`rust.rustup-required-retries`,
  `rust.rustup-required-propagates`,
  [failure-modes.md](docs/failure-modes.md#rustup-component-add-aborts-under-qemu-user)).

## 2026-11-06 — The SBSA RUNPATH starts with `$ORIGIN`, and the CUDA SONAMEs come from the host toolkit too

- The fourth arm64 package stage left 15 closure rows with every element registering: nine were
  `libnvdsgst_deepstream_bins.so` NEEDing its sibling plugins in `gst-plugins/`, out of reach of a RUNPATH that
  names `lib/` alone, and six were still bare `libcufft.so`, `libcublas.so`, `libnppial.so` and `libnppist.so`,
  because the staged arm64 runtime holds only cudart's dev link. `ds_sbsa_runpaths` now writes
  `RUNPATH=$ORIGIN:…/lib`, as the amd64 Makefiles do, and `ds_sbsa_cuda_soname` reads the SONAME from the target
  view or the host toolkit of the same version (`deepstream.sbsa-origin-runpath`, `deepstream.sbsa-host-cuda-sonames`,
  [failure-modes.md](docs/failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).

## 2026-11-06 — The SBSA bufferpool is staged under its SONAME, and every bare CUDA NEEDED is rewritten

- The third arm64 package stage left 24 closure rows and four elements that "do not register" from
  `/nonexistent`: the SBSA container ships `libnvdsbufferpool.so` bare, and nothing that NEEDs
  `libnvdsbufferpool.so.1.0.0` resolved it; `libcublas.so`, `libnppial.so` and `libnppist.so` were NEEDed
  bare like `libcufft.so`; and the UCX, Maxine and bare-bufferpool excuses were STALE on a `.deb` without those
  files. `ds_stage_sbsa_libs` copies the bufferpool under its SONAME with the bare link, `ds_sbsa_runpaths`
  rewrites every bare NEEDED to the target CUDA dev link's SONAME, and the amd64-only excuses are gated per arch
  (`deepstream.sbsa-bufferpool-soname`, `deepstream.sbsa-bare-cuda-needs`, `deepstream.sbsa-amd64-excuses`,
  [failure-modes.md](docs/failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).

## 2026-11-06 — The SBSA DeepStream files get RUNPATHs and link TensorRT 10

- The second arm64 package stage failed DeepStream's soname closure (105 rows) and found `nvinfer` linked
  `libnvinfer.so.11`. The Jetson `.deb`'s files carry no RUNPATH (L4T's `ld.so.conf` has the tegra dir) and NEED a
  bare `libcufft.so`; `ds_sbsa_runpaths` now sets `RUNPATH=…/deepstream-9.1/lib` on every file without one and
  rewrites that NEEDED to `libcufft.so.12`, as the amd64 `.deb` carries. The TensorRT 10 SDK's `-L` precedes the
  sysroot flags on the cross compiler word, and the three VPI consumers are excused on arm64 only
  (`deepstream.sbsa-trt-sdk-before-sysflags`, `deepstream.sbsa-runpaths-set`, `deepstream.sbsa-vpi-excused`,
  [failure-modes.md](docs/failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).
