# Backlog — image gaps

Every known gap in the images this hub publishes (`:latest`, `:winamd64`, the
`:winarm64` bundle) that a consumer lane hits or works around. The refactoring
registers stay in [`docs/refactoring-backlog.md`](docs/refactoring-backlog.md).
The CON1–CON6 prefix history is in
[`…-archive-2026-09-17.md`](docs/refactoring-backlog-archive-2026-09-17.md).

**State 2026-10-07**, read from the registry (hub = the image's `revision` label, digest =
the per-arch manifest). Published: `:latest` (2026-10-03, hub b4d5fdd5; amd64 `686fdf4e…`,
arm64 `26957741…`, riscv64 `67887737…`), `:winamd64` (2026-10-06, hub b3cf4c76), `:winamd64-nvidia` (2026-10-02, hub 7a5a2a33, `a9e67332…`),
`:winamd64-rocm` (2026-10-03, hub 1d910553, `493e80f1…`), `:winarm64` (2026-10-04, hub
80647a9a, `97bbcd35…`, without NVIDIA; no `:winarm64-nvidia` tag exists), `:latest-nvidia`
(2026-10-02, hub b4d5fdd5, amd64 `95c3a343…`, built without DeepStream) and `:latest-rocm`
(2026-10-02, hub b4d5fdd5, amd64 `bdfcb731…`). Every Linux image gap up to CON41 shipped
and was checked in the published children (git history). Decisions and gaps checked closed live in
[`docs/image-decisions.md`](docs/image-decisions.md). **Re-derive before acting; a number
here is a date's measurement.**

## Protocol

The agentic loop's format (`docs/windows-agentic-loop.md`):

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★, as in the refactoring backlog.

## Open — getting fixes to consumers

- [ ] **CON75 — the free-threaded wheel on the cross lanes** [M, ★]. The riscv64 cross build
      and the Windows arm64 cross lane skip `cp314t` with a logged reason. riscv64 needs 3.14t
      target headers in the sysroot (CON66 stages them at `/opt/python-cross-ft/riscv64`), the
      `.cpython-314t-riscv64-linux-gnu.so` suffix and a 3.14t host pip. Windows arm64 builds no
      Cython wheel at all; its target interpreter exists since CON74 half 1, and
      `New-FreeThreadedBuildPython` pins a cross venv's `EXT_SUFFIX` since CON79 item 2; the Linux riscv64
      cross half is what remains. Done when both ship a wheel proved on
      the target.
- [ ] **CON76 — a real cp314t proof in the hub suite** [S, ★]. Once `:latest` ships `3.14t` on
      every arch (CON66), `test-python-free-threaded-wheel.sh` builds two tiny C extensions (one
      declaring free-threading support, one not) and runs `prove` for real instead of a stubbed
      interpreter.
- [ ] **CON74 — a free-threaded CPython for Windows arm64, so its 3.14t legs stop downloading**
      [M, ★]. Half 1 is in the scripts since 2026-10-07 (CHANGELOG): media-core's
      `Build-TargetCpython.ps1` stages the `--disable-gil` ARM64 build into
      `C:\runtime\python-freethreaded` (`python3.14t.exe`, `libs\python314t.lib`, the venv
      launchers, no `python.exe`), `BUNDLE-ENV` appends it last to `PATH`, and
      `Test-Arm64Bundle.ps1` runs it on a device when the bundle carries it. Left:
      1. **Republish `:winarm64`.** The published one (2026-10-04, hub 80647a9a) has no tree. Then
         read the first `bundle-gate` job of a cross lane with `bundle-artifact-name` for the step
         `free-threaded interpreter: GIL off, stdlib extensions import`.
      2. **[b] python-ci-windows.yml's arm64 job — owner decision.** It runs on the bare runner,
         and `Invoke-PythonTestLegs.ps1 -InstallUv` lets uv download a python-build-standalone
         3.14t. No image runs on `windows-11-arm`, so the tree has to arrive as an artifact:
         either a `windows-2025` job pulls `:winarm64` and uploads only
         `C:\runtime\python-freethreaded` (82.5 MB), as `container-ci-windows.yml`'s bundle export
         does for the whole tree, or the image publish pushes that directory as its own SHA-pinned
         artifact. Then the arm64 job extracts it, appends it to `PATH`, sets
         `UV_PYTHON_DOWNLOADS=never` and checks that `uv python find 3.14t` resolves inside it;
         only then is the download dropped. The job's GIL legs download too (separate decision).

      Done when a windows-11-arm `3.14t` leg passes with `UV_PYTHON_DOWNLOADS=never` and the
      device smoke reports `sys._is_gil_enabled() == False` for the bundle's `python3.14t.exe`.
- [ ] **CON79 — the cp314t chain twins reach the published images, and phase 2** [L, ★★]. Linux native
      and Windows amd64 are in source since 2026-10-07 (CHANGELOG). Open:
      1. **Prove in full image builds**: Linux — the nvidia and rocm ORT twins (one call each), the IREE
         compiler twin at v3.12.0 (proved locally on v3.11.0's tree, 2026-10-07), FT-STORE green on `:latest` amd64 (and arm64 on a native arm64 chain), the ORT census
         taking the twin, `PYTHON_WHEELS_CP314T` in FT-STORE, and a 3.14t venv reconciled onto the real ORT twin
         (`uv_reconcile_chain_ort`, proved locally only with stand-in twins). Windows — a `:winamd64` image build carrying all five twins, so smoke section 20 checks its
         exact set; the IREE v3.12.0 clang-cl fixes and the `iree-base-compiler` twin are proved locally on the
         full compiler tree since 2026-10-07. Optional: keep the GIL interpreter in IREE's VM ISA genrule for
         the Windows twin, as `Set-OrtNinjaCommandPython` does for ORT (56 of its 137 edges go away).
      1b. **Linux cross twins** (arm64 cross, riscv64, including riscv64 torch/torchvision/numpy, which need
         rows in `03-media/free-threaded-twins.txt`): `ft_soabi_gate` takes the target EXT_SUFFIX from `/opt/python-cross-ft/<arch>`, and the
         proof runs on the target (QEMU) or in the package stage.
      2. **arm64 cross twins (Windows): the device proof.** In source since 2026-10-07 (CHANGELOG), proved
         statically in `:winarm64`. Left: republish `:winarm64`, then read the first `bundle-gate` job's step
         `free-threaded wheels: every cp314t twin loads with the GIL off`. Also left: cp314t `win_arm64` wheels
         for the twins' dependencies (numpy and ORT's requirements, `Copy-TargetPythonDeps.ps1`), without which
         a consumer installs a twin `--no-deps`.
      3. **The ROCm torch twin** (`Build-TorchRocmFromSource.ps1`; `Dockerfile.torch` already mounts the module,
         and must mount `linux/scripts/03-media/free-threaded-twins.txt` at `C:\bkmnt\free-threaded-twins.txt`
         once it asks `Get-FreeThreadedTwinPlan`).
      5. **Upstream**: IREE's bare-`python3` genrule (`runtime/src/iree/vm/bytecode/isa/CMakeLists.txt`) and its
         Windows `cpython-NNt` SOABI detection (`CMakeLists.txt:782-791`); onnxruntime-genai's
         `PYBIND11_MODULE` (`src/python/python.cpp:468`) plus a thread-safety audit of its global log callback.
- [ ] **CON80 — prove the in-place site-packages merge in the next Windows chain run** [S, ★]. The cause
      (a COPY over a lower layer's file stores it lowercased) and the fix landed 2026-10-07 (CHANGELOG): the
      fan-in merges in one RUN, refuses mixed versions and lost RECORD spelling. Proved in a replay only.
      Rebuild `:winamd64` and `:winarm64`: smoke section 2 must pass `import Cython.Shadow` and the RECORD
      check. Until then, images built before the fix take `pip uninstall -y cython` and
      `pip install cython==3.3.0` in two separate RUNs (verified on bk-windows-media); a one-layer
      `--force-reinstall` leaves `cython\` and still fails.

- [ ] **CON84 — lock maintenance and sqlite3, the loose ends** [S, ★]. (1) The report cannot say how far behind a
      maintained lock is: add the tool's own dry-run count per lock. (2) Yarn is NOT CARRIED (no family repo has a
      yarn.lock today). (3) `actions-selftest.yml` never runs `clone-into-short-path` on a pull_request merge ref; the fix
      is proved by a local reproduction only. (4) Consumers to follow: jotrockenmitlocken (sqlite3 3.7.0 in its lock and
      a refreshed `web/sqlite3.wasm`), ANThology (lock maintenance), OmniAccelerANT's `environment: flutter: '>=3.41.6'`
      floor (its lock now needs 3.47.0), and optionally OmniAccelerANT's `dev.flutter.flutter-plugin-loader` gradle rule
      into the preset. (5) OmniAccelerANT's lock maintenance (go_router 18.0.2, sqlite3 3.7.0 and the wasm) waits
      locally for its hub gitlink to move past this commit, which waits for the published images (CON72).

- [ ] **CON83 — the riscv64 Python lane: seed its sync, and test the cross wheel** [M, ★★]. Found while fixing
      OrchestrANT's riscv64 lane (2026-10-07): its emulated `uv sync` of the `test` extra builds numpy, matplotlib,
      contourpy, pillow, line-profiler, psutil and pyyaml from source, 108 min of the runner's 6 h (numpy alone 107 min),
      because no cp314 riscv64 wheel exists for them. The image already builds OrchestrANT develop: ship a riscv64 uv
      cache (or wheel store) seeded from its lock that `ci_tests.sh` copies into `UV_CACHE_DIR` (a warm cache synced in
      1 min locally). And install plus smoke-test the cross-built riscv64 wheel on the emulated row; today it is never
      installed. The riscv64 image also lacks shellcheck and hadolint (their rows report SKIPPED).
      OrchestrANT-side, owner calls from the same analysis: import `matplotlib.pyplot` lazily in
      `orchestrant/__init__` (31-37 s per subprocess under QEMU; `bench_agent.py --list` takes 41.9 s
      against a 60 s timeout, but the change touches Cython-built modules and tests that patch
      `plotting.plt`); hermetic grading (`PYTEST_DISABLE_PLUGIN_AUTOLOAD`) in bench_agent's own
      grading runs, which changes product behaviour; and re-measuring the process ceiling per launch
      on a busy shared box (about 0.37 s per launch under QEMU).

- [ ] **CON82 — prove the 2026-10-07 pin bumps in the images** [M, ★★]. Linux base/sdk on Vulkan SDK 1.4.363.0, with
      the arm64/riscv64 foreign SDK reaching 24/24 without the retired slang patch and the runtime smoke advertising
      1.4.363.0; the package stage with Chrome for Testing 155, Node 26.11.0 and the seven 26.08 flatpak refs on amd64
      and arm64; Windows base (scoop vulkan 1.4.363.0 and the arm64 component), the rocm loader zip, arm64
      Vulkan-ValidationLayers at vulkan-sdk-1.4.363.0, the rocm FFmpeg against VK_HEADER_VERSION 363, the media x265 4.2
      build and the rocm llama stage's ggml-hip from b11476; Linux media vvdec v3.2.1; then OmniAccelerANT's flatpak and
      catcam lanes on runtime 26.08 once its hub gitlink moves. Also `bump_versions.py --audit-sha-pairs` fails since
      before this bump: about 100 SHA keys have no refresh spec (`X265_SHA256` among them).

- [ ] **CON78 — prove the TheRock 10.1 images (`:latest-rocm`, `:winamd64-rocm`)** [M, ★★]. The bump
      (CHANGELOG 2026-10-07, CON73) was proved in throwaway `:latest` and `:winamd64` containers only.
      **Linux**, a rocm chain run (`CROSS_VARIANT=rocm`):
      1. `Dockerfile.amd` as a gpu stage over `:cross-sdk-amd64`, and the media stage's ORT gpu step under the
         chain's toolchain and caches (`verify-media-artifacts.sh onnxruntime-gpu`).
      2. The runtime copy: `copy_rocm_payload` carrying `/opt/rocm/extras-10` and remaking the `core-10` and
         `rocm-*` alternatives links; `publish_rocm_ld_path` writing `extras-10/lib`; the ORT G6 census.
      3. The wrapper smoke: `torch.version.hip` with the rocm7.14 wheels over a 10.1 system tree, and
         `MIGraphXExecutionProvider` listed. Then the image size (21.7 GB of ROCm before the runtime copy).
      **Windows**, a `Build-Buildkit.ps1 -Variant rocm` run:
      4. The whole rocm chain on the 10.1 sdk layer, then `Test-RocmImage.ps1` with every rocm-check clean;
         MIGraphX 2.18.0 and the EP inside BuildKit (`prefuse_ops.cpp` is the stage's critical path).
      5. torch v2.14.1 / torchvision v0.29.1 against the 10.1 SDK, and rocm-1 installing the 10.1.0 wheels:
         `rocm-checks\Torch.ps1` reports `+rocm10.1.0` and HIP 7.16.
      6. The llama stage in BuildKit (`ggml-hip` through the WebDAV sccache, the `llamamods` closure, cleanup,
         `LlamaCpp.ps1` at the smoke gate). Then drop the `hip-msvc-cmath` overlay if 4–6 build without it.
      **Both, on a real GPU (RX 9070 XT, gfx1201):** a MIGraphX EP session, torch HIP, and a small model on
      ggml-hip against its CPU result. With no bundled runtime a bare Windows host's loader takes Adrenalin's
      System32 `amdhip64_7.dll` before TheRock's (llama.cpp#26929): prove it serves TheRock 10.1's hipBLAS, or
      re-bundle TheRock's three runtime DLLs and the byte-identity check that went with them.

- [ ] **CON56 — ripgrep in the images** [S, ★★]. Owner rule 2026-10-05: search with `rg`
      in every repo of the family (`AGENTS.md` § *Searching the tree*). In source the same
      day: `setup-package-image.sh` adds `ripgrep` beside jq/Xvfb (and `rg` to the presence
      check), and `Install-ScoopTools.ps1` adds `main/ripgrep` to the floating tools. Done
      when a published `:latest` (all three arches) and `:winamd64` answer `rg --version`.
      **The Windows half is done:** the `:winamd64` published 2026-10-06, built from hub
      f4c0e2be, answers `ripgrep 15.2.0`. **The Linux half is open:** the published `:latest`
      (`sha256:6ceffedc`) still has no `rg` on amd64 or arm64, and waits on a Linux rebuild.

- [ ] **CON72 — the 2026-10-07 Renovate bumps reach a published image** [L, ★★]. In source on
      2026-10-07 (CHANGELOG): LLVM 23.1.3, Rust 1.99.0, CPython 3.14.8, CMake 4.4.4, uv 0.12.23,
      TVM v0.27.0, IREE v3.12.0, GenAI v0.17.0, LiteRT-LM 0.18.0 (protoc 36.1), PyAV 19.0.1,
      torch 2.14.1/torchvision 0.29.1, llama.cpp b11460 (since b11476, CON82), Ollama 0.40.0, Flutter 3.47.6, cuDNN
      9.27.0.42 and the tool pins. Every hash was checked, and the patches were applied to the new
      sources. What only a chain can prove:
      - **TVM v0.27.0** is 141 commits past the proven `994e0216`, built by GCC 16 and clang-cl
        23.1.3. Its tvm-ffi bump changes how the arm64 and riscv64 ffi wheels find Python.
      - **IREE v3.12.0** bundles LLVM 24.0.0git, and the cross builds (arm64 clang-cl, riscv64)
        meet a new async proactor, the local-task executor and new tools. OrchestrANT's lock carries
        iree-base-compiler/runtime 3.12.0 since c33edb3 (a 3.12 runtime does not load a 3.11 VMFB).
      - **GenAI v0.17.0** is a 487-file refactor, on GCC 16, clang-cl and nvcc. On Windows,
        configure needs `nuget.exe` on the media-core `PATH`, DirectML/D3D12/DXC restore unhashed
        from nuget.org, and `D3D12Core.dll` must land beside the DLL.
      - **LiteRT-LM 0.18.0** (Windows, Bazel) adds WORKSPACE repos (rules_go, gazelle, rules_android
        0.7.0, whose toolchain names `@androidsdk`) and moves LiteRT to `26895c9f` under MSVC. The
        rocm GPU path now loads `webgpu_dawn.dll`, which only the rocm check's load probe proves.
      - **LLVM 23.1.3** rebuilds both toolchains, and the Windows patched LLVM.
      - **PyAV 19.0.1** against FFmpeg n9.0.2, with Cython ≥ 3.3.
      - **torch 2.14.1**: the riscv64 source build and the Windows rocm source build at the new
        commits. OrchestrANT's lock (APP_REF=develop) must carry the same pair, or the torch
        stage's pin check stops.

      Found during the bump, older than it: `Build-TvmFromSource.ps1`'s cross path versions the
      win-arm64 `apache_tvm` wheel with `TVM_COMMIT`'s hash, which is not PEP 440 and makes
      `tvm\_version.py` invalid Python. It has been live since `TVM_COMMIT` reached Windows
      (2026-08-28); no arm64 gate imports tvm. Done when a published `:latest` (all arches),
      `:winamd64` and `:winarm64` built from this hub pass their smokes.

      **OrchestrANT's Linux x64 and arm64 lanes are red until then** (c33edb3, run
      37597200372): its hub pin carries `PYTHON_VERSION=3.14.8`, and `python-app-bundle.sh`
      asks the published image's uv 0.12.17 for a 3.14.8 runtime it does not know (`No download
      found for request: cpython-3.14.8-linux-x86_64-gnu`). uv 0.12.23 in the next `:latest`
      serves it. Lesson: a consumer's pin bump that moves `PYTHON_VERSION` or `UV_VERSION` waits
      for the image.

      **Once the images are published, every consumer moves its hub gitlink**, and these wait on it:
      - **OmniAccelerANT**: its local lock-maintenance commits (go_router 18.0.2, sqlite3 3.7.0 with
        `web/sqlite3.wasm`; CON84) go with the bump, and `check-rust-toolchain.sh` then grades rustc 1.99.0.
      - **OrchestrANT**: the riscv64 packaging fix (sysroot libc, 2026-10-07) arrives with it. Its cp314t
        wheel needs the image's `3.14t` (CON66); `free-threaded-wheel: off` (CON77) is the interim switch
        should the pin have to move first.
      - **BeschleunigerBallett**: drop its local sccache override and its format counter, which the
        hub's guarded launcher and the pinned clang-format replace.
      - **AccelerANTgine**: `scan-build-21` → `scan-build` (CON71 wires the pinned LLVM's tools).
      - **OxidANT, WebDavClient, DocumANTation, ANThology**: the gitlink only.

## Open — Linux image (all arches)

- [ ] **CON65 — cargo-audit, cargo-deny and cargo-tarpaulin in the image** [M, ★★]. Owner rule
      2026-10-06: what a lane needs goes into the image. Every OxidANT run `cargo install`ed all
      three from crates.io. In source the same day:
      - The package stage installs them on amd64 and arm64 from their upstream release binaries,
        SHA-pinned in `versions.env` beside the versions (`install_cargo_qa_tools`).
      - riscv64 ships none: no upstream binary, and its lanes cross-build on amd64.
      - The smoke table's `cargo-qa-tools` row compares each binary's version with its pin.
      - `cargo_security_checks.sh` and `cargo_coverage.sh` build a tool only when the pinned
        version is not on `PATH` (`cargo_install_pinned`).
      - Docs: `docs/consumer-image-contract.md` § The cargo QA tools.
      **Order matters, and it holds:** OxidANT's hub pin had to reach this commit before a
      `:latest` with the tools publishes, because the old scripts' `cargo install` fails on a
      binary cargo did not install. OxidANT pins cef76510 since 5381dc1a (2026-10-06). Done
      when a published `:latest` passes the row on amd64 and arm64.
- [ ] **CON66 — a pinned free-threaded Python in the image** [S, ★★]. Every `3.14t` leg
      (OrchestrANT, WebDavClient) had uv download a free-threaded interpreter per run, its patch
      version unpinned. Since 2026-10-07 (owner decision) the toolchain stage builds it from the
      `PYTHON_VERSION` tarball (`build_python.sh`, `PYTHON_VARIANTS=gil,freethreaded`), natively
      and per cross arch, and the package stage COPYs
      `/opt/python-cross-ft/<arch>/opt/python-freethreaded` to `/opt/python-freethreaded`
      (`docs/consumer-image-contract.md` § The free-threaded Python). Proven in `:latest`
      containers: every arch's tree passes the row. Open, only a published chain proves it:
      - the toolchain → media → android → package chain builds in cross AND native mode, with
        BuildKit expanding `${TARGET_ARCH:-${TARGETARCH}}` in the COPY;
      - the toolchain stage's added time on the CI runners (estimate 25-40 min on 4 cores);
      - a native arm64 toolchain build (PGO on arm64);
      - a published `:latest` passes `free-threaded-python` (prefix check included) on amd64,
        arm64 and riscv64, and the consumers' `3.14t` legs stay green on it.

- [ ] **CON71 — every LLVM tool is the pinned release, on Linux and Windows** [M, ★★]. Owner
      decision 2026-10-06, reversing CON15's "clang-format and llvm-config stay 21". Measured on
      the published images the same day:
      - `:latest` (amd64 and arm64): 86 unversioned `/usr/bin` LLVM names were LLVM 21, among
        them `clang-format`, `clang-tidy`, `clang-cl`, `llvm-config`, `llvm-cov` and `ld.lld`. Only
        `PATH`'s `/usr/local/bin` links reached 23.1.1.
      - `:winamd64`: IREE's `clang`, `llvm-link` and `FileCheck` (23.0.0git) and the MSVC
        `llvm-symbolizer` (23.0.0git) came first on `PATH`.

      In source the same day:
      - `wire_pinned_llvm_tools` diverts every unversioned distro LLVM name to the pinned tree or
        off `PATH`.
      - `llvm-cross.sh` builds lldb and installs the utilities, so lldb, `FileCheck`,
        `yaml2obj` and `llvm-tblgen` exist at 23.1.1. This rebuilds the toolchain stage on all
        three arches.
      - `validate-compilers.sh smoke` grades 26 tools against `LLVM_RELEASE` and fails any
        distro name under an unversioned `/usr/bin` name.
      - Windows: the entrypoint puts `C:\llvm-patched\bin` first, `Build-LlvmFromSource.ps1`
        installs the utilities, and `Test-Container.ps1` checks 21 tools against clang-cl.

      Proven before the chain:
      - The wiring on a throwaway `:latest`: every existing tool reports 23.1.1, and a reinstall
        of the distro packages keeps the wiring.
      - A configure of llvm-project 23.1.1 with the new flags installs all 13 missing names.
      - On `:winamd64`, the new entrypoint leaves only IREE's `FileCheck` off the pin.

      Done when a published `:latest` and `:winamd64` pass both gates. Then:
      - AccelerANTgine switches `scan-build-21` to `scan-build`;
      - each consumer re-runs its formatter under clang-format 23 and commits the result.
      Measured the same day: AccelerANTgine's 38 C++ files drift in 25 under clang-format 21 and
      26 under 23, the native plugin's 26 files in 25 under both. Neither gates C++ formatting, so
      the switch reds nothing there; BeschleunigerBallett's sweep already uses 23.
- [ ] **CON58 — the Android Rust target in the image** [S, ★★]. Cargokit builds an
      Android app's Rust for `aarch64-linux-android`. `:latest` carried std for
      aarch64/riscv64/wasm32/x86_64 only, so OmniAccelerANT's Android lane added the
      target on every run (about 4 s, measured 2026-10-05, and a network dependency).
      In source the same day: `install-rust.sh` adds it to the pinned toolchain, and
      `smoke-toolchain.sh` fails an image where it does not emit an object. Done when a
      published `:latest` lists it under `rustup target list --installed` on all three
      arches.

- [b] **CON57 — mold in the image, only once it earns it** [S, ★]. `KATAGLYPHIS_LINKER=mold`
      (2026-10-05, `lib/linker-select.sh`) fetches the pinned mold 3.0.0 on first use. Baking
      it in (an `install_mold_pinned` beside `install_sccache_pinned`, apt's 2.40.4 cannot link
      AccelerANTgine) is open on two conditions. 3.x must have had a point release: 3.0.0 is
      the Rust rewrite, published the day the switch landed. And some build must link
      faster with it than with lld: none measured did (`docs/shared-script-libraries.md`
      § *linker-select.sh*), BeschleunigerBallett included (2026-10-06: 0.32 s against
      lld's 0.20 s for its `commitTestSuite` Debug relink). Re-checked 2026-10-07: rui314/mold's
      newest release is still v3.0.0 (2026-10-05).

- [b] **CON44 — `LP_NATIVE_VECTOR_WIDTH=256` in the image** [S, ★★]. Mesa 26.0.8's lavapipe
      compiles its BVH radix sort for 8-lane subgroups, but llvmpipe's subgroup is its vector
      width / 32: 4 lanes on arm64 NEON and riscv64, where every acceleration-structure build
      SEGVs (BeschleunigerBallett run 36746313937; detail in `docs/failure-modes.md`). The
      image sets `ENV LP_NATIVE_VECTOR_WIDTH=256`, and the `:latest` published 2026-10-01
      proves it in all three children (`check_lavapipe_subgroup`: 8 lanes on amd64, arm64 and
      riscv64), and BeschleunigerBallett's `run-ctest.sh` no longer exports its own. Open:
      - Retire the `ENV` once the image's Mesa has upstream ebcfbe60 (2026-08-22), which
        deletes that sort. **No Mesa release carries it yet** (checked 2026-10-07 against the
        tags: 26.2.4, the newest, lacks it), so it arrives with 26.3, and in the image only
        when Ubuntu's `mesa-vulkan-drivers` moves to it. Sooner means a source-built lavapipe
        with ebcfbe60 cherry-picked, an owner decision.
      - **Its cost on arm64, seen 2026-10-05:** at 256 bits, llvmpipe's LLVM 21.1.8 on
        AArch64 sometimes fails instruction selection and aborts the process. The error is
        `LLVM ERROR: Cannot select: v4f32 = bitcast … extract_subvector … In function:
        fs_variant_partial`. That reds OxidANT's arm64 renderer tests intermittently:
        `forward_ambient` in run 37354297722, `headless` in run 37005853556. 9117d46 passed
        on the same image three hours before the first of those, and no amd64 run has
        shown it. Until ebcfbe60 lands, check that the
        crash is gone before calling a red arm64 renderer test a regression. A narrower
        `ENV` (only the BVH build needs the 8-lane subgroup) would also avoid it. The consumers
        that build no BVH narrow it themselves since 2026-10-06: OxidANT's
        `ci-container-steps.sh` (c8637e5) and BeschleunigerBallett's `run-cargo-tests.sh`
        export 128 on aarch64. Four of about twenty OxidANT arm64 runs since 2026-10-05 had
        died on it, one as a SIGSEGV in `forward_ambient` rather than an `LLVM ERROR`.

- [ ] **CON53 — BuildKit cache housekeeping on the build host** [S, ★]. Both causes found and
      fixed in the source on 2026-10-01 (CHANGELOG; `docs/build-cache-tiers.md` § 3.2.1,
      `docs/linux-host-setup.md` § B7): `--keep-storage` bounds the whole store, so the keep
      value now adds the cache mounts; and BuildKit's non-blocking `sharing=shared` lookup
      makes a second record when the first is locked mid-release, which `prune-safe.sh` now
      lists. Left: remove the 52 GB of surplus records (six ids; `/uv-cache-riscv64` 25.9 GB)
      with `PRUNE_DUP_CACHEMOUNTS=1 linux/host-config/prune-safe.sh` once no chain holds the
      store; it refuses while one does.

## Open — Linux arm64 and riscv64

- [b] **CON70 — a riscv64 Flutter engine, for OmniAccelerANT's riscv64 lane** [L, ★]. CON48's
      riscv64 consumer lanes (OxidANT, AccelerANTgine, BeschleunigerBallett) cross-build on
      amd64 and test under QEMU since 2026-10-01. OmniAccelerANT has none, because no image
      carries a riscv64 Flutter. Checked 2026-10-06:
      - Flutter publishes no `linux-riscv64` engine or tool artifacts; flutter/flutter#99963
        is open.
      - Community builds exist: meta-flutter's Yocto recipes (riscv64 engine, `gen_snapshot`,
        a newer LLVM than Flutter's stable one) and KDAB's industrialflutter port.
      Either way is an owner decision: an engine built from source in the image (our own pin,
      hours of chain time per Flutter bump) or a third-party engine binary. Until then
      OmniAccelerANT's riscv64 coverage is OxidANT's and AccelerANTgine's own lanes.

## Open — Windows `:winamd64`

- [b] **CON27 — MSVC STL 14.51 breaks `find`/`count`/`remove` on odd-sized structs
      under clang-cl** [S, ★]. Blocked upstream (checked 2026-10-02): microsoft/STL#6294
      is open, its fix #6298 awaits review, and neither 14.52 nor 14.53 Preview carries it.
      The toolset is VS 18's stable channel, not a pin that could move.
      BeschleunigerBallett's `find_if` stands (a2793e6c). Never set
      `_USE_STD_VECTOR_ALGORITHMS=0` image-wide: it turns every vectorized algorithm off.
      Close when a production toolset ships #6298.
- [b] **CON54 — Let the litert-lm CMake superbuild consume the already-built LiteRT
      install** [M, ★★]. The hub flow builds LiteRT (bazel, `LITERT_VERSION=v2.2.0` =
      145c7523, 2026-08-06) and then litert-lm's superbuild builds LiteRT a SECOND time
      from `litert.cmake`'s `GIT_TAG main` — two different copies in one product, both
      floating (v0.17.1's WORKSPACE pins 9fe5be45, 2026-08-27, 3 weeks NEWER than the
      prebuilt). The harness already sends `CMAKE_PREFIX_PATH=C:\runtime\lib\litert`
      but the lane has no consumer for it: the top-level orchestrator is LANGUAGES NONE,
      and litert.cmake defines litert_external unconditionally (its "already installed"
      message prints on every path; the only skip fallback sits behind a FATAL_ERROR
      else-branch). Upstream-PR-shaped feature: a `LITERTLM_LITERT_PROVIDER=installed`
      (or honored prefix) that keys the aggregate/target-map/include-paths at the
      installed tree instead of the EP build dir. Side value: it removes the litert EP
      from the graph — the chunk where google-ai-edge/LiteRT#tensor/examples
      (gemma3's find_package(Protobuf REQUIRED)) fires, and the largest slice of the
      superbuild's wall time. The direct-consumption build is also the sharpest
      API-skew probe: if v2.2.0 lacks what litert-lm's sources use, the compile fails
      with the missing member visible. Repro: litertlm-harness runs 1-19, Oct 4 2026.
## Open — the Windows arm64 bundle and unpublished variants

- [ ] **CON64 — the Vulkan validation layer in `C:\runtime\vulkan-layers`** [S, ★★]. Owner rule
      2026-10-06: what a lane needs goes into the image, not into a CI step. BeschleunigerBallett's
      Windows arm64 GPU suites ran unvalidated, because the image's SDK has an x64 layer only and
      LunarG's ARM64 SDK installer runs only on ARM64. In source the same day: the merge stage
      builds the layer for arm64 from Khronos sources at `vulkan-sdk-<VULKAN_VERSION>` and copies
      the SDK's for amd64 (`Build-VulkanValidationLayers.ps1`, `docs/windows-cross-builds.md`
      § The Vulkan validation layer). `Test-Arm64Bundle.ps1` loads it when the bundle carries it.
      Done when a published `:winarm64` passes that step; then raise the gate's floor to 13 and
      fail a bundle without the layer. BeschleunigerBallett's `-StageTests` already stages it
      from there on both arches (BB 17aa94ff) and warns until the bundle carries it.
- [ ] **CON67 — the test runner's wheels in the `:winarm64` wheel store** [S, ★]. OrchestrANT's
      `Stage-Arm64Tests.ps1` installed pytest and six plugins (cov, benchmark, md, md-report,
      html, requests) for win_arm64 from PyPI at cross-build time, versions unpinned. In source
      2026-10-06:
      - `versions.env` pins the 31 cp314 wheels by URL and SHA256 (`PYTEST_WINDOWS_ARM64_*`),
        the versions OrchestrANT's lock runs on x64; jinja2 and setuptools are the torch stack's.
      - `Copy-Arm64TorchWheels.ps1` stages them beside the torch stack, and the three native
        ones pass `Assert-WheelTargetArch`.
      - `Test-Arm64Bundle.ps1` installs them offline and imports them, in a bundle that has them.
      - Docs: `docs/windows-cross-builds.md` § A consumer's test runner, pinned.
      Done when a published `:winarm64` passes that step on the device and OrchestrANT's
      `Stage-Arm64Tests.ps1` installs from the wheel store instead of PyPI.

- [ ] **CON63 — prove the WebRTC contract on the next arm64 chain** [S, ★★]. The
      2026-10-05 Windows WebRTC fixes (`docs/windows-builds.md` § libffi's type exports,
      § DTLS with OpenSSL 4, § gst-plugins-rs on Windows) were built and run on amd64
      only. On the cross lane four things have never run: the gst-plugins-rs cross build
      for `aarch64-pc-windows-msvc` (`Get-GstRustCargoPlan`'s target env), the host link
      without `/FORCE:MULTIPLE`, the native file's `c_args = ['-fcommon']` for the
      build machine's `ffi-7.dll`, and `Assert-LibffiTypeExport` on an aarch64 DLL. The
      first arm64 merge either passes them or names the failing crate or symbol. Then
      run the WebRTC loopback on the Snapdragon device through `Test-Arm64Bundle.ps1`,
      which has no WebRTC step yet.
- [b] **CON30 — The `:winarm64` bundle** [L, ★]. Blocked on hardware and owner
      decisions.
      - The aarch64 ASan runtime ships in the bundle since 2026-10-03: VS 2026's MSVC
        toolset carries clang_rt.asan_dynamic-aarch64.dll (+ the dbg twin), the merge
        stage stages both into C:\runtime\bin, the arch gate machine-checks them and
        Test-Arm64Bundle.ps1 asserts the runtime on the device.
      - The CUDA payload now also stages nvrtc and cupti (13.4.92, SHA-pinned, 2026-10-03)
        for consumers that compile kernels at run time or profile; nvtx is header-only on
        windows-arm64, so there is nothing to stage for it. The payload still needs an
        arm64 CUDA device to prove it runs.
      - No LiteRT QNN dispatch (#155: five upstream defects, documented 2026-08-31 at the
        pinned v2.2.0; upstream main still fetches QAIRT unhashed, so a pin bump alone
        would not fix it).
      - Absent by construction: the TVM/IREE compilers, LiteRT-LM, the torch
        stage (its cp313 win-arm64 wheel stack - torch 2.14.0+cpu, torchvision,
        the first-touch deps - ships in the wheel store since 2026-10-03, SHA-
        pinned; upstream builds no cp314 wheel the bundle's own interpreter
        could use), Flutter, classic TensorRT, TAPPAS.
      - The bundle EXECUTES on hardware since 2026-10-03 (Snapdragon X, summy-server; the
        gate is `windows/scripts/build/Test-Arm64Bundle.ps1`, nine steps, floor nine):
        HailoRT-CLI 5.4.0, GStreamer 1.29.2 (`gst-inspect` + a videotestsrc->fakesink
        pipeline), `iree-run-module`, and the bundle's own Python 3.14.7 importing
        numpy 2.5.3, onnxruntime 1.30.0 (DmlExecutionProvider + CPUExecutionProvider),
        av 18.1.0 and cv2 5.0.0 - the wheels installed offline from its store.
      - The gate runs per push since 2026-10-03: a cross lane that sets `bundle-artifact-name`
        packs `C:\runtime` in the build job and the `windows-11-arm` job runs
        `Test-Arm64Bundle.ps1` over it ([`docs/windows-cross-builds.md`](docs/windows-cross-builds.md) - Verification).
      - Still unproven on a device: an inference, a camera/plugin pipeline, and the
        consumer run jobs' apps (those jobs loaded the bundle's DLLs only; runs
        36136967538, 36142875090, 36142882316).
- [b] **CON31 — Variants that are not published** [L, ★]. Blocked on owner decisions.
      - `:latest-nvidia`: no `libnvinfer` in the runtime payload, and no arm64 route. Published
        for amd64 since 2026-10-02 (hub b4d5fdd5); whether that payload has `libnvinfer` is
        unchecked.
      - `:latest-rocm`: the wrapper lacks `ROCM_PATH`/`HIP_PATH` and cannot open
        the device as shipped.
      - `:winamd64-rocm`: published (first 2026-09-28 at ad08bc30, again 2026-10-03 at
        1d910553); the redistribution decision is recorded in `docs/windows-rocm.md`
        § Redistribution.

      Sources: `docs/linux-accelerator-images.md` and `docs/windows-rocm.md`.
- [ ] **CON42 — DeepStream in `:latest-nvidia`** [L, ★★]. Owner request 2026-09-30. Spike
      (phases 1–3) done 2026-10-01, the GPU gate passed the same day; phases 4 and 6 are in
      the source. **Owner decision 2026-10-07: DeepStream is in every amd64 nvidia build, at
      full size** (TensorRT 10's builder resources for every GPU generation stay, so the RTX
      2080's sm_75 keeps working). `stage-defs.sh` defaults `ENABLE_DEEPSTREAM=true` for an
      amd64 nvidia chain; `=false` opts a run out. One thing left:
      1. **The next nvidia variant chain run**, which now builds it without being asked. Started
         2026-10-01 21:34 (amd64, from `gpu`, hub 629afe5d); done when `:latest-nvidia` is
         published with `check_deepstream` green. The `:latest-nvidia` published 2026-10-02
         (hub b4d5fdd5, amd64 `95c3a343…`) is not that run: its build args carry an empty
         `ENABLE_DEEPSTREAM` and its `USE_NEW_NVSTREAMMUX` is empty. Until then everything
         below was proven in throwaway containers FROM the published `:latest` amd64 child
         plus the variant's CUDA install. It is also the first build of
         the GPU run's three fixes in a chain. GStreamer and libcamera without libunwind are in
         every variant by owner decision (2026-10-01, "everywhere"): the `:latest` published
         2026-10-01 proves it in all three children (no shared object under `/opt` or
         `/usr/local` needs `libunwind.so.8`), and so does the `:latest-rocm` of 2026-10-02
         (CON51, closed).

      Measured 2026-10-01 (DeepStream v9.1.0, commit 581889df; runtime
      `deepstream-binaries-x86_9.1.0_amd64.deb`; GStreamer 1.29.2; CUDA 13.4.2; GCC 16.2):
      - **Phase 1 — passes.** 48 source components build against `/opt/gstreamer`; all nine
        checked elements register without a GPU. Fixes, exclusions and the soname closure:
        `docs/linux-accelerator-images.md` § DeepStream.
      - **Phase 2 — passes on the GPU** (RTX 2080, sm_75, driver 595.58.03, CDI with rootless
        nerdctl): TensorRT 10.16 builds the sample engine for sm_75, NVDEC decodes through the
        distro `libv4l2`, and decode → `nvstreammux` → `nvinfer` → `nvtracker` →
        `nvmultistreamtiler` → `nvdsosd` (GPU mode) runs with detections and tracker ids in the
        metadata, as root and as uid 1001. `nvstreamdemux` and `nvurisrcbin` run too. TensorRT 10
        sits beside the variant's 11 (`ENABLE_TENSORRT` stays false; DeepStream does not need it).
        Pass/fail only; the licence forbids publishing benchmark results.
      - **Phase 3 — passes.** NVIDIA's CUDA 13.2 builds (`libnvbufsurftransform`, the tracker,
        TensorRT 10.16) run their sm_75 kernels on CUDA 13.4.92.
      - **The GPU run found four defects, all fixed in the source** (doc § The GPU run): the
        builder resources TensorRT `dlopen()`s by file name need links in the default lib dir;
        NVDEC needs NVIDIA's plugin linked into the distro `libv4l2`'s plugin dir; NVIDIA's
        prebuilt legacy `nvstreammux` reads `GstMapInfo.data` after unmap, which GStreamer
        ≥ 1.28 clears, so the image sets `USE_NEW_NVSTREAMMUX=yes`; and `libunwind.so.8`, linked
        by GStreamer core and libcamera, turned an exception through `std::call_once` into a
        segfault (`docs/failure-modes.md`).
      - **Phases 4 and 6 — in the source.** `05-frameworks/deepstream.sh` (media stage `build`,
        package `stage-runtime` / `assert-absent`), `deepstream-verify.sh` (closure, one
        GStreamer, no `libv4l2` hijack, the two `dlopen()` links, plugin dir, registration; also
        `check_deepstream` in the runtime smoke), `DEEPSTREAM_*` pins with SHA256s, the
        `ENABLE_DEEPSTREAM` refusals outside the nvidia variant, `test-deepstream.sh` and 22
        `deepstream.*` mutation entries.
      - **Phase 5 — decided**: the owner allowed publishing it (doc § Licence).

      Still to do:
      - Other prebuilt NVIDIA plugins may read `GstMapInfo` after unmap like the legacy mux.
        The GPU run exercised `nvvideoconvert`, `nvv4l2decoder`, `nvmultistreamtiler` and the
        tracker; `deepstream_bins`, `dewarper`, `of`, `segvisual` and the rest were not run.
      - Size: TensorRT 10 alone is 2.6 GB (builder resources for every GPU generation). Kept
        whole by owner decision (2026-10-07).
      - **Phase 7 (arm64)**: out of scope until CON31 has an arm64 CUDA route. The Jetson
        runtime `.deb` is pinned (`DEEPSTREAM_BINARIES_ARM64_SHA256`); nothing installs it.
      - **Phase 8**: `consumer-image-contract.md` names (`DEEPSTREAM_ROOT`, the plugin link,
        `USE_NEW_NVSTREAMMUX`) and OmniAccelerANT's `nvinfer` path, after a published image exists.
      - Renovate reports `DEEPSTREAM_VERSION` (github-releases, report-only). The v9.1.0 release
        also hosts 9.1.1 assets for NVIDIA's `develop` branch; the pin stays on 9.1.0.

## Open — hub tooling and the dev host

- [b] **CON69 — 23 hub files declare Apache-2.0 under the hub's MIT `LICENSE`** [S, ★]. Owner
      decision needed (2026-10-06). The hub has carried an MIT `LICENSE` since 709756eb
      (2026-08-02), but 23 files outside `third_party/` still say
      `SPDX-License-Identifier: Apache-2.0`, most of them under `windows/scripts/`
      (`rg -l 'SPDX-License-Identifier: Apache-2.0' --glob '!third_party/**'`). Moved here from
      BeschleunigerBallett's closed LICENSE row. Either relicense the 23 to MIT (one header line
      each), or record why they stay Apache-2.0 in `docs/third-party-licenses.md`.
- [b] **CON62 — WSL containers (`wslc`) as the local Linux engine** [M, ★★]. Blocked
      upstream. Evaluated 2026-10-05 against WSL 3.0.1
      (`docs/rancher-desktop-linux-containers.md` § *WSL containers*): faster bind
      mounts and no credential trap, but no `--privileged`, `--platform` or `--device`,
      which the lanes pass. Re-evaluate when microsoft/WSL#41545 (privileged/cap-add)
      and #41123 (multi-platform) land. The Dart-only pilot is in: OmniAccelerANT
      7775b51, `Invoke-DartChecks.ps1 -Engine wslc`, analyze 146 s against nerdctl's
      371 s, format + test 23 s against 32 s (2026-10-06).
