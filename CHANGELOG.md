# Changelog

> **Older entries** are archived, newest archive first:
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

## 2026-10-20 — GTK 4 for gtk4-rs in every Linux image, from the next build (CON129)

- **Why.** OxidANT's GTK GUI (`gui_unix`, gtk4-rs 0.11 `v4_10`) is mandatory (owner, 2026-10-20),
  and `:latest` could not build it: amd64's `/opt/gstreamer` GTK 4.14.5 `gtk4.pc` lacked
  `graphene-gobject-1.0`, arm64 and riscv64 had no `gtk4.pc`.
- **The package stage** adds `libgraphene-1.0-dev` and `libvulkan-dev` on amd64 and Ubuntu's
  `libgtk-4-dev` 4.22.4 on arm64 and riscv64 (`gtk4_dev_packages`). On riscv64
  `yield_older_prefix_glib` drops the prefix's GLib 2.86.3 for Ubuntu's 2.88.0: Ubuntu's GTK 4
  died at start on `undefined symbol: g_get_monotonic_time_ns`, and PyGObject could not import
  GObject, in the published image too. GStreamer keeps its 290 plugins.
- **Gates.** `verify_gtk4_dev_surface` (gtk4 >= 4.10, every `Requires`, `ldd -r`) fails the
  package stage, and contract row 9 (`gtk4-dev`) runs it as uid 1001 in the shipped image; eleven
  mutations in `test-package-image-wiring.sh`.
- **Proved** in throwaway containers of `:latest` `b52f8c34`: OxidANT's `kataglyphis_cli` with
  `gui_unix` built and its GUI stayed up under Xvfb on amd64, and cross-built for riscv64 and stayed
  up under QEMU; arm64 under QEMU ran a gtk4-rs window and passed `cargo check`.
- **Docs.** [`consumer-image-contract.md` § GTK 4 for gtk4-rs](docs/consumer-image-contract.md#gtk-4-for-gtk4-rs);
  `image-decisions.md` no longer lists GTK 4 dev headers as left out.

## 2026-10-20 — `python-ci.md` names the pinned X.Y as the drivers' default, not `3.14`

- `ci_static_analysis.sh` and `test-free-threaded-wheel.sh` default to `DEFAULT_PYTHON_VERSION`
  (`python_uv.sh`: the image's `PYTHON_MAJOR_MINOR`, else `versions.env`), and the experimental leg
  to its X.Yt. The installed-wheel example passes `${1:+--python-version "$1"}`, as OrchestrANT's
  wrapper does.

## 2026-10-20 — The consumers' free-threaded legs on the image's interpreter, proved in CI (CON66)

- OrchestrANT and WebDavClient ran both Linux legs on `:latest`'s interpreters with no download
  (`/usr` 3.14.4, `/opt/python-freethreaded` 3.14.8) and passed `test-free-threaded-wheel.sh` on the
  installed cp314t wheel, x64 and arm64: OrchestrANT runs 39413508655 and 39347777216 (8 passed,
  2 skipped), WebDavClient 39413315749 and 39347779924 (24 passed). The 3.15 repeat and the PGO and
  CI-runner timing leftovers moved to CON90.

## 2026-10-20 — The docs sites' sidebar toggles work, and a headless click proves it (CON121)

- **Measured** on the nine published sites with the image's headless Chrome: the five Sphinx
  sites built from PyPI (sphinx-book-theme 1.4.0, pydata-sphinx-theme 0.20.0) had dead toggles
  at every width, and all six Sphinx sites had the primary toggle off-screen between 768 and
  991 px. The three dartdoc sites were fine. Every asset was served with its right type, so
  `nosniff` was not the cause.
- **Fix** in DocumANTation ed5f840, the gitlink here: `setup_theme()` sets
  `navbar_persistent: []`, so pydata 0.20 renders no header with a hidden toggle pair that the
  theme JS binds first; `custom.css` no longer makes the primary sidebar sticky, which kept the
  drawer in the flow and pushed the article's toggle to x=-242.
- **The gate.** `linux/scripts/check-docs-sidebars.js` clicks every visible toggle at the
  layout's widths; `docs-site.sh build <site>` runs it in the build's container for a site
  `build-docs.yml` builds, and
  `lib/docs-build.sh` and `ci_build_docs.sh` after `make html` for the artifact sites.
  Suite `test-docs-sidebars.sh`, 14 `docs-site.*` mutations. [docs-sites.md § The sidebar toggle
  check](docs/docs-sites.md#the-sidebar-toggle-check).
- **Live, 2026-10-20**: every toggle passes the check at 1400/1100/850/400 px on all six Sphinx
  sites; the three dartdoc sites passed before and after. CON121 is done.

## 2026-10-20 — The Windows images' history names no cache endpoint, bucket or LAN address (#177)

- **The leak.** BuildKit writes an `ARG`'s value into its history entry and a RUN's build args
  into the RUN's (`RUN |9 … SCCACHE_BUCKET=… pwsh …`). The 2026-10-17 images named the WebDAV and
  S3 endpoints, the bucket and the region; `:winamd64` carried 30 RFC1918 mentions. The base's
  `ARG VULKAN_PRESEED_ENDPOINT` added five more entries. No key leaked.
- **Secrets only.** `Get-BkSccacheConfig` now returns only secrets: the driver sets
  `KATAGLYPHIS_BK_<NAME>` in its process and passes `--secret id=<name>,env=…`. The 16 compiling
  RUNs mount all eight settings as env secrets (`Get-BkSccacheSecretMount`). The litert wheel RUN
  (Bazel's remote cache) and the base's `Install-ScoopTools.ps1` RUN mount the WebDAV one. The
  stages declare none of them as an ARG any more. `sccache levels:` names no endpoint. The write
  probe passes its endpoint through `Invoke-DiagnosticProbe.ps1 -Secret`.
- **The history gate.** `Invoke-BkHistoryGate` reads every exported image's config
  (`--metadata-file`, `buildctl debug get`) and runs `Assert-ImageConfigPublishable`
  (`WindowsImageEnv.Common`). It fails on:
  - a host-carrying sccache setting or key half with a value;
  - an RFC1918 or link-local address;
  - either endpoint's host;
  - the bucket or the region as a `*BUCKET*`/`*REGION*` value.

  It prints entries and reasons, never values. A missing digest fails it.
  `verify_image_env.py` refuses an ARG of an endpoint, bucket, region or key name, and a compiling
  RUN without the WebDAV secret.
- **Proved on this host** (buildkitd v0.33.0, real settings, bare servercore base): all eight set
  in the RUN, both endpoints answering, none in the next RUN, 0 mentions in the config, the build
  record, its provenance and the log. The four published configs gave 134, 134, 196 and 144
  findings (`:winamd64`, `-nvidia`, `-rocm`, `:winarm64`), all on the known carriers. Tests: `ImageEnv.HistoryGate.Tests.ps1`, the history scenarios in
  `ImageEnv.PublishGate.Tests.ps1`, `BuildDriver.SccacheLevels.Tests.ps1`, `test-image-env.sh`.
- **Re-key:** the next chain rebuilds from the base's scoop layer on. An image built before it
  fails the gate, so `-Stages final -PushRef` refuses old bk- tags.

## 2026-10-20 — WebDavClient's docs copy README and CHANGELOG instead of tracking them (CON117)

- WebDavClient 9944a9e: `docs/source/README.md` and `CHANGELOG.md` are gitignored, and its
  `docs/Makefile` and `make.bat` copy the root files before every build, as `ci_build_docs.sh` already
  does; its `doc-link-roots.allow` resolves `getting-started.md`'s `README.md#quick-start` from the
  root (f621c7c moves its pin here, b8be92b8). In `:latest`, `make html` and `sphinx-build -W` both
  render the two pages with no warning.

## 2026-10-20 — `doc-links` grades a link the way pandoc resolves it (CON119)

- DocumANTation's pandoc sources link from the repo root (`--resource-path .`, `pandoc_builder.py:83`),
  so `verify_doc_links.py --root` called both images `no such file`. `<root>/doc-link-roots.allow`
  declares such a root per page glob (`data/book/* | .`); a row no link needs is `STALE`, a missing
  directory a finding. Three cases in `test-doc-links.sh`, mutations `doc-links.link-roots-*`
  ([`code-quality-tooling.md` § Links a build resolves from another directory](docs/code-quality-tooling.md#links-a-build-resolves-from-another-directory)).

## 2026-10-20 — The wxPython plumbing is gone (CON107)

- OrchestrANT, its one consumer, dropped wxPython in d954e86; `git grep -il wxpython` over the
  thirteen family repos' develop tips finds only OrchestrANT's CHANGELOG and one comment.
- `uv_sync_project` loses `--no-wxpython` and its `pyproject.toml` sniff (an unknown flag is still
  skipped, so a stale caller does not break); its seven calls in `ci_tests.sh`, `ci_static_analysis.sh`,
  `ci_packaging.sh` and `ci_build_docs.sh` pass nothing.
- `Sync-UvProjectDependencies` loses `-NoBuildIsolationPackageWxPython`; no consumer passes it.
  `Invoke-CiStaticAnalysis.ps1`, `Invoke-CiPackaging.ps1` and `Invoke-PythonCiBuild.ps1` stop passing it.
- `assemble-torch-app.sh`'s "it pulls wxPython" comment stays for CON106, which decides the
  `frontend` extra.

## 2026-10-20 — A red `develop` anywhere in the family opens an issue here (CON120)

- **A red run told nobody.** `Windows x64 · script tests` stayed red 11 h (run 39345711596 to
  39416230326), and fc5386eb and b0b83498 failed every other session's commit hook until they were
  fixed. `develop-red.yml` now reads every family repository's `develop` runs twice an hour and keeps
  one `develop-red` issue per red workflow, listing each red job with its run; the issue closes
  itself once each job passed again. The newest run of a job decides it, so an on-request or
  release run of another lane neither hides nor clears a red one.
- One hub workflow on the hub's `GITHUB_TOKEN`: no consumer file, no secret.
  `develop-red-selftest.yml` fails or passes on request, to prove it. AGENTS.md's push rules read
  the open issues before every push.
- **Proved on a real transition** (2026-10-20): self-test run 39425116404 red, watch run 39425267469
  opened [#4](https://github.com/Kataglyphis/ANTfrastructure/issues/4); run 39425445085 left it alone;
  self-test run 39425593827 green, watch run 39425615967 closed it. Every run ends with a `watched:` line
  naming the repositories it read, so a token that sees nothing does not pass for a green family.

## 2026-10-20 — "Windows x64 · script tests" no longer needs uv on the runner

- `Uv.PythonRequest.Tests.ps1`'s "Initialize-UvVenv creates the venv on the pin" case (edc4dc54)
  reached the real `uv python find` through `New-UvProjectEnvironment`'s default finder, and
  `windows-2025` has no uv on `PATH` (`The term 'uv' is not recognized`, red since run 39345711596).
  The case stubs `uv` for its duration; 9/9 with and without uv on `PATH`.

## 2026-10-20 — The Windows arm64 Python job runs on `:winarm64`'s interpreters and toolchain (CON113)

- **`windows-11-arm` downloaded its CPython and built with the runner's Visual Studio.** WebDavClient
  run 39336879640 logged `Downloading cpython-3.15.0-windows-aarch64-none` and its `+freethreaded`
  twin through uv, then built the `win_arm64` wheels with the runner's VS. `python-ci-windows.yml`'s
  `arm64-tests` now runs two jobs: a `windows-2025` job stages every leg in `:winarm64`
  (`New-Arm64PythonTestStage.ps1`), and the `windows-11-arm` job runs that stage and installs nothing.
- **The stage:** per leg the image's target interpreter, the leg's `cpXY` or `cpXYt` `win_arm64` wheel
  cross-built with the image's VS 2026 and clang-cl, and the lock's set with that wheel in the
  interpreter's site-packages (`Install-PythonCrossSite`: hash-checked, `--no-deps` on the exported
  closure so a project's `[tool.uv]` overrides hold, pyyaml pure, psutil's `cp315t` from the image's
  store). `CL` names the target, so a `setup.py` that swaps in clang-cl needs no flag of its own. The
  tests run from a copy without the package and import the installed wheel; each wheel is also
  proved alone (`load`, `prove` on X.Yt). The tree is built container-local and copied out: on a bind
  mount uv cannot rename its temporary files (`os error 3`). The arch gate grades it standalone.
- **New inputs:** `arm64-test-files`, `arm64-test-env`. `arm64-wheels` now only uploads, after the
  device proved the wheels. A release that collects `*.whl` skips `python-windows-arm64-stage`.
- **Gone:** `Invoke-PythonTestLegs.ps1`, `Invoke-NativeWheelBuild.ps1` and `PythonTestLegs.Tests.ps1`;
  only this workflow called them. `UV_WINDOWS_ARM64_SHA256` goes with the next chain (CON89).
- **Shared now:** the arm64 bundle's `Install-PythonAppCrossPackage` is `Install-PythonCrossSite`
  plus the chain ORT; `Get-PyprojectBuildInfo` reads a project's name and build requires.
- Measured in `:winarm64` (2026-10-17, with the chain's psutil wheel): WebDavClient's two legs staged
  in 78 s, `kataglyphis_webdavclient-0.10.1-cp315-cp315{,t}-win_arm64.whl`; the standalone arch gate
  inspected 213 PE files, 0 violations, 0 unresolved imports.
- Tests: `PythonArm64Stage.Tests.ps1`, `PythonApp.Cross.Tests.ps1`, `test-reusable-windows-lane.sh`
  (both jobs gated, inputs as container env, the device installs nothing); mutations
  `windows-lane.arm64-stage-gated`, `.arm64-device-installs-nothing`, `.arm64-failed-leg-fails`.

## 2026-10-20 — ModelANT builds its models in `:latest` (CON112)

- **ModelANT's `build.sh` runs only in the image** (ModelANT 038ca50): a venv on the pinned
  CPython sees `/opt/venv`'s torch, torchvision and chain ORT behind its own packages, pip adds the
  rest held at the image's versions, and `ort-venv-census.py --check` must pass before the export.
  Before, `release.yml` ran `setup-python` 3.14 and pip-installed PyPI `onnxruntime` 1.31.0, which
  has no cp315 wheel. Its dispatch run 39392921386 rebuilt `deim_dfine_n_coco` byte-identical to
  the v1 release on ORT 1.30.0 from `/opt/venv`. `data-repositories.md` says where it builds.

## 2026-10-20 — riscv64's uv cache seed covers the free-threaded leg (CON110)

- **`uv-cache-seed.sh build` syncs the app lock twice through one cache**, on `X.Y+gil` and on
  `X.Yt`, each venv on the image's interpreter with `UV_PYTHON_DOWNLOADS=never`, and refuses a venv
  that comes back as the other build. The proof syncs a fresh copy once per interpreter. The record
  lists both Pythons, every built wheel by its ABI tag (`cp314` and `cp314t` share the python tag)
  and one proof each; `verify` wants both passes, both proofs and each wheel under its own tag.
  `ci-common.sh`'s restore names the Pythons it seeds.
- **The X.Yt tree's sysconfig names only tools the image runs.** A cross arch's tree recorded the
  toolchain stage's `/opt/gcc-16.2.0/bin/riscv64-linux-gnu-ar`, absent from the riscv64 image, so
  pillow's `cp314t` build died with exit 127 (measured in `:latest`'s riscv64 child). The torch stage
  runs `06-packaging/free-threaded-sysconfig-tools.py fix`, which points a missing compiler tool at
  its name on `PATH` in the sysconfig data, its JSON twin and the config `Makefile`, then fails on any
  tool that still does not run. It lands before the seed RUN, so only the torch stage's last layers
  re-key.
- **Measured in `:latest`'s riscv64 child under QEMU** (Python 3.14.4 and 3.14.8t, OrchestrANT
  de144d10): with the GIL pass warm from the image's seed, 1271 s, 7 compiled wheels built as
  `cp314t`; 15 wheels, 40 MB, both proofs ok, `verify` passes. From it, that commit's `3.14t` leg
  built no dependency and passed its tests in 62 min. arm64's X.Yt lacks its `ar` the same way,
  and `fix` repairs it there too. Waits for the next `:latest`: the seed and the fix ship with it;
  then OrchestrANT's riscv64 lane asks for `pinned pinnedt`.
- Tests: `test-uv-cache-seed.sh` 74 assertions (both passes, the ABI-tag verify, a missing or GIL
  X.Yt), `test-free-threaded-sysconfig-tools.sh` 19; mutations
  `uv-cache-seed.seeds-the-free-threaded-twin`, `.verify-wants-a-free-threaded-pass`,
  `.verify-matches-the-abi-tag`, `.venv-refuses-the-other-build`, `.never-downloads-an-interpreter`,
  `python.ft-sysconfig-fix-swaps-a-missing-tool`, `.swap-replaces-the-whole-path`,
  `.check-fails-a-missing-tool`.

## 2026-10-20 — The base's toolchain check reads the hub sccache build's banner

- **The next stop was `Test-Toolchain.ps1`**: the hub's build reports `sccache 0.18.0+1bd7432.pr2809`,
  the pin is `0.18.0-1bd7432-pr2809`, and the check wanted the pin verbatim. `Test-PinnedBanner`
  accepts the pin or a hub build id in semver's build-metadata spelling, and no other commit; clang-cl
  and CMake take it too, CMake now in the ninja/nasm/sccache loop. Test:
  `Build.ToolchainBanner.Tests.ps1`.

## 2026-10-20 — The Windows base passes `SCCACHE_DOWNLOAD_BASE` to the rust step

- **The first Windows chain after b9e451da stopped in `Dockerfile.base`** (arm64, 2026-10-20, 25 min
  in): `Install-RustToolchain.ps1` runs before the base bakes `versions.env`, and it threw
  `SCCACHE_DOWNLOAD_BASE is not set (versions.env not loaded?)`. The base now declares
  `ARG SCCACHE_DOWNLOAD_BASE` above that RUN and `Build-Buildkit.ps1` forwards it with the other
  sccache pins. Test: `Build.BaseRustArgs.Tests.ps1` (every pin the script reads is an ARG above its
  RUN at the `versions.env` value).

## 2026-10-20 — `:winarm64` builds the cp315t psutil wheel PyPI lacks

- **psutil 7.2.2 has no `cp315t` `win_arm64` wheel on PyPI** (`cp313t` and `cp314t` only), and
  OrchestrANT's and WebDavClient's free-threaded device legs lock it. The arm64 merge now builds it
  from the sdist pinned by the new `PY_PSUTIL_SDIST_SHA256` (`Build-TargetSdistWheel.ps1`) into
  `C:\runtime\wheels-free-threaded\deps`, before `Copy-TargetPythonDeps.ps1`'s gate (CON111).
- **clang-cl, not VS's `cl`:** setuptools runs copies of clang-cl, lld-link and llvm-lib named `cl`,
  `link` and `lib`, and `CL` adds `--target=aarch64-pc-windows-msvc /clang:-fcommon`. psutil's
  headers define their function pointers in every object; `cl` merges them, clang 23 stopped with
  `duplicate symbol: _GetExtendedUdpTable` until `-fcommon`. The wheel then passes the twins' three
  static gates and a new one: no member carries MSVC's Rich header.
- **One cross build for both scripts.** `Invoke-CrossWheelBuild` (`WindowsSourceBuild.Common`) holds
  `DIST_EXTRA_CONFIG`, the `uv build` and the static gates `New-CrossFreeThreadedWheel.ps1` had
  inline, for a `cp3XY` or `cp3XYt` wheel. `New-CrossBuildPython` is `New-FreeThreadedBuildPython`
  with a GIL form and a `-LibDir` override; the shipped image keeps the GIL target's import library
  in `C:\runtime\python\libs`, not `PCbuild\arm64`.
- Measured in the published `:winarm64` (2026-10-17): `psutil-7.2.2-cp315-cp315t-win_arm64.whl`,
  one `0xAA64` module. Test: `Build.TargetSdistWheel.Tests.ps1`. Rides the next arm64 chain.

## 2026-10-20 — A repository with a release keeps a CHANGELOG

- **The naming rule changed** (owner, 2026-10-20). It said only a registry package keeps
  `CHANGELOG.md` and applications rely on git history, while `release-publish.yml` takes every
  release's notes from the CHANGELOG's `## <version>` or `## [<version>]` section. Now
  [`adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md#the-rest-of-the-naming-rules-in-one-place)
  says a repository with a release keeps one and one without (jotrockenmitlocken) needs none;
  `repository-family.md`'s layout table agrees. All six family repositories with a `release.yml`
  (OmniAccelerANT, OxidANT, AccelerANTgine, BeschleunigerBallett, OrchestrANT, WebDavClient) have a
  section for their current version. ModelANT and AssetANT release per asset with notes from its
  JSON and keep none.

## 2026-10-20 — Dependabot is off family-wide

- **Dependency upgrades go only through Renovate as a local CLI** (owner, 2026-10-20). Every
  family `.github/dependabot.yml` is deleted, its open PRs closed and its `dependabot/*` branches
  removed, and each repository's Dependabot security-update PRs are disabled; alerts stay where
  they are on. [`dependency-updates.md`](docs/dependency-updates.md) says so, and `default.json`'s
  description no longer says the consumers carry Dependabot configs. No hub gate or template
  expected the file.

## 2026-10-20 — The Windows uv venvs and the host probes take the pinned CPython

- **`Initialize-UvVenv` defaults to the pin's X.Y, not 3.12** (owner, 2026-10-20: only the pinned
  CPython). Its implicit callers, `Invoke-EarlyWebDavDownload` (BeschleunigerBallett) and
  OmniAccelerANT's cmake-format venv, made `:winamd64`, which carries 3.15.0 alone, download 3.12
  through uv. `Initialize-UvVenvPython` (`Invoke-CmakeFormatStep`) passes no version of its own.
  `Test-UvVenvHealthy -PythonVersion` recreates a venv on another X.Y or X.Yt, so a reused
  workspace follows a pin bump. Measured in `:winamd64`: the venvs use `C:\temp\cpython`'s 3.15.0,
  and `uv python list` shows the image's two interpreters before and after, nothing downloaded.
- **cmake-format 0.6.13 runs on Python 3.15.** 3.15's `re.Scanner` refuses capturing groups
  (`ValueError: Cannot use capturing groups in re.Scanner`, measured in `:winamd64`), and
  cmakelang's lexer has them; 0.6.13 is the last release. `linux/scripts/lib/cmakelang-py315.py`
  swaps in 3.14's `Scanner` verbatim, minus the check, writing a new file so uv's hardlinked cache
  keeps the wheel's bytes. `Install-UvRequirements` and `code_quality_ensure_cmake_format` run it
  after each install; below 3.15 it does nothing. Output equals stock 3.14 byte for byte over 79
  CMake files of the hub, OmniAccelerANT and BeschleunigerBallett. Without it `:latest`'s move to
  3.15 would red every CMake format gate.
- **`install-deps-preamble.sh`'s `host_python_major_minor` fallback answers the pin** (the image's
  `PYTHON_VERSION`, else `versions.env` beside it) where it said 3.12.
- **`preflight.sh` probes `pythonX.Y` of the pin first**; python3 and the older names stay for a
  host without it. `windows-host-setup.md` B4 installs the pin's X.Y and says where it lives.
- Tests: `Uv.PythonRequest.Tests.ps1` (venv reuse per X.Y/X.Yt, the pinned default, the helper
  after an install), `Python.PinnedDefault.Tests.ps1` (no module's `-PythonVersion` defaults to a
  literal), `test-python-ci-defaults.sh` (both probes), `test-cmake-format.sh` (the gate under the
  patched lexer); mutations `python.preamble-fallback-is-the-pin`, `lib.cmake-format-py315-fix-runs`,
  `lib.cmakelang-py315-replaces-the-scanner`.

## 2026-10-20 — The arm64 Python job defaults to the pinned X.Y and X.Yt

- **`python-ci-windows.yml`'s empty `arm64-python-versions` runs the pinned X.Y plus X.Yt when
  `pyproject.toml` declares free-threading**, as the x64 driver and `python-ci-linux.yml` do (owner,
  2026-10-20: every lane tests only the pinned CPython, once with the GIL and once free-threaded).
  It ran X.Y alone. One helper holds the rule: `Resolve-PythonLegList -PyprojectPath` reads the
  classifier with `free-threaded-wheel.py declares`. `Invoke-PythonCiBuild.ps1`'s `Get-DefaultLeg`
  is gone, and `Invoke-PythonTestLegs.ps1` installs the pinned X.Y first when uv has none, since a
  hosted runner has no image interpreter. The job's one caller, WebDavClient, names `pinned pinnedt`.
- `python-ci.md`: the defaults paragraph under ORT trap 3 named 3.14 and WebDavClient's 3.13 legs;
  it states the pin rule now.
- Tests: `PythonWheel.FreeThreaded.Tests.ps1` and `PythonTestLegs.Tests.ps1` (classifier declared,
  absent, unreadable; the pinned X.Y installed only when uv finds none).
