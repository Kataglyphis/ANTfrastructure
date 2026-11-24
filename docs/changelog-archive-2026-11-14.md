# Changelog archive: 2026-11-13 … 2026-11-14

Later entries are in [the 2026-11-15 … 2026-11-17 archive](changelog-archive-2026-11-17.md);
preceding entries are in [the 2026-11-07 … 2026-11-12 archive](changelog-archive-2026-11-12.md).

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
