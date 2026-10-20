# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-10-13 … 2026-10-18`](docs/changelog-archive-2026-10-18.md) ·
> [`2026-10-08 … 2026-10-12`](docs/changelog-archive-2026-10-12.md) ·
> [`2026-10-01 … 2026-10-07`](docs/changelog-archive-2026-10-07.md) ·
> [`2026-09-22 … 2026-09-30`](docs/changelog-archive-2026-09-30.md) ·
> [`2026-09-08 … 2026-09-21`](docs/changelog-archive-2026-09-21.md) ·
> [`2026-08-29 … 2026-09-07`](docs/changelog-archive-2026-09-07.md) ·
> [`2026-08-14 … 2026-08-28`](docs/changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.

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

## 2026-10-19 — Docs: Windows CPython is 3.15, the sccache file is read

- **`windows-builds.md` names the Windows images' CPython 3.15.0** (`PYTHON_VERSION` in both
  published images of 2026-10-17): `python3.15t.exe`, `python315t.lib`, `cp315` and `cp315t` where
  it said 3.14; the dated 3.14 measurements stay. "No arm64 import has ever been executed" is gone:
  `Test-Arm64Bundle.ps1` imports `numpy`, `onnxruntime`, `av` and `cv2` on `windows-11-arm`
  (run 39200278761: `PY 3.15.0`, 18 steps passed).
- **`linux-build-basics.md` and `build-cache-tiers.md`: sccache reads `/etc/sccache/config.toml`
  while `SCCACHE_DIR` is set, but drops its `[cache.disk]` section**, so the baked knobs never
  apply. Measured in `:latest` (sccache 0.18.0): the file's `[dist]` scheduler applied, its `dir`
  and `size` did not. "Not read at all" was wrong.
- `doc-dupes.allow`: six budgets down to the measured counts (`adopting` | `linux-build-basics`
  17 → 14, `windows-build-invariants` | `windows-builds` 22 → 15, `| windows-cross-builds` 20 → 15,
  `| windows-build-lanes` 20 → 17, `failure-modes` | `windows-host-setup` 18 → 14,
  `cross-build-verification` | `linux-cross-builds` 16 → 13).
- `windows-cross-builds.md`: the Python-bindings heading said "staged, never imported"; the build
  stages them and `windows-11-arm` imports them. Its `cv2` gate names `cv2.cp315-win_arm64.pyd`.

## 2026-10-19 — The arm64 test artifact keeps its hidden files

- **`container-ci-windows.yml` uploads `<artifact-name>-tests` with `include-hidden-files: true`.**
  `upload-artifact` drops dot-paths by default, so OrchestrANT's staged `.github/workflows/`
  never reached `windows-11-arm` and `test_viewer_job.py` failed there with `FileNotFoundError`
  (run 39322525681) while the arch gate had passed the full tree.

## 2026-10-19 — Renovate installs from a committed lock

- **`renovate-local.sh` installs Renovate with `npm ci` from
  `linux/scripts/renovate-npm/package-lock.json`** (620 entries, each with its sha512), into
  `renovate-<version>-<lock hash>` in the cache. `npm install -g renovate@44.157.0` failed today
  with `npm ETARGET @aws-sdk/credential-provider-http@^3.972.77`: Renovate pins only its direct
  dependencies, `@aws-sdk/credential-provider-node` 3.972.87 (published 18:47:51Z) requires
  `^3.972.77`, which AWS published at 18:53:07Z, and the install at 18:48:11Z fell in between.
  Nothing was yanked and no lock was stale; there was none
  ([`dependency-updates.md`](docs/dependency-updates.md#pins-and-why-node-is-one-of-them)).
- The script refuses a lock that installs another Renovate than `RENOVATE_VERSION`, and
  `--print-bin` prints the path alone: the bootstrap's notes and npm's output go to stderr, where
  `node "$(renovate-local.sh --print-bin)"` used to get them on a first run.
  `.github/renovate.json` gates the `package.json` bump like the `tool-pins.env` one.
- `test-renovate-bootstrap.sh` 10 assertions, 4 `renovate.bootstrap-*` mutations. In `:latest`:
  the six renovate suites pass, and a fresh bootstrap (27 s) answers `renovate --version`
  with `44.157.0`.

## 2026-10-19 — `builder: dartdoc` takes a guide list and clears doc/api first

- **`build-docs.yml` input `guides`**: one `<source>|<slug>|<nav title>` per line, reaching the
  build container as `DOCS_GUIDES` and `dartdoc_build_main` as `DARTDOC_BUILD_GUIDES`, sources
  made absolute from the repository root. `docs-site.sh plan` refuses guides without
  `builder: dartdoc`, a line without all three fields, a source outside the checkout and a slug
  outside `[A-Za-z0-9_-]`. ANThology used `command: bash scripts/build-docs.sh` because the builder
  took no guide list ([`docs-sites.md`](docs/docs-sites.md#moving-a-repository-onto-it) said
  otherwise; corrected).
- **The builder clears `doc/api` before `dart doc`**: `dart doc` writes over it, so a rebuild kept
  the staged `.htaccess` and `stage` failed "the site ships a .htaccess".
- ANThology through the builder with its one guide, twice in `:latest`: 1071 documents, 0
  findings, 57 s, the rebuild 29 s. `test-docs-site.sh` 60 assertions; 8 `docs-site.*` mutations.

## 2026-10-19 — WindowsContainerLog.Common's header names how OxidANT imports it

- The module header said OxidANT's container scripts import it from `C:\host-scratch`; since
  OxidANT 20a03fb they import it through `Resolve-BuildModule.ps1` from the streamed tree
  (`Build-RustAll.ps1:15`, `Test-RustAll.ps1:13`). The header is four lines now, the restore
  history stays in [`changelog-archive-2026-09-21.md`](docs/changelog-archive-2026-09-21.md), and
  `.github/consumers.json`'s OxidANT note says the same.

## 2026-10-19 — the format walks skip node_modules and the other trees git never lists

- **Windows' source walk** (`Get-ProjectSourceFiles`, used without a `.git`, as in a tar-piped
  container) skips `node_modules`, `.pub-cache`, `.dart_tool`, `.gradle`, `.cxx`, `.cargo` and
  `flutter\ephemeral`: a local container build of BeschleunigerBallett failed its clang-format
  check on `.opencode/node_modules/msgpackr-extract/src/extract.cpp`. The `git ls-files` path is
  unchanged.
- **Linux**: `CODE_QUALITY_UNTRACKED_EXCLUDES` holds the same globs; `code_quality_find_cpp_files`
  and `code_quality_find_clang_tidy_files` apply them, and `CODE_QUALITY_CMAKE_DEFAULT_EXCLUDES`
  is that list (it was `*/.pub-cache/*` alone).
- `test-code-quality-walk.sh` (4 assertions, 4 mutations `lib.*-walk-*`) and two cases in
  `WindowsFormatting.ClangFormatCheck.Tests.ps1`, which fail without the exclusion.

## 2026-10-19 — New-PortableBundle returns its result object alone

- **`New-PortableBundle`** pipes its `-Runner` call to `Out-Host`: the default runner let cmake's
  install lines into the return value (a real tree returned 32 objects, 31 of them strings), so a
  caller reading `.Bundle` got an array. A passed runner's output stays out of the result too.
- `CrossBundle.Common.Tests.ps1` 11 cases: the new one runs the default runner against a fake
  `cmake.cmd` on `PATH` and a runner that returns a line; without the `Out-Host` it gets 3 objects.

## 2026-10-19 — a local run grades the staged tests' verdict line too

- **`Invoke-StagedTests.ps1 -AssertVerdict`** throws after printing
  `TESTS: passed=<n> failed=<n> skipped=<n>` when a test failed or none passed, and
  **`Assert-StagedTestVerdict -Lines`** (`WindowsTesting.Common`) reads that line out of captured
  output with the same rules and returns the counts. AccelerANTgine's `Start-Windows.ps1` and
  OxidANT's `Invoke-HostTests.ps1` each parsed it themselves. `container-ci-windows.yml`'s
  arm64 run job keeps its own reading: it has no checkout, and it writes the counts to the job
  summary before it judges them
  ([`windows-cross-builds.md`](docs/windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml)).
- `StagedTests.Tests.ps1` 7 cases; dropping either rule fails one.

## 2026-10-19 — New-PortableBundle builds a CMake product's bundle and packages

- **`New-PortableBundle`** (`WindowsCrossBundle.Common`): `cmake --install` of the build dir into
  `<DistDir>\bundle`, the DLL closure of its `bin` from `Get-ProductDllSearchPath` (or
  `-SearchDirectory`), and the build dir's `.msi`, `.zip` and the NSIS `.exe` named like one of
  them in `<DistDir>\packages`. **`-RequireCompleteInstall`** throws when the closure has to add
  a DLL, as AccelerANTgine's copy did; BeschleunigerBallett's did not, so it is a switch.
  `-Runner` takes the build's logged cmake call; the module gains no import, since media stages
  mount it beside `WindowsTargetArch.Common` alone
  ([`windows-cross-builds.md`](docs/windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml),
  which no longer says BeschleunigerBallett passes `C:\runtime\bin` itself).
- `CrossBundle.Common.Tests.ps1` 10 cases over synthetic PE imports; dropping the throw, the
  installed-names filter or the test-binary exclusion each fail one.

## 2026-10-19 — Get-BuildConfigurationRow reads a Build-Windows.config.psd1 row

- **`Get-BuildConfigurationRow`** (`WindowsConfig.Common`) returns `Build.Configurations.<Name>`
  as `Name`, `BuildDir`, `Preset`, `Configuration` and the raw `Row`, with `BuildDir` and `Preset`
  taken from the row's `BuildDirEnv` / `PresetEnv` variables when set, and throws, naming the
  file, for a name the config lacks. AccelerANTgine's `Build-Windows.ps1` and `Start-Windows.ps1`
  and BeschleunigerBallett's `Build-Windows.ps1` and `Build-Windows-Container.ps1` each read the
  row themselves. `WindowsConfig.Common.Tests.ps1` 8/8.

## 2026-10-19 — an MSIX that must install can require its signature

- **`Invoke-MsixPackage -RequireSignature`** (implies `-Sign`) throws when the package comes out
  unsigned, or, with `-SignerSubject`, signed by another subject: `Invoke-MsixSign` only warns,
  and an unsigned MSIX does not install. OmniAccelerANT's `New-AppMsix` checked
  `Get-AuthenticodeSignature` itself. The default `-Sign` behaviour is unchanged.
- **`New-TestSigningCertificate`** (`WindowsMsix.Signing`) is the one throwaway certificate
  maker: in memory, no store touched, `-Password` protects the `.pfx`. It replaces
  `WindowsPythonApp.Common`'s `New-PythonAppSigningCertificate` (no consumer named it) and the
  store-based `New-SelfSignedCertificate` in `rust/New-MsixPackage.ps1 -CreateTestCertificate`;
  `certificates/GenerateCertificateMSIX.ps1` stays the manual tool for a long-lived developer
  certificate ([`adopting-in-a-new-project.md` § 7](docs/adopting-in-a-new-project.md#7-certificates--packaging-windows)).
- Packed and signed on this host with the Windows SDK's makeappx and signtool: the signed MSIX
  passed `-RequireSignature -SignerSubject 'CN=H4b Probe'` with the certificate's thumbprint, a
  package from a directory without a `.pfx` was refused, and no store held the certificate
  afterwards. `WindowsMsix.Common.Tests.ps1` 24/24, `PythonApp.Msix.Tests.ps1` 5/5.

## 2026-10-19 — the pinned clang-format is the hub's to find

- **`code_quality_require_pinned_clang_format`** (`lib/code-quality.sh`) sets
  `CODE_QUALITY_CLANG_FORMAT` to the first of `CODE_QUALITY_CLANG_FORMAT_CANDIDATES` (default
  `/usr/local/llvm-target/bin/clang-format`) and `PATH`'s clang-format that reports
  `LLVM_RELEASE`, the environment's else `versions.env`'s, anchored so `23.1.30` is no `23.1.3`;
  none errs naming the release. `code_quality_check_clang_format` and `_run_clang_format` run
  that binary. AccelerANTgine's and BeschleunigerBallett's `run-static-analysis-format.sh` and
  OmniAccelerANT's `check-plugin-cpp-format.sh` each grep `clang-format --version` themselves
  ([`code-quality-tooling.md`](docs/code-quality-tooling.md#the-pinned-clang-format)).
- **`Invoke-ClangFormatCheck` refuses any release but `LLVM_WINDOWS_VERSION` by default** (the
  Windows image's LLVM; `-ExpectedVersion ''` skips), so BeschleunigerBallett need not read
  `versions.env` to pass it. Both pins are `23.1.3` today.
- `test-pinned-clang-format.sh` 11 assertions in `:latest` over stand-in clang-formats, 3
  `lib.pinned-clang-format-*` mutations; `WindowsFormatting.ClangFormatCheck.Tests.ps1` 5/5.

## 2026-10-19 — Get-PackageVersion reads the repo's own version file, and can refuse to guess

- **`Get-PackageVersion -VersionFile`** reads one file as `version_util.sh --file-version` does: a
  `Cargo.toml`'s `[workspace.package]` or `[package]` version, a `CMakeLists.txt`'s `project()`
  `VERSION`, a `pubspec.yaml`'s `version:` without its `+build`, and, new in this twin, a
  `pyproject.toml`'s `[project]` version; another file gives its first version.
  **`-Required`** throws instead of the silent `0.0.1.0` fallback. OxidANT's
  `Get-CargoMsixVersion`, OmniAccelerANT's two `pubspec.yaml` regexes and BeschleunigerBallett's
  `VERSION.txt` guard each worked around the missing switches. `WindowsMsix.Common.Tests.ps1`
  23/23; dropping the `-Required` throw fails a case.

## 2026-10-19 — Linux containers from Windows: one nerdctl lookup, the family image chowns

- **`Resolve-NerdctlExe`** (`WindowsContainerBuild.Reuse`, the twin of `Resolve-DockerExe`):
  `-Override`, `NERDCTL_EXE`, `PATH`, then Rancher Desktop's copy, never Stevedore's
  `nerdctl.exe`, which drives the Windows containerd; `-AllowMissing` returns `$null` for a guard
  ([`rancher-desktop-linux-containers.md`](docs/rancher-desktop-linux-containers.md#use-nerdctl-not-docker)).
  OmniAccelerANT resolved it three times: `Invoke-DartChecks.ps1`, `Invoke-Renovate.ps1` and
  `WindowsLaneGuard.Common`.
- **`Invoke-InLinuxContainerBuild` chowns its named volumes with the image it runs**
  (`--entrypoint chown`, on its `--platform`), no longer with `alpine:3.20`, finds nerdctl through
  `Resolve-NerdctlExe` for `-Engine nerdctl`, and takes `-Privileged`, `-Device`, `-Env` and
  `-ExtraMount`. Run against `:latest` through Rancher's nerdctl: the volume came out owned by
  1001, uid 1001 wrote into it, `-Env` arrived.

## 2026-10-19 — two suites and the data fetcher hold on a Windows checkout

- **`test-collect-release-assets.sh`'s `_job` drops a trailing `\r`**: on a Windows
  `core.autocrlf` checkout `release-publish.yml` has CRLF lines, so no job key matched and 10 of
  129 assertions failed in `:latest`. 129/129 now on this CRLF checkout and on an LF copy.
- **`fetch-data-lock.py`'s `place_file` removes `<file>.part` when anything after the copy
  fails**: in `:winamd64` on a bind mount `os.replace` raised `WinError 3` and left the part
  beside the target, which [`data-repositories.md`](docs/data-repositories.md#the-hubs-fetcher)
  says never happens. `test-fetch-data-lock.sh` puts a directory where the file goes (69
  assertions in `:latest`); `data-lock.failed-place-leaves-no-part` bites, and
  `data-lock.readable-by-all` follows the new indentation.

## 2026-10-19 — the CI compiler cache moves in and out through WindowsBuild.Common

- **`Restore-CiCompilerCache` / `Save-CiCompilerCache`** move `CI_COMPILER_CACHE`'s sccache (and
  with `-Cache sccache, cargo` cargo's) caches into container-local directories, point
  `SCCACHE_DIR` / `CARGO_HOME` there, stop the sccache server around each move, and move them
  back without cargo's unpacked `registry\src` and `git\checkouts`; a failed move back warns and
  returns `$false`. **`Test-SccacheModuleSafe`** moved here from OmniAccelerANT, and
  `-RequireModuleSafeSccache` keeps a clang-cl C++20 module build off an sccache that serves
  stale importers ([`build-cache-tiers.md`](docs/build-cache-tiers.md)). OmniAccelerANT's
  `Build-Windows.ps1` and OxidANT's `Invoke-WindowsLane.ps1` each carried their own robocopy
  `/MOVE` pair.
- `Build.CiCompilerCache.Tests.ps1`: real robocopy moves between temp directories and an
  sccache stand-in that records `--version`, `--stop-server`, `--show-stats`, `--stop-server`.

## 2026-10-19 — one generated-artifacts suite for every consumer

- **`shared/windows/tests/Repo.GeneratedArtifacts.Tests.ps1`** fails on a tracked file that
  `.gitignore` also excludes and on one under the repo's generated-output pathspecs, read from
  `scripts/windows/generated-artifacts.txt` (or `-Pattern`). AccelerANTgine, BeschleunigerBallett
  and OxidANT each carried a 47-line copy; it runs under Pester 3.4.0 and 5+, and a setup error
  surfaces in each case, since Pester 6.1 reports a throw from `BeforeAll` as an escaped `break`
  ([`adopting-in-a-new-project.md` § 9](docs/adopting-in-a-new-project.md#9-quality-gates)).
- **`Get-TrackedGeneratedArtifact` refuses a wildcard pathspec ending in `/`**: git matches
  `**/__pycache__/` or `build*/` against no file, so the check held nothing there. Measured on
  the consumers' lists: BeschleunigerBallett's `**/__pycache__/` and AccelerANTgine's `build*/`
  and `docs/test-results*/` were such dead entries; with `*` appended all three repos pass.
  `WindowsRepoHygiene.Common.Tests.ps1` and `Shared.GeneratedArtifacts.Tests.ps1` (Pester 3.4.0
  and 6.1.0, child process) prove both.

## 2026-10-19 — the hub runs a Python repo's Windows CI build

- **`windows/scripts/python/Invoke-PythonCiBuild.ps1`** runs the Linux lane's three steps on
  Windows: pytest on each Python leg in its own venv, `Invoke-CiStaticAnalysis.ps1` as a gate,
  then the repo's `DataLocks` through `fetch-data-lock.py` and `Invoke-CiPackaging.ps1`. A repo
  keeps its values in `scripts\windows\python-ci.psd1` under the driver's parameter names; a
  parameter on the command line wins, and an unknown key fails the run
  ([`python-ci.md`](docs/python-ci.md#the-windows-build-driver)). OrchestrANT's and
  WebDavClient's `Build-Windows.ps1` shared 161 identical lines of shims over the hub's modules,
  and WebDavClient's ran its static analysis as `Invoke-Optional`, which gates nothing.
- **`python-ci-windows.yml`'s `build-script` defaults to empty**: the repo's own
  `scripts\windows\Build-Windows.ps1` when the checkout has one, as before, else the hub driver
  with `-RepoRoot` set to the mount.
- Run in `:winamd64` (`f8da1c947056`) on each consumer's HEAD with this hub tree and a
  `python-ci.psd1`: OrchestrANT 3.15 (1776 passed) and 3.15t (1735 passed), six gates ok, the
  model fetched by lock, sdist, pure, cp315 and cp315t wheels, MSI, MSIX and zip in 12m22s;
  WebDavClient 3.13, 3.14 and 3.14t, six gates ok, sdist, pure, cp314 and cp314t wheels in
  4m42s. The checkout was copied into the container first: on this host a bind mount refused
  uv's renames (`failed to persist temporary file`). `PythonCiBuild.Tests.ps1` drives it over a
  recording uv, python and child drivers; `test-reusable-windows-lane.sh` holds the default, and
  2 `windows-lane.build-script-*` mutations prove it.

## 2026-10-19 — the agentic-loop runners are watched copies

- **`shared-assets.manifest` registers `agentic-loop-sh` and `agentic-loop-ps1`** in body mode:
  OmniAccelerANT and BeschleunigerBallett carried `Run-AgenticLoop.sh` and
  `Invoke-AgenticLoop.ps1` as copies of the templates that nothing compared. In a PowerShell file
  a leading `<# … #>` help block now counts as header prose, in both twins; `head -` is the bash
  runner's knob, since its `--help` prints the consumer's header
  ([`shared/config/README.md`](shared/config/README.md#the-template-trees-are-owners-too)).
- **The bash template's header sits above `set -euo pipefail`**, so body mode starts after it,
  and the template reaches the library through `scripts/linux/lib/antfrastructure.sh`, as
  BeschleunigerBallett's copy already did, instead of a `third_party` literal.
- Not registered: the five consumers' `renovate-local.sh` wrappers and ANThology's
  `scripts/lib/find-hub.sh` are their own code, not copies of a template; ANThology's sibling
  probe stays its own, since no other consumer lacks the submodule.
- Read with both twins over the two consumers' runners: `DRIFTED` as they are, in sync once
  re-based on the templates under their own headers, and `DRIFTED` again with one planted line.
  `test-shared-config-sync.sh` adds the help-block case; 2 `shared-config.*` and 2 `shared-assets.*`
  mutations (a new declared family).

## 2026-10-19 — the hub's docs build from the image, offline

- **`linux/scripts/build-docs.sh` no longer installs Sphinx from PyPI in CI.** In the image its
  `.venv` sees the image's `python3` site-packages through a `.pth` (Sphinx 9.1.0,
  sphinx-book-theme 1.2.0, myst-parser 5.1.0, sphinx-design 0.7.0, Pygments 2.20.0 in `:latest`), and
  only the vendored DocumANTation theme is installed into it, editable, `--offline --no-deps
  --no-build-isolation`. A theme requirement the image does not meet stops the build and is named;
  CI without the image refuses; a workstation without it installs `requirements.txt` as before
  ([`project-info.md`](docs/project-info.md#building-the-hubs-docs)).
- Built in `:latest` with `--network none`: the same 98 pages and 49 warnings as the PyPI build,
  and the site-link gate passes. `tests/test-build-docs.sh` drives the three ways and the
  requirement check; 4 `docs-site.*` mutations prove it.

## 2026-10-19 — the cargo-cache recipe follows its own page

- **`rancher-desktop-linux-containers.md` § *Persisting the cargo cache*** chowns the named
  volume with the family image (`--user root --entrypoint chown`, once), not `alpine:3.20`, and
  then runs as the image's uid 1001 instead of `--user root`. It binds the repo by its Windows
  path through Windows `nerdctl`, not `rdctl shell nerdctl -v /mnt/d/...`, the form the same
  page's § *An empty mount is not a missing drive* shows mounting nothing. Run from Git Bash on
  2026-10-19: the chown, then a uid-1001 write into the volume.

## 2026-10-19 — the large-files gate measures what git stores

- **`verify_large_files.py` sizes each tracked file by its blob** (`git cat-file --batch-check`),
  not by the checkout: under `core.autocrlf` a text scene grows by a byte a line, so
  BeschleunigerBallett's `Resources/Models/suzanne.obj` read `GREW from 986 to 1017 KiB` on its
  Windows checkout and passes now, against the same `986` row. A blob git cannot size exits 2
  ([`data-repositories.md`](docs/data-repositories.md#keeping-data-out-of-the-code-repositories)).
- `tests/test-large-files.sh` adds a CRLF checkout and an unsizable blob; its symlink case waives
  on Git Bash, which makes no symlinks, instead of failing there. 2 `large-files.*` mutations.

## 2026-10-19 — consumers' bash suites on the hub's harness

- **`linux/scripts/lib/test-harness.sh`** is the consumer entry to the hub's own
  `tests/test-harness.sh`: one harness, so a consumer suite gets the zero-assertion guard, the
  misused-assertion guard and the Git Bash skips the hub's suites have. Three assertions join it
  for the two helpers six consumer suites carried in copies: `t_assert_rc <rc> <cmd…>` (that exit
  code exactly; a miss prints the output) for `expect`, and `t_assert_grep` / `t_assert_no_grep
  <file> <ERE>` (a miss prints the file; a pattern may start with `--`) for `check`
  ([`shared-script-libraries.md`](docs/shared-script-libraries.md#libtest-harnesssh)).
- Like every `lib/` module it loads `01-core/logging.sh` through `log-bootstrap.sh`
  (`test-lib-modules.sh`, which the first version of the entry failed).
- OxidANT's `test-check-crate-coverage.sh`, ported in `:latest`, runs the same 8 cases on it.
  `test-harness-guards.sh` holds the new assertions and the entry from a consumer-shaped tree;
  5 more `gate-fixture.harness-*` mutations prove it.

## 2026-10-19 — one fetcher for the data locks (CON98, the hub half)

- **`linux/scripts/lib/fetch-data-lock.py --lock FILE [--dest DIR] [--extract] [--only NAME]...
  [--cache DIR]`**, stdlib Python, and **`cmake/KataglyphisFetchData.cmake`**'s
  `kataglyphis_fetch_data(LOCK … [DEST …] [EXTRACT] [ONLY …])`: the one implementation of the
  contract OxidANT's `fetch-models.sh` and `Get-Models.ps1`, OrchestrANT's `fetch_models.py`
  and BeschleunigerBallett's `FetchAssets.cmake` each kept. The cache is `<sha256>-<file>` (a
  bare `<sha256>` still serves); every cached copy, download and target is hashed; writes go by
  one rename, `0644` under any umask, one fetch per cache at a time; `--extract` unpacks a scene
  to `<name>/` only, touched to now, and stamps it with its hash and file count
  ([`data-repositories.md`](docs/data-repositories.md#the-hubs-fetcher)).
- Read in `:latest` over the consumers' real locks: the same three model files as
  `fetch-models.sh` and `fetch_models.py`, the same 44 scene files and stamps as
  `FetchAssets.cmake`, whose stamps it reads as up to date. `data-repositories.md`'s consumer
  table now lists OmniAccelerANT and AccelerANTgine too, and says `Get-Models.ps1` keeps no
  cache. `tests/test-fetch-data-lock.sh`; 20 `data-lock.*` mutations (a new declared family).

## 2026-10-19 — one ELF closure walker for every Linux bundle

- **`linux/scripts/06-packaging/elf-closure.sh`** is `python-app-closure.sh` made language-neutral;
  the old path stays, as a one-line `exec` of the new one. New options: `--from SONAME-GLOB=DIR` (that
  directory or nowhere), `--ldconfig`, `--ldd` (a file's libraries as `ldd` lists them), `--exclude`,
  `--no-default-system`, `--relocatable` (a RUNPATH out of the bundle resolves nothing) and
  `--no-runpath`; without them it behaves as before
  ([`linux-build-basics.md`](docs/linux-build-basics.md#the-elf-closure-walker)).
- It replaces four consumer copies: OmniAccelerANT's `bundle-runtime-closure.sh` walk and the `ldd`
  loops of `package-observant.sh` and `package-producer-bundle.sh`, and OxidANT's `collect_hostlibs`.
  Run against those walkers on bundles of `:latest`'s own libraries, each produced the same files,
  byte for byte (27, 28 and 24 entries).
- `tests/test-elf-closure.sh` compiles its fixtures; 15 `packaging.elf-closure-*` mutations prove it,
  the wrapper's path among them. The walker had no suite of its own until now.

## 2026-10-19 — a docs guide's link to any repository file reaches GitHub

- **`lib/dartdoc-guides.py` rewrites every relative link of a guide**, not only `*.md` ones: a
  file goes to `<repository>/blob/develop/<path>`, a folder to `/tree/`, a submodule path to that
  submodule's repository. A link that names nothing in the repository and no page of the built
  site fails the render; a submodule the build did not check out is linked unchecked. Until now
  a link to a workflow, a manifest or a hub script stayed relative and 404ed: OmniAccelerANT's
  13 `docs/site-links.allow` rows, which go stale at its next hub pin
  ([`shared-script-libraries.md`](docs/shared-script-libraries.md#dartdoc-buildsh--theme-and-enrich-a-dart-doc-site)).
- Read over OmniAccelerANT's eleven guides in `:latest`: exactly those 13 links now point at
  GitHub, and every guide renders; jotrockenmitlocken's two render too.
  `tests/test-dartdoc-guides.sh` adds a fixture tree and an end-to-end render; 8 more
  `lib.dartdoc-guides-*` mutations prove it.

## 2026-10-19 — one release collector and one reusable release workflow

- **`linux/scripts/06-packaging/collect-release-assets.sh [options] <artifacts dir> <out dir>`**
  replaces the six consumers' own copies, which had diverged (wheels in AccelerANTgine only, zips in
  OmniAccelerANT and OxidANT, an inlined `put()` in OrchestrANT). Options cover every variant:
  `--skip`, `--include`, `--exclude`, `--only-from`, `--rename` (`{version}`, `{arch}`, `{machine}`,
  `{stem}`), `--flatpak-arch-from-suffix`, `--zip UPLOAD[/DIR]=NAME`, `--unpack`, `--expect`,
  `--strict`, and `--options FILE`, one per line. A docs site's upload (`*-docs-site`,
  `docs-site-*`) is always skipped. Duplicates, an empty release and a missing `--expect` fail
  ([`branch-and-release-strategy.md`](docs/branch-and-release-strategy.md#collecting-the-release-files)).
- **`.github/workflows/release-publish.yml`** ("Release · version check + publish (reusable)") is
  the `version:` and `release:` jobs every `release.yml` carried, ~105 identical lines each:
  `stage: check` before the lanes, `stage: publish` after them, with `dry-run` checking and
  collecting without a tag. A real publish runs from `main` only, a misspelt stage fails.
- `tests/test-collect-release-assets.sh` ports the six consumers' suites, each with its own options,
  plus AccelerANTgine's docs-site check, and pins the workflow's guards; 29 `release.*` mutations (a
  new declared family) prove it. Consumers move in a later wave.

## 2026-10-19 — every docs site is built, checked and published the same way

- **`build-docs.yml` is the family's docs-site lane** ("Docs · build + publish (reusable)").
  A `site` job builds the site in the image from `command` or `builder` (`rustdoc`, `python`,
  `dartdoc`, the hub's drivers) or takes an `artifact` an earlier job uploaded, then
  `docs-site.sh stage` adds the hub's `.htaccess` and 404 page and runs the link gate
  (`link-allow`). A `publish` job runs `deploy-over-ftp` on a push to `develop` or `main` only
  (a dispatch with `publish-on-dispatch`), in a `docs-publish-<site-name>` group that is never
  cancelled, with no `continue-on-error`. Secrets: `FTP_SERVER`, `FTP_USERNAME`,
  `FTP_PASSWORD`, nothing else; the old `SERVER`/`USERNAME`/`PW` inputs had no caller but the
  hub ([`docs-sites.md`](docs/docs-sites.md#the-reusable-workflow)).
- **The hub's site moved to `docs.yml`**: `linux-x64.yml`'s cancelling group could cut its
  upload off, and the preflight subset the old job ran is `linux-x64.yml`'s anyway.
- **`python-ci-linux.yml` publishes through it**: the x64 row builds the docs after a red test
  too and uploads them as `python-docs-site`; a new `docs` job calls `build-docs.yml`
  (`publish: deploy-docs`, new input `docs-link-allow`). OrchestrANT and WebDavClient need no
  change; their docs now publish from `develop` and `main` only, after the link gate.
- `docs-site.sh plan|build|stage` is the workflow's logic in one testable place;
  `tests/test-docs-site.sh` drives it and pins the publish job's guards; 19 more `docs-site.*`
  mutations prove it. `docs-sites.md` lists each repository's move onto the workflow.

## 2026-10-19 — one hub-owned .htaccess for the docs sites

- **`linux/webserver/templates/docs-site.htaccess`**: http → https (301, with a guard against a
  loop behind a TLS proxy), HSTS for a year, `X-Content-Type-Options: nosniff`, the FTP library's
  `.ftp-deploy-sync-state.json` answered as 404, and `ErrorDocument 404 /404.html`, with
  `docs-site-404.html` as that page. Read with `curl` the same day: all nine FTP sites are Apache on
  `85.13.169.97`, answer plain http with 200, serve the state file, and show Apache's default 404
  ([`docs-sites.md`](docs/docs-sites.md#the-sites-htaccess)).
- **Every directive is in Apache's FileInfo override class**, the one `jonasheinle.de` on the same
  host is proven to allow; `tests/test-docs-site-htaccess.sh` fails on any other, since a refused
  directive is a 500 on every page. The image has no `httpd`, so the suite checks the directives
  and the state-file regex; eight `docs-site.*` mutations (a new declared family) prove it.

## 2026-10-19 — a built docs site is checked for dead links before it goes up

- **`linux/scripts/verify_site_links.py <site dir> [--allow FILE] [--print-keys]`** reads a
  built HTML tree offline and fails on an internal link, meta refresh or anchor that resolves to
  nothing, a link that climbs out of the site root, and a root without `index.html`. It honours
  `<base href>`, reads anchors as written and decoded, accepts rustdoc's source line ranges, and
  skips dartdoc's script-injected sidebar fragments. Known exceptions go into an allow file under
  the two-way rule; `--print-keys` seeds one ([`docs-sites.md`](docs/docs-sites.md#the-built-site-link-gate)).
- **The hub's site resolves completely**: three Markdown links to a directory, which the theme
  rendered as dead anchors (`#../linux/scripts/01-core/`), point at the GitHub tree now. Built in
  `:latest` by `build-docs.sh`: 96 documents, 0 findings. OxidANT's 11-crate rustdoc: 517
  documents, 20 `missing <module>/dispatcher` in `kataglyphis_webgpu_renderer`.
- `tests/test-site-links.sh` builds fixture sites; 16 `site-links.*` mutations (a new declared
  family) prove it. `docs/docs-sites.md` is the page for what the hub does to a site before the
  upload.

## 2026-10-19 — the dartdoc guide renderer downloads nothing in CI

- **`dartdoc_build_prepare_python_env` takes `python3` when it imports `markdown-it-py` at the
  version `lib/dartdoc-guides.requirements.txt` pins** (`:latest`: `/opt/venv/bin/python3`,
  4.2.0). With `CI=true` or inside the image (`/opt/venv`) it fails instead of installing it
  from PyPI; only a workstation without the image still builds the uv venv, for OmniAccelerANT's
  documented host run of `generate-docs.sh`
  ([`shared-script-libraries.md`](docs/shared-script-libraries.md#the-renderers-python)).
- `tests/test-dartdoc-python.sh` drives every branch with a stub parser; six
  `lib.dartdoc-python-*` mutations prove it. BACKLOG CON101 keeps what is left: the image pin and
  its smoke check, and the two consumers that still run a bare `dart doc`.

## 2026-10-19 — rustdoc documents every crate of a workspace

- **`02-toolchain/rust/cargo_build_doc.sh` adds `--workspace` when `Cargo.toml` has a
  `[workspace]` table** and the caller named no packages (`-p`, `--package`, `--workspace`,
  `--all`). OxidANT, its one caller, published `oxidant` alone; in `:latest` against OxidANT
  `8af8f67` the driver now documents all 11 crates in 39 s. A single-package manifest builds as
  before ([`shared-script-libraries.md`](docs/shared-script-libraries.md#every-crate-of-a-workspace)).
- `tests/test-cargo-build-doc.sh` drives the driver with a logging `cargo`; three `rust.cargo-doc-*`
  mutations prove it.

## 2026-10-19 — the site renders with DocumANTation 4866eae

- **`third_party/DocumANTation` 4783f2c → 4866eae**: Markdown links between pages resolve on the
  site, links to repository files go to GitHub, headings get anchors to depth 6, and the family
  logo, favicon and a page title without the version are `setup_theme()` defaults.
- **`docs/conf.py` passes no `release`**: titles no longer carry it, and nothing else reads it.
- Built in `:latest` (Sphinx 9.1.0) and crawled offline: 95 pages, 273 internal targets, none
  broken; the live site, on the old theme, had 184. Three anchors stay dead: links to a directory
  (`../linux/scripts/01-core/`, `../linux/scripts/02-toolchain/rust/`, `upstream/patches/`)
  render as fragments, which the theme has to map.
- **Two archives render again** (rendering fixes, the records unchanged):
  `windows-backlog-archive-2026-08-21.md` had a bare `<script>` in prose that swallowed the rest
  of the page, now in backticks; `changelog-archive-2026-09-07.md` linked the old D5 heading of
  `linux-host-setup.md` and now names the current one.

## 2026-10-19 — a consumer page that restates a hub page fails

- **`verify_doc_dupes.py --against-hub --root <consumer>`** grades a consumer's tracked pages
  against every tracked page of the hub it ships in, by the same shingle rule: a consumer
  paragraph and a hub paragraph sharing more than 12 eight-word shingles is a copy. Budgets are
  the consumer's, in `<root>/doc-dupes-hub.allow` (`consumer page | hub page | budget | reason`),
  and the mode is **off until that file exists**: it says so and exits 0 without reading the hub,
  and `--report` lists what it would find. Without a consumer `--root` it exits 2.
- **`run-lint-gates.sh --ratchets` runs it** in every consumer, beside `doc-links`.
- **Badge and image lines are markup, not prose**, in both modes: every family README's badge
  row matched the hub's. The hub's own run scans one paragraph fewer and keeps every budget.
- `tests/test-doc-dupes.sh` drives the mode against a fixture hub and the aggregator call; ten new
  `doc-dupes.*` mutations prove it ([`code-quality-tooling.md`](docs/code-quality-tooling.md#consumer-pages-against-the-hub-doc-dupes---against-hub)).
  No consumer is seeded yet; on 2026-10-19 nine of the twelve family repositories had a finding, 23 in all.

## 2026-10-19 — the hub stops restating its neighbours, and one wrong credit

- **`geniex-local-ai-setup.md` §§ 1m/1n keep the GenieX measurements and link the lab for the
  harness**: what `bench_agent.py` scores, its self-test and blocked-is-not-failed rule, the
  tool-call shim's usage and refusals, `bench_coding`'s cut detection and `--deadline`, and the
  2026-09-05 grader fixes are OrchestrANT's `benchmarks/README.md`, linked at `develop`. The
  reproduce block pointed at `benchmarks/` paths this repository no longer has.
- **`linux/llm-stack/README.md`**: the gateway's acceptance steps are OrchestrANT's; the hub keeps
  the `budget_tokens` trap and what is not covered yet.
- **`project-info.md` § Reusable Sphinx theme package** says what the hub wires and links
  DocumANTation for the rest; it carried the same opening sentence twice.
- **The Dev Drive `fsutil` command lives only in `windows-container-build-performance.md`**;
  `windows-build-lanes.md` links it.
- **`data-repositories.md`**: `scripts/windows/Get-Models.ps1` is OxidANT's, not OmniAccelerANT's
  (OxidANT tracks it; OmniAccelerANT has none).

## 2026-10-19 — generic facts the consumers carried get one hub home

Each was written out in one or more consumers; the hub now owns it and the consumers can link.

- **Linux packages** ([`linux-build-basics.md`](docs/linux-build-basics.md#linux-packages-that-run-outside-the-image)):
  the section has headings to link, and two new parts: an `$ORIGIN` RUNPATH per bundled ELF,
  because RUNPATH is not transitive, and **GStreamer loads from the package alone** (the four
  variables, set-unless-set in a constructor, `gstreamer-bundle.sh copy`/`check`).
  `python-app-bundles.md` § GStreamer links there instead of listing the variables.
- **Submodule URLs are https, never `git@`**: `adopting-in-a-new-project.md` § 0.
- **`dart format`**: never `dart format .` (the analyzer's `exclude:` does not stop it; checked
  in `:latest`, Dart 3.13.5), and the `environment: sdk:` floor picks the style the frb codegen and
  `gen-l10n` format with: `code-quality-tooling.md` § `dart format`: the tracked files, in the
  floor's style.
- **`failure-modes.md`**: `set: pipefail\r: invalid option name` (a CRLF checkout) and the MSVC
  STL 14.51 `unexpected size` `static_assert` under clang-cl (microsoft/STL#6294, fixed upstream by
  #6298 on 2026-10-18, not yet in the image's VC Tools).
- **Local lanes**: KVM in Rancher's VM for the Android emulator
  (`rancher-desktop-linux-containers.md`), a lane under a rootless engine on a Linux host runs as
  root with `TAR_OPTIONS=--no-same-owner` (`linux-build-basics.md`), and QEMU user mode on a
  16 KiB-page kernel (`riscv64-cross-test-lanes.md` § Traps).
- **`cmake/README.md` § Sanitizers**: what the modules do on every compiler, checked against
  `Sanitizers.cmake` and `SanitizerSupport.cmake`; `windows-clang-cl-sanitizers.md` links it.
- **`shared/templates/AGENTS.md.template`**: a § 2 row for the bootstrap copies and module
  resolution, a § 3 line for `git-sync-branches.sh`. `INDEX.md` names every new anchor.

## 2026-10-19 — the dartdoc guide renderer's links land

- **An anchored link between guides is rewritten.** `dartdoc-guides.py` tested the whole
  href for a `.md` suffix, so `getting-started.md#known-issues` stayed as written and 404ed on
  the site; it now becomes `guide-getting-started.html#known-issues`.
- **A link to a Markdown file that is no guide goes to GitHub.** `../AGENTS.md` became
  `guide-AGENTS.html`, which nothing renders; it now becomes
  `<repository>/blob/develop/AGENTS.md`, and a path inside a submodule goes to that
  submodule's repository. The repository is the new `DARTDOC_BUILD_REPO_URL`, else the
  checkout's `origin`, so OmniAccelerANT's `generate-docs.sh` needs no change. A link out of
  the repository, or with no URL to use, fails the render.
- **Links resolve from the guide's source path**, which `dartdoc-build.sh` now hands the
  renderer: a guide is found by the file a link names, not by a slug that happens to match
  (`README.md` beside `docs/source/overview.md` is the `docs-readme` guide).
- **Heading anchors are GitHub's** (`run-lint-gatessh--seven-gates`, not `…sh-seven-gates`).
- `tests/test-dartdoc-guides.sh` is the renderer's first suite; eight `lib.dartdoc-guides-*`
  mutations prove it. Rendering OmniAccelerANT's eleven guides in `:latest` leaves no relative
  `*.md` link and finds every anchor its cross-guide links name.

## 2026-10-19 — two stale facts: pyhailort's Python, MSIX trust

- **pyhailort is built for `PYTHON_VERSION`, not for "3.14".** `hailo-support.md` and
  `overview.md` said the image runs 3.14 and that the staged wheel serves a ≤3.13
  environment. The pin is 3.15.0 since CON90, and no image with pyhailort on 3.15 is built
  yet; the published `:latest` (2026-10-11) runs Python 3.14.4, stages
  `hailort-5.4.0-cp314-cp314-linux_x86_64.whl`, which installs on 3.14 only, and imports
  `hailo_platform` on amd64 (checked 2026-10-19).
- **A self-signed MSIX certificate needs `LocalMachine\TrustedPeople` only.**
  `windows/scripts/certificates/README.md` said `TrustedPeople` alone fails with
  `0x800B0109` and told everyone to import into `Root` too. OmniAccelerANT's installer test
  imports a fresh self-signed certificate into `TrustedPeople` alone and `Add-AppxPackage`
  passes on `windows-2025` and `windows-11-arm` (runs 39038477716 and 39038479571,
  2026-10-17). `Root` is for a CA-issued certificate's CA and for `signtool verify /pa`.

## 2026-10-19 — the README rule is a gate

- **`readme-length` fails a root `README.md` over 100 lines**, badges included, and names
  `repository-family.md` § The README rule. It is a preflight slug in the commit hook's fast set,
  and `run-lint-gates.sh` runs it over every consumer, so `lint-gates.yml` and the consumers'
  pre-commit hook enforce it. `tests/test-readme-length.sh` drives both halves; five
  `readme-length.*` mutations prove the limit, the unterminated last line, the missing file and
  the consumer wiring ([`code-quality-tooling.md` § README length](docs/code-quality-tooling.md#readme-length-readme-length)).
- **The hub's README is 100 lines, down from 103**: the failure-modes pointer already in the
  documentation table left the quick start, and two paragraphs were rewrapped. Every consumer
  README was at most 89 lines when the gate went in.
- **`lint-gates.empty-shell-list-refuses` bites on a Git Bash host too.** Its case let the real
  `lint-shell.sh` lint the mutation mirror, which fails there, so the missing refusal still read
  red; a green stand-in now plays the clean hub.

## 2026-10-19 — one page for the family, and the README rule

- **`docs/repository-family.md` holds what every repository shares:** what each one is and who
  vendors or fetches it, how one is laid out, contributing, licence and contact. The READMEs
  link to it instead of carrying their own copies, which had drifted to four different contact
  addresses and a fork-and-feature-branch recipe that contradicts the develop-only rule.
- **The README rule (owner, 2026-10-19):** a README is a short overview, under about 100 lines,
  that links into `docs/` for everything else; facts true for more than one repository move to
  this hub. `shared/templates/README.md.template` is that shape.
- **The hub's own README follows it: 408 lines to about 100.** What it carried moved, not copied:
  the accelerator table, the live-index warning, the annotated Dockerfile tree, the phases and
  the three lanes, and the home-lab section to `docs/overview.md`; the CI table's names and
  purposes to `docs/ci-build-triggers.md`, which gained `windows-arm64.yml` and the dispatch-only
  probes; the 2026-09-22 Windows measurement to `docs/windows-cross-builds.md`; the corrected run
  snippet and the rootless note to `docs/linux-build-basics.md`; the 2026-09-01 gates to
  `docs/code-quality-tooling.md`. The rest was already a doc's and is linked. Two claims were
  stale and are fixed where they landed: `:latest-nvidia` and `:latest-rocm` are published for
  amd64, and the clone line used an ssh URL.

- **What the READMEs carried for more than one repository moved here.** `python-ci.md`
  § Working on a Python consumer locally (the hook, the static-analysis gate, binary-only
  wheels, the tools), `failure-modes.md` (a host CMake too old for `"version": 10` presets),
  `branch-and-release-strategy.md` (checking a download against `SHA256SUMS`), and
  `repository-family.md`: a README rendered on PyPI, rustdoc, `dart doc` or Sphinx links its own
  files absolutely; ModelANT's scripts are Apache-2.0; AccelerANTgine fetches from ModelANT too.
  `project-info.md` points at the family page for contributing and contact, and lost the 3D-model
  acknowledgements, which were never this repository's.
- **`doc-links` no longer crashes on a submodule below a consumer's top level.** Its consumer
  scan read every `git ls-files` path as a file, and a gitlink is a directory:
  `PermissionError` on DocumANTation's `md2pdfLib/third_party/`. It keeps files only now;
  `test-doc-links.sh` plants the nested gitlink, and `doc-links.consumer-gitlink-skip` proves
  the case bites.
- `linux-accelerator-images.md` no longer calls `:latest-rocm` unpublished: it is, since 2026-10-09.
- **Docs are short and precise, written like a developer would** (owner, 2026-10-19): in this
  `AGENTS.md`, the `AGENTS.md` template and every consumer's `AGENTS.md`.
