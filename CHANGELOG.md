# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-08-29 … 2026-09-07`](docs/changelog-archive-2026-09-07.md) ·
> [`2026-08-14 … 2026-08-28`](docs/changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.


## 2026-09-15 — the audit's second hub batch: the owner's decisions, executed

The 2026-09-14 family audit left 33 open items against this repository and
twelve questions for the owner. The answers came back; this is the hub's side of
them. Cross-repo halves (the consumer wrappers, the OrchestrANT copy of the NAS
census, the dartdoc fork deletion, the Flutter lane rewrite) are a separate pass
— every hub-side helper they need exists now.

### The owner's decisions

**D1. The home-lab stacks stay, and the README says so.** `linux/homeassistant/`
and `linux/nextcloud-aio/` are the owner's personal operations stacks, carried
here deliberately. README.md states that under its own heading, with the
consequence spelled out: anything claiming this repository is build
infrastructure ONLY is false. The h4 that claimed exactly that is rewritten to
what the tree actually holds.

**D9. `linux/webserver/dist/` stops being tracked.** 82 MB of minified Flutter
output, built in another repository, rewritten in full on every site build, and
unrebuildable by anything here. The image takes it from a named BUILD CONTEXT
now (`COPY --from=site`, `--build-context site=<jot>/build/web`), and a build
that names no `site` context fails at that line rather than serving nothing.
`git rm -r --cached` only — the files stay on disk. `license-assets/` stays
TRACKED, against the item text: it is 48 KB, this repo GENERATES it, and a live
gate checks it is current.

**D8. The NAS document-AI thread leaves for OrchestrANT.** `nas_census.py`, its
suite and `nas-document-ai.md` are removed here, with their mutations, their
allow row and their family, and every reference repointed. The consumer side is
a later pass; the files are recoverable from this commit's parent.

**D4. The repository size is documented, not rewritten.** `project-info.md` now
says what is large (nothing, after D9), why the pack is still ~154 MB (dist's
history) and why no `filter-repo` runs: it would change every commit id, break
the gitlink in six consumers and every SHA in every changelog entry, to save a
one-time clone cost measured in seconds.

**D10. AGENTS.md is 900 lines, down from 1863.** Nothing was deleted. Every
paragraph either stayed because it is a RULE an agent must not break, or landed
in the docs page that owns its topic with a link back — the Validation
measurements to `linux-host-setup.md` § B7/B8, the caching mechanism to
`build-cache-tiers.md` and `windows-build-resources.md`, the command reference to
`linux-cross-builds.md`, the Repo Map's per-file detail to
`shared-script-libraries.md`, and so on. § Contents states the split, so the next
reader knows which side a new paragraph belongs on.

**A089, decided by Claude because the item recommended it.**
`renovate-fleet.sh --vendored` is an opt-in mode for the two cases that are not
the accident the default protects against: a repo of the owner's with no own
checkout anywhere, and a container that mounts a single superproject.

### The scan-root contract reaches the docs gates

`doc-links`, `doc-dupes` and `code-dupes` resolved their root from `__file__`,
so in a consumer's `third_party/ANTfrastructure` checkout they graded THIS
repository and reported that as the consumer's verdict. All three take `--root`
now, keep their current behaviour exactly when the root is the hub, and read
their budget from `<root>/<gate>.allow` otherwise. `doc-links` joins the
`--ratchets` step — it is the only one with no budget to seed — which is what
finally puts a consumer's own `README.md` into the cross-reference graph.

Ten gates gained a `--root` test case and a
`<gate>.root-argument-is-the-tree` mutation; nine are verified to bite (the
tenth needs shellcheck, which this image has not). That needed a fixture the
suites did not have: every existing one plants a tree AROUND the gate, so the
gate cannot tell it from its own repo. `gate-tree.sh` grows `gate_tree_git` plus
two assertion helpers, because ten hand-copied blocks are what the code-dupes
gate exists to catch.

### The upstream halves the consumer forks were waiting on

A Flutter lane prologue and an HTTP-readiness helper (three consumers had each
written the poll loop; this one RETURNS rather than exits, so the nginx caller
can still dump its logs). `run-in-ci-image.sh`, which is the hand-typed
`docker run` every README carried, once — with the Git Bash path-mangling escape
exported rather than documented, because a note nobody reads is how that keeps
being rediscovered. A cmake-format venv DEFAULT instead of an error. MSIX
orchestration (`Invoke-MsixPackage`, `Get-PackageVersion`) with the assertion
that makeappx actually produced a file. `export_clang_gcc_toolchain_env`
restored, with a prefix resolver that probes for `crtbeginS.o` instead of
trusting a composed path. The WebDAV downloader moved to `01-core/` with its
client PINNED, so both lanes install the same one. `STATIC_ANALYSIS_EXTRA_PATHS`
and `CARGO_CLIPPY_ARGS`, the two knobs whose absence made consumers hand-roll
the drivers.

### Gates and hooks

One Python-probe owner for `lint-python.sh` and the versioned hooks: eight bare
`python3` call sites, one of which was silently turning the embedded-Python
extractor into a no-op on a Windows host. The consumer inventory can see the
half of the fleet it was blind to — backslash-spelled hub paths, and the three
shapes that reach a PowerShell module by NAME. A weekly failure now files an
issue instead of reporting to nobody. The delete guard stops listing two
repository checkouts that have not existed since the 2026-09-12 rename.

Budgets moved with the code and every one is recorded at the measurement, with
the cause: six code-dupes budgets re-measured after the corpus grew, seven rows
retired as stale, seven added, two doc-dupes rule/mechanism pairs budgeted,
`renovate-fleet.sh` frozen at 814 lines with the not-a-split argument, six
comment-size headers frozen, and three new operator knobs registered.

## 2026-09-14 — family audit: the hub's side of the fixes

A cross-repo audit of all nine consumers against this hub (reuse, duplication,
docs freshness, naming, quality-gate reuse, topic separation) landed the hub
half of its mechanical fixes here; the consumer halves are one commit per repo.

* **Three files the 2026-09-08 "no consumer" sweep (2eaed40e) deleted are
  back**: `windows/scripts/modules/WindowsOnnx.Common.psm1` (AccelerANTgine's
  `Build-Windows.ps1` imports it by NAME; its Windows lane was red from the pin
  bump that carried the deletion), `windows/scripts/modules/WindowsContainerLog.Common.psm1`
  and `windows/scripts/rust/New-Archive.ps1` (OxidANT reaches both by path).
  The consumer inventory gains a `windows-lang-script` class for
  `windows/scripts/rust/*.ps1` (the `windows/scripts/*.ps1` glob is
  non-recursive, so nothing graded them), and AGENTS.md § Contributing
  Reusable Work Here now carries the rule: a hub file is deleted only when the
  inventory reports it *named by nobody*.
* **`.github/consumers.json`**: WebDavClient is a confirmed consumer (verified
  against a clone; it still calls the python-ci lanes under the pre-rename
  `Kataglyphis-ContainerHub` name, which is its own migration item); the
  `unconfirmed` array is empty (AccelerANTgine and ANThology were already
  confirmed rows); the OxidANT and AccelerANTgine notes say what those repos
  actually do.
* **`Sync-UvProjectDependencies` excludes the extras that `[tool.uv] conflicts`
  forbid** (`Get-UvConflictGroups`, `Get-UvExtrasToExclude`, `UV_SYNC_EXTRAS`
  override), the port of `python_uv.sh`'s `_uv_extras_to_exclude` — OrchestrANT's
  Windows lane had failed on `uv sync --all-extras` since 2026-09-12 while the
  Linux twin routed around it. Pinned by `Uv.ConflictExtras.Tests.ps1`.
* **`run-lint-gates.sh --ratchets`** (opt-in): the eight `--root` measurement
  gates over the consumer tree, freeze files at `<root>/<gate>.allow`; no
  consumer had run any of them. The consumer-pins gate and the new step run
  under `PREFLIGHT_PYTHON` instead of a bare `python3`, through the probe
  `lint-workflows.sh` had carried inline — now `01-core/python-probe.sh`
  (`preflight_python_require`), the one owner both call, and it accepts a
  command-line value such as `uv run --no-project python`, which is the hint the
  failure message itself gives. `gate_scope.tracked()` pins `encoding="utf-8"`
  (a non-ASCII tracked path aborted every `*`-scoped gate on a cp1252 host).
* **Two reusable lanes**: `.github/workflows/lint-gates.yml` (`workflow_call`;
  inputs `exclude`, `submodules`, `hub-checkout`, `ratchets`) replaces the seven
  consumer copies of the lint job, and `submodule-pins.yml` gained
  `workflow_call` (inputs `suite-path`, `pester-version`, `runner`) so the three
  consumer copies collapse to one `uses:` line.
* **`deploy-over-ftp` has callers**: `build-docs.yml` and `python-ci-linux.yml`
  publish through it (their own `chmod -R 755` steps are gone with it), and
  `actions-selftest.yml` names every input in a guarded step so actionlint
  holds the contract. `docs/ftp-deploys.md` and `.github/actions/README.md`
  say so.
* **`.gitattributes`** pins the extensionless bash files
  (`linux/host-config/git-hooks/*`, `linux/nextcloud-aio/custom-bin/*`), the
  Linux build context's text files (`linux/Dockerfile*`, `*.txt`, `*.allow`) and
  the Python gates (`linux/**/*.py`, `docs/**/*.py`, `.claude/**/*.py`) to LF: a
  `core.autocrlf=true` checkout materialised them CRLF, and preflight's
  crlf-guard, shellcheck, android-parity and `test-advertised-keys.sh` (its
  fixture mutates a gate with a `$`-anchored sed) went red on every Windows host
  bind-mount while Linux CI stayed green.
* **Docs**: `adopting-in-a-new-project.md` gains § 9 *Quality gates* (manifest,
  aggregator, pin suite, python-ci lanes) and four checklist rows, and stops
  claiming a layout uniform "across all seven consumers" (the two Linux-only
  Flutter repos keep a flat `scripts/`); `shared/templates/README.md` describes
  the six-section AGENTS template it ships; `docs/INDEX.md` cites a
  BeschleunigerBallett passage that still exists; `dependency-updates.md` names
  `GITHUB_COM_TOKEN` for `--platform=local` (three sites said `RENOVATE_TOKEN`,
  which is why four consumers had measured and retyped the correction);
  `shared-script-libraries.md` documents six lint gates, not three; stale counts
  in AGENTS.md (12 actions; the pre-commit mutation cap), README.md (no
  hard-coded slug count), `.github/actions/README.md` and `ci-build-triggers.md`
  (`llm-stack-serving.yml`, the pins/selftest/inventory workflows) corrected;
  the consumer-inventory examples say `/c/GitHub`; a broken link in
  `shared/linux/templates/README.md` fixed.


## 2026-09-12 (night) — Home Assistant hardening pass

* **Energy dashboard repaired**: solar is back on the Growatt inverter
  (`sensor.hannemann_total_energy_today`) and the Tasmota smartmeter counters
  are the grid import/export source, after `homeassistant.customize` gave them
  `kWh`/`total_increasing`/`energy` metadata.
* **Security/runtime**: login ban threshold 5 (was −1 = off), recorder
  `commit_interval: 30`, `stop_grace_period: 60s`, `privileged` and
  `/run/dbus` dropped — the latter silences the BlueZ D-Bus spam, since a
  rootless container cannot authenticate to the host bus anyway.
* **Cleanup**: 5 stale `mobile_app` registrations and the 2 Bluetooth adapter
  entries deleted; dead `sleep_for_90sec`, the missing `themes/` include,
  `automationsBackup.yaml` and `.storage/tmp*` removed. The two
  `forecast_solar` entries are two arrays (10 kWp + 2.5 kWp), not duplicates,
  and both were kept.


## 2026-09-12 (evening) — the Home Assistant stack moves in

* **`linux/homeassistant/` now tracks the compose stack that lived in
  `~/Documents/homeassistant`** — compose plus the hand-written YAML and
  blueprints, with the volume rewritten to the relative `./config`. Live state
  (recorder DB, logs, `backups/`, `secrets.yaml`, `.storage/`) is gitignored and
  also excluded from every Docker build context, and the stale 455 MB `core`
  dump was deleted. `secrets.yaml.example` is the tracked template; the WoL MAC,
  the F@H SSH commands and the alert address live in the gitignored
  `secrets.yaml` as whole-value `!secret` nodes, and the three stale-device
  automations plus the unwanted high-power F@H stop were removed.
* All remaining automations were dropped at the owner's request —
  `automations.yaml` is `[]` — leaving the WoL switch and the `shell_command`
  services callable from the UI.
* **Two pre-existing reds cleared on the way**, because the newly installed
  pre-commit hook runs whole-tree gates: the three `shared/*/templates/README.md`
  pages lost their duplicated table boilerplate (code-dupes), and
  `gate-proofs.allow` shed the 19 mutation families the benchmark lab took to
  OrchestrANT, with `docs/code-quality-gates.md` regenerated (gate-registry).


## 2026-09-12 (later still) — the benchmark lab leaves for OrchestrANT

* **The measurement suite, the viewer and the tracked results moved out of
  `linux/llm-stack/`** to OrchestrANT (`benchmarks/`, with the runner in the
  `orchestrant.benchmark` package). This repo keeps the serving stack,
  `backends.json` — the registry both host tooling and the benchmarks consume —
  and `nas_census.py`. `llm-stack-tests.yml` becomes `llm-stack-serving.yml`:
  the compose files parse, the registry keeps its default and GenieX lanes, and
  the NAS census test still runs.
* The roadmap and panel-review pages, ~200 mutation entries, the size
  allowlists, the doc-link test fixtures and every prose pointer moved with the
  lab; the two gate tests that pinned `linux/llm-stack`'s scan membership now
  pin the NAS file that stayed.


## 2026-09-12 (latest) — the pre-existing CI reds, fixed

* **The composite-actions self-test could not find its own local actions.**
  Three jobs called `./.github/actions/...` with no checkout ahead of them, so
  GitHub searched an empty workspace. Each now bootstraps the repository first;
  the actions under test still do their own checkout.
* **The consumer inventory failed on its own test fixtures.** `dangling_refs`
  now skips `linux/scripts/tests/` and `windows/scripts/tests/`: those suites
  build fake consumer trees full of paths that must not exist, and a real call
  in a test fails the suite itself.
* **And on vendored submodule paths.** A fresh clone leaves
  `third_party/DocumANTation/` empty, so a reference into it read as dangling;
  paths declared in `.gitmodules` are now outside the check.
* **The version snapshot failed on the DocumANTation Dockerfile.** The pin was
  behind, so its `ARG` defaults had drifted from versions.env; bumped to the
  rename commit.
* **The SIGPIPE case in test-renovate-exit.sh was a race, not a defect.** A
  closed pipe ends the run through the PIPE trap (141) or through bash's
  EPIPE-on-builtin path (1); the test accepts both and still asserts the tree is
  intact, which is the part that must not vary. New helper:
  `t_assert_contains_any`.


## 2026-09-12 (later) — the hub is now ANTfrastructure

* **`Kataglyphis/ContainerHub` is renamed to `Kataglyphis/ANTfrastructure`.**
  GitHub redirects the old URLs so nothing breaks in flight, but the whole
  family is swept in the same change: every URL, `uses:` ref and Renovate
  `github>` preset; the submodule path (`third_party/ANTfrastructure`); the
  bash bootstrap (`shared/linux/templates/antfrastructure.sh`,
  `antfrastructure_path` / `antfrastructure_source` / `antfrastructure_exec`);
  the `CONTAINERHUB_*` environment variables; and the per-consumer
  `.antfrastructure-shared.manifest`. The rename starts here because this repo
  owns the template every consumer copies.


## 2026-09-12 — merge cleanup: the CI reds the Renovate merge left behind

* Eight preflight checks were red on `origin/main` after the Renovate merge;
  all fixed here: code-dupes (2 budgets tightened, 4 stale rows removed, the
  env-suite clone given one owner), SBOM regenerated, comment-size (6 new
  blocks frozen), code-size re-baselined after the `bump_versions.py` shrink,
  shellcheck SC2088 reworded, workflow-lint's spelled-out CI image ref replaced
  with the helper's name, and the six failing unit suites.
* The Windows job's failures were LiteRT-LM pin parity: `0.16.1 -> 0.17.0` and
  PROTOC `31.1 -> 35.1` in `Build-LitertLmFromSource.ps1`, plus the same
  LiteRT-LM default in `Build-LitertLmBazel.ps1`. The PinParity scanner also
  excluded `tests/` with Windows path separators only, so on Linux it scanned
  the test fixtures themselves.
* `verify_mutations.py --jobs > 1` raced: the first shard mutates the repo root
  in place while the other shards were still copying their mirrors, so a mirror
  could capture a mutated file and its baseline read as a vacuous bite. Mirrors
  are now materialized before any shard starts.
* The fleet suite's per-repo budget was 1s, which flaked on a loaded host (the
  repo before the slow one timed out too); it is 5s now, and the slow fixture
  still sleeps 20s so the verdict is unchanged.
* The hook itself carried a bug the new renovate suites exposed: git exports
  `GIT_DIR` to pre-commit, so fixtures that shell out to git operated on the
  superproject and the mutation sample failed under `git commit` while passing
  standalone. The hook clears `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE`/
  `GIT_PREFIX` before it runs anything.


## 2026-09-11 — android stage unblocked: every installed foreign arch gets a source

* **Symptom.** The android stage failed on all three arches within seconds:
  `libc6:i386=2.43-2ubuntu2.4` (fresh from archive) Breaks the foreign
  `libc6:arm64`/`riscv64=2.43-2ubuntu2.3` (frozen on ports) and apt had no
  source to upgrade them from.
* **Root cause.** The compiler base installs `libc6` for both foreign arches,
  but `Dockerfile.media`'s apt reset leaves sources for the build host and the
  current target only. A transient archive/ports sync gap (i386 2.4 vs
  arm64/riscv64 2.3, back in sync minutes later) then makes the i386 install
  unsatisfiable.
* **Fix.** `cross_ensure_installed_foreign_arch_sources` (`01-core/cross-apt.sh`)
  writes a per-arch ports source for every installed foreign arch that lacks
  one; `android-sdk.sh` calls it before `apt-get update`. Reproduced and
  validated against the real media-parent state in a container before coding.
* **Test.** `test-cross-apt.sh` covers the helper (ports arches only, existing
  file untouched, missing wiring = no-op) plus a whole-line wiring check on
  `android-sdk.sh`. Both mutations proven red — the first attempt at the wiring
  check passed with the call deleted because the helper's name appeared in a
  comment.
* **Two gates the fix flushed out.** `test-mirror-consistency`'s NOSITES fixture
  went blind because `command -v ubuntu_write_deb822_source` parsed as a call
  site; the scanner now skips `command -v`/`type -t`/`declare -F` probes, which
  could previously make a writer-less tree read green. `test-script-copy-coverage`
  needed `ubuntu-mirror.sh` in `KNOWN_BASE_PROVIDED` for Dockerfile.android
  (inherited from the compiler base).
* **Symptom entry:** [`docs/failure-modes.md`](docs/failure-modes.md#apt-libc6i386-install-is-unsatisfiable-after-an-archiveports-drift).


## 2026-09-11 (night) - ASan runtime staging follows the link policy

* **The build stages the runtime the link selected.** `Get-SanitizerRuntimeDlls`
  (WindowsCMake.Common) walked `clang-cl`-on-PATH first and returned LLVM's
  `clang_rt.*san*.dll`, while `cmake/Sanitizers.cmake` links Microsoft's
  import lib from the VS toolset; inside the Windows image every
  ASAN-instrumented build tool then died at load with
  `STATUS_ENTRYPOINT_NOT_FOUND` (`0xC0000139`). It now delegates to
  `Get-AsanRuntimeDirs` (WindowsTesting.Common), the one owner of the
  Msvc-first policy - no second root ordering to drift.
* **Regression covered:** `WindowsCMake.Common.Tests.ps1` pins the delegation
  and the empty-result array (full suite: 826/828; the 2 LiteRT-LM pin parity
  failures predate this change).


## 2026-09-11 (late) — bump_versions.py shrinks to the complement

* **The detection half is gone, the finishing half stays.** The script's tiers
  drop every key Renovate now owns and reports (23 entries out of SAFE/REPORT),
  about 80 lines of upstream-querying helpers with them, and the coverage
  audit learns `renovate_owned()` — a key is classified when it is in a tier,
  carries a `# renovate:` annotation, or is a non-version.
* **What it still does, on purpose:** paired `*_SHA256`/`*_COMMIT` refresh
  (`--write`/`--write-all`), the keys with no feed, the two registry digests,
  the artifact-gated TENSORFLOW_C check, and the slaved PROTOC derivation.
* **Measured after the shrink:** `--check` completes with **0 lookup failures
  and 0 unclassified keys**, and still reports the real outstanding bumps
  (pwsh, uv, node, ollama, pandoc, flutter, CUDA/cuDNN, both digests).
* **Pre-existing, not introduced:** `--audit-sha-pairs` fails on 11 scattered
  `*_SHA256` keys that predate this change (verified on HEAD); recorded here so
  the next sweep can classify them rather than rediscover them.

## 2026-09-11 (evening) — 68 -> 89: vendor JSON, PyPI twins and digests

* **Twenty-one more keys.** Three custom datasources (`custom.cuda` with an
  HTML-href fetch and a JSONata strip, `custom.vulkan`'s WINDOWS value,
  `custom.nuget`'s `tools.json`), a second customManager using the regex
  manager's `currentDigest` capture for `UBUNTU_DIGEST` /
  `WINDOWS_BASE_DIGEST`, `versioning=regex:...` for the 4-part PyPI twins
  (`nvidia-cudnn-cu13`, `tensorrt`) and for `protocolbuffers/protobuf`'s
  major.minor-only `31.1`, plus ROCm via `ROCm/TheRock` tags.
* **Two live iterations, both measured.** `format: plain` maps each LINE to a
  version, so CUDA needed the HTML fetcher; and `skipReason: invalid-value`
  named strict semver as the reason cuDNN, TensorRT and protoc were silently
  updateless.
* **Live report: 29 pending updates and zero lookup warnings** — including the
  two digest moves and the setuptools `<82` cap holding (no 84 proposal).
* **20 tracked keys remain annotation-free**, in documented classes: a slaved
  pin, feeds no datasource can serve (MIGraphX, flatpak branch, JRE selector,
  the libffi wrap), platform matrices with no feed, checksums/raw SHAs,
  artifact-gated and dated pins —
  [`docs/dependency-updates.md`](docs/dependency-updates.md#what-is-still-not-annotated-and-why).

## 2026-09-11 (later) — the local apply half can write versions.env

* **`custom.regex` becomes a writable manager for the self-contained keys.**
  `renovate_locator.find_annotated_env` anchors on the hint's `depName` and
  returns the KEY= line under it; `renovate_audit._parse_env` reads the file
  back independently. A KEY, not a dep name, identifies a leaf — the live
  dry-run immediately caught that `NODE_VERSION` and `RENOVATE_NODE_VERSION`
  share `depName=node`, which a dep-keyed parser had refused wholesale.
* **Which keys may be written is a file-scoped policy** in
  `.github/renovate.json`: approval by default, cleared for the Rust
  security-tool and Python build-executor installs, the npm web runtimes,
  `rust-lang/rust`, `cargo-c`, `APP_REF` and `syft`. On the live ANTfrastructure
  report that is 7 applicable rows and 13 refusals, exactly as intended.
* **`bump_versions.py` is demoted, not deleted:** it remains the lock tool for
  every coupled `*_SHA256`/`*_COMMIT` pin and the detector for the 41
  unannotated keys. New suite
  [`test-renovate-env.sh`](linux/scripts/tests/test-renovate-env.sh) covers the
  write, the refusal and the unreadable hint; all six Renovate suites stay
  green (201/87/105/98/15/11 assertions).

## 2026-09-11 — versions.env is 68 keys visible to Renovate, not 18

* **The annotation pass, verified against the real report.** `bump_versions.py`
  tracks 99 keys; 68 now carry a `# renovate:` annotation (up from 18). A live
  `renovate-local.sh --managers custom.regex .` resolved every one of them with
  **zero lookup warnings** and reported 20 pending updates — `uv 0.12.13`, LLVM
  `23.1.1`, LiteRT-LM `0.17.0`, ComputeLibrary `v53.3.0`, openh264 `2.6.0`,
  flutter `3.47.3`, syft `v1.51.1`, among others. The remaining 41 tracked keys
  are documented exclusions in
  [`docs/dependency-updates.md`](docs/dependency-updates.md#what-is-still-not-annotated-and-why):
  coupled `bump:hold` pairs, vendor indexes with no datasource, base/platform
  pins, untransformable tag shapes, deliberate same-major pins and checksums.
* **Every datasource was tag-shape checked first** (`git ls-remote`), then
  added: `github-tags`/`github-releases`, `pypi`, `npm`, `node-version`,
  `python-version`, `flutter-version`, `crate`. The customManager grew a
  `versioning=` capture with the standard `versioningTemplate`, needed by the
  two leading-zero tags (`ARM-software/armnn` `v26.07`,
  `microsoft/vcpkg` `2026.07.29`); `test-renovate-annotations.sh` now asserts
  the capture and the template cannot drift apart.
* **Two would-be wrong bumps are gated to match the writer's tiers:**
  `NODE_VERSION` within its major (`allowedVersions <27`) and
  `PYTHON_VERSION` within its minor (`<3.15`) — what `bump_versions.py` classes
  same-major/same-minor in SAFE.

## 2026-09-10 — the foreign Vulkan prefixes are two files from amd64

* **VK6 and VK7 closed, measured on both pushed digests.** `lib/` is 118 on
  amd64 and **123** on arm64 (`@sha256:f77f97fa`) and riscv64
  (`@sha256:028ce048`); `bin/` 52 everywhere; layers 9 / 10 / 10. The gap VK6
  opened at **72 files is now 2**, identically on both arches.
* **The entry's own fix would have made it worse.** `BUILD_SHARED_LIBS` is
  exclusive, not additive: ON alone gains 9 files and LOSES 6, because glslang
  guards three static installs behind `if(NOT BUILD_SHARED_LIBS)`. The vendor
  configures glslang twice into one prefix and the STATIC pass must land LAST,
  because the second install owns `lib/cmake/glslang` and therefore what
  `find_package(glslang)` describes. A test asserts the order, not just the
  presence.
* **Two files stay, both explained.** `VulkanLoader` is a layout difference the
  consumers already assume; `libshaderc_util.a` has no install rule and ships
  with no headers even on amd64, so it is unlinkable there too.
* **VK7 mirrors the vendor's own prune** and is guarded on `include/dxc/dxcapi.h`
  — without that marker the helper would `rm -rf include/llvm` out of whatever
  directory it is handed, and `/opt/llvm-target` holds 41 MB of real LLVM 23
  headers.
* **VK5 closed with them:** arm64's earlier number was measured against a tree
  that no longer existed. Both foreign arches now report `24/24` from the
  current one, with zero `unavailable on <arch>` lines.
* **EX1 closed too**, and the residual AS1 neighbours are latent (every cross
  stage builds on `linux/amd64`).

## 2026-09-09 (later) — all three arches ship 52 Vulkan binaries

* **VK4/VK5 closed: 52 = 52 = 52, and the foreign pair leads on layers.** Measured
  on the pushed digests with both directories listed in a container, not derived
  from a log: `bin/` 52 on amd64, arm64 (`@sha256:6eefc3c3`) and riscv64
  (`@sha256:1bdfbb3a`); `explicit_layer.d` 9 on amd64 and **10** on both foreign
  arches. Zero entries in either direction — the sets are identical, not just
  equal in size. `dxc`, `vkconfig`, `vkconfig-gui` and `llvm-tblgen` report ELF
  AArch64 / RISC-V, so none is a copied host binary.
* **The gap was never a build failure.** LunarG's `./vulkansdk` builds 24
  components under `all`; the HOST list named 18. A component not named there is
  never checked out, and the install helper returns before incrementing
  `_vk_attempted` — so the three missing ones were never counted as attempted and
  the verdict read a clean `N/N`. Four rows and three dynamic-arg arms later the
  table is 21 + 3 hardwired = 24, exactly the vendor's own `build_all` count.
* **`-Werror` on a warning this file already knew about.** `dxc` failed the first
  riscv64 run at `external/SPIRV-Tools/source/util/timer.h` on GCC 16's
  `-Warray-bounds`. Configure had completed, so LLVM 3.7 does know the riscv64
  host triple. `_vulkan_target_build_spirv_tools` had carried
  `-DSPIRV_WERROR=OFF` for that exact warning for ages; DXC vendors its own copy
  of SPIRV-Tools. The rebuild logged 164 such warnings on riscv64 and **93 on
  aarch64** — the fix saved both lanes, not one.
* **A vacuous success caught before it shipped.** VulkanTools does
  `find_package(Qt6 ... QUIET)` and, without Qt6, drops the whole configurator
  with a `message()` and exits 0 — the row would have counted as BUILT with no
  vkconfig in the image. `CMAKE_REQUIRE_FIND_PACKAGE_Qt6=TRUE` makes it honest.
* **A gate that was coin-flipping.** `verify-artifact-copy-parity.sh` failed ~1
  run in 10 on an unchanged tree, naming a different artifact each time. Both
  sets were byte-identical on a red run: the bug was `printf | grep -qxF`, whose
  status is not reliably 0 when `-q` exits early on a pipe. Replaced with a shell
  `case`; 200 runs green and both directions still redden.
* **Still open, both small:** VK6 (13 shared libraries the foreign arches do not
  get, caused by our own `ENABLE_OPT=OFF` / `SPIRV_CROSS_SHARED` flags) and VK7
  (11 DXC files they ship that the vendor prunes).

## 2026-09-09 — riscv64 reaches 20/20, and the apt pockets have to agree

* **VK2 is closed: 20/20 Vulkan cross-components on both foreign arches.**
  `Vulkan cross-targets riscv64: 20/20` (`sdk-rv64-20260908-211949`, pushed
  `@sha256:09a4d255`) and `aarch64: 20/20` (`sdk-20260908-132426`). Verified on
  the shipped bytes, not the log: `riscv64/bin` holds 37 entries and is a strict
  subset of `x86_64/bin`'s 52, and `vulkanCapsViewer`, `slangc`, `gfxrecon-info`
  and `vulkaninfo` all report ELF machine RISC-V. The 15-entry delta is entirely
  LunarG's prebuilt tarball (the DXC family, `llvm-tblgen`, `vkconfig`) — which no
  arch builds from source, and which is now VK4 rather than a regression.
* **The last blocker was not Qt and not riscv64: the host and target apt sources
  disagreed on a POCKET.** The compiler stage wrote `ubuntu.sources` for amd64
  **without** `-security` and `ubuntu-ports.sources` **with** it. Since
  `libcurl3t64-gnutls` is `Multi-Arch: same`, amd64 topped out at
  `8.18.0-1ubuntu2.4` while riscv64's candidate was `2.5`, no common version
  existed, and apt reported the DEPENDENT (`libappstream5:riscv64`) as
  unsatisfiable. Every `Multi-Arch: same` library with a security-only upload was
  affected; Qt6 was just the first to matter. Proven by A/B on the same base
  image, one line different.
* **Fixed in three places, because two of them are not enough.**
  `build_python.sh` and `Dockerfile.media` now write both halves with
  `-security`; `cross_align_host_apt_pockets` (cross-apt.sh) repairs an
  **inherited** skew at the point of use, so a stage benefits without its parent
  being rebuilt — which is why the riscv64 sdk stage could be fixed with no
  compiler rebuild. `archive.ubuntu.com` carries `<codename>-security` for amd64
  (HTTP 200), so the old `0` bought nothing.
* **The `mirror-consistency` gate now asserts the pair, not the literals.** It
  runs the real `ubuntu_write_deb822_source` for a host arch and a ports arch and
  requires the two suite sets to match, then parses every shipped call site with
  `shlex` and fails if they disagree on the flag. Neither file is invalid on its
  own, so nothing that reads one file at a time could ever have caught this.
* **`_apt_sources_rewrite` now owns the atomic sources rewrite.** The pocket
  repair had drifted into an eight-line identical run with
  `apt_sources_set_architectures`; the dupes gate caught it, and the shared owner
  keeps the three properties each of which was paid for by a real failure (temp
  beside the target, explicit cleanup instead of a trap in a SOURCED file, and no
  `mv` after a failing awk).
* **Also this window:** the retry classifier stopped reading BuildKit's elapsed
  prefix as an HTTP 429, `smoke-toolchain.sh` asserts LLVM by major.minor instead
  of the full pin, `lint-secrets.sh`'s gitleaks invocation was repaired, and
  `bench_coding.py`'s `RLIMIT_NPROC` counts tasks rather than processes.

## 2026-09-08 — the container stack installs rootless, with no sudo

* **`install-nerdctl-full.sh` grew a rootless prefix mode.** It always installed
  into `/usr/local` with unconditional `sudo tar` / `sudo cp -a`, which made it
  unrunnable unattended on a host whose sudo prompts for a password. It now
  installs into `$HOME/.local` with no sudo anywhere. The mode is AUTO-DETECTED
  from the live `systemd --user` units' `ExecStart` — those units are the only
  authority on what a host actually runs — so neither host needs a knob;
  `NERDCTL_ROOTLESS=1|0` forces it. Every safety property is unchanged: busy-build
  refusal, SHA256 verification, backup + `--rollback`, the cache-mount census, the
  buildkitd worker assertion and the QEMU-binfmt warning.
* **Extracting the bundle was only half a prefix change.** The units keep the
  absolute `ExecStart` they were generated with, so an install into a new prefix
  moved no daemon at all. The script now repoints
  `~/.config/systemd/user/{containerd,buildkit}.service` and prepends
  `${PREFIX}/bin` to their `Environment=PATH`, stashing the pre-image in
  `${NERDCTL_BACKUP_DIR}/systemd-user` so `--rollback` restores units as well as
  binaries. A relocation is same-version by definition, so the "daemon version
  MOVED" proof is replaced there by the one that actually applies: every daemon's
  `/proc/<pid>/exe` must resolve under the new prefix.
* **A drop-in `ExecStart` beats the unit file's.**
  `buildkit.service-override.conf` hardcoded `/usr/local`, so applying host config
  after a rootless install silently reverted `buildkitd` to the other prefix —
  invisible until a build failed. It now carries `@NERDCTL_PREFIX@`, substituted
  by `apply-host-config.sh` and `verify-host-config.sh` before they install or
  diff.
* **CNI plugins: 0 → 18.** Rootless nerdctl resolves plugins under its own
  `$HOME/.local/libexec/cni`, not under `/usr/local`, so summy-server had been
  running with none at all — `/usr/local/libexec/cni` held only a LICENSE. The
  install now counts them where nerdctl actually looks and fails the run at zero.
* **Measured on summy-server (aarch64, Snapdragon X, WSL2).** The relocation was
  byte-identical: sha256 matched across `nerdctl`, `containerd`, `buildkitd`,
  `rootlesskit`, `runc` and `containerd-rootless.sh`, because `/usr/local` already
  held the same nerdctl-full 2.3.5 bundle. Not a version change — a relocation.
  Documented as [`linux-host-setup.md` § B3c](docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo).

