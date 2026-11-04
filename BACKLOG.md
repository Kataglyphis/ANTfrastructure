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
**Digests read 2026-11-02:** `:latest-nvidia` is `70bc45db…`, `:latest-rocm` `05518138…` (created 2026-10-28),
`:winamd64-nvidia` `b472f91b…` and `:winamd64-rocm` `774af209…`. Entries that cite the older Linux `a5d68fbe…` or
`0e9dec34…` were not read again on the current digests.

## Protocol

The agentic loop's format (`docs/windows-agentic-loop.md`):

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★, as in the refactoring backlog.

## Next image build — GPU consumer findings

The application-build investigation is tracked in the items below. Recheck the cited
image digests before implementing fixes and retain CPU-only support. The requested GPU
targets are Linux NVIDIA x64/arm64, Linux AMD x64, and Windows NVIDIA/AMD x64; Linux ARM
ROCm and Windows ARM GPU images are outside the requested matrix.

- **Linux GPU SDKs and execution:** CON31, CON78, CON129, CON172, CON176, CON196, CON198,
  CON202 and CON207 cover runtime selection, GTK/Vulkan headers, inference plugins,
  AMD model parity and the separate AMD GenAI investigation.
- **Windows GPU runtimes:** CON180–185 and CON201 cover DirectML/CUDA provenance,
  provider paths, media plugins, native DLL notices and Media Foundation availability.
- **Runtime provenance:** CON203–204 cover the Linux ROCm and NVIDIA library handoff.
- **Build tools:** CON145, CON177, CON179, CON187, CON194, CON197 and CON214
  cover tools, plugins, SDK inputs and Flutter/FRB generation.
- **CPU image and package handoff findings:** CON188, CON190 and CON191 cover DEB host-library
  versioning, auditwheel and the DNNL provider's oneDNN runtime. These also affect
  the CPU baseline that GPU consumers must continue to support.
- **CUDA architectures:** CON217 adds Turing, so RTX 20xx cards can run the NVIDIA packages.
- **Results on a GPU:** CON220 covers wrong DirectML output that the provider checks do not see.
- **GenAI threads:** CON218 covers the default thread count on pinned CPUs.
- **riscv64 ORT:** CON219 covers the 4-bit `MatMulNBits` crash on RVV.
- **Image readiness and capacity:** CON90 and CON174 track the ROCm Python rollout and
  measured disk requirements for GPU consumer builds.

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
          has pushed (PAR5: hours at media) → CON169.
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
      11. Sidebar check done, b8b4b376 (`CHECK_DOCS_SIDEBARS_JOBS`, 4 Chromes: 66 → 18 s). 2026-11-03: the
          site link gate parses in a process pool (`SITE_LINK_JOBS`) and `run-lint-gates.sh` runs gitleaks per
          entry side by side (`LINT_GATES_SECRET_JOBS`, 27 entries: 27 → 5 s). Open: Sphinx `-j` (risky with `-W`
          and Exhale), the dartdoc nav rewrite.
      Open: 8 (Windows variant pushes off the next variant's path; `-ConcurrentAux` never ran),
      9 (parallel runtime builds: `BUILD_MEM_DIVISOR` plus a disk gate that sizes, worth it only
      where builds outlast uploads). 10 is in source, opt-in: CON169. **The next 3-arch runtime run must show**: `[runtime-push] arch=amd64
      start` before arm64's `step=base` and `RUN` lines, `[runtime-push] arch=amd64 done` after
      them, `[runtime-push] queue drained: 3 push(es), waited N s` (the residual upload),
      `[runtime-gates] … 3 arch(es), 3 at a time`, `[smoke <arch>]` lines among the wrapper
      build's and `step=smoke-wait`, and a wall clock down by about the summed upload plus
      min(smoke, wrapper) per arch. Tick 1–2 on that run.

- [ ] **CON139 — a failed arch re-runs alone; prove it on the build host** [M, ★★★].
      In source since 2026-10-26 ([`linux-cross-builds.md` § A failed arch re-runs alone](docs/linux-cross-builds.md#a-failed-arch-re-runs-alone)):
      each wrapper carries `org.kataglyphis.build-key`, and a published child whose key matches joins the
      index by digest after every gate read it (`RUNTIME_REUSE_CHILDREN=0` restores the same-run index).
      All three children of `:latest` `7d4d4129…` carry the key. Done when a
      follow-up `--target-arches riscv64 --from-stage runtime` logs `[runtime-reuse] amd64: reusing …` and
      the same for arm64, builds riscv64 only, gates all three, and publishes a 3-child `:latest` that
      passes freshness.

- [ ] **CON112 — why one ModelANT export differed: an investigation (owner, 2026-11-04)** [M, ★★].
      In ModelANT since 2026-10-20 (038ca50): `build.sh` runs only in the image and the hub's ORT census must pass first.
      Tag `deim_dfine_n_coco-v2` was released by run 41498847541 with `SHA256SUMS`; its log shows CPython 3.15.0 and
      `ORT-CENSUS PASS` on `onnxruntime_dnnl-1.31.0-cp315`. The `.onnx` hash `0bf16e85…` is in the `models.lock` of
      OrchestrANT, OxidANT and AccelerANTgine. Left: why one export differed. Rebuild 41511367119 gave `0bf16e85…`, but
      candidate run 41431013995 gave `0c7b4141…`: the same graph, with 136 of 342 initializers differing in their bytes.
      The cause is unknown. The DirectML parity of 2026-11-02 passed on the candidate.

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

      Done when a docs build in `:latest` renders the guides on the pinned parser.

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
      3. Never run yet: any Windows build (the dev host has no Visual Studio) and any arm64 build.
- [ ] **CON103 — `FLET_VERSION` in `versions.env`, one pin for Python and client** [S, ★★]. The
      Python SDK and the client speak one release's protocol, so a bump moves together:
      OrchestrANT's `frontend` extra (`flet[desktop]==1.0.5`, `flet-web==1.0.5`), its
      `benchmarks.yml` viewer job (`flet==1.0.5`, held to `uv.lock` by OrchestrANT's
      `test_viewer_job.py`) and CON102's client tag. Add the consumer-pins rows and one Renovate
      group (pep621 and the `versions.env` regex). OrchestrANT's 550f0ff moved to 1.0.5 and dropped
      `fastapi<0.145`; flet-dev/flet#6984 is closed.
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
      and FastAPI on amd64 and arm64, absent by decision on riscv64. The published `:winamd64` (`3189832e…`, revision
      c9ef6ccc) descends from 37602770, whose `Build-TorchApp.ps1:203` prints the line, but nobody has read the printed
      line. Done when `:winamd64`'s torch stage is seen printing `extras: ml-ai docs frontend`.
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

## Open — language AI in the images

Owner goal 2026-10-30: text, LLM and speech apps in the four code repositories on the chain's
GenAI. The plan, the contract and every `LAI-*` ID: [`docs/language-ai.md`](docs/language-ai.md).

- [ ] **LAI-H2 — GenAI builds with llguidance on Windows** [M, ★★]. `Build-OnnxGenaiFromSource.ps1`
      passes `-DUSE_GUIDANCE=OFF`, so `json_schema` works on Linux only. Needs Rust in the
      media-core builder and a Windows chain to prove; done when the smoke gate runs a
      schema-constrained `generate()` on `:winamd64`.
- [ ] **LAI-H6 — GenAI for Android** [L, ★★]. Milestone 1 is done, so nothing blocks it
      ([`docs/language-ai.md` § Roadmap](docs/language-ai.md#roadmap)). ORT is built for Android
      (`03-media/build/onnxruntime/android/build-android.sh`, `Dockerfile.android:125`); GenAI is not. Left: build
      GenAI against that ORT in the android stage. Proving it needs a chain.

## Open — Linux image (all arches)

- [b] **CON224 — run the GPU packages on the cards no hosted runner has** [M, ★★★]. Owner decision: the
      owner runs these, and no release to `main` until they pass. Blocked on that hardware. Hosted CI builds
      all nine GPU workflows but tests on the CPU only. Windows AMD passed on 2026-11-03/04 on an RX 9070 XT
      (unpacked ZIP and MSIX, not the MSI). Still open, for OxidANT, OrchestrANT, AccelerANTgine and OmniAccelerANT:
      1. Linux AMD, in a native Ubuntu boot on the RX 9070 XT: **ran 2026-11-04, all four packages red**
         (runs 41738311741, 41738330472, 41738320553, 41755043524; host ROCm 10.1 / MIGraphX 2.18.0 from TheRock).
         Every package loads the provider and runs the detector on MIGraphX, then `compare_detector_parity.py`
         fails with `detection counts differ`: one ORT bug, CON225. OrchestrANT's `profile-gpu-candidate.sh`
         reported `ok` because it counts operators and compares no detections; give it the parity check.
         Host setup the page did not say: `libmigraphx_c.so.3` comes only from AMD's `amdrocm10-migraphx`
         (Ubuntu 26.04's own ROCm 7.1 has no MIGraphX), `/opt/rocm/core-10.1/lib` and `extras-10/lib` go on the
         loader path, and OmniAccelerANT needs `xvfb-run`. Rerun after CON225 ships.
      2. Linux NVIDIA, on a machine with a supported card (not the RTX 2080 until CON217).
      3. Windows NVIDIA, on that machine. OrchestrANT's package uses DirectML there.
      Steps: [§ A package on your own GPU](docs/gpu-artifact-receipts.md#a-package-on-your-own-gpu). The Linux
      scripts have never run outside their tests. Done when each package passes `compare_detector_parity.py`
      against the CPU with its operators on the provider. Failures on gfx1036 belong to CON202.

- [ ] **CON225 — ORT's MIGraphX provider corrupts a partition output with non-standard strides** [M, ★★★].
      Found 2026-11-04 on the RX 9070 XT (gfx1201) with ORT v1.31.0 (`--use_migraphx`) and MIGraphX 2.18.0:
      `deim_dfine_n_coco` returns three drifting detections where the CPU finds five, in every Linux AMD
      package. Pure MIGraphX compiles the whole graph and matches the CPU (max diff 0.0025, three identical
      runs). The EP leaves the six `GridSample` ops and the stem's ceil-mode `MaxPool` on the CPU, so the
      graph splits into five partitions, and one of them is only the `Slice` + `Reshape` that cut the 40×40
      level out of the shared value tensor. MIGraphX returns that output as a view with strides
      `[32000, 2000, 40, 1]`, and the EP binds that shape straight onto ORT's dense `[8, 16, 40, 40]` buffer
      (`migraphx_execution_provider.cc`, the `#output_N` binding in the compute function): ORT reads
      strided data as dense (emulating that reproduces ORT's tensor to 6e-6 on the 80 % the write defines)
      and the overrun corrupts neighbours, which is why run 1 differs from run 2 and
      `enable_mem_pattern=False` makes it deterministic but still wrong. `HIP_LAUNCH_BLOCKING` and
      `AMD_SERIALIZE_*` change nothing. Two fixes, both upstreamable: make the EP copy a non-standard
      output through a contiguous scratch, and add `GridSample` to its op list (MIGraphX has it), which
      makes this model one partition. Carry them as `linux/scripts/patches/onnxruntime/` entries applied by
      `apply_ort_gpu_source_patches`, rebuild the rocm chain, and report upstream with the evidence in
      `~/gpu/work` on the build host. Windows DirectML has its own wrong-result class (CON220); the Windows
      ROCm image is not affected by this partition (its ORT is CUDA/DirectML only). Done when all four Linux
      AMD packages pass `compare_detector_parity.py` on the RX 9070 XT (CON224 item 1).

- [ ] **CON217 — build CUDA compute capability 7.5, so RTX 20xx cards run the NVIDIA packages** [M, ★★].
      Owner decision 2026-11-02: add `75` (Turing: T4, RTX 20xx) to `CUDA_ARCHITECTURES`, today
      `86;87;89;120`. Found the same day on an RTX 2080 (driver 595.58.03) with OxidANT's Linux x64
      NVIDIA package (run 41415056257): the package runs on the CPU, and CUDA stops with
      `cudaErrorNoKernelImageForDevice`, so that card gets a named failure or, on `auto`, the CPU
      ([§ A card without a CUDA kernel](docs/linux-accelerator-images.md#a-card-without-a-cuda-kernel)).
      There is no PTX to fall back on, and no other entry reaches major 7. Edit the five places in AGENTS.md's "To add or remove one" together. Each entry
      compiles every ONNX Runtime and OpenCV CUDA kernel once more, so record the build time and
      image size of the rebuild. Done when a package from the new NVIDIA image, on that RTX 2080,
      passes `shared/python/compare_detector_parity.py` against the CPU with its operators on
      `CUDAExecutionProvider`. Check Windows `:winamd64-nvidia` on such a card separately; the Linux
      run says nothing about it.

- [ ] **CON220 — the Windows image checks do not see wrong DirectML results** [M, ★★★].
      Found 2026-11-02 on an RX 9070 XT with DirectML 1.15.4, the DLL in AccelerANTgine's and
      OmniAccelerANT's AMD packages: `deim_dfine_n_coco-v1` ran with every profiled operator on
      `DmlExecutionProvider` and returned no detection, where the CPU finds two cats. MatMul of a
      matrix by a 1-D vector computes wrongly. ModelANT's `deim_dfine_n_coco-v2` (8b08b7e) rewrites it
      through Unsqueeze/MatMul/Squeeze, so that model runs; any other graph of this shape still fails
      silently. `Assert-OrtDmlProviderSmoke` in `Test-Container.ps1` only asks whether the provider is
      available. Not known: whether DirectML or ORT's provider is at fault, and whether NVIDIA cards
      show it. Add a small MatMul graph compared against the CPU wherever a DirectML adapter exists,
      try a newer DirectML, and report it upstream. Done when an image check fails on this shape on
      that card, or a shipped DirectML passes it.

- [ ] **CON218 — GenAI's default thread count ignores the CPU affinity mask** [S, ★★].
      Found 2026-11-02 by `--perf-host` on an AMD Ryzen 9 5950X pinned to 8 CPUs: the shipped SmolLM2-135M
      config gave about 92 tok/s and 143 ms to first token, with TTFT spread above 8 %. A copy fixed to 7
      threads (`lib/genai-model-threads.py`) gave about 314 tok/s and 20 ms, and the perf baselines use that
      copy, so their text figures are not the shipped default. Done when a shipped config respects the
      mask, or the consumers set a bounded thread count, and a measurement quotes the unmodified model.
- [ ] **CON219 — ORT reads a null scale pointer in 4-bit `MatMulNBits` on riscv64 RVV** [M, ★★★].
      Found 2026-11-02 with OxidANT's SmolLM2-135M contract test under QEMU, image index `7d4d4129`: a fault in
      `libonnxruntime.so.1.31.0` at `0x150150c` on `flw fa5, 0x0(s10)`, `s10=0x1f80`. In ORT v1.31.0's
      `matmul_nbits.cc`, `UseSharedPrePackedBuffers` sets `scales_are_packed_` with a 4-bit exception guarded by
      `MLAS_TARGET_ARM64`, while `PrePack` uses `!MLAS_TARGET_AMD64_IX86`. That cause comes from reading the source;
      no patched build was tested. Stack size and vector length are ruled out. Shipped riscv64 images are exposed
      for such models. OxidANT's lane forces scalar MLAS for that one test (`63828b5`). Done when a patched chain
      build passes the test on RVV and OxidANT drops the override; an image chain is an owner decision.
- [ ] **CON207 — investigate Linux AMD GPU support for GenAI** [M, ★★]. The cached
      `:latest-rocm` amd64 image contains the vision ONNX Runtime MIGraphX provider, but its
      GenAI tree has only the generic library and llguidance; `60-build-genai.sh` builds GenAI
      against the CPU ORT unless NVIDIA is enabled. The NVIDIA image separately carries the
      GenAI CUDA library. Determine whether the pinned upstream GenAI and AMD stack support a
      viable GPU build, then define the build and image smoke for a future image. Verify provider
      initialization and actual model execution on supported AMD hardware, and resolve runtime
      provenance and redistribution before claiming support. This is separate from the existing
      vision MIGraphX provider and from applications choosing whether to bundle GenAI. No AMD
      GenAI GPU execution or upstream compatibility is established by the file inspection.

- [ ] **CON172 — the sdk stage points the target multiarch `libstdc++.so` at the host's; prove the fix on an sdk rebuild** [S, ★★].
      Found 2026-10-29 on the first arm64 nvidia media build: `vulkan.sh`'s `_vulkan_setup_gcc_runtime` linked
      `libstdc++.so` and `libgcc_s.so` from every `LIBRARY_PATH` dir (the HOST's `/opt/gcc-16.2.0/lib64`) into
      `/usr/lib/<target triplet>`, so the cross media images carry an x86-64 `libstdc++.so` there; lld rejects it
      on any link line with an explicit `-lstdc++` (OpenCV's CUDA line), bfd only skips it. In source since
      2026-10-30: `_vulkan_lib_fits_dir` reads each candidate's ELF machine and refuses one that is not the dir's
      arch (`test-vulkan-gcc-runtime-links.sh`); ffmpeg, GStreamer and OpenCV keep their repins until the published
      sdk is rebuilt. Done when `file -L /usr/lib/aarch64-linux-gnu/libstdc++.so` in a fresh `cross-sdk-arm64`
      says AArch64 and the three repins can go.
- [ ] **CON163 — every Linux compile reaches sccache; prove it on a chain** [S, ★★★]. In source since 2026-10-26
      ([`build-cache-tiers.md`](docs/build-cache-tiers.md#a-subproject-that-forces-its-own-launcher)): the Vulkan
      SDK RUN mounts both caches and pins its launcher, and ONNX Runtime, LiteRT and the riscv64 torch wheel pin
      `CCACHE_BINARY` against pthreadpool's FORCE, gated by `cmake_assert_compiler_cache_pin`. Done when a second
      chain's `sdk-arm64`/`sdk-riscv64` dependency step and ONNX Runtime's `onnxruntime 2/9` step log
      `sccache-stats|` hits above 90 % of their compiles, and the Vulkan step drops below 10 min.
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
- [ ] **CON168 — prove on a chain that one lane compiles the IREE host LLVM** [S, ★★]. In source since 2026-11-03
      ([`iree-two-stage-build.md` § One host stage per chain](docs/iree-two-stage-build.md#one-host-stage-per-chain)):
      the first lane builds under a lock in the `id=iree-host` cache mount, the next restores (`IREE_HOST_CACHE=off`
      reverts). `test-iree-host-once.sh` proves it with a stub `cmake`. Done when the next chain's arm64 and riscv64
      media logs show one host compile and `IREE host stage: reusing` in the other lane.
- [ ] **CON169 — prove one pipeline per arch on a chain, then decide its default** [M, ★★★]. In source since
      2026-11-03, opt-in ([`linux-cross-builds.md` § One pipeline per arch](docs/linux-cross-builds.md#one-pipeline-per-arch)):
      `CROSS_ARCH_PIPELINE=1` runs each arch through its stages, with a per-lane disk guard scoped to finished arches.
      Proved by `test-arch-pipeline.sh` (rendezvous, stub stage runner, the real driver's dry run). Done when a chain
      logs an arch's `stage=android start` while another arch's `stage=media` runs, no image removal lands under a
      running build, and the lanes' overlapping disk use fits; then make it the default or record why not.
- [ ] **CON171 — a stopped chain leaves BuildKit records in use** [S, ★]. In source (CHANGELOG 2026-11-03,
      `_disk_guard_release_stale_records`), tested with stubs only. Done when the next chain resumed after a stop
      logs `left by a stopped chain: restarting buildkitd` and reclaims without a hand restart.
- [ ] **CON153 — the pinned release assets come from the Garage mirror** [S, ★★★]. Owner decision
      2026-10-26: Garage S3. In source ([`linux-cross-builds.md` § The asset mirror](docs/linux-cross-builds.md#the-asset-mirror),
      runbook in [`linux/sccache-s3/README.md`](linux/sccache-s3/README.md)): every `download_verified_file`
      asks `<mirror>/<sha256>/<name>` first and falls back upstream, through the `asset_mirror` BuildKit
      secret. The bucket, both keys and this host's env files exist since 2026-10-26 (`--check` passes); a
      new chain host runs `set-asset-mirror.sh --from <ssh-target> --url <bucket-url>`. Filled on 2026-10-27 from that chain's
      misses: 32 of 33 assets. Done when the next chain logs
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
      **GPU consumer evidence, 2026-10-30:** the locally cached amd64 `:latest-rocm`
      (index `a5d68fbe…`) and `:latest-nvidia` (index `0e9dec34…`) lacked the GTK 4 /
      `graphene-gobject-1.0` development surface needed by OxidANT's mandatory GUI build.
      Installing `libgtk-4-dev` in disposable containers let both release builds finish; that
      is a local workaround, not the image fix. Keep the selective amd64 package choice in the
      consumer contract: do not pull a second distro GTK/GStreamer stack into the image just
      to reproduce the workaround. Before the next GPU image publication, make both candidate
      variants pass `verify_gtk4_dev_surface` and the `gtk4-dev` runtime contract as uid 1001,
      then build OxidANT's GUI. Record the
      image digests, architectures and results; verify the NVIDIA arm64 child separately.
      The NVIDIA arm64 child `sha256:6cc1a6744b88cb0e4e031c79e1a0e8bcf9d7e0277f8fac63686b5a59368f5d11`
      resolves `gtk4` 4.22.4 and `graphene-gobject-1.0` 1.10.8 through `pkg-config --exists`
      as uid 1001 under user-mode emulation (2026-10-30). This is not a GUI build or the full
      development-surface contract; retain the native arm64 checks.
      **2026-11-02:** OxidANT's GPU workflows still install the package
      (`linux-x64-amd-gpu.yml`, `linux-nvidia-gpu-build.yml`). Runs 41517659698 (`:latest-rocm`
      `05518138…`) and 41517653860 (`:latest-nvidia` `70bc45db…`, x64) did so, which does not show
      whether these digests still need it. Both lanes keep their install
      ([why](docs/image-decisions.md#deliberate--not-gaps)).

- [ ] **CON176 — verify the Vulkan development surface in GPU consumer images** [S, ★★].
      On 2026-10-30 the cached amd64 `:latest-nvidia` (`0e9dec34…`) and `:latest-rocm`
      (`a5d68fbe…`) had neither `/usr/include/vulkan/vulkan.h` nor `pkg-config vulkan`.
      The local OmniAccelerANT CUDA build installed `libvulkan-dev` in its disposable
      container, along with the missing graphene metadata in CON129. Determine which Vulkan
      development files the supported consumer builds require, add and verify that surface
      in the GPU image build as appropriate, and rerun the consumers without ad hoc package
      installation. Check the published NVIDIA arm64 child separately; do not infer its
      contents from amd64.
      The NVIDIA arm64 child `sha256:6cc1a6744b88cb0e4e031c79e1a0e8bcf9d7e0277f8fac63686b5a59368f5d11`
      contains `/usr/include/vulkan/vulkan.h` and resolves `vulkan` 1.4.341 through
      `pkg-config --exists` as uid 1001 under user-mode emulation (2026-10-30). That does not
      prove a consumer build.
      **2026-11-02:** OmniAccelerANT's `linux-gpu-candidates.yml` installs no Vulkan package, and its AMD and
      arm64 jobs are green on the current digests (41517668512). Whether those builds use the headers is not read.

- [ ] **CON177 — verify ShellCheck in the ROCm consumer image** [S, ★★]. The cached amd64
      `:latest-rocm` (`a5d68fbe…`) did not have `shellcheck` on PATH on 2026-10-30, while
      the cached amd64 `:latest-nvidia` did. The image source already installs pinned lint
      tools in `Dockerfile.torch`; prove the runtime contract in the next ROCm image, then
      run the consumer's shell lint without an ad hoc install. Check the published image
      digest rather than assuming the cached image reflects the current registry tag.

- [ ] **CON179 — check optional libcamera GStreamer plugin in consumer images** [S, ★★].
      The cached amd64 `:latest-nvidia` (`0e9dec34…`) did not expose the optional
      GStreamer `libcamera` plugin to an OrchestrANT bundle on 2026-10-30. Its required
      GStreamer elements and CPU self-test passed; this is not evidence that all camera
      paths work. Check the intended image contract and the current NVIDIA amd64/arm64
      and ROCm amd64 children, restore the plugin if the contract requires it, and
      record digest-specific plugin and camera-path results. The NVIDIA arm64 child
      `sha256:6cc1a6744b88cb0e4e031c79e1a0e8bcf9d7e0277f8fac63686b5a59368f5d11`
      supplied `/opt/libcamera/lib/gstreamer-1.0/libgstlibcamera.so` to an isolated
      OrchestrANT bundle on 2026-10-30. File staging alone does not prove that the plugin
      loads or that a camera works; retain the native ARM checks.
      The cached x64 CPU `:latest` digest
      `sha256:3c558d8828553ea2e3feedb97c99e15bb89a0820c6a056813876da4cd968d92c`
      also reported that optional plugin missing during a fresh OrchestrANT bundle build;
      this does not establish the status of any other GStreamer plugin or camera path.

- [ ] **CON190 — provide auditwheel for the Linux CPU image's Python wheels** [S, ★★].
      On 2026-10-30 the cached x64 CPU `:latest` registry digest
      `sha256:3c558d8828553ea2e3feedb97c99e15bb89a0820c6a056813876da4cd968d92c`
      had no `auditwheel` on PATH and `python3.15` could not locate its module as uid
      1001. In an isolated OrchestrANT CPU build using its recorded hub pin and app extra,
      the packaging driver found no `auditwheel` in its binary packaging venv either and
      warned that `orchestrant-0.0.32-cp315-cp315-linux_x86_64.whl` would be shipped
      unrepaired; the app bundle build continued. Add a compatible pinned auditwheel to
      the image, then verify wheel repair and its resulting platform tags and dependencies
      with a real consumer build. This observation does not establish that the app bundle
      fails, nor that unrepaired wheels work on every target distribution.

- [ ] **CON191 — ship the matching oneDNN runtime and its license in the Linux image** [S, ★★]. Owner decision
      2026-11-03. Chain work. The chain ORT lists `DnnlExecutionProvider` on amd64, but `libonnxruntime_providers_dnnl.so`
      needs `libdnnl.so.3`, and no path in `:latest` holds it (`3c558d88…`, read 2026-10-30). An explicit DNNL session
      falls back to `CPUExecutionProvider`, and on 2026-11-02 `--perf-host` reported the DNNL rows of AccelerANTgine
      and OxidANT as `ProviderUnavailable`. Ship the `libdnnl.so.3` that provider was built against, with its
      redistributable license and a row in `docs/third-party-licenses.md`. Done when a bundle on a clean host runs an
      explicit DNNL session with its operators on that provider, which is also the AI-fleet goal's open DNNL proof on
      amd64. Listing the provider proves nothing; arm64 does not build it.

- [ ] **CON194 — eliminate build-directory TCL RPATHs from Python runtimes used in GPU images** [M, ★★].
      On 2026-10-30, retained OrchestrANT GPU x64 bundles built with cached NVIDIA index
      `sha256:0e9dec3401f012fe6a5e4e47798aacbd7c2447ba5d8f6308635a3238db79f5cc` and ROCm
      index `sha256:a5d68fbe64e579de09473290489b6953b5bce9aeb7644c18b86d6969bf37ace8`
      contained `runtime/lib/libtcl9.0.so` and `libtcl9tk9.0.so` with legacy absolute
      `/tools/deps/lib` RPATH. Their builds downloaded python-build-standalone 3.15.0 and
      3.14.4 respectively; the provenance of those individual libraries is not yet proven.
      Legacy RPATH can take precedence over a bundle's `LD_LIBRARY_PATH` and affect inherited
      dependency lookup. Determine whether the image, Python distribution or packaging stage
      supplies the paths; remove or replace build-only paths without disturbing legitimate
      local dependencies or protected wheel bytes. Verify fresh CPU and supported GPU bundles,
      both glibc modes and native architectures, and prove no external build-directory RPATH
      remains. Removing just these two paths in disposable GPU copies allowed their dependency
      scans to pass, but is not a fresh image or application build proof.

- [ ] **CON187 — make the Linux GPU image's sccache log writable and honor disabled caching** [S, ★★].
      On 2026-10-30, the cached `:latest-rocm` digest
      `sha256:a5d68fbe64e579de09473290489b6953b5bce9aeb7644c18b86d6969bf37ace8`
      running as uid 1001 exported `SCCACHE_ERROR_LOG=/tmp/sccache.log`, but that file was
      owned by root with mode 0644. During an isolated AccelerANTgine amd64 build with
      `SCCACHE_DISABLE=1`, the shared launcher nevertheless retried a failed sccache server
      twice, reporting that it could not write the log, before falling back to direct
      compilation. For the local test only, the copied launcher was changed to honor the
      existing disabled-cache setting; no packaging or license checks were bypassed. Before
      the next image build, arrange a writable per-user log or remove the stale image log,
      define the disabled-cache contract in the shared launcher, and verify both enabled and
      disabled modes as uid 1001. Check the other image digests and architectures separately.

- [ ] **CON188 — derive versioned host-library dependencies for Python DEBs** [L, ★★★].
      **Version nodes are done** (2026-11-03, [`python-app-bundles.md`](docs/python-app-bundles.md#versioned-host-dependencies)):
      `GLIBCXX_3.4.32` gives `libstdc++6 (>= 13.1)` from the installed symbols file. **Left:** symbols with no
      version node, and per-symbol minimums inside a node. On 2026-10-30 the retained OrchestrANT AMD candidate's
      bundled `libgstreamer-1.0.so.0` used the host's `libgobject-2.0.so.0` and `libglib-2.0.so.0`, whose exports are
      unversioned; Debian's symbol metadata derived `libglib2.0-0t64 (>= 2.81.1)` and the scanner still declares it
      unversioned. This needs the ELF's undefined symbols, the loader-visible export check and the scope findings
      below. On 2026-10-30 `debian:13` (`sha256:913f6706…`) showed why a bound matters: dpkg configured an
      unversioned DEB whose fixture needs `GLIBCXX_3.4.34`, and loading it failed; `libstdc++6 (>= 15)` made dpkg refuse.
      Do not simply merge `dpkg-shlibdeps` output: a real CPU preload fixture loaded its
      bundled libz through both launcher paths, yet the tool reported host `zlib1g`, and
      a copied AMD MIGraphX provider caused it to report bundled C++ runtimes as host
      dependencies. It also exits successfully after warning about an unresolved host
      symbol, while intentionally waived GPU symbols produce similar warnings.
      Debian's `Dpkg::Shlibs::Objdump` also injects version-node pseudo-symbols and
      does not match an unversioned reference to a default-versioned export. A real
      MIGraphX provider imports unversioned `Provider_GetHost`, supplied by the separately
      loaded bundled `libonnxruntime_providers_shared.so` as `@@VERS_1.0`. The workspace
      `default-export-proof.sh` reproduces successful loader binding and a false unresolved
      result from that API; version needs and the actual global loading scope matter.
      Isolated 2026-10-30 prototypes covered `readelf`'s required imports and exports on all
      250 AMD candidate ELFs and 328 Linux ARM NVIDIA candidate ELFs. For the AMD bundle,
      matching the exact host's symbols/shlibs metadata produced GLib `>= 2.81.1`, ICE
      `>= 1:1.0.0` and SM `>= 2:1.2.6`; a missing GLib symbol, missing symbol metadata and
      a waived HIP provider removed from the candidate cache were rejected. A CPU fixture
      loaded bundled zlib, GCC and C++ runtimes through both glibc paths. Separate loader
      fixtures reject missing, reversed and wrong-SONAME preloads and show standalone
      executables do not inherit Python's
      preloads. These are experiments in `_implementation/deb-depends-audit-20261030`, not
      a production scanner or proof of GPU execution. A separate ABI-aware owner lookup in
      `_implementation/deb-owner-prototype` rejects ambiguous or hwcaps cache entries.
      Later prototypes reject an unloaded-libpython symbol and an ORT provider lookalike,
      compare version nodes with the named provider, and preserve Debian's private-symbol and
      unversioned metadata templates. A test-only AMD DEB using the derived bounds installs
      and runs CPU inference on the image baseline in both glibc modes. That does not prove
      compatibility on older hosts or establish all process-global and plugin scopes.
      The x64 NVIDIA prototype checks 326 ELFs using the image's CUDA stub solely as
      evidence for the waived `libcuda.so.1` symbol, without shipping or running that stub;
      hiding it rejects the unresolved symbol. An emulated ARM NVIDIA scan also checked 328
      ELFs with no unresolved symbols using that image's same-SONAME stub as evidence only;
      native-device execution remains unproved. An inherited-RPATH fixture
      shows that a standalone launcher's legacy RPATH can resolve a dlopened plugin's
      dependency. The production scanner now rejects dynamic-entry, string and version-needs
      sections that disagree with loader-mapped bytes; this does not solve symbol binding.
      A standalone GPU executable fixture loaded host zlib without the Python launcher's
      library path; production discovery now retains `zlib1g` unless detected executables
      have generated wrappers. SONAME-bearing shared objects in `runtime/lib` are treated
      as libraries, so intentionally executing one directly is outside that guard's proof.
      A wrapped standalone executable can also load a site-package DSO without Python
      preloads; a fixture observes host zlib in that process, but the current production
      scanner can omit it. Legacy inherited RPATH can also precede the wrapper's library
      path. GPU x64 bundles contain `libtcl9tk9.0.so` and `libtcl9.0.so` with legacy
      `/tools/deps/lib` RPATH. A stricter experimental guard rejects those and the real CPU
      bundle's wrapped GStreamer executable, so it was not integrated. In disposable tests,
      removing those TCL RPATHs passed GPU scans, and CPU runtime-path wrappers passed CPU
      inference on both glibc modes; fresh package builds and complete loader ancestry still
      need proof. Experimental scanner and fixtures are in
      `_implementation/deb-depends-audit-20261030`.
      Further 2026-10-31 loader fixtures in `_implementation/loader-scope-con188` show the
      scanner omitted host zlib when an earlier host RPATH or RUNPATH won over a later
      bundled path. Production discovery now rejects that direct-path ambiguity and distinguishes
      legacy RPATH from RUNPATH when assessing launcher library paths. The scanner can still omit
      host zlib when a program first loads it before a plugin with a purely
      bundled RUNPATH. The latter proves a possible dynamic-load scope, not that a retained
      bundle exercises it. A third fixture shows a local library with the wrong ELF machine
      is skipped by the loader; the scanner now checks the class, byte order and machine of
      bundled dependency candidates against the importer and records the host package in
      that case. This is not a complete architecture-specific loader compatibility check.
      A real loader fixture also rejects matching-architecture ET_EXEC and ET_DYN PIE files
      masquerading as shared libraries; production discovery now rejects those candidates
      rather than incorrectly considering them bundled. Other load failures remain unproved.
      An independent
      global-interposition fixture shows both unversioned and versioned plugin references
      binding to a previously global different-SONAME host library while the named bundled
      dependency is mapped; even its unversioned export can satisfy the versioned reference.
      These are synthetic process scopes, not demonstrated real-bundle behavior. The exact-symbol
      prototype also rejected 58 unresolved DNNL and
      OpenMP symbols in the retained CPU ORT provider; the simpler CPU fixture is not full
      CPU-provider proof. In `_implementation/deb-metadata-review`, zeroing a GNU-hash bloom
      filter leaves the prototype claiming an export that the real loader cannot find, and
      malformed Debian symbols metadata can emit a parse warning while the prototype reports
      success. Integration must validate loader-visible hash lookup and reject metadata parse
      warnings as well as failures.
      Blanket preloading by SONAME is not a safe substitute for that scope analysis: the
      retained NVIDIA bundle has different OpenCV and Pillow `libXau-154567c4.so.6.0.0`
      copies, both referenced by bundled libxcb libraries. Importing cv2 before PIL.ImageGrab
      maps the OpenCV copy; reversing the order maps the Pillow copy instead. Reproduce with
      `_implementation/loader-scope-con188/import-order.sh`; equivalence of the two copies
      and GPU hardware execution were not established.
      An all-DT_NEEDED host-package superset also needs a proven process context. In
      `_implementation/loader-scope-con188/slashed-needed.sh`, a previously global host
      plugin with a different SONAME interposes a symbol even when an explicit bundled
      `$ORIGIN` dependency is mapped; an unowned RPATH shadow is another possible provider.
      The retained CPU bundle has 108 distinct needs, of which 60 are absent from the build
      image cache and 11 have ambiguous or unpackaged candidates; rejecting all such cases
      would reject the bundle. The NVIDIA bundle includes libv4l2 but mapping every image
      candidate adds `libv4l-0t64`, while Debian 11/12 use `libv4l-0`. Debian 12 also runs
      a bundled-zlib fixture but rejects it when the image's newer installed zlib version
      is imposed as a host minimum. This does not prove a symbol-derived minimum fails.
      Reproduce with `all-host-inventory.py` in the loader-scope directory and
      `conservative-build.sh` / `conservative-debian12.sh` in `deb-metadata-review`.
      A separate valid packed-relative-relocation fixture requires `GLIBC_ABI_DT_RELR`; the
      former numeric-only scanner reported `libc6 (>= 2.17)` although Debian metadata derives
      `libc6 (>= 2.36)`. Reproduce with `_implementation/deb-metadata-review/glibc-relr.sh`.
      The scanner now applies the 2.36 bound to that marker and DT_RELR, and rejects unknown
      `GLIBC_ABI_` markers when glibc is not bundled; this targeted correction does not
      establish bounds for the other host packages or resolve bundled loader scope.
      A gzip fixture in `_implementation/deb-relr-fix-20261031` confirmed the boundary:
      offline Debian 11 index `sha256:6f519a81440354a85eb592c5f32109ab80605f6b892455983a6f618bf87fabe9`
      configured the old `>= 2.17` package with libc6 2.31 but its binary could not load;
      `>= 2.36` refused configuration. Debian 12 index
      `sha256:d74df7598108a173a621eda4d58a2adbf850b2d9a9d81bc2cca1a6c21174a880`
      installed and ran the corrected fixture. The independent metadata audit also found
      that a symbols lookup can return an entry tagged for the wrong target architecture;
      validate that tag rather than assuming installed metadata was prefiltered.
      A later strict metadata prototype in `_implementation/deb-metadata-review` completed
      retained AMD x64 (251 ELFs), NVIDIA x64 (250 ELFs), and emulated NVIDIA ARM (328 ELFs)
      scans with no unresolved symbols; the CUDA stub was waiver evidence only. The CPU scan
      still fails closed on 58 unclassified oneDNN-provider symbols. It rejects some valid
      pattern/include and duplicate metadata; its experimental classifier skips libc metadata
      and does not use the separate strict package-control query helper. These results do not
      establish actual loader scope or GPU execution.
      Derive and verify minimum versions against the exact host-resolved library's Debian
      symbols or shlibs metadata, fail closed on unmapped required host symbols, and
      distinguish proven GPU waivers from other unresolved symbols. Verify real and
      mutated CPU/GPU bundles, private RPATHs, Python preloads, both glibc launcher paths,
      native architectures, and a clean host with an older incompatible package; retain
      no false dependency for bundled or waived libraries. The versioned fixture above
      must refuse configuration on that older image while a compatible host can load it.
      Integration still needs a validated dynamic-symbol count and section/segment mappings,
      architecture-aware loader search and actual process scopes, recursive ordered preload
      closure, bundled-glibc resolution, Debian metadata alternatives and copied-script
      wiring. The current scanner rejects unowned or multiply owned host libraries and bounds version nodes;
      unversioned symbols and per-symbol minimums have no bound yet.

- [ ] **CON180 — record DirectML redistributable provenance and license in Windows images** [M, ★★★].
      AccelerANTgine's existing native inventory says the image does not carry the Microsoft
      DirectML license text. This is a repository statement, not a fresh inspection of a
      cached or current GPU image: the NVIDIA digest `b472f91b…` was later pulled locally on
      2026-10-30, but its DirectML redistributable source and original license text have not
      yet been established. Its chain `DirectML.dll` reports version 1.15.4 and matches the
      DirectML file in the image's ORT 1.31.0 wheel and a finished AccelerANTgine NVIDIA ZIP.
      Inspect the published `:winamd64`, `:winamd64-nvidia` and `:winamd64-rocm` digests;
      record the source NuGet package/version, redistribution terms and original license text,
      and prove that the installed `DirectML.dll` matches that source. Provide a stable
      image path and consumer verification contract for both bytes and license, then rerun
      Windows candidate packaging against the next images. Do not infer GPU hardware support
      from a DLL or infer today's mutable tag contents from older observations.

- [ ] **CON182 — publish CUDA/cuDNN runtime license and origin metadata for Windows consumers** [M, ★★★].
      The cached `:winamd64-nvidia` image digest `b472f91ba9553937a1c62f476ef6d01a878db4d44c754091ece08fb21ba11777`
      was inspected on 2026-10-30. Its chain OpenCV Python import closure includes 13
      CUDA and cuDNN DLLs from `C:\runtime\cuda-runtime\bin`; that runtime directory contains
      no license text or origin manifest. Their bytes matched the CUDA 13.4 toolkit and
      cuDNN 9.27.0.42 installs in the same image; their original `LICENSE` files reside under
      the respective SDK install roots. All 31 flattened DLLs match one SDK source each;
      [the digest-specific evidence](docs/windows-nvidia-runtime-evidence-2026-10-30.md)
      records each file's SHA-256, SDK origin and both license hashes. Clarify the
      redistribution status of `nvfatbin_130_0.dll` and define the runtime set needed by
      real GPU inference before shipping the image's flattened directory as-is. Provide a
      stable runtime-side license/provenance handoff with exact version and file hashes, and
      verify those texts and DLLs during the next NVIDIA image build. Check the current
      mutable tag and supported architectures separately; this observation is for the
      cached digest, not later images.

- [ ] **CON183 — restore Windows GPU image VP8 GStreamer capability** [M, ★★★].
      On 2026-10-30 the cached `:winamd64-nvidia` digest
      `b472f91ba9553937a1c62f476ef6d01a878db4d44c754091ece08fb21ba11777` had
      no `gstvpx.dll`, and its own `gst-inspect-1.0 vp8enc` reported no such element.
      The cached `:winamd64-rocm` digest `774af209a9282b8e8439653eb55756228a6ebdd219076ddc54a1e012e550c99c` also lacks
      `gstvpx.dll` and reports no `vp8enc`.
      The cached CPU image `:winamd64` digest
      `bec12ad0afe6a5f0a90ae7c58ac06e605ee64b2a06c555842019bb1f00062927` also reports no `vp8enc`.
      The cached `:winarm64` CPU digest
      `d265a950d502f49462ad378e4fd062ba416c6f2f304567a00b16a8fd4c5e6b54` also lacks `gstvpx.dll` (file inspection only).
      Its WebRTC, Rust WebRTC and OpenH264 plugin DLLs were present. Restore or provide
      the VP8 encoder plugin and its runtime dependencies, verify `vp8enc` and VP9 if
      promised, and record the plugin's original license and provenance in the image.
      Check the current NVIDIA and AMD Windows image digests and CPU images independently;
      the cached digest does not establish the contents of today's mutable tags. A local
      AccelerANTgine package using this image cannot pass its required VP8 capability check.


- [ ] **CON184 - provide provenance and license texts for Windows GStreamer runtime dependencies** [M].
      Cached `:winamd64-nvidia` digest `b472f91ba9553937a1c62f476ef6d01a878db4d44c754091ece08fb21ba11777`
      ships GStreamer plugins whose PE closure includes `jpeg-8.3.2.dll`, `libcrypto-4-x64.dll`,
      `libssl-4-x64.dll`, `openh264-7.dll`, `png16-16.dll`, `srtp2-1.dll`, and `z-1.dll`;
      the runtime share tree has no corresponding license texts or source provenance.
      Cached `:winamd64-rocm` digest `774af209a9282b8e8439653eb55756228a6ebdd219076ddc54a1e012e550c99c` also has
      all seven DLLs and no corresponding texts under `C:\runtime\share`. Image pkg-config
      identifies libjpeg 3.1.4.1, libpng 1.6.58, libsrtp 2.8.0, OpenH264 2.6.0, and zlib 1.3.2;
      the OpenSSL DLL file metadata reports 4.1.0. A fresh inspection of that NVIDIA digest found that
      both runtime OpenSSL DLLs match the Scoop OpenSSL 4.1.0 `current\bin` copies byte for byte:
      `libcrypto-4-x64.dll` SHA-256 `40b607fc33bab7d3e8b0cec53d20bbb2d9a6928c807b7b2ab0778982eb914cfa`,
      `libssl-4-x64.dll` SHA-256 `1c817fa1968bb3d38f5b2c936c9972464ee7b761b97fe3f3a9069990e137c54d`.
      That Scoop install has `license.txt` (SHA-256 `ed72ce2b51ee58f117e5a021e2e04af158857f40269fbc03491f0b2a99dbcc96`).
      The runtime `z-1.dll` does not match Scoop's `zlib.dll`; pkg-config versions alone do not
      establish the source or license of the remaining five runtime DLLs. Preserve each actual binary's source, version, license
      texts and a verifiable association with the installed DLL (including transitive/static notices),
      and expose these to consumers. Check CPU and AMD/ARM images independently. Until then the
      AccelerANTgine install-time third-party notice gate correctly rejects this closure.
      Implement an image-owned native-DLL provenance manifest before GStreamer's source cleanup:
      record each selected installed DLL's SHA-256, exact source identity and hash, and the original
      license/notice paths and hashes. Verify the manifest after image-stage merges and again when
      staging the consumer's PE import closure; reject unknown DLLs, mismatched bytes, missing texts,
      duplicate entries and unsafe paths. ORT's wheel-specific license handoff remains separate and
      is not evidence for these native media dependencies.
      A prospective AccelerANTgine install from the NVIDIA image reached this notice gate and
      rejected all seven DLLs, so it produced no installer; see
      `_implementation/accelerant-win-prospective3-20261031-build.log`.


- [ ] **CON185 - provide Windows GStreamer tensor inference elements** [M].
      Cached `:winamd64-nvidia` image digest
      `b472f91ba9553937a1c62f476ef6d01a878db4d44c754091ece08fb21ba11777` reports no
      `tensor_transform`, `onnxruntime`, or `tensor_decoder` via `gst-inspect-1.0`.
      Cached `:winamd64-rocm` digest `774af209a9282b8e8439653eb55756228a6ebdd219076ddc54a1e012e550c99c` likewise
      reports all three elements missing.
      AccelerANTgine's `Src/gstreamer_pipeline.cpp` constructs its inference pipeline using
      these elements. Add the compatible plugins and runtime dependencies, their source and
      license provenance, and image checks for the elements; verify other Windows image variants
      independently. Until then that pipeline is unavailable in this image.

- [ ] **CON204 — preserve Linux NVIDIA runtime provenance and notice handoff** [M, ★★★].
      On 2026-10-31, the cached Linux ARM NVIDIA image child
      `sha256:6cc1a6744b88cb0e4e031c79e1a0e8bcf9d7e0277f8fac63686b5a59368f5d11`
      contained CUDA 13.4 and cuDNN 9.27. Its chain CUDA ONNX Runtime provider directly
      needs `libcudart.so.13`, `libcublas.so.13`, `libcublasLt.so.13`, `libcurand.so.10`
      and host driver `libcuda.so.1`. `dpkg-query -S` found no installed package for
      `/usr/local/cuda-13.4/targets/sbsa-linux/lib/libcublas.so.13.8.0.4` or
      `/usr/lib/aarch64-linux-gnu/libcudnn.so.9.27.0`, while it did identify `/usr/bin/bash`.
      A targeted license-name search to depth three in `/usr/local/cuda-13.4`,
      `/usr/share/doc`, `/usr/share/licenses` and `/opt/nvidia` found no matching files;
      this does not establish whether notices exist elsewhere. For a future self-contained
      CUDA artifact, preserve each shipped library and dynamically loaded resource's exact
      source, version, applicable license and notices in a verifiable image-to-consumer
      handoff. Determine the runtime closure and driver boundary and test on supported GPU
      hardware. On 2026-10-31, a separate read-only, network-free inspection of the cached
      Linux x64 NVIDIA image (repository digest `sha256:70bc45db5e2032cad3042b88b2f9a1c06cf4c4ddbbfc91251fbc0c9a2cba233d`,
      image ID `sha256:613b7fdc50efe39df3f71b2d2ef4ec4d77516afa9bae6e2efc27e3c3c7ddee54`)
      found CUDA 13.4.3 and the same provider SONAMEs; `dpkg-query -S` did not identify
      owners for the five inspected canonical cudart, cuBLAS, cuBLASLt, cuRAND and cuDNN files.
      NVIDIA's official CUDA 13.4.3 manifest identifies their matching cudart, cuBLAS and
      cuRAND versions. The small, hash-verified official cudart 13.4.92 x64 archive's
      extracted library exactly matched the image file, and its license text was retained.
      A later check downloaded the manifest-listed x64 cuBLAS, cuRAND, NVRTC and cuDNN
      archives and verified their declared sizes and SHA-256 values. The image's cuBLAS,
      cuBLASLt, cuRAND, NVRTC, NVRTC builtins and all ten versioned cuDNN runtime files
      matched their respective archive bytes; the original CUDA and cuDNN license texts
      were retained. In an isolated, unreleased bundle prototype, these files let the CUDA
      provider resolve its four direct CUDA library dependencies from the bundle on a
      CPU development image; the intentionally unbundled host `libcuda.so.1` remained
      missing, and CPU detector parity passed. NVIDIA's cuDNN documentation also identifies
      dynamically loaded cuBLASLt and NVRTC for some engines. These checks do not prove
      complete runtime-resource closure, legal compliance, a clean-host installation or
      physical GPU execution; retain each as a separate gate before any self-contained
      release. See `_implementation/nvidia-x64-redistrib-verification-20261031/VALIDATION.md`
      and the earlier `_implementation/nvidia-linux-x64-provenance-20261031/VALIDATION.md`.
      An installed prospective Omni NVIDIA DEB in an isolated Ubuntu 26.04 rootfs,
      with no vendor runtime or GPU passed through, rejected explicit CUDA execution
      because `libcublasLt.so.13` was absent. This tests the candidate's failure path,
      not the image's CUDA installation or execution on a supported GPU. Carry this
      clean-host case into the future image-to-consumer handoff and verify the resulting
      runtime closure on a supported host. Evidence: `_implementation/omni-clean-rootfs-20261031/VALIDATION.md`.
      Check newer mutable image tags independently. This observation
      concerns provenance and notice handoff, not redistribution rights or a defect in the
      existing host-runtime artifact. Offline QEMU inventory and commands:
      `_implementation/nvidia-linux-inventory-20261031/arm-inventory.log` and `probe.sh`.

- [ ] **CON203 — preserve Linux ROCm runtime provenance and notice handoff** [M, ★★★].
      On 2026-10-31, the cached Linux x64 `:latest-rocm` image digest
      `sha256:a5d68fbe64e579de09473290489b6953b5bce9aeb7644c18b86d6969bf37ace8`
      identified ROCm 10.1.0 and MIGraphX 2.18.0. Its MIGraphX ONNX Runtime provider's
      dynamic closure includes MIGraphX, HIP, HSA, COMGR and ROCm LLVM libraries. Component
      license files for MIGraphX, HIP, ROCR, COMGR, MIOpen and rocBLAS exist under their
      respective `share/doc` trees, but `dpkg-query -S` could not associate the six inspected
      MIGraphX, HIP, HSA, COMGR, LLVM and Clang shared objects with installed packages.
      Within `/opt/rocm/core-10.1/lib/llvm`, the only filename matching license, notice or
      copyright was the 303-byte `include/llvm/Support/LICENSE.TXT`, which refers readers to
      the LLVM license website. The COMGR license contains Apache and LLVM exception text,
      but its applicability and completeness for the separately copied LLVM binaries and
      other transitive or dynamically loaded components have not been established.
      A later comparison verified current AMD repository `InRelease` signatures with
      the image-build-pinned key and checked the signed package-index hashes. Selected
      files from the signed `amdrocm10-migraphx 2.18.0-1`, `amdrocm-runtime10.1`,
      `amdrocm-llvm10.1`, `amdrocm-blas-host10.1`, and `amdrocm-dnn-host10.1`
      (all four ROCm packages `10.1.0-3`) match the image's corresponding MIGraphX,
      HIP, HSA, COMGR, LLVM, Clang, rocBLAS, hipBLASLt and MIOpen shared objects;
      the checked MIGraphX, HIP, COMGR, rocBLAS and hipBLASLt notice files also match.
      This proves only those selected current-archive bytes, not the image's original
      package transaction, all dynamic resources or complete applicable notices. Scoped
      signed index, archive hashes, file lists, comparisons and unresolved notice
      observations: `_implementation/rocm-official-package-audit-20261031/VALIDATION.md`.
      The matched AMD clang executable reports LLVM source revision
      `d6f6cb691863e9258034ab48c1dfce21689d5606`, the LLVM gitlink in AMD's
      `therock-10.1` source tag. The matched MIOpen binary embeds version
      `3.6.1.39d8d603`; that short revision agrees with the tag's ROCm-libraries
      gitlink, and the image's MIOpen notice is byte-identical to that pinned source
      licence. Exact-revision LLVM and Clang source licence files were retained and
      verified against their source blob IDs. These associations do not establish the
      image's complete build inputs, all third-party notices or redistribution rights.
      Reproduce the scoped checks and private-test plan:
      `_implementation/rocm-official-package-audit-20261031/SOURCE-NOTICES.md`.
      A read-only follow-up against the same image found that its ORT MIGraphX
      provider directly imports `libmigraphx_c.so.3` and `libamdhip64.so.7`;
      the two retained OxidANT and AccelerANTgine AMD DEBs examined declare no
      package-manager dependency that installs either ROCm or MIGraphX. Their
      documented host-runtime design therefore needs a separately provisioned,
      compatible vendor runtime; this observation does not establish that the
      packages or GPU inference were run. A separately installed prospective Omni
      AMD DEB in an isolated Ubuntu 26.04 rootfs, with no vendor runtime or GPU
      passed through, rejected explicit MIGraphX execution because
      `libmigraphx_c.so.3` was absent. Carry this clean-host failure case into the
      image-to-consumer handoff and verify the resulting closure on supported AMD
      hardware; it does not establish GPU execution. Evidence:
      `_implementation/omni-clean-rootfs-20261031/VALIDATION.md`.
      The image returned no installed
      `amdrocm*` entries from `dpkg-query`, while the image build's source installs
      AMD packages before copying the ROCm tree. Record the signed build-stage
      package identities, versions, source hashes and component notices in the
      future image so consumers can assess host provisioning or a self-contained
      userspace sidecar without guessing. Direct ELF dependencies do not cover
      dynamically loaded libraries, target kernels, or other runtime resources.
      Scoped commands, candidate hashes and AMD documentation:
      `_implementation/rocm-runtime-delivery-audit-20261031/VALIDATION.md`.
      For any future self-contained GPU runtime artifact, preserve a verifiable association
      of each shipped binary and resource to its exact source/version and original applicable
      license and notice texts; include and verify those texts in the image and consumer
      artifacts. Verify the complete runtime closure and driver boundary on supported hardware.
      This is an image-to-consumer provenance handoff gap, not a conclusion about redistribution
      rights or proof that the existing host-runtime artifact is broken. Evidence and scoped
      commands: `_implementation/rocm-bundled-provenance-20261031/VALIDATION.md`.

- [ ] **CON202 — investigate locked detector failure on WSL gfx1036 with MIGraphX** [L, ★★★].
      On 2026-10-31 the cached Linux x64 `:latest-rocm` image digest
      `sha256:a5d68fbe64e579de09473290489b6953b5bce9aeb7644c18b86d6969bf37ace8`
      exposed the WSL integrated Radeon `gfx1036` through `/dev/dxg` and a render node.
      Running as root with the WSL driver libraries, both the image's ONNX Runtime 1.30.0
      and a retained OrchestrANT AMD candidate's matching-version runtime failed while
      compiling the locked DEIM detector model
      (SHA-256 `225f612fc879d604b79a569648f274672090070a07dcbdef469796df956f8392`)
      with `adaptive_topk_benchmark: all candidates failed to run`.
      The retained package's CPU model self-test passed; small Relu and four TopK graphs
      ran with profiled MIGraphX operators through both runtimes. MIOpen also warned that
      `libMIOpenCKGroupedConv_gfx1036.so` could not be opened; inspection found other
      architecture variants under `/opt/rocm` but not this one in `/opt/rocm` or `/opt/venv`.
      An independently built AccelerANTgine AMD x64 TAR (SHA-256
      `c1accbf341de3de8e7bfbfbe2c0966648e067dccc749c8926a71434aff23fee1`) reproduced
      the same warning and full-model MIGraphX compilation failure on `gfx1036` using that
      image; its CPU fallback passed, but GPU profiling stopped at the TAR and did not test
      the AppImage. The local log is `_implementation/accelerant-rocm-hardware-profile-20261031/gpu-profile.log`.
      A fresh prospective OmniAccelerANT AMD x64 TAR (SHA-256
      `585cf4a3373003fa4f900be42494f341a7f1ff4058ff93289b61e0f329940cc6`)
      reproduced the same default-settings `adaptive_topk_benchmark: all candidates
      failed to run` during locked-model compilation, along with the missing gfx1036
      MIOpen-library warning. This was a no-network WSL run on the sole HIP-visible
      integrated Radeon `gfx1036` at PCI `0000:18:00.0`; the CPU detector profile
      passed first. The disabled RX 9070 XT was not used. No MIGraphX tuning
      workaround was applied, and this observation does not establish either message's
      cause or the discrete GPU's behavior. It stopped at the TAR, without a successful
      GPU profile or parity result. Logs and source/image limitations are in
      `_implementation/omni-amd-prospective-build-20261031/VALIDATION.md` and
      `_implementation/omni-amd-prospective-build-20261031/gpu-integrated-profile.log`.
      Repeating the same package and device with the documented process-only
      `MIGRAPHX_BENCHMARKING_USE_SIMPLE=1` option exposed a specific kernel launch failure:
      the image's MIGraphX reports it was not built for `gfx1036` and recommends adding that
      target. Investigate whether the next image can include `gfx1036` in MIGraphX's
      `GPU_TARGETS` while preserving its existing targets, then re-run full-model GPU
      profiling and CPU/small-graph controls. This does not establish why the default
      adaptive benchmark failed or whether the MIOpen warning is causal. The diagnostic
      log is `_implementation/accelerant-rocm-profile-simple-benchmark-20261031/gpu-profile.log`.
      An image-ORT control with the same locked detector and deterministic random input
      failed CPU/MIGraphX output parity with `MIGRAPHX_SKIP_BENCHMARKING=1`: at
      `rtol=atol=0.001`, 1,785 of 1,800 elements differed. Optimal row matching found no
      strict matches; 30 of 300 matched at exact class, IoU >= 0.9 and score delta <= 0.01.
      Both outputs were finite. Neither produced detections above score 0.25 on this
      synthetic input, so it is not a real-world accuracy benchmark. Investigate and
      require output parity before treating the workaround as a verified GPU path. Saved
      inputs, outputs, profiles and matching results: `_implementation/accelerant-rocm-parity-20261031/`.
      A separate control used the MIT-licensed `two_cats.jpg` fixture and a Python
      reimplementation of the application's stretch/nearest-neighbor RGB preprocessing,
      checked against all four ModelANT preprocessing contract cases. The resulting input
      SHA-256 was `d44fc999b2ddcb98ecd7cea18df7b39a74298b46937a04298e20fd5828f3dede`.
      With image ORT 1.30.0, the same model, device and image digest above, a no-network
      root container, `MIGRAPHX_SKIP_BENCHMARKING=1` and no cache-path override, 1,767
      of 1,800 finite output elements differed at `rtol=atol=0.001`. Applying the app's
      confidence threshold 0.25 and per-class NMS IoU 0.45 yielded four CPU and three
      MIGraphX detections; none matched at equal class, IoU >= 0.9 and score delta <= 0.01.
      This is a provider comparison, not a ground-truth accuracy measurement. See
      `_implementation/accelerant-rocm-cats-parity-20261031/` for preprocessing provenance,
      raw outputs, per-detection matching and profiles.
      Repeated CPU inference was bit-identical. A separate three-call MIGraphX session on
      the same input showed a maximum first-versus-second output difference of 552.2444;
      each input hash stayed unchanged and outputs copied immediately after calls did not
      share memory. The profile recorded 15 MIGraphX operator events across the three calls.
      These observations do not establish the cause, default-setting behavior, native GPU
      behavior or numerical correctness. Retain parity as a release gate while investigating
      the image, runtime and device combination. Raw outputs, logs and checks are in
      `_implementation/accelerant-rocm-cats-repeat-20261031/` and
      `_implementation/accelerant-rocm-cats-alias-control-20261031/`.
      A later no-network control used the same image digest and integrated WSL GPU, a
      rebuilt AccelerANTgine TAR (SHA-256
      `583039f26baf779c404064f481d6b188b43ef2fe58a4f1db98808f6ad8e0d873`), the same
      locked detector and two-cats fixture, and two detector calls per session. With
      `MIGRAPHX_SKIP_BENCHMARKING=1` plus either `MIGRAPHX_SET_GEMM_PROVIDER=rocblas`
      or `MIGRAPHX_DISABLE_MLIR=1`, each CPU call returned four detections, each GPU call
      returned three, and the two GPU outputs differed. Both GPU traces had a verified
      non-copy MIGraphX model operator in each run. Neither setting passed detector parity.
      A test adding `MIGRAPHX_GPU_DISABLE_NONTEMPORAL_LOADS=1` also failed parity, but the
      installed image files did not establish that the switch was supported; its effect is
      unknown. `ORT_MIGRAPHX_EXHAUSTIVE_TUNE=1` without skip-benchmarking was still searching
      MIOpen kernels at the 240-second timeout and produced no GPU inference result. These
      are bounded diagnostics, not verified fixes or proof of the failure's cause. Inputs,
      exact output hashes, per-run profiles and logs are under
      `_implementation/accelerant-rocm-tuning-20261031/`.
      A separate non-packaged OxidANT CLI test used the same image, WSL device, locked
      model and two-cats JPEG (SHA-256
      `6d375ac20fadfd400b3033084f8b0581dcc145f7c14e3b24b97975e379c52999`), with root,
      no network, the WSL driver libraries, four ORT
      threads and process-only `MIGRAPHX_SKIP_BENCHMARKING=1`. The legacy Rust provider
      registration first failed at the literal `""/…` cache path. A local generic-API
      registration with explicit device and memory options created the session without
      that path error. Its same-binary CPU and MIGraphX traces recorded 787 CPU operators
      and 5 MIGraphX plus 19 CPU operators respectively; the detector reported five CPU
      detections and three MIGraphX detections. The dominant cat scores were approximately
      0.891 and 0.651. The strict detector comparator rejected the different counts.
      Retain this mismatch as a release blocker; it does not identify the cause or prove
      default-setting, packaged, native-device or other-architecture behavior. The CLI
      logs, JSON detections and profiles are in
      `_implementation/oxidant-detector-parity-cpu-20261031/results/`.
      A later non-packaged CLI test on the same WSL `gfx1036`, image, model and fixture
      repeated inference twice per session with the same benchmarking workaround. The
      two CPU outputs were identical with five detections; both GPU outputs had three
      detections and failed CPU parity. The leading cat scores were 0.8907 on CPU,
      0.6511 on the first GPU call and 0.3383 on the second. One profile recorded
      MIGraphX operators in both GPU runs (10 MIGraphX and 38 CPU operator events total).
      This demonstrates failure under the diagnostic override, not its cause or behavior
      at default settings. Logs, outputs and profiles are in
      `_implementation/oxidant-repeat-session-linux-20261031/results/`.
      A separate finished OxidANT AMD x64 TAR (SHA-256
      `dbec28967642de1692c5c5c619f6fa65b34b0c2a168773bf92f444d8e864d9a2`),
      using the same image digest and two-cats fixture hash above on WSL `gfx1036`,
      stopped at MIGraphX model compilation with `adaptive_topk_benchmark: all candidates
      failed to run`; it also warned that `libMIOpenCKGroupedConv_gfx1036.so` was absent.
      The gate rejected the package and did not establish the cause of either message or
      the behavior of another GPU. The package-specific log is
      `_implementation/oxidant-amd-package-parity-20261031/hardware-gate.log`.
      With the nondefault process-only `MIGRAPHX_SKIP_BENCHMARKING=1`, that TAR's
      bundled runtime and model ran 787 CPU operators and 5 MIGraphX plus 19 CPU
      operators in clean-environment profiles. Detector parity still failed: the CPU
      produced five detections versus three on the GPU, with leading cat scores of
      0.8907 versus 0.6511. See the same directory's `diagnostic-clean.log`, JSON and
      profiles. This workaround is diagnostic and does not make the package verified.
      With the process-only `MIGRAPHX_SKIP_BENCHMARKING=1`, compilation completed but ORT
      then failed to save its compiled model under a literal `""/…` cache path. Setting
      `ORT_MIGRAPHX_MODEL_CACHE_PATH=/tmp` in the disposable container allowed the same
      TAR's model inference to finish with 21 MIGraphX and 19 CPU operators in its verified
      trace. Its subsequent video check did not complete before the 300-second timeout, so
      the whole profile failed and the AppImage was not tested. Investigate the cache-path
      behavior and video timeout; do not infer default-setting behavior or numerical parity
      from this diagnostic. Log and trace: `_implementation/accelerant-rocm-profile-skip-with-cache-20261031/`.
      A prospective current-source OrchestrANT AMD x64 TAR (SHA-256
      `e7a3856d5e053c47fb1b5f009431b4b9b60d20d21aac2bbddd8385781637db98`)
      repeated the real-image test using the same image, model, fixture and WSL GPU.
      Two CPU calls in one session passed the shared detector comparator and profiled
      1,574 CPU operator events. Default MIGraphX initialization failed with the same
      adaptive TopK compilation error after the missing gfx1036 MIOpen library warning;
      no GPU detections were written, and the shared profile verifier rejected its
      initialization-only trace. The package uses a separate newer hub overlay because
      the recorded consumer pin does not yet support this AMD packaging path, so it is
      prospective evidence, not a successful current workflow or verified release.
      Logs and results: `_implementation/orchestrant-detector-amd-prospective-20261031/`.
      In a separate non-release experiment on that same TAR, explicitly enabling
      `MIGRAPHX_SKIP_BENCHMARKING=1` allowed two calls in one GPU session. Both had
      profiled MIGraphX operators (10 MIGraphX and 38 CPU events total), but neither
      matched the CPU result: CPU returned six detections, the GPU calls returned three
      and two, and their leading cat scores were 0.6573 and 0.3335 versus 0.9090 on CPU.
      This override is diagnostic only and does not establish a supported workaround.
      The warning does not establish the compilation failure's cause. Determine whether
      this WSL integrated GPU configuration is supported, investigate the missing device
      library and full-model error, and verify the locked model with operator profiling on
      a supported native Linux AMD GPU in the next image. Retain CPU and small-graph
      controls; do not infer native-device, non-root, or other-architecture behavior from
      this observation. Reproduction and controls: `_implementation/orchestrant-rocm-wsl-hardware-20261031/VALIDATION.md`.
      Separately, when the disabled Radeon RX 9070 XT is available to WSL, identify its
      exposed GPU and explicitly select it for a default-settings test of the published
      ROCm image; keep the integrated `gfx1036` results separate. Require the locked
      detector's CPU baseline, repeated same-session output parity and a MIGraphX model
      operator in every GPU run. Record the device, driver and image digest, and do not
      treat benchmark-skip or other diagnostic overrides as a passing image gate.
      **2026-11-02:** `deim_dfine_n_coco-v2` (`0bf16e85…`) rewrites a MatMul for DirectML and has not run on this
      device with MIGraphX. Use it for the next attempt.
      **2026-11-03, the RX 9070 XT:** `rocminfo` in the WSL container lists it as `gfx1201`, next to `gfx1036`, and
      `HIP_VISIBLE_DEVICES=1` or `ROCR_VISIBLE_DEVICES=1` selects it. On the cached `:latest-rocm` `a5d68fbe…`, not
      the current `05518138…`, MIGraphX compilation does not finish there. OxidANT's Linux AMD TAR from run 41583483219
      with `deim_dfine_n_coco-v2` passed on the CPU and stopped at the 1,800-second limit with default settings, and at
      600 seconds with `MIGRAPHX_SKIP_BENCHMARKING=1` and `ORT_MIGRAPHX_MODEL_CACHE_PATH=/tmp`. No detection, no
      profile. `_implementation/orchestrant-rocm-wsl-hardware-20261031/minimal-ort.py`'s one-node Relu, with the
      image's ORT 1.30.0, compiled on `gfx1036` in under 2 seconds with its operator on MIGraphX, and on `gfx1201`
      stopped at the 150-second limit after `Model Compile: Begin`: one thread used a full core, the other 65 slept.
      The image holds 835 `gfx1201` files, including `libMIOpenCKGroupedConv_gfx1201.so`, so the target is not simply
      missing. The package's launcher defaults to `migraphx`, so on this setup it hangs and does not reach the CPU.
      OxidANT's was the only package run.
      **Later on 2026-11-03, on `05518138…` with ORT 1.31.0:** the Relu behaves the same, and with
      `MIGRAPHX_TRACE_COMPILE=1` it reaches `relu_kernel`'s code object before it stops. The first stop is below
      MIGraphX: a plain HIP program with no ORT and no MIGraphX, built with `hipcc --offload-arch=gfx1036,gfx1201`,
      returns 42 on `gfx1036`. On `gfx1201` `hipGetDeviceProperties` and `hipMalloc` pass and the first host-to-device
      `hipMemcpy` does not return within 45 seconds, with 99% of its samples in
      `rocr::core::BusyWaitSignal::WaitRelaxed` in `libhsa-runtime64`. `HSA_ENABLE_SDMA=0`, `HSA_ENABLE_INTERRUPT=0`,
      both together, `HSA_ENABLE_PEER_SDMA=0`, `HIP_FORCE_DEV_KERNARG=0`, `DEBUG_HIP_DYNAMIC_QUEUES=0`,
      `GPU_MAX_HW_QUEUES=1` and `HIP_HOST_COHERENT=1` change nothing. Windows driver `32.0.32015.7029`, reached over
      Remote Desktop. The cause in the driver or `librocdxg` is unknown, and this says nothing about native Linux. So
      this card cannot prove a Linux AMD package under WSL. OxidANT `921d8e8`, AccelerANTgine `5e89bb7` and OrchestrANT
      `fcb936f` turn the hang into an error after 30 seconds, with one copy in a child process; `auto` in OrchestrANT and
      OxidANT moves on to the CPU. AccelerANTgine and OrchestrANT copy to the selected device index, OxidANT to device 0,
      which is the only index it gives MIGraphX. All three were run on the card. Omni `6e2738cb` pins both.
      On `gfx1036` a Relu model runs with real MIGraphX inference through AccelerANTgine's engine. The full model still
      fails at the load with `adaptive_topk_benchmark` (ORT says `Failed to call function`), with or without the check and
      with `/opt/rocm/extras-10/lib/migraphx/lib` on the search path; without that directory even Relu cannot load
      `libmigraphx_gpu.so`. The owner runs the packages under Ubuntu on this machine.
      Inside the image, `ORT_DYLIB_PATH` points at `/usr/local/lib/onnxruntime-cpu`, which a package then loads instead
      of its own (`MIGraphXExecutionProvider is absent`). Unset it for any package check in the image.

- [ ] **CON201 — check Media Foundation in the next Windows image** [M, ★★]. Owner decision 2026-11-03.
      `:winamd64-rocm` `774af209…` (2026-10-31) carries `C:\runtime\lib\gstreamer-1.0\gstmediafoundation.dll`, but a
      fresh container could not load it and `gst-inspect-1.0 mfvideosrc` found no such element. The plugin imports
      `MFPlat.dll`, `MF.dll` and `MFReadWrite.dll`, none of them in `System32` or `C:\runtime\bin`. In the next image,
      provide Media Foundation in a supported Windows container configuration, record its prerequisites and
      provenance, and verify the plugin and `mfvideosrc` in a fresh container on CPU, NVIDIA, ROCm and ARM. This may end with
      "not possible in a container": record that in `docs/image-decisions.md` and remove the entry. It says nothing
      about host cameras or GPUs.

- [ ] **CON198 — assess Linux GStreamer tensor inference dependencies** [M]. On 2026-10-31,
      `gst-inspect-1.0` in the cached x64 images `:latest` (digest
      `3c558d8828553ea2e3feedb97c99e15bb89a0820c6a056813876da4cd968d92c`),
      `:latest-nvidia` (`0e9dec3401f012fe6a5e4e47798aacbd7c2447ba5d8f6308635a3238db79f5cc`), and
      `:latest-rocm` (`a5d68fbe64e579de09473290489b6953b5bce9aeb7644c18b86d6969bf37ace8`)
      reported no `tensor_transform`, `tensor_filter`, `tensor_decoder`, or `onnxruntime`
      elements; `vp8enc` was present. AccelerANTgine constructs a pipeline using several
      of these names. Determine a supported CPU and GPU inference integration with the
      consumer, supply its required plugins and dependencies with source and license
      provenance, and test the actual model pipeline on each supported architecture and
      vendor. NNStreamer's ONNX Runtime integration is a `tensor_filter` backend rather
      than an `onnxruntime` element and its [upstream source](https://github.com/nnstreamer/nnstreamer/blob/main/ext/nnstreamer/tensor_filter/tensor_filter_onnxruntime.cc)
      describes that backend as CPU-only, so installing it alone does not establish this
      pipeline or GPU support.
      These observations apply to the cached x64 digests only; inspect current image tags
      and ARM independently.

- [ ] **CON181 — document and harmonize Windows GPU ORT provider paths** [S, ★★]. The
      published `:winamd64-nvidia` image digest `b472f91ba9553937a1c62f476ef6d01a878db4d44c754091ece08fb21ba11777`
      was inspected locally on 2026-10-30: `onnxruntime.dll` and its shared provider bridge
      are in `ONNX_ROOT\bin`, while `onnxruntime_providers_cuda.dll` is in `ONNX_ROOT\lib`.
      The installed ORT 1.31.0 wheel contains the CUDA provider and shared bridge, and Python reports CUDA,
      DirectML and CPU as available. This is a split-layout mismatch, not a missing CUDA SDK
      or proof of GPU inference. Document a stable consumer contract and either stage the
      provider consistently beside the core or test the split location across NVIDIA images
      and consumers before the next image publication. Verify source and wheel bytes match.

- [ ] **CON197 — provide cargo-expand for Flutter Rust Bridge code generation in Linux images** [S, ★★].
      On 2026-10-31, an isolated OmniAccelerANT/OxidANT code-generation check in the Linux
      amd64 CPU registry image `sha256:3c558d8828553ea2e3feedb97c99e15bb89a0820c6a056813876da4cd968d92c`
      found `cargo expand` missing; `flutter_rust_bridge_codegen generate` attempted to
      install it from the network. The existing code-quality documentation also records this
      first-use install. Pin and install a cargo-expand release compatible with the image's
      Rust toolchain and Flutter Rust Bridge generator (OxidANT's `frb-codegen.sh` pins and verifies
      1.0.127 since 2026-11-01 and can drop that install once the image carries it), record its
      licence and source, and verify a generation run in a fresh image. Check Linux ARM and the NVIDIA and
      AMD image variants separately; this observation does not establish their contents.
      FRB 2.13.0 also invokes full Cargo metadata, including dependencies for other target
      platforms. When that failed, it failed silently and the generated Dart loader stem became
      `UNKNOWN`, breaking normal application startup even though Linux compilation succeeded.
      OxidANT's `scripts/linux/verify-frb-bindings.py` now rejects such a stem. Left: the cargo-expand pin in the image.

- [ ] **CON196 — select the GPU ONNX Runtime reliably in consumer images** [M, ★★★].
      On 2026-10-30 both cached GPU images exported `ORT_LIB_LOCATION` pointing at
      `/usr/local/lib/onnxruntime-cpu/lib`, even though the CUDA or MIGraphX runtime was at
      `/usr/local/lib/onnxruntime-gpu/lib`. That CPU default is intentional. In a local
      AccelerANTgine probe the image's library search path could also resolve OpenCV's ORT
      ahead of the requested GPU core despite the executable's RPATH. Provide and document an
      explicit provider-specific setup for builds and runtime loading without changing the CPU
      default. Before the next GPU image publication, prove on each published child that a
      consumer links and loads the requested chain GPU core and matching provider, with no
      foreign or stale ORT; exercise the CPU setup too and make a missing provider fail clearly.
      An actual GPU inference and operator-placement profile remains a separate hardware check.
      On 2026-10-30 the NVIDIA arm64 child
      `sha256:6cc1a6744b88cb0e4e031c79e1a0e8bcf9d7e0277f8fac63686b5a59368f5d11`
      passed the shared unstripped wheel check for its aarch64 GPU ORT core, shared bridge and
      CUDA provider under user-mode QEMU. The image's Python ORT also ran its bundled sigmoid
      sample using CPU, while advertising CUDA; the image retains the CPU default. These checks
      do not prove requested consumer linking, chain runtime selection or GPU execution.
      **2026-11-02:** the consumers choose it themselves until then: AccelerANTgine's
      `scripts/linux/ci-gpu-candidate.sh` and the `ORT_LIB_LOCATION` in OmniAccelerANT's `linux-gpu-candidates.yml`.

- [ ] **CON174 — measure GPU image disk needs for consumer workflows** [M, ★★]. On
      2026-10-30 the locally cached amd64 NVIDIA and ROCm images reported 53.24 GB and
      74.75 GB respectively in `nerdctl images`. OxidANT's GPU build also needs compiler
      targets and package output, so image size alone cannot establish whether a hosted runner
      has enough space. Measure pull, unpack, build and artifact peaks for both variants on
      their intended runners, including cleanup and cache behavior. Establish a supported
      runner/storage configuration; retain measured image digests and do not claim a hosted lane
      works until it has completed. The early space check exists: `prepare-linux-ci-host`'s `min-free-gb`.
      On 2026-10-30 the pinned NVIDIA arm64 child
      `sha256:6cc1a6744b88cb0e4e031c79e1a0e8bcf9d7e0277f8fac63686b5a59368f5d11`
      reported 36.12 GB image size and 17.22 GB compressed blobs in nerdctl. This is not a
      measurement of build or runner peak disk use.
      **2026-11-02:** the GPU lanes of all four consumers completed on hosted runners in their release
      dry runs (AccelerANTgine 41443288812, OmniAccelerANT 41482481579, OrchestrANT 41491524238,
      OxidANT 41502007839). AccelerANTgine's Linux x64 job in the first failed during the image pull,
      apparently out of disk (the log message was cut off), and passed on rerun. OmniAccelerANT's AMD
      job hit the 180-minute timeout once (41417020203); it did not recur and its cause is unknown.
      The `:latest-rocm` pull took about 9 minutes (41517659698). Peak disk use is still not measured.

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
      1. `:latest-rocm` `05518138…` is on 3.15.0: OrchestrANT run 41491524238's x64 job pulled that digest and installed
         `onnxruntime_migraphx-1.31.0-cp315` with `ORT-CENSUS PASS`. Left: relocation. That job still takes the standalone
         Python (OrchestrANT `linux-gpu-inventory.yml:115`); prove the image's interpreter relocates by the normal consumer
         bundle path, and recheck OrchestrANT's notice inventory against its native closure. Do not suppress the notice
         check. That job turns the free-threaded wheel off, so it does not read the twins.
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
        when Ubuntu's `mesa-vulkan-drivers` moves to it. Owner decision 2026-11-03: this stays
        blocked until Ubuntu's Mesa reaches 26.3, with no source-built lavapipe before that.
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

- [ ] **CON130 — prove riscv64's pkg-config isolation on AccelerANTgine** [S, ★★].
      `riscv64_cross_env` unsets `PKG_CONFIG_PATH` and its riscv64 twin (c40797cc), and it strips the host-triplet dirs
      from `GST_PLUGIN_PATH` (0aef805d, `test-riscv64-cross.sh:163`), so QEMU no longer opens the amd64 plugins: OxidANT
      run 40837860172 logged 1224 such lines, and 41268857583 logs none. That run also compiled gtk4-sys. BeschleunigerBallett
      41156999263 passed, but its raster shard does not compile gtk4-sys. Left: AccelerANTgine's `linux-riscv64.yml` last
      ran on 2026-10-15 (38756496664), before both fixes. A dispatched run there must resolve riscv64's `gtk4.pc`.

- [ ] **CON145 — `cxxbridge` in the Linux and Windows images** [S, ★★]. Found 2026-10-21 with
      BeschleunigerBallett 7f54642c: every BB configure runs an unpinned `cargo install cxxbridge-cmd` at build time
      (`_myproject_find_or_install_cxxbridge`, `third_party/CMakeLists.txt:103`). `CXXBRIDGE_CMD_VERSION=1.0.205` matches
      OxidANT's lock; the two must match. **Windows:** `:winamd64`, `:winarm64`, `:winamd64-nvidia` and `:winamd64-rocm`
      of 2026-10-28/29 carry that ARG in their history, and `Test-Container.ps1:455` asserts the binary. Left:
      - `:latest` (web-lane tools, three arches) and the NVIDIA and ROCm variants: no Linux script installs it. An
        AccelerANTgine GPU package check had to compile it in its container, and an OmniAccelerANT CUDA build failed
        installing it from an incomplete offline Cargo cache. Verify the pinned binary before publication.
      - BB's helper refuses a missing or mismatched binary in CI.

- [ ] **CON110 — OrchestrANT's riscv64 free-threaded leg needs a seeded cache** [M, ★]. The seed's second pass on X.Yt
      and the torch stage's `ar` fix are in source since 2026-10-20 (CHANGELOG); from that seed OrchestrANT de144d10's `3.14t`
      leg under QEMU built no dependency and passed (2529 tests in 62 min). `:latest` `7d4d4129…` (hub 8119595e) is built
      from that source; this assumes the seed carried, and nobody read its X.Yt wheels. Left: OrchestrANT's
      `linux-riscv64.yml:24` still asks for `pinned`. It asks for `pinned pinnedt`, and a dispatched run passes both legs
      inside 360 min.

      The seed covers the lock at `APP_REF`; a lock that moved since rebuilds what moved, once per leg.

- [b] **CON70 — a riscv64 Flutter engine, for OmniAccelerANT's riscv64 lane** [L, ★]. CON48's
      riscv64 consumer lanes (OxidANT, AccelerANTgine, BeschleunigerBallett) cross-build on
      amd64 and test under QEMU since 2026-10-01. OmniAccelerANT has none, because no image
      carries a riscv64 Flutter. Checked 2026-10-06:
      - Flutter publishes no `linux-riscv64` engine or tool artifacts; flutter/flutter#99963
        is open.
      - Community builds exist: meta-flutter's Yocto recipes (riscv64 engine, `gen_snapshot`,
        a newer LLVM than Flutter's stable one) and KDAB's industrialflutter port.
      Owner decision 2026-11-03: this stays blocked on upstream flutter/flutter#99963, with
      neither an engine built in the image nor a third-party binary. Until then
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
      Every image carries chain ORT 1.31.0, `:latest-rocm` `05518138…` included (`ONNXRUNTIME_VERSION=v1.31.0` in its
      history; OrchestrANT run 41491524238 installed its MIGraphX wheel, census PASS). Left:
      1. A real consumer session on the right device: the GPU core and provider on an AMD GPU, not the CPU twin's version.
      2. OxidANT moves off its exact `ort` 2.0.0-rc.13 pin (`Cargo.toml:53`) to rc.14 or newer, with its own tests.

      ORT configure still builds onnx from source: v1.31.0 fails on a found ONNX package with a different protobuf.
- [ ] **CON96 — the arm64 and riscv64 children without the x86_64 host payload** [S, ★★]. Owner request
      2026-10-13 (CI prologue measures, item 5). `prune-host-payload.sh` empties `/opt/android-sdk`, `/opt/android` and
      the builder's rustup in `artifact-source` for every arch outside `HOST_PAYLOAD_ARCHES` (default `amd64`). Index
      `7d4d4129…` shows it: arm64 6.72 GB compressed (was 10.11), riscv64 4.96 GB (was 8.51), and `ANDROID_HOME` empty on
      both. Left:
      - Read the package log lines in [`build-watch-list.md` § The host payload](docs/build-watch-list.md#the-host-payload-con96-new-2026-10-13)
        and the smoke's lines on arm64 and riscv64: `SKIP android-home`, the ABI gate's `SKIP`, ARCH-PARITY still finding
        `android` and `android-sdk`.
      - Time one arm64 consumer pull against the 4.19 min median: about 1.1-1.3 min less is expected.

- [b] **CON27 — MSVC STL 14.51 breaks `find`/`count`/`remove` on odd-sized structs
      under clang-cl** [S, ★]. Fixed upstream: microsoft/STL#6294 closed and its fix #6298 merged
      on 2026-10-18. Nobody has checked whether a production toolset ships it.
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

## Open — the Windows arm64 bundle and unpublished variants

- [ ] **CON173 — reconcile and prove the GPU image architecture matrix** [L, ★★★]. A live
      registry manifest check on 2026-10-30 found `:latest-nvidia` has Linux amd64 and arm64
      entries; `:latest-rocm` has amd64 only, and `:latest-rocm-arm64`, `:winarm64-nvidia`
      and `:winarm64-rocm` returned not found. The Windows x64 NVIDIA and ROCm tags existed.
      **Owner matrix, 2026-10-30:** use the images in
      `ghcr.io/kataglyphis/kataglyphis_beschleuniger`: Linux NVIDIA on amd64 and arm64 from
      `:latest-nvidia`, Linux AMD on amd64 from `:latest-rocm`, and Windows NVIDIA and AMD
      on x64 from `:winamd64-nvidia` and `:winamd64-rocm`. Skip Linux arm64 ROCm and Windows
      arm64 NVIDIA and ROCm GPU builds; do not create image routes or artifact lanes for them.
      CPU-only Linux and Windows builds, including their existing arm64 lanes, remain supported
      using the registry's CPU images. Windows x64 DirectML may use the registry's `:winamd64`
      image where that provider is appropriate.
      A manifest entry does not prove its SDK, provider or device works. Reconcile CON31 and
      `docs/linux-accelerator-images.md` with the published NVIDIA arm64 entry; inspect its
      digest, SDK and ORT provider and run an arm64 consumer build. Before publishing each
      supported route, prove its architecture, provider and dependency closure, and record
      inference on suitable hardware; keep CPU images and tags independent.

- [ ] **CON108 — the Windows arm64 device runs OrchestrANT's Flet tests** [S, ★].
      `Stage-Arm64Tests.ps1` stages from `:winarm64`'s `PYTHON_WHEELS`, which has no Flet, so
      `test_view.py`, `test_flet_viewer.py` and `test_streaming.py` skip on the device. flet,
      flet-desktop, oauthlib and repath are pure Python; msgpack 1.2.3 has a cp315 `win_arm64`
      wheel. Add them to the store and to OrchestrANT's staging list.
      **Store:** the closure (flet/flet-desktop 1.0.4, httpx, httpcore, h11, anyio, rich, markdown-it-py, mdurl, oauthlib,
      repath, msgpack) as `PYTEST_WINDOWS_ARM64_*`, in `:winarm64` `2f537246…` of 2026-10-28 (hub 30365bcf). Left:
      OrchestrANT's lock is at flet 1.0.5 while `versions.env` pins 1.0.4, so the store must follow it; OrchestrANT's staging
      list (`Stage-Arm64Tests.ps1:44`); a device run without those skips.
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
- [ ] **CON226 — `:latest-nvidia` on the RTX 2080 host** [S, ★★]. Split from CON31 (owner, 2026-11-04), which waits on an
      arm64 host; this needs none. The owner boots the machine into Linux for it. Done when a session over the smoke's Add
      graph with `TensorrtExecutionProvider` builds an sm_75 engine and returns `[[11, 22, 33, 44]]`, and the DeepStream
      gate pipeline still passes.

- [b] **CON31 — the native arm64 nvidia route (phases A/B) and two device runs; the variants are published** [L, ★]. `:latest-nvidia`
      (amd64 + arm64, one index) and `:latest-rocm` (amd64) are published with passed acceptance receipts: amd64 on
      2026-10-28, arm64 on 2026-10-29 through the CROSS route from this amd64 host (phases C, D and E of
      `logs/research/nvidia-arm64-native-and-cross.md`, local; `CROSS_VARIANT=nvidia CROSS_NVIDIA_SBSA=1`,
      `docs/linux-accelerator-images.md` § Cross from the amd64 host). What is left of the owner's 2026-10-28 decision
      ("natively AND cross") is the NATIVE route: phase A (an arm64 host builds gpu..runtime first-class, the tag and
      refusal changes G1-G12 of the plan) and phase B (the merge of a native child into the published index). Blocked
      on an arm64 build host (Orin or another arm64 box); the cross route is the default owner of the arm64 child.
      Published manifests do not themselves prove GPU execution on the consumer's device; recheck the relevant
      image digest and run the device-specific inference gate before claiming acceleration. Also left, each on its own
      hardware:
      - `:latest-nvidia` on the RTX 2080 host: CON226.
      - `:latest-rocm` on a native Linux host with an AMD GPU, as uid 1001 with the documented run line: `rocminfo` listing
        the GPU, a `hipcc`-built program running, the Add graph through MIGraphX, and torch `cuda.is_available()` with a
        tensor op; without `--group-add`, the entrypoint's warning.
      - The arm64 child's contents and device execution: CON173.

      Sources: `docs/linux-accelerator-images.md` and `docs/windows-rocm.md`.
- [b] **CON136 — the GPU images ship TensorRT's runtime files only** [M, ★★]. Owner decision
      2026-10-21 ("Rausnehmen"). The Linux nvidia and rocm chains ran on 2026-10-28/29 with the gates in the revision
      (`check-gpu-runtime.sh:135`, `deepstream-verify.sh:155`). Blocked on the owner's actions below. Left:
      - Windows `-Gpu` with a zip staged in `windows/downloads/`, not yet read on `:winamd64-nvidia` `b472f91b…` (revision
        0aef805d): `Copy-TensorrtRuntime.ps1`'s `ships 11 runtime DLLs` line, `bk-windows-tensorrt-sdk-nvidia` tagged, the
        ORT RUN's `TensorRT detected at C:\tensorrt-sdk\current`, and the smoke's `TensorRT ships only its runtime DLLs`
        and `ORT TensorRT EP finds every TensorRT DLL it loads` passing with `cuda=1 trt=1`; zip-less, both pass on the
        empty root.
      - **For the owner: check the private package.** nvidia's `gpu`, `media` and `android` stages push to
        `ghcr.io/kataglyphis/kataglyphis_beschleuniger-stages`. The package page
        (`github.com/users/Kataglyphis/packages/container/package/kataglyphis_beschleuniger-stages`) says
        Private (never switch it: a public package cannot be made private again); `curl -s -o /dev/null -w
        '%{http_code}\n' 'https://ghcr.io/token?scope=repository:kataglyphis/kataglyphis_beschleuniger-stages:pull'`
        prints `401` (read 2026-11-04; the public package prints `200`, a missing one `403`); `DOCKER_CONFIG="$(mktemp -d)"
        nerdctl pull ghcr.io/kataglyphis/kataglyphis_beschleuniger-stages:cross-media-nvidia-amd64` fails `denied`, while
        a logged-in `nerdctl manifest inspect` of it succeeds.
      - **For the owner: delete the old public stage tags.** All three still resolve (read 2026-11-04; a delete is
        restorable for 30 days):
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
      - **Phase 7 (arm64)**: the arm64 CUDA route exists since 2026-10-29 (CON31, cross from amd64), but the
        cross media stage sets `ENABLE_DEEPSTREAM=false` off amd64: NVIDIA's arm64 DeepStream is the Jetson (L4T)
        package with its own TensorRT binding, not an SBSA one. The Jetson runtime `.deb` is pinned
        (`DEEPSTREAM_BINARIES_ARM64_SHA256`); nothing installs it. Work: decide whether the SBSA image may carry the
        Jetson deb at all (its libs link L4T's TensorRT), else leave arm64 without DeepStream by design.
        The arm64 manifest entry alone does not prove DeepStream is present; recheck the published child.
      Renovate reports `DEEPSTREAM_VERSION` (github-releases, report-only); the pin stays on 9.1.0.

## Open — hub tooling and the dev host

- [ ] **CON222 — evaluate offline gitleaks availability in consumer images** [S, ★★].
      On 2026-11-01, the cached Linux amd64 CPU image at registry digest
      `sha256:3c558d8828553ea2e3feedb97c99e15bb89a0820c6a056813876da4cd968d92c`
      had no `gitleaks` on PATH or in its selected bootstrap cache for its default user.
      With networking disabled, the shared lint gate attempted its pinned 8.30.1 download
      and failed before it could run its secret-scan self-test. Decide whether offline
      consumer linting belongs to the image contract; if so, include the pinned tool in
      the next image and verify the secret-scan gate without network access on each
      supported image architecture. This observation does not establish that the online
      bootstrap fails or describe the current mutable registry tag.
- [ ] **CON223 — a smaller Linux image for lanes that need no toolchain** [L, ★★]. Chain work. `:latest` takes about
      72 GB unpacked, so a 72 GB `ubuntu-26.04` runner cannot hold it and a job: WebDavClient run 41731774668 and
      OmniAccelerANT's docs run 41731757638 ran out of disk. Done when docs and pure-Python lanes pull an image that
      fits that runner with its job, gated like `:latest`.

- [ ] **CON214 — SquashFS tools for non-executing AppImage inspection** [S, ★★]. Evaluated in throwaway
      `:latest` containers on 2026-11-03: Ubuntu's `squashfs-tools` 1:4.7.5-1 installs on amd64 and riscv64 and is in
      the arm64 ports index, 599 kB. `unsquashfs -o <offset> -lln` lists a payload without executing the candidate and
      shows symlink targets, `-d` extraction keeps absolute links as links, and `ulimit -f` stops a 300 MB payload at
      its cap with status 153. It has no size cap of its own. Left, at a planned rebuild: add the package to the
      package stage; a shared helper that finds the offset, lists first, refuses absolute, `..` and escaping symlink
      entries, then extracts under `ulimit -f`, with a crafted-image test. This does not establish provenance or GPU
      readiness.

- [ ] **CON175 — prove Linux package system-library dependencies on a clean host** [M, ★★].
      On 2026-10-30 an AccelerANTgine AMD CPack prototype passed the image's ELF walk but its
      archive failed on clean Ubuntu 26.04 because `libgobject-2.0.so.0` was absent. The shared
      closure's default system allowlist excludes GLib/GObject from the bundle while that
      consumer's declared Debian dependencies cover only `libc6` and `libegl1`; the existing CPU
      package may have the same gap. A scratch `--no-default-system` closure that bundled those
      libraries started on the clean host with only the declared EGL dependency, under both host
      and bundled glibc. Reproduce against the recorded CPU and GPU consumers, choose and document
      whether to bundle or declare each dependency, and gate finished tar/deb/AppImage artifacts
      on clean-host startup and inference. Do not treat libraries merely present in the build image
      as proof that the installed package has them.

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

- [ ] **CON142 — the resource monitor names every runtime-lane phase** [S, ★]. In source: `runtime_step_phase`
      and per-arch gate markers name every phase after the arch loop
      ([`build-resource-monitoring.md`](docs/build-resource-monitoring.md)). Left: read the next chain's
      runtime summary. Done when it has no `stage=?`.

- [b] **CON62 — WSL containers (`wslc`) as the local Linux engine** [M, ★★]. Blocked
      upstream. Evaluated 2026-10-05 against WSL 3.0.1
      (`docs/rancher-desktop-linux-containers.md` § *WSL containers*): faster bind
      mounts and no credential trap, but no `--privileged`, `--platform` or `--device`,
      which the lanes pass. Re-evaluate when microsoft/WSL#41545 (privileged/cap-add)
      and #41123 (multi-platform) land. The Dart-only pilot is in: OmniAccelerANT
      953d6f6, `Invoke-DartChecks.ps1 -Engine wslc`, analyze 146 s against nerdctl's
      371 s, format + test 23 s against 32 s (2026-10-06).
