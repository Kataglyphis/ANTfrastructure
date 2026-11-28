# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-11-15 … 2026-11-17`](docs/changelog-archive-2026-11-17.md) ·
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

## 2026-11-28 — OpenCV's CUDA configure keeps its libcuda stub

- The nvidia chain `20261127-154917-57ee53f3` failed amd64 Media at OpenCV: `CUDA_CUDA_LIBRARY` NOTFOUND for
  `opencv_cudacodec`. `opencv-cuda-cache.sh` passed `-DCUDA_TOOLKIT_ROOT_DIR` since c238a510, and CMake's FindCUDA
  clears its library cache entries when that root differs from its unset internal marker. It now exports
  `CUDA_TOOLKIT_ROOT` instead. `test-opencv-cuda-cache.sh` runs a real FindCUDA configure against a fake toolkit;
  the recipe `probe.opencv-cuda-cache-root-cli` puts the CLI root back and turns it red.
## 2026-11-28 — run-pester-suite runs Pester 5 and 6, so a consumer can leave 3.4.0

- AccelerANTgine's BACKLOG asks its 14 suites to move from Pester 3.4's `Should Be` to the dialect of the image's
  Pester 6.2.0 (CON283). Its workflows could not follow: the action called `Invoke-Pester -PassThru -Quiet` and read
  `TestResult`, which Pester 6 rejects and 5 no longer has. The logic moved into
  `.github/actions/run-pester-suite/Invoke-PesterSuite.ps1`. Below 5.0.0 it makes the same call as before. From
  5.0.0 on it runs a Pester configuration with `Run.Exit` off, prints each failed test's path, message and stack,
  and fails a file that breaks in discovery or its top-level `BeforeAll`, which Pester reports as a failed
  container with no failed test. The default stays `3.4.0`. `path` and `version` reach the script through the
  environment instead of the script text.
- `Ci.PesterActionExit.Tests.ps1` grades both dialects against stubbed Pester (9 cases). `Ci.PesterAction.Tests.ps1`
  now runs genuine Pester: eight cases at versions.env's `PESTER_VERSION`, and the six 3.4.0 cases on Windows.
  `actions-selftest.yml` runs a modern suite at that pin and asserts that a broken file fails the action. Two recipes
  are retargeted to the script and six added; all eight go red.

## 2026-11-28 — the rustdoc site links its dependencies to docs.rs, and the link gate sees Rust paths

- `cargo_build_doc.sh` runs `cargo +${RUST_NIGHTLY_TOOLCHAIN} doc -Zrustdoc-map` with crates.io mapped to docs.rs
  (owner decision). Stable `--no-deps` gave rustdoc no page for a dependency, so every link into one stayed raw
  text. tracing's blanket impls put `dispatcher#…` on every OxidANT type page, which OxidANT froze as 60
  `missing <module>/dispatcher` rows. tracing 0.1.44 is correct: built with its dependencies, the same link
  resolves, so no upstream fix is due. The pin comes from `versions.env`, and a host without that toolchain
  fails with the install line.
- `verify_site_links.py` reports a link that is a Rust path (`super::Subscriber`, `crate::Span`) as
  `unresolved<TAB><link>`. `urljoin` read `super:` as a URL scheme and skipped those as external, four per
  type page on rust.jonasheinle.de.
- Measured in WSL on OxidANT's develop, 18 of 20 crates: 69 findings with stable (63 `missing`, 6
  `unresolved`), none of them with the nightly. Six new recipes; nine builder and gate mutants go red. OxidANT
  drops its frozen rows once this lands. docs/docs-sites.md § Links into dependencies.

## 2026-11-28 — an AMD bundle's self-test proves its own plugin module on a host without the GPU (develop-red #276)

- OrchestrANT's `gpu-lin / inventory (amd, x64, latest-rocm)` got past the closure with 5f8bc07ae and stopped at
  the self-test (run 46072754506): `the self-test did not register the plugin EP MIGraphX: []`. AMD's module
  asks HIP for its devices while it registers, so the hosted runner answered `HIP failure 100: no ROCm-capable
  device is detected`. The docs' "permits a build without GPU hardware" was never true. The report also named
  the image's module, because `ORT_AMDGPU_EP_ROOT` pointed there.
- `python_app_selftest` in `python-app-cli.sh` now runs the self-test for both drivers, with
  `ORT_AMDGPU_EP_ROOT` unset, so the app registers the bundle's copy (owner decision). Where `/dev/kfd` is
  missing, `python_app_deviceless_args` adds `--deviceless-plugin-error`. `python-app-selftest.py` then accepts
  the registration's failure in place of the registration, and only when it carries HIP error 100 and names a
  module under `--root`. Any other reason, an image path or a missing `--root` still fails, and a host with
  the device still has to register.
- Suites: 6 new self-test assertions, 7 for the CLI helpers. Six new recipes, two retargeted to the moved
  lines; eleven mutants go red. docs/python-app-bundles.md § Linux GPU bundles.

## 2026-11-27 — a ROCm Python bundle carries the chain core its plugin MIGraphX EP links (develop-red #276)

- OrchestrANT's `gpu-lin / inventory (amd, x64, latest-rocm)` (runs 43409294907, 45983749575) stopped in the
  closure: `capi/libmigraphx-ep.so: libonnxruntime.so.1` resolved nowhere. Gate first: the modules of both
  `:latest-rocm` builds (sha256 `c69589860128…` and `d54388c35c95…`, read from OxidANT's and AccelerANTgine's AMD
  artifacts) import none of the core's three exports, `OrtGetApiBase` included, so the core they load stays apart
  from the binding's.
- `python-app-bundle.sh` (owner decision): `ort_stage_plugin_core` copies the CPU prefix's `libonnxruntime.so.1`
  to `capi/libonnxruntime.so.1`, checks its sha256 against the chain's, and refuses to replace a wheel file. Every
  launcher, the closure and G6 take `capi` as the library path.
- `bundle-loader.sh --library-path DIR[:DIR...]` writes bundle directories into both glibc paths and refuses a
  rerun with another path. `elf-closure.sh --library-path` resolves a library there ahead of any RUNPATH. Both
  read the path through the census's rules (`ort_bundle_library_dirs`).
- `python-app-deb-depends.py` parses such a launcher and counts its directories as bundled.
  `verify-python-gpu-package.py` proves the copy against the chain core, keeps it out of the wheel proof, and
  requires it in every finished format. `_ort_validate_python_provider_wheel` skips it as well.
- Suites: `test-ort-runtime-bundle.sh`, `test-ort-host-runtime.sh`, `test-elf-closure.sh`,
  `test-linux-closure-install.sh`, `test-python-deb-depends.py`, `test-python-gpu-package.py`, `test-ort-census.sh`
  and `test-python-app-bundle-license.sh`. Twenty-two `packaging.*` recipes, each seen to bite under WSL.
  `docs/failure-modes.md` records the symptom. BACKLOG CON256 (i)/(j) is fixed in source, and (k) records the
  module's empty RUNPATH entry. Not yet run in a rocm image.
## 2026-11-27 — the backlog reads the published images: CON283 done, CON238, CON264, CON79 and CON99 advanced

- `:latest` `abb3030d…` and `:latest-rocm` `4de019ad…` replace the backlog's digest baseline; both passed all six
  consumers and carry only `tar+zstd` layers.
- CON283 is done: the image carries Pester 6.2.0, and the owner keeps 6.2 rather than 5.7 (`docs/decisions.md`).
- CON238's Linux half, CON264's fresh chain, CON79's riscv64 torch twin and CON99's first zstd re-push are recorded
  with what each still lacks.

## 2026-11-27 — `prepare-linux-ci-host` takes the full cleanup below 100 GB free

- `fast-floor-gb` defaults to 100, was 90. The larger x86-64-v3 `:latest` with Flutter 3.50 left
  OxidANT's and OmniAccelerANT's Linux build jobs out of disk under the fast cleanup. OxidANT 93a2bad
  passed `free-disk-space: 'true'` meanwhile; the hub default now covers it.
- Its amd64 manifest (index `abb3030d`) holds 12.5 GB of zstd layers, summed from the registry
  manifest, and 38.4 GB unpacked, counted from each layer's decompressed tar stream. The
  2026-11-03 index `7d4d4129` measured 13.0 GB (gzip) and 36.6 GB the same way, so the action's
  "about 72 GB unpacked" was never the unpacked size; that text goes.
- A new last step prints `df -BG /` after the pull, so the next floor is sized from a measurement. It
  cannot fail the job.
- `test-select-disk-cleanup.sh` follows the new floor and pins the default and the report step.
  `actions.disk-cleanup-floor-default` and `actions.free-disk-after-pull-reported` prove it bites.

## 2026-11-27 — shared helpers for three checks the consumers hand-roll (fleet-health #364)

- `Assert-PackageOrtProviderSet` in `WindowsPackageBinary.Common` compares one package directory's
  ORT providers with a proven list, in any order. A difference fails and names both sets. It
  replaces the `-join` and `-cne` comparison four consumers write after `Get-PackageOrtProviderNames`.
  `PackageBinary.ProviderSet.Tests.ps1` covers it, and `Msi.InstalledPath.Tests.ps1` adds a real MSI.
- `linux/scripts/lib/app-packaging-artifacts.sh` is new. `app_packaging_single_artifact` selects
  exactly one artifact of a suffix, and `app_packaging_linux_artifacts` the `.deb`, `.tar.gz` and
  `.AppImage` together. Neither changes the caller's glob options. `test-app-packaging-artifacts.sh`
  covers none, one and two of each format.
- `TestHarness.psm1` gains `Get-TestAstFunction` and `Get-TestAstAssignment` beside
  `Get-TestAstCommands`. `Get-ScriptFunctionDefinition` now uses the function query and still lifts
  the first definition.
- 20 mutation recipes guard the three. The consumers switch after their hub pin moves.

## 2026-11-27 — the duplicate-code gate reads PowerShell param blocks as idiom (owner decision)

- Owner decision of 2026-11-27: `verify_code_dupes.py` no longer counts a shingle that reaches into a
  PowerShell `param(...)` block, at script, function or script-block level, toward a pair. The block stays
  in the `MAX_OWNERS` idiom census, so a pair's count can only fall; the body after the block is compared
  as before. `--explain` reports the dropped shingles as idiom. Inline parameter lists and the
  `[CmdletBinding()]` attribute still count.
- The PowerShell literal masking and the new block marks moved to `docs/scripts/code_dupes_ps.py`, which
  keeps the gate under the 800-line file limit. The module joins the gate in the parameter and return
  tier of `lint-python-types.sh`.
- `code-dupes.allow`: 22 stale rows removed and 20 budgets lowered to the measurement. No row was added or
  raised.
- `test-code-dupes.sh` gains nine cases and `mutations.json` eight `code-dupes.ps-param-*` recipes, each
  proven to bite. `code-quality-tooling.md` § PowerShell param blocks are idiom, the gate registry, the
  derived mutation counts and the page's prose row follow.
- In AccelerANTgine, the three `Build-Windows.ps1` `Copy-*` pairs that shared only their parameter list
  (11 shingles each) now share nothing counted, and seven cross-file pairs fall under the threshold.

## 2026-11-27 — a Flutter 3.50 runner loads libgcc_s ahead of the engine's unwinder

- Flutter 3.50.1's `libflutter_linux_gtk.so` exports 31 of LLVM libunwind's symbols (ten `_Unwind_*`, four
  `__unw_*`, seventeen `unw_*`) but not `_Unwind_GetIPInfo`; 3.47.9 exports none. A runner lists the engine
  first among its libraries, so the first C++ exception aborts the app, even one the throwing library catches.
  OmniAccelerANT's integration test hit it (develop-red #408 x64, #411 arm64; fixed there in 0393907c and
  d53bf654). Ten lines of C++ against the real 3.50.1 engine abort with rc 134 when the engine leads NEEDED
  and catch when libgcc_s does.
- `cmake/KataglyphisFlutterUnwinder.cmake`: `kataglyphis_flutter_unwinder_first(<runner>)` links `gcc_s` inside
  `--push-state,--no-as-needed` ahead of `flutter`, and fails the configure when the runner already links
  `flutter` or the engine's path. Windows and macOS runners are left alone. With it, the same ten lines catch
  against the real engine.
- `05-frameworks/flutter/check-flutter-unwinder-order.sh <executable>...` fails unless libgcc_s is the first
  object in `ldd`'s load order that defines `_Unwind_RaiseException`. An unresolved library, a `readelf`
  error and a launcher without its ELF fail too; a `bundle-loader.sh --beside` launcher is graded by its
  `<name>.bin`.
- Suites: `test-cmake-flutter-unwinder.sh` (the link line, the refusals, and a runner and a control built
  against a stand-in engine, run and gated) and `test-check-flutter-unwinder-order.sh`. Nine
  `flutter.unwinder-*` mutations, all proven under Linux bash.
- `docs/failure-modes.md` § A Flutter 3.50 Linux app aborts at its first C++ exception, linked from the
  `libunwind.so.8` and ROCm entries; `code-quality-tooling.md` § The Flutter Linux unwinder order.
- Upstream fixed it on master (flutter/flutter#196451), not on 3.50 stable or 3.51 beta.
  `linux/upstream/flutter-unwinder-cherry-pick/ISSUE.md` is the prepared cherry-pick request, not posted.
  jotrockenmitlocken still has to adopt the module (BACKLOG CON150).

## 2026-11-27 — Renovate's Node moves to 24.22.3

- `RENOVATE_NODE_VERSION` 24.22.3 with both `.tar.xz` SHA-256s from nodejs.org's `SHASUMS256.txt`: renovate 45.1.2
  and later declare `node ^24.22.3`, so `renovate-local.sh` stopped at `npm ci` (EBADENGINE) on 24.22.2.

## 2026-11-27 — FFmpeg's tag archive is pinned on both lanes (CON227)

- `versions.env` pins `FFMPEG_SHA256`, the tag archive's decompressed-stream hash, and `FFMPEG_TAG_COMMIT`. Linux's
  new `fetch-ffmpeg.sh` checks the archive and refuses a git fallback off that commit; Windows'
  `Assert-FfmpegTarballStream` checks the archive before it is extracted.
- `spec_ffmpeg_tag_commit` moves both after Renovate moves the tag. The Windows driver forwards `FFMPEG_SHA256` to
  the FFmpeg stage only.
- It re-keys the Linux compiler image and the Windows FFmpeg stage, so it lands with a rebuild. Twelve new recipes.

## 2026-11-27 — a failure mode for a download right after its upload; CON302 pilot and FFmpeg pin status

- `failure-modes.md` names `None of the provided artifact IDs were found` after a fresh upload: the run's listing
  lags, so a job waits before the download or downloads in a later job (AccelerANTgine 71cbf1d).
- `BACKLOG.md` records CON302 step 7 in OxidANT (4890c0a) and what it leaves, and the FFmpeg pin that waits for
  the next rebuild.

## 2026-11-27 — the ORT Web stager for an app's site (OmniAccelerANT browser port step 1, CON233)

- `linux/scripts/lib/stage-ort-web.py` stages the image's ORT Web builds, JSPI, Asyncify and CPU, and JSEP with
  `--jsep`, under `ort/<version>-<build hash>/` with ORT's license texts and `ort/manifest.json`. It refuses a
  missing build, bytes that differ from `ort-webgpu-wasm.json`, and a wheel license text of another ORT
  version. Owner section: `docs-sites.md` § Staging ORT Web for an app. Suite `test-stage-ort-web.sh` and the
  `docs-site.ort-web-*` mutations.
- `40-build-wasm.sh` no longer collects a loader's `*.mjs.bak` and puts ORT's `LICENSE` and
  `ThirdPartyNotices.txt` beside the wasm. It lands with the next media build, which re-keys the web stage.
- `BACKLOG.md`: a CON233 note, and CON306 for receipts of the CPU and JSEP builds.

## 2026-11-27 — the hub AGENTS.md is under its 6000-word target (CON303 phase 3)

- `AGENTS.md` falls from 7,321 to 5,194 words. Six sections keep a short rule and a link; their full
  text moved to the owner pages: Repo Map to `overview.md` § Repo map, Shell safety to
  `shared-script-libraries.md` § Shell safety conventions, Background jobs to `linux-host-setup.md` § B11,
  Caching discipline to `build-cache-tiers.md` § Caching discipline, Push and Publish to
  `linux-cross-builds.md` § Push and publish rules, and Documentation Maintenance to `INDEX.md`. Every
  heading stays; `docs/INDEX.md`, `adopting-in-a-new-project.md` and the `test-ifs-safety.sh` comment
  point at the new owners. No rule changed; the doc-prose rows fall.
- `BACKLOG.md` CON303 marks the word budget done.

## 2026-11-27 — the last four invariant tables read as rule lists (CON303 phase 2)

- Script, test and packaging (Windows), shell helper, ONNX Runtime build and plugin, and test harness and lint
  invariants: each table row is a bullet, one clause per sentence. No rule changed; the doc-prose rows fall.
- `BACKLOG.md` CON303 records the second pass and what is left.

## 2026-11-27 — eight more invariant tables read as rule lists (CON303 phase 2)

- AMD source-stack, acceptance, compiler and SDK proof, GPU workflow, cleanup and relocation, local launch and
  handoff, packaging and licence, and Renovate driver invariants: each table row is a bullet, and each clause
  it chained with a semicolon is its own sentence. No rule changed; the doc-prose rows of the pages fall.

## 2026-11-27 — six invariant tables read as rule lists (CON303 phase 2)

- The one-column rule tables phase 1 moved out of `AGENTS.md` become bullet lists of short sentences, each
  former clause its own sentence, on six pages: release, uv and free-threaded, source-original notice, cache
  probe, reuse and delegated-maintenance invariants. No rule changed; the doc-prose rows of the six pages fall.
- `AGENTS.md` § Delegated Windows storage maintenance keeps one rule and the link; its other two sentences
  are items on the owner list.

## 2026-11-27 — AGENTS.md's Container Architecture, Quick Reference and Build Workflow keep only the rules (CON303 phase 2)

- `AGENTS.md` falls from 9,526 to 7,342 words. Each section keeps its heading, so consumer links still land,
  and states the rule with a link to the page that now holds the detail.
- New owner sections: `overview.md` § Tag naming (the tag table and every naming rule),
  `windows-build-lanes.md` § Local intermediate tags, `repository-family.md` § Contributing reusable work,
  `local-proof-workflows.md` § Run artifacts and operational scripts. The variant-chain mechanics join
  `linux-cross-builds.md` § A variant chain; the Windows lane, prerequisites, resume boundary and host fixes
  join their `windows-builds.md`, `windows-build-lanes.md` and `windows-host-setup.md` sections.
- Superseded history leaves the instructions: the `:latest-cross` tags are gone (decisions.md keeps both rows).
  No test asserted a moved line; none changed.

## 2026-11-27 — AGENTS.md's Linux Build Rules and Validation keep only the rules (CON303 phase 2)

- `AGENTS.md` falls from 12,299 to 9,526 words. Each Linux Build Rules and Validation bullet is now the one
  rule an agent must not break, with a link; the detail it carried moved to the page that owns it.
- New owner sections: `linux-cross-builds.md` § Rules for the Linux lane, `onnxruntime-single-source.md`
  § The rules on Linux, `code-quality-tooling.md` § Where the gates run (the four places table) and
  `cross-build-verification.md` § Runtime verification. Short rule paragraphs join the DeepStream, TensorRT,
  Intel, SBSA, Hailo, web-lane, wheelhouse, Chrome, uv-seed, free-threaded, ISA-floor, libsanitizer,
  host-config and PowerShell sections; the companion table gains the runtime smoke's two modules.
- Pointers that sent readers to `AGENTS.md` for that detail now name the owner sections. One `doc-dupes`
  allow row is gone, because its overlap is gone. `test-doc-numbers.sh` now wants the hook's fast-slug count
  on `code-quality-tooling.md` instead of `AGENTS.md`, because the gate table moved there.

## 2026-11-26 — a release carries FFmpeg's exact sources (CON227 step 3)

- `Export-NativeSourceArchive` copies the archives, build scripts, patches and `ffmpeg-sources.json` the bundle owes
  to the package folder's `source-offer/`, each checked against its SHA-256; `New-PythonAppPackage.ps1` calls it.
- `collect-release-assets.sh` collects a byte-identical copy from several lanes once, still fails on two different
  files of one name, and has `check-source-offer.py` prove every collected index complete before publishing.
- `Publish-NativeSourceOffer` refuses an offer that names one file twice. Ten new recipes, one re-anchored.

## 2026-11-26 — the develop-red watch retries a dropped connection

- One watch run failed and opened develop-red #402 on itself because GitHub closed a connection before any answer
  (`http.client.RemoteDisconnected`). urlopen leaves that unwrapped, so neither the 5xx retry nor the per-repository
  catch saw it. A GET now retries any transport failure (`TRANSIENT`) on the same delays, a write still never, and a
  repository that keeps dropping is named and the others settle.
- Two replay scenarios simulate the drop; three recipes, and `develop-red.repos-isolated` re-anchored.

## 2026-11-26 — an AMD AppImage's ORT core matches its wheel after the image's strip

- `verify-ort-appimage-payload.sh` asked every variant for exact, unstripped wheel bytes, but the image strips its CPU
  core (`30-build-native.sh`), which AMD packages carry; no wheel could match, so AccelerANTgine's AMD candidate
  failed with `expected one wheel matching every native library; found 0` (BACKLOG CON item (i) foresaw it). AMD now
  compares after GNU `strip --strip-all`; NVIDIA keeps the exact check. `test-ort-appimage-payload.sh` holds both.

## 2026-11-26 — Python app packages carry FFmpeg's GPL texts and source offer (CON227 step 2)

- `WindowsSourceOffer.Common.psm1`: `Copy-NativeSourceOffer` copies the texts and the offer of every image FFmpeg DLL
  a bundle holds; `Assert-PackageSourceOffer` compares them in the finished package with the image's bytes.
- `New-PythonAppBundle.ps1` copies them after cv2's closure, and `New-PythonAppPackage.ps1` checks the ZIP, MSI and
  MSIX. An image that predates the offer warns and passes, so a consumer stays green until the Windows rebuild.
- `SourceOffer.Common.Tests.ps1`, a shared offer fixture, the packager's structure test and ten recipes.

## 2026-11-26 — the ORT profile suite imports its fixture under python -I

- `test_verify_ort_profile.py` puts its own directory on `sys.path` before importing `ort_profile_fixture`:
  AccelerANTgine's GPU candidates run it with `python3 -I`, which leaves that directory off, so its 0.0.4 release run
  failed with `ModuleNotFoundError` before any GPU package was built. `test-verify-ort-profile.sh` now also runs it
  with `-I`; one mutation holds it.

## 2026-11-26 — the Windows FFmpeg ships its GPL texts and exact sources (CON227 step 1)

- `Publish-NativeSourceOffer` (`WindowsSourceOffer.Build.psm1`) writes, beside FFmpeg's binaries, the licence texts of
  FFmpeg, x264, x265 and dav1d from their exact trees, the archives they were built from with the build scripts and
  patches, `sources.json`, `SOURCE-OFFER.txt` and `provenance\ffmpeg.json`. x264 is a clone, so its archive is
  `git archive` of the pinned commit. The smoke gate checks the offer; the BtbN fallback writes none and fails it.
- The new leaf module is mounted only in the FFmpeg RUN; `WindowsNativeProvenance.Common` is unchanged, so the ONNX
  stage keeps its cache key. Not in an image yet: the owner holds the Windows rebuild.
- `SourceOffer.Build.Tests.ps1` and six recipes; nine FFmpeg-RUN mount recipes re-anchored on the two new mounts.

## 2026-11-27 — the acceptance retries a failed consumer once and cleans up as it goes

- The `:latest` acceptance failed once on jotrockenmitlocken: `sqlite3`'s build hook saved GitHub's
  500 page as `libsqlite3.so` and refused its hash. A consumer whose command exits nonzero now runs
  once more without its build outputs, and the receipt keeps the first attempt and its log.
- The rocm acceptance failed `No space left on device` in OxidANT's tests: three runs that day had
  kept 133 GB of consumer checkouts. Each passed consumer now loses its untracked build outputs at
  once (`git clean -ffdx`, submodules included); its versioned sources and Git stores stay, as the
  acceptance invariants require. `--keep-build-outputs` keeps them.
- A GPU variant's runtime lane budgets 280 GB per arch instead of 180: a rocm lane that rebuilt its
  package filled 225 GB free, its wrapper and the smoke beside it about 100 GB each.
- `image-acceptance.retries-a-failed-command`, `.retry-only-on-nonzero-exit`,
  `.retry-records-first-attempt`, `.passed-checkout-removed`, `.cleanup-reaches-submodules` and
  `disk-guard.gpu-variant-lane-budget`.

## 2026-11-27 — rustup downloads through curl on the emulated package stages

- The arm64 package stage failed twice in four runs: rustup 1.29.3 aborted under qemu-aarch64 while downloading,
  once in `rustup-init` and once in all three tries of `rustup component add rustfmt`.
- In the arm64 wrapper under qemu, the rustls backend aborted 3 of 6 installs and the default 1 of 6, while
  `RUSTUP_USE_CURL=1` passed 18 of 18. `RUSTUP_IO_THREADS=1` and `RUSTUP_CONCURRENT_DOWNLOADS=1` did not help.
- `ensure_native_rust_toolchain` runs `install-rust.sh` with `RUSTUP_USE_CURL=1`. `install-rust.sh` stays untouched,
  so the toolchain stage keeps its key; only the package stage re-keys. `rust.package-rustup-downloads-with-curl`
  holds it.

## 2026-11-27 — the free-threaded WebGPU proof reads stdout only

- The first riscv64 runtime smoke since the WebGPU factory checks failed `no unique successful free-threaded WebGPU
  factory proof`. ORT's `Unknown CPU vendor` warning under qemu-riscv64 went to stderr, which the probe had merged
  into the proof row.
- `check-free-threaded-wheels.sh` keeps the factory's stderr apart and adds it to the row only when the proof fails.
  The transport test's stub warns on stderr, and `probe.ft-webgpu-proof-reads-stdout` holds it. The smoke runs on the
  host, so no image re-keys.

## 2026-11-26 — the riscv64 NumPy probe wheel builds outside its pool

- The riscv64 wrapper failed `FT-PROBE-DEPS FAIL: probe dependency pool has unexpected entries` after `uv build`
  succeeded: uv 0.13.7 leaves its sdist extraction (`.tmp*/numpy-2.5.4`) under `--out-dir`, which was the pool.
- `populate` builds into `<pool>-dist`, moves the wheel in and removes the rest. The test's uv stub leaves the same
  tree behind; `probe.ft-deps-build-outside-pool` holds it. Only the wrapper's probe-deps RUN re-keys.

## 2026-11-26 — the runtime lane's zstd conversion no longer breaks the wrapper it pushes

- The first runtime lane since CON99 built and smoked the amd64 wrapper, then its push failed with
  `content digest sha256:0883bfe0…: not found`. `nerdctl image convert` with the source tag as its target loses the
  source manifest when no other image holds it; a wrapper built from an OCI layout is such an image. A small image built
  the same way reproduced it, and converting to a second tag did not.
- `_runtime_zstd_convert` converts to `<tag>-zstd`, retags and removes the staging tag. `test-runtime-push.sh`'s stub
  fails an in-place convert, and `runtime-push.zstd-converts-to-a-second-tag` and `runtime-push.failed-retag-stops`
  hold it.

## 2026-11-26 — Intel's GPU user space is asked for on amd64 only

- The first runtime lane since CON258 stopped in its input preflight on arm64 and riscv64:
  `Package 'intel-media-va-driver' has no installation candidate`. The existence check uses
  `apt-cache show`, which finds the name on the ports mirror, so `append_available_packages` kept it.
- `select_dev_packages` now asks for the three Intel packages only on amd64, like mingw.
  `intel-gpu.amd64-only` holds the guard; `intel-gpu.packages` follows the new indentation.

## 2026-11-26 — the package gates read an NSIS setup (CON302 step 4)

- `verify_package_license.py` and `verify_package_binary.py` read a `-setup.exe` with `7z -tNsis`, by `$INSTDIR`-relative
  path. `$PLUGINSDIR` and other `$` entries never match, a path held twice in any case fails, and only the selected files
  are extracted, which must come back exactly. On a Windows host both read the hub's real test setups.
- `Get-NsisSetupFileNames` and `Test-NsisSetup` (`WindowsMsiLicense.Common`) give the MSVC notice gate and both ORT
  censuses an NSIS branch. `New-PortableBundle` finds a setup by its first header, checks it and ships it once, whatever
  its name; before, a setup shipped unchecked and only beside a same-stem MSI or ZIP.
- The arm64 device job fails when the uninstaller leaves any file but `Uninstall.exe`, and names each one.
- `test_package_nsis_setup.py`, `Nsis.PackageGates.Tests.ps1` and fifteen new recipes.

## 2026-11-26 — the riscv64 torch twin builds torch_python again

- The riscv64 media stage failed its final store check: the `cp315t` torch wheel had no `_C`. scikit-build-core 1.1.2
  sets `Python_FIND_ABI=ANY;ANY;ANY;ON` for a free-threaded interpreter, and CMake 4.4.5's cross FindPython then found
  no `Development.Module`, so torch turned `BUILD_PYTHON` off with a warning. A probe build of the app-wheelhouse step
  showed the cache; a toy project in the sdk image showed that any explicit `FIND_ABI` fails and an unset one works.
- `_torch_build_free_threaded_wheel` drops both `FIND_ABI` cache values after the init cache and fails the twin unless
  `BUILD_PYTHON:BOOL=ON`. `wheels.torch-ft-drops-find-abi` and `wheels.torch-ft-requires-build-python` hold it.
  Only the riscv64 app-wheelhouse RUN re-keys.

## 2026-11-26 — NSIS setups and their uninstallers are test-signed (CON302 step 5)

- `WindowsMsix.Signing` gains `Invoke-AuthenticodeSign`, the format-neutral signtool step that `Invoke-MsixSign` now
  calls, and `Assert-AuthenticodeSigner`, which accepts a test certificate's untrusted root but not a foreign signer or a
  broken hash. `-Require` turns a missing signtool or `.pfx` into an error. signtool's `/p` password is redacted in the
  build log; it was printed in plain text before.
- `Invoke-NsisPackage`'s `SignPfx` key signs through `windows/scripts/nsis/Invoke-NsisSign.ps1` behind `!finalize` and
  `!uninstfinalize` with `= 0`, and checks the signer of the written setup. The password stays in the environment.
  On a Windows host a makensis 3.13 build test-signed and timestamped both files, and a wrong password stopped makensis
  with no setup written. Seven new `windows-lane.*` recipes; the CON227 owner decision is recorded in BACKLOG.

## 2026-11-26 — riscv64 OpenCV names libtiff6 beside libtiff-dev

- Chain `linux-publish-default-20261126b` failed media-riscv64 in OpenCV's bundled libtiff (`jconfig.h` not found):
  after today's libtiff `4.7.0-3ubuntu5.1` security update, apt 3.2.1's solver refused `libtiff-dev:riscv64` alone,
  so the best-effort deps install skipped it and OpenCV fell back. Reproduced in the riscv64 SDK image: named with
  `libtiff6`, or under `--solver internal`, it resolves. `opencv/install-deps.sh` names `libtiff6` for riscv64 only,
  so only the OpenCV branch re-keys; `lib.opencv-riscv64-names-libtiff6` holds it.

## 2026-11-26 — the hub AGENTS.md drops from 26,270 to 12,299 words (CON303)

- The one-line invariants appended under the seven priorities, in Quick Reference and in the rule
  sections move unchanged in substance to the page that owns each topic, one table row per rule, in
  sections named "… invariants"; `docs/INDEX.md` § Invariants by topic lists them. The "Copied X
  carries Y" rows sit together in `shared-script-libraries.md` § Companion files a copied helper needs.
- GPU architecture coverage moves to `linux-accelerator-images.md`, the Code Organization list to
  `shared-script-libraries.md` § Key shared utilities, the Windows disk-reclaim rules to
  `windows-host-setup.md` § Host disk reclaim and the delegated-maintenance policy to
  `windows-stevedore-and-docker.md`; `AGENTS.md` keeps a one-to-three-sentence rule and a link for each.
- `AGENTS.md` loses its decision dates and ids (each has its `decisions.md` row), keeps one bold
  phrase per section and splits long sentences at their clause breaks. Its `doc-prose` rows and the
  receiving pages' rows fall.

## 2026-11-26 — the hub builds NSIS setups with the pinned makensis (CON302 step 3)

- `WindowsNsis.Common.psm1`'s `Invoke-NsisPackage` builds a per-machine, zlib-compressed setup from
  `windows/scripts/nsis/setup.nsi` and `kataglyphis-common.nsh`: a stable uninstall key that an upgrade finds, the
  architecture check that names the other setup, the MSI guard and refusals that exit 2 when silent.
  `Resolve-MakensisExe` refuses any makensis but `NSIS_VERSION`, `Assert-NsisPayloadPath` fails a path at MAX_PATH,
  and `New-NsisFileList` lets the uninstaller delete only what the setup installed. `WindowsMsix.Common` exports
  `Invoke-PackagerTool` and shares `Assert-PackagerInput` and `New-PackagerParentDirectory` with the MSI path; two
  code-dupes budgets fell by one. Both architectures' setups compile with makensis 3.13; none was run.
  `Nsis.Common.Tests.ps1` (9 cases) and eleven `windows-lane.nsis-*` recipes hold it.
- `BuildKit.ModuleClosure.Tests.ps1` reads only tracked Windows Dockerfiles: its scan of the whole checkout failed on
  an unreadable folder under the ignored `logs/`.

## 2026-11-26 — Windows binaries carry the CFG bit (CON290 done)

- BeschleunigerBallett's hub pin `5514538c` contains `d3661575`, which links `/NXCOMPAT /DYNAMICBASE /guard:cf` and
  `/CETCOMPAT` off ARM64. `llvm-readobj` on `GraphicsEngine.exe` (sha256 `340b1bfd…`) from its Windows x64 build
  run 45749219579 (head `7f2a3413`) reads `GUARD_CF`, `DYNAMIC_BASE`, `NX_COMPAT`, `HIGH_ENTROPY_VA`, the
  `CF_INSTRUMENTED` guard flag with 6102 guarded functions and `EX_CET_COMPAT`. CET enforcement at launch on
  CET-capable hardware stays unmeasured.

## 2026-11-26 — the Linux QNN plugin's ort_core comes from the verified commit

- Chain `linux-publish-default-20261126` failed media-arm64: the QNN plugin's configure downloads
  `microsoft/onnxruntime/archive/refs/tags/v1.29.0.zip`, which GitHub has served as 404 since 2026-11-17. A
  previous run had it cached. `36-build-qnn-plugin-ep.sh` now fetches `ORT_QNN_EP_CORE_COMMIT` from Microsoft or
  the `onnxruntime` pin's fallbacks, checks `VERSION_NUMBER`, archives it as a local `refs/tags/v1.29.0.zip` and
  substitutes the fork's `ort_core` row and `URL_HASH` (SHA256), as the Windows lane does. The fork's six `ort_core`
  patches still apply; a live run fetched `2e2543fb` from `ROCm/onnxruntime` and dry-ran all six. Seven
  `onnx-ep-qnn.ort-core-*` mutations hold it.

## 2026-11-26 — source-pins.txt's ORT and GenAI rows follow versions.env in the same Renovate call (CON305 step 2)

- `sync_versions.py --write` copies the tag and commit of the `onnxruntime` and `onnxruntime-genai` rows in
  `source-pins.txt` from `versions.env` (`docs/scripts/source_pins.py`), keeping their fallbacks; `--check` fails a
  row that differs, is missing or repeats. `renovate-local.sh` already runs `--write` after its sweep, so the rows move
  in the same call and a held commit holds them too. `bump_coverage.py` no longer lists versions outside the pin files.
  The licence subprocess is one `website_licenses(mode)` that keeps the generator's raw status. Four new mutations.

## 2026-11-26 — the native ORT plugin header reads the environment without `_wgetenv`

- `shared/native/ort_plugin_eps.hpp`'s `environment_path` reads a variable on Windows with `GetEnvironmentVariableW`:
  clang-cl marks `_wgetenv` deprecated, and AccelerANTgine's `-Werror` Windows lanes failed on it
  (`-Wdeprecated-declarations`), so no NSIS setup was built there. The Linux path is unchanged.

## 2026-11-26 — the Linux IREE cross twin configures nanobind free-threaded

- Default chain `linux-publish-default-20261125` failed media on arm64 and riscv64: the `iree-base-runtime` twin
  linked `_runtime.cpython-315t-*.so` with no inputs, because its rebuild had produced the GIL-named module. CMake
  4.4.5's cross FindPython empties `Python_SOABI`, so nanobind kept the GIL pass's cached `NB_SUFFIX`; the Windows lane
  hit the same on 2026-11-08. `_iree_free_threaded_rebuild` now drops `NB_SUFFIX*`, passes `SKBUILD_SOABI` and fails
  when `build.ninja` builds no `nanobind-static-*-ft` library. Three `wheels.iree-twin-*` mutations hold it.

## 2026-11-26 — the warning census reads clang-cl, and a Windows build writes its own log (CON295 (c))

- `verify_warning_census.py` reads clang-cl's `path(line,col): warning: ... [-Wflag]` and a verbose ninja's
  `clang-cl.exe ... -c` lines, strips the colour codes a clang on a terminal prints, and normalises `.` and `..`, so
  `Src/a/../b/x.h` and `Src/b/x.h` are one warning and `Src/../third_party/` is foreign. `C:/ws/`, `C:/ws-mnt/` and a
  Windows runner's checkout are workspace prefixes; any other drive-letter path is foreign. On BeschleunigerBallett's
  Windows x64 logs it reads the 11 own warnings Phase 20 counted by hand (job 139485513493) and 0 after its fixes
  (job 139672697599, 1415 compile lines). File format and lane semantics are unchanged; two suite cases, six new
  mutations, two refreshed.
- `Invoke-CmakeConfigureAndBuild -BuildOutputLog <file>` also writes the build step's output there, failed build or
  not, so a Windows lane can hand the census one build. One Pester check with its mutation.
- `cmake/README.md` § Warnings as errors: per target names `COMPILE_WARNING_AS_ERROR` on a project's own targets as
  the family's way, after SYSTEM includes and a census at zero.

## 2026-11-26 — a DevTools call takes its caller's bound

- `check-docs-sidebars.js`'s `send(method, params, timeoutMs)` keeps 30 s as the default and takes a longer bound from
  a caller whose page holds its main thread: OxidANT's browser lane failed a path-traced step on a slow runner with
  "Runtime.evaluate got no answer from Chrome in 30 s", at one of its unpolled calls, on develop and on a branch alike.
  The socket's call pairing is `cdpClient`, apart from `launch`, so `test-chrome-close.js` drives it with a fake
  socket; two cases, two mutations.

## 2026-11-26 — LIBVPX_MESON_COMMIT moves with GStreamer in the same Renovate call (CON305 step 1)

- `spec_libvpx_meson_commit` joins the safe tier. When `GSTREAMER_VERSION` moves, it reads that release's
  `vpx.wrap`, pins the head of the branch it names and hashes the archive into `LIBVPX_MESON_SHA256`. The new
  `LIBVPX_MESON_GSTREAMER_VERSION` in `tool-pins.env` records the release, so a moving branch alone changes
  nothing. A wrap that names another repository refuses. Live it reproduces both of today's pins.
- `gstreamer_git_wrap` reads a `[wrap-git]` for it and for `spec_x264_meson`. `LIBVPX_MESON_SHA256` leaves the
  SHA exemptions; drift is down to the three pins on Microsoft's ORT and GenAI repositories.
- A `test-bump-versions.sh` case and `test-bump-coverage.sh` assertions; three new mutations, all proven.
  `tool-pins.env` is a Windows build input, so the four lanes need a new proof at their next build.

## 2026-11-25 — LLVM_COMMIT and TVM_COMMIT move in the same Renovate call (CON305 step 1)

- `spec_llvm_commit` and `spec_tvm_commit` join the safe tier. The sweep runs after Renovate, so they read the
  `LLVM_RELEASE` and `TVM_REF` tags Renovate just wrote and pin those tags' peeled commits; both match today's
  pins. The coverage audit drops them from its drift list, which now says when a drift pin is held.
- A `test-bump-versions.sh` case and two `test-bump-coverage.sh` assertions; three new mutations, all proven.

## 2026-11-25 — The Renovate call names the pins it does not move (CON305)

- `bump_versions.py --audit-coverage` (`docs/scripts/bump_coverage.py`) places each of the 550 pin-file keys in
  one class: Renovate, the bump sweep, a spec extra, `--write-all`, by hand, checksum or not a version. It names
  the drift pins, whose owner one call moves while they stay, and versions outside the pin files
  (`source-pins.txt`). `--coverage-json` writes the table.
- Every `renovate-local.sh` run ends with the brief form. A key in no class or a stale `FOLLOWS`/`STANDALONE`
  row exits the run 2.
- `--audit-unclassified` uses the same classes: the non-version filter no longer hides `_COMMIT`, `_ASSET` and
  `ORT_*` pins, so each of the 43 it hid now names its owner pin. `derived_keys` adds DeepStream's three OSS commits.
- `test-bump-coverage.sh` (three cases) and one `test-renovate-pin-sweep.sh` case; five new mutations, all
  proven. Both bump suites share `bump-versions-fixture.sh`, which holds the workspace and the offline helpers
  `test-bump-versions.sh` carried; its three mutations moved with them.

## 2026-11-25 — The Windows final stage pins NSIS 3.13 (CON302 step 2)

- `NSIS_VERSION` 3.13 and `NSIS_WINDOWS_ZIP_SHA256` in `versions.env`. `windows/scripts/host/Install-Nsis.ps1`
  downloads SourceForge's zip with `Invoke-WebRequest` and a non-browser user agent: SourceForge answers the shared
  helper's browser one with an HTML page. It checks the SHA256, accepts only the `nsis-<version>` root with makensis,
  `COPYING` and the zlib stub, and requires makensis to report that release.
- `windows/Dockerfile` runs it in the final stage, puts `C:\nsis\Bin` first on PATH and sets `NSISDIR`; `Test-Container.ps1`
  fails when makensis resolves anywhere else or to another version. No image carries it yet: the next Windows build
  rebuilds only the final stage.
- Renovate's `custom.nsis` datasource and `bump_versions.py spec_nsis` read nsis-dev/nsis's `v313` tags. The spec
  pins the zip's SHA256 only after its SHA1 matches SourceForge's.
- `deps.json` lists NSIS as `Zlib AND bzip2-1.0.6 AND CPL-1.0` with a source pointer; both SPDX ids are new in
  `license_obligations.py`.
- `Nsis.Install.Tests.ps1` (six cases), a `test-bump-versions.sh` case, and six new mutations, all proven.

## 2026-11-25 — an nvidia chain on amd64 builds arm64 by default (owner directive)

- `cross_nvidia_sbsa_active` is on unless `CROSS_NVIDIA_SBSA=0`, and a variant chain without `--target-arches`
  takes `cross_variant_default_arches`: `amd64,arm64` for nvidia on amd64 (arm64 through the SBSA cross route),
  `amd64` for rocm, the full default set otherwise. Before, a bare nvidia chain fell back to `amd64,arm64,riscv64`
  and was refused. Four stage-graph mutations hold the default, both variant defaults and the chain's use of them.

## 2026-11-25 — the NVIDIA AppImage check accepts a bundle's bare ORT soname

- `verify-ort-appimage-payload.sh --nvidia-core libonnxruntime.so` lets a bundle that ships only the soname ort
  dlopens pass; OmniAccelerANT's NVIDIA AppImage failed on the missing `libonnxruntime.so.1` after its TAR and DEB
  passed. The versioned soname stays the default for every other caller, and only the two core names are accepted.
  A host-independent NVIDIA fixture and two packaging mutations hold it.
## 2026-11-25 — CPack's NSIS setups compress with zlib

- The released NSIS setups of AccelerANTgine v0.0.3 and BeschleunigerBallett v1.6.0 carry NSIS's CPL-1.0 LZMA
  stub without a source notice, because CPack defaults to `lzma`. Both were built with NSIS 3.13, so the two NSIS
  CVEs do not apply. `kataglyphis_cpack_common` now sets `CPACK_NSIS_COMPRESSOR` to `zlib`;
  `test-cmake-package-license.sh` and one mutation hold it ([compressor](docs/third-party-licenses.md#the-nsis-setups-compressor)).
  The two repos release again once their hub pin moves.

## 2026-11-25 — :winamd64, :winamd64-nvidia and :winamd64-rocm carry 58d00ec7

- With the owner's approval, the three Windows images built at `58d00ec7` are published after their smoke and
  publish gates passed again in the push run: `:winamd64` `sha256:74d35f135f74ecb065a793bcf9861f216f3c4b3cd218467e315351b614213b3d`
  (289 passed), `:winamd64-nvidia` `sha256:ae107fbffbb99205e317137bcb5cb79888d4324db5d7888f087ebe521588a9ca` (319 passed,
  CUDA and TensorRT plugin EPs) and `:winamd64-rocm` `sha256:0e1d2f858d83357d4359727c92ad06b8ebf1668ca2e68fad8fcbeba7c2db4ffb`
  (286 passed, MIGraphX plugin EP). No smoke check failed. GPU execution stays unproven: this host has no NVIDIA driver,
  DirectML adapter or AMD GPU. The consumers' Windows lanes were dispatched on each tag.

## 2026-11-25 — A CI probe measures the image's makensis (CON302 phase 0)

- `windows/scripts/diagnostics/Measure-NsisSetup.ps1` packs a release's x64 bundle ZIP with zlib and with
  `/SOLID lzma` in the published `:winamd64` image. It records the makensis version, time, peak RAM and setup
  size, the 7-Zip listing, whether makensis takes the one-frame PNG `.ico`, and whether a silent install creates
  and removes a Start-menu shortcut. It resolves Scoop's shim, so the RAM figure is the compiler's.
- `windows-nsis-probe.yml` runs it on dispatch and uploads `nsis-probe.json`; it proves no shipped installer.
- `Diagnostics.NsisSetupProbe.Tests.ps1`: seven cases for the script generator, the listing parser and the shim
  reader; three new mutations, all proven.

## 2026-11-25 — The web smoke test accepts the fallback fonts of the transition lock

- `flutter_integration_smoke_test.sh` with `CHECK_FALLBACK_FONTS=1` still required every row of
  `fallback-fonts.lock`, but a build on the 3.47.9 image places the transition lock's rows. OmniAccelerANT's
  `[ci web]` lane failed on `notocoloremoji/v39` with HTTP 404.
- `fetch-fallback-fonts.py --print-generations` prints the lock's font paths, then its transition lock's, and needs
  no engine. The smoke test reads them from there and passes when the site serves one lock's whole set. A mix or a
  partial set fails. `FALLBACK_FONTS_LOCK` names another lock for the suite's fixtures.
- `test-flutter-smoke-test.sh`: three new cases; `test-fetch-fallback-fonts.sh`: one. Four new mutations, and
  `web-smoke.fallback-fonts-served` re-pointed, all proven.

## 2026-11-25 — A Windows-on-Arm laptop as a development host

- `docs/windows-on-arm-dev-host.md`: what an aarch64 laptop with unified memory carries, the sizing on a 32 GB,
  8-core device, which jobs run locally and which stay in CI, lavapipe's vector width there, and what to read after
  a freeze. Indexed in `docs/INDEX.md`.

## 2026-11-25 — `run-in-ci-image.sh` caps a container's memory and CPUs; sizing WSL2 for builds

- `--memory SIZE` and `--cpus N`, or `RUN_IN_CI_IMAGE_MEMORY` and `RUN_IN_CI_IMAGE_CPUS`, limit the run; the swap
  limit equals the memory limit, so a container at its cap is killed instead of swapping the WSL VM until the
  Windows host freezes, which a consumer's local builds did twice. A malformed value exits 2 before any engine
  call. `test-run-in-ci-image-limits.sh` holds both, over a fake engine; checked against nerdctl's cgroup files.
- `rancher-desktop-linux-containers.md` § Sizing the VM for container builds: the shared VM cap, `.wslconfig`,
  earlyoom, a cap per container, one heavy job at a time and a lean editor.

## 2026-11-25 — local proofs take the preflight group count from their source

- `normal_stage_launch.full_source` requires as many distinct groups as the proved checkout's `KNOWN_SLUGS`
  (42 at the earlier reference, 43 today) instead of a literal 42; the GPU and Media reviews record that checked
  count. Five mutations hold the slug comparison, uniqueness, slug parsing and both reviews. The 2026-11-25
  Omni comparison at 647bccb showed its NVIDIA candidate's missing `libonnxruntime.so.1` predates the CON231 pins.

## 2026-11-25 — The fallback-font check accepts the 3.47.9 engine while the image switches Flutter

- The published image still runs Flutter 3.47.9, whose engine requests Noto Color Emoji v32 and Noto Sans Symbols 2
  v24. The 3.50.1 lock failed every web build on it, OmniAccelerANT's docs publish among them.
- `fallback-fonts.lock` names `fallback-fonts-flutter-3.47.9.lock` in a `# transition:` line; it holds the rows from
  before the 3.50.1 refresh. `fetch-fallback-fonts.py` uses them only when the engine fails the lock and requests
  exactly those rows. It then places only them and says so. A partial match still fails.
- `test-fetch-fallback-fonts.sh`: two new cases. Four `fallback-fonts.transition-*` mutations, all proven.
- Owner decision. The line and the 3.47.9 lock come out once the 3.50.1 image is published (BACKLOG).

## 2026-11-25 — build-docs.yml checks its isolated apps live after each publish

- New input `live-url`. With `isolated-apps`, a `live-check` job runs after the publish job. It runs
  `check-live-site.js --isolated` on each app at `<live-url>/<app>/` and sweeps the files it published. The upload
  cannot be undone, so a red job means the live app is broken now.
- `docs-site.sh live <site>` reads `DOCS_LIVE_URL` and `DOCS_ISOLATED_APPS`. It checks every app, also after a
  red one, and refuses a plain-http address, no apps and a path outside the site.
- `test-docs-site.sh`: four new cases with a stub node. Seven `docs-site.live-*` mutations, all proven.
- OmniAccelerANT's `docs.yml` opts in with `live-url: https://kataglyphisinferenceengine.jonasheinle.de`.

## 2026-11-25 — a bundle launcher can preload GCC's unwinder (CON231)

- `bundle-loader.sh --gcc-unwinder` preloads the bundle's `libgcc_s.so.1`. OmniAccelerANT's AMD bundle
  aborted on the RX 9070 XT because `libflutter_linux_gtk.so` exports its own `_Unwind_*`, which cannot
  catch the `filesystem_error` ROCm's `librocm_kpack` throws and handles inside `libhipblaslt`'s
  constructor. With the preload the same bundle ran MIGraphX operators and passed CPU detector parity.
  Four mutations hold both preload paths, the rerun policy and the missing-library refusal.

## 2026-11-25 — the usable CPUs honour the cgroup quota

- Owner decision: every cgroup v2 `cpu.max` from the process's own cgroup up to the root counts, and the
  smallest quota on that path wins. The usable CPUs are `max(1, floor(min(affinity, quota)))`.
- `shared/contracts/usable-cpus.json` holds 11 cases: `max`, 1.5 CPUs, under one CPU, above the affinity, a
  missing file, no cgroup path, a limited parent, a tighter child, a tighter parent, another period, and a
  smallest share that is not the smallest number. `test-usable-cpus.sh` replays them through a reference rule.
- `genai-model-threads.py` follows the rule: `auto` and `text` read the affinity mask and every `cpu.max` up to
  the root. Its tests replay the case file and walk a fixture cgroup tree. Nine mutations, all proven.
- `onnxruntime-single-source.md` § The ORT thread rule defines the usable CPUs and links the file. CON304 keeps
  the consumer bindings: OxidANT, AccelerANTgine and OrchestrANT.

## 2026-11-25 — the Python plugin helper can reuse another library's registration

- `shared/python/ort_plugin_eps.py` takes `reuse_existing=True` in `register_plugin_library` and
  `select_plugin_device`, as the native and Rust helpers do: a device another library of the process already listed
  is used without registering the module again and is never reported as this helper's registration. OrchestrANT
  needs it to keep its current behaviour. Four cases, three mutations.

## 2026-11-25 — the Rust plugin helper can reuse another library's registration

- `shared/rust/ort_plugin_eps.rs` gains `append_provider_reusing_external`, the Rust form of the native helper's
  `reuse_existing`: a device another library of the process already listed is attached without registering the
  module again, and is never recorded as this registry's own. OxidANT needs it to keep using AccelerANTgine's
  registration in one app. Four cases, four mutations.

## 2026-11-24 — nine mutation shards, and the four slowest suites in sections

- Owner decision: both. The hub's mutation lane runs nine shards, and `source_ci/linux.py` reads the shard count
  from the tested revision's workflow instead of assuming eight.
- `test-docs-sidebars.sh`, `test-dead-functions.sh`, `test-mutation-gate.sh` and `test-runtime-push-queue.sh`
  have `-k` sections; each of their 143 recipes runs the cheapest section that bites it, proven here (the sidebar
  ones in the CI image). The push-queue suite's held upload, start wait and background job are three times
  shorter, and both of its "under 60 s" checks are now "under 20 s", so a mutant that waits them out still fails.
- The cost table gets a row per section, scaled from local runs; the next green run's logs replace them. The plan
  predicts about 17 minutes per shard, against 27 to 28 for three of eight before.
- The cost table is rebuilt from the nine green shard logs of run 45526187655; all 996 test commands now have a
  measured cost. That run's shards took 13 to 20 minutes.

## 2026-11-24 — An isolated web app on a docs site

- `linux/webserver/templates/flutter-web-isolated.htaccess` serves a cross-origin-isolated web app: COOP
  `same-origin`, COEP `require-corp`, `Permissions-Policy: camera=(self)`, the `.wasm` and `.mjs` types,
  `no-cache`, and `immutable` only under `ort/<version>-<build hash>/` and `models/<sha256>/`. Every directive
  is in FileInfo. `flutter-web.htaccess` is unchanged. Suite `test-flutter-web-isolated-htaccess.sh`; the
  htaccess suites share `htaccess-lines.sh`, which also sorts in byte order on any host locale.
- `build-docs.yml` takes `isolated-apps`: `docs-site.sh stage --isolated-app DIR` puts the template into a
  web app's directory below the site's root. OmniAccelerANT's `/app/` is the first.
- The link gate reads a root-absolute `<base href>` (`/app/`) from the site's root; it reported every link of
  such a page dead.
- `check-live-site.js --isolated` fails a route whose `crossOriginIsolated` is false and a base URL without
  COOP `same-origin` and COEP `require-corp`.

## 2026-11-25 — the TVM smoke reaches the shipped image and reads the right fact

- The runtime gate calls `smoke-torch-venv.sh` only with `STV_ASSERT_ONLY=1`, so `assert_tvm_codegen` never ran on a
  shipped venv; it runs there now. Its shared-LLVM check read the process map and failed on Torch-ROCm's own
  `libLLVM`, which a ROCm image always maps; it now fails only a `libtvm_compiler.so` that needs a `libLLVM`.
  Two cases, two mutations.

## 2026-11-24 — TVM links a private static LLVM

- `import tvm` crashed in about two of three ROCm app smokes: Torch-ROCm's own LLVM, loaded process-wide,
  interposed 117 references inside the shared `libLLVM.so.23.1` that TVM linked. `tvm.sh` now links the LLVM
  archives, which TVM hides, fails a `libtvm_compiler.so` that needs a `libLLVM` or exports `llvm::` symbols, and
  the runtime codegen smoke fails a process that mapped any `libLLVM`. An installed LLVM package maps `all` to
  nothing, so the patch takes the static targets from `LLVM_AVAILABLE_LIBS`; a version script keeps the inline
  `llvm::` members TVM's own objects instantiate local. Two suites, eleven mutations.

## 2026-11-24 — README words and width; the owner's NSIS answers

- `readme-length` holds every root README to 700 words and 160 characters a line besides its 100 lines (owner
  decision). Badge lines and lines that are only a link count for neither. A README already over them keeps rows
  in `readme-length.census` that may only fall, in the `doc-prose` census format; a consumer only reports until
  it seeds its census. Suite `test-readme-length.sh` gains `-k` sections and the family 22 recipes.
- The hub README is an overview again: 98 lines, 563 words and no line over 160 characters, from 2,353 words and
  28 wider lines (the widest 3,456 characters). The pages it links already held the detail.
- CON302 records the owner's NSIS answers and a sub-step for the CPack setups that ship LZMA without its
  CPL-1.0 notice. New: CON304, a shared case file for the usable-CPU rule.
- The consumer `AGENTS.md` template links `docs/writing-docs.md`.
- `test-gstreamer-original-notices.sh` has `-k notice|transport|package`, and each of its 73 recipes runs the
  cheapest section that bites it (34, 21 and 18). Every recipe ran all three suites before, about 30 s on the Pi;
  the three sections take 3, 10 and 17 s. Run 45421650403 on the fresh cost table was green, but three mutation
  shards took 27 to 28 of their 30 minutes.

## 2026-11-24 — the runtime storage guardian refuses a placement FINAL cannot read

- `launch-runtime-storage-guard.py launch` now requires the runtime's host tools checkout and revision and a directory
  beside the runtime output named `<output>-storage-guard`. Local FINAL reads an unloaded runtime's guardian only
  there; a guardian started from another checkout ran a whole runtime and was then unusable. One case, three mutations.

## 2026-11-24 — a Python mutant never runs the previous mutant's bytecode

- `verify_mutations.py` deletes a `.py` target's cached bytecode after writing each mutant and after restoring it.
  Python trusts a `.pyc` whose source size and mtime second match, so a same-size second mutant of one module ran
  the first one's code and survived on a fast host. `test-mutation-gate.sh` covers it; two mutations.
- The CON50 probe fixture carries its own `cargo` dispatcher and a planted host `cargo`, since the probe now asks
  `cargo <tool> --version`.

## 2026-11-24 — two runtime smoke probes read the shipped image correctly

- The `cargo-qa-tools` probe now asks `cargo <tool> --version`: `cargo-mutants --version` rejects the flag, so every
  amd64 image reported `cargo-mutants=` empty although 27.1.0 was installed.
- `Dockerfile.torch` ships `03-media/free-threaded-wheels.sh` and its twin table to `/opt/scripts/03-media/`; the
  FT-STORE probe sources them, failed without them and reported "the in-image probe never finished".
- `test-runtime-probe-inputs.sh` checks both against fake tools and the Dockerfile COPY lines; three mutations.

## 2026-11-24 — the Linux torch stage checks out OrchestrANT's hub submodule

- Since OrchestrANT 3abd84e (CON289) its `setup.py` copies hub modules from `third_party/ANTfrastructure`, and a clone
  without that submodule fails `uv sync` ("verify_ort_profile.py is missing"). The Windows torch stage hit it first
  and checks the submodule out since this hub's windows-torch commit; `assemble-torch-app.sh`'s `fetch_app_tree` does
  the same now, `--depth 1` and not recursive, before its next app ref reaches the error. One case, one mutation.

## 2026-11-24 — the mutation shard plan has fresh costs

- `docs/scripts/mutation-costs.json` is rebuilt from the cost lines of run 45373701267 (all eight shards) and
  run 45404285986 (the seven green ones). 469 of 950 test commands had no cost and were planned at the median,
  1.2 s per entry. Shard 3 then drew `test-gstreamer-original-notices.sh` (73 entries at about 25 s) and was
  cancelled at its 30-minute timeout. Now 949 commands have a cost; only `test-doc-prose.sh -k hub` is missing.
  The new plan gives every shard the same predicted load, 17 % below the old plan's heaviest shard.

## 2026-11-24 — docs get a style page, a glossary, a decisions page and a prose ratchet

- Priority 4 in `AGENTS.md` is narrower (owner decision, docs audit): `AGENTS.md` changes only for a new or
  changed rule, the README only for a new entry point, a mechanism goes to the `docs/` page that owns it and
  history comes here. Dates, decision ids, run ids and hashes stay in this file, `BACKLOG.md` and the new
  `docs/decisions.md`.
- New pages: `docs/writing-docs.md` (twelve rules, each with a before and after from a real page, and
  templates for a topic page, a failure entry and an `AGENTS.md` "Common tasks" block), `docs/glossary.md`
  (twelve family terms as the docs use them) and `docs/decisions.md` (the owner decisions the docs cite, each
  with its date and reason).
- New gate `doc-prose` (`linux/scripts/verify_doc_prose.py`): per page the average sentence length, the share
  of sentences over 30 words, dates and ids per 1000 words and bold per 1000 words, frozen in
  `docs/scripts/doc-prose.census`. A value may only fall; a page without rows meets fixed limits (22 words, 15 %,
  2 per 1000); the `AGENTS.md` word count is a row too, against a target of 6000 here and 3000 in a consumer.
  It runs in preflight and the commit hook, and through `run-lint-gates.sh` in every consumer, report-only until
  the consumer seeds its census. Its splitter keeps list items apart and skips reST directives, so a generated
  page no longer reads as one 1393-word sentence. Suite `test-doc-prose.sh`, 39 recipes.
- BACKLOG: CON302 (an NSIS setup beside MSI and MSIX, with the owner's decisions and the steps) and CON303 (the
  remaining docs phases).
- Home Assistant's runtime `config/ip_bans.yaml` is ignored, so it is never committed.

## 2026-11-24 — :winarm64 carries the 946c1637 bundle

- The ARM64 bundle built at `946c1637` passed its smoke gate and all 22 device steps. `:winarm64` now points at
  `sha256:f0a860faba4629ff51897ffacef8de1905928902011c062459102991b6260a75`, promoted by
  `windows-arm64-acceptance.py`, and the six consumers' Windows lanes were dispatched on it
  ([acceptance](docs/windows-cross-builds.md#accept-an-arm64-image-before-moving-its-tag)).
- Test fixtures no longer name the build host's LAN addresses: the image-env and sccache-level suites use
  `10.255.255.16`/`.26`, which the leak gate still flags as private, and `Set-SccacheS3Level.ps1`'s example uses
  `192.0.2.26`.

## 2026-11-24 — the old public nvidia stage tags and two legacy packages are gone

- With the owner's approval, `ghcr-delete-tags.sh` deleted `cross-toolchain-nvidia-amd64`, `cross-media-nvidia-amd64`
  and `cross-android-nvidia-amd64` from the public package; they carried TensorRT SDK files from before the stage
  images moved to the private `-stages` package. The packages `kataglyphis_beschleuniger_windows2025` and
  `kataglyphis_beschleuniger_test`, untouched since 2025, were deleted whole. No repository named any of them. A dry
  run selected exactly these versions first; afterwards all five answer 404 and the public tags resolve unchanged.

## 2026-11-24 — old candidate tags go on a list for approval

- 15 versions of the public package (about 223 GB) carry only `candidate-*` tags, which never expire.
  `linux/host-config/ghcr-candidate-tags.py` lists those older than 30 days with the tracked files that name
  them, and prints the `ghcr-delete-tags.sh` command; it deletes nothing. None is old enough today; the first
  qualify from 2026-11-26. `ghcr_candidate_tags_tests.py` and one mutation
  ([B8](docs/linux-host-setup.md#b8-ghcr-registry-hygiene)).

## 2026-11-24 — the weekly GHCR prune covers the private stage package

- `ghcr-cleanup.yml` also prunes `kataglyphis_beschleuniger-stages`, which held about 167 GB in 30 untagged versions
  no tag references. Its `MIN_TAGS` guard is 3 for that package only, since it carries one tag per nvidia stage.
  A local dry run kept the 6 tagged versions and planned the other 30. `ghcr_cleanup_workflow_tests.py` and two
  mutations hold both steps ([B8](docs/linux-host-setup.md#b8-ghcr-registry-hygiene)).

## 2026-11-24 — CI artifacts keep days, not the 90-day maximum

- An audit of the 13 public repositories found 1.64 TB of Actions artifacts. Every package upload of the
  shared lanes kept the 90-day maximum. `python-ci-linux.yml`, `python-ci-windows.yml` and
  `container-ci-windows.yml` now keep package and report artifacts 30 days on `main`, 14 on `develop` and
  5 elsewhere; the new `artifact-retention-days` input overrides it. Same-run hand-offs keep 1 day, and
  `winarm64-bundle` 2 days on its daily run and 14 on a manual candidate run. `artifact_retention_tests.py`
  and three mutations hold it ([policy](docs/python-ci.md#how-long-the-artifacts-live)). Existing artifacts
  keep their old expiry.

## 2026-11-24 — the ARM64 acceptance tool is versioned

- `linux/scripts/local-proof/windows-arm64-acceptance.py` replaces five ignored handoff scripts. It uploads
  the graded `bk-winarm64` image by digest, checks a device run's receipt and log, and moves `:winarm64` only
  with `--apply`. A device run on a later `develop` commit counts only when no path between the image source
  and that commit lies in the Windows build closure. The tool derives that closure from the Windows
  Dockerfiles' context copies and bind mounts, plus `windows/`, the host-read pin files and `.dockerignore`;
  a coarse prefix list first blocked Linux-only commits. `windows_arm64_acceptance_tests.py` and four
  mutations cover the refusals ([procedure](docs/windows-cross-builds.md#accept-an-arm64-image-before-moving-its-tag)).

## 2026-11-24 — the docs match the tree again, and name no host

- The build host's name is gone from every tracked file; the Home Assistant notes write the MQTT broker as
  `<mqtt-host>:1883`.
- No home host name or LAN address is left in the tree (owner decision): the fleet's hosts are `catcam-2`,
  `sbc-1` and `win-1` in the inventory, the README tables and the LLM registry, the Windows host's setup
  script is `setup-win-1.sh`, and addresses are placeholders. On a control node, rename `host_vars/<old>.yml` to the new
  key and make `win-1` resolve for `backends.json`. Home Assistant ids that hold `mintberry` stay, since a new
  `unique_id` would start the cam's long-term statistics from zero.
- `code-quality-tooling.md` carried an older second copy of its mutation-gate sections behind a broken heading.
  The copy is gone, `## Doc numbers are derived` is whole again, and the pre-push section names the image-runner
  retry. The warning census section says how a consumer's CI runs it; it is not a preflight slug.
- Stale facts fixed against the tree: `jq` is in the Linux image, the action, reusable-workflow and consumer
  counts, the `#requires` exceptions, the hook suite paths, the doc gates, where host-tool checksums live, what
  `sync_versions.py` rewrites in the docs, the `01-core` count and two contradictions in `failure-modes.md`. The
  adoption checklist now lists `.github/consumers.json`, and two done backlog items are pruned.

## 2026-11-24 — the no-push runtime wrapper finds its wheelhouse again

- The local wheel context keeps the stage name `runtime_wheels` instead of a digest-pinned image
  reference, which BuildKit sent to the registry. The fix existed on an unmerged branch since
  2026-11-14 and is now on the main line.
- `launch-normal-runtime.py --runtime-source` accepts a later commit on a verified Android parent
  when only host-only runtime files differ among the base-to-Android inputs.

## 2026-11-24 — CON295 (c) is done in AccelerANTgine

- AccelerANTgine went through all three warning steps: its x64 lanes hold their own warnings with
  `verify_warning_census.py` (GCC 16, clang 48, matched exactly in CI), it fixed them down to a doxygen note on a fuzz
  test (b96099a4), and its library, CLI and demo build with `-Werror` (`/WX` under clang-cl) on every lane (4eac5a56).
  Two lessons for the next consumer, in CON295: CMake compiles an imported module's BMI with the importing target's
  flags, so a dependency module's own warnings (GCC's TU-local ones in nlohmann) need `-Wno-error`; and SYSTEM on
  Abseil breaks clang-cl's parse of its `function_ref.h`, so it is SYSTEM for GCC and clang only.

## 2026-11-24 — the Linux torch stage checks out OrchestrANT's hub submodule

- Since OrchestrANT 3abd84e (CON289) its `setup.py` copies hub modules from `third_party/ANTfrastructure`, and a clone
  without that submodule fails `uv sync` ("verify_ort_profile.py is missing"). The Windows torch stage hit it first
  and checks the submodule out since this hub's windows-torch commit; `assemble-torch-app.sh`'s `fetch_app_tree` does
  the same now, `--depth 1` and not recursive, before its next app ref reaches the error. One case, one mutation.

## 2026-11-24 — the Windows torch stage checks out the app's hub submodule

- `uv sync` of OrchestrANT failed in `Dockerfile.torch`: since OrchestrANT `3abd84e` its `setup.py` copies hub
  modules from `third_party/ANTfrastructure`, and `New-TorchAppCheckout` cloned without submodules. It now
  initializes that one submodule shallowly, without nested ones. `TorchApp.Checkout.Tests.ps1`, one mutation
  ([failure mode](docs/failure-modes.md#torch-stage-verify_ort_profilepy-is-missing--check-out-the-hub-submodule-before-building)).

## 2026-11-24 — every Windows wheel install pins packaging

- The arm64 media merge refused the same mixed `packaging` after the TVM fix below: `wheel` also pulls
  `packaging`, and the TVM cross path, IREE, FFmpeg and GenAI installed `wheel` without it.
  Each of those `Install-CpythonPipPin` calls now names `packaging`, and `Build.PipPins.Tests.ps1`
  treats `wheel` like the other build tools; one mutation
  ([failure mode](docs/failure-modes.md#windows-media-merge-a-merge-would-leave-a-mixed-install-pin-one-version)).

## 2026-11-24 — the TVM branch pins packaging with its build tools

- The Windows media merge refused `packaging` 26.3 from media-core beside 26.4 from TVM: TVM's branch
  installed `scikit-build-core` and `setuptools-scm` before it had `packaging`, so pip took the release that
  appeared between the two builds. `Build-TvmFromSource.ps1` now names `packaging` in that pinned install, and
  `Build.PipPins.Tests.ps1` fails a call that installs either tool without it; one mutation
  ([failure mode](docs/failure-modes.md#windows-media-merge-a-merge-would-leave-a-mixed-install-pin-one-version)).

## 2026-11-23 — build ROCm Media from a reviewed newer source on the same GPU parent

- `launch-normal-media.py --media-source/--media-source-proof` accepts a later commit when it
  descends from the GPU source, has its own complete preflight and leaves every compiler, SDK
  and GPU input byte-identical. The Media export recomputes that review.

## 2026-11-23 — fetch ONNX Runtime sources by verified commit with fork fallback

- Microsoft's ONNX Runtime, GenAI and onnxruntime-extensions repositories return 404.
  Linux Media and Android now fetch each source through `source-fetch.sh`: the upstream tag
  first, then the pinned commit from fork networks, and every checkout must match its pin.
- GenAI builds against the verified extensions checkout instead of cloning it in CMake.
  The Windows lane still clones the Microsoft URLs and remains blocked.

## 2026-11-23 — refresh SDK fallback fonts for Flutter 3.50.1

- Pin every Noto Color Emoji v39 and Noto Sans Symbols 2 v25 chunk requested by
  the built Flutter SDK, with SHA-256 verified against the original font downloads.

## 2026-11-23 — the MSVC runtime notice is final (CON228)

- `cmake/msvc-runtime-notice.txt` loses its DRAFT line and names the Visual Studio license terms as the governing
  text; it pointed at Redist.txt, which only lists the redistributable files. It now says the DLLs are unmodified,
  that installing or using the package means agreeing to those terms, and links the license terms beside the
  redistribution list. The owner approved the wording after a check against the Distributable Code conditions:
  MIT projects meet the Excluded License condition and an MSI shows the notice on the accepted licence page; for a
  ZIP or MSIX, which only carry it, Microsoft's text does not say whether that counts as agreeing
  ([`third-party-licenses.md`](docs/third-party-licenses.md#the-msvc-runtime-notice)).

## 2026-11-23 — an install tree refuses build-time files (CON299)

- `Assert-InstallTreeLayout` (WindowsCrossBundle.Common.psm1) and `New-PortableBundle -ForbidBuildTimeFiles` refuse an
  install tree with headers, CMake or pkg-config packages or import and static libraries in it, naming the count and
  the first files; `-Allow`/`-AllowBuildTimeFile` except what a product ships on purpose. BeschleunigerBallett's
  Windows bundle had shipped 52 gtest and gmock files (found by its CI track). `check-install-tree.sh` is the Linux
  twin with the same rule. Opt-in, so no consumer turns red before it chooses; one Pester case, one shell suite, three
  mutations.

## 2026-11-23 — the warning census (CON295 (c) step 2)

- `linux/scripts/verify_warning_census.py` is the per-repo warning ratchet the owner chose today: it counts a
  lane's GCC and clang warnings in the repository's own code, each `path:line:flag` once, and holds them at the
  `<lane> | <flag> | <count>` rows of a committed census file. Growth fails, and so does a drop until the row is
  lowered in the same commit; a log that compiled nothing fails rather than read as zero. BeschleunigerBallett's GCC
  job reads 37 own warnings over six flags. `test-warning-census.sh`, six mutations; clang-tidy findings, which name a check and no -W flag, do not count. The consumers wire it next.

## 2026-11-23 — IWYU's fatal errors are unread units

- `code_quality_run_iwyu` counted only `: error:`, but IWYU writes `: fatal error:` for a missing header, so a
  planted one stayed green in BeschleunigerBallett (found by its CI track). It counts both; one case, one mutation.
  `failure-modes.md` explains why GCC still warns in a SYSTEM header at an LTO link (spdlog's 8
  `-Wstringop-overflow` in BeschleunigerBallett's profiling job), and CON299 queues a shared check that refuses
  build-time files in an install tree.

## 2026-11-23 — RustDesk on a Windows host: Chocolatey updates, direct IP access, the permanent password

- `docs/windows-host-setup.md` gains Phase F, the Windows counterpart of the Linux page's RustDesk phase.
  winget has no RustDesk package and Scoop's is the portable exe without a service, so
  `Install-RustDesk.ps1` installs and updates Chocolatey's `rustdesk.install` (the official MSI) and
  registers the weekly SYSTEM task `RustDesk Update (choco)`. It backs up both config directories first,
  refuses while a session is open, and runs Chocolatey's installer only with a valid Chocolatey Software
  signature. `Set-RustDeskDirectAccess.ps1` turns on direct IP access and proves a RustDesk listener on
  the port; `Set-RustDeskPassword.ps1` sets the permanent password, which RustDesk never shows again.
- `WindowsRustDesk.Common.psm1` holds the CLI calls: `rustdesk.exe` is a GUI-subsystem binary that
  prints only into a pipe, `--option` reads every value back, and the missing-admin reply becomes an
  error. `Host.RustDesk.Tests.ps1` adds ten cases against a fake CLI; nine mutations all go red. Proven
  on one host: 1.4.6 → 1.5.3 kept its config, and 1.5.3 listened on `[::]:21118` without a restart.

## 2026-11-23 — an IWYU report is green only when every unit was read (CON295 (a))

- `code_quality_run_iwyu` read only the log's error lines, so a missing driver (status 127), a driver that stopped
  on a compile-DB failure, and a unit absent from the compile DB each reported green with every unit "read"
  (found by the Windows session in issue #249, confirmed with the official IWYU 0.23 `iwyu_tool.py`: 0 of 1 and
  1 of 2 units ran). Under `set -e` the same function aborted on the driver's suggestion status or on a log
  without errors. Each requested unit must now appear in the log with an include list or as correct, matched by
  path suffix; the driver status is captured and only reported. `CODE_QUALITY_IWYU_TOOL` and its `env-knobs`
  allowlist entry are gone: the driver comes from `PATH`, as the fixture already supplied it. Five new cases in
  `test-code-quality-iwyu.sh`, four mutations.

## 2026-11-23 — workflow_run filters are graded as GitHub patterns

- `verify_workflow_conventions.py` gains its sixth check, `run-filter`, armed from the start: each
  `on.workflow_run.workflows` entry is read with GitHub's filter grammar (`*`, `**`, `?` and `+` repeating the
  character before them, `[...]` with only a-z, A-Z and 0-9 ranges, `\` escapes) and must match a workflow's name
  in the tree. Every consumer's `retry-disk-refusal.yml` named its lanes as `"... build + test"`, where `+` repeats
  the space, so the filter never matched and a disk refusal on those lanes was never retried; BeschleunigerBallett's
  `[ci <lane>]` was no valid pattern and started a phantom run on every completed workflow (found by its CI track,
  fixed there in e6832053). The hub's own `'Docs · build \+ publish'` is escaped; the consumers escape theirs at
  their next pin (OxidANT 4, AccelerANTgine 3, OmniAccelerANT 4, OrchestrANT 3, WebDavClient 2 filters). The
  README says the names are patterns. `test-workflow-run-filters.sh`, three mutations.

## 2026-11-23 — hardening's PIE reaches a target from any scope (CON297)

- `myproject_enable_hardening` set `CMAKE_POSITION_INDEPENDENT_CODE` in the caller's scope: called from a function,
  such as BeschleunigerBallett's `myproject_enable_local_hardening`, it stayed in that function and reached no target,
  so BeschleunigerBallett's executables were PIE only through clang's default (found by its CI track). A real target
  now gets `POSITION_INDEPENDENT_CODE` itself, and an INTERFACE target hardened from a function warns that its PIE
  reaches nothing; at the project's scope the variable is set as before. Three cases in
  `test-cmake-hardening-linux.sh`, two mutations.

## 2026-11-23 — the quality report skips agents-drift without a docs table (CON298)

- `quality-report.sh` called a consumer without a `[docs]` table "incomplete": the `agents_drift` collector ran
  `verify_agents_drift.py`, which refuses such a repo, and turned the refusal into a failed metric, so
  `code-quality-report.yml` with `quality-report: true` failed though agents-drift is scoped to the AI consumers
  (found by BeschleunigerBallett's CI track, which declared a table to get past it). The collector now reports the
  metric as not collected, "no [docs] build_list and source", as it does for a repo without `AGENTS.md`; one test
  and one mutation. CON295 records AccelerANTgine's IWYU wiring (0126297) and BeschleunigerBallett's SYSTEM
  includes (a9333e7e); CON297 records that the hardening module's PIE reaches no target from a function.

## 2026-11-23 — IWYU reports on the units without modules (CON295 (a))

- IWYU never ran: `myproject_apply_iwyu` set the property on the INTERFACE target `myproject_options`, which reaches
  no compile, and the image's `include-what-you-use` 0.23 is built on clang 19, so it cannot load the clang 23
  build's module files ("PCH file uses a newer PCH format"). The owner chose a report on the plain units:
  `code_quality_find_iwyu_files` lists the units that neither declare nor import a module (5 of AccelerANTgine's 37,
  35 of BeschleunigerBallett's 121), and `code_quality_run_iwyu` runs `iwyu_tool` over them and counts the files
  with suggestions. Suggestions stay green; a unit IWYU could not read is red. `myproject_ENABLE_IWYU` is now OFF.
  `test-code-quality-iwyu.sh` covers the selection and the verdict, with three mutations.

## 2026-11-23 — CON288 done: every contract case replays in its bindings

- **CON288 is done.** Each shared case file the oxidation roadmap asked for exists and replays where it belongs: the
  D8 stream cases and whole answers (OxidANT c10095f, OrchestrANT 9c3882b, OmniAccelerANT 20c940a), the think split
  (OxidANT 5bf5639, OrchestrANT 3abd84e, OmniAccelerANT 2620136), the fixture's refusals (OxidANT 5bf5639, OrchestrANT
  3abd84e, AccelerANTgine 5207eb7), and ModelANT's full-size frames by tensor digest and raw-head cases (ModelANT
  b47ed40 and f845b60). All three detectors match the four frames bit for bit (OrchestrANT 2d82f87, OxidANT c881224,
  AccelerANTgine cedb886); OrchestrANT and AccelerANTgine replay the raw heads, and AccelerANTgine's suppression now
  sorts stably, so equal scores keep the lower candidate (D6). OxidANT decodes no raw head. AccelerANTgine's think
  split rides its text pilot, OxidANT's roadmap step 4.

## 2026-11-23 — CON289 done; CON288's cases replayed in every binding

- **CON289 is done:** no consumer keeps its own ORT-profile count. OxidANT dropped its copy earlier (56865c4), and
  OrchestrANT's `setup.py` now copies `shared/python/verify_ort_profile.py` into `orchestrant/_hub` at build time,
  where Cython compiles it into the wheel, while a checkout reads the hub's file itself (OrchestrANT 3abd84e; ce48210
  keeps the copy in a wheel built from the sdist, which carries no `third_party`). Its bundle's
  `ort_profile.operator_counts` calls the hub's rule.
- **CON288:** every binding replays the new cases of (a) to (c): the D8 stream cases in OxidANT, OrchestrANT and
  OmniAccelerANT, the think split in all three, and the fixture's refusals in OxidANT, OrchestrANT and
  AccelerANTgine, whose C ABI gains status 11 for `context_length_exceeded`. (e) is in ModelANT b47ed40:
  four full-size frames compared by tensor digest and seven raw-head decode cases under D6.

## 2026-11-23 — the think split, the fixture's refusals and an importable ORT count (CON288 (b), (c); CON289)

- `shared/contracts/think-split.json` maps a reply's text pieces to `shown`, `answer` (OxidANT's per-block rule),
  `final` (the lab's text after the last `</think>`), the thinking count and the late closes, owner decision D5.
  `final` stops at a `<think>` that opens after the last close and never closes (owner, 2026-11-23): the lab graded
  `X<think>b` for such a reply, against its own comment that an unclosed block holds no answer. A late close inside
  one piece hides the text before it, as the web shows it. `test-think-split.sh` replays the 11 cases through a
  reference splitter, and two recipes guard the cut and the hidden text.
- The tiny-model fixture gains five cases refused before GenAI runs: a role outside the four, a NaN temperature, the
  prompt and the budget over the context (`context_length_exceeded`, D7), and a NUL byte in a message and in a stop
  string. JSON holds no NaN, so the case writes `"temperature": "NaN"` and each binding's replay turns it into a
  float NaN (owner, 2026-11-23).
- `shared/python/verify_ort_profile.py` exports `model_nodes` and `operator_counts` (CON289), which its `main` uses
  and a test imports; `packaging.ort-profile-require-operator` points at the function's indentation.
- **Consumers:** the bindings fail the new fixture cases and the think-split file at their next pin until they map
  `context_length_exceeded`, pass `temperature` and `stop`, and follow the split; OrchestrANT copies the ORT count in
  at build time (owner, 2026-11-23).

## 2026-11-22 — continue the local NVIDIA Android export through runtime and FINAL

- Launch the amd64 and arm64/SBSA runtime from the verified same-target Android
  export. Use the NVIDIA GPU ORT and CUDA Torch packages, the amd64 Android
  wheelhouse export and the target runtime wrapper.
- Bind the original Android, Media and runtime receipts in local FINAL. Check
  the recorded runtime environment and worker closure before the complete
  consumer plan. Actual builds and consumer acceptance remain pending.

## 2026-11-22 — carry NVIDIA Linux Media through the Android stage

- Use the same-target NVIDIA Media receipt to launch Android on amd64 and
  arm64/SBSA. The OCI exporter checks inherited accelerator settings and all
  Media ancestor layers and requires a target-suffixed runtime context.

## 2026-11-22 — bind NVIDIA Linux GPU and WebGPU Media to the target SDK

- Add local amd64 and arm64/SBSA GPU and Media launch/export profiles. Bind
  the exact SDK source, target-specific image config, immutable native OCI
  ancestry, both required Media Wasm modes and the 300-GiB Media floor.
  Ordinary ROCm Media now uses the same launch floor.
- Synthetic OCI tests cover the launcher and export contracts. Fresh builds,
  downstream runtime/FINAL acceptance and physical GPU tests remain pending.

## 2026-11-22 — continue default Linux Android through runtime and local FINAL

- Launch the existing runtime chain for default amd64, arm64 and riscv64 from
  same-target stopped Android receipts. Local wheel exports use the artifact's
  build-host platform and the runtime build uses the target platform.
- Retain exact parent/source bindings through the six-consumer local FINAL
  entry and use the same 300-GiB runtime admission. Synthetic transport and
  receipt tests exercise these paths. Fresh builds and acceptance are pending.

## 2026-11-22 — continue default Linux Media through native Android handoffs

- Extend the existing OCI export and ordinary Android launch entries to the
  default amd64, arm64 and riscv64 chains. Bind target-specific receipts, baked
  cross environment, immutable SDK/Media parent, both Media Wasm modes and all
  ancestor layers. Keep the ROCm command defaults and current disk admission.
- Test all three command and receipt paths with synthetic OCI data. Actual
  foreign Media/Android builds, runtime and FINAL acceptance remain open.

## 2026-11-22 — qualify arm64 and riscv64 SDKs for default Media

- Bind the foreign SDK receipts to the matching producer, Linux amd64 image,
  target LLVM drivers and C/C++ QEMU smokes in both shell modes. Reuse the
  compiler OCI ancestry checks and the ordinary Media launcher's disk guard.
- Add fixture and mutation controls for target selection and receipt coverage.
  The actual foreign SDK builds, Media exports and factory replays remain open.

## 2026-11-22 — replay the delivered WebGPU Wasm factories

- After JS staging, strict Linux Media builds run the Asyncify and JSPI factory
  checks against the delivered modules. The replay also runs on shared output
  cache hits. Preserve ordinary receipt-only checks and the explicit
  disabled-flavor path.

## 2026-11-22 — retain live OpenCV cache diagnostics

- Add an OpenCV Media phase to the shared read-only cache log reader. Require the
  outer build command and its final cache drain before allocating evidence.
- Test both Dockerfile RUNs and reject the inner build command, dependency setup
  and a missing drain. The full OpenCV compiler-cache measurement remains open.

## 2026-11-22 — keep the shared Python registration protocol valid under dead-code grading

- Mark the unused positional-only library parameter in the runtime-binding protocol explicitly
  unused. Preserve its argument order, types and positional-only contract; registration behavior
  and owning-binding state remain unchanged.
- The ordinary consumer Vulture gate exposed the defect at its existing 100-confidence bound.
  Retain that bound and the shared-asset equality check; a real-analyser consumer regression
  checks the mirror rather than adding a private copy or quality exception. This proves no
  native loading, compiled consumer package or GPU inference.

## 2026-11-22 — assemble closed direct-wrapper source receipts

- Preserve complete direct-wrapper preflight receipt assembly with exact suite/mutation evidence, canonical runner library exclusions and regular-file discovery, original cleanup identity and fresh absence queries. Never reconstruct driver metadata, re-seal a stopped unit or repeat exclusive cleanup.

## 2026-11-22 — keep native file-status fallback compatible with consumer guards

- Compare the already queried file-status enum when distinguishing optional absence from a broken bundle link. This preserves resolution and native error behavior while exact C++ consumer mirrors retain their conservative no-throw source guard. Re-key the existing broken-link mutation to the new expression; no quality threshold or exclusion changes.

## 2026-11-22 — explicitly reuse externally registered native plugin devices

- Add an append opt-in for a device another library already registered in the owning ORT environment. Preserve module checks, registry-owned path bindings, exact device selection and raw failures; external factories do not enter the owned-registration report. Default append and explicit registration retain their existing behavior.
- Add compiled fake-API controls and mutation recipes for the opt-in, strict defaults, failed enumeration and external ownership. These checks do not authenticate an external factory or prove a native consumer, package or GPU.
- Validate that every new native variant compiles and links before it fails a policy assertion or independent count. Preserve compiler, linker and abnormal-exit refusals and mutation-test the validator itself; separate object compilation makes the fixture compiler cache usable.

## 2026-11-22 — verify packaged image source originals byte for byte

- Add a shared finished-file checker for staged original trees and their original manifest, preserving exact bytes, selected scope and raw verifier failures.
- Keep empty sources forbidden by default; allow explicitly selected empty members and forward that permission through native AppImage extraction only for recorded source patches.
- Share Flatpak's private import/checkout between text and binary checks; the fixture declares its actual defaults and omits unused controls. Share exact member-name validation and drive empty-source CLI cases through one Python fixture. Preserve default ZIP/TAR/DEB/MSI verdicts and native architecture/path checks.
- Add synthetic archive, real DEB, controlled native-extraction and conditional real Flatpak controls. Actual rebuilt images and application packages, complete binary/source licences and GPU inference remain separate requirements.

## 2026-11-22 — transport selected image source originals

- Add a reusable consumer stager for the reviewed GCC and GStreamer original trees, retaining exact notices, source records, working context and patches. Validate selected inputs before fresh output allocation.
- Share bounded file validation and fresh writes with the GStreamer producer; retain its narrow Dockerfile companion mount and required API checks. Copy the two media smoke siblings together without increasing the frozen Dockerfile size.
- Add synthetic transport/refusal and mutation controls. Actual rebuilt images, consumer integration, finished packages and complete native licences and corresponding sources remain open.

## 2026-11-22 — read equivalent systemd cleanup arguments

- Accept joined and separated systemd `ExecStopPost` arguments when assembling a complete-preflight receipt. Require exactly one across all forms; keep the executed argv unchanged and retain every source, mutation, owner, cleanup and engine-query check.
- Add end-to-end synthetic CLI regression controls and parse-valid mutations. Preserve the original successful 753e source run and failed receipt assembly separately; tooling replay does not qualify a new production commit.

## 2026-11-22 — retain complete isolated preflight transcripts

- Save the worker's own stdout and stderr through the existing evidence bind before container cleanup. Keep the attach stream separately; a missing or linked transcript fails even after engine exit zero. Preserve raw command/cleanup statuses and every existing full-source acceptance gate.
- Retain the original f715 command/cleanup zeros, outer extraction failure and incomplete attach log. Its 7,714 mutation cases are byte-verified; missing outer groups/footer and failed later cleanup still prevent full qualification. Add transport/status fixtures and semantic mutations; a new exact-source full run remains required.

## 2026-11-22 — integrate exact-source Windows evidence with develop

- Document the existing Ninja generator prerequisite for compiler-less CMake checks in Windows Git Bash when nmake is unavailable; preserve every assertion and mutation gate.
- Split free-threaded bootstrap and owned-container fixtures into shared companions while retaining every test and the original selected source/fixture lifetime; keep the unchanged file-size gate.
- Preserve both source histories, every mutation ID from both histories and the Windows harness's existing closure while adding upstream PE hardening fixtures. Keep strict exact-commit patch acceptance and both Git fixture environment protections. Add six actual refusal mutations for the incoming PE-hardening gate; synthetic PE tests do not prove real linker output.
- Record the complete local `79e41b6b` NVIDIA producer and separate CUDA repeat: 6,304 primary hits, including 605 NVCC hits, zero misses/cache/compiler errors at that point. Its two original smoke skips have separate exact-image CPU/CUDA/TensorRT/DirectML and negative Pad/MaxPool receipts; they do not qualify another source.
- Preserve CPU raw outcomes `[1,1]`: TVM/IREE exported successfully, but the unchanged 45-GiB guard stopped before Media-Merge at 29.5 GiB. The completed non-admin cleanup freed about 66 GiB, kept all 22 image identities and six compiler caches, and still missed the 100-GiB full-build target.
- Keep GStreamer's measured 102 cache errors and 32 failed compiler requests unclassified. Final-source quality, four whole lanes, physical AMD/ARM64 checks, hosted CI and digest-specific ARM64 acceptance remain open; CON228 stays OPEN/DRAFT. Git integration and unused worktree retirement are separate operations.

## 2026-11-22 — the OpenAI contract cases of owner decisions D7 and D8 (CON288 (a), (d))

- `shared/contracts/openai-stream-lines.json` gains 11 cases for D8: any non-null `error` fails the stream (`false`,
  `""`, `{}` and an object without a message among them, matched by the error's JSON text), and so does a chunk that
  is not an object; a `null` error is none; nothing after `[DONE]` is read; the finish reason keeps its raw value
  (`content_filter`); usage counts prompt and completion alone, beside `total_tokens` and `reasoning_tokens`; a
  whole-number float counts, and a negative count is missing, which leaves the usage null.
- The sibling `shared/contracts/openai-chat-answers.json` holds 10 whole, non-streamed answers under the same rules:
  content and reasoning under either name, a raw finish, usage, error objects, and bodies that are not an object or no
  JSON. `test-openai-stream-lines.sh` checks the shape of both files and now allows a raw finish reason;
  `lib.openai-stream-lines-shape` mutates a count negative instead, as its old `truncated` finish is legal now, and
  `lib.openai-chat-answers-shape` drops an outcome field.
- `docs/language-ai.md` states the D8 rules and lists `context_length_exceeded` among the text-contract failures
  (D7), which `orchestrant-serve` answers with HTTP 400.
- **Consumers:** OxidANT's `endpoint.rs`, OrchestrANT's `answers.py` and OmniAccelerANT's `endpoint_reply.dart`
  replay every stream case, so the new ones fail each at its next pin until its reader follows D8.

## 2026-11-22 — shared immutable native-helper packaging

- Add explicit byte-preserving Linux helper launchers with private library paths on both loader branches, unchanged arguments and raw worker exit statuses. Refuse legacy RPATH, linked or escaping inputs, existing payloads and mismatched launcher policies.
- CMake accepts installed-relative `IMMUTABLE_HELPERS`, protects their native payloads during ELF closure, checks their hashes after closure and composes helper and ORT protection in one AppImage patcher. Literal paths and unique basenames prevent ambiguous staging.
- Real ELF, relocation, TGZ and DEB fixtures exercise the shared transport. Finished consumer packages, actual AppRun, hardware inference and complete licence closure retain their separate proof requirements.

## 2026-11-21 — preserve selected GStreamer source notices before cleanup

- Retain distinct original monorepo and Rust-plugin notices, source commits, tracked patches and the GTK4 package's own version under the GStreamer prefix.
- Require reviewed release/commit/hash bindings and unchanged original Git bytes; missing, linked or reused paths and native/cross staging failures abort before cleanup.
- Add real-Git synthetic byte/refusal and conditional-call controls. Actual rebuilt images, finished packages and complete native/transitive licence and corresponding-source closure remain required.

## 2026-11-21 — preserve original GCC runtime notices before source cleanup

- Require the original GPL and runtime-exception texts to match the same build's source archive, then retain both under the installed GCC prefix with the archive SHA512 and canonical source URL.
- Preserve raw staging failures before cleanup, including conditional callers; reject missing, empty, rewritten or linked inputs and linked output paths.
- Add synthetic transport and refusal controls. Actual rebuilt images, consumer package staging and the complete native licence closure remain required.

## 2026-11-21 — retain repository origins in independent source copies

- Preserve locally configured origin URLs, their order and literal values when copying committed, recursive or staged sources from local objects. Workflow checks retain the original repository identity instead of the local source folder name.
- Add real local-Git controls for recursive/working copies, absent origins, multiple values and fatal configuration failures. This metadata does not authenticate sources or prove workflow/build acceptance.

## 2026-11-21 — admit default amd64 WebGPU Media from its SDK

- Add a dedicated owned launcher using the canonical default Media command and existing native SDK/OCI qualifier, exact source proof, compiler ancestry and shared bounded admission.
- Retain both required Wasm modes, explicit accelerator flags and a 300 GiB durable-storage minimum, including stricter caller reserves. Bind SDK/source/parent and launcher bytes; reject optimized Python before shared parent assertions.
- Add synthetic positive/refusal and mutation controls. Other foreign/NVIDIA profiles, actual Media builds, factory replay and FINAL acceptance remain open.

## 2026-11-21 — isolate cache diagnostic defaults and derive gate counts

- Keep the compiler-cache report fixture's automatic address independent of inherited socket/port settings, and prove an explicit caller socket still appears in the report. The production capture environment is unchanged; a new mutation must break the isolated default case.
- Refresh quoted manifest and dead-function figures with the existing measured updater; stale documentation cannot supply a green baseline for its mutation controls.

## 2026-11-21 — retire closed copied package staging

- Add a preview/apply worker restricted to a closed producer's three copied package trees. Bind fresh unit/container/mount observations, exact staging identity and snapshots, and all three retained archive hashes; preserve sources, targets, home caches and receipts. Temporary fixtures and require-removal mutations cover refusals without asserting host authenticity or archive validity.

## 2026-11-21 — exact binary checks for finished Linux packages

- Extend the shared streaming binary verifier to extracted directories, TAR and DEB payloads. Retain exact member names, duplicate/case/alias refusals, regular-file requirements and complete hashes; one conventional TAR root prefix is accepted without accepting duplicate aliases. Share the checked dpkg stream with the text verifier and preserve failed native transport status.
- Add a native AppImage binary entry point using the same architecture, selected-path, extraction and cleanup helper as licence checks. Synthetic fixtures cover large payloads, final-byte changes, symlinks, duplicates, malformed paths and raw extractor failures; byte equality alone does not establish provenance, executable mode, loader behavior or complete licence coverage.
- Keep extraction state initialization in the shared helper, removing redundant entry-point declarations reported by the complete ShellCheck warning gate; no warning budget is raised.

## 2026-11-21 — recognize quiet task-absent Stevedore containers

- Accept nerdctl's complete typed empty process state through the shared container parser; keep raw fields, stopped/disposable selection and all image/cache protection rules.
- Refuse native stderr in the canonical per-removal query as well as delegated inventory, since a failed task lookup can otherwise resemble task absence. Add regression and mutation controls; installation and real host acceptance remain separate.

## 2026-11-21 — the PE twin of the ELF hardening gate (CON294)

- `Assert-PeHardening` (`windows/scripts/modules/WindowsPeHardening.Common.psm1`) reads each PE's DllCharacteristics
  and throws naming every file without DYNAMIC_BASE, NX_COMPAT, HIGH_ENTROPY_VA (PE32+ only) or GUARD_CF, the bit
  BeschleunigerBallett's binaries lacked before CON290; `-NoCfg` waives CFG by leaf name for a third-party DLL. Its own
  module, as `WindowsTargetArch.Common.psm1` sits near the 800-line limit. `New-OrtTestPe` takes
  `-DllCharacteristics`, and `PeHardening.Tests.ps1` holds the check on synthetic PEs.

## 2026-11-21 — Linux release hardening for every C++ repo, and its ELF gate (CON294)

- `Hardening.cmake` turns on PIE and links with `-z relro -z now` for GCC and Clang on Linux; BeschleunigerBallett
  had linked with neither ("Hardening Linker Flags:" was empty), while AccelerANTgine set them itself. Its global mode
  joins each flag list with spaces: the semicolons of a list had gone into `CMAKE_CXX_FLAGS` and
  `CMAKE_EXE_LINKER_FLAGS`, where they end the command line.
- `06-packaging/verify-elf-hardening.sh` checks shipped ELFs for PIE, `GNU_RELRO`, BIND_NOW, the stack protector
  and `_FORTIFY_SOURCE`, from AccelerANTgine's package gate made generic. `test-cmake-hardening-linux.sh`,
  `test-verify-elf-hardening.sh` (compiled fixtures, one per missing property) and ten recipes hold both.

## 2026-11-21 — an exact skip list for staged gtest entries (CON292)

- A `tests.json` gtest entry of `Invoke-StagedTests.ps1` may carry `allowed_skips` (owner decision D2): a skip not on
  the list, and a listed test that passed, failed or did not run, each count as a failure and are named, so the list
  stays exact. An empty list refuses every skip; the field on a cargo, pytest or exitcode entry is refused before the
  binary runs. Two cases in `StagedTests.Tests.ps1`; AccelerANTgine (seven tests) and BeschleunigerBallett (none) opt
  in next.

## 2026-11-21 — the filesystem recipe leaves current_path(ec); a debugger probe for windows-11-arm

- The exception-free filesystem recipe in `code-quality-tooling.md` read `current_path(ec)`, the non-throwing getter,
  as a throwing one-argument call: BeschleunigerBallett's `Src/` showed five such false matches. It now catches the
  one-argument throwing overloads, the iterator declaration and a bare `current_path()`, and says that a
  two-argument throwing call is not caught. AccelerANTgine's and BeschleunigerBallett's rows follow it.
- `windows-arm-debugger-probe.yml` (by hand) reports which debugger windows-11-arm offers for a fail-fast's stack:
  `cdb` under the Windows Kits, winget's WinDbg, and the WER settings that keep `LocalDumps` empty there.
  OxidANT's arm64 abort (0xC0000409) needs one.

## 2026-11-21 — a failed gate names itself on GitHub (CON293); the filesystem pattern recipe (CON295)

- `gates.sh` writes `::error title=<batch>: <gate>::<gate> failed (exit N)` for each failed gate, with `:` and `,`
  escaped in the title, and a row into `$GITHUB_STEP_SUMMARY` where that is writable. A host step has
  `GITHUB_ACTIONS=true`; `run-in-linux-container` passes `GATES_GITHUB_ANNOTATIONS=1` into its container, since
  `GITHUB_ACTIONS` would also change the tools' own behaviour there. `test-gates-annotations.sh` and two recipes
  hold it; `shared-script-libraries.md` describes the named-parts lane pattern (owner decision D7).
- `code-quality-tooling.md` § Pattern limits gains the recipe for exception-free `std::filesystem` calls that
  AccelerANTgine binds (457b753): it matched exactly that tree's three throwing sites.

## 2026-11-21 — Windows images get the CFG bit (CON290); ctest fails on a logged critical (CON291)

- `cmake/Hardening.cmake` linked `/NXCOMPAT` alone and passed `/DYNAMICBASE` and `/guard:cf` only to the compiler,
  whose `/guard:cf` instruments but cannot set the image's CFG bit: BeschleunigerBallett's Windows binaries shipped
  without it (none of the 13 lld-link lines of job 136406090876). Every MSVC link now gets `/NXCOMPAT /DYNAMICBASE
  /guard:cf`, `/CETCOMPAT` still off ARM64; `test-cmake-windows-arch.sh` and a recipe hold it.
- `ctest-run.sh --fail-on-log-pattern REGEX` (env `CTEST_FAIL_ON_LOG_PATTERN`) fails a run in which a test's output
  has a matching line, naming each such test, and keeps ctest's own failure status. It reads this run's
  `Testing/Temporary/LastTest*.log`, not the JUnit report, which cuts a passed test's output to 1 KiB, and only the
  output section, as a test's `Command:` line holds its own echo text. A real ctest's log is the fixture; a real-ctest
  case and three recipes cover the gate.

## 2026-11-21 — CON99 measured; two corrections; the oxidation and C++ decisions recorded

- CON99: three probe runs pulled the published gzip image in 387, 515 and 235 s and the zstd copy in 290, 227 and
  294 s on fresh runners (median -25 %, a quarter of the spread). The probe's comment and CON99 claimed both legs
  print the same image id; Docker's containerd store names an image by its manifest digest, so they differ, and the
  copy's source digest ties them. The owner chose zstd from the next chain: `runtime_push_tag` now converts a
  runtime tag's gzip layers with `nerdctl image convert --zstd --oci` before the push (`CROSS_LAYER_COMPRESSION`,
  default `zstd`, the cross stages' knob), and a failed conversion pushes nothing; `test-runtime-push.sh` covers both
  with two mutation recipes.
- Correction to 2026-11-20's staged-runner entry: WER does not log OxidANT's arm64 fail-fast abort late, it logs none:
  run 44804439631 waited the full 15 s and found no event 1000, while an access violation is named at once. The wait
  stays for a record written late; `windows-cross-builds.md` and the script's comments now say what is known.
- The owner decided the oxidation review (D1 to D17) and the comparison with BeschleunigerBallett's C++ setup (D1 to
  D12), all as recommended. New: CON288 (the contract cases, ModelANT's among them) and CON289 (one ORT-profile
  counter) here, CON290 to CON296 for the shared C++ gates (the CFG bit, `--fail-on-log-pattern`, an exact Windows
  skip list, gate annotations, Linux release hardening, analyzers and warnings, a bridge import helper); the consumer
  steps went into OxidANT's, AccelerANTgine's, OmniAccelerANT's and OrchestrANT's BACKLOGs.

## 2026-11-21 — required native cache setup propagates failures explicitly

- Retain the required environment owner's raw status before resolving the native fixture compiler; validate its two exports explicitly. The hosted launcher-policy suite correctly rejected the new unguarded call after the original Rust/Dart suite passed again.
- Add an environment-failure control that requires no cache/compiler command to run. Keep the existing cache retry, raw compiler failure, clock and real Rust/Dart checks.
- Canonicalize the launcher-policy scan root before excluding tests. Guarded/bare fixtures through `tests/..` and a missing-root refusal prevent the production scan from passing with every path accidentally filtered out; keep the original exclusions and explicit caller failure policies. Isolate the fake subshell-loss control from inherited real socket/port values, with an explicit inherited-setting regression.

## 2026-11-21 — native fixture compiles use the guarded compiler cache

- Resolve the shared C/C++ fixture launcher through the canonical cache owner after publishing its parent-shell environment. Bare sccache bypassed infrastructure-error recovery and made the hosted Rust/Dart suite fail on temporary-file errors.
- Retain optimized/fatal-warning C compilation, ASAN C++ flags, raw import/resolver/compiler failures and command/cache statistics. Real compiler errors remain fatal; the canonical launcher owns cache retries and direct fallback.
- Add fake cache-infrastructure controls for both real compiler paths and mutation guards for imports, exports, parent environment, resolver and status propagation. Real clock, Rust/Dart, hosted CI and finished consumer checks retain their separate scope.

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

## 2026-11-20 — preserve separate Cargo release metadata for native helpers

- Add paired optional JSON outputs to the shared Rust release driver, retaining its full-workspace build and explicit CLI build. Each file records one complete unfiltered Cargo call, suitable for the existing strict native-helper selector; no extra release builds or combined-message exception are introduced.
- Validate distinct regular output paths and invalidate both before the shared wrapper runs. Stub controls cover argument boundaries, stale streams, path aliases, nonregular outputs and raw wrapper/build failures; actual module/helper staging and finished consumer packages remain separate evidence.
- Keep Cargo at its original source-level call sites: the added alias regression rejects the unpublished function-based prototype, and controls cover both wrapper-selected aliases and an alias changed between the two phases.

## 2026-11-20 — isolated worker clock failures remain errors under optimization

- Share the native supervisor's monotonic-clock error boundary before launch and during its wait loop. Preserve nonzero errno and report `EIO` when a failing clock leaves errno zero, avoiding an unset elapsed value that GCC 16.2 rejects under `-O3 -Werror`.
- Compile shared native fixture objects with optimization and fatal warnings. Add real child controls for initial/elapsed clock failures, exact error preservation and kill/reap behavior; retain the existing timeout, Rust and Dart ownership tests. These source controls do not establish finished consumer packages or GPU acceptance.
- Normal commit hooks also exposed a missing logging-bootstrap import in the recently added host-red helper. Add its canonical import and a removal mutation; keep the existing unmutated library controls fatal and retain the original rejected commit attempt.

## 2026-11-20 — shared hook diagnostics load the canonical logger

- Import `log-bootstrap.sh` from `hook-host-red.sh` so standalone library checks see the real logging API. The missing import made the hosted preflight fail three library assertions and invalidated twelve mutation baselines in run 44819008926.
- Add a removal mutation against the existing library suite; retain failed-positive-control refusals and normal hook scope. Local source checks remain separate from the subsequent hosted CI result.

## 2026-11-20 — a probe for zstd layers (CON99); CON283 names OxidANT's Pester suites

- `zstd-pull-probe.yml` (dispatch only, owner OK for a scratch package) recompresses `:latest`'s amd64 image to zstd
  in `ghcr.io/kataglyphis/antfrastructure-zstd-probe`, times a serial `docker pull` of the published gzip image and
  of the copy on two fresh runners through `prepare-linux-ci-host`'s `pull-seconds`, and deletes the package with
  `GHCR_TOKEN` whatever the legs did. The copy fails unless its layers are `tar+zstd`. Its first run (44812697921)
  read the tag's multi-arch index as the amd64 image and stopped before the pulls; the copy now takes the amd64
  manifest out of the index, and the cleanup's delete answered 204.
- CON283: OxidANT's Pester suites speak 3.4 too; AccelerANTgine, OmniAccelerANT and OxidANT each record the migration
  as blocked on the chain that brings Pester 6.2.0.

## 2026-11-20 — the staged test runner waits for WER's record of a fail-fast abort

- `Invoke-StagedTests.ps1` looked for Windows Error Reporting's event 1000 once, right after a binary died. That
  works for an access violation (run 44739816593 named `d3d10warp.dll`), but WER logs a fail-fast abort
  (`0xC0000409`) only after the process has exited, so OxidANT's two arm64 aborts in the traced renderer tests (runs
  44759227422 and 44782412041) named no module. A crash now looks again each second for up to
  `-CrashEventWaitSeconds` (default 15); a green run never waits. `StagedTests.Tests.ps1` covers a record that turns up
  on the second look and one that never does.

## 2026-11-20 — CON287 (slangc), CON283 notes CON273, a stale lint-tools recipe re-pointed

- New BACKLOG CON287: the image's slangc (Vulkan SDK, Slang 2026.17) cannot emit WGSL binding arrays; OxidANT's
  bindless textures need 2026.22 through a separate pin. CON283 records that CON273 put Pester 6.2.0 into the image
  source on 2026-11-15, so only the chain is left.
- `lint-tools.contract-wants-no-hadolint-on-riscv64` follows CON222's riscv64 line, which stopped the hub push as
  stale, and `lint-tools.contract-wants-no-gitleaks-on-riscv64` holds gitleaks off riscv64 the same way.

## 2026-11-20 — Flutter 3.50.1 in source; CON150's cause named

- `FLUTTER_VERSION` 3.47.9 to 3.50.1 (owner OK; `bump_versions.py --write --only FLUTTER_VERSION`, with
  `FLUTTER_SDK_SHA256` and `FLUTTER_COMMIT` from `releases_linux.json`; `sync_versions.py --write` and the curated
  SBOM follow). 3.50.1 fixes multi-threaded skwasm (flutter/flutter#196127), the source of CON150's worker
  `TypeError` on jonasheinle.de, which jotrockenmitlocken 80f5716 works around with `forceSingleThreadedSkwasm`
  until the image carries 3.50.1. Images change with the next chain.
- The pre-commit hook proves a sample in the image when every failing recipe's test is red before any mutation on
  this host (`baseline test already fails unmutated`), as it already does for a missing pwsh: three hub tests trip
  over Debian 13's bash 5.2.37 (`pop_var_context: head of shell_variables not a function context`) and pass under the
  image's bash 5.3.9, so they said nothing about a mutation here. A real survivor beside them still stops the commit.
  The pre-push hook does the same (it rejected the push of these commits for exactly those four tests); both read
  `linux/scripts/lib/hook-host-red.sh`, and `test-prepush-hook.sh` covers the push side.

## 2026-11-20 — gitleaks in the image for an offline secret scan (CON222, in source)

- `install-lint-tools.sh` installs gitleaks at `GITLEAKS_VERSION` on amd64 and arm64 beside shellcheck and hadolint,
  SHA-verified, and fails unless it reports the pin and finds a GitHub-shaped token planted at run time (owner decision:
  offline consumer linting belongs to the image contract). The smoke's `FACT lint-tools` and the `lint-tools` contract
  row carry it; riscv64, with no upstream binary, ships none. A real arm64 run reported 8.30.1 and found the token.

## 2026-11-20 — retain the mutation companion in consumer hook fixtures

- Copy the mutation workspace module with the real runner into isolated consumer-hook fixtures. Clean pushes and stale-recipe refusals continue through the actual hook pair; a missing module cannot replace the intended verdict.
- Clear inherited per-command Git configuration before creating fixture repositories, including runs started by the real hook. Regression mutations remove the companion or either configuration guard; local Git remotes and linter doubles do not qualify downloaded linters or public pushes.

## 2026-11-20 — deduplicate reviewed immutable OCI archives

- Add a default preview and digest-bound apply helper for explicitly selected immutable OCI blobs. Require matching content, ownership, modes and timestamps; exclude identity-bound receipts, parent directories and outside hardlinks.
- Recheck candidate inputs, authorization, receipt protections and idle engines before atomic per-path replacement. Retain partial-operation journals and verify original paths and receipt bytes before reporting success. This is neither receipt authentication nor a lock against concurrent writers.
- Scan complete quoted tokens once to bound large escaped source payloads. Detect identity-bearing JSON keys without mistaking unrelated strings in source manifests for identity records; retain their byte fingerprints and refusal of malformed identity receipts.
- Reuse the qualified native OCI hashing and identity helpers and the additive full-ID host-command query. Container fixture and mutation checks cover refusal paths without touching real archives.

## 2026-11-20 — restore digest-bound consumer source archives

- Restore a parent snapshot from a local base bundle, staged binary patch, index, file/mode manifest and exact original shallow metadata. Check caller-selected archive digests, restored bytes/index and independent Git objects before writing a receipt.
- Restore original shallow boundaries before checkout; never invent boundaries or claim complete history. Preserve recursive dependencies separately. The archive format and temporary materialization do not establish source authenticity, builds or hardware acceptance.
- Extend the existing source-preservation suite with real archive round trips, shallow history, changed inputs, exact index/working bytes, required object checks and refused outputs.

## 2026-11-20 — preserve private mutation worker paths

- Add opt-in `verify_mutations.py --workspace-root` for stable worker paths in fresh container-private roots. Keep source copies, baseline controls, isolated workers and existing parallelism/disk caps.
- Refuse existing paths, source overlap, symlinked parents and in-place combinations. Require root identity and successful cleanup; filesystem and child-process controls do not establish compiler hits, native Windows behavior or build acceptance.

## 2026-11-20 — consolidate the Linux proof work with current develop

- Preserve both explicit ORT census loader-path interfaces and their exemption arguments. Keep the platform grouping in the shared ISA module so the runtime smoke stays within its existing size limit.
- Preserve both histories and their mutation recipes; rebase archived changelog links and keep all original entries.

## 2026-11-20 — the contract follows `ort` 2.0.0-rc.15 (CON95 step 2)

- OxidANT f76b7f9 pins `ort` 2.0.0-rc.15. The consumer contract's Rust registration names the one `Environment` a
  consumer builds with `ort::init_from(dylib)?.build()?`, keeps alive (rc.15 holds only a weak reference) and passes
  to every `Session::builder`; the `ort-sys` build-script rules it quotes are re-read from rc.15 and unchanged.

## 2026-11-20 — CON148 closed: jotrockenmitlocken checks both dev domains live

- jotrockenmitlocken a80c562 runs `check-live-site.py` after each develop upload (the WASM domain before the CanvasKit
  build replaces `build/web`, then the dev domain), with the URLs from the owner's new `DEV_WASM_SITE_URL` and
  `DEV_SITE_URL` secrets; run 44716391170 passed both checks.

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

## 2026-11-19 — remove approved unused QA environments reproducibly

- Preserve a default-preview cleanup helper for explicitly reviewed ignored QA virtualenvs under the owner's standing authorization. Reuse canonical environment/inode validation, require fresh usage observations and exact source/input snapshots, and retain empty mountpoints and per-path receipts.
- Preserve sources, caches, images, packages, archives, logs and the current shared QA environment. Add disposable-tree and fake-host regressions and actual refusal mutations; supplied authorization is not authenticated and usage observations do not lock concurrent writers or establish build/runtime acceptance.

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
