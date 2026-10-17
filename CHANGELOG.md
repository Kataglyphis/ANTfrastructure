# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-10-08 … 2026-10-12`](docs/changelog-archive-2026-10-12.md) ·
> [`2026-10-01 … 2026-10-07`](docs/changelog-archive-2026-10-07.md) ·
> [`2026-09-22 … 2026-09-30`](docs/changelog-archive-2026-09-30.md) ·
> [`2026-09-08 … 2026-09-21`](docs/changelog-archive-2026-09-21.md) ·
> [`2026-08-29 … 2026-09-07`](docs/changelog-archive-2026-09-07.md) ·
> [`2026-08-14 … 2026-08-28`](docs/changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.

## 2026-10-17 — `git-adopt-rewritten-history.sh`: a checkout after a history rewrite

- **New entry point `linux/scripts/git-adopt-rewritten-history.sh`**, for the family's
  purge of big blobs from history. It moves a checkout and its submodules onto the
  rewritten remotes, saves the local work first (uncommitted changes, stashes, commits
  that never reached origin, local-only tags) and drops the old objects with
  `reflog expire` + `gc`. A rewritten commit is recognised by its twin on origin (same
  author, author date and subject), because the first draft compared against origin's
  branches before the fetch, and a `--dry-run` (or an IDE's background fetch) had
  already moved those. `test-git-adopt-rewritten-history.sh` rewrites a superproject
  and its submodule with `filter-branch` and checks the backups, both submodule states,
  the dropped blobs and that a second run changes nothing. Docs:
  `adopting-in-a-new-project.md` § *After a history rewrite*.
- **`tests/git-fixture-env.sh`** holds the git environment both git fixture suites set
  (file:// submodules, `develop`, one identity); `code-dupes.allow` records two budgets that
  had shrunk (`python-app-bundle.sh` 57 → 56, `verify-parity.sh` 22 → 21).

## 2026-10-17 — the sccache bucket's size cap is 100 GiB

- **The VPS raised the cap from 60 to 100 GiB** (`CAP_GB=100` in `sccache-evict.service`), at the
  owner's request, so Linux builds share the bucket. The eviction target follows, at 90 %: 90 GiB.
- **The Garage layout's capacity is 120G** (was 80G). On one node it is only a weight, kept above
  the cap.
- The bucket held 50.1 GiB (756k objects) and the shared disk had 87 GB free.
  `linux/sccache-s3/README.md` records both and the steps for the next change.

## 2026-10-17 — data repositories: models and scenes outside the code

- **`docs/data-repositories.md`** describes the family's rule of the same day: code
  repositories track code, ModelANT holds the models, the new AssetANT the 3D scenes. It
  covers the lock format, the contract every fetcher keeps, the two-field scene stamp (a
  hash-only stamp reported "up to date" over an emptied directory), and what stays tracked.
  OrchestrANT dropped its 78 MiB AGPL `yolov26m.onnx` for ModelANT's DEIM-D-FINE-N, and
  BeschleunigerBallett moved 518 MiB of scenes to AssetANT. `python-app-bundles.md`'s example
  `app.json` names the new model. BACKLOG CON98: one hub-owned fetcher in place of three.

## 2026-10-17 — the arm64 setup .exe: NSIS's x86 stub passes the arch gate, and the device installs it

- **`Test-TargetArch.ps1` reports an NSIS installer instead of failing it.** NSIS has no arm64
  stub, so AccelerANTgine and BeschleunigerBallett dropped their arm64 setup `.exe` from every
  release while x64 shipped one. The gate recognises the installer by NSIS's first header
  (`0xDEADBEEF`, `NullsoftInst`) in its first 8 MiB, lists it under "NSIS installers", and counts
  it as nothing. An x86 binary without that header still fails. One Pester case in
  `SourceBuild.VerifyTargetArch.Tests.ps1`.
- **`container-ci-windows.yml`'s `run-arm64` job installs each `packages/*.exe`** on
  `windows-11-arm`, silently and emulated. It then checks that every installed `.exe`/`.dll` is
  ARM64 and runs the new `installed-run-command` in the install directory. Last, it uninstalls in
  place, and no DLL may stay behind. Owner rule of the same day: every release ships Windows arm64
  installers next to the x64 ones.

## 2026-10-17 — the Linux chain's sccache gets the shared S3 level

- **Every sccache RUN of the Linux chain can chain the shared bucket behind its disk cache
  mount** (`disk,s3`), the bucket the Windows chain has used since 2026-10-15. The host's key
  goes to `nerdctl build` as one secret, `id=sccache_s3`, with the endpoint in it, so neither
  re-keys a RUN. `sccache_start_server` (`01-core/sccache-s3-level.sh`) hands it to the server
  alone, never to the build's environment. A refused key or a stalled check restarts the server
  on disk alone, and each RUN ends with an upload drain. Without the host file every build runs
  as before.
- **`linux/host-config/set-sccache-s3-level.sh`** stores the key in
  `~/.config/kataglyphis/sccache-s3.env` (600), after a signed list request accepts it.
- 23 RUNs in `Dockerfile.toolchain`, `.media`, `.android` and `.torch` changed, so the next chain
  re-keys every sccache stage once, from the GCC build on.
- Measured through rootless BuildKit against the real bucket: 60 cold writes reached level 1, 29
  of them after the compiles ended (the drain took 2 s), and the same RUN on an empty disk cache
  id hit 60 of 60. Tests: 27 assertions in
  `test-sccache-s3-level.sh`, one of them over every Dockerfile RUN on the sccache mount.

## 2026-10-17 — native Windows arm64 wheels

- **`python-ci-windows.yml` takes `arm64-wheels`.** After the arm64 test legs, the
  `windows-11-arm` job builds one binary wheel per leg with Visual Studio's clang-cl
  (`windows/scripts/python/Invoke-NativeWheelBuild.ps1`) and uploads them as
  `packages-windows-arm64-wheels`. Each must be that leg's `cpXY`/`cpXYt` `win_arm64` wheel, and
  it is installed alone into a fresh venv where every compiled module loads. The `:winarm64`
  container cross-builds no GIL Cython wheel, so WebDavClient v0.10.0 shipped `win_amd64`
  wheels only. Owner rule of the same day: every release ships Windows arm64 next to x64.
- **`free-threaded-wheel.py load DIST`**, the GIL build's twin of `prove`: every compiled module
  loads, on any interpreter. `Invoke-FreeThreadedWheelProof` and
  `Invoke-FreeThreadedWheelVenvProof` take `-Check load`.
- **`Resolve-PythonLegList`** reads a leg list (`pinned`, `pinnedt`, either separator) for
  `Invoke-PythonTestLegs.ps1` and the new script alike.
- Tests: 10 new assertions in `test-python-free-threaded-wheel.sh` (a real extension loads, a
  broken one fails) and three Pester cases in `PythonWheel.FreeThreaded.Tests.ps1`.

## 2026-10-17 — docker's parallel layer downloads, as a measurement

- **`prepare-linux-ci-host` takes `max-concurrent-downloads`** (empty by default: docker keeps
  its 3). A number is merged into `/etc/docker/daemon.json` and the daemon restarted before the
  pull. OmniAccelerANT's Linux x64 lane sets 10. Its first run pulled the 28 GiB `:latest` in
  288 s, against 318-325 s over the five runs before (39014164655); one run is no default yet.

## 2026-10-17 — the MSIX takes a CMake project's version

- **`Get-PackageVersion` reads `CMakeLists.txt`'s `project(... VERSION x.y.z)`** when a workspace
  has no `VERSION.txt`/`version.txt`. AccelerANTgine has none, so its MSIX stayed at the
  `0.0.1.0` fallback while CPack stamped 0.0.2 on everything else (its 0.0.2 dry run,
  38985083941: `AccelerANTgine_0.0.1.0_x64.msix` beside `AccelerANTgine-0.0.2-Release-x86_64.msi`),
  and an MSIX with an unchanged version does not upgrade an installed one. A version file still
  wins. Two Pester cases in `WindowsMsix.Common.Tests.ps1`.

## 2026-10-17 — the closure tool compares RUNPATH entries whole

- **`python-app-closure.sh` skipped a needed `$ORIGIN`** whenever an entry such as `$ORIGIN/..`
  already contained it as text. Under `LOADER` the moved program carries `$ORIGIN/..`, so it never
  got `$ORIGIN`: AccelerANTgine's clean-host job (x64 and arm64, 6ad3b09) found its
  `lib/accelerantgine/AccelerANTgine` taking the distro's `libstdc++` (`GLIBCXX_3.4.36 not found`)
  and no ORT. The launcher hid it (`--library-path`), and so did the image (its ld.so cache has
  GCC 16's `libstdc++` and ORT). The check now matches whole entries; a new assertion in
  `test-linux-closure-install.sh` (32) resolves the moved program with the system loader and fails
  on the old tool.

## 2026-10-17 — a Flutter bundle through the loader, and a flatpak that keeps the bundle whole

- **`bundle-loader.sh --beside`** keeps the program in its directory as `<name>.bin` with the loader
  next to it: under the launcher `/proc/self/exe` names the loader, and a Flutter runner finds
  `data/` from that directory. OmniAccelerANT's October 12 bundle, wrapped this way, held its
  20 s launch smoke under Xvfb in the image and reached GTK on himbeere2's Debian 13. A second run
  finds its own launcher and changes nothing. GStreamer then scans plugins in-process, since its
  external scanner is handed `/proc/self/exe`.
- **The Flutter flatpak installs the bundle whole** under `/app/lib/<package>/`, with
  `/app/bin/<package>` a link to its runner, as the AppImage does. It installed the runner alone
  in `/app/bin` and `data/` in `/app/data`, where the runner never looks.
- `test-linux-closure-install.sh`: 31 assertions.

## 2026-10-17 — `LOADER`: Linux packages start on Debian 13 too

- **`kataglyphis_install_linux_closure(LOADER ...)`** ships the image's loader and glibc:
  `06-packaging/bundle-loader.sh` moves each executable beside them in `lib/<PRIVATE_DIR>` and
  leaves a launcher that starts it through that loader. Measured on himbeere2 (Debian 13, glibc
  2.41, GStreamer 1.26) with AccelerANTgine: the tarball, the unpacked `.deb` and the AppImage
  start with `LD_BIND_NOW=1`, and `apt-get install --simulate` takes the `.deb`.
- **Two traps on the way, both handled in `LOADER`:** CPack's AppImage generator patches every
  library without a RUNPATH, the bundled loader included, which then segfaults
  (`patchelf-keep-glibc.sh` leaves glibc as built); and `dpkg-shlibdeps` read the bundled glibc as
  the system's and pinned `libc6 (>> 2.43), libc6 (<< 2.44)`, so it is off and `DEBIAN_DEPENDS`
  names what the system brings.
- `test-linux-closure-install.sh`: 26 assertions (the launcher, the relocated run, the wrapper).

## 2026-10-16 — Linux packages that start outside the image

- **AccelerANTgine 0.0.1's Linux packages started nowhere but in the image.** They needed GCC
  16.2's `libstdc++` (`GLIBCXX_3.4.36`) and the chain ORT, carried neither, and the executable
  could not find its own `lib/`. BeschleunigerBallett's and OmniAccelerANT's need `GLIBC_2.43`.
  Nothing noticed, because every check ran inside the image.
- **`kataglyphis_install_linux_closure`** (`cmake/CPackCommon.cmake`): at install time, what the
  installed files need beyond glibc, glib, the graphics stack and `SYSTEM` goes to
  `lib/<PRIVATE_DIR>` with `$ORIGIN` RUNPATHs, the compiler's own `libstdc++` first.
  `python-app-closure.sh` gained `--system`. `test-linux-closure-install.sh`: 17 assertions.
- **Only the top-level project's call counts.** AccelerANTgine, which OmniAccelerANT's plugin
  pulls in by `add_subdirectory`, would otherwise rewrite the Flutter bundle on install, the
  chain ORT that G6 grades included; the test fails without the guard.
- **The `clean-host-package-check` action** installs a `.deb` with apt on a bare `ubuntu-26.04`
  runner, scans every installed ELF with `ldd` and starts a command with `LD_BIND_NOW=1`.
- **Left: Debian 13 and Ubuntu 24.04** (glibc 2.41, 2.39) need the image's loader and libc in the
  package, as ObservANT does: CON97.

## 2026-10-16 — the AMF header pin follows AMD's re-upload of v1.5.3

- **AMD replaced the asset `AMF-headers-v1.5.3.tar.gz` at 19:36 UTC**, two weeks after the release
  (2026-09-29). The new file is 88,584 bytes with GitHub digest `0f521ad9…`.
- The rocm chain fetched the old one at 17:05 UTC. The nvidia chain's FFmpeg stage refused the new
  one four times (`SHA256 mismatch`) and stopped, as the pin is meant to.
- **The contents did not change.** All 57 headers in the new tarball equal the blobs at the git tag
  `v1.5.3`, byte for byte (the full tree, not truncated). Only the archive was repacked.
- `AMF_HEADERS_SHA256` in `versions.env` and the ARG default in `Dockerfile.media-builder` now name
  the new digest. The note above the pin records why.

## 2026-10-16 — VS Build Tools from VS 18's own channel name

- **`aka.ms/vs/18/release/vs_buildtools.exe` redirects to Bing.** Every base build of the day got
  its HTML page three times before the floating fallback took over. VS 2026 names its channels
  `stable` and `insiders`; `aka.ms/vs/18/stable/` serves the 5.7 MB bootstrapper.
- **`Install-Vs.ps1` tries `vs/<major>/stable/` first**, then `vs/<major>/release/` (VS 17 and
  older), then the floating `vs/stable/`. Only the floating alias triggers the floating-channel
  warning. Tested in `Host.InstallVsUrls.Tests.ps1`.

## 2026-10-16 — the cache work, measured on two nvidia chains; cargo's wrapper goes

- **ONNX Runtime with nvcc through sccache.**
  - nvidia stage: 83 min with nvcc bare (2026-10-14), 79 min on the first fill.
  - **22 min warm** (1332 s), 569 of 569 CUDA files hit, 0 misses in 6134 requests.
  - The exemption kept `onnxruntime_providers_cuda_llm` bare every time.
  - `onnxruntime_providers_cuda` linked from hits, and the smoke gate passed 301 assertions.
- **Bazel's cache on dufs.**
  - LiteRT-LM 429 s cold → 204 s warm (3618 of 3619 actions from the cache).
  - The ai-edge-litert wheel 238 s → **23.5 s** (3925 of 3925).
  - The stage: 1379 s → 927 s.
- **The S3 level in a full chain:** both levels at every server start, 179 and 36 writes with none
  failed, every drain 0 s.
- **cargo's `RUSTC_WRAPPER` is taken out again.**
  - 99 % Rust hits left gst-plugins-rs at 131 s against 125 s bare, because its plugin crates are
    cdylibs.
  - It had also brought a failure: cc-rs wrapped meson's shim, and sccache refused it.
  - `SourceBuild.GstreamerWebRtc.Tests.ps1` now checks that the cargo plan sets no wrapper on
    either arch.
- Docs: `windows-build-resources.md` (§ Persistent compile cache, § Two cache levels, § Bazel's
  cache) and `windows-builds.md` § gst-plugins-rs on Windows carry the numbers.

## 2026-10-16 — the sccache bucket's runbook carries the live server's files

- **The outage's cause, and its fix on the VPS.**
  - The FritzBox's IPv6 prefix changed overnight. `wg` had resolved the endpoint's MyFritz name
    once, so the bucket was unreachable for about 8 hours.
  - `wg-reresolve-dns@wg0.timer` runs wireguard-tools' own `reresolve-dns.sh` every 30 s; a peer
    whose handshake is older than 135 s gets its name resolved again. Recovery: about 20 s.
- **`linux/sccache-s3/` now holds what the server runs**, with every secret, the MyFritz name and
  the IPv6 prefix as placeholders:
  - Garage as the system user `garage` in `/srv/garage`, `/etc/garage/garage.toml` 640, zone `vps`.
  - `sccache-s3-evict`, which checks the bucket size through the admin API before it lists anything.
  - The key files `/root/sccache-s3-key.txt` and `/etc/garage/evict-key.txt`.
  - The two re-resolve units.
- The reconstructed `sccache-evict.sh` and `sccache-evict.env.example` are gone.
- **The tunnel and Garage come back by themselves.**
  - `wg-quick@wg0.service.d/retry.conf` retries a tunnel whose endpoint name did not resolve at
    boot, every 30 s with no start limit.
  - `garage.service` is also wanted by `wg-quick@wg0`, so the `BindsTo` stop is followed by a start
    when the tunnel returns. Tested by restarting `wg0`.

## 2026-10-16 — a bucket that stalls sccache's startup check no longer stops a build

- **What happened.** The VPS stopped answering through the tunnel at about 00:49, while the first
  nvidia chain with the S3 level was running.
  - ORT finished, with 608 of 2364 level-1 writes failed.
  - FFmpeg's sccache server then timed out in its startup check, and every compile failed. One level
    that fails its check stops the whole server (`multilevel.rs`).
- **The fix.**
  - `Start-SccacheServerSession` drops the S3 level (`Remove-SccacheS3Level`, Shared) when the server
    does not start with it, and starts the server again on WebDAV.
  - The app builds' exec passes `SCCACHE_SKIP_CACHE_CHECK=true`.
  - `Set-SccacheChainWithout` is the one owner of the chain edit, `Clear-UnreachableSccacheEndpoint`
    included.
- **The same chain measured ORT's new launcher, cold for CUDA:** the exemption hit
  `onnxruntime_providers_cuda_llm`, nvcc made 292 hits and 277 misses, and the stage took 4746 s
  against 4956 s bare.
## 2026-10-16 — One release script for every repo

- **`06-packaging/publish-github-release.sh`** publishes `v<version>` at `HEAD` with a directory's
  files, a `SHA256SUMS` and the version's CHANGELOG section (`## <version>` or `## [<version>]`).
  It started as OmniAccelerANT's `publish-release.sh`, which knew only `pubspec.yaml`; OxidANT's
  release takes its version from `Cargo.toml`. It refuses a released version, a version without
  a section, notes over GitHub's 125000 characters, an unanswering GitHub and an empty directory.
  `test-publish-github-release.sh`: 34 assertions, each refusal checked for its message and for
  no release asked of GitHub; a loose heading match, a dropped `[` strip, a dropped release check and a dropped
  "not found" check each fail.
- **`version_util.sh --file-version <file>`** prints the version a `VERSION.txt`, `Cargo.toml` or
  `pubspec.yaml` (without its `+build`) states, and fails without one: a release never falls back
  to a branch name. `test-version-util.sh` grows to 13 assertions.

## 2026-10-15 — `version_util.sh` reads a `Cargo.toml`

- **A Rust repo keeps its version in `Cargo.toml` alone** (owner, for OxidANT). Handed a file
  named `Cargo.toml`, `version_util.sh` reads `[workspace.package]`'s `version`, else
  `[package]`'s, never a dependency's; `container-ci-windows.yml`'s `version-file` passes it
  through. `test-version-util.sh` is new (7 assertions: both file kinds, a dependency table,
  the fallbacks, `--github-env`); dropping the section check or the `Cargo.toml` branch fails 2
  and 4 of them.

## 2026-10-15 — The Dart gate can write coverage from its own test run

- **`flutter_checks.sh --coverage <file>`** runs the gate's `flutter test` with
  `--coverage --coverage-path <file>`, so a lane's coverage floor reads that report instead of
  testing everything a second time (55 s per push on OmniAccelerANT's native lane). Refused
  with `--test-platform chrome`. `test-flutter-checks-platform.sh` covers both cases.

## 2026-10-15 — the app builds reach the S3 level, and cargo goes through sccache

- **Reused build containers get the shared S3 level per `docker exec`.**
  - `Get-HostSccacheS3ExecEnv` returns the settings and both key halves only when all of them exist
    and the bucket answers.
  - `Invoke-ContainerBuild` passes them as value-less `-e NAME`, which docker resolves from its own
    environment, so the key reaches no command line and no container config.
  - The bind-mount transport, kept for inspection after a failure, does not get it.
- **One owner for the S3 settings:** `Get-SccacheS3Level` (Shared) now serves both the image chain's
  `Get-BkSccacheConfig` and the container path; `Invoke-WithProcessEnvironment` serves the docker
  call and `Invoke-S5cmdWithKey`.
- **gst-plugins-rs compiles through sccache:** `RUSTC_WRAPPER` and `CARGO_INCREMENTAL=0` whenever
  meson's compiles do; the step took about 2 min uncached in every variant.
- The Linux lanes have no remote sccache tier yet, so the bucket does not reach them.
## 2026-10-15 — Branches, CI rounds and releases: one rule for every repo

- **Owner rule, written down in `docs/branch-and-release-strategy.md`.** A push to
  `develop` runs the Linux x64 lane only. Every other lane runs when a commit message
  asks with `[ci <lane>]` (`[ci windows]`, `[ci arm64]`, `[ci all]`) or by hand. `main`
  moves only by a fast-forward to a fully green `develop` commit, and every push to it
  runs every lane and releases only when all are green. It replaces the 2026-09-24
  rule of every lane on every push; `ci-build-triggers.md` lists which repo has moved.
- **New action `requested-lanes`.** It reads the `[ci <word>]` tokens of every commit
  in a push, plus a dispatch's words, and says which lanes they pick; a lane
  `<os>-<arch>` answers to each part of its name. `test-requested-lanes.sh` has 14
  checks, and four planted bugs each fail one or more. The self-test calls it.
- AGENTS.md's *Which CI lanes run when* becomes *Branches, CI rounds and releases*,
  and the consumer template's § 2 table gets the row.

## 2026-10-15 — ORT's nvcc keeps sccache, and the LiteRT bazel builds get a cache

- **ONNX Runtime's CUDA kernels go through sccache again on a Blackwell arch list.**
  - Since 2026-09-26, `Disable-OrtCudaLauncherForPtx` had dropped the nvcc launcher for all of
    ORT, because one target compiles `120-virtual` on MSVC and sccache aborts PTX-only output
    (mozilla/sccache#2862). The nvidia ORT stage then took 83 min, the longest step of any chain.
  - `sccache-ptx-exempt.cmake` now clears the launcher only on targets with a `-virtual` arch:
    `onnxruntime_providers_cuda_llm`, and the CUDA plugin's `_llm` twin when it is built.
  - The suite runs CMake on a stand-in project.
- **Bazel's HTTP cache on the host's dufs.**
  - The LiteRT-LM build (5244 actions, ~400 s) and the ai-edge-litert wheel (5655 actions, ~226 s)
    ran in full in every variant.
  - `Get-BazelRemoteCacheArg` points both at `<SCCACHE_WEBDAV_ENDPOINT>/bazel` with every output
    downloaded, and leaves the option out when the endpoint is missing or silent.
  - dufs answers the protocol as it is (PUT 201, GET 200, missing 404).
  - The S3 seed skips `bazel/`.
- Neither is measured in a chain yet: docs/windows-build-resources.md § Persistent compile cache
  (sccache) and § Bazel's cache.

## 2026-10-15 — sccache gets a second level: a shared S3 bucket behind each host's WebDAV

- **The Windows lane can chain `webdav,s3`.** Level 0 stays the host's dufs. Level 1 is a Garage
  bucket on a VPS that every build host reaches over the FritzBox's WireGuard, so one host's
  compiles become hits on the others. sccache writes level 0 in the compile and level 1 in the
  background.
- **Why not a disk level 0.** Windows BuildKit cache mounts still lose writes:
  `Invoke-SccacheWriteProbe.ps1` lost 165 of 250 writes in its second run, and none in a plain
  directory. Two WebDAV levels cannot chain either, because sccache allows each backend type once.
- **The key travels only as env-sourced BuildKit secrets.**
  - `Build-Buildkit.ps1` passes `--secret id=sccache_s3_key_id,env=…` and `id=sccache_s3_secret,env=…`.
  - All 16 sccache RUNs mount them as `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
    (`--mount=type=secret,…,env=…`), and declare the bucket's four settings as ARGs.
  - Probed with a dummy secret: it is set in its RUN, gone in the next, and a build without it
    still runs.
  - The publish gate and its Python twin now fail an image environment carrying an `AWS_*` credential.
- **No upload is lost at the end of a RUN.**
  - A stopping sccache server drops its unfinished background writes (`multilevel.rs`).
  - `Complete-SccacheServerSession` therefore waits in `Wait-SccacheUploadDrain` until level 1's
    writes plus failures reach level 0's writes, at most 600 s.
- **A missing level never stops a build.**
  - `Get-BkSccacheConfig` leaves the S3 level out, with a warning, when anything is missing.
  - The driver drops it when the host cannot reach it.
  - `Clear-UnreachableSccacheEndpoint` drops either level inside a RUN (no key, unreachable)
    and takes only that level out of the chain.
- **Client scripts:**
  - `Set-SccacheS3Level.ps1` writes the five `KATAGLYPHIS_SCCACHE_S3_*` user variables; the
    secret is asked without echo.
  - `Copy-SccacheCacheToS3.ps1` seeds the bucket 1:1 from the dufs tree with s5cmd; both backends
    use the key `a/b/c/<hash>`.
  - `Test-HostSetup.ps1` reports the level as unset, half set, reachable or unreachable.
- **Validated end to end the same day.** A BuildKit probe wrote 20 objects to both levels (0
  failures, drained at once), and a fresh S3-only server hit all 20. `Set-SccacheS3Level.ps1`
  now refuses a secret with whitespace and, with s5cmd on PATH, a key the bucket refuses: the
  first attempt had stored the command line as the secret, which only surfaced as
  `Invalid signature`.
- **The server is in the repo:** `linux/sccache-s3/` holds the runbook (WireGuard, Garage v2.4.1
  pinned by digest, the bucket and keys, ufw, the size cap with s5cmd 2.3.0), `garage.toml`, the
  units and the eviction script.
- **Re-key and docs.** The RUN changes re-key every sccache stage once; they compile warm from level 0.
  Docs: `windows-build-resources.md` § Two cache levels, `windows-host-setup.md` § C7, INDEX, AGENTS.md.
- **Tests:** `BuildDriver.SccacheLevels.Tests.ps1`, `SourceBuild.SccacheUploadDrain.Tests.ps1`,
  the S3 cases in `Build.SccacheEndpointProbe.Tests.ps1`, and the fixture's credential rows.

## 2026-10-15 — GStreamer's arm64 cross file keeps the sccache shim and `--target` apart

- **`meson setup` of the arm64 merge stopped at once** with `Unknown compiler(s): [['C:/temp/gst-sccache-shim/clang-cl.exe--target=aarch64-pc-windows-msvc']]`.
  The cross file built its compiler list as `(($env:CC -split '\s+') | Where-Object { $_ }) + @("--target=…")`. Since
  #182 (2026-10-12) `CC` is the one-word shim path, the pipeline yields a plain string, and `+` appended `--target` as
  text. The two-word `sccache clang-cl` had hidden it.
- `Format-MesonExeList` builds all four lists (cross and native, C and C++) through `@()`.
  `Build.GstreamerSccacheShim.Tests.ps1` checks the one-word shim, a padded two-word command and the native form, and
  that every list goes through it. The dupes budget of the script's self-pair falls from 51 to 33.

## 2026-10-15 — PyAV's arm64 wheel links the target's `python315.lib` again; a failing `setup.py` shows its error

- **The arm64 PyAV wheel failed with 207 unresolved Python symbols** (`LNK1120`, `__imp_PyBaseObject_Type` and the rest)
  in the first arm64 chain since CON93. CON93 (2026-10-12) put the host's x64 `python3XY.lib` into `C:\temp\cpython\libs`,
  and setuptools lists that directory first on the link line, ahead of the target's from `LIB`. The free-threaded twin
  already passed the target's `libs\` with `-L`; the GIL build now does the same, and `SourceBuild.FindPythonPrefix.Tests.ps1`
  requires it. The arm64 media-core branch then built in 16:34 min, both PyAV wheels (`cp315`, `cp315t`) included.
- **Every failing wheel build now shows its own output.** `Invoke-PythonWheelBuild` returned the GIL build's log as
  pipeline output, and every caller drops or indexes it, so the failure above read only `exit 1`. The log goes to the
  host now, and a test proves a failing build's line reaches it when the caller drops the result.

## 2026-10-15 — The arm64 target's free-threaded CPython 3.15 drops its byte-identical `python.exe`

- **The first arm64 cross chain on CPython 3.15.0 stopped in media-core** (bk-20261015-102101, phase 6 of the target
  CPython). 3.15's `PCbuild` builds `python.exe` and `pythonw.exe` in `arm64t` and copies each to `python3.15t.exe` and
  `pythonw3.15t.exe` (`CopyFreethreadedBinary`). `Install-CpythonTargetTree` copied `python*.exe`, so the free-threaded
  tree held a `python.exe`, and the gate refused it.
- The staging now drops `python.exe` and `pythonw.exe` from the free-threaded tree when each is byte-identical to its
  `X.Yt` twin. A `python.exe` with other bytes still trips the gate, as `SourceBuild.TargetCpythonTree.Tests.ps1`'s
  refusal row asserts; a new row covers the duplicate (14 of 14 pass). The amd64 host's free-threaded tree was never
  affected, since `PC\layout` writes only the `X.Yt` names.

## 2026-10-14 — `CUDA_INSTALLER_SHA256` names the network installer again; `spec_cuda` checks NVIDIA's MD5

- **The CUDA 13.4.3 bump below pinned the wrong file.** `spec_cuda` hashed the ~4 GB full installer
  (`local_installers/cuda_13.4.3_windows_x86_64.exe`, `35296d52…`), but `Install-Cuda.ps1` has downloaded the network
  installer since 13.4, because the full one dies in-container with `0xE0E00064`. The nvidia chain of 2026-10-14
  refused it after 54 s (`SHA256 mismatch … got C4F4DCDE…`); the CPU chain before it was green.
- The pin is `c4f4dcde…`, the SHA256 of `network_installers/cuda_13.4.3_windows_x86_64_network.exe` (9 476 200 B),
  whose MD5 `d6b30212…` is the one NVIDIA lists in `docs/sidebar/md5sum.txt`. That is the provenance `versions.env`
  states for this key.
- `spec_cuda` now goes through `cuda_network_installer_sha256`: it hashes the network installer and refuses a pin
  whose MD5 is not NVIDIA's. `test-bump-versions.sh` covers it offline (the network URL is the hashed one, the full
  installer never is, a wrong MD5 raises): 105 of 105 pass in `:latest`.

## 2026-10-14 — Both host fixes measured in the from-base chain; `Install-NewHost` sets `TcpTimedWaitDelay`

- **The fork shim `04a9bdaa` works.** In `bk-20261014-cpu` every RUN without an sccache server reached DONE
  0.9 to 3.3 s after its last output line, Visual Studio's install included (199.9 s of output, `DONE 202.3s`).
  `windows-host-setup.md` § R1 and the recurrence playbook in `failure-modes.md` record the timing signatures.
- **#179 is cut to ~30 s by the host's `TcpTimedWaitDelay` = 30 s.** The sccache RUNs (ONNX Runtime 1.31, FFmpeg)
  reached DONE 29.9 s and 30.2 s after their last line, against 114 to 124 s in the chains of 2026-10-10/11. That
  is about 90 s per sccache RUN, 12 to 21 min per chain. The patched sccache stays the option for the remaining 30 s.
- `Install-NewHost.ps1` sets the value as step 5 (`-TcpTimedWaitDelay`, default 30, `-SkipTcpTimeWait`) and says
  when a reboot is due. `Get-TcpTimeWaitChange` decides and is tested (`NewHost.TcpTimeWait.Tests.ps1`).
  `Test-HostSetup.ps1` warns on any other value. The new `windows-host-setup.md` § C6 has the manual recipe.
- AGENTS.md § Stevedore Fixes After Install names both fixes, where they are scripted, and the tails that tell
  them apart.

## 2026-10-14 — The hcsshim fork takes upstream main: `Install-NewHost` builds `04a9bdaa`

- **`Kataglyphis/hcsshim@feature/configurable-teardown-timeout` merges upstream `main` `bd97a054`** (16 commits:
  go-winio v0.6.4, containerd v2.3.6, grpc 1.84.0 and others). A merge, not a rebase, so the branch moved without a
  force-push; the fork's `main` is synced to the same commit. Upstream did not touch `cmd/containerd-shim-runhcs-v1/`
  in between, so the patch is unchanged and #2855 stays open, unreviewed.
- `Install-NewHost.ps1` pins `$forkPin = 04a9bdaa…`. Verified on Go 1.27.2: `gofmt -l` and `go vet` clean, the shim
  package's tests pass (`Test_resolveTeardownTimeouts`, 7 cases). The build is 25 971 200 B, sha256 `8C9ECBA3…`,
  in `out\shim-builds\containerd-shim-runhcs-v1-fork-04a9bdaa.exe`, deployed like the last one:
  `Publish-ShimPatch.ps1 -ShimPath <it> -ServiceEnvironment CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m`.

## 2026-10-14 — Every pin at its newest: uv 0.13.1, ollama 0.40.4, Chrome 155.0.8059.79, Renovate 44.157.0

- `bump_versions.py --write`, the safe tier: `UV_VERSION` 0.13.0 -> 0.13.1 with the amd64, arm64, riscv64 and Windows
  arm64 archive SHA256s; `OLLAMA_VERSION` 0.40.3 -> 0.40.4 with both arches'; `CHROME_FOR_TESTING_VERSION`
  155.0.8059.39 -> 155.0.8059.79 with Chrome's and chromedriver's for both arches. DocumANTation's Dockerfile
  mirrors the uv pin (its `ca062a0`), so its gitlink moves too.
- `RENOVATE_VERSION` 44.155.2 -> 44.157.0, npm's latest; Node stays at 24.21.0, the newest 24.x.
- Still held, each for its stated reason: `PROTOC_VERSION` 36.1 (slaved to LiteRT-LM v0.18.0's `protobuf.cmake`, the
  newest LiteRT-LM release), GenAI v0.17.0 (the newest GitHub tag; 0.18.0 is on PyPI only, and the chain builds from
  the tag).

## 2026-10-14 — CUDA 13.4.3 and llama.cpp b11617 for the GPU variants

- `CUDA_VERSION` 13.4.2 -> 13.4.3 for the nvidia variants (Linux and Windows), through `bump_versions.py`'s own
  `spec_cuda`: the Windows installer's SHA256 from a download, and the arm64 redist components re-read from
  `redistrib_13.4.3.json`, where only cuSOLVER moved (12.3.4.7 -> 12.3.5.3).
- `LLAMA_CPP_HIP_BUILD` 11583 -> 11617 for the rocm variant (`spec_llama_cpp_hip`): the tag's commit, the source
  archive and the CPU and Vulkan release assets re-hashed; the licence is unchanged.
- Both report-tier keys were written alone; `--write-all` would also have taken the safe tier's uv, ollama and
  Chrome bumps, which wait. `sync_versions.py` carried the values into the nvidia and rocm-llama Dockerfiles' ARG
  defaults, the README and the licence pages.

## 2026-10-14 — The Windows base re-key: vswhere's selector, PowerShell 7.6.7, the October servercore

- **The next Windows chain rebuilds from `Dockerfile.base`, so the base items ride it together** (CON89):
  - `WindowsScripts.Shared.psm1`'s vswhere selector is `@(if (-not $All) { '-latest' })`. The old
    `if ($All) { @() } else { @('-latest') }` unrolled to a string and splatted vswhere `- l a t e s t`, so every chain
    logged `vswhere returned no installation; using filesystem fallback`. `Lint.ScalarSplat.Tests.ps1` no longer allows
    the site.
  - PowerShell 7.6.6 -> 7.6.7 (`PWSH_VERSION`, released 2026-10-13). `PWSH_ZIP_SHA256` is GitHub's asset digest for
    `PowerShell-7.6.7-win-x64.zip`, `d2f952eb...`, which a download hashed to the same value.
  - `WINDOWS_BASE_DIGEST` -> `sha256:1d3cd3d0...`, MCR's `servercore:ltsc2025` manifest list on 2026-10-14. The pin
    moves only with a from-base rebuild, which this is.
- `Dockerfile.base` COPYs the module before the VS install, so any of the three re-keys the base. Measured on the last
  chain (`bk-con91-cpu-6`, base from cache): C: fell from 89.2 to 48.9 GB free, so a from-base chain wants clearly more
  headroom than that before it starts.

## 2026-10-14 — sqlite3's web wasm 3.7.1, and WebDavClient's lock maintenance

- `SQLITE3_WASM_VERSION` 3.7.0 -> 3.7.1 with its SHA256 (`87c1869b...`, the `sqlite3-3.7.1` release's
  `sqlite3.wasm`). The day's lock maintenance moved the `sqlite3` Dart package to 3.7.1 in OmniAccelerANT and
  jotrockenmitlocken, and OmniAccelerANT's `pinned_artefacts_test.dart` requires the committed `web/sqlite3.wasm`, this
  pin and the lock to move together.
- `WEBDAVCLIENT_REF` -> `a53b013e`, its uv.lock maintenance (more-itertools 11.2.0, ty 0.0.87).

## 2026-10-14 — A census of what the Windows image holds

- `windows-image-census-probe.yml` (dispatch only) pulls `:winamd64` on `windows-2025` and prints two tables. The first
  is `docker history`'s on-disk size per layer. The second lists every directory of 150 MB or more, five levels deep,
  with its file count, from one pass inside the container. Those are the bytes and files hcsshim imports serially on
  every pull, about 14 of a Windows job's 16 prologue minutes since `cleanup: hide`. It is the measurement behind
  slimming the image.

## 2026-10-14 — The Linux app bundle runs the Python its wheels were built for

- **`python-app-bundle.sh` installs the version of the image's `python3`, not `versions.env`'s pin.** Since CON90 moved
  the pin to 3.15.0, OrchestrANT's Linux lanes had failed every run (x64 and arm64 since run 38265793839, 2026-10-12):
  `uv python install 3.15.0` found no download in the published image's uv 0.12.23, and the wheels it would have
  installed were cp314, built by that image's 3.14.8. The pin runs ahead of the published images during an upgrade,
  so the interpreter that built the wheels decides; the pin is the fallback when no `python3` runs. The Windows bundle
  already used the image's own CPython. Suite `test-python-free-threaded-wheel.sh` (in WSL: 62 passed) and mutation
  `python.app-bundle.runtime-follows-the-image`.

## 2026-10-14 — Renovate preset: the Flutter SDK's Gradle plugin loader is never looked up (CON84)

- `default.json` disables `dev.flutter.flutter-plugin-loader` for the `gradle` manager. An Android app's
  `settings.gradle.kts` includes it from the Flutter SDK, no Maven repository serves it, and every lookup failed.
  OmniAccelerANT carried the rule alone; jotrockenmitlocken includes the same plugin and now gets it too. That was
  CON84's item (3).

## 2026-10-14 — Workflow conventions: every hub job is bounded, `job-timeout` is armed here

- `python-ci-windows.yml`'s container build job, the hub's last job without a bound, takes `timeout-minutes` (default
  150). OrchestrANT's ran 39-61 min over its last nine finished runs.
- `preflight.sh` arms `job-timeout` beside `permissions`, so a hub job added without `timeout-minutes` is red the day
  it lands. The hub's census row for it is gone.
- BeschleunigerBallett's two census rows are gone too. Its 64834207 bounds `clang-tests` (150 min), `gcc` (90) and
  `pester-tests` (15) from their last five runs, and fails an empty Linux package upload. The gate reads 0 findings
  there.

## 2026-10-14 — CI prologue: Windows deletes nothing by default, it only hides the cleanup's directories from PATH

- **`prepare-windows-container-host` defaults to `cleanup: hide`.** No directory is deleted. Every `PATH` entry under
  one that `cleanup-disk-space` deletes leaves `PATH` for the job's later steps (`mode: hide`, `Hide-CleanupRoots.ps1`,
  through `GITHUB_ENV`). A host step that runs a built binary still finds no DLL there that the product failed to
  bundle, the reason the cleanup could not simply go. `after-pull`, `before` and `off` stay selectable; `off` is for a
  job that builds on the host. `free-disk-space: 'false'` still means `off`.
- **Why:** `after-pull` (yesterday's default) slowed the container builds it ran beside by 23-54 %. OxidANT x64 went
  1087 → 1334 s, AccelerANTgine x64 1420 → 1682 s and its arm64 cross 1001 → 1546 s. Probe run 38473550649, from the
  prologue to the end of the container work:
  - `before` 2400 s (cleanup 672 s);
  - `after-pull` 2259 s (waited 387 s), at idle priority 2060 s;
  - no cleanup 1718 s, about 11.4 min less than `before`.
  - With no cleanup, C: stayed at 28.87 GB free or more: the image, the container's scratch layer and the mounted
    tree are on D:.
- `cleanup-disk-space` keeps its removal roots in two lists, `$removeFirst` and `$removeLast`. The deletions and `hide`
  both read them, in the same order as before. Suite `DiskCleanup.Hide.Tests.ps1` covers wildcard roots, a sibling
  sharing a root's prefix, an unexpanded `%VAR%` entry and a missing `GITHUB_ENV`. The deep Windows job of
  `actions-selftest.yml` checks the default on a real runner: the tool cache is still on disk and none of its entries
  is on `PATH`.
- That job never ran before: deep is off by default, and its first dispatch (run 38486829937) stopped at the
  local action, because the job checked nothing out first. It now checks out first, as its Linux twin does.
- **`run-in-windows-container`'s `command` reaches the container base64-encoded (`-EncodedCommand`).** The image's
  `entrypoint.cmd` runs `%*`, so cmd re-parsed the text: a multi-line command ran only its first line and exited 0
  (job 115392832215), and the selftest's failed at a brace (`\" } was unexpected at this time.`, job 115605163947).
  Base64 has no character cmd reads. A command over ~2,600 characters now fails with a pointer to `file`, which
  never had the problem.

## 2026-10-13 — CI prologue: the Windows cleanup moves behind the pull, the Linux pull starts first

- **Windows: `prepare-windows-container-host` runs `cleanup-disk-space` after the pull, in the background** (input
  `cleanup`, default `after-pull`; `before` is the old order, `off` none). `run-in-windows-container` waits for it after
  its container run, so host steps after that see the cleaned C: as before. Measured on `windows-2025` with
  `ci-host-speed-probe.yml`, prologue before the container step:
  - run 38425248553: `before` 1761 s (cleanup 786, pull 932), `after-pull` 974 s, `off` 927 s;
  - run 38455306377: `before` 1630 s (cleanup 652, pull 927), `after-pull` 1043 s, `off` 1183 s (a 1137 s pull).
  - So 9.8-13.1 min off every Windows container job and its workflow's critical path.
- **The pull never needed the cleanup.** With no cleanup, C: stayed at 31.71-31.92 GB free through the whole pull
  while D: carried the staging (`D:\docker\tmp`, up to 49 entries). A `SystemTemp` for the docker service on D: changed
  nothing (904 and 920 s pulls against 874 s), so `set-docker-data-root` has no input for it.
- **The background cleanup is detached through WMI.** A `Start-Process` child with redirected output died seconds after
  its step ended (run 38455303000, and the first probe's job 115392832642); the WMI one finished its 552 s cleanup and
  the wait found its marker. Beside a fixed container workload it cost nothing measurable: 43 s against 46 s with no
  cleanup. If WMI fails, the cleanup runs in the foreground with a warning.
- **`off` is not the default**: without the cleanup, the runner's own toolchains stay on `PATH`, and host steps that run
  built binaries with the inherited `PATH` (OmniAccelerANT's `Test-LaunchSmoke.ps1`, AccelerANTgine's
  `Start-Windows.ps1`) could load a DLL the product failed to bundle.
- **Linux: `prepare-linux-ci-host` logs in, starts the pull in the background and runs the cleanup and the checkout
  beside it** (`pull-first`, default `'true'`), and the cleanup keeps its quick part (`free-disk-space`, default
  `fast`: .NET, Haskell, swap; `'true'` is the full set). Run 38425248553: `ubuntu-26.04` 444 → 311 s (58.1 GB free
  after the pull, against 78.4 with the full set), `ubuntu-26.04-arm` 323 → 229 s (85.6 GB free).
- **The riscv64 lanes keep the full cleanup**: `container-ci-riscv64.yml` under `sysroot-mode: export` and
  `python-ci-linux.yml`'s riscv64 row pull the riscv64 child as a second image after the prologue.
- `python-ci-windows.yml` no longer walks the data-root after the pull (`measure-data-root`, 22-26 s per job).
- `cleanup-disk-space` takes `mode: foreground | background | wait` (`Wait-DiskCleanup.ps1`, suite
  `DiskCleanup.Wait.Tests.ps1`); both prepare actions report `pull-seconds`, the Linux one `cleanup-seconds` too.
  `Invoke-Lint.ps1`'s default scope takes `.github/actions`. Docs:
  [`windows-container-build-performance.md` § The prologue on hosted runners](docs/windows-container-build-performance.md#the-prologue-on-hosted-runners).
- Found on the way: a multi-line `command:` to `run-in-windows-container` reached the container's pwsh as its first line
  only and exited 0 (job 115392832215). The probe uses `file:`; the action is unchanged.

## 2026-10-13 — CI: riscv64 cross jobs build the sysroot with skopeo by default

- **`sysroot-mode` defaults to `skopeo`** in `setup-riscv64-cross` and `container-ci-riscv64.yml`, so the cross lanes
  of OxidANT, AccelerANTgine and BeschleunigerBallett take it on their next run, BeschleunigerBallett's weekly GPU
  shards included. `sysroot-mode: export` brings the old path back. `python-ci-linux.yml` still passes `export`.
- **Measured** with `riscv64-sysroot-probe.yml`, binfmt registration included:
  - Run 38455969715 at 24 parallel blobs: export took 357 s and skopeo 78 s (a 39 s copy, then a 32 s extract).
  - Run 38426729036 at skopeo's default of six: export took 415 s and skopeo 155 s.
  - Both runs: identical trees of 32791 entries, and the C, C++, GStreamer and Rust smoke passed on each.
  - Before the switch, the lanes' step had a median of 354-373 s, so about 4.6 min come off every riscv64 cross job.
- **The first lane runs after the switch**, dispatched together, all tests green: OxidANT 38458259151 took 110 s,
  AccelerANTgine 38458264112 96 s and BeschleunigerBallett 38458268864 111 s for the step, against medians of 366,
  354 and 373 s. That is about 4.3 min off each job.

## 2026-10-13 — From the next chain on, the arm64 and riscv64 images drop the x86_64 host payload (CON96)

- **3.41 GB of each foreign child goes.** The published `:latest` of 2026-10-11 ships three layers in its arm64
  and riscv64 children that are byte-identical to amd64's (manifests `448591ff…`, `7689579f…`):
  - `/opt/android-sdk`, 1 816 MB compressed. `adb`, `aapt2` and the NDK's only prebuilt toolchain are linux-x86_64.
  - `/opt/android`, 850 MB. These libraries link only through that NDK.
  - `/usr/local/rustup`, 745 MB. It is the cross builder's x86_64 toolchain, and `ensure_native_rust_toolchain`
    deleted it again one layer later.

  The Android lane runs on amd64 only.
- **`prune-host-payload.sh`** runs in `Dockerfile.package`'s `artifact-source`, before the four COPYs, as the Vulkan
  prune does. With `HOST_PAYLOAD=off` it empties the SDK and `/opt/android`, and writes
  `/opt/android/.android-payload-off`, which `smoke-android.sh`, the emulator installer and the contract gate already
  read. It also empties a Rust toolchain that is not the target's, and `/usr/local/cargo` but its registry, by
  `ensure_native_rust_toolchain`'s own rule, so no shipped file changes there. Every directory stays, so the COPYs, the
  manifest and the ARCH-PARITY table are unchanged.
- **The ENV follows the payload.** `ANDROID_HOME`, `ANDROID_SDK_ROOT` and the six Android root variables are empty where
  `HOST_PAYLOAD=off`, and `PATH` gains no Android entry there, the way `CHROME_EXECUTABLE` is empty on riscv64.
  `ANDROID_TARGET_ABI` stays, since it names an ABI, not a path. Checked in Rancher's BuildKit with the
  `dockerfile:1.28.0` frontend: `on` gives the old values and the old `PATH` byte for byte, `off` gives empty values.
- **One switch, the old shape one step away.** `runtime_host_payload` passes `HOST_PAYLOAD` per arch. It is `on` for
  the arches in `HOST_PAYLOAD_ARCHES` (default `amd64`). It is `off` for the rest, and for any artifact that no amd64
  host built, which has no SDK anyway. On the amd64-hosted cross chain, `HOST_PAYLOAD_ARCHES=amd64,arm64,riscv64`
  rebuilds the images as published until now; a native or arm64-hosted chain gets empty
  Android variables either way, where it used to set them over an empty SDK. The chain and both runtime orchestrators refuse a bad list with exit 2. A manual `docker build` without the arg
  keeps the old shape. A native arm64 or riscv64 chain keeps its own Rust toolchain.
- **Gates.** The contract row `android-home` still skips a payload-off image, and now fails one that sets
  `ANDROID_HOME` or `ANDROID_SDK_ROOT` anyway. `check_android_abi` skips a payload-off image, and fails one whose
  `/opt/android` still holds objects. `test-host-payload.sh` covers the prune on fixture trees, its place in the
  Dockerfile, the eight variables and the resolver. Ten new mutation entries bite, and so do the three
  `android-env.*` entries rewritten for the new lines.
- **Measured locally.** The script ran over the real trees in the amd64 `:latest`, for an arm64 target. It emptied
  2 193 MB of rustup, 230 MB of cargo, 8 167 MB of SDK (with the emulator, which only amd64 installs) and 3 490 MB of
  `/opt/android` in 9.6 s. A second run changed nothing, and a bad `HOST_PAYLOAD` exited 1.
- **Left for the next chain** (BACKLOG CON96): the arm64 and riscv64 children published without the three layers, the
  package-stage log lines in `build-watch-list.md`, and the arm64 pull time against the 4.19 min median.
- **Review follow-ups.** `check_android_abi` now fails an amd64 image whose payload is off, since the Android lane
  builds only there; before, every gate skipped it. `prune-host-payload.sh` refuses an empty `HOST_PAYLOAD`, which
  `Dockerfile.package` would have read as off for the ENV lines while the prune kept the trees.

## 2026-10-13 — CI: the riscv64 sysroot from the registry (`sysroot-mode: skopeo`), export kept

- **Why.** Every riscv64 cross job (OxidANT, AccelerANTgine, BeschleunigerBallett) pulled the whole riscv64 child
  (8.51 GB, 72 layers) after the amd64 image, only to pipe `docker export` through `tar` for the 5 GB sysroot. The
  `Set up riscv64 cross testing` step took a median of 366 s (OxidANT), 354 s (AccelerANTgine) and 373 s
  (BeschleunigerBallett) over each repo's last six runs.
- **`riscv64-sysroot.sh --mode skopeo`.** It fetches the child's layer blobs with the runner's skopeo, pinned to the
  `linux/riscv64` digest of the index the amd64 image was pulled from. The new `oci-layers-extract.py` then applies them
  in order with OCI whiteouts and opaque directories, decompressing one layer per process and keeping only
  `RISCV64_SYSROOT_PATHS`. On the riscv64 base layer it wrote the same tree as GNU tar, mode for mode and byte for byte.
  It refuses `..` members and never writes through a symlink.
- **The switch.** `setup-riscv64-cross` and `container-ci-riscv64.yml` take `sysroot-mode` (`export` or `skopeo`).
  The default stays `export` until the probe below has measured both. `python-ci-linux.yml` passes `export`, because its
  riscv64 row runs the riscv64 image afterwards and reuses export's pull.
- **The probe.** `riscv64-sysroot-probe.yml` (dispatch only) builds the sysroot both ways on fresh runners, times them,
  diffs the trees with `tree-manifest.py` and runs `riscv64-cross-smoke.sh` (C, C++, a GStreamer link, Rust under QEMU)
  against each.
- **First probe, run 38426729036.** The two trees were identical: 32791 entries, with the same types, modes, sizes,
  link counts, file mtimes, link targets and bytes. The smoke passed on both. The sysroot took 406 s by export (a
  250 s pull, then 154 s of export and tar) and 143 s by skopeo (a 99 s copy, then a 41 s extract).
- **skopeo copies 24 blobs at once** (`--image-parallel-copies`, when the skopeo has it). Its default of six held the
  2.36 GB layer back until 34 s into the copy.
- Suite `test-oci-layers-extract.sh`, ten mutations in the `riscv64-cross` family.
  `docs/riscv64-cross-test-lanes.md` § *The sysroot from the registry (skopeo)*.

## 2026-10-13 — Pins: Renovate's 2026-10-13 app bumps (Flutter 3.47.7, Ollama 0.40.3, llama.cpp b11583, TensorRT 11.4.0.106, …)

- **Flutter 3.47.6 → 3.47.7.** `FLUTTER_SDK_SHA256` measured by full download of the Linux tarball (1,578,092,224 B),
  equal to `releases_linux.json`, which names 3.47.7 the current stable. The Windows zip that scoop installs is in
  `releases_windows.json`, and the Extras bucket's manifest carries the same URL and hash.
- **Ollama 0.40.0 → 0.40.3.** `OLLAMA_AMD64_SHA256` and `OLLAMA_ARM64_SHA256` measured by full download of both
  `.tar.zst`, equal to the release's `sha256sum.txt` and to GitHub's asset digests. 0.40.4-rc1 is a pre-release.
- **llama.cpp b11476 → b11583** (Windows rocm lane). It is the newest build that publishes both the win-cpu-x64 and the
  win-vulkan-x64 zip; Renovate already sees the tags b11584 and b11586, which have no release yet. The whole
  `LLAMA_CPP_*` set moves:
  - `_COMMIT` is the lightweight tag's commit; `git ls-remote` and the API agree.
  - `_SOURCE_SHA256` is equal over two full downloads (github.com's archive and codeload), and the tarball's pax
    header names that commit.
  - `_CPU_SHA256` and `_VULKAN_SHA256` are measured by full download, equal to GitHub's digests. The LICENSE is
    byte-identical.
  - Both zips list the 51 files of the b11472 test fixture. The Vulkan zip adds `ggml-vulkan.dll`, at the same CRC32s.
  - At b11583, release.yml still builds `windows-rocm` against TheRock 10.0.0, and every CMake option the `ggml-hip`
    build passes still exists. `windows-rocm.md` follows.
- **freetype 2.14.3 → 2.15.0** (OpenCV's cross fallback). The key stays dotted: `install-deps.sh` derives the tag
  `VER-2-15-0` from it, and its fallback default moves too. The tag sits at the same commit on the GitHub mirror and on
  gitlab.freedesktop.org, and savannah publishes `freetype-2.15.0`. The annotation needs no `extractVersion`, because
  its `versioning=regex` reads `2.15.0` and `VER-2-15-0` as one version. A Renovate report over the new file no longer
  lists freetype. Every `FT_DISABLE_*` option the fallback passes still exists in 2.15.0.
- **DXC v1.9.2607 → v1.9.2609** for the ORT WebGPU EP (rocm lane). `ORT_WEBGPU_WINDOWS_DXC_ASSET` becomes
  `dxc_2026_09_29.zip`, and `_SHA256` is measured by full download, equal to GitHub's digest. The zip still carries the
  six members `Expand-OrtWebGpuDxc` takes, and `Rocm.OrtWebGpu.Tests.ps1` asserts the new asset name. v1.10.2605.37 is a
  pre-release.
- **TensorRT 11.3.0.99 → 11.4.0.106.** NVIDIA's ubuntu2604 apt repo builds it for cuda13.4 on x86_64 and sbsa, so
  `tensorrt-dev=11.4.0.106*` resolves against the pinned CUDA 13.4.2, and CUDA stays.
  - `TENSORRT_ZIP_SHA256` named the 11.2.1.2 zip until now. It now pins
    `TensorRT-Enterprise-11.4.0.106-Windows-amd64-cuda-13.4-Release-external.zip` (1,984,616,374 B).
  - That zip was downloaded in full from NVIDIA's CDN, which served it without a login. Its top directory is
    `TensorRT-11.4.0.106`, and its S3 multipart ETag, recomputed from the bytes, equals the CDN's.
  - DeepStream's private TensorRT stays at 10.16.1.11 for CUDA 13.2. It is still the newest TensorRT 10 that NVIDIA
    builds, and DeepStream 9.1.0 is still the newest release.
- `sync_versions.py` and `generate_sbom.py` regenerated the derived files. Not in this batch: ONNX Runtime, LiteRT and
  `WEBDAVCLIENT_REF`.

## 2026-10-13 — ONNX Runtime v1.31.0 in source, with the GenAI and DXC changes it needs (CON95)

- **ONNX Runtime v1.30.0 → v1.31.0** (`ONNXRUNTIME_VERSION`). `sync_versions.py --write` moved the four Dockerfile
  ARGs, the three Windows build-script defaults, README, overview, the licence tables and the SBOM. The free-threaded
  twin row moves to v1.31.0 after a re-read: `onnxruntime_pybind_module.cc` still passes `py::mod_gil_not_used()`
  under `Py_GIL_DISABLED`, and pybind11 is still v3.0.2.
- **Dawn v20260818.211311 → v20260916.214021** for the rocm WebGPU spike, the tag v1.31.0's `cmake/deps.txt` names.
  `ORT_WEBGPU_WINDOWS_DAWN_SHA256` is `507949fd…`, measured by a full download; its SHA1 equals deps.txt's
  `514e914f…`. ORT's six Dawn patches apply to it in order with GNU patch (five with fuzz), and the prebuilt-DXC
  block `Invoke-DawnPrebuiltDxcPatch` rewrites is unchanged.
- **The spike ships `dxcompiler.dll` alone.** That Dawn creates the DXIL validator from `dxcompiler.dll` and loads
  nothing else, and v1.31.0's CMake no longer copies or depends on `dxil.dll`. The build stages and hashes only
  `dxcompiler.dll`, and the marker drops `DXIL_SHA256`. The wheel gate and `rocm-checks\OrtWebGpu.ps1` fail on a
  leftover `dxil.dll`. The `copy_dxil_dll` target goes from the Dawn patch, because the new Dawn no longer depends on
  it. The licence rows now name `dxcompiler.dll` only.
- **GenAI v0.17.0 does not compile against v1.31.0, so it carries a patch.** ORT moved the thirteen model-package
  entries GenAI resolves out of the experimental header into the stable `OrtModelPackageApi` table. GenAI's
  `onnxruntime_api.h` still names the removed `OrtExperimental_*_SinceV28_Fn` typedefs: 64 GCC errors.
  `linux/scripts/patches/onnxruntime-genai/002-ort-1.31-model-package-api.patch` takes the types and pointers from
  the stable table when `ORT_API_VERSION >= 31`, and keeps the experimental path below that. `60-build-genai.sh`
  applies it on every arch. `Build-OnnxGenaiFromSource.ps1` applies the same file, mounted per file into the GenAI
  RUN. A syntax-only compile of the header in `:latest` covered GCC 16 and clang, ORT v1.30.0 and v1.31.0 headers,
  pristine and patched: pristine fails only against v1.31.0, and patched passes all four. GenAI `main` and the
  untagged `rel-0.17.1` still carry the old code. The patch registers are `upstreamable-patches.md` entry 23 and a
  row in `upstream-windows-patches.md`.
- **The GCC 16 epilogue patch goes.** v1.31.0's `moe_gemm_tma_ws_launcher.inl:535` carries upstream's own
  `std::remove_reference_t` fix. With the patch go its apply step in `build-onnxruntime.sh` and the patches mount of
  the ORT GPU RUN, so `Dockerfile.media`'s size budget drops from 880 to 879.
- **Checked against v1.31.0's sources, unchanged:** every `build.py` flag the native, nvidia, amd, wasm and android
  builds pass, and every CMake define of the Windows raw-CMake build. The five Windows ORT patches and the android AGP
  patch apply. KleidiAI v1.30.0 (SHA1 `36aebdd5…`, measured) has one `enable_language(ASM_MARMASM)` and no rule of its
  own, so the arm64 rule patch holds. Telemetry stays off: 1DS is now the default backend, but `--no_telemetry` and
  the raw-CMake default still disable it. onnx 1.22.0, protobuf 33.6, flatbuffers 23.5.26 and pybind11 v3.0.2 do not
  move. The agility SDK, google_benchmark and coremltools move, but the hub builds none of them.
- **Not proven:** anything only a chain build shows. CON95 lists it.

## 2026-10-13 — LiteRT v2.2.0 → v2.3.0 on every lane, and the cp315 wheel builds again

- **The pins.** `LITERT_VERSION` v2.3.0 (released 2026-10-07). `LITERT_WINDOWS_SOURCE_COMMIT` 4352e261 is the commit the
  tag names (GitHub API). Its `.bazelversion` is still 7.7.0, so the bazel pin stays; that SHA256 equals GitHub's asset
  digest. The accelerator wheel is PyPI's `ai_edge_litert-2.3.0-cp314-cp314-win_amd64.whl`. Its SHA256 was measured by
  full download and equals PyPI's digest. Its `libLiteRtWebGpuAccelerator.dll` (`1cf8b23c…`) is byte-identical to the
  cp313 wheel's and still imports only system DLLs. The Dockerfile ARG defaults, the Windows script fallbacks, the
  licence pages and the SBOM follow through `sync_versions.py`. `build-litert.sh`'s stale v2.1.6 default moves too.
- **v2.3.0 moved its Python rules, and the wheel build needed patch `003`.** LiteRT now declares its own externals:
  rules_python 2.2.0, absl 20260526.0 and protobuf 6.31.1, no longer TF's. rules_python 2.2.0 takes `base_urls`, but
  rules_ml_toolchain still passes `base_url = ""` when `HERMETIC_PYTHON_URL` is set, so the first probe stopped at the
  WORKSPACE. `003-rules-ml-toolchain-base-urls.patch` gives rules_ml_toolchain a patch that drops that argument, through
  LiteRT's own `litert_workspace.bzl`. A URL with `://` is used as given, so `base_urls` is not needed. Patches `001` and
  `002` were regenerated against v2.3.0 (`002` had moved one line). Every external rewrite still finds its anchor, and
  TF 5c0b7a59 still defines `x64_windows-clang-cl`.
- **Proven in a probe** (`probe-litert-230`, the P12 shape, on the 3.15 toolchain image). It built
  `ai_edge_litert-2.3.0-cp315-cp315-win_amd64.whl` from 5655 bazel actions in 390 s. All 4545 compile, link and archive
  actions ran clang-cl, lld-link or llvm-lib. The wheel passed its contract and `LITERT-WHEEL-SMOKE PASS`. The RUN took
  799 s and peaked at 6.2 GB.
- **The patch-drift gate covers LiteRT.** `Test-PatchesApplyClean.ps1` had no `litert` mapping, so CI's `patch-drift`
  job failed on `001` and `002` from CON91 on. It now clones `LITERT_VERSION`, and it no longer asks to check out a file
  that a patch creates. All 23 patches apply, by both `git apply` and GNU patch.
- **Linux and Android needed two fixes, both in `build-litert.sh` and the Android build.**
  - v2.3.0 tracks `tensorflow/lite/tools/BUILD` (a bazel alias), so a real `tensorflow/lite` directory stood where the
    hub links `tflite/`. `ln -snf` then created `tensorflow/lite/tflite`, and tflite's C API configure found no
    `CMakeLists.txt`. `_litert_link_tensorflow_lite` replaces a directory that holds only bazel files with the link and
    refuses one that holds sources. The C API build and the pip wheel step both use it.
  - `tensor/CMakeLists.txt` adds every example it finds, and the gemma3 one fetches sentencepiece v0.2.0, whose
    `sentencepiece_processor.h` lacks `<cstdint>` under clang (`unknown type name 'uint32_t'`). It broke v2.2.0's tree
    in today's image too. `litert_prune_tensor_examples` (`android/litert-tensor-examples.sh`, sourced by both lanes)
    removes `tensor/examples` before configure; no image ships those demos. `test-litert-tensor-examples.sh` covers it.
  - Proven in `:latest` on amd64 with the media stage's `install-deps.sh` and `build-litert.sh` at v2.3.0 (4352e261,
    with the image's own `LITERT_VERSION=v2.2.0` overridden): 1306 s, `libLiteRt.so`, `libLiteRtDispatch_Arm.so`,
    `libLiteRtDispatch_GoogleTensor.so`, `libtensorflowlite_c.so` and `ai_edge_litert-2.3.0` built. The Android NDK
    build and the arm64/riscv64 cross builds still wait for the chain.
  - The pip-script patch still applies, and the pip script is unchanged. tflite's vendored protobuf is still `90b73ac3`, so `LITERT_TFLITE_PROTOC_VERSION` stays 21.9. The QAIRT
  anchor is still there, and the LiteCore default URL is still the 404 one that the Android lane replaces. v2.3.0 adds an
  Arm dispatch plugin that needs only LiteRT's own headers. It also adds SafeInt (a commit-pinned fetch) and
  `find_package(Eigen3)`, which tflite's `FindEigen3.cmake` serves.
- **Smaller fits.** `TFLITE_ENABLE_LABEL_IMAGE` is gone from tflite's CMake, so the Windows build no longer passes it.
  The free-threaded twin row is re-read at v2.3.0: none of the wheel's 13 extension modules passes
  `py::mod_gil_not_used()`; only `_pywrap_converter_api` does, and the wheel does not ship it. The wheel target now names
  LiteRT's LICENSE, PyPI's 2.3.0 wheel carries it in its dist-info, and the licence row says so. XNNPACK `d89ef666`
  still forces KleidiAI off on Windows.

## 2026-10-13 — Pins: Renovate's 2026-10-13 tool bumps (ruff 0.17.0, Renovate 44.155.2, Node 26.11.1, pandoc 3.12.1, …)

- **Node 26.11.0 → 26.11.1** (same major). `NODE_AMD64_SHA256` and `NODE_ARM64_SHA256` measured by full download of
  both `.tar.xz`, equal to nodejs.org's `SHASUMS256.txt`. Its clearsigned copy verifies against release key
  `5BE8A3F6…B168D356`, which nodejs/node's README lists. `node --version` ran from the measured x64 bytes in
  `:latest`; the arm64 `node` is ELF aarch64.
- **pandoc 3.12 → 3.12.1.** `PANDOC_SHA256_AMD64/ARM64` measured by full download, equal to GitHub's asset digests.
  `pandoc --version` ran from the measured amd64 `.deb` in `:latest`. DocumANTation's Dockerfile ARGs follow through
  `sync_versions.py` (gitlink 3736dd5 → cb6809f), and its 23 real-pandoc filter tests pass on 3.12.1.
- **ruff 0.16.10 → 0.17.0** (`tool-pins.env`). The gate pass (`E9,F63,F7,F82`) is clean on all 122 files. 0.17.0 now
  prints unsafe fixes in the advisory pass, which does not grade. OrchestrANT, WebDavClient and DocumANTation repeat
  the pin, so their `consumer pins` gate fails until each follows.
- **Renovate 44.144.1 → 44.155.2**, one patch past the report's 44.155.1, published after it. `engines.node` is still
  `^24.11.0` (npm registry), so `RENOVATE_NODE_VERSION` stays at 24.21.0, the newest 24.x. 44.155.2 ran on that Node
  in `:latest` over this tree: every detected manager reports nothing behind, and `custom.regex` lists only keys other
  batches own.
- **cargo-c 0.10.25 → 0.10.26** (crates.io's `0.10.26+cargo-0.100.0`, MSRV 1.97). `cargo install --locked --version
  0.10.26 cargo-c` built it in `:latest` with Rust 1.99.0.
- **truststore 0.10.4 → 0.10.5.** Neither it nor cargo-c has a SHA pair: pip installs the pinned version, and cargo
  checks the crates.io checksum.
- **`# syntax=docker/dockerfile:1.28.0`** in all eleven Linux Dockerfiles. 1.28.0 refuses `COPY --link --chown=<name>`
  at parse time (moby/buildkit#7134). The three `--link --chown` copies in `Dockerfile.package` use the numeric
  `RUNTIME_UID`. A probe of that form built under the 1.28.0 frontend in Rancher Desktop's BuildKit, and the by-name
  form was refused.
- **Actions:** `github/codeql-action/upload-sarif` v4.38.2 → v4.38.3 (`24c54180`), `astral-sh/setup-uv` v10.2.0 →
  v10.3.0 (`1c37ad07`). Each digest was resolved from its tag through the GitHub API.
- **llm-stack compose:** Open WebUI v0.11.4 → v0.12.0, Glances 4.5.7-full → 4.5.8-full. The file pins tags, not
  digests; both tags resolve in their registries.
- Not in this batch: ONNX Runtime, LiteRT, Flutter, Ollama, llama.cpp, freetype, DXC, TensorRT and `WEBDAVCLIENT_REF`.
  protobuf 36.2 stays held, slaved to LiteRT-LM 0.18.0's v36.1.

## 2026-10-13 — no ONNX Runtime training (CON94 dropped)

- **Owner decision: the chain ORT stays inference-only.** Upstream deprecated on-device training in 1.20.0: the last
  training packages are 1.19.2's, onnxruntime-web dropped its `training` export, the training CI pipelines are gone,
  and commits under `orttraining/` are down to security fixes. A training build also changes inference: LayerNorm fusion
  and Dropout elimination behave differently, and so do the allocation planner and strided tensors. Carrying that
  needed eight hub patches to re-port on every ORT bump. Fine-tuning belongs in PyTorch, with the result exported to
  ONNX for the chain ORT.
- **The one training build the image carried goes.** `40-build-wasm.sh` compiled a third wasm pass with
  `--enable_training_apis` and copied `ort-training*` with `|| true`, though nothing loaded it. The WebGPU passes are
  now 3 and 4. The shared wasm cache id moves to `-wgpu2`, so no cached training files ship.
- **The shared wasm cache can no longer be stamped empty.** A non-amd64 target skips the wasm step with rc 0, and the
  RUN then stamped its empty directory complete. Under a fresh cache id, an arm64 or riscv64 stage that ran before the
  amd64 one would have left every arch without wasm. The stamp now waits for a `*.wasm`.
- **No `onnx` package either.** It was planned only for training artifacts; no family repo imports it.

## 2026-10-13 — the first all-3.15 `:winamd64` chain is green (CON91, CON92, CON93)

- **What ran.** Local BuildKit chain bk-20261013-004816 from hub 355a1d14, all 16 stages, 10347 s, no retries.
  media-litert took 1608 s and torch 1701 s. The smoke gate passed 273, failed 0 and skipped 1, the CUDA section
  on a CPU image. The target-arch walk passed 1378 binaries.
- **What it proves:**
  - **CON91:** media-litert built `ai_edge_litert-2.2.0-cp315-cp315-win_amd64.whl` (4522 compile, link and archive
    actions, all LLVM) and passed its smoke. The merge staged it in `C:\runtime\wheels`, and the torch venv installed
    it from there.
  - **CON92:** LiteRT-LM's 3829 compile, link and archive actions all ran clang-cl, lld-link or llvm-lib, and
    `litert_lm_main.exe --help` answered.
  - **CON93:** the toolchain staged `python315.lib` and `python3.lib` in `C:\temp\cpython\libs`. The torch stage built
    antlr4-python3-runtime, line-profiler, orchestrant and pyyaml from source with clang-cl and passed the Rich-header
    gate.
- **Not published yet.** The push to `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` is the owner's
  (`Build-Buildkit.ps1 -Stages final -PushRef …`, which rebuilds only the final stage from cache).

## 2026-10-13 — LiteRT-LM compiles with clang-cl, from a pinned bazel (CON92)

- **The LiteRT-LM lane left MSVC.** `Build-LitertLmBazel.ps1` passed only `--config=windows`, so Bazel picked its default
  `msvc_x64` toolchain: `cl.exe`, `link.exe` and `lib.exe`, against the clang-cl rule. It now builds with Bazel's own
  clang-cl toolchain (CON91's recipe), and an aquery gate fails the stage on any other compiler. Probe LM2 built
  `litert_lm_main` that way: 5244 actions in 539 s, all 3829 compile, link and archive actions on LLVM tools, `--help`
  OK.
- **Two floating fetches are gone.** bazelisk downloaded bazel 7.6.1 without a hash check; the lane now fetches that
  bazel binary by its SHA256 (`LITERT_LM_BAZEL_WINDOWS_*`) and refuses a clone whose `.bazelversion` differs. LiteRT-LM's
  WORKSPACE pulled the unhashed 744 MB OpenVINO nightly on every build; `OPENVINO_NATIVE_DIR` now names an empty dir.
  Probe LM1 showed `litert_lm_main` never uses it.
- **Bazel's user root moved out of the profile** to `C:\bzl-user`, so the cleanup removes it with the rest. `Get-TreeGb`
  no longer throws on an empty tree. Proven by chain bk-20261013-004816 (the entry above).
