# Backlog — image gaps

Every known gap in the images this hub publishes (`:latest`, `:winamd64`, the
`:winarm64` bundle) that a consumer lane hits or works around. The refactoring
registers stay in [`docs/refactoring-backlog.md`](docs/refactoring-backlog.md).
The CON1–CON6 prefix history is in
[`…-archive-2026-09-17.md`](docs/refactoring-backlog-archive-2026-09-17.md).

**Groomed 2026-10-23 against the merged source and recorded checks; re-checked 2026-10-27.** The immutable Linux index
published on 2026-10-27 is
`sha256:7d4d4129472cbb854217d6dd444f1813a90371f1a5f9c839247051d814207282`
(hub `8119595e93b83d7e623089a3536879dedebf8ede`, run `20261027-125309-76ffcd44`),
with amd64, arm64 and riscv64 children; its consumer acceptance passed for six consumers.
The recorded consumer runs on this index use Python 3.15 and chain ORT 1.31.0. This replaces the earlier default-image baseline of Python 3.14/ORT 1.30;
it is not a fresh assertion about a mutable tag or either GPU variant.
Earlier Windows and GPU measurements remain dated evidence in their individual entries.
Decisions and checked closures live in [`docs/image-decisions.md`](docs/image-decisions.md).
**Re-derive before acting; source completion, image publication and device execution are separate.**

## Protocol

The agentic loop's format (`docs/windows-agentic-loop.md`):

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★, as in the refactoring backlog.

## Open — getting fixes to consumers

- [ ] **CON126 — every hub pipeline runs at the host's parallelism, never one step at a time** [L, ★★★].
      Owner directive 2026-10-20: "alles innerhalb von ANTfrastructure massiv parallel (soviel wie
      möglich)". Measured on that day's 3-arch `:latest` rebuild: the cross stages already run two
      arches at a time (`--parallel-archs`), but the **runtime lane serialises per arch** — amd64
      finished at 13:45 and riscv64 did not start while arm64's ~20 GB push streamed, so each arch
      leaves ~1.2 h of idle upload at the measured 5 MiB/s (3 arches ≈ 2–3 h of wall clock). Work:
      start an arch's successor as soon as that arch's **build** ends, not its push (a push needs no
      CPU); make `MAX_PARALLEL_ARCHS=3` usable by sizing the memory divisor and the disk gate for it
      rather than by refusing; and keep every push off the critical path of the next build. Done when
      a 3-arch run shows the next arch's `RUN` lines while the previous arch's `nerdctl push` is
      still streaming, and the wall clock drops by roughly the summed upload time.
      **Measured 2026-10-21** over three runtime runs' resource samples (32 cores): mean CPU 6–10 %,
      and 87–94 % of the samples under 15 % CPU at a load of 1–3, so one thread works (push, layer
      export, compression) while 31 cores wait. Also in scope: the wrapper-smoke gate (amd64 821–898 s,
      arm64 1150–1265 s) runs before the wrapper build although neither reads the other, so the two
      can overlap and the push wait for both.

      **Survey 2026-10-21** (serial spot → cost → fix, in payoff order; the serial path stays behind
      a switch in each):
      1. Runtime lane: each wrapper push blocks its arch (~1.2 h/arch, above) → a FIFO background
         pusher; the index waits for it (`RUNTIME_ASYNC_PUSH`, 0 = inline).
      2. Runtime lane: content gates and smokes run one arch at a time, after every push (two 30 GB
         rootfs exports per content gate, ~100 container runs per smoke, mostly under QEMU;
         unmeasured) → all arches at once while the pushes stream (`RUNTIME_GATE_JOBS`, 1 = in turn).
      3. `run-tests.sh`: 227 suites in turn, 25+ min in `:latest` on 32 cores → N at a time,
         output printed per suite in order (`RUN_TESTS_JOBS`, 1 = in turn). Feeds preflight and CI.
      4. `lint-shell.sh`: one shellcheck per file, two passes over 545 files (~105 s) → `xargs -P`.
      5. `preflight.sh`: 39 slugs in turn (secret scan ~170 s alone) → read-only slugs side by side,
         tree-writing ones (cmake-format's venv) first and alone (`PREFLIGHT_JOBS`, 1 = in turn).
      6. Mutation gate: mirrors copied one at a time before any shard starts, entries dealt
         round-robin, pre-push at `--jobs 4` → copies in parallel, a shared work queue, the gate's
         default in the hook.
      7. Windows tests: `Invoke-Tests.ps1` runs 179 files in turn (305-404 s in CI);
         `Invoke-Lint.ps1` analyses 379 files in turn (68-134 s) → process shards with summed
         results (the 797-test floor holds), `ForEach-Object -Parallel` for the analyzer.
      8. Windows chain: variants run one after another, each ending in `final-push` (amd64
         2700-4950 s; four push-only runs on 2026-10-17 took ~2.6 h in turn) → the push leaves the
         next variant's critical path. `-ConcurrentAux` (litert ‖ tvm, ~960 s/chain) exists but
         never ran; litert and tvm need nothing from media-core, hailo and genai nothing from
         ffmpeg/opencv (Dockerfile work, re-keys the media phase).
      9. Runtime lane builds in turn: after 1 the lane's floor is the first build plus the summed
         upload, so parallel wrapper builds pay only where builds outlast uploads; they need a
         `BUILD_MEM_DIVISOR` in the package/torch compile steps (hailo) and a disk gate that sizes
         the concurrency (120 GB each) instead of refusing.
      10. Cross stages join every arch between stages, so a fast arch idles until the slowest one
          has pushed (PAR5: hours at media) → an arch-major pipeline; the between-stage disk guard
          and the image-store lever assume no build in flight, so opt-in first.
      11. Docs: Sphinx without `-j`, the sidebar check one page × viewport at a time, the site link
          gate and the dartdoc nav rewrite one page at a time; `run-lint-gates.sh` runs gitleaks per
          top-level entry in turn.

      **Status 2026-10-21** (each knob `1`/`0` restores the serial path):
      1. Done, 31887ce1: a FIFO background pusher per lane (`RUNTIME_ASYNC_PUSH`); the manifest
         waits for it. Proved against a throwaway local registry, both paths and a failing push.
      2. Done, 31887ce1: content gates and smokes run every arch at once (`RUNTIME_GATE_JOBS`),
         beside the pushes. 93cf530c: the wrapper-smoke gate runs beside the wrapper build
         (`RUNTIME_SMOKE_OVERLAP`); the push waits for both.
      3.–5. Done, 84b4870a: `run-tests.sh` 754 → ~106 s, `preflight.sh` without mutations
         1125 → 123 s, `lint-shell.sh` 77 → 14 s in `:latest` on 32 cores (`RUN_TESTS_JOBS`,
         `PREFLIGHT_JOBS`, `LINT_SHELL_JOBS`). 2ffd3f2c: the suites prove overlap by a rendezvous
         (`tests/meet.sh`); wall-time comparisons and a queue race went red in 5 of 13 side-by-side
         runs, the new ones in none of 5. Once, unexplained: `test-smoke-arch-parity.sh`
         (`FAILURES=1`, not reproduced in 10 runs or 32 copies at once).
      6. Done, f73b8335: one work queue, mirrors copied inside the pool, default every CPU capped by
         temp space; the hook takes it.
      7. Done, 14867ace: one `pwsh` per test file (317 → 65 s, 2097 tests) and child processes for
         PSScriptAnalyzer, which is not runspace-safe (50 → 32 s).
      11. Sidebar check done, b8b4b376 (`CHECK_DOCS_SIDEBARS_JOBS`, 4 Chromes: 66 → 18 s). Open:
          Sphinx `-j` (risky with `-W` and Exhale), the site link gate, the dartdoc nav rewrite,
          gitleaks per entry in `run-lint-gates.sh`.
      Open: 8 (Windows variant pushes off the next variant's path; `-ConcurrentAux` never ran),
      9 (parallel runtime builds: `BUILD_MEM_DIVISOR` plus a disk gate that sizes, worth it only
      where builds outlast uploads), 10 (arch-major cross stages, opt-in). A WSL push that
      touches `test-docs-sidebars.sh` fails there (no node 22, no Chrome); push from Git Bash,
      which skips it. **The next 3-arch runtime run must show**: `[runtime-push] arch=amd64
      start` before arm64's `step=base` and `RUN` lines, `[runtime-push] arch=amd64 done` after
      them, `[runtime-push] queue drained: 3 push(es), waited N s` (the residual upload),
      `[runtime-gates] … 3 arch(es), 3 at a time`, `[smoke <arch>]` lines among the wrapper
      build's and `step=smoke-wait`, and a wall clock down by about the summed upload plus
      min(smoke, wrapper) per arch. Tick 1–2 on that run.

- [ ] **CON139 — a failed arch re-runs alone; prove it on the build host** [M, ★★★].
      In source since 2026-10-26 ([`linux-cross-builds.md` § A failed arch re-runs alone](docs/linux-cross-builds.md#a-failed-arch-re-runs-alone)):
      each wrapper carries `org.kataglyphis.build-key`, and a published child whose key matches joins the
      index by digest after every gate read it (`RUNTIME_REUSE_CHILDREN=0` restores the same-run index).
      The first chain after it rebuilds every arch (no published wrapper has a key yet). Done when a
      follow-up `--target-arches riscv64 --from-stage runtime` logs `[runtime-reuse] amd64: reusing …` and
      the same for arm64, builds riscv64 only, gates all three, and publishes a 3-child `:latest` that
      passes freshness.

- [ ] **CON112 — ModelANT's release build runs on the pinned CPython and the chain ORT** [M, ★★].
      `.github/workflows/release.yml` builds on `ubuntu-latest` with `actions/setup-python`
      3.14, and `scripts/build.sh` pip-installs `onnxruntime==1.31.0` from PyPI
      (`scripts/requirements.txt`), which publishes no cp315 wheel (read 2026-10-20: cp311–cp314
      only). Both break owner rules: only the pinned CPython, and every ONNX Runtime consumer
      links the chain ORT. Fix: run `build.sh` in `:latest` on its interpreter, with the chain ORT
      wheel from the image's store instead of the PyPI pin. Done when a `<name>-v<N>` tag builds
      in the image and the release's SHA256SUMS still match the export check.
      In ModelANT since 2026-10-20 (038ca50): `build.sh` runs only in the image, in a venv that
      sees `/opt/venv` (torch, torchvision, the chain ORT) behind pip's additions held at the
      image's versions, and the hub's ORT census must pass first; `release.yml` uses the hub's
      container actions, and a dispatch builds without publishing. Dispatch run 39392921386 on
      `:latest` (3.14.4, ORT 1.30.0 dnnl from `/opt/venv`, torch 2.14.1+cpu): census PASS, all five
      files byte-identical to `deim_dfine_n_coco-v1`; again with SHA-pinned actions (1f37627, run
      39394810441). Left: the next tag publishes from it, and
      the 3.15 `:latest`, where pip's additions resolve from cp315 or abi3 wheels (read 2026-10-20).

- [ ] **CON101 — the dartdoc guide renderer's parser comes from the image** [S, ★★]. Since
      2026-10-19 `dartdoc_build_prepare_python_env` (`linux/scripts/lib/dartdoc-build.sh`) uses
      `python3` when it imports `markdown-it-py` at the version `dartdoc-guides.requirements.txt`
      pins, and fails in CI or inside the image rather than download it; only a workstation
      without the image still builds a uv venv
      ([`shared-script-libraries.md`](docs/shared-script-libraries.md#the-renderers-python)).
      `:latest` has markdown-it-py 4.2.0 in `/opt/venv`, but only as myst-parser's dependency from
      OrchestrANT's `docs` extra, so no pin holds it at the renderer's version (read 2026-10-19).
      1. Pin it in the image from that one requirements file, and assert the version in the smoke.
      2. Done: jotrockenmitlocken (a591954) and ANThology (c3615ca) run `dartdoc_build_main` with
         their `docs/` guides; their `build-docs.yml` runs 39382562942 and 39382416312 (2026-10-20)
         took `/opt/venv`'s markdown-it-py 4.2.0 and uploaded `guide-*.html` (two and one).

      Done when a docs build in `:latest` renders the guides without network, on the pinned parser.

- [ ] **CON97 — Linux packages that start on Debian 13 and Ubuntu 24.04** [L, ★★★]. Owner OK
      2026-10-16. Step 1 is in (`kataglyphis_install_linux_closure`, the
      `clean-host-package-check` action on `ubuntu-26.04`; linux-build-basics.md § Linux packages
      that run outside the image): the packages start on the image's base and newer. The image's
      loader and glibc travel with `LOADER` since 2026-10-17: AccelerANTgine's `.deb`, tarball and
      AppImage start on himbeere2's Debian 13, and so does OmniAccelerANT's app through
      `bundle-loader.sh --beside` (a window drawn on Debian 13, its flatpak started by the lane),
      OrchestrANT's Python app packages, whose interpreter carries the launcher (2026-10-18,
      their clean hosts start them), and BeschleunigerBallett's 1.5.2 tarball, through its bundled
      loader (`--version`; its engine renders there with the `SV_VulkanVertexID` shaders of
      `dc8ba245`, 2026-10-18). Left: AccelerANTgine's `kataglyphis_inference` wheels, the
      same closure through auditwheel.

      Done when those wheels install and import on himbeere2's Debian 13 and in the clean-host job.

- [ ] **CON74 — a free-threaded CPython for Windows arm64, so its 3.14t legs stop downloading**
      [M, ★]. Half 1 is in the scripts since 2026-10-07 (CHANGELOG): media-core's
      `Build-TargetCpython.ps1` stages the `--disable-gil` ARM64 build into
      `C:\runtime\python-freethreaded` (`python3.14t.exe`, `libs\python314t.lib`, the venv
      launchers, no `python.exe`), `BUNDLE-ENV` appends it last to `PATH`, and
      `Test-Arm64Bundle.ps1` runs it on a device when the bundle carries it. Left:
      1. Done: the `:winarm64` of 2026-10-10 (`ba6bfaae…`) carries the tree, and BeschleunigerBallett run
         38100828628 passed `free-threaded interpreter: GIL off, stdlib extensions import` on `windows-11-arm`.
      2. python-ci-windows.yml's arm64 job: in source as CON113 since 2026-10-20 (403b7a23), so the
         owner decision is moot. A `windows-2025` job stages both legs from `:winarm64`'s
         interpreters and the device installs nothing.
      3. The device smoke half passes on 3.15: hub run 39200278761 (2026-10-19, `:winarm64`
         `e78fa8c3…`) printed `sys._is_gil_enabled() False | Py_GIL_DISABLED 1`.

      Done when CON113's `windows-arm64.yml` run passes its X.Yt leg without downloading.
- [ ] **CON79 — the cp314t chain twins reach the published images, and phase 2** [L, ★★]. Linux native
      and Windows amd64 are in source since 2026-10-07 (CHANGELOG). Open:
      1. **Prove in full image builds**: Linux — FT-STORE is green on the published `:latest` amd64
         (2026-10-09, hub 36e996a7) with the cp314t twins of av 19.0.1, iree_base_compiler/runtime 3.12.0
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
      2. **arm64 cross twins (Windows): done.** Chain bk-20261016-211745 built them on 3.15, `:winarm64`
         `e78fa8c3…` published them on 2026-10-17, and on `windows-11-arm` hub run 39200278761 loaded every
         `cp315t` twin (apache_tvm_ffi, av, iree_base_runtime, onnxruntime 1.31.0) with the GIL off.
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
      yarn.lock today). (5) npm, poetry, pdm and pnpm locks report
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

      Windows 4–6 are proved: the `:winamd64-rocm` published 2026-10-09 (hub c0969e22, `32c7cc51…`)
      built MIGraphX 2.18.0, the EP and `ggml-hip` in BuildKit. Its smoke gate passed 265 assertions, 1
      skipped, with eleven rocm-checks and `torch 2.14.1+rocm10.1.0`, HIP 7.16.26385. **The overlay is gone and
      proved** (CHANGELOG 2026-10-12). Hub c5466f58's rocm chain built every stage without it: MIGraphX with the
      EP, `ggml-hip` (gfx1201 and gfx1200), and torch 2.14.1+rocm10.1.0 with HIP 7.16.26385. Smoke: 265 passed,
      0 failed, 1 skipped, and all eleven rocm-checks passed (`kernel compiled for gfx1201`). Only the GPU
      runs below are left on Windows.
      **Both, on a real GPU (RX 9070 XT, gfx1201):** a MIGraphX EP session, torch HIP, and a small model on
      ggml-hip against its CPU result. With no bundled runtime a bare Windows host's loader takes Adrenalin's
      System32 `amdhip64_7.dll` before TheRock's (llama.cpp#26929): prove it serves TheRock 10.1's hipBLAS, or
      re-bundle TheRock's three runtime DLLs and the byte-identity check that went with them.

- [ ] **CON115 — DocumANTation's Python runs on a uv download and Ubuntu's `python3`, not the pin** [S, ★★].
      Owner rule 2026-10-20: only the pinned CPython, once GIL and once free-threaded. `linux-x64.yml` runs one
      leg on `ubuntu-26.04` through `setup-uv` with `python-version: "3.15"` (a uv download), no `3.15t` leg, and
      downloads pandoc at run time. The `Dockerfile` builds its `md2pdf` venv on Ubuntu's `python3-full`. Fix:
      the lane in the family image on the pinned X.Y and X.Yt, and the Dockerfile's venv on the pin.

- [ ] **CON124 — three consumer workflows run Python on the runner, not in the image** [S, ★★]. Owner
      rule 2026-10-20: only the pinned CPython, from the family images (ModelANT's check moved in,
      85647c6; DocumANTation is CON115). None of the three repos has a backlog. Left: item 1's contract
      job, which waits on CON131.
      1. OrchestrANT `benchmarks.yml`: both jobs used `setup-uv` on `ubuntu-26.04`; the contract job ran
         pytest on `/usr/bin/python3` 3.14.4 (run 39270082041), the viewer job too. GIL only. **The
         viewer job is in** (ddf5258, run 39501333926): `benchmarks/ci-image-leg.sh pinned|pinnedt`
         runs its old `uv run` in a fresh venv of the image's interpreter, the same 98 tests on 3.14
         and 3.14t. **The contract job stays on the runner** until CON131: in `:latest` its 41
         PowerShell tests skip. Its in-image legs otherwise pass locally (2370 passed, 43 skipped,
         both legs, no uv-managed interpreter).
      2. ~~AssetANT `check.yml:20`~~ done: `scripts/check.sh` in the image (24b7cde, run 39496647122:
         `python: Python 3.14.4`, `14 assets, 0 problem(s)`); rc=1 on a planted bad sha256 and SC2086.
      3. ~~jotrockenmitlocken `web.yml`~~ done: the sync runs in the image, the secrets passed by name
         (`-e WEBDAV_PASSWORD`), outside it the script stops with exit 2 (90eb29b, run 39497261352:
         `Using CPython 3.14.4 interpreter at: /usr/local/bin/python3.14`, `UV_PYTHON_DOWNLOADS=never`,
         the deploy green).

      Done when each runs in `:latest` on its interpreter, OrchestrANT's tests on X.Y and X.Yt.

- [ ] **CON148 — jotrockenmitlocken's live-site check on its two dev domains** [S, ★★]. Found
      2026-10-21: `web.yml` runs `scripts/check-live-site.py` after main's upload only, because the
      dev domains are secret and no secret holds their URL (`DEV_USERNAME`, `DEV_WASM_USERNAME` are
      FTP logins). Owner first: add `DEV_WASM_SITE_URL` and `DEV_SITE_URL`. Then one step after each
      dev upload, passing the URL by name (`-e DEV_WASM_SITE_URL`); the WASM check must run before
      the CanvasKit build replaces `build/web`. Done when a develop push shows both checks green.

- [ ] **CON150 — the uncaught `postMessage` TypeError on jonasheinle.de's landingPage and error404** [S, ★★].
      Found 2026-10-21, when jotrockenmitlocken 1.4.1 went to main: the live check saw one
      `Uncaught TypeError: Cannot read properties of undefined (reading 'postMessage')` on
      `/#/landingPage` and `/#/error404` at 1280x800, once per run. Phone widths, the reruns and
      all 128 files were clean. The gate now retries such a route once and logs the first failure
      as `flaky:` (`check-live-site.js`, `checkRouteTwice`), so the run stays green and the log
      keeps it. Not found in the sources: jotrockenmitlocken's `lib/`, `web/` and the shared shell
      (`web/javascript/`), nor ANThology's `lib/`, and the minified `main.dart.js` is the only
      place left. Next: search the Flutter web packages the app resolves (`url_launcher_web`,
      any iframe or `window.parent` caller) and the engine's `flutter.js` for a call on a property
      that is undefined before the page's listeners attach. Both pages render ANThology's
      navigation and cookie notice, so reproduce by loading `/#/landingPage` 50 times at 1280x800
      with the console captured. Done when the cause is named and fixed in its own repo, and the
      retry logs no `flaky:` line on 50 consecutive runs.

## Open — Flet clients for OrchestrANT's UIs

Owner decisions 2026-10-19: OrchestrANT's UIs are Flet (OrchestrANT 2aa1da8, the benchmark viewer;
d954e86, `yolo-monitor`'s viewer and the camera stream page), and Flet's clients are built from
Flet's `client/` sources on this hub's `FLUTTER_VERSION`, not on Flet's own pin (3.44.8); the
owner carries the breakage that costs.

- [ ] **CON102 — Flet's desktop and web client, built in the images on `FLUTTER_VERSION`** [L, ★★★].
      Probe 2026-10-19 on `:latest` (amd64, Flutter 3.47.7 against Flet's 3.44.8, Flet v1.0.4):
      the same analyzer findings bar one `use_super_parameters` info, core `flet` 91/91 tests,
      the client builds for `linux` and `web` and starts under xvfb on Impeller. The first
      breakage to expect is core `flet`'s `cacheExtent`/`onReorder`, deprecated in Flutter 3.44.
      1. Core controls only: both OrchestrANT UIs use `RawImage`, canvas, `DataTable` and
         `ProgressBar`, so the client drops all 19 extensions (their path deps in
         `client/pubspec.yaml`, their imports and `Extension()` rows in `lib/main.dart`; keep the
         dev_dependencies). That also drops libmpv, libsecret and GStreamer from the client. A
         build trimmed to charts and datatable2 linked only window_manager, screen_retriever,
         pasteboard, url_launcher and dartjni (37 MB bundle).
      2. Linux amd64 and arm64 in `:latest`, Windows x64 in `:winamd64`, Windows arm64 natively
         on `windows-11-arm` (Flutter cannot cross-build it, flutter/flutter#62597; OmniAccelerANT's
         `windows-arm64.yml` does the same), and the web client once. riscv64 waits on CON70.
      3. The client's pub cache in the image, proven under `--network none` as `flutter --version` is.
      4. Never run yet: any Windows build (the dev host has no Visual Studio) and any arm64 build.
- [ ] **CON103 — `FLET_VERSION` in `versions.env`, one pin for Python and client** [S, ★★]. The
      Python SDK and the client speak one release's protocol, so a bump moves together:
      OrchestrANT's `frontend` extra (`flet[desktop]==1.0.4`, `flet-web==1.0.4`), its
      `benchmarks.yml` viewer job (`flet==1.0.4`, held to `uv.lock` by OrchestrANT's
      `test_viewer_job.py`) and CON102's client tag. Add the consumer-pins rows and one Renovate
      group (pep621 and the `versions.env` regex). OrchestrANT also holds `fastapi<0.145`: flet-web
      1.0.4 passes the `openapi_prefix` argument FastAPI 0.145 removed (flet-dev/flet#6984, open
      2026-10-19). Lift it with the Flet release that fixes that.
- [b] **CON104 — the app bundles ship the Flet client** [M, ★★]. Blocked on CON102.
      OrchestrANT's packages carry its `app` extra only, so `yolo-monitor --ui auto` falls back
      to OpenCV's window there (OrchestrANT `AGENTS.md` § 4). With CON102:
      1. A `packaging/app.json` key that copies the client into the bundle and sets
         `FLET_VIEW_PATH` in the launchers (`docs/python-app-bundles.md`). Not flet_desktop's own
         lookup: it starts any `.exe` under `<cwd>/build/windows` (or `build/linux`) before
         `FLET_VIEW_PATH`, and unpacks an archive in its `bin` dir into `~/.flet/client`.
      2. `flet[desktop]` joins OrchestrANT's `app` extra (consumer side).
      3. `Test-TargetArch.ps1` over the client in the Windows arm64 bundle (an x64 client would
         run there under emulation without a word), and a self-test line that the client is
         present, with no display.
      4. The deb and AppImage runtime dependencies of the core-only client: GTK 3, and whether
         `libsecret-1-0` is still needed once the secure-storage extension is gone (CON105).
- [ ] **CON105 — `:latest` lacks the runtime library Flet's stock Linux client needs** [S, ★].
      Measured 2026-10-19 on `:latest` amd64: the client flet_desktop downloads (1.0.4, light)
      stops at start with `libsecret-1.so.0: cannot open shared object file`; with `libsecret-1-0`
      installed it runs under xvfb, frames at about 30 fps. This matters for anyone running
      OrchestrANT's viewers in the image before CON102 lands (dev containers, xvfb UI checks).
      Building Flet's full client needs `libsecret-1-dev` and `libmpv-dev` too, and
      `audioplayers_linux` links `-lgstreamer-1.0` without pkg-config's `-L`, so
      `/opt/gstreamer/lib/x86_64-linux-gnu` has to be on `LIBRARY_PATH` (or the plugin's CMake
      patched). Both are moot for CON102's core-only client.
- [ ] **CON106 — the app venv's `frontend` extra in `:winamd64`** [S, ★]. Owner decision 2026-10-26.
      Linux proven on the 2026-10-27 index `7d4d4129…`: APP-PARITY passes with flet, flet-desktop, flet-web
      and FastAPI on amd64 and arm64, absent by decision on riscv64. Done when `:winamd64`'s torch stage
      prints `extras: ml-ai docs frontend`.
- [b] **CON109 — ANThology widgets as a Flet extension** [M, ★]. Blocked on CON102, and on a
      UI that needs a widget Flet lacks (owner, 2026-10-19). OrchestrANT's Flet UIs take
      ANThology's look from Python alone (Material 3, `color_scheme_seed` green accent) and use
      only core controls, so nothing wraps ANThology yet. When something does (its markdown page,
      openable image or pie chart are the likely first):
      1. A `flet-anthology` extension package: per widget, a Python control class and a Dart
         wrapper that reads the fields and returns the ANThology widget; events go back through
         `triggerEvent`.
      2. ANThology pinned where the client is built (CON102's build, so here, the way
         OmniAccelerANT pins it: a submodule and a pubspec `path:` dependency), not in
         OrchestrANT, which compiles no Dart.
      3. Its Flutter floor stays at or below `FLUTTER_VERSION` (3.44.0 in its pubspec today).
         Every package it shares with Flet's client resolved within its ranges on 2026-10-19
         (fl_chart 1.2.0, intl 0.20.2, url_launcher 6.3.2, markdown 7.3.1).
      4. Widgets tied to ANThology's app shell take those dependencies as arguments first:
         `AnthologyTable` calls `context.go`, `SkillTable` and `single_page` read
         `UserSettings`/`AppSettings`, and `open_button` needs `AnthologyLocalizations`.

## Open — Linux image (all arches)

- [ ] **CON172 — the sdk stage points the target multiarch `libstdc++.so` at the host's** [S, ★★]. Found 2026-10-29
      on the first arm64 nvidia media build: `vulkan.sh`'s `_vulkan_setup_gcc_runtime` links `libstdc++.so` and
      `libgcc_s.so` from every `LIBRARY_PATH` dir (the HOST's `/opt/gcc-16.2.0/lib64`) into
      `/usr/lib/<target triplet>`, so the cross media images carry an x86-64 `libstdc++.so` there; lld rejects
      it on any link line with an explicit `-lstdc++` (OpenCV's CUDA line), bfd only skips it. ffmpeg, GStreamer
      and now OpenCV repin GCC's target library per build. Work: make the Vulkan step link only libraries whose
      ELF machine matches the dir's arch, or skip the target dir under a cross build; drop the three repins once
      a rebuilt sdk proves the link correct. Done when `file -L /usr/lib/aarch64-linux-gnu/libstdc++.so` in a
      fresh `cross-sdk-arm64` says AArch64 and no consumer needs the pin.
- [ ] **CON173 — `onnxruntime-web` compiles uncached; ccache holds the seat, S3 does not reach it** [S, ★★]. The
      2026-10-28 audit found one compile RUN with no cache at all: the WebAssembly ORT build (emcc, 3857 objects,
      ~40 min). sccache as `EM_COMPILER_WRAPPER` failed every CMake try_compile of the wasm configure on a targeted
      amd64 build of the `onnxruntime` stage (2026-10-29: `18 unsupported compiler calls, 738 non-cacheable calls`,
      `Could NOT find Iconv`, 6 of 6 tests failed), so `40-build-wasm.sh` exports `EM_COMPILER_WRAPPER=ccache`
      (emscripten's documented wrapper) and prints `ccache-stats|`; the RUN mounts both caches and the S3 secret
      and drains. Proved the same day on the same targeted build: all four wasm flavors in 25 min, `Cacheable
      calls: 47015 / 52217 (90.04%)`, `Hits: 12853`, `Misses: 34162` on the first fill. ccache is disk-level only: this RUN's objects live on the host's cache mount, not in the shared
      S3 level. Work: find why sccache rejects emcc's clang (its debug log names the parse failure) or give the
      wasm step its own S3-backed ccache remote. Done when a media chain's web RUN shows `ccache-stats|` hits and,
      for the S3 half, an upload path.
- [ ] **CON175 — the CUDA cross compiles bypass sccache; prove the fix on a chain** [S, ★★]. The arm64 nvidia
      media chain's ORT GPU RUN (2026-10-29) logged `3856 requests, 3210 hits, 0 misses, 36 errors, 609 not
      cacheable`: every C/C++ object hit, the 609 kernels ran uncached, the RUN's two hours. Cause, reproduced
      in the gpu image with `SCCACHE_LOG=debug`: sccache's nvcc parser reads `-target-dir sbsa-linux` as a second
      input file (`CannotCache(multiple input files)`); `--target-directory=sbsa-linux` parses and hits. In
      source since 2026-10-29 (`cross-cuda.sh`, `verify-cuda-stack.sh`, OpenCV's `CUDA_NVCC_FLAGS`). First run with
      the flag (2026-10-29 14:25): `Cache misses (CUDA) 598`, `(CUBIN) 1188`, `(PTX) 1533`, `Non-cacheable calls 0`,
      `L1 (s3): 3928 written, 0 failed` -- every kernel is cached now; the 609 "non-cacheable compilations" are
      sccache's count of the outer nvcc calls whose sub-compilations it caches. Done when the NEXT rerun of the RUN
      shows `Cache hits (CUDA)` above 90 % and the RUN takes under 30 min.
- [ ] **CON174 — image acceptance clones the cyclic submodules recursively** [S, ★]. `image-acceptance.py`'s
      consumer clones use `--recursive`; the ANTfrastructure → DocumANTation → awesome-beamer → ANTfrastructure
      cycle is finite but cost 29 GB and 15 min per receipt on 2026-10-28 (`logs/image-acceptance/*/consumers`).
      Work: clone each consumer with `--recurse-submodules=<the paths the smoke needs>` or depth-limited, and
      remove the tree after the receipt. Done when a receipt's consumer tree stays under 5 GB and the directory
      is gone afterwards.

- [ ] **CON163 — every Linux compile reaches sccache; prove it on a chain** [S, ★★★]. In source since 2026-10-26
      ([`build-cache-tiers.md`](docs/build-cache-tiers.md#a-subproject-that-forces-its-own-launcher)): the Vulkan
      SDK RUN mounts both caches and pins its launcher, and ONNX Runtime, LiteRT and the riscv64 torch wheel pin
      `CCACHE_BINARY` against pthreadpool's FORCE, gated by `cmake_assert_compiler_cache_pin`. Done when a second
      chain's `sdk-arm64`/`sdk-riscv64` dependency step and ONNX Runtime's `onnxruntime 2/9` step log
      `sccache-stats|` hits above 90 % of their compiles, and the Vulkan step drops below 10 min.
- [ ] **CON164 — the S3 level drops uploads; prove the re-put on a chain** [S, ★★]. The 2026-10-26 chain's drains logged
      `L1 (s3): 3 written, 9 failed of 12` and `6 failed of 9`; on 2026-10-29 the arm64 GStreamer RUN logged
      `229 written, 3 failed of 232` with the cause: `write close failed Unexpected (temporary) at write => send
      http request` (a transient S3 write that sccache never retries). In source since 2026-10-29: the drain re-puts
      every object the server log names from the disk level (`docs/build-cache-tiers.md` § The shared S3 level).
      Done when a chain's drain with failed writes prints `re-uploaded N of N` and the next chain shows the hits.
- [ ] **CON165 — ONNX Runtime builds with one job under `--parallel-archs`; prove the governor on a chain** [S, ★★★]. In source since 2026-10-27: the launcher's compile governor and `PAR_INTRA_STEP_BUDGET=2` ([docs](docs/build-parallelism-memory-tuning.md#the-compile-governor)). Done when a chain's resource trace keeps `compilers` at or under 32 with no OOM kill and ONNX Runtime and IREE log more than one job. Found 2026-10-26:
      `Using JOBS=1` in `media-arm64.log`, since `compute_jobs_with_mem_cap "" 2000` divides RAM by
      `BUILD_MEM_DIVISOR=18` (3 arches × `PAR_INTRA_STEP_BUDGET=6`). With the cache warm a serial build costs
      little; cold, it is the 104 min step. Measured 2026-10-27 (`resources-20261027-024119-*.csv`, 32 cores,
      62 GB): over the media stage the median CPU was 12 % with 4 compilers running, while memory peaked at 54 GB
      used and the 8 GB swap filled, so a fixed divisor is too tight for the long idle tail and right for the
      peaks. amd64 builds its ONNX Runtime variants one after another at one job each, hours after arm64 and
      riscv64 have moved on. Work: measure ONNX Runtime's peak per job, then size its jobs from `MemAvailable` when
      the step starts instead of the static `BUILD_MEM_DIVISOR` share
      ([`build-parallelism-memory-tuning.md`](docs/build-parallelism-memory-tuning.md)). Done when that step
      logs more than one job on an idle host and no arch is OOM-killed. IREE's wheelhouse build has the same
      cause: both its host and target LLVM builds ran `cmake --build … -- -j1` for over 3 h on arm64 and riscv64.
- [ ] **CON167 — a knob defaulted inside one function and read before it runs** [S, ★★★]. The 2026-10-22
      knob moves (`72d3aa76`, `96cbe525`) put `: "${X:=…}"` at the top of one function while another reader, or
      the top level, could run first. Under `set -u` that stopped GStreamer twice on the 2026-10-27 chain
      (`GSTREAMER_DEBUG_LOGS`, `GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR`; fixed). `build-clang.sh` reads
      `CLANG_NUM_JOBS` and `CLANG_BUILD_MB_PER_JOB` at top level before `run_preflight_checks` sets them, and
      `test-clang-job-policy.sh`, red since before, pins an `unbound variable` receipt for that path: decide
      the intended behaviour there first. Work: a gate that flags a bare `${X}` read where no default of `X`
      has run on every path; the pattern scan that found these also listed three safe callers (sccache-s3-level,
      iree-wheelhouse, build-runtime-manifest), so it needs call order, not just scope. Done when the gate
      catches both GStreamer cases as mutations and `build-clang.sh` has one defined default.
- [ ] **CON168 — arm64 and riscv64 build the same IREE host LLVM at the same time** [M, ★★]. Found 2026-10-27:
      both media lanes run `/tmp/app-wheelhouse/iree-build-host` with the build host's `/usr/bin/g++` at once, so
      the second lane cannot hit the cache the first is still filling. Work: build the host stage once per chain
      (a shared step or a cached artifact keyed on the IREE pin), or let the second lane wait for the first's
      cache. Done when only one lane compiles the IREE host LLVM per chain.
- [ ] **CON169 — an arch waits for every other arch before its next stage** [L, ★★★]. Measured 2026-10-27:
      `media-arm64` and `media-riscv64` were pushed at ~09:35 and their android stages waited ~2 h for amd64's
      ONNX Runtime and OpenCV. `build-cross-chain.sh` runs one `run_parallel_arch_loop` per stage and joins it,
      although `android-<arch>` needs only `media-<arch>`. The join carries three things: the image-store lever
      runs only with nothing in flight ([`build-cache-tiers.md` § 3.2.2](docs/build-cache-tiers.md#322-the-image-store-lever-disk3)),
      pins and ancestry are harvested per stage, and the disk estimate assumes all lanes are in one stage. Work:
      one pipeline per arch through the stages, with an image lever scoped to the tags of arches that are not
      building, and a disk gate per arch. Done when a chain starts an arch's next stage as soon as that arch's
      previous one is pushed, without an image removal under a running build.
- [ ] **CON170 — the uv installer pin follows a moving URL** [S, ★★]. `python_uv.sh` (`uv_ensure_installed`, used by
      `lib/dartdoc-build.sh` and consumer hosts) runs `https://astral.sh/uv/install.sh`, which installs the newest uv
      (0.13.6 on 2026-10-27) and changes with every release, so `UV_INSTALL_SH_SHA256` (`283cbef4…`) matches neither it
      nor the pinned `UV_VERSION=0.13.1`. Work: run `https://astral.sh/uv/${UV_VERSION}/install.sh` and pin
      `7c482d409673a53f4d9bd34ae95c9166be3b8d89ca82f27dd7bca3cab457afff`, byte-identical on 2026-10-27 to the
      GitHub release asset `uv-installer.sh` of 0.13.1, and let `bump_versions.py` move it with `UV_VERSION`.
      `versions.env` re-keys `Dockerfile.base`, so this rides a planned rebuild. Done when `uv_ensure_installed`
      installs exactly `UV_VERSION` through a hash that no uv release can rotate. The 2026-10-27 mirror fill refused it
      (`FAILED 283cbef4bdac install.sh`), the only one of 33 assets.
- [ ] **CON171 — a stopped chain leaves BuildKit records in use** [S, ★★]. Found 2026-10-27: after a
      stopped run, the runtime lane's entry reclaim freed 0 of 165 GiB layer cache and refused at 376 GB free;
      once `systemctl --user restart buildkit` ran with nothing building, `prune-safe.sh` freed 116 GB and kept
      all 114 cache mounts. The disk preflight also adds the lane's ~415 GB to the stage cost under
      `--from-stage runtime` (~535 GB) and only warns. Work: in the reclaim, with no build in flight, restart
      buildkitd before the layer prune; count the lane once. Done when a chain resumed after a stop reclaims
      without a hand restart.
- [ ] **CON166 — an asset-mirror miss logs `curl: (22) … error: 404`** [S, ★]. Found 2026-10-26: every
      miss prints curl's error line before `asset-mirror| miss`, so a log search for `error` hits each pinned
      download that falls back upstream. Work: keep the mirror GET silent on HTTP errors and let the miss line
      speak (`01-core/downloads.sh`). It is mounted per file by `Dockerfile.base`, so it rides a planned
      rebuild from base. Done when a miss logs only its `asset-mirror| miss` line.
- [ ] **CON153 — the pinned release assets come from the Garage mirror** [S, ★★★]. Owner decision
      2026-10-26: Garage S3. In source ([`linux-cross-builds.md` § The asset mirror](docs/linux-cross-builds.md#the-asset-mirror),
      runbook in [`linux/sccache-s3/README.md`](linux/sccache-s3/README.md)): every `download_verified_file`
      asks `<mirror>/<sha256>/<name>` first and falls back upstream, through the `asset_mirror` BuildKit
      secret. The bucket, both keys and this host's env files exist since 2026-10-26 (`--check` passes); a
      new chain host runs `set-asset-mirror.sh --from <ssh-target> --url <bucket-url>`. Filled on 2026-10-27 from that chain's
      misses: 32 of 33 assets; the uv installer refused its pin (CON170). Done when the next chain logs
      `asset-mirror| hit` for the pinned assets.

- [ ] **CON129 — finish GTK 4 validation on foreign arches and GPU variants** [M, ★★★].
      The mandatory `gui_unix` feature is enabled in OxidANT. On the recorded `3c558d88` index,
      its x64 run `39865676735` passed 728 normal and 728 instrumented tests with real Xvfb/GTK;
      all GUI coverage floors passed. That closes the x64 consumer blocker, not every image lane.
      Left, using [`consumer-image-contract.md` § GTK 4 for
      gtk4-rs](docs/consumer-image-contract.md#gtk-4-for-gtk4-rs):
      1. Record the package-stage `verify_gtk4_dev_surface` and runtime `gtk4-dev` verdicts for
         all three default children and the next nvidia/rocm builds. Preserve riscv64's GLib
         handoff, plugin health and SHIPPED-TRUTH D checks.
      2. Prove the mandatory GUI build in OxidANT's arm64 lane and its riscv64 sysroot test.

- [ ] **CON131 — pwsh in the Linux image; then OrchestrANT's `benchmarks.yml` contract job moves into
      `:latest`** [S, ★★]. Found with CON124 (2026-10-20): in `:latest` the contract job's 41 PowerShell
      tests skip (`pwsh is not on PATH`, `benchmarks/tests/test_bench_coding_powershell.py` and
      `test_bench_coding_tasks.py:189`), as on every other lane (Linux: no pwsh; Windows: "the harness is
      POSIX-only"), so the job's bare runner is their only run. In source: the package stage's
      `install_pwsh` puts pwsh `PWSH_VERSION` and PSScriptAnalyzer `PSSCRIPTANALYZER_VERSION` on amd64
      and arm64 ([`consumer-image-contract.md` § PowerShell](docs/consumer-image-contract.md#powershell));
      riscv64 has neither. Proved in throwaway containers of `:latest` `b52f8c34`, no chain build:
      amd64 and arm64 (QEMU) install both and list the module as uid 1001, riscv64 prints the note, and
      OrchestrANT's contract command passes 2411, skips 2 on 3.14 and 3.14t (2370 and 43 without pwsh).
      The 2026-10-27 chain installed pwsh 7.6.7 and PSScriptAnalyzer 1.25.0 on amd64 and arm64 and printed
      the riscv64 note.
      Left: OrchestrANT's contract job moves in, prepared in CON124: its checkout, `setup-uv` and `run`
      become `prepare-linux-ci-host` (`fetch-depth: '1'`, `submodules: 'true'`) and two
      `run-in-linux-container` steps, `extra-args: --network host -e OLLAMA_BASE_URL -e TEST_TIMEOUT`,
      `script: bash benchmarks/ci-image-leg.sh pinned` (then `pinnedt`, `if: ${{ !cancelled() }}`)
      `--extra test bash benchmarks/ci-contract-tests.sh "${OLLAMA_BASE_URL}"`, the two variables as
      job `env:`, `timeout-minutes: 45`, and the "On the runner until" comment gone.
      Done when that job's run shows the PowerShell tests passed on both legs.

- [ ] **CON99 — measure, then maybe publish `:latest` with zstd layers** [M, ★★]. Every Linux CI
      job pulls the whole image: `:latest` amd64 is 72 layers, 12.84 GB, all `tar+gzip`
      (manifest read 2026-10-17). In OmniAccelerANT's Linux x64 run 39041777817 the background
      pull ran 14:41:48 → 14:48:53, 7 of the job's 16 min: ~30 MB/s for 12.84 GB, far under a
      hosted runner's ghcr bandwidth, so serial unpacking is the likely cap. The runner image has
      pigz 2.8, which dockerd may already use, but unpigz decompresses mostly on one thread. The
      cross stages already push `compression=zstd` (PUSH1); the final publish does not. Measure
      before switching, without the build host: on a hosted runner `skopeo copy
      --dest-compress-format zstd` the tag into a scratch package, then `time docker pull` the gzip
      and the zstd tag in two fresh jobs, and delete the scratch package. The cost is one full re-push of every layer per arch at the build host's
      ~4.5 MB/s uplink, and every consumer re-downloading once; Docker 23+, containerd and podman
      all read zstd layers.

- [ ] **CON90 — finish the Python 3.15 rollout and remaining measurements** [L, ★★★].
      The default-image and x64 consumer rollout is recorded under
      [`image-decisions.md`](docs/image-decisions.md); do not repeat the old 3.14 blocker.
      The 2026-10-22 arm64/riscv64 observations also proved that `/usr/local/bin/python3.15`
      runs and its sysconfig `AR` exists. Left:
      1. Prove the 3.15 `:latest-rocm` rebuild, including its ABI-specific wheels and twins.
         The nvidia 3.15 publish was already proved on 2026-10-19 (run `20261019-055155`).
      2. Retain explicit per-ABI wheel/store verdicts on foreign arches; the x64 consumer runs
         do not prove every arm64/riscv64 wheel or free-threaded leg.
      3. PGO on arm64 needs a native arm64 toolchain build; cross arches currently get LTO alone.
         Measure the toolchain's CPython time on a four-core CI runner; 25–40 minutes remains
         an estimate. Keep the single-pin contract in [`python-ci.md`](docs/python-ci.md).

- [ ] **CON123 — Linux app bundles carry the image's own CPython; prove on arm64** [M, ★★].
      In source since 2026-10-26 ([`python-app-bundles.md`](docs/python-app-bundles.md#the-relocated-image-cpython)):
      `python-relocate.py` stages a relocated copy of `/usr/local`'s CPython at bundle time (no new image
      tree; `--python-runtime standalone` keeps the download), and the smoke's `RELOCATABLE-PY` row passed on
      the published amd64, arm64 and riscv64 children. An amd64 bundle built under `--network none` and its
      moved copy passed the self-test. Left: an arm64 consumer bundle (the closure now copies the distro's
      libssl, sqlite, libffi into `runtime/lib`), and OrchestrANT's release logging no `Downloading cpython`.
      `import readline` is absent in bundles on purpose (GPL-3).

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
        `forward_ambient` in run 37354297722, `headless` in run 37005853556. 82b3677 passed
        on the same image three hours before the first of those, and no amd64 run has
        shown it. Until ebcfbe60 lands, check that the
        crash is gone before calling a red arm64 renderer test a regression. A narrower
        `ENV` (only the BVH build needs the 8-lane subgroup) would also avoid it. The consumers
        that build no BVH narrow it themselves since 2026-10-06: OxidANT's
        `ci-container-steps.sh` (580e097) and BeschleunigerBallett's `run-cargo-tests.sh`
        export 128 on aarch64. Four of about twenty OxidANT arm64 runs since 2026-10-05 had
        died on it, one as a SIGSEGV in `forward_ambient` rather than an `LLVM ERROR`.
      - **The Windows lane pins 256 too** (`Install-LavapipeHost.ps1`, `Dockerfile.media-merge-builder`,
        `Test-Arm64Bundle.ps1`), and BeschleunigerBallett's arm64 GPU suites crash intermittently
        with `0xC0000005` on a worker thread in the cloud passes (its #97, from 2026-10-16), the
        prime suspect being the same JIT. Its suites now link `kataglyphis_add_crash_dump`, so the
        next crash shows whether the frame is JIT code (no module) or `vulkan_lvp.dll`. The fix:
        when mmozeiko/build-mesa publishes 26.3.x (26.2.5 is its newest on 2026-10-28; ebcfbe60 is
        in `26.3.0-rc2`), move `LAVAPIPE_VERSION` and drop the 256 pin on arm64 on both lanes.

- [ ] **CON137 — Playwright in `:latest`, so the Flutter web console capture runs in a lane** [S, ★★].
      Found 2026-10-21, sharing OmniAccelerANT's web side with jotrockenmitlocken.
      `linux/webserver/scripts/flutter_capture_console_errors.py` needs the Python `playwright`
      package. `:latest` ships Chrome for Testing (`CHROME_EXECUTABLE`) but not that package, so
      the capture is hand-run, and neither app's web lane runs it. Proved by hand in a throwaway
      container of `:latest` `b52f8c34`: playwright pip-installed into `/tmp`, then
      jotrockenmitlocken's wasm build over 21 routes gave 38 passed, 0 failed, no console errors.
      Next: the image installs `playwright` into its venv, without its browser download (the
      script launches `CHROME_EXECUTABLE`). Then jotrockenmitlocken's `web.yml` smoke step and
      OmniAccelerANT's web lane run the capture after the smoke test, each with its `--route` list.

- [ ] **CON147 — the web engine's fallback fonts in `:latest`, so a web build downloads none** [S, ★].
      Found 2026-10-21 with jotrockenmitlocken's emoji fix. `fetch-fallback-fonts.py` puts the 18
      files of `fallback-fonts.lock` (Noto Color Emoji and Noto Sans Symbols 2, 2.3 MiB) into each
      web build, from fonts.gstatic.com through a cache that dies with the container, so every CI
      build downloads them. Next: the SDK stage fetches them into a read-only directory beside
      Flutter, and the fetcher reads it before its writable cache (today `cache_lock` opens
      `<cache>/.lock`, which a read-only layer refuses). Done when a build with fonts.gstatic.com
      unreachable places all 18, and a Flutter bump re-pins the lock in the same change.
      Status 2026-10-21: implemented (store in `linux/Dockerfile.sdk`, read-first in the fetcher, 21 test
      assertions under WSL); open until a family image build shows the 18 placed without a download.




- [ ] **CON162 — step labels in the published images** [S, ★★]. In source since 2026-10-26: a
      `LABEL kataglyphis.step=<name>` before each of the 104 RUNs in `linux/Dockerfile.*`, graded by
      `verify_dockerfile_step_labels.py`, and `layer-audit.py` prints each layer's step. Done when
      `nerdctl history` of the next `:latest` names every step and `layer-audit.py` names the Android SDK
      layer `step=android-sdk`, with already-built layers still `CACHED` across each stage handoff.
      The 2026-10-27 amd64 child's history carries 17 `kataglyphis.step` labels (package and torch);
      left: `layer-audit.py` on `:latest` and the `CACHED` check.

## Open — Linux arm64 and riscv64

- [ ] **CON130 — riscv64 cross runs still inherit the amd64 GStreamer plugin path** [S, ★★].
      The build-time half is in (c40797cc, 2026-10-25): `riscv64_cross_env` unsets `PKG_CONFIG_PATH`
      and its riscv64 twin, and `riscv64-cross-smoke.sh` uses that environment, so a host `.pc`
      fails before consumer tests ([`riscv64-cross-test-lanes.md`](docs/riscv64-cross-test-lanes.md)).
      Left:
      1. Prove it on the three riscv64 consumer lanes (OxidANT, AccelerANTgine, BeschleunigerBallett),
         which load the library at `@develop`: gtk4-sys must resolve riscv64's 4.22.4 `gtk4.pc`.
      2. **The run-time leak:** the riscv64 QEMU test processes inherit the amd64 `GST_PLUGIN_PATH`
         (and registry) and try `/opt/gstreamer/lib/x86_64-linux-gnu/gstreamer-1.0/*.so`, about 300 load
         warnings per process (OxidANT run 39487523314, 2026-10-20); harmless today. Point the run at the
         sysroot's riscv64 plugin dir.

- [b] **CON135 — the active braces advisory has no patched version** [S, ★].
      Observed 2026-10-23 in `linux/scripts/renovate-npm/package-lock.json`: braces 3.0.3
      ([GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm), high, via
      micromatch) still has an active advisory and no first patched version. Blocked on a fix;
      use the local Renovate workflow when one exists ([`dependency-updates.md`](docs/dependency-updates.md)).
      The second repository alert, sprintf-js 1.1.3 via roarr, is still open, but its advisory
      [GHSA-hp3w-g68c-fv3c](https://github.com/advisories/GHSA-hp3w-g68c-fv3c) was withdrawn
      on 2026-10-22 at 19:21:04 UTC. Withdrawal is not a package fix; neither alert was dismissed.

- [ ] **CON145 — `cxxbridge` in the Linux and Windows images** [S, ★★]. Found 2026-10-21 with
      BeschleunigerBallett 7f54642c: every BB configure runs `_myproject_find_or_install_cxxbridge`,
      an unpinned `cargo install cxxbridge-cmd` at build time, because neither `:latest` nor
      `:winamd64` carries it (everything-in-the-image rule). Pin `CXXBRIDGE_CMD_VERSION` in
      `versions.env` to the `cxx` OxidANT's `kataglyphis_cxx_bridge` locks (the two must match),
      install it in both images, and make BB's helper refuse a missing or mismatched binary in CI.
      **Windows in source since 2026-10-27:** `CXXBRIDGE_CMD_VERSION=1.0.205` (OxidANT's lock), baked by
      `Install-RustToolchain.ps1`, asserted by the smoke. Left: the next `:winamd64` passing that assert,
      `:latest` (web-lane tools, three arches), and BB's helper.

- [ ] **CON110 — OrchestrANT's riscv64 free-threaded leg needs a seeded cache** [M, ★]. Its
      riscv64 lane (`linux-riscv64.yml`) runs `pinned` alone: run 38562273950 (2026-10-14) took
      the riscv64 job 3 h 52 min for the GIL leg, 137 min of it source builds under QEMU (its lock
      had moved past the seed's numpy, matplotlib and contourpy) and 74 min pytest. In source since
      2026-10-20 (CHANGELOG): the seed's second pass on X.Yt, and the torch stage's fix for the X.Yt
      sysconfig's `ar`, which the riscv64 and arm64 images lacked; proved in `:latest`'s riscv64
      child, 15 wheels for 3.14.4 and 3.14.8t. From that seed, OrchestrANT de144d10's `3.14t` leg
      under QEMU built no dependency and passed (2529 tests in 62 min; the 6 that read the hub
      submodule's `backends.json` passed with it checked out). Left:
      1. a `:latest` built from it;
      2. OrchestrANT's `linux-riscv64.yml` asks for `pinned pinnedt`, and a dispatched run passes
         both legs inside 360 min.

      The seed covers the lock at `APP_REF`; a lock that moved since rebuilds what moved, once per leg.

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
      Flet's Linux client for riscv64 (CON102) waits on the same engine; OrchestrANT's
      `frontend` extra leaves riscv64 out until then.

## Open — Windows `:winamd64`

- [ ] **CON93 — the torch venv's sdists compile with VS's `cl` and cannot link against the in-tree CPython**
      [S, ★★]. Found 2026-10-12 by probe P13 on the 3.15 toolchain image. line-profiler 5.0.2 and pyyaml 6.0.3 have no
      cp315 wheel, so `uv sync` builds them with setuptools.
      - setuptools takes VS's `HostX86\x64\cl.exe` and `link.exe`, against the clang-cl rule.
      - The link fails `LNK1104 python315.lib`: setuptools looks in `sys.base_exec_prefix\libs`, which the in-tree
        build lacks, and in the venv's `PCbuild\amd64`.
      - Fixed in source: the toolchain copies the GIL import libs into `C:\temp\cpython\libs`. The torch stage syncs
        under a clang-cl/lld-link/llvm-lib shim (`DISTUTILS_USE_SDK`), and a Rich-header gate checks what uv built.
        Smoke section 2 checks the libs.
      - **Proven by chain bk-20261013-004816 (2026-10-13):** the toolchain staged `python315.lib` and `python3.lib` in
        `C:\temp\cpython\libs`. The torch stage built antlr4-python3-runtime, line-profiler, orchestrant and pyyaml from
        source under the shim and passed the Rich-header gate. Smoke section 2 passed the libs check.
      - **Left:** the x64 consumer lanes (`Invoke-PythonCiBuild.ps1` since 2026-10-19, `Invoke-CiPackaging.ps1`)
        still build third-party sdists with VS's `cl` (`Invoke-PythonTestLegs.ps1` went with CON113). OrchestrANT's own `setup.py` switches to clang-cl but links with
        `link.exe`, so moving those lanes onto the shim changes its linker too and needs its own proof.
- [ ] **CON95 — finish ORT 1.31.0's ROCm rollout and consumer API update** [M, ★★].
      The recorded default index `3c558d88`, Windows images and `:latest-nvidia` already carry
      chain ORT 1.31.0. Left: prove it in the next `:latest-rocm`, then move OxidANT from its
      current exact `ort` 2.0.0-rc.13 pin to rc.14 with its own tests.
      Compatibility evidence for the remaining rebuild (read from the two tags' sources):
      - Dawn v20260818.211311 → v20260916.214021: `ORT_WEBGPU_WINDOWS_DAWN_SHA256` is
        `507949fd45d7ca0cfc672617fd1e06ee02ce23c4f32856b342c48133e71d682e` (full download, 2026-10-13), its SHA1 equal
        to deps.txt's `514e914f…`. ORT's six Dawn patches apply to it with GNU patch, five with fuzz.
      - That Dawn creates the DXIL validator from `dxcompiler.dll`, and v1.31.0 ships no `dxil.dll`. The rocm spike
        stages only `dxcompiler.dll`, and its build gate and smoke now fail on a leftover `dxil.dll`.
      - GenAI v0.17.0 does not compile against v1.31.0's headers: the model-package entries it resolves left the
        experimental header for the stable `OrtModelPackageApi` table (64 GCC errors). Both lanes apply
        `onnxruntime-genai/002-ort-1.31-model-package-api.patch`. A syntax-only compile in `:latest` passes with GCC
        and clang against both ORT versions. GenAI `main` and `rel-0.17.1` still carry the old code.
      - KleidiAI v1.20.0 → v1.30.0, SHA1 equal to deps.txt's `36aebdd5…`: one `enable_language(ASM_MARMASM)` and no
        rule of its own, so the arm64 rule patch still applies. Its new SVE2p1 `.S` files are new to armasm64.
      - The D3D12 agility SDK, google_benchmark, coremltools and the 1DS SDK move too; the hub builds none of them
        (no `DAWN_USE_AGILITY_SDK`, no benchmarks, telemetry off). The vendored onnx stays 1.22.0, pybind11 v3.0.2,
        flatbuffers 23.5.26.
      - `patches/onnxruntime/001-gcc16-epilogue-scalars-reference.patch` is gone: v1.31.0's
        `moe_gemm_tma_ws_launcher.inl:535` carries upstream's own `std::remove_reference_t` fix.
        `001-android-gradle-agp8-compat.patch` and the five Windows ORT patches apply to v1.31.0.
      - Every build.py flag and CMake define the native, nvidia, amd, wasm, android, GenAI and Windows builds pass
        still exists. The free-threaded twin row was re-read at v1.31.0.
      - **Proven on Windows** by the chains of 2026-10-16/17, published 2026-10-17: the venvs install `onnxruntime`
        1.31.0 and GenAI 0.17.0 as cp315 (`onnxruntime-genai-cuda` in the nvidia chain bk-20261017-103208); the rocm
        chain bk-20261016-184041 passed `OrtWebGpu.ps1` on Dawn v20260916.214021 with DXC v1.9.2609 and loaded
        `migraphx-ep.dll`; `windows-11-arm` imported ort 1.31.0 from `:winarm64` (hub run 39200278761). **Linux:**
        `:latest-nvidia` of 2026-10-19 ships v1.31.0 with GenAI v0.17.0 (CUDA, with `002`'s `<cstdint>`).
      - ORT configure still builds onnx from source: v1.31.0 fails on a found ONNX package
        with a different protobuf. The default-image consumer proof does not substitute for
        the ROCm EP and GenAI rebuild.
- [ ] **CON96 — the arm64 and riscv64 children without the x86_64 host payload** [S, ★★]. Owner request
      2026-10-13 (CI prologue measures, item 5). **In source since 2026-10-13 (CHANGELOG); the next chain proves it.**
      `prune-host-payload.sh` empties `/opt/android-sdk`, `/opt/android` and the builder's rustup in `artifact-source`
      for every arch outside `HOST_PAYLOAD_ARCHES` (default `amd64`), and the package stage leaves the eight Android
      variables empty there. Proved without a chain: the BuildKit ENV expansion, and the script over the real trees of
      the amd64 `:latest`. Left for the chain:
      - The package log lines in [`build-watch-list.md` § The host payload](docs/build-watch-list.md#the-host-payload-con96-new-2026-10-13)
        on all three arches, and the arm64 package RUN's native Rust reinstall over the empty tree.
      - The smoke green on arm64 and riscv64: `SKIP android-home`, the ABI gate's `SKIP`, ARCH-PARITY still finding
        `android` and `android-sdk`.
      - The published arm64 child about 3.4 GB smaller than `448591ff…` (10.11 GB), and riscv64 against `7689579f…`
        (8.51 GB), with amd64 unchanged in content.
      - One arm64 consumer pull timed against the 4.19 min median: about 1.1-1.3 min less is expected.

- [b] **CON27 — MSVC STL 14.51 breaks `find`/`count`/`remove` on odd-sized structs
      under clang-cl** [S, ★]. Blocked upstream (checked 2026-10-02): microsoft/STL#6294
      is open, its fix #6298 awaits review, and neither 14.52 nor 14.53 Preview carries it.
      The toolset is VS 18's stable channel, not a pin that could move.
      BeschleunigerBallett's `find_if` stands (c2237c0f). Never set
      `_USE_STD_VECTOR_ALGORITHMS=0` image-wide: it turns every vectorized algorithm off.
      Close when a production toolset ships #6298.
- [b] **CON54 — Let the litert-lm CMake superbuild consume the already-built LiteRT
      install** [M, ★★]. The hub flow builds LiteRT (bazel, `LITERT_VERSION=v2.2.0` =
      145c7523, 2026-08-06; v2.3.0 = 4352e261, 2026-10-07, since 2026-10-13) and then
      litert-lm's superbuild builds LiteRT a SECOND time
      from `litert.cmake`'s `GIT_TAG main` — two different copies in one product, both
      floating (v0.17.1's WORKSPACE pins 9fe5be45, 2026-08-27, 3 weeks NEWER than the
      v2.2.0 prebuilt, 6 weeks older than v2.3.0). The harness already sends `CMAKE_PREFIX_PATH=C:\runtime\lib\litert`
      but the lane has no consumer for it: the top-level orchestrator is LANGUAGES NONE,
      and litert.cmake defines litert_external unconditionally (its "already installed"
      message prints on every path; the only skip fallback sits behind a FATAL_ERROR
      else-branch). Upstream-PR-shaped feature: a `LITERTLM_LITERT_PROVIDER=installed`
      (or honored prefix) that keys the aggregate/target-map/include-paths at the
      installed tree instead of the EP build dir. Side value: it removes the litert EP
      from the graph — the chunk where google-ai-edge/LiteRT#tensor/examples
      (gemma3's find_package(Protobuf REQUIRED)) fires, and the largest slice of the
      superbuild's wall time. The direct-consumption build is also the sharpest
      API-skew probe: if the pinned LiteRT lacks what litert-lm's sources use, the compile fails
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
- [ ] **CON89 — what rides the next full Windows chain** [M, ★]. Each item re-keys `Dockerfile.base` or the media
      stages, so landing one alone would cost a rebuild of its own. They go in with the next planned full rebuild.
      **Rode the chains of 2026-10-16/17** into the images of 2026-10-17: the `vswhere` splat fix (its base re-key, PowerShell
      7.6.7, is in `:winamd64`'s history), the pinned pip installs, VVL's and x265's `/w` (arm64 merge log of
      bk-20261016-211745: 138,210 lines, against 6.2 M for the VVL vertex alone), bazel, the JDK and git-lfs from the
      pinned tool cache, and the patched LLVM built with the pinned clang-cl (rocm chain bk-20261016-184041). Left:
      - IREE's VM ISA genrule on the GIL interpreter (`IREE_ISA_PYTHON`, CON79 item 1, optional).
      - `UV_WINDOWS_ARM64_SHA256`: removed in source 2026-10-27 with its `bump_tools.py` row; rides the next chain.
## Open — the Windows arm64 bundle and unpublished variants

- [ ] **CON108 — the Windows arm64 device runs OrchestrANT's Flet tests** [S, ★].
      `Stage-Arm64Tests.ps1` stages from `:winarm64`'s `PYTHON_WHEELS`, which has no Flet, so
      `test_view.py`, `test_flet_viewer.py` and `test_streaming.py` skip on the device. flet,
      flet-desktop, oauthlib and repath are pure Python; msgpack 1.2.3 has a cp315 `win_arm64`
      wheel. Add them to the store and to OrchestrANT's staging list.
      **Store in source since 2026-10-27:** the closure at OrchestrANT's lock (flet/flet-desktop 1.0.4, httpx,
      httpcore, h11, anyio, rich, markdown-it-py, mdurl, oauthlib, repath, msgpack) as `PYTEST_WINDOWS_ARM64_*`.
      Left: the next `:winarm64`, then OrchestrANT's staging list and a device run without those skips.
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
- [b] **CON31 — Variants that are not published** [L, ★]. `:latest-nvidia` and `:latest-rocm` (amd64) were
      published on 2026-10-28 from this host (TensorRT 11, DeepStream, ROCm; two gates fixed on the way, CHANGELOG).
      The owner reversed the arm64 decision on 2026-10-28: NVIDIA arm64 must build natively AND cross. Plan with
      phases A-E in `logs/research/nvidia-arm64-native-and-cross.md` (local); phase C (the cross gpu stage,
      `CROSS_NVIDIA_SBSA=1`) landed the same day, phases D (media CUDA consumers) and E (package stage) are next,
      then A/B (native route first-class, manifest merge). Earlier decision for the record (2026-10-20): TensorRT 11 and the ORT TensorRT
      EP in `:latest-nvidia`, and a `:latest-rocm` that finds its ROCm and opens an AMD GPU; not the arm64 nvidia route.
      Both are in the source since 2026-10-21, hub f6771ee4 (`docs/linux-accelerator-images.md` § TensorRT 11,
      § Running it on an AMD GPU, § The GPU runtime gate). No image carries them yet.
      - `:latest-nvidia`, TensorRT 11: `ENABLE_TENSORRT=true` on amd64; exactly `11.4.0.106-1+cuda13.4` from NVIDIA's
        `ubuntu2604` repo; only the runtime `.so` files ship, which the SLA names distributable (§ Redistribution).
        Proved in a throwaway container on the published `0e9dec34…` (no GPU): the hub's `install-tensorrt.sh`
        installed the twelve packages (1.93 GB of debs), `getInferLibVersion()` 110400, and ORT v1.31.0 with the hub's
        flags configured (`NV_TENSORRT_MAJOR is 11`) and built its TensorRT EP (§ TensorRT 11, Measured). The next
        nvidia chain must show:
        - gpu: `TensorRT: 11.4.0.106-1+cuda13.4 installed (12 packages)`;
        - media: the GPU ORT's `NV_TENSORRT_MAJOR is 11`, GenAI built without `--use_trt_rtx`, and
          `deepstream-verify.sh`'s `DeepStream links TensorRT 10 from … only`;
        - wrapper: `assemble-torch-app.sh verify` passing its `TensorrtExecutionProvider` assert;
        - runtime smoke: every `GPU-RUNTIME` row passing, the TensorRT ones included, and the image about 2.8 GB
          larger than `0e9dec34…`;
        - on the RTX 2080 host: a session over the smoke's Add graph with `TensorrtExecutionProvider` building an sm_75
          engine and returning `[[11, 22, 33, 44]]`, and the DeepStream gate pipeline still passing.
      - `:latest-rocm` (published `a5d68fbe…`): it had no `ROCM_PATH`, `HIP_PATH` or `/opt/rocm/bin` on `PATH`, so the
        venv's rocm-sdk `hipcc` could not link a HIP program; and uid 1001 cannot open a `0660` render node without
        `--group-add`. Fixed in `Dockerfile.package` (the roots), the entrypoint (a warning that names the
        `--group-add`), the documented run line, and `check_gpu_runtime`, which fails the published image on six rows.
        Proved on this host's WSL VM: `/dev/kfd` does not exist there, but over `/dev/dxg` a `hipcc`-built program ran
        on the Ryzen iGPU (gfx1036) as uid 1001 with the roots set and did not link without them, and ORT's MIGraphX EP
        served the Add graph. The RX 9070 XT is not enumerated over DXG. The next rocm chain must show every rocm
        `GPU-RUNTIME` row passing, and on a native Linux host with an AMD GPU, as uid 1001 with the documented run line:
        `rocminfo` listing the GPU, a `hipcc`-built program running, the Add graph through MIGraphX, and torch
        `cuda.is_available()` with a tensor op; without `--group-add`, the entrypoint's warning.
      - `:latest-nvidia` has no arm64 route; out of scope (owner 2026-10-20).
      - The stale `tensorrt.conf` naming `/usr/local/tensorrt/lib` is gone: checked in the published `0e9dec34…`
        (2026-10-19) on 2026-10-21.
      - `:winamd64-rocm`: published (first 2026-09-28 at 73a8dd74, again 2026-10-03 at
        49fe27ef, with TheRock 10.1 on 2026-10-09 at c0969e22); the redistribution decision is recorded in `docs/windows-rocm.md`
        § Redistribution.

      Sources: `docs/linux-accelerator-images.md` and `docs/windows-rocm.md`.
- [b] **CON136 — the GPU images ship TensorRT's runtime files only** [M, ★★]. Owner decision
      2026-10-21 ("Rausnehmen"), in the source since this row's commit; blocked on the next nvidia chains,
      as CON31. Proved without a chain (`CHANGELOG.md` 2026-10-21, CON136): the published `:latest-nvidia`
      `0e9dec34…` fails both new gates on DeepStream's 13 TensorRT 10 headers and three dev links and
      passes them on the new layout, with every DeepStream gate and ORT's TensorRT EP resolving; the
      Windows gate fails the old tree shape and passes the subset in `:winamd64`. The next chains must show:
      - Linux media: `deepstream.sh`'s `runtime -> …/tensorrt-10.16.1.11, headers and dev links -> …/trt-sdk
        (build only)`, the components built, and `deepstream-verify.sh`'s `holds only TensorRT's runtime .so
        files and their docs`, at the end of the build and again in the package stage;
      - Linux runtime smoke: the `GPU-RUNTIME` row `only TensorRT's runtime .so files ship` passing on
        `-nvidia`, `-rocm` and `:latest`, and `/opt/nvidia/deepstream/tensorrt-10.16.1.11/lib` holding its 22
        runtime files and links (2.5 GB), with no `include/` and no unversioned `.so`;
      - Windows `-Gpu` with a zip staged in `windows/downloads/`: `Copy-TensorrtRuntime.ps1`'s `ships 11
        runtime DLLs` line, `bk-windows-tensorrt-sdk-nvidia` tagged, the ORT RUN's `TensorRT detected at
        C:\tensorrt-sdk\current`, and the smoke's `TensorRT ships only its runtime DLLs` and `ORT TensorRT EP
        finds every TensorRT DLL it loads` passing with `cuda=1 trt=1`; zip-less, both pass on the empty root.
      - **The stage images go private** (owner 2026-10-21, "Auf privat stellen"; in the source since the
        `cross_stage_repo` commit): nvidia's `gpu`, `media` and `android` stages push to
        `ghcr.io/kataglyphis/kataglyphis_beschleuniger-stages`; `:latest-nvidia`, the shared stages and rocm
        stay. The Windows chain pushes no stage (`docs/linux-accelerator-images.md` § Stage images).
      - **For the owner, after the first nvidia chain's push:** the package page
        (`github.com/users/Kataglyphis/packages/container/package/kataglyphis_beschleuniger-stages`) says
        Private (never switch it: a public package cannot be made private again); `curl -s -o /dev/null -w
        '%{http_code}\n' 'https://ghcr.io/token?scope=repository:kataglyphis/kataglyphis_beschleuniger-stages:pull'`
        prints `403` (the public package prints `200`); `DOCKER_CONFIG="$(mktemp -d)" nerdctl pull
        ghcr.io/kataglyphis/kataglyphis_beschleuniger-stages:cross-media-nvidia-amd64` fails `denied`, while
        a logged-in `nerdctl manifest inspect` of it succeeds.
      - **For the owner: delete the old public stage tags** (read anonymously 2026-10-21; no other tag shares
        these digests and no index lists them; a delete is restorable for 30 days):
        `cross-toolchain-nvidia-amd64` `sha256:af3245773499e0287ccded76d35aefa3560d34c217635e9ae8fedc8d20c7dffd`,
        `cross-media-nvidia-amd64` `sha256:d2d11dbbb50bc5eb8cb070b7597761428c9123786cd7f42d15ebdfeb02935ce6`,
        `cross-android-nvidia-amd64` `sha256:e495e70dd62456f68f07f92ae2ef409e3ca1a869f609093295b8fa649c2b0e70`.
        With a PAT holding `read:packages` and `delete:packages` (`GHCR_TOKEN` or `docker login`): `bash
        linux/host-config/ghcr-delete-tags.sh cross-toolchain-nvidia-amd64 cross-media-nvidia-amd64
        cross-android-nvidia-amd64` (dry run), then the same with `GHCR_DELETE_TAGS_CONFIRM=1`. Their untagged
        predecessors go with the weekly `ghcr-cleanup.yml` prune once 14 days old.
      - Open: `ghcr-cleanup.yml` prunes only the public package; on `-stages` its `MIN_TAGS=10` guard would
        refuse three tags, so untagged stage versions stay there (private, storage free today).
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

- [ ] **CON146 — TVM's cross sysconfig export lags the wheelhouse's** [S, ★]. Found 2026-10-21 with
      CON114: `_tvm_target_python_sysconfig_export` (`tvm-python.sh`) still takes its triplet from
      `cross_target_triplet` and puts the module's own dir on `PYTHONPATH`, the two things ab61b9e0 and
      fc5386eb took out of the wheelhouse's export (a host-shaped tag; the target stdlib shadowing the
      pinned interpreter's when the module sits in `lib/python3.X/`, not `lib-dynload/`). Check the
      tvm-ffi wheels of the next arm64 and riscv64 media chain for a target tag; if one comes out
      host-tagged or withdrawn, give TVM the wheelhouse's copy-and-synthesise export.

- [ ] **CON144 — explain the build host's Chrome HTTP stall** [M, ★★].
      The 2026-10-22/23 Linux CI and immutable-image browser suites pass; that does not explain
      the earlier failure on the other build host. Found 2026-10-21: `test-docs-sidebars.sh` passed 47
      of 47 at 10:51 and hung from about 11:20 on; `test-webgpu-canvas-readback.sh` hung on
      unmodified HEAD `b515b7ca`. At that time `run-tests.sh` had no per-suite timeout, so one hung
      suite stopped preflight (27 min in `test-docs-sidebars.sh`), while the mutation baseline
      timed out at 300 s and reported `vacuous bite`. Reproduced without the hub: `google-chrome` 156.0.8078.47
      (apt, updated 08:31 that day) `--headless=new --no-sandbox --disable-gpu --dump-dom` loads
      `data:` and `file:` URLs in 0 s but never returns on `http://127.0.0.1:<port>/`, not even on a
      refused port 1 (curl refuses in 20 ms). The `--v=1` log shows `NotifyBeforeURLRequest:
      http://127.0.0.1:1/` in the network service and nothing after it. Not the cause, each tried:
      `--no-proxy-server`, `--disable-quic`, `--headless=old`, `--disable-background-networking`,
      `--disable-component-update`, `--disable-extensions`, `--disable-field-trial-config`, and
      `--disable-features=` `LocalNetworkAccessChecks`, `HttpsUpgrades` and `OptimizationHints`;
      GNOME's proxy mode was `none`. Work: re-check that host and, if it still stalls, identify
      what the network service waits for. The separate Chrome cleanup race is fixed: callers
      await group termination, child exit and bounded profile cleanup, and startup failures
      release their resources too. Suite timeouts reap process groups. Those regression-tested
      fixes do not establish the cause of the HTTP stall
      ([`docs-sites.md`](docs/docs-sites.md#the-sidebar-toggle-check)).

- [ ] **CON142 — the resource monitor names every runtime-lane phase** [S, ★].
      `<arch>.<step>` markers under `RESOURCE_MONITOR_STEP_DIR` ([`build-resource-monitoring.md`](docs/build-resource-monitoring.md))
      name each arch step on the 2026-10-27 chain (`stage=amd64/smoke+amd64/wrapper+amd64/wrapper-build`). Its
      peaks of memory, disk and load fell after the arch loop, in the manifest gates and consumer acceptance,
      and read `stage=?`. Work: mark those phases too. Done when a runtime summary has no `stage=?`.

- [ ] **CON143 — the hub's tests leave their `mktemp` trees in `/tmp`** [S, ★]. On 2026-10-21 the
      build host's `/tmp` (a 31 GB tmpfs, so RAM) held 31,668 entries and 2.7 GB: 23,865 `tmp.*`,
      3,218 `wlt-target.*`, 1,719 `wlt-work.*`, 2,463 `buildkit-*`, plus `ccl-empty*`,
      `cc-test-bin*`, `cross-oci-test*` and `mutation-gate-*`. Fifteen suites call `mktemp` without a
      cleanup trap (most: `test-setup-package-image.sh` 10, `test-cuda-runtime-payload.sh` 8,
      `test-uv-conflict-extras.sh`, `test-runtime-image-gates.sh` and `test-gpu-variant.sh` 7 each),
      and `06-packaging/web-lane-tools.sh` makes the `wlt-*` trees. Work: one `t_mktemp` in
      `test-harness.sh` that registers each tree for removal at exit, the suites moved onto it, and a
      `run-tests.sh` check that counts `/tmp` entries before and after the run and fails on growth.

- [b] **CON62 — WSL containers (`wslc`) as the local Linux engine** [M, ★★]. Blocked
      upstream. Evaluated 2026-10-05 against WSL 3.0.1
      (`docs/rancher-desktop-linux-containers.md` § *WSL containers*): faster bind
      mounts and no credential trap, but no `--privileged`, `--platform` or `--device`,
      which the lanes pass. Re-evaluate when microsoft/WSL#41545 (privileged/cap-add)
      and #41123 (multi-platform) land. The Dart-only pilot is in: OmniAccelerANT
      953d6f6, `Invoke-DartChecks.ps1 -Engine wslc`, analyze 146 s against nerdctl's
      371 s, format + test 23 s against 32 s (2026-10-06).
