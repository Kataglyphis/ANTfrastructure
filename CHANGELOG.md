# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-11-10 … 2026-11-17`](docs/changelog-archive-2026-11-17.md) ·
> [`2026-11-06 … 2026-11-12`](docs/changelog-archive-2026-11-12.md) ·
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

## 2026-11-20 — consolidate the Linux proof work with current develop

- Preserve both explicit ORT census loader-path interfaces and their exemption arguments. Keep the platform grouping in the shared ISA module so the runtime smoke stays within its existing size limit.
- Preserve both histories and their mutation recipes; rebase archived changelog links and keep all original entries.

## 2026-11-20 — CON237 closed: every binding replays the shared text cases

- `fixture.json`'s `cases` are replayed by AccelerANTgine 7f8cb17 (C++ and Python), OxidANT 9e0f589 and OrchestrANT
  585f40c, which now names a schema object llguidance cannot compile `generation_failed` as C++ and Rust do. The stream
  lines reach Dart too: OmniAccelerANT e6b1898's `endpoint_reply.dart` replays them and fails on an `error:` line.

## 2026-11-20 — the test model's `fixture.json` lists its cases (CON237 item 4)

- `tiny-genai-model.py` writes `cases`: seven requests with their answer or their error kind (`invalid_options`,
  `generation_failed`), measured on the image's GenAI: greedy to the budget (`defg`, `length`), the schema case
  (`7`, `stop`), a schema that is an array or a number, an object the grammar compiler refuses, no messages and no
  budget. Owner decision 2026-11-20: all three bindings replay it.

## 2026-11-19 — `ctest-run.sh --fail-on-skipped REGEX`: a skip is not a pass (BeschleunigerBallett X2)

- BeschleunigerBallett's llvmpipe lane counted its hardware ray-tracing `GTEST_SKIP`s as passes. After ctest,
  `ctest-run.sh` now reads ctest's JUnit report and fails the run on each test matching REGEX that was skipped,
  printing its name and ctest's reason; ctest's own failing status wins. Disabled tests never count. The report is
  the caller's `--output-junit` or a temporary one, and a missing one fails; `CTEST_FAIL_ON_SKIPPED` sets the pattern
  from the environment. The suite reads a report ctest 4.4.3 wrote and runs the host's ctest too. See
  [`ctest-run.sh`](docs/shared-script-libraries.md#ctest-runsh--run-a-cmake-projects-test-suite-in-a-container).

## 2026-11-19 — the Cargo license stager gates the crate graph it stages (BeschleunigerBallett X4)

- Only a comment in a manifest kept wgpu out of BeschleunigerBallett's C++ bridge. `stage-cargo-licenses.py` gains
  `--forbid-package PATTERN`, a repeatable case-sensitive glob over the selected graph's names that fails with each
  match's shortest dependency path, and `--max-runtime-packages N`, which counts live `cargo tree --edges normal` and
  fails above N with the count. Both run before staging and stay off by default. On 2026-11-19 OxidANT's
  `kataglyphis_cxx_bridge` staged 129 to 130 packages and held 55 in its normal tree on all three of its targets. See
  [`third-party-licenses.md`](docs/third-party-licenses.md#checking-delivered-package-licences).

## 2026-11-19 — one file of OpenAI stream lines for every binding (CON237 item 3)

- Rust and Python read stream lines differently: a chunk that is no JSON failed Rust's stream and was skipped by
  Python, and an `error:` line failed Python's and was ignored by Rust. `shared/contracts/openai-stream-lines.json`
  holds eleven cases with their events or error; owner decision 2026-11-19: both fail the stream.
  `test-openai-stream-lines.sh` holds its shape.
- OxidANT 2afd994 reads an `error:` line as the server's error and OrchestrANT 985c0d6 fails a chunk that is no JSON;
  both replay all eleven cases.

## 2026-11-19 — Home Assistant keeps the cat cams' model time (CON253, in source)

- `configuration.yaml` reads each cam's `/healthz` `stats` as Modellzeit, Bildrate and CPU sensors with
  `state_class: measurement`; `packages/catcam_performance.yaml` adds each cam's median model time over a day and a
  week and `catcam_model_time_rise`, which notifies when the day's median stays about 25 % above the week's for an
  hour; the 21:00 summary names each cam's day median. `check_config` of `home-assistant:stable` passes. The live
  instance takes it when its owner deploys it.

## 2026-11-19 — the three detectors' golden tests read the same pixels (CON234)

- ModelANT bd4094a carries `contracts/fixtures/two_cats.png`, the lossless decode of `two_cats.jpg`, its digest in
  `fixtures/NOTICE`. OxidANT (d518ad4), AccelerANTgine (30ba9a8) and OrchestrANT (d926992) read it at that pin.
  AccelerANTgine's `jpegdec` and `videoconvert` had given the second cat 0.721 where OpenCV gave 0.564; on the PNG
  both give 0.564, and its recording is redone. Fleet-health's contract rows read 0 on 2026-11-19. CON234 is done.

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

## 2026-11-19 — retain ORT loader identity with internal HIP probes

- Accept unrelated fork-child runtime records in a profiled process's loader trace. The current Rust CLI's internal HIP probe produces these records before the parent loads the MIGraphX plugin.
- Keep every selected ORT core and requested plugin bound to the profile PID and package origin, including duplicate records. Add regressions for foreign and malformed selected PIDs and missing required libraries; this does not authenticate traces or prove loaded bytes, a single session, clean hosts or licences.

## 2026-11-19 — select an explicit mirror for isolated source proofs

- Add an optional Ubuntu mirror URL to the isolated runner, record it and forward exactly one bootstrap value. Use the existing Ubuntu mirror rewriter before apt; the default retains the image's source configuration and signed metadata. Refuse malformed or credential-bearing URLs before output allocation.
- Retain closed, ignored quality environments on existing tmpfs through a repository-owned relocation helper. Preserve canonical GNU tar bytes, refuse shared cache inodes and retain an empty original mountpoint. This does not preserve volatile tools across reboots or qualify builds; sources, locks, persistent caches and original outputs remain separate.
- Add actual prefix/command fixtures for mirror ordering, defaults and raw failure, plus isolated environment-retention controls and mutations. The Media control driver includes these preserved suites; they do not replace a full preflight or image/hardware acceptance.

## 2026-11-19 — prepare the six WebGPU Media command profiles

- Share canonical stage argument construction while retaining the existing ordinary launcher's ROCm/amd64 refusals. Add explicit default amd64/arm64/riscv64, ROCm amd64 and NVIDIA amd64/SBSA arm64 Media profiles, immutable local parents and absolute paths.
- Require the correct SDK/GPU parent selection, both WASM modes and the amd64 build platform. Check every profile against independent expected argv and the actual shell stage graph. Prepared commands do not launch builds, verify parent ancestry or establish image/hardware acceptance; the remaining owned launch and handoff profiles still need qualification.
- Clear inherited accelerator flags during canonical tag lookup and select both accelerator toggles explicitly in prepared environments. This prevents a tool image's default AMD/NVIDIA setting from turning a default Media command into a different variant.
- Reuse the existing source-check protocol for Media controls. Its fake S3 startup children clear an inherited cache-chain setting; an explicit inherited-environment regression retains the original fallback assertions without changing the real compiler-cache setup.
- Preserve proof-driver input and source checks with isolated command fixtures and mutations. Refuse missing inputs before bootstrap, retain existing evidence, propagate raw child/Git failures and reject patch, index or worktree drift before success.

## 2026-11-19 — combine all WebGPU media factory proofs

- Add a shared media acceptance entry requiring delivered enabled native/GIL/FT products and both compiled Asyncify/JSPI factory replays at one explicit ORT ref and Git revision. Preserve the narrower existing media replay and its CLI failure policy through shared parsing and dispatch.
- Reject missing flavors, disabled products, mismatched source/configuration, failed or duplicate fresh replay verdicts and changed input receipts. Keep native partial evidence and raw child statuses without publishing an overall receipt on failure. Synthetic fixtures and mutations test these refusals; actual image builds, device inference and final consumer acceptance remain separate requirements.

## 2026-11-19 — preserve append-only operational memory updates

- Add one repository-owned memory appender with explicit expected bytes/SHA256, live-controller refusals, nonblocking file locking, append-only writes and exclusive original-prefix/append backups. Changed prefixes, file identities, unknown observations or failed I/O cannot produce a passed receipt.
- Add independent controller/file fixtures and mutations, including concurrent suffixes, symlinks, hardlinks, short writes and failed proof writes. Expand strict Python coverage by all four new Python files and retain positive and negative scope controls. The helper does not authenticate writers or provide a crash-atomic transaction; it grants no build, GPU or goal acceptance.
- Include shared Python test siblings in the type checker's search roots. Extend the independent import chain and prove removal fails, retaining every existing root and file scope.
- Reverify both saved snapshots after writing as well as before it. An independent red control showed the first version accepted either post-write corruption; two mutations remove the separate checks. The memory prefix remains preserved when a later snapshot check fails.

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

## 2026-11-18 — resolve real package loader parent segments

- Accept a traced `$ORIGIN/../lib` path only with explicit live root resolution, a normalized expected package directory and actual file containment. Canonical CLI roots, missing-file and symlink-escape refusals remain strict; receipts preserve the original trace paths.
- Synthetic live-file controls and mutations cover valid parent segments, missing files, absent resolution and symlink traversal. This does not authenticate traces or library bytes, prove a session or GPU inference, or repair the original failed C++ hardware receipt.

## 2026-11-18 — preserve the exact staged consumer index

- Restore the optional working-source copier on the current tooling branch. Generate its overlay from the index, preserving staged gitlinks even when both the selected base and actual child checkout differ. Regular-file staging, complete index, copied bytes/modes/links, source-race and independent-object checks remain required; committed recursive acceptance stays strict.
- Real temporary Git fixtures cover three distinct base/index/child revisions and independently corrupted destination indices. Mutations restore working-tree selection or omit gitlinks; these controls do not authenticate pins, materialize child sources, build a consumer or prove inference.

## 2026-11-18 — preserve escaped mutation recipe data

- Serialize merged registries as ASCII-safe JSON while preserving every decoded value. Intentional corrupt strings in encoding mutations no longer contaminate the clean registry source.
- Add round-trip, existing-entry and repeated-write controls plus a mutation that restores literal Unicode output. These checks cover registry serialization, not consumer encoding coverage or complete mutation acceptance.

## 2026-11-18 — refresh derived quality documentation

- Run the canonical doc-number updater after the package and loader mutation additions. Preserve the computed totals, family counts and census values; repeat the previously invalid doc-number and registry baselines and their existing mutation recipes.

## 2026-11-18 — repair full-preflight documentation and recipe namespaces

- Keep the loader-origin pointer in the existing GPU bundle bullet, restoring the README's unchanged 100-line limit.
- Move the nine AMD provenance recipe IDs from the unregistered `ort` family to the existing `packaging` family. Keep every target, edit, test and reason unchanged and preserve a one-to-one ID map with the proof; the registry retains all 6,922 recipes.

## 2026-11-18 — share profiled ORT loader-origin checks

- Add a shared parser and CLI for bundle and AppImage loader paths. Profile mode validates the original profile bytes with the canonical provider/run verifier, then requires the matching PID trace and every requested plugin beside ORT.
- Refuse foreign origins, lexical escapes, missing evidence and mismatched PIDs. Optional live resolution rejects symlink escapes; trace-only callers retain an explicitly weaker origin check.
- Synthetic controls and mutations cover these refusals. Loader paths do not prove file hashes, one ORT session, clean-host inference or complete licence closure.

## 2026-11-18 — retain original AMD plugin package provenance

- Extend shared AMD package staging and verification with an optional provenance path outside the exact license tree. Original image bytes, regular files, package containment and fresh stage targets are required; existing three-argument callers retain their behavior.
- Synthetic refusal cases and mutations cover missing, changed, linked, escaping and overwritten files plus raw copy failures. These checks do not prove linkage, full licence closure or GPU inference.

## 2026-11-18 — package the selected Linux TAR bundle

- Make Linux TAR use the shared bundle resolver, including `APP_PACKAGING_BUNDLE_DIR`, instead of the raw Flutter tree. This retains the prepared runtime closure and ORT notices in Omni packages.
- Preserve default paths, empty overrides, Android APK selection and legacy output copies; fail on an invalid selected tree or resolver error. Real TAR fixtures and mutations cover selection and argument boundaries, not native inference or full licence closure.

## 2026-11-18 — preserve consumer command seals

- Add a reusable terminal command/cleanup sealer for cache-captured consumer jobs. It reuses the existing unit parser and terminal verdict, retains input hashes and raw statistics, and refuses an existing exclusive cleanup. Caller markers are not artifact, cache or GPU acceptance.
- Mocked positive/refusal controls and 15 mutations cover identity, status, markers, evidence, stopping, cleanup and preserved scope.

## 2026-11-18 — check ordinary Android commands before local FINAL

- Derive a missing Android stage label from the exact unpublished Android driver, lane, literal transport and hash-bound complete source proof; preserve original producer bytes and reject explicit incorrect labels.
- Share producer-unit matching across Runtime and Android, and extend independent command, duplicate-flag, launch and source-refusal fixtures across all six supported Linux lane schemas. These fixtures do not establish actual FINAL or GPU acceptance.

## 2026-11-18 — bind local FINAL acceptance to canonical runtime exports

- Accept the existing image and verified export wheelhouse modes without changing required runtime gates, original source/Android evidence or the complete six-consumer plan.
- Match explicit runtime unit lanes to their declared variant and bind the original host checkout through its complete selected worker mapping. Separately located owned wrappers must retain every selected companion byte, a clean source tree and exact invocation ownership flags.
- Extend synthetic producer, receipt and companion refusal controls across all six Linux lane schemas and both delivery modes. These controls do not establish actual FINAL consumer, GPU, clean-host or legal acceptance.
