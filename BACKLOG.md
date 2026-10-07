# Backlog — image gaps

Every known gap in the images this hub publishes (`:latest`, `:winamd64`, the
`:winarm64` bundle) that a consumer lane hits or works around. The refactoring
registers stay in [`docs/refactoring-backlog.md`](docs/refactoring-backlog.md).
The CON1–CON6 prefix history is in
[`…-archive-2026-09-17.md`](docs/refactoring-backlog-archive-2026-09-17.md).

**State 2026-10-05**, read from the registry (hub = the image's `revision` label, digest =
the per-arch manifest). Published: `:latest` (2026-10-03, hub b4d5fdd5; amd64 `686fdf4e…`,
arm64 `26957741…`, riscv64 `67887737…`), `:winamd64` (2026-10-04, hub 9ecb2503,
`65c0dc1f…`), `:winamd64-nvidia` (2026-10-02, hub 7a5a2a33, `a9e67332…`),
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
      Cython wheel at all (CON74 brings its interpreter). Done when both ship a wheel proved on
      the target.
- [ ] **CON76 — a real cp314t proof in the hub suite** [S, ★]. Once `:latest` ships `3.14t` on
      every arch (CON66), `test-python-free-threaded-wheel.sh` builds two tiny C extensions (one
      declaring free-threading support, one not) and runs `prove` for real instead of a stubbed
      interpreter.
- [ ] **CON77 — a workflow input for `PYTHON_FREE_THREADED_WHEEL`** [S, ★]. Today a consumer
      can switch the free-threaded wheel off in CI only by dropping its classifier.
- [ ] **CON74 — a free-threaded CPython for Windows arm64, so its 3.14t legs stop downloading**
      [M, ★]. Since 2026-10-07 `:winamd64` builds `python3.14t.exe` beside the GIL build
      (`C:\python-freethreaded`, windows-builds.md § *The free-threaded CPython*). The arm64
      bundle carries only the GIL target interpreter (`C:\runtime\python`,
      `Build-TargetCpython.ps1`). Two halves:
      1. `Build-TargetCpython.ps1` runs `Invoke-CpythonPcbuild -Platform ARM64 -FreeThreaded
         -ExtraArguments '"/p:PreferredToolArchitecture=x64"'` after the GIL build and stages
         `PCbuild\freethreaded\arm64` into `C:\runtime\python-freethreaded`. Its staging block
         (PE-machine gate, host-arch CRT replacement, the vcruntime140_1 drop, headers, Lib, empty
         site-packages, DLL-directory shim, ensurepip check) becomes one function both trees
         call, with `Select-CpythonImportLib -FreeThreaded`. Write-BundleManifest and the merge
         gate then cover the new directory.
      2. python-ci-windows.yml's arm64 job runs on the bare runner, without an image, so
         `Invoke-PythonTestLegs.ps1 -InstallUv` still has uv download a python-build-standalone
         3.14t. The job must take its interpreter from the bundle, or from a published
         free-threaded artifact, before half 1 removes any download.

      Done when a windows-11-arm `3.14t` leg passes with `UV_PYTHON_DOWNLOADS=never` and the
      device smoke reports `sys._is_gil_enabled() == False` for the bundle's `python3.14t.exe`.
- [b] **CON73 — ROCm 10.0 → 10.1 (TheRock `therock-10.1`, 2026-10-05)** [M, ★★]. Renovate
      reports it since its annotation reads `versioning=loose` (2026-10-07). Blocked upstream:
      - **No llama.cpp build ships a `win-rocm-10.1` zip.** All builds through b11461 ship
        `rocm-10.0`, and llama.cpp's `release.yml` still sets `ROCM_VERSION: "10.0.0"`.
        `Install-LlamaCpp.ps1` refuses a 10.0 asset on a 10.1 image, and
        `rocm-checks\LlamaCpp.ps1` requires its HIP DLLs byte-identical to the image's.
      - **MIGraphX 2.18.0 has no `rocm-10.1` tag yet.** Only the branch
        `release/rocm-rel-10.1` exists (`95672916`, 2026-09-29). On Linux the 10.1 package is
        renamed `amdrocm10-migraphx`. `Build-MigraphxFromSource.ps1` needs the commit's tree
        version to equal `MIGRAPHX_VERSION`. The branch already contains 5a80dc91ba, so
        `001-mlir-off-stubs.patch` goes with the bump.
      - **Owner decision:** wait for both (one bump), or Linux now with a separate
        `MIGRAPHX_WINDOWS_VERSION`.
      - **The Windows values are measured** (2026-10-07: full download, `sha256sum`, byte
        count equal to Content-Length). `PYTORCH_ROCM_INDEX` stays `rocm7.14`, because
        `rocm7.15`, `rocm10` and `rocm10.1` all answer 403.

        | Key | Value |
        | --- | --- |
        | `ROCM_WINDOWS_TARBALL_SHA256` (10.1.0, 2,244,477,973 B) | `e8d5acd522aa106d685485707e5085d491ead7d0d84a79ef74dc5995941403b2` |
        | rocm-10.1.0.tar.gz (27,536 B) | `e6616e62ebd1324031681e6e59349d46ee4f143a8d8f4f901a91c35c993041fc` |
        | rocm_sdk_core-10.1.0 (776,978,384 B) | `b12f1c4cde14ed1cd8864006d17586c6b1e6a4e4695b9597cfe04ed7715e952f` |
        | rocm_sdk_libraries-10.1.0 (118,645,973 B) | `0c34bafbb4aa626cc710d8b130bb314f591194c3d79eeb5892b755ea0be06159` |
        | rocm_sdk_device_gfx1201-10.1.0 (314,133,708 B) | `56085e8f865b6b96c230fe8d1731074103553d0d958a31be13907d01e558fd0e` |
        | rocm_sdk_device_gfx1200-10.1.0 (378,463,821 B) | `8b670bee24ca4fc6c13c1eb58e9c6c39929913107ce00a8661c4db9d3e39d9fa` |
      - **Files that move with it:**
        - ARG defaults: `linux/Dockerfile.amd`, `windows/Dockerfile.{rocm,torch,rocm-llama,rocm-migraphx}`.
        - `Torch.Rocm.Tests.ps1:223-228` hard-codes `10.0.0` and `10.1.0`; derive the release from `$pins`.
        - `docs/deps/deps.json`, `sbom-curated.spdx.json`, `third-party-licenses.md`, the web
          licence pages, `docs/windows-rocm.md`.

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
      torch 2.14.1/torchvision 0.29.1, llama.cpp b11460, Ollama 0.40.0, Flutter 3.47.6, cuDNN
      9.27.0.42 and the tool pins. Every hash was checked, and the patches were applied to the new
      sources. What only a chain can prove:
      - **TVM v0.27.0** is 141 commits past the proven `994e0216`, built by GCC 16 and clang-cl
        23.1.3. Its tvm-ffi bump changes how the arm64 and riscv64 ffi wheels find Python.
      - **IREE v3.12.0** bundles LLVM 24.0.0git, and the cross builds (arm64 clang-cl, riscv64)
        meet a new async proactor, the local-task executor and new tools. **OrchestrANT's lock
        must move iree-base-compiler/runtime to 3.12.0 first**: a 3.12 runtime does not load a 3.11
        VMFB, so arm64's `check_iree_native` would fail.
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
