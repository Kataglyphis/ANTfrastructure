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

- [ ] **CON50 — Every test on every arch lane** [L, ★★★]. Owner goal 2026-10-01. A read-only
      audit of the six consumers that day (latest green develop runs) found Linux arm64 at
      parity with Linux x64 everywhere. The gaps are the Windows lanes, suites that run on no
      lane, and one narrowing:
      - **OxidANT:** Windows x64/arm64 run 167 tests to Linux's 358. The renderer integration
        tests, `kataglyphis_inference` and `kataglyphis_telemetry` are missing. (Closed
        2026-10-01, OxidANT fe14359: every Linux and Windows lane runs the same 360 tests. Its
        arm64 parallel WARP crash is in its BACKLOG.)
      - **BeschleunigerBallett:** no GPU suites (40) or perf suite on Windows. Windows arm64 is
        Release-only.
      - **AccelerANTgine:** its suites were placeholders, so 0% of `Src/` is covered on every
        arch.
      - **OmniAccelerANT:** the plugin's Dart tests and gtest and the integration test run
        nowhere. The web lane never tests in a browser, and Android only on the x64 VM.
        (Closed apart from the browser: the plugin suites run on every lane since 2026-10-01
        (530ad8f), the integration test under Xvfb on Linux and through `flutter drive` on
        Windows x64 and arm64 since 2026-10-04/05 (80e5329, 8015371). The Chrome run is open
        in its BACKLOG.)
      - **OrchestrANT:** Windows arm64 runs none of the 959 pytest tests. The benchmark lab
        suites run on Linux x64 only.
      - **WebDavClient:** `tests/unit` holds 3 dummy tests, and the 6 WebDAV tests ran nowhere.
        There is no Windows arm64 lane.
      - **Both Python repos:** `3.14t` ran 0 tests.

      Owner decisions the same day:
      - `3.14t` becomes a real leg.
      - The Windows GPU tests run now: OxidANT's wgpu suites on the runner host and on
        windows-11-arm, and BeschleunigerBallett's Vulkan goldens on a software rasterizer.
      - AccelerANTgine gets real tests.
      - Web tests run in Chromium, and Android tests on an emulator.

      The consumer work runs in each repo, tracked in its own BACKLOG.
      **Here:**
      1. Python lanes run the project's `testpaths` and gate a `3.14t` leg through
         `free-threaded-extras` (`docs/python-ci.md` § What the test leg runs). (Done
         2026-10-01.)
      2. `container-ci-windows.yml` takes a binary-free test tree and `Invoke-StagedTests.ps1`
         reads pytest, for OrchestrANT's arm64 suite. (Done 2026-10-01.)
      3. Chromium in `:latest` (`linux/Dockerfile.package`) for `flutter test --platform chrome`.
         **Published in the `:latest` of 2026-10-03** (hub b4d5fdd5; its config sets
         `CHROME_EXECUTABLE`): Chrome for Testing + chromedriver on amd64 and arm64 (none
         exists for riscv64). Proven on a throwaway
         image FROM `:latest`: OmniAccelerANT runs 37 tests in Chrome; two files need
         `@TestOn('vm')` (`docs/consumer-image-contract.md` § Browser tests).
      4. An Android emulator and arm64-v8a system image for OmniAccelerANT's APK. arm64
         runners have no KVM, so it runs as an x64 image with ARM translation or on another
         runner. Measure before choosing. **Measured 2026-10-01, published in the `:latest` of
         2026-10-03** (its history runs `install-android-emulator.sh`): an x86_64 API 35
         `google_apis` image on amd64 (API 30's translator SIGILLs on the APK); booted in 25 s
         with KVM and ran the arm64-v8a release APK. The consumer lane needs an x64 runner
         with `/dev/kvm` passed in.
      5. A software Vulkan ICD for Windows x64 and arm64 (Mesa lavapipe; WARP/Dozen lacks ray
         tracing). Ship it in the image or as a pinned, SHA-checked download; the consumers
         run the goldens with it. (Done 2026-10-04, CON50: `Install-Lavapipe.ps1` stages the
         SHA-pinned mmozeiko/build-mesa driver plus LunarG's arch loader into
         `C:\runtime\lavapipe`, the merge stage sets `LP_NATIVE_VECTOR_WIDTH=256`, the amd64
         image registers the ICD in HKLM, the bundle manifest and the gate's twelfth step
         carry the device half. `:winamd64` was republished the same day - the smoke's
       `vulkaninfo --summary` lists the llvmpipe device; the `:winarm64` bundle is published and its device gate passed 12/12 on the Snapdragon X (Windows 11 ARM64).)
      6. A native `windows-11-arm` Python job in `python-ci-windows.yml` for WebDavClient:
         `arm64-tests` and `Invoke-PythonTestLegs.ps1`. (Done 2026-10-01.) WebDavClient
         keeps py-spy and line_profiler off ARM64 (1f9bb5f) and runs the job since f7ed5d8
         (`windows-arm64.yml`, hub 625b3653).

- [ ] **CON55 — The hub pieces OxidANT waits on** [M, ★★]. Not an image gap. Seven rows in
      OxidANT's BACKLOG (§ Waiting on ANTfrastructure) are `[b]` there only because the other
      half is a hub change, and nothing here tracked them until 2026-10-05. Each was
      re-checked at hub 62487181 and is still undone:
      - `_cargo_wrapper.sh` gets the safe.directory guard that `lib/cmake-build.sh` has,
        behind a `CARGO_SAFE_DIRECTORY` knob (default `/workspace`), and the other
        `cargo_*.sh` drivers source it.
      - `Get-ANTfrastructurePin` moves from `windows/scripts/rust/Build-Windows.ps1` into
        `WindowsScripts.Shared.psm1`, so OxidANT can delete its `Resolve-CargoToolPin`.
      - **Owner decision:** `windows/scripts/rust/Build-Windows.ps1` has no consumer. Either
        make it callable (`-Features`, `-Package`/`-Bin`, no rustup or scoop calls) or
        delete it and record OxidANT as the owner of the Windows Rust build. Decide it with
        the row above.
      - An MSI function for an app that does not build through CPack: `-WxsFile -LicenseFile
        -ProductName -Manufacturer -ExeSource -Version -OutFile`, plus `-Arch` and the payload
        DLL list. OxidANT would be its only caller. The nearest model is the script-local
        `Invoke-MsiPackage` in `windows/scripts/python/New-PythonAppPackage.ps1`.
      - `windows/scripts/certificates/README.md` covers `TrustedPeople` only. The MSIX trust
        steps (`LocalMachine\Root` as well, `0x800B0109`, `Get-AppxLog`) move there from
        OxidANT's README.
      - `docs/adopting-in-a-new-project.md` § 8 names `scripts/windows/container/` as the
        place for scripts that run inside the Windows image.
      - The functions in OxidANT's AGENTS.md § 2 inventory are listed upstream (§ 2/8 of
        `docs/adopting-in-a-new-project.md` or `docs/INDEX.md`), so that table can become a
        link.

      Done when OxidANT has turned each row into a deletion and moved its pin.

## Open — Linux image (all arches)

- [ ] **CON44 — `LP_NATIVE_VECTOR_WIDTH=256` in the image** [S, ★★]. Mesa 26.0.8's lavapipe
      compiles its BVH radix sort for 8-lane subgroups, but llvmpipe's subgroup is its vector
      width / 32: 4 lanes on arm64 NEON and riscv64, where every acceleration-structure build
      SEGVs (BeschleunigerBallett run 36746313937; detail in `docs/failure-modes.md`). The
      image sets `ENV LP_NATIVE_VECTOR_WIDTH=256`, and the `:latest` published 2026-10-01
      proves it in all three children (`check_lavapipe_subgroup`: 8 lanes on amd64, arm64 and
      riscv64). Open:
      - BeschleunigerBallett drops its own export in `run-ctest.sh` (2ac0e785).
      - Retire the `ENV` once the image's Mesa has upstream ebcfbe60 (2026-08-22), which
        deletes that sort.

- [ ] **CON51 — `:latest-rocm` rebuilt with the 2026-10-01 media fixes** [M, ★★]. Owner
      decision 2026-10-01: GStreamer and libcamera without libunwind "everywhere". `:latest`
      carries it since 2026-10-01 (all three children pass the libunwind smoke), and
      `:latest-nvidia` gets it from the chain run CON42 is waiting on. `:latest-rocm`
      (2026-09-28, hub 1754a1dd) still links `libunwind.so.8` and lacks CON44's `ENV` and
      CON47's patch. Done when a `CROSS_VARIANT=rocm` chain publishes and its runtime smoke
      shows the three new checks green. A rocm chain republished it on 2026-10-02 (hub
      b4d5fdd5, amd64 `bdfcb731…`) and its config carries CON44's `ENV`; that chain's smoke
      verdicts for libunwind and CON47 are not checked yet.

- [ ] **CON52 — The torch stage installs the chain wheels once and proves them** [M, ★★].
      Measured in the 2026-10-01 `:latest` chain (amd64 and arm64): torch and torchvision come
      straight from OrchestrANT's lock (`torch pins satisfied`); `ai-edge-litert` and
      `onnxruntime-genai` were installed before `uv sync`, removed by it and installed again.
      **Fixed in source (2026-10-01):** `reconcile_local_wheels` is the one install point, and
      `assert_chain_wheels_installed` (`CHAIN-WHEEL FAIL`) proves every staged wheel is the
      venv's. Proven in a container FROM the published `:latest` amd64 child with that chain's
      `/opt/wheels` and OrchestrANT 7daaa3e6: no uninstall in the sync, each wheel installed
      once, `CHAIN-WHEEL PASS` + `ORT-CENSUS PASS`; a PyPI `onnxruntime-genai` 0.15.2 in place
      of the chain's fails the gate. OrchestrANT's lock stays on PyPI: routing a package to
      `/opt/wheels` makes `uv lock` fail off the image (`docs/linux-cross-builds.md` § The
      chain wheels and the app's lock). Ships with the next chain; done when its torch stage
      logs `CHAIN-WHEEL PASS` on amd64, arm64 and riscv64.

- [ ] **CON53 — BuildKit cache housekeeping on the build host** [S, ★]. Both causes found and
      fixed in the source on 2026-10-01 (CHANGELOG; `docs/build-cache-tiers.md` § 3.2.1,
      `docs/linux-host-setup.md` § B7): `--keep-storage` bounds the whole store, so the keep
      value now adds the cache mounts; and BuildKit's non-blocking `sharing=shared` lookup
      makes a second record when the first is locked mid-release, which `prune-safe.sh` now
      lists. Left: remove the 52 GB of surplus records (six ids; `/uv-cache-riscv64` 25.9 GB)
      with `PRUNE_DUP_CACHEMOUNTS=1 linux/host-config/prune-safe.sh` once no chain holds the
      store; it refuses while one does.

## Open — Linux arm64 and riscv64

- [ ] **CON48 — riscv64 consumer lanes: cross-build on amd64, test under QEMU** [M, ★★].
      Owner decision 2026-10-01: a consumer's riscv64 lane cross-compiles on the amd64 runner
      and runs only the tests under QEMU user-mode; a fully emulated build (20-30x slower)
      would pass GitHub's 6 h limit for the C++ repos. The hub half is the
      `setup-riscv64-cross` action, the reusable `container-ci-riscv64.yml`,
      `lib/riscv64-cross.sh` and the CMake toolchain
      ([`docs/riscv64-cross-test-lanes.md`](docs/riscv64-cross-test-lanes.md)). Consumers:
      OxidANT (pilot), AccelerANTgine, BeschleunigerBallett, all green (2026-10-01); OxidANT's
      GPU suites run weekly (measured on GitHub: 358 passed, test step 43.5 min).
      **OmniAccelerANT waits** until the riscv64 image carries Flutter. Open:
      - **The Vulkan variables: fixed in source (2026-10-01), ships with the next chain.** The
        entrypoint (via LunarG's `setup-env.sh`, not the login shell) pinned `VULKAN_SDK`,
        `VK_ADD_LAYER_PATH` and four more to `/opt/vulkan/<version>/<arch>`; it now leaves them
        on `/opt/vulkan/active`, and the boot smoke fails an image that does not
        (`docs/failure-modes.md`). Then: check `vkarch=neutral` in the published children, and
        drop the two `export`s in `linux/scripts/lib/riscv64-cross.sh` (`riscv64_cross_env`),
        the only override. No consumer repo overrides them itself (checked OxidANT,
        AccelerANTgine, BeschleunigerBallett on 2026-10-01); BeschleunigerBallett sets
        `CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT`, which `lib/cmake-build.sh` now puts back on the link too.

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
      the source, off by default (`ENABLE_DEEPSTREAM=false`). One thing left:
      1. **An nvidia variant chain run** with `ENABLE_DEEPSTREAM=true`, owner-approved. Started
         2026-10-01 21:34 (amd64, from `gpu`, hub 629afe5d); done when `:latest-nvidia` is
         published with `check_deepstream` green. The `:latest-nvidia` published 2026-10-02
         (hub b4d5fdd5, amd64 `95c3a343…`) is not that run: its build args carry an empty
         `ENABLE_DEEPSTREAM` and its `USE_NEW_NVSTREAMMUX` is empty. Until then everything
         below was proven in throwaway containers FROM the published `:latest` amd64 child
         plus the variant's CUDA install. It is also the first build of
         the GPU run's three fixes in a chain. GStreamer and libcamera without libunwind are in
         every variant by owner decision (2026-10-01, "everywhere"): the `:latest` published
         2026-10-01 proves it in all three children (no shared object under `/opt` or
         `/usr/local` needs `libunwind.so.8`); `:latest-rocm` gets it with CON51.

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
      - Size: TensorRT 10 alone is 2.6 GB (builder resources for every GPU generation).
        Trimming them to `CUDA_ARCHITECTURES` would drop the 2080's sm_75: an owner call.
      - **Phase 7 (arm64)**: out of scope until CON31 has an arm64 CUDA route. The Jetson
        runtime `.deb` is pinned (`DEEPSTREAM_BINARIES_ARM64_SHA256`); nothing installs it.
      - **Phase 8**: `consumer-image-contract.md` names (`DEEPSTREAM_ROOT`, the plugin link,
        `USE_NEW_NVSTREAMMUX`) and OmniAccelerANT's `nvinfer` path, after a published image exists.
      - Renovate reports `DEEPSTREAM_VERSION` (github-releases, report-only). The v9.1.0 release
        also hosts 9.1.1 assets for NVIDIA's `develop` branch; the pin stays on 9.1.0.
