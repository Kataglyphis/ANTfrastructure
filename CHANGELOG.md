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

## 2026-10-21 — No more ghost processes: test runners reap their process groups, agents start units, ghost-watch reports the rest

The build host carried a test fixture spinning at 100 % for 2.8 days and 24 headless Chromes
holding 22 GB, each left behind by an interrupted test run, and a watcher an agent had detached.

- **`lib-ordered-jobs.sh` runs each job as its own process group** and kills it whole when the job
  ends, after `OJ_TIMEOUT`, and from `oj_reap` when the runner exits; `run-tests.sh` and
  `preflight.sh` call it from their EXIT traps. `run-tests.sh` sets `OJ_TIMEOUT` from
  `RUN_TESTS_SUITE_TIMEOUT` (default 900 s) and prints `TIMEOUT: killed after …`, so a hung suite
  no longer stops the whole preflight: one sat 27 minutes in `test-docs-sidebars.sh` (CON144).
  Git Bash keeps the plain subshell. New `test-run-tests-reaping.sh`, serial and side by side.
- **`verify_mutations.py` ends each test's session after it, not only on timeout**, and every
  live test session when the gate itself gets SIGTERM, SIGINT or SIGHUP; its tests ran with
  `start_new_session`, which hid them from whoever killed the gate. It sends SIGTERM and waits
  5 s before SIGKILL, so a runner inside reaps the groups it made. Two new cases in
  `test-mutation-gate.sh`; its fixtures now keep their children off the test's pipes, and the
  suite runs in 8 s instead of two minutes.
- **`linux/host-config/ghost-watch.sh`** reports a user's orphans (parent PID 1 or the user's
  systemd, older than an hour) that average 25 % CPU, hold 1 GB or look like test leftovers;
  `--install` adds an hourly user timer with a desktop notice. It only reports.
  `docs/linux-host-setup.md` § B10, `test-ghost-watch.sh`.
- **`AGENTS.md` § *Background jobs and test processes (no ghosts)***: agents start background jobs
  as `systemd-run --user --unit=… -p RuntimeMaxSec=…`, fixtures end on their own, runners kill
  whole groups, wait loops wait on a PID or a file.
- Eight mutation entries pin it: `ordered-jobs.reap-job-group`, `script-tests.reap-on-interrupt`,
  `script-tests.suite-timeout`, `mutations.reap-*` and `ghost-watch.*`; `test-harness.sh` gains
  `t_wait_file` and `t_pid_state`.

## 2026-10-21 — The wrapper-smoke gate runs beside the wrapper build (CON126)

- The gate took 821–898 s on amd64 and 1150–1265 s on arm64 per run, and the wrapper build, which
  reads nothing of it, waited. `runtime_build_chain` now starts it in the background (lines prefixed
  `[smoke <arch>]`) and builds the wrapper meanwhile. The push, or the rootfs export, waits for its
  verdict, a red gate fails the arch with nothing shipped, and a failed wrapper build still collects
  it. `[runtime-timing] ... step=smoke-wait` shows the wait left. `RUNTIME_SMOKE_OVERLAP=0` runs the
  gate first, as before.
- **Proof.** `test-runtime-smoke-overlap.sh` times the chain against its serial twin and checks the
  push and export order and both failure paths; six `runtime-smoke.*` mutations bite. AGENTS.md's
  wrapper-smoke rule says where the gate now sits.
  [linux-cross-builds.md § The wrapper-smoke gate runs beside the wrapper build](docs/linux-cross-builds.md#the-wrapper-smoke-gate-runs-beside-the-wrapper-build).

## 2026-10-21 — preflight, the script tests and shellcheck run side by side (CON126)

- **`lib-ordered-jobs.sh`**: runs recorded commands N at a time, each into its own log, and reports
  them whole in the order recorded. `run-tests.sh` runs its 227 suites through it
  (`RUN_TESTS_JOBS`), and `preflight.sh` its slugs (`PREFLIGHT_JOBS`), with `cmake-format` alone
  first and `mutations` alone last, since one writes into the tree and the other copies it.
  `lint-shell.sh` runs one shellcheck per file `LINT_SHELL_JOBS` at a time and refuses a run that did
  not report on every file. Default: one per CPU; `1` restores the serial path.
- **Measured in `:latest` on 32 cores**: `run-tests.sh` 754 → ~106 s, `PREFLIGHT_SKIP=mutations
  preflight.sh` 1125 → 123 s, `lint-shell.sh` 77 → 14 s. Every parallel run reported the same red
  suites as the serial one: the three that fail on the image's Python 3.14 against the 3.15 pin.
- A background job ignores SIGINT, so `test-renovate-fleet.sh`, which tests its own Ctrl-C
  handling, failed only side by side. The runner hands each command its SIGINT back, and so do the
  runtime lane's parallel gates.
- **Proof.** `test-run-tests.sh`, `test-preflight-parallel.sh` and `test-lint-shell-parallel.sh`
  compare each parallel run with its serial twin (same report, less time), and 14 new mutations
  bite. [code-quality-tooling.md § The gates run side by side](docs/code-quality-tooling.md#the-gates-run-side-by-side).

## 2026-10-21 — One lookup for the target's sysconfigdata (CON114)

- `cross_target_sysconfigdata_dir <triplet> <root>` (`01-core/cross-python.sh`) finds
  `_sysconfigdata__linux_<triplet>.py` under `<root>/lib`, lib-dynload included. The wheelhouse's
  `resolve_target_python_sysconfig_export` and TVM's `_tvm_target_python_sysconfig_export` both
  call it instead of their own `find`; what each does with the module is unchanged. The pair's
  `code-dupes.allow` row was already gone since ab61b9e0 rewrote the wheelhouse export.
- **Proof.** `test-wheelhouse-sysconfig-env.sh` gains a staged target module that the wheelhouse
  copies instead of synthesising, and TVM's export for it (its first test). Its synthesis case now
  names what Git Bash lacks (Windows' sysconfig ignores `_PYTHON_SYSCONFIGDATA_NAME`).
  `wheels.target-sysconfigdata-in-lib-dynload` and `wheels.staged-sysconfigdata-wins` bite.

## 2026-10-21 — A caller's `ARCH` survives the Vulkan SDK's `setup-env.sh` (CON133)

- **Cause.** Not the login shell: the image's entrypoint sources LunarG's `setup-env.sh`, whose
  first line is `ARCH="$(uname -m)"`. A lane's `-e ARCH=x64` stays exported with the new value, so
  every command through the entrypoint saw `x86_64` (`aarch64` on arm64); OxidANT's
  `package-linux.sh` refused both (OxidANT 134e46e). Measured in `:latest`: `--entrypoint bash`
  keeps `x64`, the default entrypoint prints `x86_64`.
- **Fix.** `vulkan_env_source_script` and the entrypoint put the caller's `ARCH` back after
  sourcing, or unset it when there was none. No family consumer read the uname value: only
  OxidANT exports `ARCH` into the image, and it accepts both since 134e46e. Lands with the next
  image. [failure-modes.md](docs/failure-modes.md#a-lanes-arch-arrives-as-x86_64).
- **Proof.** Two cases in `test-vulkan-env-active-link.sh` (the helper, with and without a caller
  `ARCH`; the entrypoint's own fallback); `vulkan.env-keeps-callers-arch` and
  `vulkan.entrypoint-keeps-callers-arch` bite.

## 2026-10-21 — `sccache-launcher.sh` keeps hyphenated environment names (CON132)

- **Cause.** The launcher ran under `#!/bin/sh`, dash in every image, and dash drops each variable
  whose name is not an identifier before it runs a child. Cargo's `CARGO_BIN_EXE_burn-demos` never
  reached rustc, so OxidANT's arm64 clippy lost the integration-test path (OxidANT 5daefb8).
- **Fix.** `#!/usr/bin/env bash`; bash passes such names on. A case in
  `test-sccache-launcher.sh` runs the launcher through its shebang with `CARGO_BIN_EXE_burn-demos`
  set and finds it in sccache's environment (`sccache.launcher-keeps-hyphenated-env` bites where
  `/bin/sh` is dash; Git Bash skips the case). [build-cache-tiers.md](docs/build-cache-tiers.md#sccache-failure-classes-the-launcher-must-bypass).

## 2026-10-21 — The disk sampler's owner is its script, not the script's parent (CON138)

- **Cause.** `_disk_guard_watch_loop` defaulted its owner to `$PPID`. Under the Git Bash mutation
  gate a suite's parent is `cmd.exe`, which MSYS reports as PID 1, so `kill -0` failed and the
  loop returned before its first sample: `watch_loop samples repeatedly` counted 0 of 3, and every
  mutation on `test-disk-guard.sh` read as a vacuous bite. In a backgrounded subshell `$PPID` is the
  script's parent too, which is why `build-cross-chain.sh` already passed `$$`.
- **Fix.** The default owner is `$$`. A new case stops the loop once its owner is gone
  (`disk-guard.watch-dies-with-owner` bites).
- **Proof.** The suite run the way the gate runs it (`subprocess.Popen(..., shell=True)` from
  Git Bash) fails 0/3 before and passes after.

## 2026-10-21 — The mutation gate restores its targets byte for byte (CON134)

- **Cause.** `verify_mutations.py` read each target in text mode and wrote the mutant and its
  backup the same way. On Windows that writes LF as CRLF, so from a target's first mutation on its
  shard mirror held a CRLF copy, and a later baseline matching an exact newline against it failed:
  CON31's pre-push read 14 vacuous bites, CON131's wiring test had to fall back to `grep`.
- **Fix.** Targets are read and written as bytes (`read_exact`, `write_exact`), and the backup is
  the original's bytes. A CRLF checkout (`core.autocrlf`) of a target gets the manifest's LF find
  and replace translated to CRLF, so its multi-line entries still apply and keep its line endings.
  `test-package-image-wiring.sh` matches `$'\n    install_pwsh\n'` exactly again.
- **Proof.** Two cases in `test-mutation-gate.sh` (an LF and a CRLF target restored byte for byte;
  a multi-line find on a CRLF target, the mutant keeping CRLF); the old gate fails the first on
  Git Bash. Three mutations bite (`mutations.restore-is-byte-exact`,
  `mutations.crlf-target-takes-lf-find`, `packaging.pwsh-wired-into-setup`).

## 2026-10-21 — The runtime lane uploads each wrapper while the next arch builds (CON126)

- **Owner directive 2026-10-20**: everything in the hub runs as parallel as the host allows. On that
  day's 3-arch `:latest` run each arch's lane ended in its ~20 GB wrapper push (~1.2 h at 5 MiB/s),
  and the next arch waited for it.
- **`lib-runtime-push.sh`**: the wrapper build queues its tag and returns, and one background pusher
  uploads the queue oldest first through `runtime_push_tag`. The index waits for the drain, and a
  failed push fails the lane there. A lane that fails earlier still uploads what it built; an
  interrupt stops the pusher. `RUNTIME_ASYNC_PUSH=0` pushes inline as before. The lib sits beside
  `lib-runtime-wheels.sh`, outside every image closure.
- **Gates during the upload**: the content gates, then the smokes, run for every arch at once, with
  each arch's output printed whole in arch order. `RUNTIME_GATE_JOBS=1` gates in turn as before.
- **Proof.** `test-runtime-push-queue.sh` holds the first upload open and shows the next arch's build
  running, FIFO order, the close race, failure, interrupt and exit-drain paths, and the gates side
  by side. Its 21 mutations bite in `:latest`. Real `nerdctl push` runs through the pusher to a
  throwaway local registry, including a permanent failure that fails the drain. The next chain run
  must show `[runtime-timing] arch=arm64 step=base` between `[runtime-push] arch=amd64 start` and
  `done`. [linux-cross-builds.md § The wrapper push runs beside the next build](docs/linux-cross-builds.md#the-wrapper-push-runs-beside-the-next-build).

## 2026-10-21 — The runtime lane's wrapper reaches the sccache S3 level, and its push stops flooding the log

Found by reading the last nine `:latest` chain logs and their resource samples.

- **`_runtime_build_wrapper` passes `--secret id=sccache_s3`** through the cross lane's
  `_cross_build_append_sccache_s3_secret`. `Dockerfile.torch`'s HailoRT RUN already mounted the
  secret, but the runtime lane never handed it over, so its only cache was the cachemount, which a
  `buildctl prune` between runs empties. Two runs in a row compiled HailoRT with 0 hits, about 32
  minutes a run on arm64 under QEMU (`hailort-build` 857 s against 49 s with hits).
  `test-sccache-s3-level.sh` pins the call.
- **`nerdctl push --quiet`** in `_runtime_push_attempt`, plus one `[push] <tag>: rc=<n> after <s>s`
  line per attempt. The progress redraw was 3.59 of the 3.66 million lines of a chain log
  (517 MB). `RUNTIME_PUSH_PROGRESS=1` brings it back. New `test-runtime-push.sh`.
- **`test-mutation-gate.sh`'s spinning fixture ends after 60 s.** Its `while :; do :; done`,
  orphaned by an interrupted run, held a core of the build host from 2026-10-18 to 2026-10-21.
- **The package stage's libFuzzer probe accepts either layout.** It looked for
  `lib/x86_64-unknown-linux-gnu/libclang_rt.fuzzer-x86_64.a`, a name that layout never uses (it holds
  the unsuffixed `libclang_rt.fuzzer.a`), so every arch of every `:latest` run printed `[WARN] no
  libclang_rt.fuzzer-x86_64.a staged` while `clang -fsanitize=fuzzer` linked fine (checked in the
  2026-10-21 amd64 and arm64 children). It re-keys the package stage from that RUN on.

## 2026-10-21 — build-docs.yml's rustdoc builder takes the guide list

- **`guides` works with `builder: rustdoc`**, as with `dartdoc` since c91187a9. `docs-site.sh` runs
  `cargo_build_doc.sh`, then dartdoc's own stage and render steps over `target/doc`.
  `dartdoc-guides.py` gains a rustdoc flavor: a guide is the root package's `<crate>/index.html`
  with `#main-content` and the sidebar's `#rustdoc-toc` replaced, written beside it so its
  `../static.files/` paths hold, and every page with a `sidebar-elems` lists the guides at its top.
  New knobs `DARTDOC_BUILD_API_DIR`, `DARTDOC_BUILD_FLAVOR` and `DARTDOC_BUILD_SHELL`; a dartdoc site
  is unchanged.
- **The sidebar check knows rustdoc** (marker `crates.js`; 1400, 700 and 400 px; the top bar's
  `.sidebar-menu-toggle`). A rustdoc site's `index.html` is a redirect at best, so it opens the
  crate pages that hold guides and those guides, else the first crate of `crates.js`.
- **Proof.** OxidANT's site with its eight `docs/` guides in `:latest` (rustc 1.99.0): 8 guides
  rendered, 478 of 594 pages navigated (source pages have no sidebar), the sidebar check green on
  `oxidant/index.html` and every guide at all three widths, the link gate 595 documents with its
  24 frozen findings, in 161 s. `test-docs-site.sh` 60 → 70 assertions, `test-dartdoc-guides.sh`
  38 → 55, `test-docs-sidebars.sh` gains a rustdoc fixture; seven new mutations, and four moved to
  the new code. Consumers: only OxidANT calls `builder: rustdoc`; no input changed.
  [docs-sites.md § Inputs](docs/docs-sites.md#inputs).

## 2026-10-21 — nvidia's stage images move to a private package (CON136)

- **Owner decision 2026-10-21** ("Auf privat stellen"): from the next nvidia chain the `gpu`, `media`
  and `android` stages carry TensorRT 11's headers and dev links, which its SLA does not let anyone
  redistribute, and GHCR sets visibility per package. `tag-naming.sh` `cross_stage_repo` sends them to
  `<repo>-stages` (`ghcr.io/kataglyphis/kataglyphis_beschleuniger-stages`, private on its first push);
  the push, its inline registry cache, the digest pins, the ancestry annotations and the runtime
  lane's artifact prefix follow the tags. `:latest-nvidia`, the shared `base`/`compiler`/`sdk` and every
  rocm stage stay in the public package. `01-core` is in the compiler closure, so this re-keys the
  default chain from the compiler stage, like any `01-core` edit.
- **Windows** pushes no stage (`trt-extract` and the rest stay in containerd; only `-PushRef` pushes).
  `Build-Buildkit.ps1` now refuses an nvidia `-ExportCacheRef` in the public package, whose `mode=max`
  cache would carry the SDK.
- **Proof.** `test-gpu-variant.sh` runs the real entry points dry: every ref a pushing nvidia media
  build names (tag, push, registry cache, parent pin) is the private package's, the runtime lane reads
  android from there, `:latest-nvidia` and rocm stay. Seven `stage-repo.*` mutations bite; three manual
  mutations of the Windows guard fail `Driver.Variant.Tests.ps1`, and the driver's preflight
  contract lists it.
- **Left for the owner** (`BACKLOG.md` CON136): check the new package's visibility after the first
  push, and delete the three old public tags `cross-{toolchain,media,android}-nvidia-amd64`.
  [linux-accelerator-images.md § Stage images](docs/linux-accelerator-images.md#stage-images-a-private-package).

## 2026-10-21 — Flutter web builds that load nothing from Google

- **Owner decision 2026-10-21** ("Selbst ausliefern"): jotrockenmitlocken stops loading CanvasKit
  from Google's CDN, as OmniAccelerANT already did. `flutter_integration_smoke_test.sh` checks
  this by default (`CHECK_LOCAL_ENGINE`): `flutter_bootstrap.js` must load the engine locally, and
  `canvaskit/canvaskit.wasm` and `skwasm.wasm` must be served as `application/wasm`.
  `REQUIRED_CSP_HOSTS` is empty by default; it asked for gstatic.
- **`flutter_capture_console_errors.py`.** It used to serve the build through `python -m
  http.server`, so every deep route got a 404 page and only `/` really loaded the app. Its own
  server now answers extension-less paths with `index.html`. It also lists every third-party
  host and HTTP error, and `--forbid-host` fails on a host. Measured on jotrockenmitlocken: before,
  www.gstatic.com (the engine) and fonts.gstatic.com (Roboto, which the engine fetches unless the
  app declares a family of that name); after, none.
- Suite: `test-flutter-smoke-test.sh` (6). Mutations: `web-smoke.no-default-csp-hosts`,
  `.local-engine` and `.engine-files`; they replace `.empty-csp-hosts`.

## 2026-10-21 — The Flutter web shell, the coverage floor and the frame timings, shared by both apps

- **`shared/web/`**: the loading screen and cookie notice both Flutter web apps load before Flutter
  starts, merged from the two copies that had diverged. From OmniAccelerANT: the phone layout,
  `prefers-reduced-motion`, a button rule scoped to the notice, and `Secure` only on https. From
  jotrockenmitlocken: the dark variant, the fade-out, a consent cookie that lasts (`Max-Age` 400
  days, `path=/`; OmniAccelerANT's unparsable `expires` made it a session cookie) and no inline
  script. Five `exact` rows in `shared-assets.manifest`; `flutter-web-htaccess` is a `body` row
  for jotrockenmitlocken's `web/.htaccess`.
- **`05-frameworks/flutter/`**: `check-dart-coverage.sh` (with `--exclude` for an app's generated
  trees), `frontend-perf-report.py`, `flutter-trace-summary.py` and the new `check-web-artefacts.py`
  (title vs manifest name, `sqlite3.wasm` vs its pin, 8-bit icons), all from OmniAccelerANT, so
  jotrockenmitlocken takes them too. Suites: `test-check-dart-coverage.sh`,
  `test-perf-reports.sh`, `test-check-web-artefacts.sh`.
- **`linux/webserver/`**: `flutter-nginx-integration-test.sh` is jotrockenmitlocken's nginx harness
  for any build dir and port, Git Bash paths included (`test-flutter-nginx-integration.sh`). The
  smoke test's `CHECK_LOADING_SHELL` now checks the shared shell's markup and files; it used to
  warn about a MutationObserver the shell no longer has. The console capture takes `--route`.
- Seven mutations, each proved to bite.
## 2026-10-21 — The GPU images ship TensorRT's runtime files only (CON136)

- **Owner decision 2026-10-21** ("Rausnehmen"): TensorRT's SLA names only "the runtime files .so and
  .dll" distributable, so headers, dev links, `trtexec`, Python bindings and SDK trees serve build
  stages and never ship.
- **`:latest-nvidia`.** `deepstream.sh` unpacks DeepStream's three TensorRT 10 header debs into its
  build tmp (`ds_trt_sdk`, with the dev links), which the components compile against and the RUN
  deletes; the prefix keeps the runtime `.so.10*` files and their docs. The published `0e9dec34…`
  carried 13 headers (0.88 MB) and three dev links there. A custom `nvinfer` parser needs
  `libnvinfer-headers-dev` 10.16.1.11 in its own build stage; no family repo builds one.
- **`:winamd64-nvidia`.** `Copy-TensorrtRuntime.ps1` ships the DLLs ORT's TensorRT EP loads
  (`nvinfer_<M>`, `nvonnxparser_<M>`, `nvinfer_plugin_<M>`, every builder resource: 11 DLLs, 2.39 GB
  for 11.4.0.106) and the licence texts instead of the zip's tree. The ORT build mounts the tree
  from `trt-extract`, which `Build-Buildkit.ps1 -Gpu` tags `bk-windows-tensorrt-sdk-nvidia`. The
  published Windows images were built zip-less and carry no TensorRT; `:winamd64` is CPU.
- **Gates.** `check_gpu_runtime` fails every image with a TensorRT header, dev link (DeepStream's
  prefix included), `trtexec` or `tensorrt` package, whatever `ENABLE_TENSORRT` says;
  `deepstream-verify.sh` fails a TensorRT 10 prefix with anything but runtime files, ldconfig's links
  and docs; the Windows smoke fails a `TENSORRT_ROOT` with anything but `current\bin\*.dll` and
  licence texts, and an EP whose TensorRT DLLs are missing there. Eight mutations, 13 Pester cases.
- **Proved** without a chain build. In a throwaway container on the published `:latest-nvidia`
  (`0e9dec34…`): both gates fail as shipped and pass on the new layout, every other DeepStream gate
  and all nine registrations still pass, every DeepStream link to TensorRT 10 (31) resolves into the prefix,
  and ORT v1.31.0's TensorRT EP, built there against TensorRT 11, resolves every dependency. In the
  published `:winamd64` (`--isolation process`) the smoke gate passes as shipped, fails the old
  tree shape on 13 files and passes the subset; the published `:winamd64-nvidia` passes with its
  empty `C:\tensorrt`.
  [linux-accelerator-images.md § Redistribution](docs/linux-accelerator-images.md#redistribution),
  [windows-builds.md § TensorRT setup](docs/windows-builds.md#tensorrt-setup-gpu-lane-optional).

## 2026-10-21 — TensorRT 11 and its ORT EP in `:latest-nvidia`; `:latest-rocm` finds its ROCm (CON31)

- **Owner decision 2026-10-20.** Every amd64 nvidia build gets TensorRT 11.4.0.106
  (`ENABLE_TENSORRT=true`; arm64 stays without). `install-tensorrt.sh` installs exactly
  `11.4.0.106-1+cuda13.4` (new pin `TENSORRT_LINUX_CUDA`) as twelve named packages, never the
  metapackages and their 1.9 GB Windows builder resource, and fails on any other version. ORT's GPU
  build gets its TensorRT EP; the package stage copies only TensorRT's runtime `.so` files, the
  only part its SLA names distributable. GenAI no longer asks for `--use_trt_rtx` (TensorRT-RTX,
  whose wheel requires an ORT the chain never builds). Proved on the published `0e9dec34…` without
  a GPU: the install, `getInferLibVersion()` 110400, ORT v1.31.0's TensorRT EP configured and built.
- **`:latest-rocm`.** The wrapper sets `ROCM_PATH`/`HIP_PATH` and appends `/opt/rocm/bin`: without
  them the venv's rocm-sdk `hipcc` could not link a HIP program. The entrypoint names the
  `--group-add` a closed `/dev/kfd` or render node needs, and the run line carries it. On this
  host's WSL VM (`/dev/dxg`, no `/dev/kfd`) a `hipcc`-built program ran on the Ryzen iGPU.
- **Gates.** `check_gpu_runtime` in the runtime smoke (the published `:latest-rocm` fails six of
  its rows), `deepstream-verify.sh` fails a DeepStream library that resolves TensorRT 11, and
  20 new mutations.
  [linux-accelerator-images.md § TensorRT 11](docs/linux-accelerator-images.md#tensorrt-11),
  [§ Running it on an AMD GPU](docs/linux-accelerator-images.md#running-it-on-an-amd-gpu).

## 2026-10-21 — Security: the Windows arm64 wheel store's Pillow and certifi

- `TORCH_WINDOWS_ARM64_PILLOW` 12.3.0 → 13.0.0 (cp313 win_arm64): GHSA-8g5g-8vmr-9782 (critical),
  GHSA-58r4-6rv3-gfh8, GHSA-65qm-jvmh-6pqg, GHSA-q45j-58j2-45rg, GHSA-pchr-8j38-3x4p,
  GHSA-p4wg-p73j-c528, GHSA-c6hw-5grf-ff96, GHSA-vx6w-vv9f-6gvg, GHSA-462x-pgg6-55fp.
- `PYTEST_WINDOWS_ARM64_CERTIFI` 2026.7.22 → 2026.10.19: GHSA-6q48-6c7w-9gw2 (critical).
- Same versions as OrchestrANT's lock (46a369a); takes effect with the next `:winarm64` build.

## 2026-10-20 — pwsh and PSScriptAnalyzer in the Linux image, from the next build (CON131)

- **Why.** CON124 moves consumer Python into `:latest`, and OrchestrANT's `benchmarks.yml` contract
  job cannot follow yet: its 41 PowerShell tests skip there (`pwsh is not on PATH`), and every
  other lane skips them too, so the job's bare runner is their only run.
- **The package stage** (`install_pwsh`, `package-image-wiring.sh`) installs pwsh `PWSH_VERSION`
  7.6.7 from its release tarball and PSScriptAnalyzer `PSSCRIPTANALYZER_VERSION` 1.25.0 from its
  release nupkg into `$PSHOME/Modules`, on amd64 and arm64, each against a SHA-256 pin
  (`PWSH_LINUX_{X64,ARM64}_SHA256`, `PSSCRIPTANALYZER_NUPKG_SHA256`, equal to the release's
  `hashes.sha256`, GitHub's asset digests and the Gallery's SHA-512). It fails the stage when pwsh
  does not report its pin or does not list the module at its pin. riscv64 gets neither: PowerShell
  publishes no riscv64 build (`image-decisions.md`). `bump_versions.py`'s `spec_pwsh` re-derives the
  two tarball pins with the zip's.
- **Gates.** Seven cases in `test-package-image-wiring.sh`, nine mutations.
- **Proved** in throwaway containers of `:latest` `b52f8c34`: amd64 and arm64 (QEMU) `OK: pwsh
  7.6.7`, `OK: PSScriptAnalyzer 1.25.0`, listed as uid 1001; riscv64 the note. OrchestrANT's
  contract command on the image's 3.14 and 3.14t, as uid 1001 against ollama: 2411 passed, 2 skipped
  on both legs, PSScriptAnalyzer's test included; without pwsh 2370 passed, 43 skipped.
- **Docs.** [`consumer-image-contract.md` § PowerShell](docs/consumer-image-contract.md#powershell).

## 2026-10-20 — A WebGPU page is proved by reading its frame back, not by a screenshot (CON128)

- In the image's headless Chrome 155 a WebGPU canvas screenshots white.
  `linux/scripts/webgpu-canvas-readback.js` runs WebGPU on SwiftShader, copies the next frame out
  after its last submit and counts its colours; it exits 1 below `--min-colours` (2) and paints the
  frame over the canvas for `--screenshot`. It reuses `check-docs-sidebars.js`'s Chrome launcher.
- BeschleunigerBallett's published demo reads back 3124 colours, `1280x743 rgba8unorm`.
  [docs-sites.md § Proving a WebGPU page](docs/docs-sites.md#proving-a-webgpu-page).

## 2026-10-20 — Exhale's tree views fold again; the sidebar check fails on an uncaught exception (CON127)

- **Cause.** Exhale 0.3.7's `apply-collapsible-lists.js` is `$(document).ready(...)`, and
  Sphinx 6 stopped shipping jQuery: every page of AccelerANTgine's and BeschleunigerBallett's
  sites threw `ReferenceError: $ is not defined`, and their API trees never folded.
- **Fix** in DocumANTation 020a5c3, the gitlink here: the theme copies a jQuery-free applier over
  Exhale's, with no new dependency. The two sites get it with their next hub gitlink, since their
  docs install the theme from this hub's DocumANTation.
- **The gate.** `check-docs-sidebars.js` fails on any uncaught exception or rejection and clicks
  an Exhale tree view's first foldable item; it opens `index.html`, the pages named after the
  site, and in a built Sphinx site every page with a tree view. Eight new `docs-site.sidebars-*`
  mutations. The other seven published sites pass it as they are.
  [docs-sites.md § The sidebar toggle check](docs/docs-sites.md#the-sidebar-toggle-check).
- **An open item taller than the viewport** is scrolled to by its first line: BeschleunigerBallett's
  first namespace, centred whole, hid its own text, and run 39511861138 failed `does not go back`.
- **Chrome's DevTools port is read once it is written.** Chrome creates `DevToolsActivePort`
  before it writes the port; under load the launcher read it empty, polled `127.0.0.1:` and
  failed five mutation baselines with `opened no page` (run 39518418220). Six suites at once on
  two CPUs failed 3 to 5 launches before, none after (twice).
- **Live, 2026-10-21**: AccelerANTgine (run 39511855642) and BeschleunigerBallett (run 39518514131)
  republished; the check over each published site and its `api/library_root.html` finds no exception
  and folds the tree `closed -> open -> closed` at all four widths. CON127 is done.

## 2026-10-20 — The last 23 Apache-2.0 headers are MIT, as `LICENSE` says (CON69)

- **Owner decision 2026-10-20.** 802699f6 (2026-08-07) moved 101 headers to MIT and missed 23
  Windows scripts; their `SPDX-License-Identifier` line now reads `MIT`. Nothing else in them
  changed: the copyright line stays.
- **Checked first.** Every commit on each file, renames followed, is the owner's, co-authored
  only by Claude, and no file carries upstream attribution, a NOTICE or copied third-party code.
  So none stays Apache-2.0 and `third-party-licenses.md` gains no row.
- **Files.** `windows/scripts/build/`: `Build-GstreamerFromSource`, `Build-LitertAll`,
  `Build-LitertLmBazel`, `Build-MediaCoreAll`, `Build-MediaTvmAll`. `diagnostics/`:
  `Test-BuildCopy`, `Test-CudaCache`, `Test-Rdna4LayerLock`, `verify-cuda-cache/Test-Cache`.
  `host/`: `Clear-DiskSpace`, `Get-HostDockerState`, `Install-DufsService`, `Install-NewHost`,
  `Repair-WindowsComponentstore`, `Reset-ContainerLocks`, `Reset-ContainerStores`,
  `Set-ContainerdConfig`, `Set-ElevatedWindow`, `Set-Rdna4Gpu`, `Sync-DefenderExclusions`,
  `Test-HostSetup`. `modules/`: `WindowsHostMaintenance.Common.psm1`,
  `WindowsSourceBuild.Common.psm1`.
- **Not touched.** `.claude/hooks/guard-destructive-deletes.{ps1,py}` still say Apache-2.0
  (`rg` skips the hidden directory, so the row's count missed them); the hook is edited by
  the owner only (`comment-size.allow`).

## 2026-10-20 — Windows runs the suite on the installed cp3XYt wheel too (CON122)

- **Why.** Windows packaging only loaded the free-threaded wheel (OrchestrANT job 118384523138: `63
  compiled module(s) of orchestrant loaded on free-threaded 3.15.0`); no test ran its code there.
- **One definition.** A project names the tests in `pyproject.toml`'s
  `[tool.antfrastructure.free-threaded-wheel-tests]` (`extra`, `copy`, `env`, `isolated`,
  `pytest-args`); `free-threaded-wheel-tests.py table` validates and prints it. The Linux twin
  reads it when no flag names the tests; flags and a table together fail.
- **The GIL check.** `free-threaded-wheel-tests.py run` runs pytest in-process and fails when the
  GIL is on before or after the tests. All three lanes run through it, the Linux twin included.
- **Windows x64.** `Invoke-FreeThreadedWheelTests.ps1`, step 4 of `Invoke-PythonCiBuild.ps1`: a
  fresh venv of `C:\python-freethreaded`, the lock's set, the wheel `--no-deps`, the tests outside
  the checkout. **Windows arm64:** `New-Arm64PythonTestStage.ps1` stages `wheel-tests-<leg>.cmd` on
  the X.Yt leg; `New-FreeThreadedWheelTestStage` (`WindowsPythonWheel.Suite.psm1`) does it for
  OrchestrANT's own stage. A new module and a new helper, so no image layer re-keys.
- **Proved** at hub 4b69aaf8, every log ending `free-threaded wheel tests passed: <wheel>` after `the GIL
  stayed disabled through the tests`: WebDavClient c8a4fdf, Windows x64 run 39503219186 (24 passed,
  cp315t `win_amd64`), arm64 run 39503223240 (`wheel-tests-3.15t.cmd` 24 passed on `windows-11-arm`),
  Linux x64 run 39503160353 (24 passed, cp314t); OrchestrANT eec686e, Windows x64 run 39503226958 (8
  passed, 2 skipped), arm64 run 39503231162 (`wheel-tests-ft.cmd` 8 passed, 2 skipped; `TESTS:
  passed=3478 failed=0`), Linux x64 run 39503168656 (8 passed, 2 skipped).
- **Docs.** [`python-ci.md` § The suite on the installed wheel](docs/python-ci.md#the-suite-on-the-installed-wheel).

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
