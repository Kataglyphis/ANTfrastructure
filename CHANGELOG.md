# Changelog

> **Older entries** are archived, newest archive first:
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

## 2026-10-27 — shared uv dependency groups

- Let consumers sync a locked dependency group without installing the project or unrelated extras, while retaining the shared environment and ORT checks.

## 2026-10-27 — require executed script tests

- Fail empty or entirely skipped Bash runs and Pester suites, with regression and mutation proofs.
- Run the WSL quality driver's Windows tests with native PowerShell, bootstrap its Pester dependency and preserve test failures through logging.
- Test the pip failure policy with a real child on both hosts and verify the error and warning paths.

## 2026-10-26 — let active develop quality runs finish

- Keep the Hub's active Linux x64 preflight and eight mutation shards running when another `develop` push arrives; the latest pending run follows, while PR and `main` keep cancellation.
- Guard that concurrency expression with a parsed workflow test and a mutation that restores cancel-on-develop.

## 2026-10-26 — Every Linux compile goes through sccache

- ONNX Runtime and LiteRT compiled most of their objects through the distro ccache: pthreadpool and XNNPACK FORCE `CCACHE_BINARY` into CMake's launchers, which beat the sccache launcher in the environment (ONNX Runtime's arm64 build: 414 sccache requests over 2740 compiles, 104 min). `append_cmake_compiler_cache_pin` passes the launcher as `CCACHE_BINARY` too, `append_cmake_cache_linker_args` and ONNX Runtime's build args always pin, the riscv64 torch wheel pins through `CMAKE_ARGS`, and `cmake_assert_compiler_cache_pin` fails ONNX Runtime's, both LiteRT and every Vulkan component's build whose launcher was replaced ([docs](docs/build-cache-tiers.md#a-subproject-that-forces-its-own-launcher)).
- The foreign-arch Vulkan SDK build was uncached: `sdk-arm64` and `sdk-riscv64` compiled 7768 objects in 79 min each. Its RUN now has both cache mounts, the S3 secret and the drain; `vulkan.sh` exports the launcher for `./vulkansdk` and pins it on each target component.
- Each sccache RUN's drain prints `sccache-stats|` (requests, hits, misses, errors), and names the server log's reason when an S3 write failed.
- GStreamer's setup died under `set -u` at its first top-level line (`GSTREAMER_DEBUG_LOGS: unbound variable`): the 2026-10-22 knob move had put the default inside `save_logs`. The default now sits beside that reader; `GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR`, from the same move, had its default in the linker wrapper while the C++ wrapper ran first, and is now set at top level. Both are covered by `test-gstreamer-debug-logs-knob.sh`.
- `prune-safe.sh` ignored its arguments, so `--help` or a mistyped `--dry-run` started a real layer-cache prune; it now prints its header for `-h`/`--help` and refuses any other argument before buildctl runs (the knobs stay `PRUNE_KEEP_GB`, `DRY_RUN`, `PRUNE_DUP_CACHEMOUNTS`).
- `stop-cross-chain.sh` exited 1 after a clean stop, since a refactor had dropped `_stop_remove_pidfile_if`; it is back, with an end-to-end case in `test-chain-lifecycle.sh`.

## 2026-10-26 — Home Assistant's cat cam config is tracked

- The three OmniAccelerANT cat cams' automations, `rest` sensors, counters and the **Katze**
  dashboard ran from an uncommitted working tree since 2026-10-13; they are in git now, with
  their `catcam_*` keys in `secrets.yaml.example` and a section in `linux/homeassistant/README.md`.

## 2026-10-26 — the home-lab backups reach the NAS every week

- **Windows CI module installs share one guarded bootstrap.** Pester and
  PSScriptAnalyzer reuse a matching installed version or retry transient Gallery
  lookup failures. An exhausted retry or an installer that returns without the
  requested version still fails the job; focused fixtures prove both cases. A
  stale Windows Meson duplication allowance was removed.
- **Default ShellCheck now covers `linux/ansible/`.** The Ansible shell scripts join the
  error-level scan and its warning ratchet; the scope suite fails if a tracked script is
  omitted. The pinned full scan and warning baseline remain green.
- **`linux/ansible/playbooks/backup.yml`** copies what git does not hold to the QNAP NAS every
  Saturday, from pi-1, which mounts the share over SMB for the run only. Three sources:
  - **Nextcloud AIO's Borg repo on srv-1** (39 GB) is mirrored the way AIO's own sync recipe
    does it: no copy while `lock.roster` exists, `aio-lockfile` held while copying and released
    in an `always:`. A stale lockfile of ours is taken over and reported, since AIO skips every
    daily backup while one exists. A source that is not a Borg repo, or whose id is not the NAS
    copy's, is refused, so `--delete` cannot replace the copy's history with a recreated repo.
  - **Home Assistant's newest backup**, only when its `backup.json` says it is encrypted and
    it is under 72 h old, checked by sha256 on the NAS.
  - **Each host's secrets** (`backup_secret_paths`), streamed as a tar straight into `age`, so
    no plaintext copy lands on any disk. srv-1's bundle holds the Borg passphrase, pi-1's the
    deploy key, the host_vars and the Home Assistant backup key.
  A failed source fails the run after the others were copied. The QTS snapshots of the share
  are the history; setup and restore: `linux/ansible/README.md` § Backups to the NAS.
- **`ansible-backup.{service,timer}`** run it through `run-update.sh`, which now takes
  `ANSIBLE_UPDATE_STATUS_NAME` and `ANSIBLE_UPDATE_TIMER` and a run lock, so the update and the
  backup never run at once. Home Assistant's Ansible page has a **Backup** view
  (`packages/ansible_backup.yaml`), and `ansible_run_status.py` collects the `BACKUP:` notes.
- **Home Assistant's local backups were not encrypted.** The README said they were since
  2026-09-14; the newest archive's `backup.json` says `protected: false`, because encryption is
  chosen per location since 2025.2. Its other tip, network storage, does not exist on a Container
  install. Both are corrected.
- **An unreachable Nextcloud host fails only its own source.** The first real run met srv-1 with
  a changed SSH host key; the delegated task dropped pi-1 from the play, which skipped Home
  Assistant and the secrets and left the share mounted. The block now ignores unreachable
  delegates and pings the host first, so the failure names the cause and the run goes on.
- Tests: `test-ansible-backup.sh` (the two helpers, seven mutations), a `BACKUP:` case in
  `test-ansible-run-status.sh`, and `linux/ansible/tests/test-backup-playbook.sh`, run by hand,
  which drives the playbook against a fake AIO host, a fake Home Assistant and a real `age` key.
  A run against srv-1 and pi-1 into a scratch directory bundled both hosts' secrets and refused
  the unencrypted Home Assistant archive.

## 2026-10-26 — Linux chain: runtime lane robustness and image content

- Read GStreamer scan markers without an early-closing pipeline. A large valid
  scan could hit `Broken pipe` under `pipefail` and be reported as `UNKNOWN`.

- Reap heartbeat timers with SIGKILL after an interrupt. TERM could be lost while
  Bash started the sleep, hanging parallel mutation baselines; the regression
  fixture now makes the timer ignore TERM and proves bounded cleanup.

- The image's app venv carries OrchestrANT's `frontend` extra (CON106, owner 2026-10-26): the Linux and Windows torch stages sync `--extra frontend`, so the image runs the Flet viewers and the camera stream page; VENV-SET holds the extra on amd64/arm64 and leaves it out on riscv64, whose markers drop every frontend requirement, and APP-PARITY requires flet, flet-desktop, flet-web and FastAPI with recorded riscv64 absences.

- riscv64 ships no hadolint (CON151, owner 2026-10-26): the torch stage's QEMU source build of hadolint (about 2 h per riscv64 wrapper) is gone with `build-hadolint.sh`, `HADOLINT_SOURCE_SHA256` and `HADOLINT_HACKAGE_INDEX_STATE`; `install-lint-tools.sh` prints a NOTE there, and the lint-tools contract row requires no hadolint on riscv64. amd64 and arm64 keep the pinned release binary.

- Every chain RUN names its layer (CON162): a `LABEL kataglyphis.step=<name>` before each of the 104 RUNs in `linux/Dockerfile.*`, graded by `verify_dockerfile_step_labels.py` (`lint-dockerfiles.sh` pass 0c); `layer-audit.py` prints each layer's step from the image history. Labels are metadata, so no layer recompiles.

- The runtime lane checks its inputs before any arch builds (CON140): each arch's package-stage apt set runs through `apt-get install --simulate` in the base's pinned parent (QEMU for foreign arches), and the rustup and uv installers are re-hashed against their pins. A conflict or rotation refuses the lane with apt's line or the pin's name; `RUNTIME_INPUT_PREFLIGHT=0` builds without the check ([docs](docs/linux-cross-builds.md#the-runtime-lane-input-preflight)).

- Linux app bundles carry the image's own CPython (CON123), staged relocatable by `python-relocate.py` (RUNPATH `$ORIGIN/../lib`, sysconfig rewritten to the new prefix, no system site-packages or GPL-3 readline binding), instead of downloading python-build-standalone; `--python-runtime standalone` keeps the download, and the runtime smoke's `RELOCATABLE-PY` row proves a moved copy on every arch.

- The runtime lane's disk gate sums the arches it keeps local (CON141): 165 GB amd64, 105 GB others, 50 GB less per wrapper already local, plus the 40 GB disk-watch floor; after the index the manifest lane removes each pushed arch's wrapper, push leftover and package image (`RUNTIME_DROP_PUSHED_IMAGES=0` keeps them; `--no-push` never removes).

- Pinned release assets come from the build hosts' Garage bucket first (`release-assets`, `<sha256>/<name>`) and fall back upstream, so a GitHub outage cannot fail an arch (CON153). The pinned sha256 stays the only gate. The host's `~/.config/kataglyphis/asset-mirror.env` reaches every Linux RUN as the BuildKit secret `asset_mirror`, and `linux/host-config/fill-asset-mirror.sh` fills the bucket from a chain's miss lines.

- The asset mirror is set up by two scripts, so another host repeats it without hand steps: `linux/sccache-s3/setup-asset-mirror.sh` creates the bucket and its read and fill keys on the Garage host (idempotent, so every host shares the keys), and `linux/host-config/set-asset-mirror.sh --from <ssh-target> --url <bucket-url>` runs it there from the build host, installs both env files mode 600, removes the Garage host's copies and proves the rights (`--check` re-proves them). The host-config scripts share one argument loop, `linux/host-config/host-cli.sh`.

- A failed arch re-runs alone (CON139): each runtime wrapper carries `org.kataglyphis.build-key` (its build-context files, version args, android parent digest and wrapper knobs), and a published child whose key matches joins the index by digest after every gate has read it; `RUNTIME_REUSE_CHILDREN=0` keeps the same-run index ([docs](docs/linux-cross-builds.md#a-failed-arch-re-runs-alone)).

- Every resource-monitor sample names the runtime lane's arch and step (CON142): `_runtime_timed` and the background pusher hold `<arch>.<step>` markers under `RESOURCE_MONITOR_STEP_DIR`, and the stage column lists them as `arch/step` joined by `+`.

- The disk trim names every slug it evicts and keeps, and logs the buildkit fallback's layer cache (records and GiB) before and after its prune (CON152); tool-build caches are BuildKit cache mounts outside the trim's reach.

## 2026-10-26 — Reuse and dependency updates

- Extend the shared submodule pin helper with `--path` for any initialized direct gitlink.
  Resolve the child's live remote default branch, validate its full tip SHA, and stage only
  that path; a local Git fixture proves a differing `.gitmodules branch` and mutation failure.

- Refresh tracked Renovate to 44.184.1 with patched Zod; drop the obsolete
  markdown-it override. Raise setuptools to 84.2.1 with a PyPI-verified wheel
  SHA in the shared pin, arm64 wheel and LiteRT lock.

- Add a reusable Windows Slang parity assertion for every manifest WGSL output.
  Ballett's ARM cross build snapshots pinned OxidANT files before compilation and
  requires every fresh emit to match the originals;
  source and output checks in its native job use the same staged artifact.

- Share Windows build config and workspace-root selection between Ballett and OxidANT;
  keep each build's own path validation. Share parsed source-copy loop fixtures between
  their ARM64 mutation suites, while retaining each suite's payload assertions.

- Share the MSIX manifest and entry reader through `WindowsSmokeTest.Common` for installer
  consumers; missing or malformed manifests remain fatal, with archive handles closed.

- Add a weekly cross-repository Bash/PowerShell reuse report to the consumer
  inventory. It reuses the existing clones and duplication tokenizer, filters the
  live GitHub list to active owned nonfork repositories, writes only under ignored
  `logs/`, and fails when inputs or repository coverage are incomplete.

- Bind `Test-Elevated` directly in the Windows host lavapipe installer, so consumer
  Vulkan tests reach the elevation decision after verified downloads. An import-binding
  and cold-export regression catches the visibility loss; the failure guide names the symptom.

- Select Windows container source roots in the shared runner for OmniAccelerANT,
  OxidANT and AccelerANTgine; preserve each repo's exact and wildcard skips,
  fail on an empty selection, and test the transport under `-WhatIf`.
- Preserve `true`, `recursive` and `false` as distinct submodule modes in the
  shared Windows short-path checkout; the preparation and container workflows
  retain their recursive short-path defaults while direct-only consumer builds
  can avoid the DocumANTation cycle.
- Let the reusable Windows Python CI workflow choose submodule depth; its
  default remains recursive, while consumers with a cyclic documentation tree
  can request direct entries.
- Share a parameterized Windows stage-directory test fixture between OrchestrANT
  and OxidANT; its negative cases prove that parse errors, missing resets,
  stale bytes and swallowed allocation failures are caught.
- Forward the WSL quality runner's `--jobs` limit to nested Bash tests and ShellCheck,
  avoiding accidental oversubscription during the full suite.
- Correct the Linux image quick reference to match its installed `jq` tool.
- Measure consumer Bash and PowerShell reuse against hub functions and script
  blocks in the shared quality-report workflow; declared bootstrap drift stays
  fatal while overlap candidates go to ignored `logs/code-quality/` reports.
  Prefer the native PowerShell drift checker on Windows.
- Fail the reusable quality report for an owned nonfork consumer whose pinned Hub
  lacks the reuse scanner; keep the upgrade notice and uploaded artifact, and
  execute the workflow step in a mutation-backed regression fixture.
- Teach future consumer `AGENTS.md` files to search their repository and
  submodules before adding another Bash or PowerShell implementation.
- Share synthetic ELF and gst-inspect test fixtures with OmniAccelerANT; its
  bundle tests retain their own assertions and request the fields they need.
- Export shared `cmake --build` arguments with an optional target so
  BeschleunigerBallett can use the same parallel and verbosity policy.
- Reject a foreign `DirectML.dll` during shared Windows media staging and check
  staged DirectML bytes against the chain, enabling AccelerANTgine to drop its
  second GStreamer DLL copier.
- Share the family-image Python guard in `python-probe.sh`; ModelANT and AssetANT
  can use one tested marker/interpreter check and retain their own diagnostics.
- Include Torch/vision Git-tag lookups when a scoped `pep621` Renovate run selects their
  Python manifest, so valid pinned sources no longer appear as unchecked dependencies.
- Clarify why TorchVision stays in the image and correct stale release examples beside the pins.
- Make the riscv64 wheelhouse reject missing or conflicting Torch source pins and pass the
  normalized package version to `uv pip install`, removing obsolete fallback releases; update
  the dead-function census after moving pin validation into its own module, and mutation-test
  source-tag drift, missing package versions and uv version normalization.
- Return explicitly from both arms of the copied Renovate apply probe so consumer
  trailing-conditional ratchets pass; prove a planted final test fails in the fixture.
- Split copied hub bootstrap checks and rollback into small helpers so consumer complexity gates
  pass, and prove the copied fixture rejects a deliberately complex mutant.
- Resolve the copied Git mode companion through each consumer's script directory in ShellCheck.
- Use Windows Git for a copied Renovate wrapper's hub bootstrap in Windows-authored WSL
  checkouts, so a false `.gitmodules` modification under WSL Git cannot reject an apply. Share
  the Git mode selector with the driver as a copied companion and enforce its drift check.
- Correct fleet plan wording to name remote default tips for direct gitlinks and distinguish
  its advisory nested-checkout graph from the apply scope.
- Let a copied consumer Renovate wrapper initialize its own missing hub submodule on `--apply`;
  report and dry-run stay read-only, while fatal failures restore the checkout and Git config.
- Make the local Renovate command inspect every direct submodule and update its gitlink to the
  latest commit of the remote default branch, regardless of `.gitmodules branch` or Renovate's
  report rows. Apply initializes missing checkouts; report and dry-run clone nothing. Retain
  rollback and manual staging.

## 2026-10-25 — Quality debt cleanup

- Reconcile OrchestrANT's seven tagged Torch/vision Git URLs with GitHub lookups;
  project only the hub-approved pair to every source and wheel pin in one audited
  TOML/uv-lock transaction, with missing-lookup and failed-lock rollback proofs.
  Include the new resolver in strict ty and Ruff annotation gates.
- Correct the family inventory to reflect ANThology's ANTfrastructure submodule.
- Count a declared shared shell bootstrap's real image-consumer command as a caller in the
  dead-function gate; keep local dead code fatal and prove inert names do not count.
- Check npm's latest Renovate release before each live local dependency scan and install it in
  an isolated user cache first; fail when the version check or installation cannot complete.
- Reject a PATH Node below Renovate's pinned minimum and recover a partial cached Node/npm
  installation through a checked staged extraction.
- Add `renovate-fleet.sh --github-owned` with a paginated, authenticated active nonfork inventory
  and complete-checkout/adoption preflight; provide a reusable read-only CI entrypoint gate.
- Include custom regex managers in default Renovate scans, resolve the GitHub token centrally
  (including `gh.exe` under WSL), and fail before writes when any dependency was not checked.
- Distinguish floating aliases, local build images, named Docker build contexts, Actions outputs,
  espup's named toolchain and unversioned Git sources from real failed Renovate lookups; fix
  dartdoc's datasource and give Windows Server Core LTSC tags a release-year versioning rule.
- Apply versioned Gradle wrapper URL updates through an audited properties parser; refuse ambiguous
  URLs and checksum-coupled archives instead of editing a guess.
- Add a reusable one-consumer hub pin helper: require an explicit remote `develop` SHA,
  check the consumer branch and a clean initialized submodule, and stage only its gitlink.
- Make quality measurements reusable across owned repositories: rooted size, complexity and duplication reports, consumer mutation recipes, read-only Python refactor previews, uv-locked Ruff and ty reports, and a standalone PowerShell lint/JSON workflow rooted at the caller. Keep duplication strictness separate from the existing ratchets while consumers remove current findings.
- Keep the Linux cmake-format preflight environment in ignored `logs/tools/` so a Windows virtual environment cannot be reused accidentally under WSL; exclude rollout logs from the critical Cargo source check.
- Register all 20 active owned repositories in the consumer inventory; archived repositories remain outside the rollout.
- Let consumers with other submodules call the shared pin gate through a separate hub checkout, avoiding a mutual DocumANTation submodule cycle.
- Isolate riscv64 cross pkg-config probes from the amd64 image's metadata, and make the GStreamer smoke use the shared target environment so invalid x86_64 link paths fail before consumer tests.
- Add an on-demand Python refactor preview: pinned safe Ruff fixes and formatting, strict follow-up gates and an uploaded patch, with local logs ignored by Git.
- Keep the preview's general tests on the runner Python while the type gate uses the locked quality environment; prove both paths in the workflow fixture.
- Upload strict Windows complexity JSON from CI so each run keeps its measured results for comparison.
- Require owned repositories to reuse or extend functionality from their shared repositories and submodules before adding another implementation.
- Add a WSL2 quality runner that installs pinned tools and runs Linux preflight, mutation proofs and PowerShell checks with logs under ignored `logs/`.
- Make the default hub Ruff sweep, all-file annotation scan and dynamic Linux/Windows ty reports fail on findings; add regression and mutation proofs for each verdict.
- Mark shebang Python scripts executable to satisfy Ruff EXE001 on Linux.
- Prove the focused hub Ruff gate rejects unused assignments independently of the final default sweep.
- Use the fixture server's free port for the dead-site browser check, because Chrome blocks port 9 before it can report connection refusal.
- Close stdin for mutation test children so inherited terminal input cannot stall proofs; save Windows harness proof JSON under ignored `logs/code-quality/`.
- Share child-process cleanup in the shell test harness and use it in both lifecycle and browser fixtures.
- Keep Gitleaks out of ignored test logs and Python bytecode, with planted-secret tests for both paths.
- Remove the test-only `VULKAN_FIXTURE` knob so the env-knob registry stays strict without an allowlist.
- Declare the version-bump mutation family and refresh the derived mutation totals.
- Add fatal Ruff parameter and return coverage for the WebDAV downloader, gateway log-tail tests, chain PID receipts and log-dir consumer tests, with per-file missing-annotation and scope mutation proofs.
- Check the Jetson webcam app against the assembled torch venv and route all five dependency-specific Python sources through their strict workflow or build gates.
- Type the validator probe, runtime child-stop, wheel tag resolution and runtime SDK help tests; move their signatures into fatal Ruff checks with per-file missing-annotation and scope mutation proofs.
- Add strict Ruff signatures for triplet query receipts, advertised-version verification, CLI help exits and image-reference behavior, with per-file missing-annotation and scope mutation proofs.
- Type native smoke dispatch, nerdctl service receipts, binfmt probe controls and native GCC environment tests; enforce their signatures with per-file failure and scope mutation proofs.
- Type the Dockerfile ENV ordering verifier, image-consumer bootstrap, NPM transport and Python provider context helpers; add each to fatal Ruff annotation coverage with mutation proofs.
- Add strict parameter and return checks for serving stack tests, the LLM network guard, libcamera report tests and consumer quality wiring tests, with missing-annotation and scope mutations.
- Type the embedded Python extractor, Corrosion fixture, sudo-policy closure tests and wheel archive transport receipts; enforce their Ruff signatures with mutations.
- Add fatal Ruff annotations for WebDAV download, Meson provider, Flutter trace-summary and wheelhouse manifest helpers, with per-file scope mutations.
- Type the Flutter web artifact checker, add it to the fatal Ruff parameter and return gate, and prove strict scope with fixture and mutation checks.
- Annotate the chain ORT, sudo policy and raw pin reader test helpers, expanding the fatal Ruff parameter and return gate with strict-scope mutations and regression tests.
- Type the gateway E2E fixture, HTTP client and operations tests, extending strict Ruff coverage across the gateway suite.
- Type the cross-active registration contract fixture and enforce its signatures in the strict Ruff gate with a mutation proof.
- Type the mocked compiler candidate tests and add their signatures to the fatal Ruff scope with a mutation proof.
- Type the media file-set receipt fixtures and enforce their signatures in Ruff, with a strict-scope mutation.
- Run the ShellCheck warning ratchet in bounded Windows batches and merge each JSON result, avoiding CreateProcess command-line overflow while preserving source following.
- Add a ShellCheck-free Windows batching test and a mutation proof for the batch loop.
- Clear the venv version probe's percent-formatting findings and narrow import, metadata, lock and OpenCV exception handling; malformed present locks now fail, with 15 probe regression tests.
- Add the venv version probe's parameters and public returns to the fatal Ruff annotation gate.
- Consolidate runtime venv status parsing, shrink the smoke script's frozen size by one line, and keep its measured size record current.
- Convert all 26 Renovate audit formatting findings to equivalent f-strings; correct the venv probe's build-pin type, and enforce annotations for the GStreamer metadata helper and data-lock fetcher with per-file failure checks.
- Keep unexpected GenAI configuration exceptions fatal, prove they cannot print a green sentinel, and document the smoke's known-error contract.
- Make the TVM codegen smoke skip only a missing import; unexpected initialization errors now fail, with a regression proof.
- Make the Flutter browser smoke treat Playwright errors as failures and propagate unexpected Python bugs; add regression coverage for both outcomes.
- Make Debian app dependency discovery fail when readelf or ldconfig fails; keep dpkg's no-owner result explicit and regression-tested.
- Restrict version-bump checksum fallbacks to network and invalid-JSON failures; propagate unexpected helper errors and cover all fallback paths with offline fixtures.
- Make the runtime VENV-SET metadata probe fail on malformed installed requirements instead of converting the error into an unavailable skip; add a regression assertion and document its verdict.
- Clear equivalent format findings in the doc-number checker, OCI layer extractor and consumer quality wiring checker; refresh the derived mutation counts.
- Clear the ORT venv census's percent-format findings; report known filesystem and wheel errors while letting unexpected bugs retain their traceback, with source and Windows-stage regression coverage.
- Type the shared ORT venv census and enforce its parameters and public return in Ruff, with per-file failure and strict ty coverage.
- Type the complexity scanner, make its 33-file Ruff signature scope fatal, and convert its file reads and subprocess status checks to explicit resource and failure handling.
- Type the code-size scanner and add its parameter and public return annotations to the strict Ruff gate, with a fixture that fails on missing annotations.
- Type the comment-size verifier and add it to the strict Ruff parameter and public-return gate, with a per-file failure fixture.
- Type the ShellCheck warning ratchet and add it to the strict Ruff parameter and public-return gate, with a per-file failure fixture.
- Type the shared gate-scope helper and enforce its signatures in Ruff with the same per-file regression gate.
- Type the Dart documentation renderer, including heading, navigation and submodule-link shapes, and enforce its API signatures in Ruff.
- Type the fleet dependency test graph and receipts, and enforce its fixture helpers and tests through the strict Ruff gate.
- Type the free-threaded sysconfig tool discovery and repair path, and add it to the per-file strict Ruff signature gate.
- Split the gateway fake lane handler out of its factory so the helper stays under the 80-line function limit without a freeze exception.
- Type the trailing-conditional verifier and extend its fatal Ruff parameter and public-return scope, with a per-file failure fixture.
- Type the manifest annotation reader and enforce its parameters and public return through the same strict Ruff scope.
- Add the lint-scope initialization tests to the strict Ruff annotation scope after typing their test methods.
- Type the Flutter fallback-font checker and add it to strict Ruff annotation enforcement and the ty quality scope.
- Type three workflow, ONNX receipt and callback-scope test helpers and make all three fail the strict Ruff annotation gate when untyped.
- Fully type the gateway routing end-to-end tests and add their signatures to the strict Ruff gate with per-file regressions.
- Type the gateway harness, shaping tests and fake lane, validate decoded JSON shapes, and enforce signatures in Ruff with a failing fixture.
- Type the apt update selection test helpers and enforce their signatures in the Ruff gate with a per-file regression fixture.
- Type the guarded-link test helpers and enforce their signatures in the same fatal Ruff scope with a per-file regression fixture.
- Type image-acceptance test helpers and enforce their signatures with the same missing-annotation regression gate.
- Type the version-bump driver's lookup and reporting helpers and add it to fatal Ruff annotation checks.
- Type the Flutter browser smoke callbacks, make the HTTP response callback return explicitly, and test its error recording.
- Type the header-discovery receipt fixture inputs and results and enforce them through the Ruff signature regression gate.
- Type the QNN query fixture inputs and receipts, and enforce their signatures with the strict Ruff and ty gates.
- Type the workflow conventions parser and findings, and enforce its signatures through Ruff with the existing ty coverage.
- Type the built-site link parser and graph checks, and enforce its signatures in Ruff with the existing ty coverage.
- Type the shared quality-allow readers and verdict helpers, preserving string and tuple keys under Ruff and ty.
- Type the media pin advisory fixtures and make missing source functions fail with a clear fixture error.
- Type the directory-visitor scenario generator, receipts and Docker closure checks in the strict annotation gate.
- Type the verified-installer shell receipts and copied-import checks in the strict annotation gate.
- Type the toolchain download-loader scenario builder and receipts, enforcing its signatures through Ruff.
- Normalize Windows Ruff source-map paths so shell-heredoc findings still point to their source file and line.
- Force UTF-8 in the Windows source-map relabeler so non-ASCII Ruff findings remain readable under cp1252.
- Annotate `ort_census_probe.py`, clear its 91 missing parameter and return types, and move it into the fatal 32-file Ruff signature gate.
- Fully type `verify_dead_functions.py`, clear its 16 UP031, three unused-noqa and subprocess-check findings, and make its ANN001/ANN201 checks fatal across 32 files.
- Annotate `verify_image_env.py`, clear its 20 Ruff UP031 findings, and extend fatal ANN001/ANN201 checks to 30 files. Its every-path signature fixture and 60 image-env assertions pass.
- Repair the Linux preflight failure caused by two reusable-lane test predicates ending on bare conditions; spell out their success and failure returns and keep the trailing-conditional gate clean.
- Annotate the mutation verifier, gate registry and image acceptance driver; clear 248 Ruff ANN001/ANN201 findings and enforce both rules on 29 files, with a failing fixture for each selected path. Clear 118 UP031 findings across the workflow checker, consumer inventory and Renovate planner, plus one PIE810 finding; keep their verdict fixtures and updated mutation recipes green.
- Resolve another 180 Ruff parameter and public-return findings in consumer inventory and the image bump tool; enforce ANN001/ANN201 on 26 fully annotated files.
- Require nonempty combined artifact uploads in both reusable Python CI workflows, remove the resolved workflow census budget, and prove the upload steps keep their failure and always-run settings.
- Keep the Windows 15-decision complexity gate green by moving LiteRT ty-pin validation into focused helpers in the BuildKit driver and wheel builder; missing pins still fail before a media solve or Bazel build.
- Clear 264 Ruff parameter and public-return annotation findings in the Renovate audit, package-name verifier and two docs bump tools; enforce ANN001/ANN201 on all 24 fully annotated files.
- Add Playwright to the locked quality environment and make ty check the Flutter browser smoke against its real API, with a failing API-type fixture and regenerated licence and SBOM records.
- Check the WebDAV downloader against the exact pinned client source commit in Linux x64 CI, without installing runtime dependencies; keep its fatal report under ignored logs and prove wrong calls and missing source fail.

- Add a locked `quality/` uv project for the Python analysis environment and expand fatal ty checks from 129 to 140 of 146 tracked files; keep the remaining image-only and private imports visible in ignored reports.
- Type the Ansible status report and add it to the fatal Ruff parameter and public-return gate, with a scope mutation proof.
- Type the Jetson webcam's frame handoff, inference helpers and request handler, and enforce the signatures in Ruff with a scope mutation proof.
- Give the smoke query contract suite explicit case tuple types and enforce its helpers in Ruff with a scope mutation proof.
- Add explicit receipt types to the Clang job policy suite and enforce its helpers in Ruff with a scope mutation proof.
- Type the Flutter performance reporter's CLI and JSON boundary, and prove its strict Ruff scope with a mutation.
- Type the binfmt probe receipt helpers and enforce their signatures in Ruff with a scope mutation proof.
- Type the Meson dispatch fixture's case rows, subprocess captures and receipts, and keep it in the fatal Ruff scope with a mutation proof.
- Share the typed receipt boundary between the host and target Cargo fixtures, and enforce both suites in Ruff with mutations.
- Type the host Python pin fixtures and enforce their helpers and test methods in Ruff with a scope mutation proof.
- Resolve all 20 missing variadic parameter annotations and make Ruff ANN002 and ANN003 fatal across every tracked Python file, with failing fixtures and mutation proofs.
- Annotate 195 private returns in Renovate Python scripts and all Linux quality verifiers; make their Ruff ANN202 findings fatal, with selector and scope mutation proofs.
- Resolve the remaining 108 private returns and make Ruff ANN202 fatal across all 146 tracked Python files; annotate the Renovate CMake parser's 50 parameters and two public returns and enforce both rules there.
- Clear parameter and public return annotation findings in the Renovate planner, gateway renderer and tests, and docs duplication scanners; extend the strict Ruff ANN001/ANN201 gate to all six fully annotated files, with failure fixtures and mutation proofs.
- Clear 14 more parameter and public return findings in nine docs, host, image, wheel and test files; extend the strict Ruff gate to all 15 typed files and test every selected path.
- Spell out 27 equivalent Python regex flags in source and shell heredocs; make Ruff FURB167 fatal in full hub lint sweeps with source, heredoc and mutation proofs.
- Parenthesize eight intentional adjacent strings in collections without changing their values; make Ruff ISC004 fatal in full hub lint sweeps with failure and mutation proofs.
- Convert 30 string formatting calls to f-strings and make Ruff UP032 fatal in full hub lint sweeps; test Python, shell heredoc and consumer advisory boundaries plus a selector mutation.
- Replace three constant-name `getattr` calls with direct attributes and make Ruff B009 fatal in full hub lint sweeps, including extracted shell Python, with failing fixtures and a selector mutation.
- Annotate the Renovate locator's 100 missing parameters and public returns and add it to the strict Ruff ANN001/ANN201 scope, with failing signature fixtures.
- Annotate 28 missing parameters and returns in four Linux quality scripts and add those files to the strict Ruff ANN001/ANN201 scope.
- Check the Linux venv probe with pinned ty against the assembled x64 torch environment, with a missing-import and wrong-return fixture; foreign architectures keep their runtime smokes.
- Check the Windows LiteRT wheel smoke with pinned ty against the built wheel and smoke dependencies, with offline execution and fatal checker and import verdicts.
- Share pinned ty setup between preflight and the Linux image build, share Windows required-child checks between FFmpeg and LiteRT, and reuse MIGraphX's file-gap probe for licence copies; shrink the measured FFmpeg/OpenCV duplication budget from 13 to 12.
- Refuse ambient ty and Ruff version overrides in the Python type and annotation gate, with failing version mutations.
- Share Windows agentic-loop test config defaults and child-process transport; lower their measured duplication budget from 39 to 20 without changing the gate threshold.
- Check `docs/conf.py` with pinned ty against the checked-out DocumANTation theme before the docs site builds; require a fatal type verdict, a missing-theme failure and mutation proofs for the file and source path.
- Enforce an 80% command coverage floor for Windows Vulkan validation after adding child-process behavior tests; the complete Windows suite passes 2,729 tests and all 15 module floors.
- Remove eight unused Python bindings, including one inside a shell heredoc, and make Ruff F401, F841 and RUF059 fatal in default hub preflight sweeps with failing fixtures and selector mutations.
- Quote the cross CMake policy option as one argument, remove its frozen ShellCheck SC2206 row, and prove the argument boundary with a focused test and mutation.
- Extend enforced Windows Pester command coverage from eleven to fourteen modules: WebDAV has a 90% floor, MSIX signing an 80% floor, and container-image module resolution a 100% floor, with success/failure tests and missing-target mutation proofs.

## 2026-10-25 — Wider strict analysis and Windows coverage

- Expand fatal ty checks from 93 to 129 of 146 tracked Python files, including the Windows certificate helper; retain full Linux and Windows diagnostic reports for the remaining optional-dependency files.
- Add return annotations to the remaining 22 constructors and callable methods, then make Ruff ANN204 and ANN206 fatal beside ANN205 over all tracked Python; prove each selector with failing fixtures and mutations.
- Raise measured Windows Pester command-coverage enforcement from eight to eleven modules: MSIX, Slang and wasm-opt now have focused floors and missing-report proofs; move the suite discovery floor from 2,680 to 2,686 after adding five tests.

## 2026-10-24 — Wider quality coverage

- Make pinned ty checks fatal for tracked Linux Python test helpers as well as verifiers, growing the clean strict scope from 40 to 93 files; test a bad type and mutation-test the new selection.
- Annotate the four remaining static methods and make Ruff ANN205 fatal across all tracked Python; share its fatal report handling with ty so the duplication gate stays green, and keep the other annotation findings visible in ignored reports.
- Extend enforced Windows Pester coverage from three to eight modules without lowering the existing floors; pin the target inventory and mutation-test removal and floor relaxation.

## 2026-10-24 — Stronger executable quality gates

- Fail Python lint on suppressed exceptions and late-bound loop closures (Ruff B012/B023), including Python extracted from shell scripts; test both defects and mutation-test the selector.
- Enforce targeted Windows Pester command-coverage floors, reject missing or empty reports, and upload ignored test and coverage artifacts from Windows x64 CI.
- Share the Windows Python CI build finisher across three drivers and remove its stale duplication exception while preserving fatal-step reporting.
- Allow manual dispatch of the Linux x64 and Windows x64 quality workflows and check those triggers in the workflow suite.

## 2026-10-24 — Locked docs dependencies

- Replace the root theme `requirements.txt` with `docs/pyproject.toml` and `docs/uv.lock`; local docs builds use `uv sync --locked`, and image builds check the lock offline while keeping their shipped Sphinx stack.
- Verify that no consumer names the removed root file and test both local locked sync and the offline image path.

## 2026-10-24 — Python type analysis

- Pin ty 0.0.91 beside Ruff and run it in the Linux x64 preflight: tracked documentation and Linux verifier quality scripts are a strict type gate, while full Linux and Windows scans save findings under ignored `logs/code-quality/`.
- Report missing Python parameter and return annotations with Ruff ANN rules in the same folder and upload the reports from CI. Ty checks types but does not itself require annotations.
- Correct type errors in quality scripts, build helpers and tests; prove that a planted type error fails the new gate and that a failed consumer ty check fails the existing static-analysis driver.
- Keep curated SBOM `--stdout` byte-identical to the generated file on Windows as well as Linux.
- Refresh the mutation manifest totals so the documentation-number suite and Linux preflight agree with the measured inventory.
- Preserve an ignored interrupt for scheduled job commands and use a valid module spec in the free-threaded load-trace fixture, fixing two Linux preflight failures.
- Keep the quick-start README within its 100-line gate and set the ordered-job interrupt trap without a ShellCheck warning.
- Reap mutation test sessions when their shell exits so an inherited output pipe cannot turn a completed baseline into a timeout; refresh stale mutation recipes and the generated gate proof registry.
- Show bounded stdout/stderr and the test leader's exit state when a mutation baseline times out; cap cleanup when a detached child retains a capture pipe.
- Keep the mutation suite's CI shard assertion readable in both LF and Windows CRLF checkouts, with fixtures for both forms.
- Send ordered-job watchdog output to its job log, with a live file-descriptor regression and mutation proof, so it cannot hold a captured test pipe open.
- Send ordered-job supervisor output to the same job log and append command output so earlier diagnostics survive; live descriptor and cleanup assertions plus two mutations prove the behavior.
- Remove a reentrant Bash `wait` from trapped ordered-job cleanup after the watchdog fired; bound the reaping fixture's joins, report its active case, and prove both failures with mutations under single-CPU stress.

## 2026-10-24 — CI quality evidence

- Lint Python embedded in tracked consumer shell scripts, including shell-only consumers; fail on extraction errors and batch the hub sweep for Windows Git Bash.
- Require fresh JUnit and package coverage XML after each successful stable Linux Python test leg; expose a per-leg `coverage-min` workflow input.
- Report PowerShell complexity on the selected path in the reusable Windows lint job, with `complexity-strict` available once a consumer meets the limits.
- Grade detected consumer CI lint calls for active, fatal ratchets in the weekly inventory, and report consumers with no detected call.
- Add focused fixtures and mutations for the new failure paths.

## 2026-10-24 — Windows PowerShell quality and harness controls

- Consolidate generated build logs, resource samples and test reports under ignored `logs/` paths on both lanes, including a durable Windows test summary; retain root chain status for live readers and the separate `out/complexity/` reports.
- Move generated complexity JSON results into the Git-ignored `out/complexity/` folder; keep `-JsonPath` optional for local snapshots.
- Add an AST-based Windows PowerShell complexity gate to Windows x64 CI, enforcing 15/5/80 across the full tracked tree; share its parser with the test harness and mutation-test its metrics.
- Refactor Windows build, host, diagnostic and test code until the strict PowerShell scan is clear; lower 25 measured duplication budgets and remove 30 stale entries. The owner-approved budget-12 syntax exception closes the last PowerShell duplication finding without raising the threshold or narrowing coverage.
- Import the exact pinned PSScriptAnalyzer version in parent and batch lint processes; both Windows CI installers read the pin, and action changes trigger the x64 workflow.
- Split Slang shader compilation and CodeQL analysis into smaller phases, with regression tests for cache, failure, fallback and result policies.
- Separate image config token checks from finding assembly while keeping order and deduplication; the history gate tests both.
- Split target CPython staging into PE, copy, redist, launcher and CRT phases; split the LLVM arm64 layout diagnostic's plan and run phases. Both now meet the strict function limits, with new edge-case tests.
- Separate CMake configure's base, CUDA and cross/ROCm argument phases without changing caller override order; focused tests cover both CUDA cache opt-in and ROCm opt-out.
- Split free-threaded wheel setup from the cross-stage plan; tests preserve stale GIL wheel cleanup, one target tag and native no-op behavior.
- Split BuildKit stage argument, cache, metadata and retry preparation into private helpers; stage execution now meets the strict function limits, and tests preserve three or five attempts and gate order.
- Split the BuildKit driver into stage, preseed, cleanup and child argument phases; shared optional stage and child option policies keep cross-lane checks intact.
- Split the ONNX, OpenCV and sccache diagnostics into focused probes, and separated VS bootstrap, MSIX signing and lint reporting phases; the changed scripts now meet the strict PowerShell limits.
- Share ROCm pin forwarding, silo stack capture, host dufs change handling and diagnostic report helpers; focused fixtures keep argument, output and failure behavior covered.
- Share the agent process output reader and separate loop input validation and Claude arguments; real child-process tests cover stderr, timeout and role policy.
- Separate warning-baseline rendering from log streaming so the diagnostic meets strict complexity limits; tests preserve the narrower clang group in the flood count.
- Separate warning-stream parsing from reporting while retaining bounded input batches and compact signal evidence; a new fixture checks counts and CLI output.
- Split RDNA4 per-device changes from host discovery; tests preserve already-correct skips and failure aggregation without touching real hardware.
- Separate host disk-reclaim reporting and daemon work from the guarded file deletion loop; tests retain report-only, apply, build-prune and junction protections.
- Split host dufs setup into executable, server, task and endpoint phases; tests preserve report-only behavior and hidden process launch.
- Separate VHDX guest reporting from compaction; host-free tests cover ReFS warnings and unattached disks.
- Separate cuDNN verification from CUDA installation; tests fail each missing header, library and DLL class.
- Separate TensorRT archive search from bounded NVIDIA download fallbacks; tests preserve staged-archive precedence and failure reporting.
- Separate the module-free Windows build-copy probe's base pin reader; tests reject incomplete version fields.
- Separate active CDSP driver discovery from the GenieX NPU symbol report; tests preserve stale-copy rejection and advisory discovery failures.
- Split the publish-gate AST fixture into solve, export, toolchain and parent checks; its 36 behavior and mutation tests still pass.
- Split Python app bundle launcher and data staging into separate steps; tests preserve declared console scripts and copied data paths.
- Split BuildKit variant behavior from tag and chain wiring tests with one shared fixture; all 30 focused assertions still pass.
- Separate Python CI leg selection and failure policy from the driver; existing settings and child-process tests cover the handoff.
- Split GenieX lane launch from listener checks, serve arguments and endpoint reporting; tests preserve hidden startup and model mismatch warnings.
- Separate LSM wait-handle discovery from system-wide holder reporting; a fake debugger fixture verifies thread binding and the R10 handle.
- Split arm64 Python test staging into interpreter, site-install and per-leg steps; fixtures check cleanup and free-threaded inputs.
- Remove one obsolete duplication exception and lower a measured budget after the refactors.

- Require all 44 current harness fixture tests to pass in the byte-verdict mutation control; retain exact discovery, failure and skip checks.
- Verify that removing the byte comparison still fails the suite.

## 2026-10-24 — share architecture parsing, triplet queries and installer transport

- Share rootless binfmt CSV parsing while retaining caller-specific architecture validation, namespace commands and statuses.
- Share best-effort triplet queries without changing compiler or GStreamer directory and fallback policies.
- Share UV/Rust installer curl, checksum, execution and cleanup while retaining temporary variables and mismatch diagnostics.
- Carry the installer companion in copied UV fixtures and the narrow Rust build mount; verify cold imports and recovery.
- Remove three resolved duplication exceptions with independent original/current receipts and unchanged gate settings.

## 2026-10-24 — share compiler probes, ORT selectors and wheel platform policies

- Share compiler source-fixture transport and GCC version capture without changing probe verdicts, temporary state or strict-shell failures.
- Share ORT component exclusions and file predicates while retaining shallow record scans, tree archive candidates and partial traversal findings.
- Share wheel platform resolution with distinct LiteRT and Torch fallback policies; preserve each GStreamer architecture lookup and its failure status.
- Share stream-fixture startup while retaining independent tag, packaging and provenance expectations.
- Point Linux action image inputs at the existing common defaults contract.
- Remove four resolved duplication exceptions without changing scanner thresholds or independent expected results.

## 2026-10-24 — share lint scope, wheel transport and packaging execution

- Share lint scope initialization in the driver shell while preserving root selection, remaining arguments and rejected-root errors.
- Carry both scope companions in copied-driver fixtures and retain independent lint verdict assertions.
- Share quiet wheel unpack/pack commands while keeping caller-specific payload edits, statuses and cleanup.
- Share packaging command execution with separate best-effort and sudo failure handlers.
- Remove five resolved duplication exceptions; verify 48 lint, 96 wheel and 28 packaging original/current receipts without changing scanner settings.

## 2026-10-24 — share version shape, guarded links and raw pin lookup

- Share three- and four-part numeric version checks while preserving exact match state, compiler defaults, builder warnings, docs failures and Rust normalization.
- Share guarded GCC/Vulkan link actions with unchanged source-probe order, link flags, lazy sudo policy and failure behavior.
- Share Android/Rust raw pin lookup while retaining empty/unset/export state, all matching lines, whitespace and read-failure behavior.
- Require fresh canonical companions and expected exports; selected-file failures stay failures in conditional contexts.
- Remove seven resolved duplication exceptions while keeping literal test oracles and the scanner settings unchanged.

## 2026-10-23 — share artifact refusal, media probes and download initialization

- Share unsupported artifact-mode diagnostics while preserving exact stderr, status and lazy branch behavior.
- Share media cross/native dispatch and FFmpeg encode/decode commands, retaining native failure policy, caller globals, codec diagnostics and temporary-file cleanup.
- Share standalone Android/Vulkan download initialization with unchanged supplied-helper precedence, core lookup order and source-failure policy.
- Carry the bootstrap beside both standalone callers across Android, SDK, package and Torch copies, including the Vulkan install companion in Torch.
- Remove three resolved duplication exceptions; retain all independent smoke and architecture assertions.

## 2026-10-23 — share linker policy, service actions and cross-chain help

- Share the optional LLD check with its original literal-`false` policy, preserving lookup order, status, compiler arguments and logs.
- Share host Python path selection with explicit and version-derived profiles, preserving caller overrides, pin order, PATH fallback and required platform companions.
- Share nerdctl installer service actions while retaining caller guards, unit splitting, action order and warning policy; verify 204 independent offline scenarios.
- Share architecture and repository help rows between the cross-chain driver and its verification wrapper with unchanged complete output.
- Load the verification wrapper's function-only renderer only for help; preserve opaque argument forwarding and the child's exit status without that companion.
- Keep independent full-help receipts and explicit missing-renderer and forwarding assertions.
- Share actual cache-slug deletion while retaining separate trim-stop and protect-and-continue policies, quiet diagnostics and guarded cache roots.
- Remove four resolved duplication exceptions without adding allowances or changing scanner settings.

## 2026-10-23 — share native compiler paths and test fixtures

- Share native GCC system-path exports between Torch setup and the generated shell profile, preserving existing flags and expansion at profile sourcing time.
- Carry the mandatory path helper through Android, package and Torch images; keep independent environment receipts and negative gate tests.
- Use canonical truthiness in the FFmpeg fixture and share lifecycle fixture setup and cleanup while keeping explicit test assertions.
- Remove two resolved duplication exceptions and lower the lifecycle budget from 12 to 11; retain the remaining independent retention assertions.

## 2026-10-23 — share push selection, compiler opt-ins and wheel manifests

- Share runtime push selectors with unchanged accepted flags, assignment order, unset state and gates-only behavior.
- Share optional compiler-tool checks while preserving legacy opt-out spellings, lookup status and each caller's command arguments.
- Share wheelhouse manifest bytes between host and image diagnostics, with independent golden hashes and required copied companions.
- Remove four resolved duplication exceptions without raising budgets or weakening gates.
- Archive complete 2026-10-20 through 2026-10-22 entries with text preserved and relative links rebased.

## 2026-10-23 — share containment, image arguments and FFmpeg enumeration

- Share lexical root containment with unchanged caller slash policies; carry its canonical helper through narrow media mounts and copied provenance fixtures.
- Share image-CLI argument binding while keeping inspect and registry status, diagnostics and default-tool policies separate.
- Share FFmpeg runtime-file enumeration with exact selection, output and distinct process-substitution/pipeline failure behavior.
- Share runtime help stage descriptions and section rendering without changing complete help bytes or caller-specific text.
- Share cross-target callback assignment and repository help text while preserving raw values, dynamic caller locals and exact help columns.
- Remove resolved duplication exceptions and lower measured overlap budgets without raising limits or reducing scan coverage.

## 2026-10-23 — reduce Windows fixture and tool lookup duplication

- Share LLVM bare-name and `.exe` lookup while preserving optional archiver use and required MASM selection.
- Keep the scoped environment helper's loop variables from shadowing caller locals, move the FFmpeg fixture into Pester's shared scope, convert full-loop engine smoke tests to distinct data cases, reuse the batch-tool fixture for Bazel, and lower the measured agentic-test self-match from 45 to 39.
- Share Torch and torchvision ROCm target-family selection through one helper at both original setup points.
- Share leaf-file gap detection across MIGraphX install, ORT EP staging and license checks while preserving each caller's required-file list.
- Share host tree byte, file and access-error enumeration for VHDX verification and disk-reclaim sizing while preserving caller-specific verdicts.
- Centralize host buildctl lookup while retaining each script's candidate and PATH fallback policy.
- Share host elevation detection between lock reset and component-store repair while keeping their throw and interactive-exit policies.
- Share the wininit CIM query between silo baseline collection and polling while retaining timeout and baseline-exclusion behavior.
- Share CPython ABI probing between app and uv modules while preserving fatal wheel-fit checks and optional twin-store selection.
- Share Meson wrap-git and forced-libffi archive download, extraction and cleanup while keeping caller-specific failure and wrap deletion policies.
- Share operation timing and failure capture across build steps, gates and optional operations while preserving each caller's verdict policy.
- Pass the flat ROCm BuildKit module mount explicitly to the llama.cpp and Torch installers, removing their duplicate root discovery while retaining checkout defaults.
- Share source-build copy-if-absent and lavapipe module-path validation; pass the mounted module root explicitly to keep the BuildKit installer mount flat.
- Share OpenCL ICD 64-bit registry entry access between ROCm installation and smoke checks; keep path validation fatal and findings caller-owned.
- Delegate the CrossBundle package-architecture export to `WindowsTargetArch.Common`.
- Share the bounded dual-stack TCP probe between URL checks and the BuildKit sccache guard while preserving malformed-URL and timeout behavior.
- Share Dockerfile stage indexing and literal test-directory cleanup across Windows suites, preserving suite-specific stage rules and cleanup scopes.
- Return validated snippet ASTs and lexer tokens from one harness parse, so comment-aware structural scans reject malformed input before inspecting declarations; reuse harness ancestor traversal in GenAI wiring checks.
- Route the ORT WebGPU image probe through the shared Python JSON transport, preserving mode arguments and caller-owned findings for malformed or failed runs.
- Route TVM ROCm runtime and codegen probes through the shared Python JSON transport, preserving TVM finding labels and child diagnostics.
- Share Python report selection, exit verdict and decoding with the injectable IREE ROCm runner, preserving its no-tail finding policy.
- Resolve CUDA and TensorRT image installer modules through the shared container-image bootstrap, passing the flat BuildKit module root explicitly.
- Share `SCCACHE_MAX_JOBS` defaulting across host-cache and CMake setup while preserving each caller's activation point and logging.

## 2026-10-23 — close the ordered-worker cancellation race

- Register and gate scheduled work before it can escape cancellation; join only owned supervisors and their suite/watchdog groups.
- Preserve caller signal policies and ordered reports while recording failed supervision or cleanup as a failed job.
- Exercise interruption during blocked PGID publication, nested runner cancellation, timeout cleanup and unrelated caller jobs with deterministic fixtures.
- Share apt-list cleanup between package and Torch setup with the early image companion, and retain exact GenAI exception reporting through one emitted recorder.

## 2026-10-23 — share fetch and runtime validation lifecycles

- Share missing-checkout clone preparation while preserving exact ORT and GenAI retry, submodule, cwd and Python requirement policies.
- Share unresolved-library collection and summaries without changing artifact selection, partial resolver output, repair advice or fatal denial gates.
- Share ordered consumer fact guards in the existing consumer-contract library while preserving lazy Android checks and caller-specific verdicts.
- Render common runtime/SDK help rows centrally with exact caller formatting and runtime-only environment-consumption checks.
- Share best-effort Torch-missing marker writes and cache-aware apt-list cleanup with unchanged import, fallback and failure policies.
- Compare original outputs, statuses and lookup order against independent fixtures; remove resolved duplication exceptions without increasing limits.

## 2026-10-23 — remove another Windows duplication wave

- Scope FFmpeg codec and Vulkan Validation Layers compiler variables with the shared environment helper, route GPU diagnostics through shared Docker discovery, and build wheel/sccache fakes with the shared batch-tool fixture.
- Cover environment restoration after success and failure, resolver removal and parse mutations, while retaining the original fixture behavior.

## 2026-10-23 — remove another Windows duplication wave

- Share CMake cache parsing, lavapipe ICD registry writes and container-client capture while preserving caller-specific verdict and failure policies.
- Split the PowerShell literal masker into state handlers so the complexity gate can grade it without freezing an exception.
- Add focused regression cases for raw cache values, registry write failures and container inspect stream policy.

## 2026-10-23 — share source-build failure summaries

- Close the active failed phase and print its caller-labeled summary through one helper across source builders; keep each caller's rethrow, cleanup and trap behavior.
- Add integration and mutation coverage for failure labeling, phase status and error propagation.

## 2026-10-23 — remove another Windows duplication wave

- Share ONNX source-patch fallback and TVM ROCm probe lifecycles while preserving caller patch, argv, wait and verdict policies.
- Share CUDA target-usability checks, source-build preparation, Python wheel DLL search paths and requirements, Agentic execution, RDNA4 filtering, and Lavapipe asset facts.
- Share Windows test fixtures and mutation setup while keeping suite-specific assertions and failure controls.
- Correct PowerShell function-boundary scanning for braces in strings, comments and here-strings; add a regression fixture without removing literal tokens from comparison.
- Remove 16 stale Windows duplication exceptions and lower 12 measured budgets without widening thresholds or narrowing scan coverage.

## 2026-10-23 — share Python paths, GPU repositories and runtime preparation

- Remove six resolved Linux duplication exceptions without changing scanner limits or coverage.
- Share executable venv selection and workspace overrides; copied UV and WebDAV modules carry the pure Python probe companion.
- Share optional-checksum repository-key downloads and ROCm source rendering while preserving warnings, retries, status and exact repository bytes.
- Share media development-link eligibility while keeping link actions, logging order and failure handling with their callers.
- Share runtime preparation with unchanged architecture binding, exported dry-run state and validation failures.
- Preserve independent behavioral receipts and add 44 mutation checks; remove the exercised WebDAV dead-function exception.

## 2026-10-23 — share logger fallbacks, ELF checks and media probes

- Share standalone logging fallback registration while retaining plain/ANSI bytes, command/function lookup, streams, fatal errors and caller state.
- Carry the logger in Toolchain, Media and isolated payload copies; reuse the canonical platform ELF parser without leaking platform initialization.
- Share raw compiler-header queries, optional Python paths and Cargo environment bindings with caller ordering and validation preserved.
- Share test fixture lifetimes and verdicts while keeping process cleanup independent of the production code under mutation.
- Remove measured duplication exceptions and lower existing budgets without changing scanner limits or scope.

## 2026-10-23 — share Windows graph, debugger and fixture lifetimes

- Reuse the architecture DLL graph for cross bundles while preserving multi-root breadth-first order, machine checks and indexed API-set/system traversal.
- Share LiteRT-LM regex guards and TVM artifact cardinality with existing source operations.
- Share native output capture and CMake/smoke environment scopes with unchanged caller verdicts and fatal companion imports.
- Share silo debugger transport and wininit queries; fix manual handle mode reading uninitialized debugger state and keep invasive argv intact.
- Share checked local git setup, batch writers, file-tree initialization and AST readers across Windows suites.
- Make shared source-probe children terminate on setup errors; retain portable consumer checks beside separately discovered native batch execution.
- Remove four resolved Windows duplication exceptions (372 to 368) and lower five measured budgets without increasing limits or reducing scan coverage.
- Pass all 2,467 Windows tests, strict lint across 451 files and 65 portable Linux cases; raise the discovery floor to 2,442.

## 2026-10-23 — share ONNX staging, Renovate reports and gate fixtures

- Share ONNX cross-toolchain arguments and advisory filename-based library actions, retaining compiler order, copy/strip selectors, depths and repack decisions.
- Share ONNX Runtime FetchContent names while keeping verifier traversal and caller-specific `ortlib` policies.
- Share Renovate listing indentation and conditional advice; preserve output bytes, refusal status and rollback dispatch.
- Share copied-gate, Vulkan and UV fixtures without dropping existing assertions; remove measured duplication exceptions without increasing budgets or limits.

## 2026-10-23 — share Windows acquisition, copy and probe operations

- Share pinned lavapipe acquisition across host and image installers while retaining caller PE, ICD, registry and environment checks.
- Share disk-space probing without confusing measured zero with an unknown drive or changing stage refusal policies.
- Share bounded artifact-copy transport and temporary test environments while retaining caller flags, failure thresholds and no-scope behavior.
- Share source file-tree staging and ordered patch accounting while keeping file filters, changed diagnostics and fatal minimums.
- Share working-directory, fake-download and source-command fixtures with failure cleanup and real mutation controls.
- Fix wildcard interpretation in fixture cleanup; bracketed directory prefixes must be removed after both successful and failed bodies.
- Remove one resolved Windows duplication exception and lower four measured budgets without adding exceptions or weakening gates.
- Pass all 2,441 Windows tests and strict lint over 441 files; raise the discovery floor to 2,416.
- Verify 68 portable cases on Linux, the three deferred batch-setup faults and all four shared harness mutation gates.

## 2026-10-23 — classify the shared cache utility as a core leaf

- Register `compiler-cache-utils.sh` as L0 so the layer gate accepts its intended use by `common.sh` and enforces that the helper sources no core modules.
- Prove the classification and no-upward-import constraint with two mutations.

## 2026-10-23 — share Linux cache, dependency and packaging behavior

- Remove 14 measured duplication exemptions through shared cache probes, staged Python reporting, Debian metadata and test fixtures; keep scanner thresholds and scan scope unchanged.
- Carry cache utility companions in narrow base-image mounts and preserve caller startup, version, output and failure policies.
- Preserve exact metadata bytes, fixture status and existing assertions, with mutation proofs for the new shared behavior.
- Fix reversed-path duplication diagnostics and guard unique self-pair reports without changing enforcement counts.

## 2026-10-23 — share Windows preparation and environment lifetimes

- Share compiler-rt verification, extraction and library discovery while retaining base-stage warnings and source-build failures.
- Share source cache setup, portable ZIP tools, cross-protoc preparation and DLL dependency traversal with caller-specific policies.
- Share UV interpreter probes, Linux helper lookup and literal staging-directory setup without weakening required module imports.
- Restore temporary environments after partial setup or GenieX launch failure; apply sanitizer variables only to the test child.
- Share recursive silo log read grants and fixture allocation, batch-tool setup and mutation lifetimes; retain negative controls and cleanup assertions.
- Remove 24 Windows duplication exceptions (397 to 373) and lower 13 measured budgets without relaxing scan coverage or limits.
- Raise the Windows test-discovery minimum to 2,378 after all 2,403 merged tests passed.
- Preserve portable batch byte checks and native Windows execution, and update the Linux mutation receipt for all 38 harness cases.

## 2026-10-23 — restore portable harness mutation baselines

- Preserve all native batch execution checks in their separately discovered Windows suite, sharing fixture construction and mutation lifecycle.
- Verify exact ASCII/CRLF batch bytes and real writer mutations in the shared harness suite, restoring all 28 cases on Linux without skips or command emulation.
- Retain quoted arguments, final exit and early-exit execution assertions for native Windows.

## 2026-10-23 — share Linux CLI, disk and workflow operations

- Share nonempty CLI argument handling and lint scope initialization; carry the existing CLI companion in copied library fixtures.
- Share core suffix, caller-directory, disk-probe and stage-publication operations while retaining ordering, raw values and caller failure policies.
- Share lane YAML queries and mutation fixtures without dropping cases; retain Linux multiword interpreter and Windows path policies.
- Share workflow document construction and Flatpak failure fixtures with unchanged assertions and exact generated YAML comparisons.
- Remove measured duplication exceptions and lower remaining budgets without relaxing thresholds or scan scope.

## 2026-10-23 — continue Windows source and workspace cleanup

- Remove three private ROCm suite path resolvers in favor of the shared source reader and isolated script workspace.
- Share build-log and Cargo target resolution while preserving external absolute paths and relative workspace roots.
- Share LLVM compiler identity capture across capture, baseline and candidate modes; pin real command arguments, output and status.
- Add workspace cleanup, malformed-source and path regressions; remove another resolved duplication exception without relaxing the gate.
- Raise the Windows discovery minimum to 2,318 for the expanded regression set.

## 2026-10-23 — share Linux artifact collection and probe execution

- Share WASM artifact collection and IREE Android runtime options while retaining caller build and argument policies.
- Share Ubuntu source-file enumeration without changing ordering or shell options.
- Share media artifact verdicts and paired-image probes; preserve symlink admission, empty-output guards and failure counts.
- Share Renovate rollback, logging-trap, module-shadow and ownership fixtures with unchanged assertions and mutation proofs.
- Share version-bump, provenance, lint and GenAI fixture setup; keep required worker functions distinct from optional definitions.
- Remove resolved duplication exemptions without increasing budgets or narrowing scan coverage.

## 2026-10-23 — share remaining Windows operations and fixtures

- Share Meson binaries, ARM per-file features, optional source edits, machine names, handoff transfers and sccache command lifecycle.
- Share compiler-wrapper environments, packaging cleanup, CMake diagnostics, Flutter links and lazy agentic configuration while preserving caller policies.
- Share host guards and diagnostic verdicts, rename evidence, directory rows and replay traces; retain exact streams and failure cleanup.
- Bind required module companions into each owner scope without forcing reloads; preserve cold and warm visibility and fail on missing dependencies.
- Carry diagnostic companions through narrow probe Dockerfile mounts and prove their import layout with missing-companion controls.
- Share batch-tool, child-import, source-literal and mutation fixtures; keep parse/import failures separate from assertion failures and lower only measured duplication budgets.
- Raise the Windows discovery minimum to 2,313 after a full run passed all 2,337 tests.

## 2026-10-23 — broaden Windows duplication cleanup

- Share GPU and Python probe transport, smoke scratch and verdicts, source-module lookup, TVM wheel packaging, bundle environment models and FFmpeg listing checks.
- Share host maintenance, isolation diagnostics, LLVM command plans and ONNX replay parsing; correct literal match counts and reject malformed host CIDR values.
- Share consumer timing, container transport, logging, benchmark rendering, runtime copies, path resolution and signing conversion; keep caller failure, quoting and password policies.
- Share fixture state, fake-function lifetime, populated temporary directories and AST ancestry; retain independent expectations and add cold-import, regression and mutation proofs.
- Remove resolved Windows duplication exceptions and lower remaining budgets without changing scan scope or thresholds.
- Raise the Windows test-discovery minimum to 2,252 after measuring 2,275 passing tests.

## 2026-10-23 — share Linux provenance and verification fixtures

- Share ORT and GenAI byte-verdict logic through the existing provenance owner, retaining distinct archive and exemption policies.
- Share TVM wheel and ancestry test execution while preserving failure statuses and every assertion.
- Share Ubuntu mirror error aggregation; retain all probes and prove failure propagation with mutations.
- Remove resolved duplication exemptions without changing scan coverage or frozen budgets.

## 2026-10-23 — share Linux cache, payload and lifecycle behavior

- Share side-effect-free cache policy and statistics, with explicit companions in narrow compiler mounts and media copies.
- Share the optional package payload inventory while preserving fourteen copies, five advisory observations and all three Dockerfile closures.
- Reuse Android patch dispatch, optional media stripping and production lifecycle predicates; retain guards, failure policies and child cleanup.
- Add offline characterization and mutation proofs and remove resolved duplication exemptions without relaxing gates.

## 2026-10-23 — repair portable CI fixture baselines

- Remove accidental ripgrep requirements from six Linux fixture suites and require exact no-match status in negative searches.
- Add a restricted-PATH regression with all 244 existing assertions and mutation proofs for missing search tools.
- Normalize the approved Windows harness file-tree join through the PowerShell provider; retain all nine fixture cases and three lifecycle mutation proofs.
- Preserve the Linux duplication cleanup while fixing the failing develop preflight and mutation baselines, without skips or relaxed gates.

## 2026-10-23 — share native builds and verification targets

- Share native ONNX build and wheel collection while preserving CPU retries, AMD invocation and original failure status.
- Share cross-verification target selection and normalization; preserve caller fallbacks, diagnostics, resolver failures and architecture restoration.
- Share LiteRT web vendoring and real lint-consumer fixtures with independent expected results.
- Share bounded GCC release downloads, compiler-cache help and unknown-option diagnostics while retaining caller arguments and command policies.
- Add characterization and mutation proofs; remove resolved Linux duplication exemptions without changing Windows source or gate thresholds.

## 2026-10-23 — share Linux initialization and web probes

- Share toolchain companion lookup and compiler-cache launcher fixtures while preserving per-caller precedence, fallback and source failure behavior.
- Share required framework/platform initialization with explicit build companions and narrow Dockerfile wiring.
- Share Flutter HTTP and size probes while preserving diagnostics, strict thresholds and curl exit codes; add baseline characterization and mutations.
- Remove resolved Linux duplication exemptions and two obsolete ShellCheck warning freezes without increasing budgets or changing Windows source.

## 2026-10-23 — reduce Windows behavior duplication

- Share source-archive extraction while keeping strict failures, pinned dangerous-link checks and optional tar cleanup.
- Share ORT chain file indexing while preserving each gate's recursion, filename and unreadable-file policies.
- Share Flutter plugin patching and artifact-copy lifecycle; retain idempotence, CMake-state exclusions and robocopy warnings.
- Share sccache diagnostic startup, compile/source setup and stats parsing while keeping environment choices and verdicts per mode.
- Share Python CI tool and child-driver fixtures; preserve exit status, quoting, call-log isolation and caller-specific summaries.
- Add focused regression and mutation proofs; remove resolved duplication exceptions and lower remaining budgets without relaxing the scan.

## 2026-10-23 — continue Linux quality and runtime deduplication

- Share host architecture probing with unchanged target/build precedence and failure fallbacks; reuse host Python version selection and ordered LLVM builder discovery.
- Share C++/tidy file traversal and compiler-cache fixtures while preserving configuration, exclusion, launcher and environment policies.
- Share runtime shell transport and scalar metadata lookup, retaining wrapper bytes, Python guards and required/advisory verdicts.
- Share critical-fix predicates and record parsing; preserve regression proofs through mutation retargeting and add local characterization tests.
- Share GHCR version metadata through a required standard-library companion; retain dry-run, age and kept-index protection, verified with offline fixtures.
- Remove resolved Linux duplication exemptions and lower remaining budgets; Windows source remains untouched.

## 2026-10-23 — share Linux smoke and verification behavior

- Share Android/compiler object probe lifecycle while preserving C programs and ELF verdict policies; reject allocation and cleanup failures.
- Share ONNX media probe dispatch while retaining required Runtime, optional GenAI and CPU-provider checks.
- Share argument declaration traversal and fatal reporting, retaining exact counts, pin exemptions and diagnostics.
- Share disk-guard and audit fixtures with independent inputs and rollback assertions; add regressions and mutation proofs.
- Remove resolved duplication exemptions and lower remaining budgets without editing Windows source or changing thresholds.

## 2026-10-23 — continue Linux duplication cleanup

- Share named-option dispatch across Linux build parsers while preserving aliases, raw values, nameref destinations, consumption and diagnostics.
- Share best-effort repository fetching through the existing download companion; keep generic and TVM checkout failure policies distinct.
- Share compiler ELF fallback verdicts and fatal/advisory failure handling without changing diagnostics.
- Share TVM argument fixtures and parallel-loop child setup while retaining independent expected results and failure cases.
- Add characterization and mutation proofs; shrink duplication exceptions without editing Windows source or changing scan coverage.

## 2026-10-23 — expand parallel duplication cleanup

- Share Torch wheelhouse preparation and collection; propagate previously swallowed sysconfig, wheel repair, retagging and copy failures.
- Share GStreamer cross-compiler initialization while preserving stage-only libstdc++ repair, legacy fallback and pinning.
- Share Windows formatting discovery and executable lookup, preserving distinct C/C++ and Dart policies; report missing clang-format correctly under strict mode.
- Share Windows lint traversal and diagnostics, retry fixtures, FFmpeg listings and OpenCV AST wiring checks; preserve all existing cases and platform failures.
- Share healthcheck tool probes, stage-log verdicts and warm-build fixtures; reuse directory creation for the CUDA cache diagnostic.
- Group Python requirement hashes and share lifted-module lifecycle while preserving constructor/body arguments and cleanup on failure.
- Add focused regressions and mutation proofs; remove resolved exemptions and lower remaining budgets without changing thresholds or scan coverage.

## 2026-10-23 — parallel duplication cleanup

- Share cross-Python context, directory lookup and pkg-config suffix composition while preserving staged precedence, argument forwarding and failure paths; share the foreign-target guard without changing raw comparisons or errexit.
- Share Vulkan target launch arguments and component accounting; retain command traces, required-component failures, loader WSI checks and glslang shared/static order.
- Share Windows architecture, artifact and UV test fixtures, preserving malformed binary layouts, child exit-code checks, caller-owned errors and package-specific assertions.
- Share workflow YAML fixture builders and wheel-metadata fixtures; preserve malformed cases and strengthen the metadata-header boundary proof.
- Add local regression and mutation proofs; remove resolved duplication exemptions without changing scan coverage or thresholds.

## 2026-10-23 — share compiler selection, logging and OCI fixtures

- TVM compiler validation and selection share pinned-name and fallback resolution; preserve overrides, wrapper inputs and missing-tool failures.
- Share plain and colored log-prefix formatting, retaining byte sequences, severity labels, streams, NO_COLOR precedence and fatal error behavior.
- Share parent-context and no-push guard fixtures while retaining the OCI handoff cases; remove the three resolved duplication exemptions and the obsolete ShellCheck warning freeze, and add mutation proofs.

## 2026-10-23 — share Linux bundle packaging lifetime

- Keep the three public packaging APIs and format layouts while sharing scoped facts, bundle copying, desktop/icon staging, architecture validation and the final artifact verdict.
- Preserve renderer failures and Bash errexit, including an early AppImage copy failure; prevent stale artifacts from turning failed renderers green.
- Add local dispatch, architecture and staging regressions with mutation proofs; retain existing archive and Flatpak checks, remove the packaging self-duplication exemption and lower the remaining cross-file budget.

## 2026-10-23 — share ONNX web build and codec-ratchet operations

- Share the three lockfile-exact npm retries and both JS artifact verdicts in the ONNX web step; retain directory order, diagnostics, fatal failures and extension-specific copies.
- Exercise the full step with stubbed npm, sleep and cleanup, using the real logging library; verify the same 53 assertions against the previous implementation.
- Share codec package set differences while preserving both directions of its ratchet; add mutation proofs and remove the resolved duplication exemptions.

## 2026-10-23 — share module visibility and ONNX smoke fixtures

- Re-export and build-call closure suites share a fresh-session module probe; discover declarations through parsed ASTs and retain child exit codes, diagnostics and isolation.
- Use one ONNX inference stub for generated-program and transported-program checks; both reject empty or truncated models.
- Remove resolved duplication exceptions and cover missing exports, import failures and quoted paths with local fixtures and a mutation proof.

## 2026-10-23 — share agentic phases and backlog counting

- Share command execution, log redirection and dry-run handling across build, test and quality phases; preserve their distinct failure policies.
- Share task-state counting and remove the agentic-loop self-duplication exemption; cover local execution and backlog contracts with regressions and mutations.

## 2026-10-23 — consolidate Windows source patch families

- GStreamer, IREE, LiteRT-LM, C++ keyword conversion and Ninja cleanup share the patch API's file and verdict handling; keep default warnings and caller-owned counters with an optional diagnostic-only quiet mode.
- Fix repeated OpenCV 5 header insertion by using the instance regex match-count overload; cover it with local fixtures and a replace-all mutation.
- Share patch diagnostic fixtures and index Dockerfile stages during parsing; preserve existing platform failures and remove resolved duplication exemptions.

## 2026-10-23 — share cross and Canadian GCC builder invocation

- Cross GCC and Canadian native GCC share builder argument construction and invocation, retaining environment, job counts, sysroot, caching and host distinctions.
- Fail ordinary cross builds explicitly even under conditional callers with stale installed tools; preserve the Canadian link-skip policy and fatal diagnostic.
- Fake-builder regressions and seven mutations cover the invocation contract; remove the GCC self-duplication exemption.

## 2026-10-23 — share critical source-pattern verdicts

- Twelve positive source-pattern checks share grep execution and PASS/FAIL aggregation; keep caller patterns and messages, compound conditions, negative checks and final failure propagation.
- Add local regressions and three mutation proofs for successful matches, failed probes, argument forwarding and accumulated failures; shrink the gate's duplication budget from 46 to 33 shingles.

## 2026-10-23 — share common runtime and cross CLI dispatch

- Architecture aliases, mirrors, global options and help have one dispatcher; preserve public parser signatures, nameref outputs, value validation and argument counts.
- Expand the parser suite to 81 assertions and add four mutation proofs; reduce its self-duplication budget from 43 to 21 shingles.

## 2026-10-23 — consolidate Windows test fixture families

- Windows suites share prefixed temporary-directory allocation and exception assertions through the existing harness; retain their import scope and cleanup lifecycle.
- Compare affected suites before and after the refactor; add harness lifecycle and mutation regressions. OpenCV builders let Git create checkout parents, covered by a local clone regression.
- Shrink duplication budgets and remove resolved pairs without changing detector thresholds or coverage.

## 2026-10-23 — share isolated Python CI test trees

- Four Python CI suites share temporary script-tree creation, source copying and workspace detection through the test harness; each retains its tool stubs and assertions.
- Harness regressions and four mutations cover paths, copied bytes, workspace binding and missing inputs; remove all six duplication exemptions between these suites.

## 2026-10-23 — share Android CMake target arguments

- IREE, LiteRT and OpenCV use one array builder for NDK toolchain, ABI and API arguments, preserving project flags and failure policies.
- Local argument fixtures and four mutations cover target selection and paths with spaces; remove the IREE/LiteRT duplication exemption and reduce IREE's remaining self-budget.

## 2026-10-23 — share LLVM source-cache validation

- Native and cross LLVM builds share checkout readiness and stale-generation eviction in `common.sh`, preserving their fetch methods and build-directory policies.
- Local Git fixtures and four mutations cover interrupted clones, missing LLVM trees, eviction scope and eviction failure; remove the duplication exemption between the two builders.

## 2026-10-23 — consolidate compiler identity and pinned Hailo sources

- Share Clang embedded-version parsing in `platform.sh`; preserve metadata priority,
  Debian epoch handling, CLI fallback and the validator's nonfatal probe policy.
- Share Hailo/TAPPAS exact-commit cloning and verified archive extraction; preserve
  submodule, header-copy, cache and strip-component policies. Remove both resolved
  duplication exemptions without changing detector thresholds or coverage.
- Propagate download failures explicitly before hashing; a conditional caller may
  not extract a stale cached archive after a failed fetch, even if its hash matches.

## 2026-10-23 — restore library baselines and bound runtime heartbeats

- Load shared logging from `project-env.sh` when sourced standalone, restoring the
  library census and its mutation baselines without weakening their assertions.
- Start no heartbeat for runtime dry runs. Terminate and reap the current sleep
  child directly, closing the signal window before a separate PID assignment.
- Isolate GPU graph fixtures from runner caches and registry lookups; reject any
  container CLI execution and reproduce the heartbeat race with bounded processes.

## 2026-10-23 — isolate old container-store husks during host cleanup

- Add `Clear-DiskSpace.ps1 -StoreHusksOnly`: exactly the three existing renamed-store
  directory patterns, report-only by default, with daemon calls disabled and TEMP/logs/scratch
  excluded. Refuse incomplete reparse scans and recheck each candidate before deletion.
- Exercise the actual cleanup functions with recorded operations, unreadable traversal and
  a newly unsafe tree; retain protected-root, junction and age-gate regression coverage.

## 2026-10-23 — groom the open backlogs against merged evidence

- Remove completed Omni fallback-font work and F1; retain dated closure evidence and archive
  Windows history while keeping unfinished cache and QNN-device checks open. Retire the old
  general registry decision using recorded published images and device-consumer execution.
- Separate proved default-image Python/ORT and x64 GTK results from outstanding foreign-arch,
  GPU and hardware checks. Keep the unresolved build-host Chrome HTTP stall distinct from
  its repaired cleanup race. Correct the remaining file-size queue and advisory status.

## 2026-10-23 — preserve failure paths while reducing quality freezes

- Store Windows SIMD flags, MLAS match patterns and match floors in the existing
  target fact table; retain distinct global/kernel values and isolate returned copies.
- Share Windows test AST command queries and parameter binding. Move structural
  suites onto the harness parsers so malformed input fails before declaration checks.

- Share CMake/CTest Git and Vulkan setup in a passive project-environment library;
  preserve SDK hook precedence, Git opt-out and advisory configuration failures.
- Remove GStreamer's private cross-mode fallback; require the guard already validated
  by media initialization and test native/cross decisions and incomplete closures.
- Share Renovate argument parsing, repository validation and submodule enumeration;
  preserve local/fleet dry-run differences, branch policies and recursive discovery.

- Share PowerShell fixture AST parsing for files and snippets; reject malformed inputs
  without executing build scripts and preserve function-extraction diagnostics.
- Share Windows source-patch reads and write verdicts, and OpenCV's written-source
  assertions. Retain regex/callback semantics, idempotence, caller diagnostics and
  refusal of missing files or incomplete required edits; add fixture coverage.
- Share ELF strip execution across media helpers, minimal toolchain setup and GCC;
  preserve host/target passes and carry the leaf in narrow GCC/LLVM build closures.
  Preserve filenames with spaces and avoid invoking strip for an empty selection.
- Share pin-parity site validation and default comparisons; retain environment AST
  policies, case sensitivity, stale-exception checks and distinct `v` trimming rules.

- Share shell CLI value parsing across app, CMake and CTest runners; retain argument
  policies and fail promptly on missing values. Share Windows ORT lock parsing and
  carry its module into the image. Remove the two resolved duplication exemptions.
- Require FFmpeg's existing compiler-resolution module and remove its private host
  resolver/wrapper fallbacks. Preserve isolated PATH, tool prefix and resolver failures.
- Remove private Windows smoke version/VS helper copies; require the canonical module
  already shipped in the image and live smoke mount. Test incomplete-closure refusal.
- Share stubbed-library capture and command logs between Flatpak and ownership tests,
  retaining their expected results and per-case environment overrides.
- Share pin-scanner command/default discovery and compiler smoke command cleanup;
  retain environment AST policies, object ELF checks and failure diagnostics.

- Share Windows app/test executable lookup while preserving caller-specific directory
  order and path normalization. Remove its duplication exemption; add four fixture cases
  and verify ordering, normalization and recursive-fallback mutations fail.

- Share Vulkan header/loader SDK search order, including paths with spaces.
- Share FFmpeg compile/link probe setup and cleanup; retain compile-only, debug and cross flags.
- Remove runtime path-helper copies, share Android SDK retries, lint release bootstrap
  and ancestry annotation validation. Preserve host library precedence, retry verdicts,
  per-tool PATH policies and checksum refusal; add stubbed regression coverage.

- Share ONNX/GenAI transport and verdict handling, consumer version comparisons and pin reads.
  The GenAI payload suite now executes the production wrapper.
- Preserve cache setup exports and separate diagnostics from the resolved launcher path.
- Share TVM CMake forwarding and Vulkan/SPIRV lookup, ORT dependency and GPU cache setup,
  and package/smoke artifact-context selection. Preserve their distinct flags and priorities.
- Share bounded compiler-signature scans, Python bundle/package CLI parsing and host-tool
  unknown-option diagnostics. Remove stale duplication freezes and lower remaining budgets.
- Add regression suites for these boundaries and mutation proofs for refusal and ordering paths.

- Remove the last complexity exceptions; every function meets branch and nesting limits.
- Split host storage policies and Vulkan provisioning from their drivers, and split runtime
  test cases without changing their execution order. Remove three file-size exceptions.
- Replace runtime symptom dispatch with a lookup and separate row and architecture verdicts.
  Preserve all 341 runtime assertions; add offline storage and SDK archive regression cases.
- Exclude GCC pretty-printer files before runtime library selection; quote fixture arguments
  and preserve stderr capture while removing five more ShellCheck exceptions.

- Resource monitoring preserves spaces in log paths, keeps marked-stage priority and retains
  the original exit status when summary generation fails; remove both ShellCheck freezes.

- Separate GStreamer Python flags, architecture flags, Rust configuration and plugin exclusions.
  Golden behavior checks pass against both the original and refactored functions.
- Preserve OpenCV's GStreamer library lookup order, ORT argument aliases and missing-value
  diagnostics, and native/cross Arm NN OpenMP links and ACL installation verification.
- Separate stage handoff bookkeeping, stop-command PID selection and manifest generation
  diagnostics. Lifecycle and provenance refusal suites retain their failure assertions.
- A failed TensorFlow pkg-config write now returns failure before writing the SDK completion
  stamp. A retry replaces partial SDK trees without nesting them. Complete, corrupt, partial,
  metadata-failure and retry archives have regression coverage.
