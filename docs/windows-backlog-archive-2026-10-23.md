# Windows backlog archive — 2026-10-23

Moved from the closed-history section of
[`windows-refactor-backlog.md`](windows-refactor-backlog.md) during the 2026-10-23 grooming.
The source baseline was merged commit `657f28031e8438e93cecfff17a1892693ff0abfd`.
The dates and proof limits below are the original observations, not new build measurements.
Open Bazel-cache, post-relink and QNN-device checks remain in the live backlog.
Earlier archives remain unchanged.

- **#181 — the LiteRT layer no longer exports bazel's trees. DONE 2026-10-12.**
  `Build-LitertLmBazel.ps1` stops the bazel server and removes `C:\bzl`, `C:\llm`,
  `C:\bzl-tools` and the bazel log after the install's contract check; the merge copies only
  `lib\litert-lm` out of the layer. Proven on a local media-litert stage (bk-20261012-152007):
  8.7 GB removed (6.66 + 1.72 + 0.33 GB), and the layer's export took 52.9 s, against 1,126 s
  in bk-20261011-184301. Its unpack took 1,047 s, against 396 s there and 1,337 s in
  bk-20261011-233025, so unpack time follows the host, not this layer, and the stage came to
  2,415 s against 2,728 s. bazel's user root (1.21 GB) and bazelisk's cache (0.11 GB) stayed;
  since CON92 the user root is `C:\bzl-user` and leaves with the rest, and bazelisk is gone. Bazel's progress now reaches the stage log once per 30 s. Not done: a
  remote action cache for the 3,603 actions every rebuild compiles afresh.

- **#180 — the patched clang-cl relinks reproducibly. DONE in source 2026-10-12.** CMake's
  default compiler for the LLVM build was MSVC `cl`, and LLVM appends `/Brepro` only for a
  Clang compiler, so each relink stamped `clang-cl.exe` with the link time (0x6ACBBE2C in
  bk-20261011-184301, 0x6AC6CAC6 in the published `:winamd64`, same 92,396,032 bytes) and
  sccache, which keys on the compiler's bytes, missed nearly every media compile after it.
  `Build-LlvmFromSource.ps1` now builds with the base image's pinned clang-cl
  (`LLVM_USER_BIN`) and fails the stage when the installed `clang-cl.exe` still carries a
  link-time stamp (`Assert-ReproducibleLink`). Proven on a local toolchain stage
  (bk-20261012-144845, 18:23): LLVM compiled cold with clang-cl in about 12 min, and
  `clang-cl.exe` carries the content hash 0x35341D1A. The next full chain rebuilds the media
  lane once against it; the relink after that is the one that keeps its hits.
- **#184 — a stopped BuildKit run keeps its record. DONE 2026-10-12.** `Build-Buildkit.ps1`
  writes `bk-<run>-manifest.txt` with `status=ok` or, from its `finally`,
  `status=failed:<stage>` and every finished stage, in the invariant culture (a German host
  had written `patched-llvm=778,9` beside `total_s=13058`). `bk-<run>-driver.log` records the
  run, each stage's start, end and failure, every retry verdict with the line that made it
  transient, and every disk-gate verdict (`Write-DriverRecord`). The resource CSV gains
  `diskFreeGB` for the build drive and `-Summarize` a `MinDiskFreeGB` column. buildctl's
  output is decoded as UTF-8. Left out: a `--progress rawjson` copy, since buildctl takes one
  progress mode; the driver log's stage stamps place the time before a stage's first RUN.

- **#153 — the step-time / silent-retry sweep. DONE 2026-10-12.** The 2026-09-01/02 logs it
  named were pruned (only manifests survive), so it ran over the three complete chains left,
  51 logs: bk-20261011-184301 (amd64, 13,058 s, smoke 268/0/1), bk-20261011-233025 with
  -20261012-051453 (amd64 rocm, 19,592 s to the disk gate, then final and smoke) and
  bk-20261010-121545 (arm64, 7,211 s, smoke 147/0/17). **The 441.3 s lifecycle floor is
  gone:** a trivial `RUN cmd /c exit 0` takes 4.9 to 9.0 s. **One silent retry in three
  chains:** rocm-llama's first RUN over the fresh migraphx image hit `ActivateLayer 0x20`,
  and attempt 2/3 went green for about 70 s; the merge fan-in self-heal did not recur (every
  merge log is `attempt 1/5`, with no `ActivateLayer`). **No clipped output** in the 51 logs,
  the 6.2 M-line VVL vertex included. **The rule for reading step times now:** subtract
  ~120 s from each RUN that started an sccache server, and nothing from the others (#179).
  What the sweep found beyond its question is #179 to #185. Before 2026-08-30 the corpus was
  pruned too, so those forensic conclusions stay unverifiable.

- **#158 / #159 / #160 / #164 / #167 / #168-#174 / #175 — the 2026-09-17
  batch: the thirteen audited defects, the eight settled-probe deletions, the
  compiler-rt verify+tar port, LLVM through sccache, smoke section 23, the
  comment-discipline wave and the three neighbourhood checks. Landed in
  `5eac94d5` (2026-09-18), unbuilt when archived.
  Archive: [`windows-backlog-archive-2026-09-17.md`](windows-backlog-archive-2026-09-17.md).

- **The 2026-09-03 doc-drift findings and the PascalCase anchors** — all six
  doc defects fixed, `deps.json`'s sccache attribution corrected, and
  `verify_doc_links.py` green over the renamed script headings. Archive: same
  page.

- **#152** — the 2026-08-31 wave: PROVEN BY BUILD 2026-09-01/02. The dual-lane
  rebuild ran it for real, and the gate did its job: the wave's compiler-rt
  ride-along had set `COMPILER_RT_BUILD_SANITIZERS=OFF`, the amd64 smoke gate
  failed on exactly the ASAN probe, the fix (`=ON`) re-ran and the lane closed
  at the best recorded state **222/0/0** (`[PASS] AddressSanitizer …`,
  `clang_rt.asan_dynamic-x86_64.dll` installs verified in the toolchain log);
  arm64 closed green at its baseline **97/0/15**. The predicted re-pay was real
  (full LLVM + media on both lanes). Narrative:
  [`changelog-archive-2026-09-07.md`](changelog-archive-2026-09-07.md) § 2026-09-01/02.

- **#149** — the `2cb182e^` warm/materialize rollback recipe: DEAD, not stale.
  FOUR independent breakages (every script path, the missing TargetArch + Tvm
  modules, the swapped media-core order, the QAIRT pin). The restore recipe is now
  a derivation rule in `windows-build-lanes.md` § Restoring the warm/materialize rollback — derive each RUN from the stage that
  runs that script TODAY. Archive: `windows-backlog-archive-2026-08-31.md`
  § Resolved 2026-08-31 (second pass).

- **#154** — QNN is integrated in ONE framework, not five: TVM, IREE and LiteRT
  were passing CMake flags upstream never defined, so CMake dropped them silently
  while all three logged success. Flags and banners removed on both lanes; the
  class is gated by `Assert-CmakeArgsConsumed`. The surviving lead is #155.
  Archive: same page.

- **#156** — LiteRT-LM QNN: DECLINED with reasons (also a standing directive
  below). Archive: same page.

- **#147 / #148 / #150 / #151** — the 2026-08-31 wave: classic driver deleted, the
  `patched-llvm` whole-dir module mount narrowed (and gated), TVM + GStreamer
  helpers moved to their leaf modules, `Set-StrictMode` plus the four latent bugs it
  exposed, the deliberate declines, the dead `build.ps1` permission entries, and the
  CHANGELOG archive split. Seven commits, `22041fc8^..ebd5457c`. Full narratives:
  [`windows-backlog-archive-2026-08-31.md`](windows-backlog-archive-2026-08-31.md)
  § Backlog wave #147-#151. Its declines are also a standing directive below.

- **#121** — QNN EP: BUILD-TIME PATH PROVEN 2026-08-31 on the full `:winarm64`
  cross run — SDK qairt-2.44.0.260225 (SHA-pinned), `onnxruntime_USE_QNN=ON`
  with the `aarch64-windows-msvc` backend set, QNN provider built, QNN runtime
  copied beside all five installs — but only ORT consumes it (#154); arch gate 1168/0, smoke 97/0/15.
  Execution verification still needs a Snapdragon host. Archive: this entry.

- **`-ResumeStage` BK equivalent** — CLOSED 2026-08-29 (no BK equivalent needed).
  The classic lane's `-ResumeStage` preserved a stopped container (hours of
  compile state), injected a fix via `docker cp`, committed to a partial image,
  and re-ran from a specific stage. BuildKit has no intermediate containers to
  preserve — but it caches completed RUN vertices, so re-running `buildctl`
  automatically resumes from the last cached step. Script fixes land via bind
  mounts (re-read at solve time), so the "inject a fix and re-run" case is
  covered natively. No BK equivalent is needed.

- **#135** — LLVM 23.1.0 AArch64 codegen: DONE 2026-08-29. `BUILD_PATCHED_LLVM=1`
  is now the DEFAULT (Dockerfile ARG + driver default), workarounds removed from
  `Build-OpencvFromSource.ps1`. `-StockLlvm` is the opt-out. Items 1+3 closed;
  item 2 (NINJA_KEEP_GOING census) is now unnecessary (root cause fixed); item 4
  filed as llvm#219200. Archive: `windows-backlog-archive-2026-08-26.md` § #135.
- **#135 follow-up — patched toolchain lacks the aarch64 compiler-rt** — DONE
  2026-08-31. The source-built `C:\llvm-patched` ships `clang_rt.builtins-x86_64.lib`
  only, so the arm64 GStreamer link died on `__udivti3` (2026-08-30 cross run,
  merge stage). The merge stage now self-heals: `Build-GstreamerFromSource.ps1`
  § 5d mines `clang_rt.builtins-aarch64.lib` from the LLVM release archive on the
  cross lane (same recipe as Install-ScoopTools.ps1). Chosen over adding the lib to
  the toolchain layer because the media branches derive FROM `bk-windows-toolchain`,
  so that would re-pay ~2 h of media compiles for one lib. Toolchain-level fix
  LANDED 2026-08-31 (`017660f4`, `Install-TargetCompilerRt` in
  Build-LlvmFromSource.ps1) and shipped with the 2026-09-01/02 toolchain
  rebuilds — the merge-stage self-heal is now the never-firing fallback.
  Nothing left here. Regression:
  `SourceBuild.GstreamerCompilerRt.Tests.ps1`. Docs:
  `docs/windows-cross-builds.md` § aarch64 compiler-rt.
  Second unmasked failure fixed in the same window: the speculative cross-lane
  opus intrinsics enablement (2026-08-30) is REVERTED to the proven disabled
  state — under clang-cl aarch64 the RTCD path applies `-mfpu=neon` (ARM32-only
  flag) and its CPU probe uses MSVC's `__emit` (absent from clang-cl). Working
  enablement recipe for a future TESTED window: `-Dopus:intrinsics=enabled
  -Dopus:rtcd=disabled` (presumes NEON+dotprod; needs a real-device smoke).
  Final gate fix in the same window: the arch-gate import walk gained the
  Qualcomm FastRPC pair `libcdsprpc.dll`/`libadsprpc.dll` as device-OS
  allowances (imported by the QAIRT HTP stub DLLs staged by `Copy-QnnRuntime`;
  they ship in every Windows-on-Snapdragon OS image, never in the SDK zip).

- **#133(d)** — LiteRT-LM CMake port: CLOSED 2026-08-29 (owner decision — staying on Bazel).
- **#134** — post-#133 cleanup wave: DONE 2026-08-29. amd64 acceptance
  PASSED (smoke 192/0/1, arch gate 1134/0). Narrative:
  [`changelog-archive-2026-09-07.md`](changelog-archive-2026-09-07.md)
  § 2026-08-29 — amd64 acceptance build GREEN, and
  [`changelog-archive-2026-08-28.md`](changelog-archive-2026-08-28.md) § #134
  acceptance run. NOT in `windows-backlog-archive-2026-08-26.md` — that archive
  (line 490) names #134 among the entries that deliberately stayed live.
- **Layer headroom dispute** — SETTLED 2026-08-28. The final image sits at ~75
  layers (counted from the inherited chain's instructions: base 16 + nvidia 3 +
  toolchain 4 + media-merge 15 + torch 3 + final 2 = 43, + 20 ENV + ~12 servercore
  = ~75). The ~108 figure was the pre-ENV-consolidation count. Updated in
  `docs/windows-build-invariants.md`.
- **#122** — CUDA on arm64: CLOSED 2026-08-28 (owner decision — at the time NVIDIA shipped no Windows-on-ARM CUDA). **REOPENED as #176 on 2026-09-19:** CUDA 13.4.2 ships `windows_arm64` installers, and x64→ARM64 cross-compilation is documented and probe-proven here — the device is needed to run the result, not to build it. Archive: `windows-backlog-archive-2026-08-26.md` § #122.
- **#136** — VS RUN caching: SOLVED + DEPLOYED 2026-08-26. Archive: `windows-backlog-archive-2026-08-26.md` § #136.
- **#137** — sccache: DONE 2026-08-28, **LANDED**, SUPERSEDED 2026-09-18. The
  `SCCACHE_GIT_REV=8ab39266` source build landed and the full arm64 chain rebuilt
  green through it on 2026-08-31; 0.18.0 (2026-09-14) ships everything that pin
  carried, so the source build retired and the base now installs the released zip
  (`Install-RustToolchain.ps1`). The next base build re-pays the rust layer once.
- **#134 free follow-ups** — ALL DONE 2026-08-28: smoke floor recalibrated (85→66),
  §19 PROVISIONAL marker removed, pin parity updated for `TVM_COMMIT`, TVM
  fixtures fixed (single-quoted `` `n `` → real newlines), three merge-stage
  test suites added (39 tests), resource sampler wired into `Build-Buildkit.ps1`.
- **#133 (a)+(b)+(c)** — DONE 2026-08-26. Archive: `windows-backlog-archive-2026-08-26.md`.
- **#128, #129** — DONE 2026-08-25/26. GStreamer webrtc/nice, OpenCV NEON dispatch.
- **#124, #125, #126, #127** — DONE 2026-08-25. vcruntime140, sitecustomize, staged deps, import walk.

## #31 — Windows registry publication: closed from recorded execution

The original task was to push verified Windows images to a registry instead of local-only
tags; the August archives describe the blocker only as the owner's registry choice.
That general decision is superseded by actual publication and consumer execution.

The registry snapshot observed on 2026-10-20 recorded the images published on 2026-10-17:
`:winamd64` (`bec12ad0…`), `:winamd64-nvidia` (`14c1a7e6…`), `:winamd64-rocm`
(`ca682539…`) and `:winarm64` (`e78fa8c3…`), all with Python 3.15 and revision `13cf002c`.
On 2026-10-19, real `windows-11-arm` run `39200278761` consumed the published arm64 bundle,
imported its chain wheels and proved the cp315t twins with the GIL off (CON74/CON79).
This is publication plus device-consumer evidence, not an inference from a push option.
The shared [Windows cross-build guide](windows-cross-builds.md) describes that published-bundle
verification. Specific GPU/hardware and private-stage publication tasks remain CON30/CON136.
