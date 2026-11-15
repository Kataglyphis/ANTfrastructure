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

## 2026-11-14 — isolate chain lifecycle fixtures from host pruning

- Disable inherited BuildKit and image-store prune permissions before lifecycle
  tests exercise low-disk refusals; keep explicit recovery doubles intact.
- Check the fixture with sentinel engines so either missing override fails
  without touching a host store or service.

## 2026-11-14 — align the general cleanup fixture with decimal MB

- Correct the general daemon-prune fixture's 100-GiB expectation to 107375 MB,
  retaining its read-only, Apply and command-order assertions.
- Document the native crash fixture's host MSVC and Visual Studio CMake
  generator prerequisites; an unprovisioned local host remains a failed run.

## 2026-11-14 — document delegated maintenance and new-host limits

- Describe the verified local on-demand cleanup/recovery pilot, its fixed rights,
  result checks, measured reclaim and remaining capacity limit.
- Add new-host guidance and the canonical administrator fallback. The pilot's
  ignored preparation files are not a distributed installer; portable setup and
  clean-host acceptance remain open. No maintenance code or installed task changes.

## 2026-11-14 — match BuildKit cleanup targets to disk admission units

- Convert GiB to rounded-up decimal MB for regular pruning, general pruning and
  advice. The old `* 1024` conversion understated a 100-GiB target by about 4.6 GiB.
- Check actual daemon arguments, rounding, large values and shared wiring with
  regression tests and mutations; retain all idle, image and compiler-cache guards.
- Keep the unit mutations in a harness-only suite for the Pester-free Linux CI
  shards; preserve the existing Pester reclaim controls and native failure checks.

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
