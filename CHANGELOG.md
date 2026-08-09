# Changelog

## 2026-08-09 - LLM stack: GPU mode override + Qwen3-Coder deploy

- **NEW `linux/llm-stack/docker-compose.gpu.yml`** — a compose overlay that
  gives the Ollama service all NVIDIA GPUs
  (`deploy.resources.reservations.devices`, driver `nvidia`) and raises the
  default context via `OLLAMA_CONTEXT_LENGTH`. The base `docker-compose.yml`
  stays CPU-only; GPU hosts run
  `docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d` after
  installing the `nvidia-container-toolkit` (install commands in the llm-stack
  README). `OLLAMA_KV_CACHE_TYPE=q8_0` and flash attention remain the defaults.
- **Deployed `qwen3-coder:30b` (30.5B A3B MoE, Q4_K_M, ~18 GB) on a 2× NVIDIA
  host (12 GB + 16 GB)**: 100 % GPU placement (9.9 GB / 12.4 GB per card),
  warm decode ~137 tok/s, ~47 s cold load, context tuned to 64K. Perf measured
  via the `/api/generate` metrics.
- **Docs:** `linux/llm-stack/README.md` gained a GPU-mode section (toolkit
  install + override usage + `ollama ps` GPU check) and a VRAM/context sizing
  table (~104 KB/token q8_0 KV ⇒ 28 GB total = ~64K cap; 256K needs >45 GB).
  The "CPU-only inference" architecture note is now "CPU-only by default, GPU
  optional". Repo `README.md` and `AGENTS.md` Quick Reference now point to the
  LLM stack (previously undiscoverable from either).

## 2026-08-09 (night) - Windows lane on a 25H2 host: platform COPY regression found; sccache source build proven host-side

The base->final GPU verification run that motivated the sccache source build hit
a wall that turned out to be the HOST OS, not the repo.

- **Windows 11 build 26200 (25H2 line) `COPY`-into-layer failure — isolated to a
  HOST-SPECIFIC damaged-install class, NOT a blanket build break (corrected
  same day).** buildkitd: `failed to reimport snapshot: hcsshim::ActivateLayer
  0x20` ("file used by another process"), deterministic across fresh chain-IDs,
  survives `-NoCache`, service restarts, vmwp kills, Defender exclusions, a
  full store reset AND a reboot. docker-classic fallback: `mkdir
  \\?\Volume{<GUID>}\C:.` invalid directory name, under process AND Hyper-V
  isolation. A minimal 3-layer probe isolates it: `FROM servercore` + `RUN`
  commits fine, the first `COPY` layer never does. NOT Defender, not a poisoned
  snapshot, not storage. However, 26200 is a retail-serviced line (the same
  cumulative KBs serve 26200.xxxx and 26100.xxxx, e.g. KB5094126) and a
  same-build 26200 machine was observed building fine - and the affected box's
  own `Get-WindowsOptionalFeature` errors "Klasse nicht registriert" (broken
  DISM COM API = damaged Windows component store, the same class as the
  documented "public 26200 ISO missing identity components" problem). Repair
  path documented: `DISM /Online /Cleanup-Image /RestoreHealth` + `sfc
  /scannow`, re-test the 3-layer probe, reinstall from a good ISO if needed.
  Docs updated: `docs/windows-host-setup.md` OS gate + AGENTS.md Common Failure
  Modes carry the corrected row. The Linux cross lane and all repo gates are
  unaffected.
- **sccache source build verified HOST-SIDE** (the part that needs no image):
  the pinned `SCCACHE_GIT_REV = e9b15a3` is confirmed from upstream to BE the
  mozilla/sccache#2722 merge ("Fix nvcc dryrun parsing for CUDA 13.3", carries
  `test_group_nvcc_subcommands_with_simt_only_cicc_input`); the EXACT command
  `setup-rust-toolchain.ps1` runs (`cargo install sccache --locked --git
  https://github.com/mozilla/sccache --rev <rev>`) compiles, links and installs
  cleanly (exit 0, 3m25s, sccache.exe in CARGO_BIN, `--version` = 0.17.0 exactly
  as the commit documented). The wiring itself remains covered by the 412-test /
  0-lint gates (verify-toolchain CARGO_BIN assert, CMAKE_CUDA_COMPILER_LAUNCHER).
  The one thing still pending is a real ONNX CUDA kernel cache-hit in an image
  build - which needs a supporting (non-25H2) host.
- New-host bring-up (setup-new-host.ps1 + verify-host-setup fix + magic-constant
  purge, this morning's entry) proved out on this fresh host: verify-host-setup
  all-green, patched shim deployed and hash-recorded, CNI confs on the live
  subnet, dufs L2 up with logon task. Host-side probe toolchain (rustup gnu via
  Strawberry's bundled mingw linker) installed for the verification above -
  throwaway, not part of any image.

## 2026-08-09 (late) - Windows lane: one-script new-host bring-up + magic-constant purge + verify crash fix

Verified live while bringing up a brand-new host (this one) for the sccache
source-build verification run; every fix below is what a fresh Stevedore box
actually trips over.

- **NEW `windows/scripts/setup-new-host.ps1`** - the scriptable half of
  `docs/windows-host-setup.md` Phases A5+C as ONE elevated, idempotent run
  (`-ReportOnly` safe, refuses while a build is live): authors the CNI
  `.conflist` from the LIVE `vEthernet (nat)` subnet (derived network/prefix+GW
  at runtime - **the magic subnet literals are gone from the docs**), then
  orchestrates the canonical per-concern scripts (apply-containerd-config ->
  `.conf` derive + debug flags + teardown env + Defender; apply-buildkitd-gcpolicy
  + the `BUILDKIT_STEP_LOG_*` env; deploy-shim-patch - BUILDING the 45min/100min
  fixed-constant shim from hcsshim source when no `-ShimPath` is given, Go via
  scoop; dufs install/start/ONLOGON-task/machine endpoint env).
  Every sub-script is called with a HASHTABLE splat - the first draft used
  array splats and hit the documented position-binding trap in `-ReportOnly`
  (`-ReportOnly` arriving as `$ServiceName`), exactly the AGENTS array-splat rule.
- **`verify-host-setup.ps1` line-212 crash fixed**: `(Get-ItemProperty ...).Environment`
  on a service whose `Environment` value does not exist threw PropertyNotFound,
  which under StrictMode surfaced as an unset-variable error and CRASHED the
  script mid-run on the common drifted host - silently skipping the teardown-env
  and debug-flag checks and under-counting the verdict (reported 2 warnings
  instead of 3). Registry values that do not exist now degrade to honest WARNs
  (`.PSObject.Properties.Name -contains` reader), matching the Defender check's
  degrade-to-UNKNOWN contract.
- **Docs purge of stale example values**: `docs/windows-host-setup.md` A5 and
  `docs/windows-builds.md` section Getting it going no longer hand out the
  reference host's `172.31.32.0/20` subnet as copy-paste gospel - both now say
  "derive" and point at `setup-new-host.ps1`; README's fresh-machine pointer
  gains the one-run path.

## 2026-08-09 (early) — Linux lane: validator split + a locale bug the split's own probe caught

- **validate_compiler_for_target decomposed** (complexity item 9): the
  108-line monolith is now five independently-callable checks
  (_cc_check_{dumpmachine,binary_elf,object,loader,qemu_exec}) with explicit
  args — deliberately NOT the _VCS_* implicit-global convention.
- **Locale bug found by the split's verification probe**: every readelf
  parser in the tree matched the ENGLISH "Machine:"/"interpreter:" strings —
  on a non-C-locale host (this one is de_DE) readelf localizes ("Maschine:")
  and the ELF-machine checks failed spuriously; inside containers (LC=C) the
  bug was invisible but latent. All parsed `readelf -h/-l/-d` calls across 7
  files now run under LC_ALL=C. Host probe: 6/6 PASS.

## 2026-08-08 (night) — Linux lane: complexity F-G + TVM shallow/commit-pin clone

- **setup-package-image's 102-line dual-purpose function split** (audit F-G):
  select_dev_packages / install_dev_packages / clang_embedded_deb_version
  (the previously function-nested, globally-leaking `_clang_ver`) /
  pin_clang_alternatives — the old name remains as its caller's 4-line
  sequence. All load-bearing comments preserved.
- **TVM clone hardened**: shallow `--depth 1 --branch <tag>` instead of the
  old bare recursive clone (which pulled the whole default branch + all
  submodules unpinned before ever checking out), plus a `TVM_COMMIT` opt-in
  pin (commit beats tag; v0.25.0's commit recorded in versions.env) —
  completing the `*_COMMIT` convention for the second compiler-class clone.
- Repo hygiene sweep came back clean: no build artifacts tracked,
  .gitignore already covers resource-monitor outputs and out/.

## 2026-08-08 (night) — Linux lane: supply-chain round 3 — build executors frozen

- **Round-3 completion**: Vulkan SDK and GStreamer-Android-universal tarball
  sha pins landed once their streamed hashes finished — the audit's entire
  class-(d) (completely unverified fetch) list is now EMPTY.

- **The ~20-site unpinned `uv pip install` surface is closed for every
  binary-shaping package**: meson, ninja, cython, pybind11, setuptools,
  wheel, scikit-build-core, setuptools-scm — and auditwheel/patchelf, which
  REWRITE the shipped wheels' ELF headers — are pinned via a new
  `PY_*_VERSION` family in versions.env (frozen to what builds were already
  resolving; the torch wheelhouse keeps its documented setuptools<82 ceiling
  via a dedicated pin). Pure-python data deps stay floating by design.
  Wired at 8 install sites with the inline-default safety-net convention.
- **abseil headers now fetch the immutable `/archive/<commit>.tar.gz`** form,
  sha-verified (ABSEIL_COMMIT + ABSEIL_TARBALL_SHA256) — the tag-tarball form
  is movable and not byte-stable.
- **verify-parity.sh main() decomposed** (complexity F-F, zero blast radius):
  five responsibilities → five functions matching the file's own check_*
  shape; behavior verified (--help, missing-args, exit codes).
- AGENTS.md: supply-chain discipline codified in Linux Build Rules; a
  16.1.0/16.2.0 GCC version drift in the rules text fixed.

## 2026-08-08 (night) — Linux lane: supply-chain hardening round 2 — pins for every trust anchor

All computed from upstream (streamed sha256, gzip/manifest-verified) and
wired with the warn-if-unset pattern:

- **CUDA apt keyring deb pinned** (x86_64 + sbsa) — the apt trust anchor for
  the whole NVIDIA lane was fetched with no hash; **ROCm apt signing key
  pinned** (was TOFU via wget|gpg); **Android commandlinetools zip pinned**
  (sdkmanager bootstraps the NDK cross compiler from it); **Flutter SDK
  pinned** with Google's official sha256 from releases_linux.json;
  **rustup/uv installer pins populated** (the fail-closed mechanism existed
  with EMPTY keys — both effectively ran unverified remote scripts as root).
- **TensorFlow C SDK: the pin was fiction.** Upstream stopped publishing
  libtensorflow C builds after **2.18.0 (x86_64 only)** — the pinned 2.21.0
  never existed as an artifact, the GitHub URL has 404'd since 2.19, and a
  `2>/dev/null` swallowed it: ffmpeg silently shipped WITHOUT its TF DNN
  backend while versions.env claimed otherwise. Now: 2.18.0 from the GCS
  mirror, sha-pinned, aarch64 says loudly that no upstream build exists, and
  the do-not-bump constraint is documented in versions.env.

## 2026-08-08 (night) — Linux lane: supply-chain round 1 + safe complexity refactors

(See commit 68bc11e: TLS redirect/wget hardening, CPython fail-closed,
NodeSource/npmjs pipe-to-shell removal, npm ci lockfile-exact, verified
Kitware/LLVM host-repo helpers, cerbero tag pinning, meson wrap-update
removal; lib/ prelude drift + clang-extractor + cross-fallback parity with
two new test suites.)

## 2026-08-08 (night) — Linux lane: smoke-depth round (audit round 3, lens 2)

A capability×depth audit of every smoke layer found the deepest ML coverage
living in an EXTERNAL repo's app smoke — torch, torchvision, onnxruntime
inference and OpenCV imencode had zero in-repo functional coverage, and
several capabilities had none anywhere. Presence checks upgraded to real
execution (all device-less, no network, seconds each):

- **GStreamer mandatory plugins** (libav/opencv/onnx/tflite) now GATE in the
  runtime smoke on the real target arch under qemu, and in smoke-media's
  native branch — a present-but-unloadable plugin (the observed
  webrtcbin2/gtk4 class) was previously only a WARN-count. Plus a data
  roundtrip (videoconvert!jpegenc → 4 real JPEG frames) beyond the
  registry-only fakesink pipeline.
- **Python stdlib battery** (ssl/sqlite3/lzma/bz2/zlib/hashlib/ctypes,
  exercised not just imported) in smoke-toolchain — the textbook from-source
  CPython failure; `_sqlite3` was checked NOWHERE in linux/ and joins
  build_python.sh's staging warn-list too.
- **torch forward+backward, torchvision nms/._C + v2.Resize, and a real
  onnxruntime InferenceSession** (model generated in-process via
  torch.onnx.export — no fabricated bytes) in smoke-torch-venv, gated
  STV_COMPUTE=1 (default on).
- **ffmpeg codec depth**: buildconf-vs-registration consistency for
  x265/dav1d/svtav1/vpx/opus (build-ffmpeg probe-gates --enable-*, so a
  silently-missed probe DROPS a codec while the build stays green) + real
  encode/decode roundtrips for libx265/libvpx-vp9 — all inside the
  binary-executes guard.
- **Cross-compiler loader assertion**: the emitted ELF's PT_INTERP must
  request the TARGET's dynamic loader (wrong-sysroot links succeed and only
  die on target); opportunistic static-binary qemu-run (exit-42 proof) when
  qemu-user is present.
- **Rust**: version pinned against RUST_VERSION (the old check asserted
  "rustc" appears in `rustc --version` — could never fail), host
  compile+RUN, and per-target emit-obj (rustup lists targets whose std rlibs
  are missing). **node/npm**: first coverage at all (version pin + JS
  execution) — the LiteRT-web WASM gate silently self-disables without node.
- **LiteRT**: `nm -D` symbol check (TfLiteInterpreterCreate/TfLiteModelCreate)
  — works on foreign-arch ELF, so the cross branch gets it too; a 12-byte
  stub used to pass `[ -f ]`. **nvcc**: device-less __global__ kernel
  compile + the fail-open hole closed (ENABLE_NVIDIA=true with no nvcc now
  fails). **GenAI**: shipped-but-unimportable is now FAIL, absent stays INFO.
  **Vulkan runtime**: real vkEnumerateInstanceVersion call (works with zero
  ICDs; a healthy loader cannot fail it). **Android NDK**: the compile smoke
  its header promised since creation (per-target object + ELF-machine
  assertion; the NDK clang is a host binary, runs on every branch).
- Fail-open holes closed: absent cross-Python staging dir now FAILS for
  requested foreign arches (ran zero checks before); smoke-media's hardcoded
  "torch not installed" INFO replaced with a real venv probe (it was false in
  the package image); smoke-vulkan's `vkvia | head` rc swallow fixed.

## 2026-08-08 (night) — Linux lane: orphan sweep (audit round 3, lens 1)

A dedicated dead-weight audit (things wired to nothing), with every dynamic
script-dispatch mechanism enumerated first so glob/variable-built paths could
not produce false orphans:

- **Real arm64 bug**: `wasm-opt.sh` built the aarch64 binaryen asset name but
  versions.env pinned no `BINARYEN_LINUX_AARCH64_SHA256` — the download died
  "No pinned SHA256" on any arm64 host. Pinned (sha computed from the
  upstream `version_131` tarball, gzip verified).
- **Dead legacy alias** `TVM_VULKAN_KEEP_SDK_LIBS` removed from vulkan.sh
  (sole occurrence repo-wide; the canonical knob is VULKAN_KEEP_SDK_LIBS).
- **Legacy flutter shims** (`setup-flutter-{arm64,x86-64}.sh`, kept for
  external ExternalLib consumers) no longer carry a hardcoded `3.44.8`
  fallback that had already drifted from the 3.44.9 pin — they now require
  the versions.env value they load anyway.
- **Deleted**: `02-toolchain/rust/Build-Linux.sh` (zero references AND a
  duplicate re-implementation of its five cargo_* siblings) and
  `06-packaging/package_archive.sh` (zero references, zero docs; its Windows
  "twin" is equally unreferenced, so no parity obligation).
- **Documented as consumer surface** (shipped into images, invoked by
  external repos, previously invisible): `lib/{ctest-run,docs-build,
  rust-toolchain}.sh` (now in the AGENTS.md + linux-build-basics.md
  inventories alongside their already-documented siblings),
  `02-toolchain/rust/cargo_*`, `02-toolchain/python/ci_*.sh`,
  `01-core/setup-host-deps.sh`.
- `make lint-workflows` target added (preflight ran it; the Makefile only
  exposed lint-dockerfiles).
- Clean bill elsewhere: zero dead Dockerfile ARG/ENVs, zero unreferenced
  patches/data files (verify-patch-integrity already gates patches), zero
  dead Makefile targets/workflow steps.

## 2026-08-08 (night) — Linux lane: audit round 2 leftovers cleared

The verified-but-queued remainder of the four audit reports:

- **Orphan verify branches wired** (Dockerfile.media): `onnxruntime-gpu` runs
  after the GPU EP build (GPU-enabled images had NO gate on those artifacts)
  and `armnn` runs after the arm64 ACL/ArmNN build (a failed build left empty
  /opt/armnn + /opt/acl shipping unexamined). Both branches had existed
  caller-less since creation.
- **`make verify-chain` can now fail**: STALE links are counted and the
  explicit `--verify-chain` path exits 2 when any exist — it used to warn and
  exit 0, an explicit verification that could not fail. The automatic
  partial-run protection (_chain_assert_ancestry, hard-fail) is unchanged.
  Makefile help text updated.
- **verify-parity.sh judges by rc, not sentinel**: `|| echo "FAILED"`
  appended AFTER the captured traceback, so the first-word parse read
  "Traceback" and an ImportError could never increment failures.
- **Runtime Vulkan check three-way**: ctypes.CDLL of the loader does NOT need
  an ICD/GPU — a load failure means the library is missing/broken, and the
  runtime image always ships the Vulkan runtime files. Missing/unloadable is
  now a FAIL; only container-infra errors stay WARN.

## 2026-08-08 (night) — Linux lane: audit round 2, Klasse C — test gaps closed

- **Zero-assertion suites now FAIL**: `t_summary` treats `_T_RUN=0` as a
  failure (a gutted suite used to print "0 assertion(s) passed" and stay
  green), and run-tests.sh aggregates the per-suite counts — the final line
  now reads "N suites, M assertions", so a coverage collapse is visible in
  every log.
- **Four new/extended suites** (7→11 suites, 68→120 assertions):
  - `test-parallelism.sh` — pins mem_capped_jobs' RAM/cores formula, the ≥1
    floor, and the new PARALLEL_JOBS validation (**fix included**: the
    override was emitted unvalidated — `PARALLEL_JOBS=0` went straight into
    `ninja -j0`; now rejected with a warning).
  - `test-cli-parsers.sh` — pins the new central two-arg value guard (**fix
    included** in dispatch_parsed_args: a trailing `--target-arches` or one
    that swallowed the next flag used to assign ""/"--push" silently and fall
    through to CROSS_DEFAULT_ARCHES — building all three arches).
  - `test-stage-defs.sh` — the REAL cross_stage_tag/cross_build_mem_divisor/
    graph-validation (test-disk-guard/test-ancestry stub these; until now no
    test executed the real ones). Also asserts the Klasse-B ENABLE_NVIDIA
    forwarding.
  - `test-smoke-arch-parity.sh` — asserts smoke-common.sh's inline fallback
    maps agree with the canonical platform.sh/arch-mapping.sh for all three
    arches (this file had already caused two silent-skip bugs).
  - Extended: riscv64→RISCV LLVM backend assert (a tempting "consistency
    rename" would break the compiler stage), runtime_artifact_platform/
    _image_ref (wrong-arch artifact COPY class), version-forwarding negative
    asserts (an unset var must NOT become `--build-arg FOO=` overriding the
    Dockerfile default with empty; `# noforward` must hold).
- **IFS bug class killed by construction**: `arch_list_to_words` and
  `smoke_arch_words` now emit NEWLINE-separated words — `for x in $(...)`
  splits under both the default and the strict `IFS=$'\n\t'`, retiring the 16
  latent for-loop sites the audit found (all consumers verified compatible:
  for-loops, `wc -w`, unquoted argv). Parity suite pins the property.
- **Gates that could not fail, now real**: smoke-torch-venv fails when
  `STV_REQUIRE_VENV=1` and /opt/venv is absent (the package wrapper-smoke
  sets it — the venv gate used to SKIP+pass exactly when setup-torch-venv
  failed hardest); the SDK image asserts a non-empty /opt/vulkan and (except
  riscv64) an executable /opt/flutter/bin/flutter (both shipped with ZERO
  verification); smoke-torch-venv reports TVM presence/version per-arch with
  EXP_TVM as opt-in hard pin (Dockerfile.media's comment claimed an
  `import tvm` runtime gate that never existed — comment corrected);
  `cross_stage_validate_graph` (pure, sub-second) now runs in preflight
  (slug `stage-graph`) instead of only at build kickoff.

## 2026-08-08 (night) — Linux lane: audit round 2, Klasse D — convention bugs

- **`USE_CCACHE`/`USE_SCCACHE`/`USE_LLD` now accept both truthiness
  spellings** (0/false/no/off, any case). Previously only the literal string
  `"false"` disabled them — `USE_CCACHE=0`, the convention half the fleet
  uses (and what `ENABLE_SCCACHE_*` expects), was silently ignored. Fixed in
  compiler-cache.sh (+ shared `_flag_disabled` helper), cmake-cache-linker.sh,
  build-ffmpeg.sh, onnxruntime lib/common.sh, ffmpeg-probe-framework.sh
  (inline case in the standalone-bundled files, per bundling policy).
  Verified live: `USE_CCACHE=0` now prints "ccache disabled".
- **Bare `sudo` in the ONNX AMD/NVIDIA steps** (30-build-native-amd.sh,
  30-build-native-nvidia.sh) replaced with the CPU sibling's guarded pattern
  (command -v probe + SKIP_DEP_INSTALL honor) — they died rc 127 on images
  without sudo while the CPU step degraded gracefully.
- **common.sh's sudo fallback now sets `SUDO_WRAP` too** (it set only `SUDO`;
  a `${SUDO_WRAP}` consumer reaching that path aborted under `set -u`).
- verify-arg-consistency.sh no longer mixes `WARN:` and `WARNING:` prefixes.

## 2026-08-08 (night) — Linux lane: audit round 2, Klasse B — contract drift

- **`CUDA_ARCHITECTURES` carried literal quote characters into CMake**: the
  only quoted value in versions.env, and `load_versions_env` exports values
  verbatim — CMake received `"80` and `90"`, and the documented Hopper
  `90→90a` suffix transform was a silent no-op (the string ends in `"`).
  Value dequoted in versions.env (the file format is unquoted inert data, as
  the loader header documents) AND the loader now strips one pair of
  surrounding quotes — defense in depth for the class. Verified live: the
  transform now yields `…;90a`.
- **Android OpenCV built a different OpenCV than the chain**:
  `OPENCV_VERSION="${1:-5.x}"` — the dispatcher passes no arguments and the
  env was ignored, so every android image cloned the MOVING 5.x branch while
  the chain ships tag 5.0.0. Now env-first with the 5.0.0 inline default
  (sibling pattern), and Dockerfile.media's final stage exports
  `ENV OPENCV_VERSION` so the android stages inherit the pin the same way
  they already inherit GSTREAMER_VERSION.
- **`Dockerfile.media` still fell back to `/opt/gcc-16.1.0`** in three
  places — a path that no longer exists since the 16.2.0 bump (every
  script-side fallback had been bumped; the Dockerfile inlines were invisible
  to verify-arg-consistency, which only parses `ARG NAME=` lines).
- **Stale nested fallbacks** (all invisible to the checker's `$`-containing
  literal guard): GenAI `v0.15.0`→`v0.15.2`, VVdec `v3.1.0`→`v3.2.0`,
  Python `3.14.6`→`3.14.7` ×2 (build_python.sh would have died on the 3.14.7
  checksum with a misleading error) + the same stale 3.14.6 on the Windows
  side (build-opencv-from-source.ps1).
- **`ENABLE_NVIDIA`/`ENABLE_AMD` now reach the cross lane**: the runtime lane
  honored them, `cross_stage_build_args` dropped them — a GPU-configured
  runtime could sit on CPU-only media artifacts with no warning. Forwarded
  (only when set) for the media stage.
- **`install_vulkan_sdk` zero-arg call aborted "unbound variable"**: the
  fallback referenced setup-dependencies.sh's flag-local
  `VULKAN_VERSION_DEFAULT`; the chain now ends in the canonical
  `VULKAN_VERSION` pin.
- Four comments whose stated contract had drifted from the code they sit on
  (abseil default, three GCC-16.1.0 claims) corrected.

## 2026-08-08 (night) — Linux lane: audit round 2, Klasse A — error-path masking

Four-perspective audit (error paths, contracts, tests, conventions); this
entry is the error-path class. Every fix below closes a path where a real
failure was reported as success:

- **ELF wrong-arch gate was dead code** (`validate-media-runtime.sh`): the
  clean-scan `exit 0` sat BEFORE the ELF architecture validation; NEEDED
  sonames resolve by name, so a wrong-arch binary scanned clean and the gate
  never ran. Now an `else` branch — ELF validation runs on every path.
- **Stale-rootfs export on failed builds**: `_build_one_artifact`
  (build-runtime-artifacts.sh) and `_sdk_arch_build` (build-sdk-artifacts.sh)
  ran under `if !`-suppressed errexit with no `|| return 1` — a failed
  `runtime_build_chain`/`cross_stage_run` fell through to
  `export_rootfs_from_image`, which exported the previous run's tag and
  reported green. Guards added.
- **parallel-loop lost workers that die via `exit`**: `err()` terminates the
  background subshell before `|| touch failed-flag` runs, and the join
  discarded `wait`'s rc — a dead lane read as green under PARALLEL_ARCHS=1.
  A nested `( )` layer now absorbs the exit into a return code.
- **app-wheels gate was vacuous**: the Dockerfile's `.placeholder` (written
  exactly when the wheelhouse build failed) satisfied "dir not empty". The
  riscv64 verify now requires a real `*.whl`; `ALLOW_EMPTY_APP_WHEELS=1` is
  the explicit escape hatch.
- **verify-media-artifacts could not fail for litert / genai / opencv-core**:
  litert checked `/usr/local/{include,lib}` (already filled by base's
  CPython); genai checked dirs its own producer `mkdir -p`'s on every skip
  path; opencv-core used INFO-only optional checks. All three now require
  stage-specific artifacts (new side-effect-free `probe_lib`/`verify_any_lib`
  helpers also fix the `verify_A || verify_B` idiom that counted A's failure
  even when B passed). genai verify mirrors its producer's legitimate
  cross-build skip instead of "verifying" pre-created empty dirs.
- **smoke-media masking**: a non-executable ffmpeg/gst-inspect was a PASS
  ("will work at runtime") — now INFO + ELF-magic assertion, with the
  functional gate named; the OpenCV cvtColor roundtrip and GStreamer pipeline
  checks had no else-branch (could not fail) — now fail when execution
  demonstrably works; ffmpeg encode failure fails when the binary executes
  and advertises libx264; onnxruntime import-failure now proves the library
  exists instead of claiming presence unchecked.
- **verify-cuda-stack.sh rewritten**: ` || true)` pasted inside three command
  substitutions made the "not found" branches unreachable and hard-failed
  healthy images under `set -e`. Now honest warn-only (stderr, no `-e`) with
  `CUDA_STACK_STRICT=1` as the real gate for complete-stack images.
- **base-image bootstrap fails fast**: the apt-update retry loop `break`ed
  away its terminal failure and continued; ca-certificates install failure
  was a log line. A broken mirror/CA store now aborts the bootstrap with the
  culprit named instead of surfacing hours later as an opaque TLS error.

## 2026-08-08 (evening) — Linux lane: IREE tblgen Exec-format failure, and the binfmt registration that silently died

### media-arm64 failed: IREE's NATIVE tblgen was cross-compiled

The app-wheelhouse IREE cross build died with `Exec format error` on
`llvm-project/NATIVE/bin/llvm-min-tblgen`: LLVM's CrossCompile.cmake defaults
the NATIVE sub-build's compilers to the **outer cross compilers**, so the
tblgen that must run on the amd64 build host was built for arm64. Fix:
`build-app-wheelhouse.sh` now passes `-DCROSS_TOOLCHAIN_FLAGS_NATIVE` pinning
the true host compilers (+ ccache launchers — closing the nested-sub-build
caching item from the backlog in the same stroke). riscv64 never hit this only
because qemu binfmt silently emulated the wrong-arch tblgen — slowly.

### Which exposed: binfmt registrations die on containerd restart

The morning's shim-failure `systemctl --user restart containerd` silently wiped
the rootlesskit-namespace qemu registrations (they are namespace-lifetime, not
host-lifetime). Re-registered for arm64+riscv64 and installed the
`rootless-binfmt.service` --user unit so login/boot re-registers automatically.
Two bugs fixed in `setup-rootless-binfmt.sh` itself along the way: it claimed
"pulling" but never pulled (image save fails "not found" on a fresh host), and
its blob-detection pipeline `tar -tf | grep -q` self-destructed under pipefail
(SIGPIPE — shell bug class 2) so extraction skipped every blob. AGENTS.md's two
stale recommendations of the non-working rootless
`tonistiigi/binfmt --install` container corrected to the helper script.

The foreign chain marked arm64 failed and moved on to media-riscv64 (by
design); media-arm64 + android-arm64 re-run after the chain with the fix.

## 2026-08-08 (evening) — Linux lane: structural round 1 (cache-key closure + drift bugs + dead code)

### Dockerfile.base no longer cache-keys on ~120 files (A1)

base's six RUNs bind-mounted **all of 01-core + 02-toolchain**, so editing any
of ~120 files — including host-only orchestrator modules the image never
executes — busted base and cascaded a rebuild through the entire chain,
undoing the toolchain stage's careful per-file mount lists one tier up. The
mounts are now the traced 15-file transitive closure of base-image.sh (mirror
RUN: 2 files). Validated with a real from-scratch base build; the first
attempt failed exit 127 because the static trace missed
`use-fast-ubuntu-mirror.sh`, which bootstrap-ca **exec**s rather than sources
— closure tracing must follow exec/`bash` edges, not just `source` lines.
Marginal cost of a future 01-core edit drops from "full chain rebuild" to
near zero.

### Three drift bugs between intentional clones (A2, A4, A5)

- `cross_build_is_active` existed 5× with 3 semantics; the documented
  arch-normalization fix had reached 1 of 5 copies. The raw copies compared
  OCI names against `uname -m` machine names and reported "cross active" on
  native arm64 hosts. All fallbacks now normalize via `arch_normalize`.
- `compiler-resolution.sh` never shipped to the android stages, so
  IREE-android's fallback `command -v gcc` resolved the **custom cross GCC**
  from the inherited toolchain PATH as its *host* compiler (live bug, masked
  by best-effort gating). Dockerfile.android now COPYs the canonical script;
  the fallback prefers explicit /usr/bin compilers like the litert copy.
- Dockerfile.package hand-rolled the ports-mirror sed: it ignored the
  `USE_FAST_UBUNTU_MIRROR` gate and never derived ports-from-archive. It now
  runs the canonical `use-fast-ubuntu-mirror.sh`.

### Dead code out (B1–B4, B6)

smoke-wrapper.sh (orphaned; two docs falsely claimed wrapper-smoke runs it —
both corrected), `create_deb()` (104 lines, zero callers, positioned after
the script's outputs were written), `run_quiet()` (zero callers), the
vestigial smoke-runtime-image.sh COPY in Dockerfile.package, and AGENTS.md's
claim of a `media_build_preamble_init` alias that does not exist.

Deferred to the post-chain batch (they touch files the running foreign chain
bind-mounts): A3 parse-table, A6 dir-walker unification, B5 smoke-runtime
decomposition. Full status in docs/refactoring-backlog.md.

## 2026-08-08 (afternoon) — Linux lane: the --no-push hole, and a forensic audit of "green"

### `--no-push` full-chain handoffs never worked on this host

The BuildKit **OCI worker keeps its own image store**: `nerdctl build -t`
loads results into containerd, which the next build's `FROM` never consults —
the mutable parent tag resolves against the **registry**. Every downstream
stage of a `--no-push` chain silently built on the last PUSHED parent. Proof:
a freshly built compiler shipped `/opt/gcc-16.2.0` while the sdk built "from"
it contained `/opt/gcc-16.1.0` (a months-old ghcr image); `FROM
repo@<containerd-digest>` errors "not found". Two full validation runs were
lost to this before the digest trail exposed it. Interim: push mode is the
only correct full-chain flow (docs updated, a warning fires at `--no-push`
parse time); real fix (OCI-layout build-context handoff, the runtime lane's
existing mechanism) is specced in the backlog. The manifest is protected by
running `--to-stage android` + the runtime lane with `--skip-manifest` until
all arches exist.

### A fifth shell bug class, found by auditing the helper scripts

Functions whose **last statement** is `[ cond ] && action` return 1 in the
healthy case; under `set -e` the guard tool kills itself. The flagship victim:
`verify-critical-fixes.sh` — the script guarding the Five Critical Fixes —
aborted after fix 1 **whenever the fixes were actually present**, silently
skipping fixes 2–9 and the summary. It only ever looked green because hosts
don't carry the staged payloads. Fixed there, in `smoke-common.sh` (the
"Unknown arch" guard was unreachable), and lint/preflight/NVIDIA-lane guards
in the same sweep.

### Forensic audit of the build logs: what "21/21 PASS" was hiding

Two-agent sweep over ~12 MB of logs, each claim re-verified:

- **Built 0.15.2, shipped 0.14.0**: the app's `uv.lock` outvoted the chain's
  freshly built `onnxruntime-genai` wheel (`--find-links` only OFFERS).
  Fixed (pre-install + `--no-install-package`), and genai added to the
  version-pin smoke so this class cannot recur unnoticed.
- **The libcamera pin was undercut at the finish line**: the media validator
  did not know meson's `lib/<multiarch>` install dirs, declared the build's
  own libs missing, and apt-installed Ubuntu's older libcamera as a shadow
  copy — a false-positive "repair". Fixed (multiarch dirs in the scan path).
- **ccache delivers zero in LLVM's nested sub-builds** (189 identical objects
  compiled twice, second pass 1.9% slower): `CROSS_TOOLCHAIN_FLAGS_NATIVE`
  forwards no compiler launcher. Plus: no ccache statistics are emitted
  anywhere — and the 2MiB step-log clip truncates **stdout only**, so stats
  (and anything that must survive) belong on stderr. Both queued.
- Still open, prioritized in the backlog: TVM ships import-broken (built
  against distro LLVM 22.1.2, not the pinned 22.1.8 — the telltale line
  prints at INFO), pyav is pinned but never installed, FFmpeg's TF/OpenVINO
  DNN backends died silently, OpenCV links distro GStreamer/FFmpeg due to
  stage ordering, three assertion-free fallback-PASSes, inner smoke warnings
  invisible to the outer verdict.
- Verified NON-issues (do not chase): "missing NVENC" is `ENABLE_NVIDIA`-gated
  by design; runtime Python 3.14.4 is Ubuntu's distro CPython as venv base
  (a decision, not a stale layer); "is not a commit!" clone warnings are
  annotated-tag peeling.

### Also — periphery audit (workflows, hooks, tooling)

A dedicated sweep over the never-audited edges. The flagship: the pre-commit
hook's sphinx gate pointed at a nonexistent `docs/source/` with the real error
swallowed — every commit on a hook-enabled clone failed; fixing the path then
exposed 12 real docs warnings under `-W` (10 orphaned pages now in an
"Operations & Reference" toctree, 2 unknown-lexer blocks) — the strict gate is
green end-to-end for the first time. Also fixed: deps.json's libcamera entry
now bound to `LIBCAMERA_VERSION` (the public license pages published
"git master" past yesterday's pin), the install-deps action's
dirname-of-empty-string putting `.` on GITHUB_PATH, a benchmark-viewer build
that reported success over a failed `npm build`, three unreachable FAIL
branches in the webserver flutter smoke, least-privilege `permissions:` on the
two unpinned workflows, SHA-pins for the last two mutable action refs, rename
coverage (`--diff-filter=ACMR`) and a loud git-grep failure mode in the hook,
and the license generator now fails on unknown versions.env vars and defaults
to check mode. Remaining periphery items are in the backlog.

### Also

- Owner priorities codified: AGENTS.md § Project priorities (speed AND
  stability AND tests, docs always in the same work unit), README
  § Engineering principles.
- buildkitd GC budget pinned (`~/.config/buildkit/buildkitd.toml`,
  gckeepstorage 500GB) + step-log-size drop-in (both effective at the next
  between-runs restart). Unexplained: base cache-missed after the first
  restart despite unchanged mounts and a surviving store — under
  investigation before cross-restart layer reuse is trusted.
- versions.env: 11 bumps (checksums from official sources), libcamera pinned
  for the first time (`v0.7.2` — the only media library that tracked master),
  OpenCV moved to the immutable `5.0.0` tag; ROCm deliberately HELD (new
  "TheRock" releases 404 on the old apt path); LiteRT-LM 0.15.0 verified to
  keep the protobuf 6.31.1 coupling.
- `latest-cross-amd64` shipped: full from-base chain in push mode with
  digest-pinned handoffs + live ancestry annotations; runtime smoke 21/21
  after a host containerd-shim failure was diagnosed (every `nerdctl run`
  died; builds unaffected) and the services restarted. The ancestry guard and
  the annotation-based `--verify-chain` verdicts had their first real-world
  successes the same day.

## 2026-08-08 — Windows lane: backlog cleared before the from-toolchain rebuild

The remaining four items, closed so the chain restarts against a tree with no
known open work. Two of them turned out to be blocked only by a third.

- **Warning floods cut at the source.** 16 % of a chain log (72 864 of 459 061
  lines) was four upstream constructs repeated thousands of times, which matters
  because buildkitd clips a RUN step's log at 2 MiB and then *deadlocks* it.
  Targeted suppressions, never a blanket `-w`: `-Wno-deprecated-copy` (OpenCV
  `matx.hpp`), `/clang:-Wno-unused-value` (ONNX), `-Wno-documentation-unknown-command`
  (TVM), and — because STL4037 is emitted by the MSVC STL headers themselves and
  no clang group can switch it off — `_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING`
  for IREE/MLIR, at directory scope where it survives LLVM's `HandleLLVMOptions`
  stripping. OpenCV's is safe for the CUDA path because the repo's own patch
  strips `-W*` before nvcc's `cl.exe` host compiler sees it (verified against the
  patch, not the comment above it). New `Measure-BuildWarnings.ps1` reports each
  family against its pre-suppression baseline, so the next run PROVES each flag
  still earns its place rather than it becoming folklore.
- **Smoke test split**, 1 573 → 1 386 lines, harness into
  `WindowsSmokeTest.Common.psm1` (no Dockerfile change — the final image already
  COPYs the whole modules dir). The move had one hazard and both halves of it
  fail silently: `Assert-Test` read `$ExitOnFirstFailure` out of the *calling
  script's* scope, which a module cannot see (the switch would have quietly
  stopped working), and the summary read `$script:passed`, which across a module
  boundary would have reported 0 passed / 0 failed and exited 0 on any run.
  Both are explicit state now. An AST inventory of every assertion call site is
  194 before and 194 after, identical as a set; 11 new tests, suite at 412.
- **Pre-commit hooks are enabled**, and the reason they were not is gone:
  `preflight.sh` used bare `python3`, which on this host is the Microsoft Store
  stub, so every commit would have failed for reasons unrelated to the commit.
  It now probes for an interpreter that can actually execute code.
- **Submodule pin drift** (`Kataglyphis-DocumANTation`, `UV_VERSION` 0.12.1 vs
  0.12.3) kept the version-snapshot check red, which is what blocked the hooks.
  Fixed and committed in that submodule; it still needs a push there plus a
  pointer bump here, left explicit because it is a different repository.

## 2026-08-08 — Windows lane: three gaps that could not fail loudly

Landed in the window a concurrent `versions.env` pin bump opened: `PYTHON_VERSION`
3.14.7 invalidates `Dockerfile.base` from its `COPY versions.env` down and every
media stage under the toolchain, so these changes cost no rebuild that was not
already owed. Each one is the same shape as the rest of this week's work — a
check that was structurally incapable of reporting the failure it existed for.

- **The FFmpeg `.pc` gate could not fail in its worst case.** It sat inside
  `if (Test-Path $ffPkgConfigDir)`, so a *missing* `lib\pkgconfig` — the most
  complete failure available — skipped every assertion without a word. Extracted
  to `Assert-FfmpegPkgConfig`, which treats an absent directory as fatal, and
  called outside that guard. Five unit tests, one per failure mode, reaching the
  function by AST extraction so it stays out of the three media branches'
  compile closure (the reason `Remove-MakefileShowIncludes` moved out of the
  shared module on 2026-08-03).
- **The base image's PATH had two dead entries and was missing a live one.**
  `SCOOP_HOME`/`SCOOP_GLOBAL` are scoop app *roots* and hold no executables.
  Meanwhile flutter is installed `--global`, so `C:\ProgramData\scoop\shims`
  exists and was on no PATH entry at all — a 2026-07-14 comment had removed it
  as a "never-created dir", which stopped being true the moment anything was
  installed globally. Invisible only because `FLUTTER_BIN` is baked separately;
  any future global package would have been unresolvable by name. Restored (user
  shims keep priority) and asserted by the smoke test.
- **An unresolved merge conflict had been committed** into
  `docs/refactoring-backlog.md` and survived several commits: two sections were
  appended concurrently and never merged. Markdown and shell lint both pass a
  conflict marker, because it is valid text. Resolved (content verified
  identical modulo the markers), and `.githooks/pre-commit` now greps the
  *staged* content for `<<<<<<< ` / `>>>>>>> ` — verified to fire on the exact
  commit that carried the bug. A bare `=======` is deliberately not matched: it
  is a legitimate Markdown setext underline, and real conflicts carry the others.
- **Nothing was linting the git hooks.** Writing that guard surfaced a live
  `SC1072`/`SC1073` parse error already sitting in `.githooks/pre-commit`: a
  comment starting with the word "shellcheck" reads as a malformed directive and
  aborts ShellCheck's parse of the whole file. It survived because
  `lint-shell.sh` filters to `*.sh` and a git hook cannot carry that suffix.
  Comment reworded, and `lint-shell.sh` now also accepts explicitly-passed
  extension-less files with a shell shebang — default sweep unchanged (223
  files), staged-file coverage gained, and the hook now lints itself.

Note: `core.hooksPath` is **unset** on the primary dev clone, so none of these
hooks have been running there — the documented one-time
`git config core.hooksPath .githooks` (AGENTS.md) is still pending, and is left
to the owner because it changes commit behaviour for every process writing to
that tree.

## 2026-08-08 — Linux cross lane: four bug classes, machine-checked ancestry, live caching

Driven by a from-base amd64 rebuild of `:latest-cross`, fixing every failure as
the chain hit it. The theme mirrors yesterday's: silent failure made loud.

### Four bash bug classes found live, fixed repo-wide, and lint-gated

1. **`trap … RETURN` leaks to the caller** — a RETURN trap set inside a
   function fires again when the CALLER returns, where the function's locals
   are gone; under `set -u` this killed `build-cross-chain.sh` AFTER every
   stage had succeeded. Three instances (parallel-loop, context-management).
2. **Unguarded pipelines under `set -euo pipefail`** — `du` on a
   not-yet-created cache dir aborted the orchestrator on FIRST runs; `readelf`
   on linker scripts, `dpkg -S` on unowned files, `find | head` SIGPIPE and
   friends would have killed the media validators mid-stage. ~10 sites.
3. **Comma-split loops break under `IFS=$'\n\t'`** — `for x in ${list//,/ }`
   runs ONCE with the whole list as one bogus element in strict-IFS scripts.
   Broke the GCC GPG key import AND would have killed the compiler stage's
   multi-target Python staging. New lint suite (`test-ifs-safety.sh`) bans the
   idiom; safe pattern is `IFS=',' read -r -a`.
4. **Vendor scripts sourced under `set -u`** — LunarG's Vulkan `setup-env.sh`
   reads `$1` unguarded and is sourced with explicitly cleared args; killed the
   sdk stage's TVM step. Vendor sourcing now suspends nounset and restores it.

### Cross-invocation ancestry is machine-checked now

Digest pinning only ever protected a SINGLE run. Every pushed cross stage now
records its parent's digest as an OCI manifest annotation
(`org.kataglyphis.parent-digest`); partial runs (`--from-stage` after base)
walk the recorded chain against the registry and hard-fail on a stale ancestor
(`linux/scripts/01-core/ancestry.sh`). `--verify-chain` gives real FRESH/STALE
verdicts from the same annotations. The old "after a compiler push start from
sdk" rule is enforced by the machine, not the reader.

### The GCC GPG failure was a key-rotation, not tampering

gcc-16.2.0 is signed by Richard Biener's key; the script pinned only Jakub
Jelinek's and reported the missing public key as possible tampering (with
SHA512 already OK). Now: accepted key SET, verdict via `gpg --status-fd`
(NO_PUBKEY → warn/skip per policy; BADSIG → fatal), signer checked against the
set so an arbitrary imported key cannot pass.

### Toolchain caching went from decorative to real

The ccache wiring was inverted: the GCC RUN mounted the cache but never exec'd
ccache; the LLVM RUN exec'd ccache but never mounted the cache. Fixed both,
plus `CCACHE_BASEDIR`/`SLOPPINESS` (without which per-target build dirs made
identical TUs never hit) and a multi-word-`CC` PATH fix for the Canadian path.
`--with-build-config=bootstrap-ccache` was PROPOSED and REJECTED — GCC 16
ships no such config (verified against the tarball). Per-target GCC builds can
now run concurrently behind `GCC_PARALLEL_TARGETS=1` (serial apt pre-pass,
divided JOBS, per-target logs; default off).

### Version pins: complete and current

`versions.env` audited for completeness (libcamera was the ONLY unpinned
media library — now `LIBCAMERA_VERSION=v0.7.2`, and the generated wheel stops
lying about its version) and currency (11 bumps incl. Python 3.14.7,
Node 26.7.0, OpenCV `5.x`→`5.0.0` tag = last non-reproducible media pin
closed; ROCm deliberately HELD — the new upstream releases 404 on the old apt
path). All checksums fetched from official sources; a new checker section
catches the case-mapped version literals the ARG checks could not see.

### Also

- `--no-push` validation runs no longer validate STALE registry images: the
  wrapper smoke pulled the published tag over the freshly built one, and the
  runtime handoff pulled `cross-android-<arch>` over the local build
  (BUILT_THIS_RUN now set on the local path too). Runtime chain failures
  propagate instead of reporting success.
- Disk preflight measures the cache dir's own filesystem (not its parent's)
  and survives first runs; `--final-image` is no longer silently overridden.
- apt.llvm.org 5xx no longer kills a multi-hour layer (falls back to source).
- Regression suites: `test-ancestry.sh`, `test-parallel-loop.sh`,
  `test-ifs-safety.sh` — auto-discovered by the pre-commit `script-tests` gate.

## 2026-08-07 — Windows lane: reproducibility, mandatory plugins, honest gates

The theme is less the repairs than what they have in common: several things had
been failing **silently** for months, so most of this work is about making
failure loud and early.

### Mandatory GStreamer plugins are a contract now

`libav`, `opencv`, `onnx` and `tflite` were absent from the published
`winamd64` image and nothing was ever red — meson's `auto` feature state means
*skip silently*, and the healthcheck printed `[PASS]` for plugins that did not
exist. Four **unrelated** root causes, diagnosed against gstreamer 1.29.2:

- **opencv** — OpenCV ships no `.pc` at all (confirmed: zero files in the built
  image). One is now authored, enumerating the import libraries from the real
  install (64 of them) instead of a hand-kept list that would rot.
- **onnx** — ONNX Runtime ships no `.pc` on any platform; one is emitted.
- **libav** — `subprojects/FFmpeg.wrap` *provides* the libav\* modules pinned to
  FFmpeg 7.1.1, and `-Dwrap_mode=forcefallback` **forced** meson onto it, so
  pkg-config was never consulted: the build fetched a second, older FFmpeg
  instead of the `n9.0` it had just built. The wrap is disabled before configure.
- **tflite** — consults no pkg-config at all. It probes the compiler for
  `tensorflow/lite/c/c_api.h`, the *pre-rename* path, while LiteRT ships the
  post-rename `tflite/` layout; an alias tree is staged. Confirmed in the field
  that upstream's first library name (`tensorflowlite_c`) does not exist here —
  only its fallback `tensorflow-lite`.

The set lives in `Get-RequiredGstPlugin` and is enforced at four points that
previously disagreed: a pkg-config pre-flight (checking version **floors**, not
just presence), meson features set to `enabled`, a post-install `gst-inspect`
gate that throws, and smoke-test assertions. `tensorfilter` is deliberately
excluded — it is an NNStreamer element this repo never builds.

### FFmpeg's .pc files were unusable

Found by probing the built image rather than waiting for the merge stage:
`Version: ..` (configure found neither a VERSION file nor git tags, because the
source is a GitHub auto-tarball) and MSYS-style `prefix=/c/…` paths that
clang-cl cannot resolve. The empty version alone kept gst-libav out,
independently of the wrap. Both fixed, and gated at the end of the FFmpeg stage.

### Reproducibility

- **LLVM, ninja and nasm pinned** (`LLVM_WINDOWS_VERSION`, …). The OS base was
  digest-pinned while the very next layer installed whatever scoop served that
  day — and five patches in this tree are written against a specific clang-cl.
  Asserted at base-build time.
- **`C:\toolchain-manifest.json`** records every pinned input as a pin/resolved
  pair plus the floating ones, so *which compiler built this image* is answerable
  from the artifact. It captures the MSVC toolset (14.51.36231) that floats
  inside VS major 18 and was previously recorded nowhere.
- **`versions.env` no longer invalidates the whole media chain.** It was COPY'd
  into the stage all three branches descend from, so three Windows-only pins
  re-ran all six media compiles (~90 min of ONNX among them). Versions now travel
  as build-args; the file is demoted to a gap-filler by a precedence rule that
  distinguishes a real build-arg override from a value merely inherited from the
  base image's machine environment.

### Gates that stop lying

- **Disk** is checked per stage, with floors calibrated against measured
  consumption, on every drive the build uses (not just `C:`), in **both** lanes.
- **The runhcs shim** is identified by the SHA256 recorded at install time
  instead of by file size; `deploy-shim-patch.ps1 -RecordCurrent` arms that
  without a redeploy.
- **The CNI conf must exist as BOTH `.conf` and `.conflist`** — buildkitd reads
  one, nerdctl the other, and "converting" between them cost a launched chain.
  The `.conf` is now *derived* from the `.conflist`.
- **Retries** stop immediately when a failure repeats byte-for-byte (a poisoned
  snapshot, whose remedy is `-NoCache` on that stage) but still retry
  snapshot-mount contention, which repeats verbatim and clears anyway. The merge
  stage's `-MaxAttempts 5` had been dead code, because its failure signature was
  never in the transient pattern.

## 2026-07-30 — Agentic loop: backlog-driven planner skip + completed-task pruning

- **Skip planner when tasks are pending** (`backlog.skipPlannerWhenTasksPending`,
  default `true`): while `BACKLOG.md` still has unchecked tasks, iterations go
  straight to the executor instead of paying for a planning pass.
- **Completed tasks are deleted from the backlog**
  (`backlog.deleteCompletedTasks`, default `true`): executor prompts now
  instruct deleting the finished entry (summary goes into the commit message),
  and a deterministic pruner (`remove_checked_tasks` /
  `Remove-CheckedBacklogTasks`) removes any lingering `- [x]`/`- [X]` blocks
  (title + indented body) before each auto-commit and at drain start.
  Completed work stays visible in git history instead of growing the file.

## 2026-07-30 — Agentic loop: live streaming output

- **Claude engine streams by default**: `claude -p` now runs with
  `--output-format stream-json --verbose` (config
  `engines.claude.streamOutput`, default `true`) and both libraries render
  the events live to console + log: session start, one line per tool call,
  assistant text per turn, tool errors, and a final
  `turns / duration / cost` summary. Set `streamOutput: false` to return to
  the silent text mode.
- **Bash opencode invocation streams too**: output is echoed line-by-line to
  console + log as it arrives instead of being buffered until exit (the
  PowerShell module already streamed).

## 2026-07-30 — Agentic loop: Claude Code engine + robustness

- **Engine abstraction** in both agentic-loop libraries
  (`linux/scripts/lib/agentic-loop.sh`,
  `windows/scripts/modules/WindowsAgenticLoop.Common.psm1`): `opencode` and
  `claude` (Claude Code CLI, headless `claude -p`) backends behind a single
  dispatcher (`invoke_agent` / `Invoke-AgenticAgent`). Selection via config
  `engine`, `AGENTIC_ENGINE`, or runner flag; model overrides via
  `AGENTIC_PLANNER_MODEL` / `AGENTIC_EXECUTOR_MODEL`.
- **Claude engine**: role system prompts via `--append-system-prompt-file`,
  planner sandboxed with `--allowed-tools`, executor permission mode
  configurable (default `bypassPermissions`), planner `--fallback-model`
  support.
- **Robustness**: retry with linear backoff per agent invocation, per-role
  timeouts (`plannerTimeoutSeconds` / `executorTimeoutSeconds`), build-failure
  fixer phase (executor-tier model gets the build log tail, then one rebuild),
  consecutive-build-failure cap that stops the loop, dry-run stall guard.
- **Shared loop features moved into the libraries**: planner-only /
  executor-only modes, max-iteration override, default phase prompts.
- PowerShell module: new exports `Resolve-AgenticEngine`, `Invoke-ClaudeCode`,
  `Invoke-AgenticAgent`, `Invoke-AgentProcess`, `Invoke-BuildFixer`,
  `Get-AgenticConfigValue`, `Get-AgentTimeoutForRole`; module version 1.1.0.
  Fixed the refactor planning cycle erroneously reusing the executor prompt.
- Pester suite extended to 38 tests (engine resolution, dispatcher, claude
  dry-run, engine-override loop smoke tests).
