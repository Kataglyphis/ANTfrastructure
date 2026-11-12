# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-10-23 … 2026-11-04`](docs/changelog-archive-2026-11-04.md) ·
> [`2026-10-20 … 2026-10-22`](docs/changelog-archive-2026-10-22.md) ·
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

## 2026-11-12 — set the amd64 baseline to x86-64-v3 (not built yet)

- Owner decision CON264: the amd64 GCC is configured `--with-arch=x86-64-v3 --with-tune=generic`
  on the native, cross and Canadian paths; OpenCV asks for `CPU_BASELINE=AVX2` and its configure
  fails without it. No chain has run with it: the published images are unchanged.
- New gates: a critical-fix pin, the configure-line cases in `test-native-gcc-multiarch.sh`,
  `check_amd64_isa` in the runtime smoke (`test-amd64-isa-gate.sh`) and an entrypoint check that
  refuses a CPU below the baseline (`test-cpu-baseline-check.sh`), each with mutation recipes. Not
  covered: clang, Rust, Windows x64 and each shipped ELF.
  [`amd64-x86-64-v3-baseline.md`](docs/amd64-x86-64-v3-baseline.md).

## 2026-11-12 — add Intel's free GPU user space to the amd64 package stage (not built yet)

- Owner decisions CON258 and CON259: `setup-package-image.sh` installs `intel-media-va-driver`,
  `libmfx-gen1.2` and `intel-opencl-icd` on amd64, in every variant; never the multiverse
  `-non-free` driver. FFmpeg gets `--enable-libvpl` on amd64 behind its own configure check.
  `check_intel_gpu_userspace` fails an amd64 image without the driver files or the `h264_qsv`
  encoder. Nothing has run on an Intel GPU.
- The riscv64 and amd64 ISA gates now live in `06-packaging/check-arch-isa.sh` and share one
  verdict renderer and one arch guard in `smoke-common.sh`; `smoke-runtime-image.sh` only wires them.
  [`linux-accelerator-images.md`](docs/linux-accelerator-images.md#intel-gpu-user-space).

## 2026-11-09 — repair Linux TensorRT cross builds and CUDA cache parsing

- NVIDIA ARM64 run `20261109-102131-e69f48d7` ended with exit 1 at 17:02:20Z.
  Both CUDA Python variants and QNN's module/export/HTP checks passed; TensorRT
  then configured nvcc with native g++ because CUDAHOSTCXX captured CXX before
  target setup. Select target CXX first and retain setup failures. The real old
  CMake/NVCC control fails; the fixed control compiles an AArch64 object with all
  five production GPU architectures.
- Native ldd returned 1 for the ARM module while the old closure gate passed.
  Closure checks now retain transport errors; TensorRT's SBSA check runs the
  target loader under bounded QEMU with explicit chain and target SDK paths.
  The complete isolated TensorRT build passes with both exports, five original
  licence texts and G2. Its repeat records 329 cache hits (317 C/C++, 12 CUDA
  subcompilations), zero misses/errors and one uncached internal compilation.
  This uses the target CPU ORT core; final GPU media/runtime and inference
  remain separate required proofs. The existing TensorRT-major mutation now
  targets the revised guard and tests a resolved closure linked to the wrong
  major, preserving its rejection independently of inspector failure.
- Linux ORT applies `003-cuda-standard-sccache.patch` through the existing patch
  driver to both CUDA source branches, then rejects partial or drifted options
  before configuration. Tarball and Git fixtures prove repeatable byte changes.
  A private-cache NVCC replay reproduces `multiple input files` with the old
  separated option; the joined option yields 12 repeat hits across CUDA,
  device code, PTX and CUBIN, zero cache errors and one uncached internal step.
  The new guards have 17 biting mutations; no full CUDA-core or remote-cache
  repeat, final image or consumer receipt is inferred from these controls.

## 2026-11-09 — keep TensorRT protobuf C++ flags out of rc.exe

- The TensorRT plugin build now scopes protobuf 21.12's compiler options to
  C/C++ before configuration. This keeps `/bigobj` and other compiler flags out
  of `rc.exe` and its `cmcldeps` preprocessor without dropping C/C++ options or
  the resource. Regression controls cover drift, missing inputs, idempotence and
  unconditional ordering; native compilation remains a separate chain result.
  Mixed already-scoped blocks now reject appended bare, quoted or unknown
  arguments, and unknown original options fail before rewriting input bytes.
- Shared Windows plugin C++ flags retain `/EHsc`. Replacing the CMake flag
  string had dropped the platform exception default and made TensorRT plugin
  sources fail with `cannot use throw with exceptions disabled`. The policy
  keeps the ORT C++ API's throwing semantics and existing warning flags.
  A later full lane and GPU execution remain separate acceptance requirements.
- ONNX CUDA generator options now use `SHELL:-std=c++20` in both branches.
  The separated long option made the pinned cache parser reject all 605 CUDA
  commands in the measured run. A replay of the actual argument policy keeps
  every warning and all five GPU targets, reproduces that refusal and then
  records CUDA, PTX, CUBIN and device-code hits with the joined option. This
  local one-kernel control does not replace the full plugin/remote repeat.
  Source fixtures check both branches, exact tokens, atomic drift refusal and
  preserved line endings; all four new mutations bite. File I/O uses the
  canonical patch API, and source fixtures share the harness regex counter
  and directory staging instead of copying those operations.
  Git Bash gate instructions require native symlinks; default file copies
  fail the unchanged QNN fixture instead of proving its library links.
  Structural tests share unconditional-call and source-order assertions in the
  harness, preserving the IREE scratch lifecycle checks without copied logic.
  The existing harness byte-verdict mutation now uses a shell-neutral Python
  subprocess transport while retaining all 45 required results and failure checks.
  The three lifted-fixture recipes use the same portable transport and retain
  their original minimum, equal passed/total, and empty failure/skip requirements.
  Four older cache, text, pip and QNN mutations call the result-writing runner
  directly, avoiding Unix-only directory setup before a native Windows test.

## 2026-11-09 — verify acceptance cleanup and publish the plugin-only ROCm wrapper

- Acceptance checks each consumer and ownership-helper container through a successful engine query
  after removal. A remaining exact name or failed query refuses a passed receipt. Already-auto-removed
  containers remain idempotent; logs retain both raw command statuses and diagnostics. Ownership
  restoration still runs after consumer-removal failure, and original consumer statuses remain intact.
  The offline suite passes 29 tests and all 11 new mutations bite; no host-process or GPU proof is added.
- ROCm runtime run `20261109-081137-973f29cc` from clean hub
  `7f97f31c122241a6eea8ba62229bbbc56c00444c` completed with amd64 wrapper
  `sha256:e9fc824e6129670a06a4e81980676e4d7a1effb3013726f844cd12d5d097c55f` and index
  `sha256:4e76aa2a75e104570794be965034bcc3276bb5ba78c98ab863659ed6630ca8de`.
  All six default consumers passed on `linux/amd64`; the exact receipt is
  `logs/image-acceptance/20261109-081137-973f29cc/receipt.json`. Every recorded log hash matches,
  and an independent post-run engine query confirms all of this run's named containers absent.
  The accepted index was promoted to `:latest-rocm` with its runtime platform preserved. This run
  preceded the stricter removal helper above; it proves the plugin-only image, not fresh GPU inference.
- NVIDIA ARM64 media/android recovery run `20261109-102131-e69f48d7` started from fully proved
  `bf4c7d47` after ROCm actually ended. Main remains frozen during that chain; the additional
  acceptance fix is isolated in the worktree and requires its own complete source preflight.

## 2026-11-09 — retry QNN configuration without losing raw failures or diagnostics

- NVIDIA ARM64 media run `20261109-002505-d3b3c0b7` reached QNN configuration after the CUDA
  build, then GitHub returned HTTP 504 for the fork's pinned protoc archive. Its QAIRT SDK hash
  check passed. The failed shared RUN produced no final media image, wrapper or consumer receipt.
  NVIDIA amd64 media/android had already passed in run `20261108-180128-c3904567`.
- QNN configuration now uses the existing three-attempt retry with ten-second delays, retains all
  stdout/stderr in `build.log` and returns the last raw failure after exhaustion. Compilation stays
  outside the retry. The 100-assertion offline QNN suite and eight biting mutations prove transport,
  limits, logs and failure propagation; an actual corrected rebuild and acceptance remain pending.
  Its fake build driver is a tracked Bash fixture, carried into mutation mirrors and checked as shell.
  [Failure and scope](docs/failure-modes.md#qnn-configure-loses-a-completed-cuda-build-to-a-transient-protoc-download).

## 2026-11-09 — keep perf transport and interrupted proof records accurate

- The first full preflight of the permanent runner reached the complete script suite, where the
  perf-report fake engine misread the required nerdctl AppArmor option as its image. The fixture
  now consumes that option pair; production security, uid assertions and grading checks remain.
  A mutation removes this parsing to prove the existing perf-report tests fail. The failed full
  run and its partial mutation results remain preserved; they are not a complete preflight proof.
- Interrupted isolated preflights leave an unobserved command exit null and record the interruption
  exit separately, while still cleaning only their own containers. A transport fixture proves the
  raw interruption, failed verdict and restored report mode without starting a real container.

## 2026-11-09 — preserve recurring proof tools and isolate mutation startup caches

- Regular isolated-preflight, unit-monitoring and native-plugin drivers now live in the repo,
  with retained source snapshots and run inputs under `logs/`. Existing scratch drivers were
  archived with their paths and hashes. The preflight runner binds frozen source read-only,
  removes only its own containers and retains raw failure and cleanup evidence. Observer timeouts
  leave builds running. Native probes reuse the production loader and preserve its extracted body;
  a real TensorRT probe passed loading and both exports, without registration or inference.
- Consumer acceptance can materialize a no-replace platform plan while retaining the entire
  validated consumer contract. Plan creation alone proves no consumer execution.
- Full local preflight at `0f77ee06` passed the other 41 jobs and 545 script suites, but failed two
  mutation baselines after one PowerShell startup abort: 4597/4599 mutations were proved. Unix
  mutation commands now get private XDG caches until child reaping, matching the upstream shared
  startup-profile failure. The failed run remains failed; a new full proof is still required.
  Regression fixtures and mutations cover cache lifetime and the new operational refusal paths.

## 2026-11-09 — record Windows cache evidence and accepted ARM64 publication

- The resource guide now describes the pinned hub sccache binary and its source,
  patch and checksum path, replacing stale instructions for upstream 0.18.0.
  The #2862 report remains open; #2809 merged on 2026-11-02. Per-stage gaps and
  the missing CUDA-plugin repeat measurement stay open in CON229.
- GPU notes distinguish the earlier AMD reference-host result from the native
  RTX 2080 driver probe of 2026-11-08. Driver discovery, container file checks and
  actual plugin inference retain separate evidence requirements.
  They also retain Microsoft's supported-base requirement: Server Core and Nano
  Server are excluded, and matching host/image builds alone cannot prove GPU
  support or execution.
- The dated ARM64 media/cache result records the initial disk refusal and the
  successful full retry after selected cleanup: 152 smoke assertions, zero
  failures, 17 cross-lane skips and a passing publish gate at `7c575e34`.
  Its subsequent candidate device run 42579941215 passed 22/22, including real ONNX
  frames and the cp315t IREE twin. The owner-approved `:winarm64` tag now points to
  `sha256:9ee61e2f49b5e59624d4ed4a4de3ec86c985f9f71567d175b5e320d85bbac137`,
  preserving its runtime platform; the cross-build guide records the receipt.
  The normal public-tag follow-up run 42583681115 also passed 22/22.
  CUDA-plugin cache and GPU execution measurements remain separate requirements.
- The NVIDIA patched-LLVM RUN records 4,233 compiler requests and WebDAV hits,
  without misses or cache errors. This is compiler-cache coverage for that stage;
  CUDA-plugin initial/repeat and hardware inference remain open.

## 2026-11-08 — runner-default fixtures isolate the outer worker cap

- The full local mutation run exposed `ordered-jobs.default-one-per-cpu` surviving when the outer
  preflight exported `RUN_TESTS_JOBS=4`. The copied runner fixture now clears that inherited value
  before applying explicit case arguments; serial and invalid inherited caps exercise its default.
  The existing default mutation and a new fixture-isolation mutation prove the rendezvous controls.
  These fixtures check scheduling and verdicts, not the coverage of the suites they invoke.

## 2026-11-08 — wheelhouse receipt probes keep their recorded diagnostic locale

- A full Linux preflight under `LC_ALL=C` exposed locale-dependent GNU find quotes in the wheelhouse
  failure fixture. Its child probes now use `C.UTF-8` and compare the original receipts under both parent
  locales. The original bytes and statuses stay checked; `lib.wheelhouse-receipt-locale` restores inherited
  locale selection to prove the regression. These are offline fixture checks, with no wheel or image build.

## 2026-11-08 — accept a Windows ARM64 image by digest before changing its tag

- The ARM64 workflow accepts an optional lowercase SHA256 digest. Both container
  actions use the same image, while default runs keep the shared image selector.
  Export records the actual image/config/revision, ZIP hash and CI source/run/attempt;
  the device checks that binding before its full existing gate and uploads a
  passed or failed receipt with the raw status. Manual runs have isolated concurrency.
  Fourteen mutations cover input, platform, identity, byte and status refusals plus
  actual workflow/module transport. Fixtures do not authenticate receipts or prove
  hardware execution. No image tag is promoted by this workflow.
- Device run42525202720 at cb2b8db6 now passes onnxinference:21/22 device steps pass;
  only the older published IREE free-threaded twin still fails. Image acceptance
  and the new workflow's CI remain separate required evidence.
- Windows run42525202620 exposed a cold module-call failure (#250): the export's
  required import loop omitted filename suffixes, so the existing closure scan
  could not discover OrtPayload. The loop now lists concrete module filenames;
  the same complete cold suite fails before and passes after the correction.
  Failure details remain on one line so the CI report retains the missing names.

## 2026-11-08 — the ARM64 export carries app-local chain ORT DLLs

- Device run42521429496 at d63c982d reached the real ONNX frame probe but loaded
  ORT1.17.1/API17 while gstonnx requested API31, then crashed with 0xC0000005.
  The ZIP now carries the chain core, provider bridge and DirectML beside its
  executables, ahead of the client's System32 lookup. A small temporary overlay
  preserves the image tree; duplicate archive paths fail. Native ZIP/hash tests
  fail before the fix, portable PE staging covers both architectures, and two
  mutations prove omission and duplicate-path refusal. Device execution remains
  pending; this does not accept the older published IREE twin or prove GPU use.

## 2026-11-08 — the ARM64 device-gate export carries the GStreamer module's shared sibling

- The ARM64 device job in run 42489063718 could not reach its WebRTC and ONNX frame probes: the
  exported GStreamer module required `WindowsScripts.Shared.psm1`, but the export omitted it.
  The export now carries that sibling; tests check all exported module hashes and import
  the exported GStreamer module in a fresh child session. The regression fails before the fix,
  and `lib.arm64-export-shared-module` removes the sibling to prove the guard through a
  host-portable copy-loop suite; native ZIP tests remain in the Windows suite. Device execution
  and the previously reported ONNX crash still require a passing ARM64 device run.

## 2026-11-08 — the IREE cross twin gives nanobind its ABI through SKBUILD_SOABI

- The arm64 chain at 2ef097ca stopped in media-tvm on `IREE twin: build.ninja builds no nanobind-static-*-ft library`.
  The gate was right: CMake 4.4.5's cross FindPython queries no interpreter and sets `Python_SOABI` to an empty normal
  variable, which hides the `-DPython_SOABI` cache value the first fix passed. The twin now passes `SKBUILD_SOABI`, which
  nanobind 2.9.0 reads first; a two-pass configure with 4.4.5's FindPython gives `NB_ABI=cp315t-win_arm64`
  (`lib.iree-twin-cross-soabi` now puts the dead spelling back).

## 2026-11-08 — the Windows plugin EP builders share their steps; develop's gates green again

- b89caee3 turned five hub gates red: code duplication (eight pairs), comment size, PowerShell complexity
  (`Get-MediaBranchVersionArg` at 86 lines), the version snapshot's pinned builder count and, through them, a mutation
  shard. The QNN and TensorRT builders now share `Save-VerifiedSourceArchive`, `Get-OrtChainPrefixFile`,
  `Get-OrtPluginEpCmakeArgs`, `Invoke-CmakeConfigureLogged` and `Install-NativeFileStage`; the four CMake G2 consumers pass
  `Assert-ChainOrtOnly -CmakeBuildDir`; media-core's pins are a key list; the suites share `Import-TestRepoModule`,
  `Invoke-TestPluginStage` and `New-TestOrtChainPrefix`. No allowance was added, and the Test-Container/Install-Cuda row
  left `code-dupes.allow` as it fell under the threshold.
- G2 reads a plugin EP's own `onnxruntime_ep_*` binaries and its `Microsoft.ML.OnnxRuntime.EP.*` C# package as a
  consumer's, as the Linux gate does, so the TensorRT plugin's gate can pass (`lib.g2-plugin-ep-*`).

## 2026-11-08 — the plugin EP stages create their directory

- The third arm64 chain stopped in the QNN plugin's staging with `Could not find a part of the path
  'C:\runtime\lib\onnxruntime-ep-qnn\bin'`: `Reset-SourceBuildDirectory` removes the directory, so the next
  `Copy-Item` wrote the DLL as a file under the directory's name. Both plugin builders (QNN, TensorRT) recreate it
  first; install tests over a stale tree and `lib.qnn-ep-stage-dir` / `lib.trt-ep-stage-dir` hold it.

## 2026-11-08 — `:latest` ships Qualcomm's plugin QNN EP on arm64 (CON232 proved)

- The seventh proof chain (runtime stage, three arches, run 20261108-131033) published `:latest` with arm64 at
  `sha256:19b99d3f4d02…`: the plugin module, 48 QAIRT backends, `ORT_QNN_EP_ROOT`, no in-tree QNN provider, all smokes
  and the acceptance receipt green. That receipt covers the six `linux/amd64` consumers; it does not claim
  arm64 or riscv64 consumer runs. The sixth chain had failed only on GitHub's 503 for the HailoRT tarball, now mirrored.

## 2026-11-08 — Linux: the CUDA EP is the plugin, the TensorRT EP NVIDIA's plugin, the in-tree TensorRT and MIGraphX EPs are gone (CON233, CON231 step 3)

- Owner decision (second of the day): "sofort komplett, inklusive Entfernen" on both lanes. The nvidia ORT GPU build
  passes `onnxruntime_BUILD_CUDA_EP_AS_PLUGIN=ON` and no `--use_tensorrt`; `assert_onnx_cuda_plugin_ep` fails a module
  that still exports `GetProvider` (the in-tree module exports the two plugin entry points too, so only the bridge
  tells) or an in-tree TensorRT EP beside it, the GPU verify stage repeats both, and the
  runtime smoke's `gpu_cuda_plugin_verdict` also wants `cuda-plugin-ep=1` in the venv wheel's build info.
- `37-build-tensorrt-plugin-ep.sh` builds NVIDIA's plugin TensorRT EP at `ORT_TENSORRT_EP_COMMIT` with its four git
  dependencies seeded from pinned release archives (`ORT_TENSORRT_EP_{PROTOBUF,ONNX,GSL,FLATBUFFERS}_*`), an `ORT_HOME`
  shim over the chain GPU prefix and a `TENSORRT_HOME` tree over the apt runtime; it ships at
  `/usr/local/lib/onnxruntime-ep-tensorrt` with `ORT_TENSORRT_EP_ROOT`, G2-stamped, in the census contract, verified by
  its media stage and by `gpu_tensorrt_plugin_verdict`. Four in-image runs found and fixed: the seed gate lower-cased the
  repository too, `grep -q` on a 4000-symbol module killed `readelf` under `pipefail`, G2 read the module and its C#
  package as ORT, and a bare verify call had no `TENSORRT_VERSION`.
- The rocm variant: `30-build-native-amd.sh`, `--use_migraphx`, the `onnxruntime-migraphx` wheel and patches 003/004 are
  gone; the plugin MIGraphX EP builds over the CPU prefix, the wrapper takes the CPU `onnxruntime` wheel, and an image
  with `libonnxruntime_providers_migraphx.so` fails its runtime smoke.
- Packaging: `stage_ort_runtime amd` stages the plugin module from `ORT_AMDGPU_EP_ROOT`; Python AMD bundles copy it beside
  the chain core, prove it against the image's copy and require `MIGraphX` in the self-test's `registered_plugin_eps`
  (`--require-registered-plugin`); the venv TensorRT provider and its optional host imports are gone
  (`# PYTHON_APP_PLUGIN_EP_API=1` replaces the TensorRT marker; `python-ci-linux.yml` checks it and passes `MIGraphX`).
- Suites: `test-tensorrt-plugin-ep.sh` (new), and the GPU runtime, G2, census, bundle, AppImage, package and self-test
  suites moved with the code; 29 recipes in the `onnx-ep-tensorrt`, `gpu-runtime`, `provenance` and `packaging` families.
- Align the ROCm overview, wheel selection and MIGraphX prefix lookup with the plugin-only CPU-prefix build; remove
  the obsolete native AMD entry point and wheel from the setup instructions.
- Replace the app-venv's stale in-tree MIGraphX/TensorRT availability assertions with native plugin loading and
  both factory exports, while retaining the ORT Python import and Torch HIP/CUDA checks. The new fixture suite covers missing modules,
  exports and roots, both selected call sites and the CPU path; GPU registration and inference remain separate.
- ROCm proof run `20261108-161535-562db2ce` (`rebuild-sequence-36`) passed media and android but stopped at that
  stale app-venv assertion. No fresh runtime wrapper or acceptance receipt was produced; the successful package
  smoke alone does not prove the wrapper or the removal from the shipped image.

## 2026-11-08 — Windows nvidia: the CUDA and TensorRT EPs are plugins (CON233)

- Owner: "Windows sofort komplett". The nvidia lane builds CUDA as ORT's plugin
  (`onnxruntime_BUILD_CUDA_EP_AS_PLUGIN`, same DLL and EP name) and no in-tree TensorRT EP. Patch 008 keys the plugin
  CMake's force-includes on the MSVC frontend variant, so clang-cl gets `/FI`; the in-tree CUDA CMake and its PCH patch 002
  are gone. `Assert-OrtCudaPluginEp` fails a staged DLL that still exports the provider bridge's `GetProvider`.
- `Build-OrtTensorRtEpFromSource.ps1` builds `onnxruntime/onnxruntime-ep-tensorrt` at `ORT_TENSORRT_EP_COMMIT` in the ORT
  RUN (amd64): an `ORT_HOME` shim over the chain, its protobuf, onnx, GSL and flatbuffers as SHA256-pinned seeds
  (`ORT_TENSORRT_EP_*`), downloads disconnected, a G2 stamp as consumer `tensorrt-ep`, licence texts and provenance in
  `C:\runtime\lib\onnxruntime-ep-tensorrt` (`ORT_TENSORRT_EP_ROOT`). `Get-SevenZipSkippedLink` moved beside
  `Expand-SourceTarball` so both plugin builders share it.
- The smoke grades both plugins by their file contract (`Get-OrtNvidiaPluginFinding`, the shared
  `Get-OrtPluginEpExportGap`) and the build info (`cuda-plugin-ep=1`); registration runs only where `nvcuda.dll` loads.
  `SourceBuild.OrtTensorRtEp.Tests.ps1` and 20 new mutation recipes (`lib.trt-ep-*`, `lib.ort-cuda-plugin-*`,
  `lib.nvidia-smoke-*`, `lib.plugin-ep-export-gap-bridge`) hold it. Not proven yet: an nvidia chain build, and registration or inference on an NVIDIA host.

## 2026-11-08 — the QNN plugin EP stages its link output

- The second arm64 chain compiled the QNN plugin and stopped in its staging: the fork's POST_BUILD copies
  `onnxruntime_providers_qnn.dll` into its wheel tree, so a recursive search found two. `Get-OrtQnnEpBuiltDll` takes the
  link output at the build root (`lib.qnn-ep-link-output`).

## 2026-11-08 — the QNN plugin EP compiles under clang-cl

- The first arm64 chain with the QNN plugin stopped in its compile: the fork passes ORT's MSVC-only
  `/experimental:external` under warnings-as-errors. `Update-NinjaFile -OrtMsvcOnlyFlags` now owns ORT's three MSVC-only
  strip patterns, and both the ORT build and the fork run it after configure (`lib.qnn-ep-ninja-msvc-only`,
  `lib.ninja-msvc-only-wx`).

## 2026-11-08 — every ORT EP with a plugin moves to it, consumers first (owner directive)

- Owner decision: every ONNX Runtime EP that has a plugin moves to the plugin system on both lanes, at its newest
  version, and the in-tree paths go. Order: plugins that need no consumer change first, then one registration helper
  per language and every consumer (CON231 step 2), then the CUDA switch and the in-tree TensorRT/MIGraphX removals.
  The evidence and links: `logs/reports/` of the 2026-11-08 deep research, summarised in BACKLOG CON233.
- Windows rocm: the WebGPU EP is the plugin code linked into `onnxruntime.dll` (`onnxruntime_USE_EP_API_ADAPTERS` and
  `onnxruntime_WEBGPU_STATIC_PLUGIN`, ORT 1.31), still registered as `WebGpuExecutionProvider` with no consumer call.
  The configure gate fails a build without both switches; `Ort.WebGpuStaticPlugin.Tests.ps1` holds it on both hosts.
- `ORT_TENSORRT_EP_COMMIT` / `ORT_TENSORRT_EP_SOURCE_SHA256` pin onnxruntime/onnxruntime-ep-tensorrt at its newest commit
  (6403f3c; the repo has no release yet) for the TensorRT plugin, built beside the in-tree EP on the nvidia lanes.

## 2026-11-08 — the ARM64 device gate's two red steps (issue 236)

- IREE's cross `cp3XYt` twin re-enabled the GIL on the device (`first by iree._runtime_libs._runtime`):
  FindPython runs no interpreter on the cross lane, `Python_SOABI` stayed empty, and nanobind configured
  without free-threading. The twin passes `Python_SOABI=cp3XYt-<tag>` (`Get-IreeTwinSoabi`) and
  `Assert-IreeTwinFreeThreadedNanobind` fails a configure without a `nanobind-static-*-ft` library.
- `onnxinference` exits `0xC0000005` on the device, and the gate lost the output to PowerShell's native-exit
  error. `Assert-GstOnnxInferenceRun` keeps it and bisects a failure (frames alone, `ORC_CODE=backup`,
  `GST_DEBUG=onnx*:6`), restoring the environment after each probe. The crash itself stays open until a device run.
- `SourceBuild.IreeTwin.Tests.ps1` and `Gst.OnnxInferenceRun.Tests.ps1` gain the cases, with five new recipes
  ([failure-modes.md](docs/failure-modes.md#the-gil-was-re-enabled-first-by-iree_runtime_libs_runtime-on-an-arm64-device)).

## 2026-11-08 — Windows builds the QNN plugin EP in the ORT RUN (CON232)

- Windows amd64 and arm64 build Qualcomm's plugin EP from the pinned fork, as the `QNN plugin EP` stage of the ORT
  RUN (`Build-OrtQnnEpFromSource.ps1`). `-Donnxruntime_ORT_HOME` points at a shim holding the chain's
  `onnxruntime.dll/.lib` and `onnxruntime_providers_shared.dll/.lib`; the fork's `ort_core` headers are copied
  flat into it after configure. The build fails on an ORT core in its tree that is not the chain's bytes, and on a
  module without `CreateEpFactories`/`ReleaseEpFactory` or with an import outside the chain, QAIRT and the OS.
- `C:\runtime\lib\onnxruntime-ep-qnn` holds the DLL, the QAIRT backends, both licence sets and a provenance
  manifest; `ORT_QNN_EP_ROOT` names it. ORT and GenAI lose the in-tree EP and its staged QAIRT DLLs, and
  `Resolve-QnnSdk` no longer returns CMake switches.
- The ORT census counts the fork tree as a chain root and the plugin directory as a chain reference; the smoke
  gate checks the file contract (`Get-OrtQnnPluginFinding`). `SourceBuild.OrtQnnEp.Tests.ps1` and seven
  `lib.qnn-*` mutations hold it ([windows-cross-builds.md](docs/windows-cross-builds.md#the-qnn-plugin-ep)).

## 2026-11-08 — the QNN EP is Qualcomm's plugin EP (CON232)

- Owner decision: the QNN execution provider moves to Qualcomm's plugin EP on both lanes. Linux arm64 builds
  [onnxruntime/onnxruntime-qnn](https://github.com/onnxruntime/onnxruntime-qnn) v2.7.0 from its pinned tag
  tarball (`ORT_QNN_EP_VERSION`, `ORT_QNN_EP_SOURCE_SHA256`) in the media stage's accelerator RUN
  (`36-build-qnn-plugin-ep.sh`): the fork's `build.py` with `--ort_home` over a shim of the chain prefix, so it
  builds no ORT core and links nothing but the chain's library (it compiles against its own `ort_core` headers); the module lands in `/usr/local/lib/onnxruntime-ep-qnn` with
  the QAIRT backends, licences and provenance beside it, and `ORT_QNN_EP_ROOT` names it on arm64 only. The in-tree
  QNN EP leaves the ORT CPU build and GenAI's staging; `verify-media-artifacts.sh` fails a provider in the CPU prefix
  and checks the plugin tree on arm64; the plugin root is a census REF (a chain root, not a G2 consumer, since its
  source is an ORT fork); the wrapper's runtime probe judges root, exports and backends per arch. Pins, SBOM row,
  suite (`test-qnn-plugin-ep.sh`), seven recipes and the pages ([qnn-linux.md](docs/qnn-linux.md#the-plugin-ep),
  [contract](docs/consumer-image-contract.md#qualcomms-plugin-qnn-ep),
  [single-source rule](docs/onnxruntime-single-source.md#a-plugin-ep-built-from-an-ort-fork-is-a-chain-root)).
  Proof in the image follows with the next default chain; Windows arm64 follows in the Windows lane.

## 2026-11-07 — the TensorRT EP smoke check passes a complete runtime

- The first nvidia chain with TensorRT staged failed its smoke gate on
  `ORT TensorRT EP finds every TensorRT DLL it loads ... missing from the shipped TensorRT runtime:`, naming
  nothing. `Get-TensorRtEpGap` had found no gap; its empty result, assigned through `if`/`else`, bound
  `Assert-Test -Finding` as `$null`, which `@()` counts as one finding. `Assert-Test` now treats a `$null`
  finding list as empty, and `Test-Container.ps1` wraps the gap in `@()`. A Smoke.FindingVerdict case and the
  `lib.smoke-finding-empty-if-result` mutation hold it
  ([failure-modes.md](docs/failure-modes.md#a-smoke-check-fails-and-names-no-finding)).
## 2026-11-07 — `:latest-rocm` ships AMD's plugin MIGraphX EP (CON231, step 1)

- CON153 is proved inside a RUN: the fourth rocm proof chain's media stage logged `asset-mirror| hit` for all ten
  plugin-EP archives that `fill-asset-mirror.sh --apply` had mirrored from the previous run's misses. The entry
  shrinks to its leftover, a chain-start line that says when the secret is absent.
- `:latest-rocm` ships the plugin since 2026-11-08 01:25 UTC (wrapper `sha256:796e6abed4d3…`): the sixth proof chain
  passed every gate, failed only the acceptance step on a dirty hub tree, and the manifest-only replay accepted and
  promoted the pushed candidate (six consumer checks passed).
- The proof chains found six gaps in the first integration, each now held by a suite case and a recipe:
  the seed reads ran under the media scripts' `IFS` and fetched `'' ''` (shell safety class 3); the export
  check missed the version script's `CreateEpFactories@@VERS_1.0`; and the media merge stage never COPYed
  the plugin tree, so the pinned media image lacked it while every in-branch gate was green; and the seed loop
  reused the source's `sha`, so `provenance.txt` named abseil's hash (the `:latest-rocm` of 2026-11-07 carries
  that line until its next publish); and the module reached the wrapper without a chain-only ORT gate (G2) or a census
  entry, so SHIPPED-TRUTH E stopped the fourth chain with `UNREGISTERED`, as designed. The build now ends in
  `ort_assert_chain_only amdgpu-ep` over its work tree, records and configure log, the census contract names the
  module and its stamp, and `F11_GATE_CALLS` holds the call; and the gate then read the CPU-only DNNL provider
  linked into `/usr/local/lib` as foreign because it knew only the GPU prefix, so it takes both chain prefixes. The plugin step
  now runs on every chain and leaves an empty tree where it does not build, and the merge stage copies it
  ([failure-modes.md](docs/failure-modes.md#a-media-artifact-is-built-and-verified-and-the-merged-image-does-not-carry-it)).
- Owner decision: the Linux rocm variant moves to AMD's out-of-tree plugin EP. The media stage builds
  `libmigraphx-ep.so` from the pinned `onnxruntime/onnxruntime-ep-amdgpu` commit (`35-build-migraphx-plugin-ep.sh`:
  every FetchContent seeded from a sha256-pinned archive, `FETCHCONTENT_FULLY_DISCONNECTED`, an imported
  `onnxruntime::onnxruntime` over the chain's library, the two exports and the closure checked), the package
  stage ships it under `/usr/local/lib/onnxruntime-ep-amdgpu` and sets `ORT_AMDGPU_EP_ROOT`, and the runtime
  smoke's GPU gate judges it (`gpu_plugin_ep_verdict`). The shared `ORT_AMDGPU_EP_COMMIT` moves to the commit the
  spike proved on an RX 9070 XT (4 ms per frame, detector parity). The built-in provider stays until every
  consumer registers the plugin ([contract](docs/consumer-image-contract.md#amds-plugin-migraphx-ep)).
  `test-migraphx-plugin-ep.sh` (27) and `test-gpu-runtime-check.sh` (82) hold it; recipes `onnx-ep-amdgpu.*` and
  `gpu-runtime.plugin-ep-*` bite.

## 2026-11-07 — CUDA compute capability 7.5 joins the build (CON217)

- Owner decision: `CUDA_ARCHITECTURES` is `75;86;87;89;120`, so T4 and RTX 20xx cards get a cubin from ONNX Runtime
  and OpenCV instead of `cudaErrorNoKernelImageForDevice`. Moved together, as AGENTS.md requires: the pin, the
  Windows canonical-value and resolver suites, `test-version-forwarding.sh`, the mutation recipe, the ORT and
  OpenCV fallbacks, the media-builder ARG and the PowerShell default, and the pages that quote the set. The next
  nvidia chain compiles every CUDA kernel five times instead of four.
- CON169: the owner keeps one pipeline per arch opt-in until a run has reclaimed disk under pressure.

## 2026-11-07 — one pipeline per arch ran on a chain

- CON169: `CROSS_ARCH_PIPELINE=1` ran the default chain's media and android stages for amd64, arm64 and riscv64
  as three lanes; amd64 started its android stage while the other two were still in media, nothing was removed
  under a running build, and the chain passed in 2 h 06 min. The cold media stages (the versions.env merge
  re-keyed them) measured ONNX Runtime at 98-99 % sccache hits and `-j3` per arch, IREE's host LLVM at 24 min on
  arm64 with riscv64 reusing it, a peak of 34 compiler processes and 26 GB of free memory: CON165 and CON168 close.
  The mode stays opt-in until the owner decides its default.

## 2026-11-07 — the asset mirror answers from the build host

- CON153: with the keys installed, the chain's download helper served a pinned asset from the Garage bucket on the
  first try, and the running chain passes the `asset_mirror` secret to every stage build. The three pinned
  sccache 0.19.0 Linux tarballs are mirrored by hand (`fill-asset-mirror.sh --apply --url … --sha …`), since the
  2026-10-27 fill predates that pin. The in-RUN `asset-mirror| hit` line waits for a cold download.

## 2026-11-07 — two ONNX Runtime PRs prepared for the MIGraphX EP

- `linux/upstream/` is the Linux lane's index of prepared upstream submissions, as `windows/upstream/` is the
  Windows lane's. First entries: the MIGraphX EP fix that stages a strided partition output and makes it dense
  through a cached one-op `contiguous` program (with a unit test; the mechanism proved standalone on gfx1201 by
  `proof.cc`), and the one-line `GridSample` addition to the EP's op list. Neither is filed: AMD declared the
  built-in EP unmaintained (onnxruntime#32571), MIGraphX fixed the root cause (AMDMIGraphX#5345, `standardize_outputs`),
  and AMD's plugin EP sets that option, refuses a non-standard output otherwise and lists every op MIGraphX parses.
  CON225 closes; CON231 moves the Linux rocm variant to the plugin EP once a ROCm carries #5345. The two
  directories were removed the same day at the owner's request (the patches stay in git at 2a819d85);
  `linux/upstream/README.md` keeps the reasons.

## 2026-11-07 — between runs the disk guard spends the image lever first

- Owner decision: `_chain_runtime_lane_disk_gate` and `_chain_stage_disk_guard` remove dangling images and the
  stage tags the run does not need BEFORE they trim cache exports, restart buildkitd for stale records or prune
  the buildkit store; the image lever costs no rebuild time and freed 363G on 2026-11-06. The in-stage sampler
  is unchanged. `test-chain-lifecycle.sh` pins both orders (`disk-guard.lane-images-first`,
  `disk-guard.stage-images-first`); [build-cache-tiers.md § 3.2.2](docs/build-cache-tiers.md#322-the-image-store-lever-disk3).

## 2026-11-07 — the Linux AMD packages pass on the RX 9070 XT; comgr keys its cache on `TMPDIR`

- CON224 item 1 and CON225: on the packages rebuilt on the patched `:latest-rocm`, OxidANT, AccelerANTgine,
  OrchestrANT and OmniAccelerANT pass `compare_detector_parity.py` on MIGraphX. OmniAccelerANT's AppImage lane
  first hit its 180 s launch timeout: comgr keys its kernel cache on `TMPDIR`, which that lane randomizes, so
  every AppImage run compiles the detector's kernels again (370 s cold, 84 s warm). OmniAccelerANT 179d532 gives
  the launch 900 s (`PROFILE_GPU_TIMEOUT`); [failure-modes.md](docs/failure-modes.md#an-appimage-gpu-profile-times-out-while-the-deb-passes).
- The build host's asset-mirror keys are installed (`set-asset-mirror.sh --check` green); CON153's proof comes
  with the next chain.

## 2026-11-07 — the CUDA cache probe runs again and proves a write

- `Test-CudaCache.ps1` and `Test-Rdna4LayerLock.ps1` computed the repo root one level short and
  stopped at `Import-Module` (`windows\windows\scripts\modules`). `Diagnostics.ModulePaths.Tests.ps1`
  evaluates every diagnostic script's repo root and module import, with two mutations.
- The probe's nonce sat in a comment, which preprocessing strips from sccache's key, so a warm
  cache hit twice; sccache 0.19 also prints no write count. The nonce is now code, and the probe
  requires a miss, then a hit (`Diagnostics.CudaCacheProbe.Tests.ps1`, two mutations).
  It passed on `bk-windows-toolchain-nvidia`: 4 misses, then 4 hits (CON229).

## 2026-11-06 — IREE builds outside the 20 GB RUN scratch

- The amd64 media-tvm stage failed with `No space left on device` in IREE's compiler wheel while
  the host had 65 GB free: every Windows RUN gets a sandbox of about 20 GB, and IREE with LLVM
  in-tree left 0.3 GB. Its build tree now lives on the RUN's `iree-build-winamd64` cache mount at
  `C:\iree-build`, emptied before configure and after the wheels; a checkout run keeps the old tree.
  Each wheel logs the free space it starts with. `SourceBuild.IreeScratch.Tests.ps1` and six
  mutations hold the path on both sides, the resolver and both resets.

## 2026-11-06 — develop is green again after the Windows image fixes

- The push of `b2b906d8` turned Linux preflight, eight mutation shards and the Windows patch-drift
  job red (#234, #235). The Windows suites behind the new recipes failed on Linux pwsh, where CI
  proves them: the meson provenance case and the MSVC notice suite now use separators and an
  interpreter every host has, and the cases that need Windows (cmd.exe, VsDevCmd, the twin builds)
  moved to `TorchApp.SdistCompilerVs.Tests.ps1`, leaving the recipes on `SourceBuild.IreeTwin.Tests.ps1`.
- `LIBVPX_MESON_SHA256`, `DIRECTML_NUPKG_SHA256` and `LIBVPX_VERSION` are classified in
  `bump_versions.py`; `genai-guidance-smoke.py` passes ty. New duplication was refactored away rather
  than budgeted: `Get-BinDllProvenanceEntry` (OpenSSL and the MSVC runtime), `Add-IreeNinjaTuFlag`,
  and `WindowsPythonApp.Common` re-exporting the notice API. Two allowlist rows became stale and left.
- The drift check maps `002-libvpx-clangcl-simd-flags.patch` to the libvpx meson port at
  `LIBVPX_MESON_COMMIT`, which the wrap applies it to, instead of GStreamer's tree.
- The libvpx patch's repo now lives in the drift check's one repo map (`Patches`), not a second table
  whose parameter duplicated another suite's signature; the TensorRT and MSVC-notice recipe families
  are declared in `gate-proofs.allow`.
- `wsl-quality.sh check` hands the suites one absolute interpreter path: 108 of them run
  `"${PREFLIGHT_PYTHON}"` quoted, so the multi-word `uv run ... python` exited 127 in each.
- Still red until `:winarm64` is published again (#236): the device gate runs the published bundle,
  which predates libvpx (`no element "vp8enc"`) and the onnxinference wide-path fix (0xC0000005).

## 2026-11-06 — Windows packages carry the MSVC runtime's notice

- A ZIP, MSIX or MSI that carries the VC++ runtime ships `licenses/msvc-runtime/Redist.txt` and a
  `README.txt` with the end-user notice and the learn.microsoft.com link; the wording is a draft for
  review. CPack installs both and adds the notice to the WiX licence page; `New-PortableBundle` and
  the Python app bundle stage them; `Assert-PackageMsvcRuntimeNotice` fails a finished package with
  the runtime and without the notice (`WindowsMsvcRuntimeNotice.Common.psm1`, CON228;
  `Msvc.RuntimeNotice.Tests.ps1`, `test-cmake-windows-arch.sh`, four `msvc-notice` recipes).

## 2026-11-06 — ORT's LLM kernels compile through sccache on Windows

- `onnxruntime_providers_cuda_llm`, the last CUDA target on bare nvcc, keeps the sccache launcher:
  `Get-OrtPtxLauncherExemptArg` and `sccache-ptx-exempt.cmake` are gone. The hub's sccache build
  carries mozilla/sccache#2809, and in the nvidia toolchain image it compiled `sm_86` plus PTX-only
  `compute_120` without `Missing "cubin" file output`, warm 5 of 5 from the cache.
  `SourceBuild.OrtCudaLauncher.Tests.ps1` refuses an exemption's return
  (`lib.ort-cuda-launcher-no-exemption`, `sccache.ptx-only-pass-runs-uncached`). The chain proof
  (provider link from hits, smoke gate, `Test-Cache.ps1`) comes with the next nvidia chain.
- v0.19.0 is exactly `SCCACHE_SOURCE_REV` and carries #2876; #2809 merged on 2026-11-02 and is in no
  release yet, so the hub's build stays (`shared/upstream/sccache/README.md`).

## 2026-11-06 — The Windows nvidia lane downloads TensorRT and fails without it

- `Install-Tensorrt.ps1` guessed the pre-11.x file names, which 404 for TensorRT 11, so every
  `-Gpu` image shipped without TensorRT while the log read "Continuing WITHOUT TensorRT". It now
  downloads `TensorRT-Enterprise-<ver>-Windows-amd64-cuda-<cuda>-Release-external.zip` from
  `developer.nvidia.com/downloads/compute/machine-learning/tensorrt/`, for the image's CUDA line
  only, and grades it with the unchanged `TENSORRT_ZIP_SHA256`: the 11.4.0.106 zip fetched on the
  host on 2026-11-06 hashed to the pin. A staged zip in `windows/downloads/` still wins.
- No TensorRT now fails the nvidia lane (owner, 2026-11-06): the installer and `Set-TensorrtTree.ps1`
  throw, and the smoke gate fails an `-ExpectGpu` image with an empty `TENSORRT_ROOT`
  (`host.trt-url-tensorrt11-scheme`, `host.trt-missing-throws`, `smoke.trt-required-expect-gpu`).
  The runtime-only rule is unchanged. Windows arm64 TensorRT stays off as an owner decision (CON230).
## 2026-11-06 — QNN's Hexagon skeletons are DSP payload, and NVIDIA's gst plugins are recorded

- The first green arm64 nvidia package stage reached the runtime-image smoke, which failed on 107 QDSP6 objects
  under `onnxruntime-cpu/lib/hexagon-v*/`: the HTP backend's skeletons, run by the DSP, never by the image's
  loader. The tree-arch scanner skips those dirs and names machine 164 `QDSP6` (`tree-arch.hexagon-skels-are-dsp-payload`,
  `tree-arch.hexagon-filter-is-narrow`). The five `libgstnv*.so` plugins that need the driver's `libcuda.so.1` are
  recorded per arch in `_PARITY_GST_KNOWN_BROKEN` (`runtime-smoke.nvidia-gst-plugins-recorded`,
  [failure-modes.md](docs/failure-modes.md#tree-arch-usrlocallibonnxruntime-cpu-ships-107-em164-objects-on-arm64)).

## 2026-11-06 — A required `rustup … add` is retried under qemu-user

- The arm64 package stage of the nvidia chain died in `rustup component add rustfmt` with a qemu-user SIGABRT
  mid-download, a step the three runs before had passed. `rustup_required` in `install-rust.sh` runs each of the
  four required adds up to three times and fails the installer after the third (`rust.rustup-required-retries`,
  `rust.rustup-required-propagates`,
  [failure-modes.md](docs/failure-modes.md#rustup-component-add-aborts-under-qemu-user)).

## 2026-11-06 — The SBSA RUNPATH starts with `$ORIGIN`, and the CUDA SONAMEs come from the host toolkit too

- The fourth arm64 package stage left 15 closure rows with every element registering: nine were
  `libnvdsgst_deepstream_bins.so` NEEDing its sibling plugins in `gst-plugins/`, out of reach of a RUNPATH that
  names `lib/` alone, and six were still bare `libcufft.so`, `libcublas.so`, `libnppial.so` and `libnppist.so`,
  because the staged arm64 runtime holds only cudart's dev link. `ds_sbsa_runpaths` now writes
  `RUNPATH=$ORIGIN:…/lib`, as the amd64 Makefiles do, and `ds_sbsa_cuda_soname` reads the SONAME from the target
  view or the host toolkit of the same version (`deepstream.sbsa-origin-runpath`, `deepstream.sbsa-host-cuda-sonames`,
  [failure-modes.md](docs/failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).

## 2026-11-06 — The SBSA bufferpool is staged under its SONAME, and every bare CUDA NEEDED is rewritten

- The third arm64 package stage left 24 closure rows and four elements that "do not register" from
  `/nonexistent`: the SBSA container ships `libnvdsbufferpool.so` bare, and nothing that NEEDs
  `libnvdsbufferpool.so.1.0.0` resolved it; `libcublas.so`, `libnppial.so` and `libnppist.so` were NEEDed
  bare like `libcufft.so`; and the UCX, Maxine and bare-bufferpool excuses were STALE on a `.deb` without those
  files. `ds_stage_sbsa_libs` copies the bufferpool under its SONAME with the bare link, `ds_sbsa_runpaths`
  rewrites every bare NEEDED to the target CUDA dev link's SONAME, and the amd64-only excuses are gated per arch
  (`deepstream.sbsa-bufferpool-soname`, `deepstream.sbsa-bare-cuda-needs`, `deepstream.sbsa-amd64-excuses`,
  [failure-modes.md](docs/failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).

## 2026-11-06 — The SBSA DeepStream files get RUNPATHs and link TensorRT 10

- The second arm64 package stage failed DeepStream's soname closure (105 rows) and found `nvinfer` linked
  `libnvinfer.so.11`. The Jetson `.deb`'s files carry no RUNPATH (L4T's `ld.so.conf` has the tegra dir) and NEED a
  bare `libcufft.so`; `ds_sbsa_runpaths` now sets `RUNPATH=…/deepstream-9.1/lib` on every file without one and
  rewrites that NEEDED to `libcufft.so.12`, as the amd64 `.deb` carries. The TensorRT 10 SDK's `-L` precedes the
  sysroot flags on the cross compiler word, and the three VPI consumers are excused on arm64 only
  (`deepstream.sbsa-trt-sdk-before-sysflags`, `deepstream.sbsa-runpaths-set`, `deepstream.sbsa-vpi-excused`,
  [failure-modes.md](docs/failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).

## 2026-11-05 — The arm64 package stage links DeepStream into the multiarch plugin dir

- The first arm64 package stage of the nvidia chain died on `no GStreamer plugin directory at
  /opt/gstreamer/lib/aarch64-linux-gnu/gstreamer-1.0`: `ds_stage_runtime` built the path from the host's multiarch
  triplet, but the cross-built GStreamer installs into `lib/` with no triplet directory. The link now lands in
  `lib/multiarch/gstreamer-1.0`, the directory `GST_PLUGIN_PATH` names on every arch
  (`deepstream.plugin-dir-multiarch-link`,
  [failure-modes.md](docs/failure-modes.md#no-gstreamer-plugin-directory-at-optgstreamerlibaarch64-linux-gnugstreamer-10)).

## 2026-11-05 — Cerbero's curl gets a stall timeout

- The amd64 android stage hung 80 minutes in `mpg123 -> fetch`: a sourceforge mirror stopped sending after 225 KB and
  cerbero's curl, which has a connect timeout but no stall timeout, waited on the open socket. The fetch retry now
  arms `speed-time = 60` / `speed-limit = 1024` through a `.curlrc` under `CERBERO_HOME` (`CURL_HOME`), so a stalled
  transfer fails and cerbero's retry and mirror take over (`lib.cerbero-curl-stall-timeout`,
  [failure-modes.md](docs/failure-modes.md#cerbero-a-fetch-hangs-for-hours-on-a-stalled-mirror)).

## 2026-11-05 — The DeepStream build hits sccache

- Both arches' DeepStream steps reported `156 requests, 0 hits, 109 misses` on every chain: the sources were cloned
  into a `mktemp -d` tree, and sccache hashes the preprocessed source whose line markers carry that path. The build
  tree is now `${TMPDIR:-/tmp}/deepstream-build`, emptied first (`deepstream.build-dir-stable`,
  [build-cache-tiers.md § 7](docs/build-cache-tiers.md#7-do-not-repeat-list)).

## 2026-11-05 — sccache gives way when the shared disk runs short

- The VPS disk had 19 GB free with Nextcloud and its backups on it, and an hourly check at a 100 GiB cap left too little
  margin. The cap is 60 GiB, checked every 10 minutes, and `sccache-s3-evict` now also shrinks the bucket when the disk
  has under 25 GiB free (`MIN_FREE_GB`), down to `FLOOR_GB`, without deleting again for space a resync is still freeing.
  A 70 GiB bucket quota and 5 GiB of ext4 reserved blocks hold the rest; nothing here limits Nextcloud
  ([size cap](linux/sccache-s3/README.md#4-the-size-cap)). `test-sccache-evict.sh` covers it.

## 2026-11-05 — The sccache size cap deletes again

- `sccache-s3-evict` failed on every run over the cap and deleted nothing: its `awk` left early, `sort` died of
  SIGPIPE, and `pipefail` ended the script before `s5cmd run`. It first bit on 2026-11-04, when the bucket passed
  100 GiB for the first time, and the bucket kept growing on the disk it shares with Nextcloud. `awk` now reads to the
  end. The live server carries the fix and cut the bucket from 104.0 to 90.1 GiB. `test-sccache-evict.sh` runs the
  script's real text against stubs, and `lib.sccache-evict-reads-whole-list` proves it
  ([failure-modes.md](docs/failure-modes.md#sccache-evictservice-fails-with-sort-write-failed-standard-output-broken-pipe)).
## 2026-11-05 — The SBSA DeepStream build finds the target's multiarch headers

- The first arm64 media builds of the nvidia chain (CON42 phase 7) died in civetweb on `zconf.h`: the cross GCC's
  sysroot is `/usr/aarch64-linux-gnu`, so apt's `:arm64` headers under `/usr/include` are invisible to it, and
  DeepStream's Makefile builds carry no cross file. `ds_cross_setup` now appends the `-idirafter` pair cross-meson
  uses plus `-L/usr/lib/<triplet>` to the cross compiler strings (a first attempt on `CPATH` named the wrong dir),
  `zlib1g-dev` is a named build package, a failed civetweb prints its error lines, the component Makefiles'
  `TARGET_DEVICE=aarch64` branches (install into and `-L` L4T's `/usr/lib/<triplet>/tegra`) get an explicit
  `LIB_INSTALL_DIR` and a build-time link to DeepStream's lib dir (`deepstream.sbsa-lib-install-dir`), the cross
  components get the CUDA view's `lib64` and `lib64/stubs` as explicit `-L` (a cross GCC ignores `LIBRARY_PATH`,
  so `nvll_osd` could not find `-lcuda`), `gst-dsexample`'s sub-make gets `$(CC)` for its literal `gcc`
  (`deepstream.dsexample-literal-gcc-patched`), `libgstnvdsseimeta.so.1.0.0` is the fourth staged SBSA copy
  (nvmultistream2 links it; no arm64 `.deb` ships it; the SBSA container's Tegra dir does), and
  `deepstream.cross-multiarch-headers` proves the include pair
  ([failure-modes.md](docs/failure-modes.md#zconfh-no-such-file-or-directory-in-civetweb-under-the-sbsa-deepstream-build)).

## 2026-11-05 — The ARM SDK pins move with the Renovate call; QNN on arm64 needs no staged zip

- Android NDK r30 (`30.0.16248370`), LiteCore v1.2.0 (the archive LiteRT main builds against) and
  QAIRT 2.51.1.261002, the public "Qualcomm AI Runtime Community" zip, are pinned in `versions.env`.
  The LiteCore pin left `build-android.sh` for `LITECORE_VERSION`/`LITECORE_SHA256`, forwarded by
  `Dockerfile.android`, and the archive comes through the asset mirror (CON227 done).
- `resolve_qnn_sdk` fetches the pinned Community zip into the `qnn-sdk-<arch>` cache mount every
  QNN-resolving media RUN now carries (GenAI's verify RUN too, and the ORT gate grades that root by
  default), so the arm64 image builds the ORT QNN EP without a hand-staged
  zip; a zip in `linux/qnn-sdk/` overrides it and must match the pin, `QNN_SDK_SOURCE=drop` keeps
  the old contract. The Community licence allows object-code distribution as part of a product only;
  the image ships the backend `.so` files as before ([qnn-linux.md](docs/qnn-linux.md#staging)).
- The Windows lane does the same: `Resolve-QnnSdk` fetches the pinned Community zip (its `lib\aarch64-windows-msvc`)
  into the `qnn-sdk-winamd64` cache mount of the four QNN RUNs of `Dockerfile.media-builder` when `windows/qnn-sdk`
  holds no zip; one pin (`QNN_SDK_VERSION`, `QNN_SDK_ZIP_SHA256`) serves both lanes, so the Linux-only key is gone.
  `SourceBuild.QnnCommunityZip.Tests.ps1` covers the fetched branch with a handed-in fetch; the Windows lane proves it.
- `bump_versions.py` gained `spec_android_ndk`, `spec_litecore` and `spec_qnn_sdk` (the vendors list
  nothing, so LiteRT main is the oracle for the two SDKs), and `renovate-local.sh` runs the sweep in
  the same call: `--check` on report, `--write` plus `sync_versions.py --write` on apply, `--no-bump`
  opts out ([the sweep rides the Renovate call](docs/dependency-updates.md#the-sweep-rides-the-renovate-call)).
  Suites: `test-qnn-community-zip.sh`, `test-litecore-pin.sh`, `test-renovate-pin-sweep.sh`, three
  offline spec cases; eight recipes bite.

## 2026-11-05 — The nvidia lanes stop erasing each other's apt lists

- The rebuild's nvidia chain (amd64 + arm64 SBSA, `--parallel-archs`) failed its arm64 gpu stage with
  `Unable to locate package cuda-cross-sbsa-13-4` right after enabling that repo: both lanes shared the
  `apt-lib-amd64` cache mount, and the amd64 lane's `apt-get update` deleted the cross-linux-sbsa lists.
  `Dockerfile.nvidia` keys its apt caches by the target too, as every other Dockerfile does, and because
  BuildKit's cache key ignores a cache mount's id (the re-keyed repo RUN stayed `CACHED`, the new mount was
  empty), `install-cuda-stack.sh` refreshes the lists before its first install. `test-cuda-cross-sbsa.sh`
  refuses both regressions; `cuda-stack.apt-lists-keyed-by-target` and `cuda-stack.installer-refreshes-apt-lists` prove it
  ([failure-modes.md](docs/failure-modes.md#the-cross-sbsa-packages-vanish-between-the-repo-run-and-the-install)).
  The default chain (three arches) and the rocm chain passed in the same sequence.
- The push before it (8dcc7d6f) left `develop` red (issue 227): `GENAI_TINY_MODEL_PY` is registered as the
  in-container name of the tiny-model source, not an operator knob; the two in-container command generators
  (`smoke_app_wheel_command`, `smoke_python_probe_command`) live in `smoke-common.sh` beside the payloads they wrap,
  so `smoke-runtime-image.sh` stays under its frozen size; and `lib.genai-smoke-tiny-missing-fails` names one edit
  again now that the wheel smoke reads the generator the same way the GenAI probe does.

## 2026-11-05 — The runtime smoke hands OrchestrANT's wheel check its GenAI model

- OrchestrANT's `orchestrant.smoke` (2026-11-01) decodes the model `ORCHESTRANT_SMOKE_GENAI_MODEL` names and only
  warns without one, so the rebuild's amd64 runtime-image smoke counted 14 of 15 and failed its floor.
  `check_app_wheel_smoke` now writes `lib/tiny-genai-model.py`'s model in-container and names it
  ([the app-wheel floor](docs/gen1-riscv64-genai.md#the-app-wheel-floor)); `boot.genai-model-named-for-wheel-smoke` pins it.
- The arm64 package stage's `rustup target add aarch64-linux-android` died once under QEMU 10.2.3 with signal 6
  (abort, no message) while the host pushed amd64 and built riscv64; the same command in a plain arm64 container
  on that host ran twice without fault, and the rerun passed. Recorded, not changed.
