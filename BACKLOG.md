# Backlog — image gaps

Every known gap in the images this hub publishes (`:latest`, `:winamd64`, the
`:winarm64` bundle) that a consumer lane hits or works around. The refactoring
registers stay in [`docs/refactoring-backlog.md`](docs/refactoring-backlog.md).
The CON1–CON6 prefix history is in
[`…-archive-2026-09-17.md`](docs/refactoring-backlog-archive-2026-09-17.md).

**State 2026-10-12**, read from the registry (hub = the image's `revision` label, digest =
the per-arch manifest). Published: `:latest` (2026-10-11, hub 7d8d0363, index `b52f8c34…`;
amd64 `624a8a63…`, arm64 `448591ff…`, riscv64 `7689579f…`), `:latest-nvidia` (2026-10-11, hub aabebdbc,
index `810f36b3…`, amd64 `23e3cc9e…`, with DeepStream 9.1), `:latest-rocm` (2026-10-09, hub f0e360b8, index
`a5d68fbe…`, amd64 `d58be41b…`), `:winamd64` (2026-10-08, hub 5dfeb42d, `e96203a8…`), `:winamd64-nvidia`
(2026-10-10, hub 93708b28, `75bbe6f6…`), `:winamd64-rocm` (2026-10-09, hub aa7a8086, `32c7cc51…`) and
`:winarm64` (2026-10-10, hub 222f2fa9, `ba6bfaae…`, without NVIDIA; no `:winarm64-nvidia` tag exists).
Every Linux image gap up to CON41 shipped and was checked in the published children (git history).
Decisions and gaps checked closed live in [`docs/image-decisions.md`](docs/image-decisions.md). **Re-derive before acting; a number
here is a date's measurement.**

## Protocol

The agentic loop's format (`docs/windows-agentic-loop.md`):

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★, as in the refactoring backlog.

## Open — getting fixes to consumers

- [ ] **CON74 — a free-threaded CPython for Windows arm64, so its 3.14t legs stop downloading**
      [M, ★]. Half 1 is in the scripts since 2026-10-07 (CHANGELOG): media-core's
      `Build-TargetCpython.ps1` stages the `--disable-gil` ARM64 build into
      `C:\runtime\python-freethreaded` (`python3.14t.exe`, `libs\python314t.lib`, the venv
      launchers, no `python.exe`), `BUNDLE-ENV` appends it last to `PATH`, and
      `Test-Arm64Bundle.ps1` runs it on a device when the bundle carries it. Left:
      1. Done: the `:winarm64` of 2026-10-10 (`ba6bfaae…`) carries the tree, and BeschleunigerBallett run
         38100828628 passed `free-threaded interpreter: GIL off, stdlib extensions import` on `windows-11-arm`.
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
      1. **Prove in full image builds**: Linux — FT-STORE is green on the published `:latest` amd64
         (2026-10-09, hub 655a2c4e) with the cp314t twins of av 19.0.1, iree_base_compiler/runtime 3.12.0
         and apache_tvm_ffi 0.1.14.post0 loaded with the GIL off. Also proved on that image (index
         sha256:af7252a0, 2026-10-09): the `onnxruntime_dnnl` 1.30.0 cp314t twin is in the store and FT-STORE;
         `PYTHON_WHEELS_CP314T=/opt/wheels-cp314t` passes FT-STORE (chain run 20261009-022859); the ORT census
         grades the twin's four members against `ort-provenance-cp314t.sha256` with chain roots and passes; and a
         3.14t venv holding PyPI onnxruntime 1.31.0 is reconciled by `uv_reconcile_chain_ort` onto the twin
         (venv census PASS, `import onnxruntime` with the GIL off, 8 threads run one session). **The GPU ORT
         twins are proved in the published images** (2026-10-11 CHANGELOG): `:latest-rocm` (index sha256:a5d68fbe, run
         20261009-152508) and `:latest-nvidia` (index sha256:810f36b3, run 20261011-040056, media from 20261010-202726)
         each pass FT-STORE with `onnxruntime_migraphx` / `onnxruntime_gpu` 1.30.0 cp314t and `onnxruntime_dnnl` loaded with
         the GIL off, and the ORT census; both twin passes rebuilt no CUDA/HIP object. Each next nvidia and rocm chain re-reads: the twin pass rebuilds no CUDA/HIP
         object (`.cu.o`/HIP count 0 between `free-threaded: build venv` and `rebuilt for`), and FT-STORE ends on
         `onnxruntime` among the families with the flavour's own twin proved. FT-STORE on arm64 is green since the cross `:latest` of 2026-10-10 (1b). **Windows is proved:** the published `:winamd64` (`e96203a8…`) carries all five twins, and smoke section 20
         holds its cp314t store to exactly that set and loads each twin with the GIL off (run 2026-10-11, again in
         chain 20261011-222153). Optional: keep the GIL interpreter in IREE's VM ISA genrule for
         the Windows twin, as `Set-OrtNinjaCommandPython` does for ORT (56 of its 137 edges go away).
      1b. **Linux cross twins: done** (CHANGELOG 2026-10-09..12). The published `:latest` of 2026-10-11 (index
         sha256:b52f8c34, run 20261011-125540) passes `FT-STORE` on all three arches; riscv64 proves
         `torch-2.14.1a0+git5c48869-cp314-cp314t-linux_riscv64.whl: 1 compiled module(s) of torch loaded on free-threaded
         3.14.8; the GIL stayed disabled` and ends on `apache-tvm-ffi av iree-base-runtime onnxruntime torch`.
         **numpy** keeps its row (`twin:FT_TORCH_TWIN`) without a chain build; torchvision stays `none`.
      2. **arm64 cross twins (Windows): the device proof.** In source since 2026-10-07 (CHANGELOG), proved
         statically in `:winarm64`; on the device, BeschleunigerBallett run 38100828628 passed `free-threaded
         wheels: every cp314t twin loads with the GIL off` (2026-10-11). **The twins' dependencies are in source since
         2026-10-11:** `Copy-TargetPythonDeps.ps1` stages them as `cp314t` or pure wheels in `wheels-cp314t\deps` and
         fails when an edge resolves nowhere, and the device installs each twin with them, offline. PyPI carries all
         six today: numpy 2.5.4 and ml_dtypes 0.6.0 as `cp314t-win_arm64`, and four pure wheels. Left: an arm64 chain
         (the merge's gate), then the device run on the `:winarm64` it publishes.
      3. **The ROCm torch twin** (`Build-TorchRocmFromSource.ps1`; `Dockerfile.torch` already mounts the module,
         and must mount `linux/scripts/03-media/free-threaded-twins.txt` at `C:\bkmnt\free-threaded-twins.txt`
         once it asks `Get-FreeThreadedTwinPlan`). Measured 2026-10-12, what makes it harder than the Linux twin:
         - No PyTorch build file names `Py_GIL_DISABLED` (code search over pytorch/pytorch).
         - The image's `C:\python-freethreaded\include\pyconfig.h` only tests the macro, and its
           `#pragma comment(lib)` picks `python314t.lib` only when the macro is set.
         - So the twin must define `Py_GIL_DISABLED=1` on torch_python's compile lines itself. A global
           `CMAKE_CXX_FLAGS` would recompile every C++ object of torch.
         - The Windows twin plan also skips a `twin:<KNOB>` row, which is torch's verdict.
      5. **Upstream**: IREE's bare-`python3` genrule (`runtime/src/iree/vm/bytecode/isa/CMakeLists.txt`) and its
         Windows `cpython-NNt` SOABI detection (`CMakeLists.txt:782-791`); onnxruntime-genai's
         `PYBIND11_MODULE` (`src/python/python.cpp:468`) plus a thread-safety audit of its global log callback.
         **Drafts written 2026-10-12, not posted** (owner reviews first; `~/upstream-drafts/2026-10-12/` on the build
         host): none of the three is reported or fixed upstream. IREE: a 13-line `iree_genrule.cmake` fix that swaps a
         leading `python3` for `${Python3_EXECUTABLE}` in all five genrules, and a 4-line SOABI fix (cosmetic today).
         onnxruntime-genai: `py::mod_gil_not_used()` alone is not safe (the binding leans on the GIL to serialise a C API
         documented as not thread safe); the issue lists what needs a lock, and the patch locks the log callback only.

- [ ] **CON84 — lock maintenance and sqlite3, the loose ends** [S, ★]. (1) Yarn is NOT CARRIED (no family repo has a
      yarn.lock today). (3) Optional: OmniAccelerANT's `dev.flutter.flutter-plugin-loader` gradle rule into the
      preset (its floors follow its lock since 467ca34, 2026-10-12: regenerate `lib/src/rust/` and `lib/l10n/` after a
      floor change, AGENTS.md § 4). (5) npm, poetry, pdm and pnpm locks report
      `behind: unknown`: none has a dry run that diffs the lock (measured 2026-10-08).

- [ ] **CON78 — prove the TheRock 10.1 images (`:latest-rocm`, `:winamd64-rocm`)** [M, ★★]. The bump
      (CHANGELOG 2026-10-07, CON73) was proved in throwaway `:latest` and `:winamd64` containers only.
      **Linux**, a rocm chain run (`CROSS_VARIANT=rocm`):
      0. *2026-10-09, run `20261009-131840`:* the media stage's ORT **CPU** step died on `ort.fbs.h`'s
         `(25 == 23)`. ROCm 10.1's hipDNN flatbuffers 25 config (`/opt/rocm/lib/cmake/flatbuffers`) is
         reachable through `/opt/rocm/bin` on `PATH`. Fixed in source (CHANGELOG 2026-10-09):
         `CMAKE_DISABLE_FIND_PACKAGE_flatbuffers` in every native ORT build, `CMAKE_IGNORE_PREFIX_PATH=/opt/rocm`
         in the CPU one. Proved in that run's gpu-stage image: the CPU `libonnxruntime.so` and
         `libonnxruntime_providers_migraphx.so` both build; the next chain run must take the media stage past it.
      1. `Dockerfile.amd` as a gpu stage over `:cross-sdk-amd64`, and the media stage's ORT gpu step under the
         chain's toolchain and caches (`verify-media-artifacts.sh onnxruntime-gpu`).
      2. The runtime copy: `copy_rocm_payload` carrying `/opt/rocm/extras-10` and remaking the `core-10` and
         `rocm-*` alternatives links; `publish_rocm_ld_path` writing `extras-10/lib`; the ORT G6 census.
      3. The wrapper smoke: `torch.version.hip` with the rocm7.14 wheels over a 10.1 system tree, and
         `MIGraphXExecutionProvider` listed. Then the image size (21.7 GB of ROCm before the runtime copy).
      **Linux 0–3 are proved** by the `:latest-rocm` published 2026-10-09 (run 20261009-152508, index `a5d68fbe…`):
      the media stage built ORT CPU and MIGraphX (`migraphx_home = /opt/rocm/extras-10`); the runtime smoke passed
      15/15, the ORT census and `FT-STORE`, with torch 2.14.1+rocm7.14 (HIP build 7.14.60850) and
      `MIGraphXExecutionProvider` available. Read in that image on 2026-10-12: `/opt/rocm/extras-10/lib` holds
      `libmigraphx_c.so.3`; no absolute and no dangling link is left under `/opt/rocm`, and `core-10` → `core-10.1` is
      relative; `000-rocm.conf` lists `core-10.1/lib`, `extras-10/lib` and `lib`, so `ldconfig -p` resolves
      `libmigraphx_c.so.3` and `libamdhip64.so.7`; ORT's `libonnxruntime_providers_migraphx.so` loads without a GPU.
      The image is 29 GB compressed.
      **Windows**, a `Build-Buildkit.ps1 -Variant rocm` run:
      4. The whole rocm chain on the 10.1 sdk layer, then `Test-RocmImage.ps1` with every rocm-check clean;
         MIGraphX 2.18.0 and the EP inside BuildKit (`prefuse_ops.cpp` is the stage's critical path).
      5. torch v2.14.1 / torchvision v0.29.1 against the 10.1 SDK, and rocm-1 installing the 10.1.0 wheels:
         `rocm-checks\Torch.ps1` reports `+rocm10.1.0` and HIP 7.16.
      6. The llama stage in BuildKit (`ggml-hip` through the WebDAV sccache, the `llamamods` closure, cleanup,
         `LlamaCpp.ps1` at the smoke gate). Then drop the `hip-msvc-cmath` overlay if 4–6 build without it.

      Windows 4–6 are proved: the `:winamd64-rocm` published 2026-10-09 (hub aa7a8086, `32c7cc51…`)
      built MIGraphX 2.18.0, the EP and `ggml-hip` in BuildKit. Its smoke gate passed 265 assertions, 1
      skipped, with eleven rocm-checks and `torch 2.14.1+rocm10.1.0`, HIP 7.16.26385. **The overlay is gone and
      proved** (CHANGELOG 2026-10-12). Hub 28daad33's rocm chain built every stage without it: MIGraphX with the
      EP, `ggml-hip` (gfx1201 and gfx1200), and torch 2.14.1+rocm10.1.0 with HIP 7.16.26385. Smoke: 265 passed,
      0 failed, 1 skipped, and all eleven rocm-checks passed (`kernel compiled for gfx1201`). Only the GPU
      runs below are left on Windows.
      **Both, on a real GPU (RX 9070 XT, gfx1201):** a MIGraphX EP session, torch HIP, and a small model on
      ggml-hip against its CPU result. With no bundled runtime a bare Windows host's loader takes Adrenalin's
      System32 `amdhip64_7.dll` before TheRock's (llama.cpp#26929): prove it serves TheRock 10.1's hipBLAS, or
      re-bundle TheRock's three runtime DLLs and the byte-identity check that went with them.

## Open — Linux image (all arches)

- [ ] **CON90 — Python 3.15 in the published images, built from the one pin** [L, ★★★]. Owner request 2026-10-12:
      `PYTHON_VERSION=3.15.0` (released 2026-10-09), and an upgrade must stay that one line
      (`docs/python-ci.md` § Upgrading Python). In source: every image ships the source-built interpreter on every
      arch, GIL and free-threaded, never the distro `python3.14`; the free-threaded store has a version-free name
      (`/opt/wheels-free-threaded`, `PYTHON_WHEELS_FREE_THREADED`); the drivers default to the pinned X.Y (and X.Yt
      for a project that declares free-threading); arm64 and riscv64 build numpy, PyGObject, pycairo and contourpy
      from sdists instead of copying apt's. uv moved to 0.13.0 with it (the first to know 3.15.0). Open:
      1. The default chain from `compiler` (amd64, arm64, riscv64), published, with every per-ABI wheel rebuilt for
         cp315/cp315t: ONNX Runtime and its twins, GenAI, IREE, PyAV, tvm-ffi, LiteRT, cv2, riscv64 torch.
      2. Then `:latest-nvidia` and `:latest-rocm`, serially.
      3. The consumers' fallout once `:latest` moves: OrchestrANT and WebDavClient drop their literal `3.14 3.14t`
         legs, their locks need cp315 wheels (numpy 2.5.4 has them; PyPI onnxruntime has none, the chain's serves
         the image), and AccelerANTgine's `ci-python-bindings.sh` defaults to the image's X.Y.

- [ ] **CON66 — the consumers' `3.14t` legs on the image's free-threaded Python** [S, ★★]. The image
      half is proven: the `:latest` published 2026-10-09 (hub 655a2c4e) carries
      `/opt/python-freethreaded` with python3.14t 3.14.8 and `sys._is_gil_enabled() == False` on amd64,
      arm64 and riscv64, and passes the `free-threaded-python` row, prefix check included
      (`docs/consumer-image-contract.md` § The free-threaded Python). Open:
      - **The consumer half is done (2026-10-12).** In the shipped image a `3.14` or `3.14t` leg takes the image's
        interpreter or fails, and never downloads one (hub 00feaf7a, CHANGELOG 2026-10-11). On that pin OrchestrANT
        (b599448) and WebDavClient (5ab44f4) logged `the image's own interpreter, UV_PYTHON_DOWNLOADS=never` for both
        legs on x64 and arm64 (`/usr` 3.14.4, `/opt/python-freethreaded` 3.14.8), and OrchestrANT's riscv64 row for its
        `3.14` leg (run 38171396906). Its riscv64 row runs no `3.14t` leg, so `uv_venv_create 3.14t` ran in the published
        riscv64 child (`7689579f…`) under QEMU: `/opt/python-freethreaded` 3.14.8, `gil=False`,
        `cpython-314t-riscv64-linux-gnu`, nothing in uv's managed store. Both consumers also run their suite on the
        installed cp314t wheel, through the hub's `test-free-threaded-wheel.sh` since 2026-10-12 (hub 9ade0dd1, OrchestrANT
        0f6def5, WebDavClient 5663983; their two local scripts are gone). Proved locally in `:latest`; their next Linux
        x64 and arm64 runs prove it in CI.
      - The toolchain stage's added time on a CI runner (estimate 25-40 min on 4 cores); a local chain
        time is not that number.
      - A native arm64 toolchain build (PGO on arm64).

- [b] **CON57 — mold in the image, only once it earns it** [S, ★]. `KATAGLYPHIS_LINKER=mold`
      (2026-10-05, `lib/linker-select.sh`) fetches the pinned mold 3.0.0 on first use. Baking
      it in (an `install_mold_pinned` beside `install_sccache_pinned`, apt's 2.40.4 cannot link
      AccelerANTgine) is open on two conditions. 3.x must have had a point release: 3.0.0 is
      the Rust rewrite, published the day the switch landed. And some build must link
      faster with it than with lld: none measured did (`docs/shared-script-libraries.md`
      § *linker-select.sh*), BeschleunigerBallett included (2026-10-06: 0.32 s against
      lld's 0.20 s for its `commitTestSuite` Debug relink). Re-checked 2026-10-12: rui314/mold's
      newest release is still v3.0.0 (2026-10-05).

- [b] **CON44 — `LP_NATIVE_VECTOR_WIDTH=256` in the image** [S, ★★]. Mesa 26.0.8's lavapipe
      compiles its BVH radix sort for 8-lane subgroups, but llvmpipe's subgroup is its vector
      width / 32: 4 lanes on arm64 NEON and riscv64, where every acceleration-structure build
      SEGVs (BeschleunigerBallett run 36746313937; detail in `docs/failure-modes.md`). The
      image sets `ENV LP_NATIVE_VECTOR_WIDTH=256`, and the `:latest` published 2026-10-01
      proves it in all three children (`check_lavapipe_subgroup`: 8 lanes on amd64, arm64 and
      riscv64), and BeschleunigerBallett's `run-ctest.sh` no longer exports its own. Open:
      - Retire the `ENV` once the image's Mesa has upstream ebcfbe60 (2026-08-22), which
        deletes that sort. **No Mesa release carries it yet** (checked 2026-10-12 against the
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

- [ ] **CON91 — the Windows lanes follow the Python pin** [M, ★★]. The Windows images read the same
      `PYTHON_VERSION` (3.15.0 since 2026-10-12, CON90), so their next chains build CPython 3.15. Derive every
      version from it, as Linux does, so the next upgrade is one line here too.
      **Done (hub, 2026-10-12):** `Get-PinnedPythonVersion`; the drivers' defaults and the arm64 job's legs
      (`pinned`/`pinnedt`); `Sync-UvProjectDependencies` leaves the lock's ORT to the chain wheels, as on Linux;
      the arm64 bundle's native pytest wheels are cp315; the rocm venv's PyPI LiteRT extra and its cp314 pin are gone.
      **Left:** the tvm-ffi wheel tags (`Build-TvmFromSource.ps1`, `WindowsTvm.Common.psm1`) and the remaining
      literal fallbacks; the twin store's name, `C:\runtime\wheels-cp314t` / `PYTHON_WHEELS_CP314T`, which Linux
      spells `wheels-free-threaded` / `PYTHON_WHEELS_FREE_THREADED` (the readers take the new name first already);
      and **ai-edge-litert built from source** for the pinned Python (owner decision 2026-10-12): no release has a
      cp315 `win_amd64` wheel (2.3.0 stops at cp314). Until it lands the cpu and nvidia venvs go without it (one app
      smoke WARN), and the rocm variant's `rocm-1` fails on `Torch.ps1`'s LiteRT check, on purpose. The accelerator
      DLL it needs is pinned already (`LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256`), so landing the build re-keys no
      more than its own stages. All of it must land before the next amd64 chain, which `PYTHON_VERSION` re-keys
      from `Dockerfile.base` anyway.

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
- [ ] **CON86 — find why a bind of a branch image opens none of its files** [M, ★]. Since
      2026-10-09 the media fan-in binds `media-core-view` and `media-tvm-view`, which add one
      empty `RUN` layer over each branch image ([failure mode](docs/failure-modes.md#a-bind-mount-of-a-branch-image-lists-its-files-but-opens-none)).
      A `RUN --mount=type=bind,from=<media-tvm image>` lists the image's site-packages, but
      `cython.py` "does not exist" there. A view stage reads it, and so does a RUN on the image.
      The fault survived a no-cache rebuild of media-tvm and a restart of containerd and
      buildkitd. The RX 9070 XT was disabled throughout, so the RDNA4 lock is ruled out. The
      first activation of the MIGraphX stage's fresh `migraphxmods` COPY layer failed with the
      same 0x20, and there the driver's retry read it. So did the llama stage's first RUN in the rocm
      chain of 2026-10-11 (`hcsshim::ActivateLayer` on snapshot 9950, process isolation, GPU disabled). Defender's exclusions were not checked
      (admin only). Find the cause, then drop the two views when a bind of the image reads again.
      **2026-10-11, a direct-bind probe** (`buildctl`, no view, one `--mount=type=bind,from=<image>` per run):
      - `bk-windows-media-tvm` (2026-10-08) and `-rocm` (2026-10-09): `site-packages` lists 49 entries and opens
        none. In the same images `Lib\json` opens 7 of 7, and a RUN on the image reads `cython.py` (661 bytes).
      - `bk-windows-media-tvm-nvidia` (2026-10-10) opens 49 of 49, and every `media-core` variant 43 of 43.
      - A RUN on the image before the bind did not help, so the layer's activation is not it. It is one
        directory of particular images, reproducible on every run, which argues against Defender.
      - Next, admin only: compare that directory's node in the top layers of the default and the nvidia
        `media-tvm` (`ctr -n buildkit`, then its reparse and attribute flags).
- [ ] **CON88 — Python in the Windows images trusts only the roots the Server Core store ships** [S, ★].
      Found in the 2026-10-11 `:winamd64` chain: meson's `ogg` wrap failed `CERTIFICATE_VERIFY_FAILED` on
      `https://downloads.xiph.org/…` and fell back to its GitHub mirror, so the build did not notice. Measured in
      the published `:winamd64` (`e96203a8…`):
      - downloads.xiph.org itself verifies. It answers with a 302 to `ftp.osuosl.org`, whose chain ends at
        `emSign Root CA - G1` (InCommon OVG2C, then emSign Root TLS CA - G1).
      - Python 3.14.8 (OpenSSL 3.5.9) reads the Windows stores as they are: 18 roots in the container, 43 on the
        dev host, where Windows had fetched more on demand. emSign is not among the 18. Unsetting `OPENSSL_CONF`
        and `OPENSSL_MODULES` changes nothing.
      - With `truststore` 0.10.4 the same URL verifies: CryptoAPI fetches the missing root, and the store then
        holds 19. The image has no `truststore`, and meson's `wrap.py` uses it whenever it imports.
      Fix: `truststore` in the image's CPython, pinned and hashed like the other wheels, so meson in the chain and
      in consumers verifies through CryptoAPI. Prove it in the next chain: no `CERTIFICATE_VERIFY_FAILED` in the
      merge stage's log.
- [ ] **CON89 — what rides the next full Windows chain** [M, ★]. Each item re-keys `Dockerfile.base` or the media
      stages, so landing one alone would cost a rebuild of its own. They go in with the next planned full rebuild, which is
      CON79 item 2's arm64 chain or CON88:
      - `WindowsScripts.Shared.psm1`'s `vswhere` selector is `if ($All) { @() } else { @('-latest') }`. Splatted, the unrolled
        string hands vswhere `- l a t e s t`, so every chain logs `vswhere returned no installation; using filesystem fallback`.
        The fix is `@(if ...)`. `Lint.ScalarSplat.Tests.ps1` allows this one site until then.
      - Pin every pip install in the chain. `Build-FfmpegCodecs.ps1` installs a floating `meson`, and IREE, OpenCV, GenAI, ORT
        and TVM each install at least one unpinned package through `Invoke-CpythonPip`.
      - Silence the vendored-code warning floods. The arm64 VVL vertex alone is 1.36 M warning lines, 97.9 % of the 768 MB
        merge log (`docs/windows-refactor-backlog.md` #183). VVL and x265 are in source since 2026-10-12.
      - Pin bazelisk, the LiteRT JDK fallback and git-lfs by version and SHA256 (`docs/windows-refactor-backlog.md` #185).
      - IREE's VM ISA genrule on the GIL interpreter (`IREE_ISA_PYTHON`, CON79 item 1, optional).
      - Already in source, and re-keying the toolchain stage: the patched LLVM builds with the pinned clang-cl, so
        `clang-cl.exe` relinks reproducibly (`docs/windows-refactor-backlog.md` #180). The chain that carries it rebuilds
        the media lane once.
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
        gate is `windows/scripts/build/Test-Arm64Bundle.ps1`, nine steps then, eighteen and floor eighteen since 2026-10-12):
        HailoRT-CLI 5.4.0, GStreamer 1.29.2 (`gst-inspect` + a videotestsrc->fakesink
        pipeline), `iree-run-module`, and the bundle's own Python 3.14.7 importing
        numpy 2.5.3, onnxruntime 1.30.0 (DmlExecutionProvider + CPUExecutionProvider),
        av 18.1.0 and cv2 5.0.0 - the wheels installed offline from its store.
      - The gate runs in the hub's `windows-arm64.yml` since 2026-10-11, daily and on a push to its files: a
        `windows-2025` job packs the published image's `C:\runtime` and a `windows-11-arm` job runs
        `Test-Arm64Bundle.ps1` over it ([`docs/windows-cross-builds.md`](docs/windows-cross-builds.md) - Verification).
        BeschleunigerBallett's cross lane hosted it from 2026-10-03 until then.
      - An inference runs on the device since 2026-10-12: the gate's ORT step builds a session over
        Test-Container.ps1's 63-byte Identity model and asserts Identity(42.0) = 42.0 on the CPU EP.
        DirectML is tried first and printed, never graded, since a runner has no adapter (in `:winamd64`
        it falls back with `No devices detected that match the filter criteria`).
      - Still unproven on a device: a camera pipeline and a GPU execution provider. No `windows-11-arm`
        runner has either; the Snapdragon X's DirectML is the one adapter in reach.
- [b] **CON31 — Variants that are not published** [L, ★]. Blocked on owner decisions.
      - `:latest-nvidia`: no arm64 route, and no TensorRT 11 (`ENABLE_TENSORRT=false`). Read in the published image on
        2026-10-12 (`23e3cc9e…`): the only `libnvinfer` is DeepStream's TensorRT 10.16.1 under
        `/opt/nvidia/deepstream/tensorrt-10.16.1.11/lib`, which `ldconfig -p` resolves; ONNX Runtime has no TensorRT EP.
        The stale `tensorrt.conf` naming the absent `/usr/local/tensorrt/lib` is gone from the source since 2026-10-12;
        the next nvidia chain proves it.
      - `:latest-rocm`: the wrapper lacks `ROCM_PATH`/`HIP_PATH` and cannot open
        the device as shipped.
      - `:winamd64-rocm`: published (first 2026-09-28 at ad08bc30, again 2026-10-03 at
        1d910553, with TheRock 10.1 on 2026-10-09 at aa7a8086); the redistribution decision is recorded in `docs/windows-rocm.md`
        § Redistribution.

      Sources: `docs/linux-accelerator-images.md` and `docs/windows-rocm.md`.
- [b] **CON42 — DeepStream in `:latest-nvidia`: what is left after the publish** [M, ★]. **Done:** DeepStream 9.1
      ships in every amd64 nvidia build (owner 2026-10-07, full TensorRT 10), published 2026-10-11 (`:latest-nvidia`
      index `810f36b3…`, amd64 `23e3cc9e…`). **The GPU run on the published image passed on 2026-10-12** (RTX 2080,
      sm_75, driver 595.58.03, CDI; `docs/linux-accelerator-images.md` § The GPU run on the published image): an sm_75
      engine build, 1442 frames with 30214 objects through `nvdsosd`, the NvDCF tracker over two sources, demux,
      `nvurisrcbin`, all again as uid 1001. Phase 8's contract is in `docs/consumer-image-contract.md` § DeepStream in
      `:latest-nvidia`. Of the prebuilt plugins, only `nvblender` reads `GstMapInfo` after unmap like the legacy mux
      (every blend drops its buffer; with two inputs it also hangs, on GStreamer 1.24.2 too); 14 others reached EOS with
      correct output. Left:
      - OmniAccelerANT's `nvinfer` path: later, by owner decision (2026-10-12).
      - `nvblender` upstream: a forum draft (both defects, with the RTX 2080's repro) waits for the owner's review in
        `~/upstream-drafts/2026-10-12/nvidia-deepstream/` on the build host; nothing is posted.
      - **Phase 7 (arm64)**: out of scope until CON31 has an arm64 CUDA route. The Jetson runtime `.deb` is pinned
        (`DEEPSTREAM_BINARIES_ARM64_SHA256`); nothing installs it.
      Renovate reports `DEEPSTREAM_VERSION` (github-releases, report-only); the pin stays on 9.1.0.

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
