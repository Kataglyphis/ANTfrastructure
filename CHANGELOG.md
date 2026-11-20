# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-11-13 … 2026-11-14`](docs/changelog-archive-2026-11-14.md) ·
> [`2026-11-07 … 2026-11-12`](docs/changelog-archive-2026-11-12.md) ·
> [`2026-11-05 … 2026-11-06`](docs/changelog-archive-2026-11-06.md) ·
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

## 2026-11-20 — preserve Stevedore image names and hidden task identity

- Preserve raw nerdctl JSON names and inspect each distinct manifest to bind
  configuration identities, including digest-qualified aliases. Keep empty
  successful output logged; refuse native diagnostics and incomplete identities.
- Resolve the hidden SYSTEM worker by exact task path and GUID. Require Ready
  state for completion and share queued/running/unknown refusal for overlap and
  revocation. Keep original raw failures, regression controls and mutations;
  corrected protected setup and real normal-user acceptance remain required.

## 2026-11-20 — complete isolated preflight's free-threading prerequisites

- Install managed free-threaded CPython from the existing source pin, keep its
  path through the clean worker environment and refuse wrong versions, enabled
  GILs or missing headers before any gate. Preserve the real extension/GIL test;
  fixture controls and mutations cover provisioning, forwarding and raw refusals.

## 2026-11-20 — isolate consumer-hook fixture ancestry

- Bound Git discovery above empty-directory cases, using Git's native root
  spelling and an owned parent repository even when TMPDIR is inside a checkout.
  Retain all hook assertions and prove the isolation with a ceiling-removal mutation.
  Use the same native spelling for the image-runner configuration diagnostic.

## 2026-11-20 — stabilize QNN query receipt fixtures

- Order the fixture's captured `find` output under the C locale while retaining
  its original arguments, raw status and injected failures. Keep all 120 frozen
  receipts byte-identical. A reverse-enumeration control and valid sort-removal
  mutation cover the rootless overlay discrepancy; real SDK/EP acceptance is separate.

## 2026-11-20 — version bounded Stevedore delegation

- Add host-specific one-time SYSTEM task setup, ordinary-user preview/Apply/status,
  protected payload/runtime hashes, read/execute-only delegation and revocation
  with archived logs. No timer or automatic service restart is installed.
- Retire only allowed completed media branches with a merged image and no
  retained container reference, plus explicitly disposable stopped containers.
  Canonical cleanup rechecks exact IDs and idle state; no force or volume removal.
  Preserve all other tags and compiler mounts, keep the 100-GiB target, and report
  target attainment separately from worker/scheduler success. Document setup,
  updates, scope and required independent acceptance on another host.
- Keep the exclusive maintenance lock in the host module so the shared module
  copied into build images remains byte-identical to the preceding source.
- Split reclaim options, runtime readiness, manifest policy, task definitions and
  fresh completion reads to meet the strict PowerShell complexity gate. Retain
  every refusal and raw status; test stale/foreign receipts and scheduler mismatch.
- Document private public-registry client configuration for rootless preflight;
  credential-helper failures cannot be ignored just because an image is public.

## 2026-11-20 — the chain names an absent asset mirror; stale GPU texts fixed (CON153, CON256 h, CON260)

- `append_asset_mirror_secret` prints `[INFO] asset mirror: none (<file> is missing)` once per chain: a missing env file
  was silent and hid an absent mirror for two rounds (CON153 closed). `test-asset-mirror.sh` holds the once-only line.
- CON256 (h): the accelerator page names `/usr/local/lib/onnxruntime-gpu` instead of the undefined `${ORT_GPU_DIR}` and
  the runtime gate's real plugin-EP checks instead of a provider list; the consumer contract sends only NVIDIA consumers
  to `onnxruntime-gpu/lib`; `AGENTS.md` says which gate fails which in-tree provider.
- CON260: the FFmpeg OpenVINO probe drops its stale `2026.2.1` literal and takes the passed pin.
- `test-deepstream.sh` and `test-gpu-variant.sh` pin the amd64 target and build host their fixtures model; on an arm64
  host they failed unmutated (8 assertions), which turned the commit hook's mutation sample vacuous there.

## 2026-11-20 — CON237 closed: every binding replays the shared text cases

- `fixture.json`'s `cases` are replayed by AccelerANTgine 7f8cb17 (C++ and Python), OxidANT 9e0f589 and OrchestrANT
  585f40c, which now names a schema object llguidance cannot compile `generation_failed` as C++ and Rust do. The stream
  lines reach Dart too: OmniAccelerANT e6b1898's `endpoint_reply.dart` replays them and fails on an `error:` line.

## 2026-11-20 — the test model's `fixture.json` lists its cases (CON237 item 4)

- `tiny-genai-model.py` writes `cases`: seven requests with their answer or their error kind (`invalid_options`,
  `generation_failed`), measured on the image's GenAI: greedy to the budget (`defg`, `length`), the schema case
  (`7`, `stop`), a schema that is an array or a number, an object the grammar compiler refuses, no messages and no
  budget. Owner decision 2026-11-20: all three bindings replay it.

## 2026-11-19 — keep media module reads independent of cached directory views

- Extend the existing narrow per-file delivery to the five media-core RUNs and TVM, preserving the same seven shared modules plus TVM's private leaf. The current NVIDIA CUDA repeat reproduced an unreadable cached view before ONNX compilation; isolated direct mounts read, hash and import those seven bytes correctly.
- Share the structural closure assertion across all eight media RUNs and mutation-test missing modules, cached-directory regressions and scan coverage. Keep all copied source views, product parents, compiler caches and stage gates.
- Preserve the successful `2c40a98d` NVIDIA producer and physical CUDA/TensorRT/DirectML evidence as exact-source results; its failed diagnostic repeat proves no CUDA cache hits. The successor still requires full qualification and current-source acceptance. CON228 remains OPEN/DRAFT.

## 2026-11-19 — deliver LiteRT modules through direct file mounts

- Preserve the same seven-module closure in both LiteRT build RUNs while avoiding a cached module view that the actual NVIDIA toolchain could list but not read. Other source views and compiler caches remain intact.
- Add portable closure checks and mutation proofs for both RUNs and every module. Actual engine controls prove reads and imports, including an inherited RUN; full new-source quality and four-lane acceptance remain required.

## 2026-11-19 — preserve IREE dispatched AVX512 under the Windows ISA floor

- Give IREE's AVX512-base clang-cl branch explicit feature flags: a forwarded global `-march=x86-64-v3` overrides `/arch:AVX512`. GNU/MSVC options and the global baseline stay intact.
- Apply before native and cross-host configuration, reject unknown source layouts and test idempotence, scope and failure paths. Compiler controls reproduce the conflict; full new-source quality and all lane/device/CI acceptance remain required.

## 2026-11-19 — retain GenAI extensions when the primary source is unavailable

- Fetch GenAI's exact upstream extensions commit before CMake, retaining primary retries, recursive checkout and fatal commit checks through the shared clone implementation.
- Route FetchContent to that verified tree; metadata and disposable Git regressions cover refusal paths. Full final-source quality, producer and device acceptance remain required.

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

## 2026-11-18 — preserve CPython zlib-ng ISA dispatch under ClangCL

- Apply CPython instruction floors after MSBuild per-file metadata: ordinary x64 stays v3; existing AVX-512 files use v4 and retain VNNI/VPCLMUL options. ARM64 is unchanged.
- Add a portable XML-wiring regression and mutation recipes. A native MSBuild/ClangCL probe reproduces the old feature-loss failure and compiles all four corrected cases; complete lane acceptance remains separate.

## 2026-11-18 — prove CPack diagnostics without Pester

- Move the four CPack diagnostic cases to a portable harness; retain the remaining CMake Pester cases.
- Retarget their mutation recipes and prove the real exported entry, preserving the Linux no-Pester guard.

## 2026-11-18 — preserve strict patch evidence and shared package diagnostics during integration

- Merge both source-identity protections and upstream-availability diagnostics; required patch acceptance
  rejects unchecked sources after the original-commit fallback. Preserve all existing mutation recipes.
- Route CPack generator messages through the canonical batch logger and share parameterized file fixtures;
  no duplication allowances or gate thresholds are increased. Regression fixtures cover sorted tails,
  unrelated files, and missing versus empty directories; upstream application and real packaging remain separate.

## 2026-11-18 — retain ONNX source identity when the primary repository is unavailable

- Recover the unchanged GenAI 0.19.0 original commit from CodeLinaro only after primary clone failure; share commit checks with explicit VERSION_INFO and keep the pin in its own compile stage.

- Use the same original commit and release checks in sparse ONNX patch-drift CI, retaining Git and GNU patch dry runs and a tagless exact-commit fallback.

- Run the eight source-pin declaration and routing mutations through the portable source-archive harness, retaining exact ONNX stage checks without requiring Pester or Windows CIM on Linux workers.

- Windows QNN preserves its separate original ONNX header commit and all upstream CMake patches while recovering unavailable source downloads through a verified local archive.

- Pin the Windows ONNX core to its full original 1.31.1 commit. Keep the primary tag clone first; after its bounded retries, fetch that exact commit from the AMD-maintained fork with shallow recursive submodules.
- Reject commit or VERSION_NUMBER mismatches and any failed fetch, checkout or submodule command before source patches or compilation. Existing non-ONNX clone behavior is unchanged.
- Share required AST command selection, argument identity, scope and order checks across the affected wiring suites, preserving the existing call-assertion diagnostics and mutation cases.
- Producer, hardware and hosted-CI requalification remain required for this changed source closure; earlier 0b552573 results retain their original attribution.

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
  (upstream answers 404)`. The original warning-only change distinguished availability from drift; required
  acceptance now fails if exact-commit recovery still leaves any patch unchecked. A reachable upstream
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
