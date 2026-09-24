<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# ONNX Runtime has one source: the chain

**Owner rule, 2026-09-23.** Every component that compiles against, links or
loads ONNX Runtime uses the ORT this repository builds from source. Nothing
downloads, restores or installs a second one: no NuGet package, no PyPI wheel,
no release zip, no apt package, no copy bundled inside another project, no
pyke build. There are no exceptions, and a plugin EP counts as ORT.

This page owns the mechanism: which consumers exist, how each one reaches the
chain ORT, which guard proves it, and what each guard cannot see. The rule
itself, as an agent must keep it, is
[`windows-build-invariants.md` § ONNX Runtime has exactly one source](windows-build-invariants.md#onnx-runtime-has-exactly-one-source-the-chain-owner-rule-2026-09-23)
for Windows and `AGENTS.md` § Linux Build Rules for Linux.

## What "the chain ORT" is

| | Windows | Linux |
|---|---|---|
| Built by | `windows/scripts/build/Build-OnnxFromSource.ps1` | `linux/scripts/03-media/build/onnxruntime/` |
| Installed at | `C:\runtime\lib\onnxruntime-source` (`ONNX_ROOT`): `bin\onnxruntime.dll`, `lib\onnxruntime.lib`, flat headers in `include\onnxruntime\` | `/usr/local/lib/onnxruntime-cpu` on every variant, plus `/usr/local/lib/onnxruntime-gpu` on the GPU variants |
| Python wheel | `C:\runtime\wheels` (`PYTHON_WHEELS`) | `/opt/wheels` at build time; the installed flavour is kept in `/opt/onnxruntime-wheels` (`ORT_CHAIN_WHEEL_DIR`) |
| Source root compiled into it | `C:\temp\onnx-src` | `/opt/onnxruntime` (`/opt/onnxruntime-android` for Android) |

The last row is the fingerprint every guard uses. ORT compiles its source paths
into its binaries through `__FILE__`, so the chain's DLL carries
`C:\temp\onnx-src\onnxruntime\core\...` and its `.so` carries
`/opt/onnxruntime/onnxruntime/core/...`. Measured on 2026-09-23: Windows ML's
`C:\Windows\System32\onnxruntime.dll` (1.17) carries `C:\__w\1\s\onnxruntime\...`,
and the PyPI GPU wheel carries `N:\_work\1\s`. Two consequences:

- Moving either source directory, or adding `-ffile-prefix-map` /
  `-fmacro-prefix-map` to the ORT build, breaks every guard and every consumer
  repo at once. They fail closed, but they all fail.
- A version is not provenance. PyPI publishes onnxruntime 1.30.0 for cp314 too,
  without DirectML, so a name-and-version check cannot tell it from the chain
  wheel. The guards compare bytes.

## What was wrong before 2026-09-23

- **Windows OpenCV** downloaded `onnxruntime-win-x64-1.25.1.zip` at configure
  time (`-win-arm64-` on the cross lane), with no pin and no SHA256, and linked
  dnn and G-API against it. The shipped image still looked clean: dnn's install
  glob reads `bin\`, and the zip keeps its DLLs in `lib\`.
- **Windows GenAI** compiled and linked against `Microsoft.ML.OnnxRuntime.DirectML`
  1.24.4, which `ortlib.cmake` restores from the aiinfra ORT-Nightly feed with no
  hash whenever `ORT_HOME` is unset.
- **The rocm venv** carried PyPI's `onnxruntime-ep-webgpu` 0.4.0.
- **The app venv reconcile** uninstalled fixed name lists and missed
  `-webgpu`, `-rocm`, `-qnn`, `-openvino`, `-training` and `-winml`. On Linux a
  missing chain wheel fell back to the app lock's PyPI 1.27.0 without a word.
- **The hub's Windows consumer API** (`WindowsOnnx.Common`) installed NuGet ORT,
  and `WindowsMediaRuntime.Common` staged only NuGet `runtimes\<rid>\native`
  layouts.
- **Linux** held the rule by accident: OpenCV built without ORT when the chain
  was missing; dnn's install copy in `/opt/opencv5/lib` won the `ld.so` lookup;
  an apt soname repair could pull `libonnxruntime1.x` (it did, on 2026-08-27);
  FFmpeg fell back to any vendor `libonnxruntime.pc`.
- **Consumer CI venvs** synced inside our images tested PyPI ORT.
- **Consumer repos**: OxidANT statically linked pyke's ORT 1.28.0; AccelerANTgine's
  CMake searched `C:/onnxruntime`, Program Files, vcpkg, `/usr` and pkg-config;
  OmniAccelerANT could load System32's Windows ML copy.

## Every consumer, and how it reaches the chain ORT

| Consumer | Lane | How it gets the chain ORT | Its own gate, then G2 |
|---|---|---|---|
| OpenCV dnn + G-API | Windows, every lane incl. the arm64 cross | § [OpenCV on Windows](#opencv-on-windows-the-shim-the-hook-and-the-gate) below | `Get-OpencvOrtConfigureFinding` |
| OpenCV | Linux, both passes | `opencv-ort.sh`: every ORT CMake input explicit (`HAVE_ONNXRUNTIME=1`, both `DOWNLOAD_*` off, `ONNXRUNTIME_PREFER_STATIC=OFF`, the CMake packages disabled, the version read from the chain library). A missing chain stops the build. dnn's install copies in `/opt/opencv5/lib` become links to the chain file | `opencv_ort_assert_configure`, `opencv_ort_assert_installed` |
| GenAI | Windows | an `ORT_HOME` shim at `<src>\ort-home` with the chain's headers, import lib and DLL; `FETCHCONTENT_SOURCE_DIR_ORTLIB` and `..._ONNXRUNTIME` point at an empty dir, so any fallback fails configure | `Get-GenaiOrtConfigureFinding`; `Get-GenaiOrtTreeFinding` reaches G2 through `-Finding` |
| GenAI | Linux | `60-build-genai.sh --ort_home <chain>` | `linux/scripts/03-media/verify-genai-ort.sh` in the genai verify RUN |
| FFmpeg | Windows | the chain headers in `compat\onnx`, the chain import lib | G2 reads `config.mak` and `config.log` |
| FFmpeg | Linux | the chain's `-L` goes ahead of every other `--extra-ldflags`; a missing chain, or a probe that cannot link it, stops the build | `ffmpeg_ort_link_findings` reads `ffbuild/config.mak` the way `ld` resolves it |
| GStreamer `onnx` plugin | Windows (merge stage) | the merged `ONNX_ROOT` | G2 reads `build.ninja`, `intro-dependencies.json` and the meson log |
| GStreamer `onnx` plugin | Linux | the chain `.pc` | `gst_onnx_ort_findings` reads `build.ninja` |
| AMD GPU plugin EP (`migraphx-ep.dll`) | Windows rocm spike | built against the image's ORT | G2 in phase 5 |
| WebGPU EP | Windows rocm spike | built in-tree into the chain `onnxruntime.dll`, not as a plugin | configure and wheel gates in `Build-OnnxFromSource.ps1` ([`windows-rocm.md` § ONNX Runtime WebGPU EP](windows-rocm.md#onnx-runtime-webgpu-ep-rocm-lane-spike)) |
| App venv (OrchestrANT) | both | purge every ORT distribution the census names, force-install the chain wheels, then the census check | `ort-venv-census.py` |
| Consumer CI venvs | both, inside our images | `uv_reconcile_chain_ort` / `Sync-UvChainOnnxRuntime` | census check plus an import proof ([`python-ci.md` § Trap 3](python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi)) |
| Rust `ort` / `ort-sys` built in our images | both | G3: the image ENV names the chain ORT | Test-Container § 19, contract row `ort-crate-env` |
| `WindowsOnnx.Common`, `WindowsMediaRuntime.Common` (AccelerANTgine's lane) | Windows | `Get-OnnxChainLayout`; NuGet ORT is refused | `WindowsOnnx.Common.Tests.ps1`, `WindowsMediaRuntime.Common.Tests.ps1` |
| apt and `ld.so` | Linux | the soname deny is in code; `000-onnxruntime.conf` sorts ahead of `000-opencv.conf` | `ort-runtime-gate.sh`, in `validate-media-runtime.sh` and `configure-runtime.sh` |

**FFmpeg on Linux stops; it never builds without ORT.** `ffmpeg_probe_libonnxruntime`
exits when the chain is missing or its synthesized-`.pc` probe cannot compile and
link it; before 2026-09-23 it skipped the backend. The probe runs after
`_ffmpeg_cross_args`, with the compiler and cross search directories FFmpeg's
configure gets, and the ORT stage leaves what it reads on every arch by the same
code: the flat `include/onnxruntime_c_api.h` (`copy_onnx_headers_to_output`) and
the `lib/libonnxruntime.so` link (`ensure_onnxruntime_symlink`). So it fails only
where FFmpeg's own `require libonnxruntime` would. The skip would stop the build
anyway, one step later: `ffmpeg_ort_link_findings` requires
`CONFIG_LIBONNXRUNTIME=yes`.

### OpenCV on Windows: the shim, the hook and the gate

OpenCV 5.0.0 had two defects on every Windows lane:

- `modules/dnn/CMakeLists.txt:141` tests `HAVE_ONNXRUNTIME`, which `FindONNX`
  never sets. dnn then downloaded its own ORT, FORCE-rewrote `ONNXRT_ROOT_DIR`
  (`:279`) and re-ran FindONNX (`:287`). Evidence:
  `out/build-logs/rebuild-push-amd64-20260922-034439.log` lines 307666, 308144
  and 308502.
- G-API's `dml_ep.cpp` compiled to a stub that throws. `FindONNX.cmake:93` looks
  for `include/onnxruntime/core/providers/dml/`, but ORT 1.30 installs
  `dml_provider_factory.h` flat into `include/onnxruntime/`.

`Build-OpencvFromSource.ps1` fixes both without a source patch:

- **The shim.** `New-OpencvOrtNestedInclude` rebuilds ORT's source-tree header
  layout at `C:\temp\opencv-src\ort-nested`. It throws when the chain lacks
  `onnxruntime_cxx_api.h` or `dml_provider_factory.h`.
- **The arguments**, the same on every lane (`Get-OpencvOrtCmakeArgs`): the shim
  as `ONNXRT_ROOT_DIR`, the chain's `lib` as `CMAKE_LIBRARY_PATH`,
  `-DHAVE_ONNXRUNTIME=ON`, the chain version, and
  `CMAKE_DISABLE_FIND_PACKAGE_onnxruntime` / `_ONNXRuntime`. The config packages
  stay off because the chain's `onnxruntimeConfig.cmake` names the DLL as its
  link library.
- **The hook.** `windows/scripts/patches/opencv/cmake-hooks/POST_CREATE_MODULE_LIBRARY_opencv_gapi.cmake`
  is loaded by OpenCV itself through `OPENCV_CMAKE_HOOKS_DIR`. It gives
  `opencv_gapi` `/DELAYLOAD` for `dxcore.dll`, `d3d12.dll`, `dxgi.dll` and
  `DirectML.dll`, the set ORT delay-loads. Without it `cv2` would fail to load
  wherever `dxcore.dll` is missing (Windows Server 2019). Only hook files may live
  in that directory: OpenCV registers every `*.cmake` in it.
- **The gate.** `Get-OpencvOrtConfigureFinding` reads the configure log,
  `CMakeCache.txt` and `build.ninja`. It stops the stage on a download line, a
  summary other than `ONNX Runtime: YES (ver <chain>)`, a cache entry naming
  `3rdparty/onnxruntime`, a `dml_ep.cpp` compile without `HAVE_ONNX_DML`, any
  `HAVE_ONNX_COREML` define, or a gapi link without the four `/DELAYLOAD`s.

What changes in the shipped bytes on every lane: `opencv_dnn500.dll` and
`opencv_gapi500.dll` compile against the 1.30 headers and need an
`onnxruntime.dll` of 1.30 or later. `dml_ep.cpp` is compiled with
`HAVE_ONNX_DML` instead of the stub that throws; no DirectML session has run
yet. On the arm64 cross lane `opencv_gapi500.dll` is the first
PE that imports `dxcore.dll`. servercore:ltsc2025 carries it (measured
2026-09-23 at the image's own OS build), so the merge stage's import walk
resolves it. A future base without it fails that walk; the fix is a measured
`-ClientOsPattern` entry, never dropping the delay-load.

## The guards

The six guards come in two orthogonal halves plus reach. **G1** judges the
shipped bytes and **G2** judges the build inputs. Neither is enough alone: G1
would pass the pre-2026-09-23 Windows OpenCV image, and G2 cannot see a
consumer nobody registered. The STAMP verdict joins them: every consumer G1 finds in an image
must carry a stamp G2 wrote against this image's chain ORT.

| Guard | What it proves | Where | What it does NOT cover |
|---|---|---|---|
| G1 ORT census | every ORT binary in the image is the chain's, byte for byte, and every importer resolves to it | Windows: `WindowsOrtProvenance.Common.psm1`, Test-Container § 25. Linux: `check-ort-provenance.sh` + `ort_census_probe.py`, smoke SHIPPED-TRUTH E ([`cross-build-verification.md` § E](cross-build-verification.md#e-ort-single-source)) | header-only provenance; files the image user cannot read; which file a `dlopen` by absolute path picks |
| G2 build gate + stamp | no foreign ORT in a consumer's tree, fetch caches, build records or logs; a pass writes the stamp | Windows: `Assert-ChainOrtOnly` in `WindowsOrtProvenance.Build.psm1`. Linux: `ort_assert_chain_only` in `linux/scripts/03-media/ort-provenance.sh` | an ORT under a non-ORT file name; what loads at run time; pip's pre-23.3 HTTP cache; on Linux the bytes in uv's cache, which is graded by where uv fetched a wheel ([§ The fetch caches G2 grades](#the-fetch-caches-g2-grades)) |
| G3 fetch-proof crate env | an `ort-sys` build in our images links the chain ORT and cannot download pyke's | `windows/Dockerfile`, `linux/Dockerfile.package`; asserted by Test-Container § 19 and the `ort-crate-env` contract row | Rust builds outside our images; a consumer that overrides the env |
| G4 static denylist | no script, Dockerfile or workflow re-arms a download, a NuGet/PyPI/apt ORT, a `download-binaries` crate or a re-arming env value; nothing deletes or patches an in-box ORT under `C:\Windows`; the G1/G2/G3 wiring stays in place | `fix11_ort_single_source_2026_09` in `linux/scripts/verify-critical-fixes.sh` (preflight slug `critical-fixes`) | an upstream bump that fetches by itself (G2/G1 catch it); names built at run time; a verb and an ORT token on different lines; `docker run -e`; a `Cargo.toml` outside this repo |
| G5 documented invariant | the next agent knows the rule | [`windows-build-invariants.md`](windows-build-invariants.md#onnx-runtime-has-exactly-one-source-the-chain-owner-rule-2026-09-23), `AGENTS.md`, this page | nothing mechanical, except that fix11 greps the invariant heading |
| G6 consumer bundle census | a shipped app carries the chain ORT of the image it was built in, and every importer finds it | `Test-OrtProvenanceTree -Root <dir>` (Windows), `check-ort-provenance.sh <dir>` (Linux) | which copy a bare host really loads beyond the modelled loader order |

G2 runs at the end of every consumer build, after the consumer's own gate and
before its tree is removed:

| Lane | Call sites | Stamp |
|---|---|---|
| Windows | `Build-OpencvFromSource.ps1`, `Build-OnnxGenaiFromSource.ps1`, `Build-FfmpegFromSource.ps1`, `Build-GstreamerFromSource.ps1`, `Build-OrtAmdgpuEpFromSource.ps1` | `C:\runtime\share\ort-provenance\<consumer>.json` |
| Linux | `build-opencv.sh` (both passes), `build-ffmpeg.sh`, `build-gstreamer-monorepo.sh`, `verify-genai-ort.sh` | `<prefix>/ort-provenance/<consumer>.json` under `/opt/opencv5`, `/opt/ffmpeg`, `/opt/gstreamer`, `/usr/local/lib/onnxruntime-genai` |

A stamp names the sha256 of the chain core library it was gated against. A
failing rerun deletes the old stamp first. G1 arms its STAMP verdict once the G2
code is present, and an image built before G2 therefore fails STAMP until its
consumer stages are rebuilt.

**The chain wheel manifest follows the wheel (Linux).** The runtime image never
holds the chain wheel, so `03-media/runtime/collect-artifacts.sh` hashes its
native members into `<prefix>/ort-provenance.sha256` for G1. The same RUN then
runs `repair-wheels.sh`, which on a cross build strips and repacks every wheel
(and natively may let auditwheel rewrite one), and the venvs install those
bytes. So `repair-wheels.sh` proves every manifest row against `/opt/wheels`
before it rewrites anything (`ort_manifest_rows check`) and re-points each row
at the rewritten wheel of the same name, platform tag aside, afterwards
(`follow`). A wheel under the chain wheel's name with other bytes, or a second
wheel of that name, platform tag aside, before or after the rewrite, stops the
media stage: the retag would rename such a twin onto the chain wheel. A wheel
the manifest never listed never enters it.

**Placement is a cache rule.** Both G2 files import or source nothing, and each
is mounted per file into exactly its consumer RUNs: `C:\bkmnt\ortmods\` on
Windows, `/opt/scripts/03-media/ort-provenance.sh` on Linux. They stay out of
the census module, out of `buildmods`, `migraphxmods`, `WindowsSourceBuild.Common`
and `Build-MediaCoreAll.ps1`, and out of `03-media/core/` and `03-media/runtime/`,
which whole images copy. Otherwise one edit would re-key five compile RUNs.
fix11 enforces the mounts.

### How G4 runs: one judging pass

fix11 reads its scan set once into a corpus (`<path>:<line>:<text>`, comment lines
dropped). The `fix11_ort_*` checks do not grep it; they QUEUE rules, and
`_f11_judge` answers every rule in one awk pass, a verdict per rule in queue order:

| Helper | Rule | FAIL names |
|---|---|---|
| `_f11_deny <what> <re> [re2 re3 not path-in path-out]` | no live line matches | the first five lines |
| `_f11_require <path> <re> <want> <what> [not]` | `N` (exactly) or `N+` (at least) lines of one file match; a `^`-path is a path ERE | the count |
| `_f11_pair <what> <re> <re-b>` | every file with a line matching `<re>` also has one matching `<re-b>` | the files |
| `_f11_count <key> <path> <re>` | no verdict: the count lands in `_F11_N[<key>]` for a bash check that runs after the pass | — |

Until 2026-09-24 each rule was its own awk run over the corpus, about 50 per gate
run. `test-critical-fixes.sh` runs fix11 once per knocked-out row, so the suite went
from 4.4 s to 45-59 s on the CI runner, and the 68 mutation entries that re-run it
pushed the preflight job past its 45-minute timeout.

**Why one pass is written the way it is.** gawk (the runner's `awk`) caches a
dynamic regex per call site and recompiles it whenever the site sees a different
one. So the judge loops rules outside and lines inside: each rule's regexes are
compiled once. `_f11_env_writes` had one `match()` site shared by seven regexes,
recompiled seven times per line: 22 s of the runner's 32 s real-tree run. Each
form now has its own site, and lines naming no ort-sys variable are skipped first.
Measured 2026-09-24 in the CI-parity container, real tree: gawk 10.1 s → 0.7 s,
mawk 1.4 s → 0.4 s.

**A pass that dies is a FAIL.** If the judge returns fewer verdicts than rules,
fix11 fails (`the judging pass broke`); otherwise a broken awk would pass every
rule it was handed.

### The fetch caches G2 grades

Every G2 call also grades the fetch caches of the machine it runs on:
`Get-OrtGateDefaultCache` on Windows, `ort_gate_default_caches` on Linux. Each
root is read at its tool's override variable, else at the tool's default.

| Cache | Windows | Linux | What fails |
|---|---|---|---|
| pyke's ORT download (`ort.pyke.io`) | under `%LOCALAPPDATA%` | under `$XDG_CACHE_HOME`, else `~/.cache` | any file |
| pip (`PIP_CACHE_DIR`) | yes | yes | an HTTP body that is a wheel with a top-level `onnxruntime/` package; a body or directory it cannot read; an ORT-named file |
| uv (`UV_CACHE_DIR`) | yes | yes | Windows: an ORT file whose bytes are not the chain's. Linux: an ORT wheel uv fetched over HTTP |
| NuGet (`NUGET_PACKAGES`) | yes | yes | an ORT-named file or archive, a `microsoft.ml.onnxruntime*` directory (GenAI's is not ORT) |
| cargo's registry and git (`CARGO_HOME`) | no | yes | the same |
| FFmpeg's SDK cache (`FFMPEG_SDK_CACHE`) | no | yes | the same |

**Linux grades uv by source, not by bytes.** There uv and pip are BuildKit
cache mounts that outlive every build, so uv's cache holds the unpacked chain
wheels of earlier builds, whose bytes are not this build's. uv records a local
wheel (`/opt/wheels`, a `--find-links` directory) with a `.rev` entry and one it
downloaded with `.http`, under `wheels-v*/<bucket>/<package>/`; only the `.http`
kind can be foreign. A PyPI ORT that any earlier build downloaded into one of
these mounts fails every later G2 call until a RUN with the same mount removes it
(`uv cache clean onnxruntime`, or the pip body the finding names). That is
fail-closed on purpose.

Not graded: ccache and sccache (object files, no ORT names) and apt's archive,
which the apt-plan and dpkg gates own. `test-ort-provenance-build.sh` fails when
any other cache mount of a Linux G2 RUN is missing from the default list. GenAI's
G2 runs in its own RUN after the build RUN, so that RUN mounts the build RUN's uv
and pip caches under the same ids; the same test fails when one is missing.

**The venv census.** `linux/scripts/03-media/runtime/ort-venv-census.py` is the
one classifier for Python environments, on both lanes. It treats as ORT every
distribution named `onnxruntime` or `onnxruntime-*` and every owner of the
`onnxruntime`, `onnxruntime_genai` or `onnxruntime_extensions` package, never a
fixed list. `--check --store DIR` requires each of them to match the store wheel
of the same name and version file by file, `onnxruntime` to have exactly one
owner, and the import to resolve to it. `Build-TorchApp.ps1` embeds a verbatim
copy, pinned by `TorchApp.OrtCensus.Tests.ps1`.

**The app `uv sync` installs no ORT.** On Windows every `onnxruntime` or
`onnxruntime-*` name in `uv.lock` goes to `--no-install-package`, and a locked
runtime or GenAI flavour with no chain wheel of its family stops the stage.
Linux skips `onnxruntime` and `onnxruntime-genai` when a chain wheel covers them.

## The in-box ONNX Runtime (Windows ML)

Windows 11 ships an ORT with the OS. This client host carries Windows ML's
`C:\Windows\System32\onnxruntime.dll` 1.17, a `SysWOW64` twin, and copies under
Edge WebView and the Windows App Runtime. The images carry none. A one-`RUN`
probe over `bk-windows-base` on 2026-09-23 (servercore:ltsc2025 at the
`WINDOWS_BASE_DIGEST` pin, OS build 26100.33438) found no `onnxruntime*`,
`Windows.AI.MachineLearning*.dll`, `Microsoft.AI.MachineLearning*.dll` or
`DirectML*.dll` anywhere on `C:\`, the VS Build Tools included. The only name
hits were vcpkg's port records `C:\vcpkg\versions\o-\onnxruntime*.json`, which
are not binaries.

Smoke § 25 asserts this on every amd64 lane, because the standard `LoadLibrary`
search puts System32 ahead of PATH: an in-box copy would take every importer
that reaches the chain ORT through PATH. The `INBOX` verdict fails on any ORT
instance under the Windows directory, and on Windows ML's API DLL, which carries
the ORT ABI under another name. No `$ortCensusExemption` entry can waive an
in-box path. The cross lane skips the assertion: the image's Windows directory
is not the device's, and G6 already assumes a client System32 copy.

If a base bump brings one, keep the previous `WINDOWS_BASE_DIGEST` in
`versions.env`. Do not exempt it, and never delete or patch files under
`C:\Windows` in a layer; fix11 refuses a script line doing so to an ORT or
Windows ML file. Staging the chain DLL beside each exe does not clear the
census today. Image mode searches
only an importer's own directory before System32, so a plugin still resolves to
the in-box copy (`UNRESOLVED`). A chain copy outside the prefix and the wheel
store is `ELSEWHERE`. The in-box file keeps its bytes verdict (`FOREIGN` for a
Windows ML build), which no exemption can waive. Admitting such a base is a
deliberate census change on three fronts: exe-directory chain copies as a
byte-checked allowed home, image mode modelling the host exes' directories, and
a decision on the in-box bytes verdict.

## Adding a new ORT consumer

1. **Build it against the chain.** Headers and import library come from
   `ONNX_ROOT` or the chain prefix. Close every fetch branch its build system has:
   a pre-set cache variable, an `ORT_HOME`, a `FETCHCONTENT_SOURCE_DIR_*` pointed at
   an empty directory, disabled CMake package lookups.
2. **Give it its own gate** when its build system has a known fetch branch, as
   OpenCV and GenAI do. Throw on any finding.
3. **Call G2 once**, after the build and before the tree is removed. Pass at
   least one log and every build record; a call without a log is a finding.
4. **Mount the G2 file per file** into that one RUN. Never widen a shared
   closure for it.
5. **Register it** in `Get-OrtConsumerContract` (Windows) or
   `ort_census_contract` (Linux), with its stamp path. Anything carrying the ORT
   ABI outside the contract is UNREGISTERED.
6. **Add its row to `F11_GATE_CALLS`** in `verify-critical-fixes.sh`. Renaming a
   gate function later means editing that table in the same change.
7. **Python:** its wheel goes into the chain store, and the census must pass.
   Never a PyPI ORT, never a prebuilt plugin-EP wheel.
8. **Run-time loading:** resolve the chain file by absolute path. A bare-name
   load on Windows reaches System32's Windows ML copy first.
9. **Licences:** a `docs/deps/deps.json` row for anything it ships beside the
   chain ORT.
10. **Mutation-test it**: a suite that goes red when its check is removed, and a
    `docs/scripts/mutations.json` entry on Linux.

## The consumer repositories

These changes sit in the consumers' working trees. Their gitlinks move only
after each repo commits and pushes, and each repo's own `AGENTS.md` and
`CHANGELOG.md` carry the detail.

- **OxidANT.** Every `onnxruntime*` feature is `ort/load-dynamic` + `api-24`,
  declared on the workspace dependency, and `download-binaries` is gone.
  `kataglyphis_inference::ort_runtime::ensure_ort_loaded()` loads an absolute
  path only, from `ORT_DYLIB_PATH`, the exe directory, `ONNX_ROOT\bin` /
  `ORT_LIB_LOCATION` or the image prefix, and refuses a file without the chain
  source-root fingerprint. `scripts/linux/check-ort-chain-only.sh` gates
  `Cargo.lock` and the resolved feature graph in its Linux lane. The Windows zip,
  MSIX and MSI ship the chain `onnxruntime.dll`, `onnxruntime_providers_shared.dll`
  and `DirectML.dll`, staged from `ONNX_ROOT\bin`; each package's payload passes
  G6 first, and counts as loading ORT when its exe or any DLL it ships does.
- **AccelerANTgine.** `cmake/SystemLibDependencies.cmake` REQUIREs ORT from one
  prefix with `NO_DEFAULT_PATH`, and stops with FATAL_ERROR unless the runtime
  library carries the chain fingerprint. Its own Windows lane stages through the
  hub's `Copy-MediaRuntimeBundle`, which is chain-only once its hub pin moves, and
  runs G6 over each staged `bin\` and over the release install tree its
  NSIS/WiX/ZIP installers pack, into which the CMake file installs the proven
  `onnxruntime.dll`; its Python package ships the chain layout only, G6-proved.
- **OmniAccelerANT.** `Build-Windows.ps1` stages the chain ORT beside the runner
  exe on every build, after the `C:\runtime\bin` glob, which no longer copies ORT,
  and stamps the runner's G6 pass. `Start-Windows.ps1` re-runs G6 on the host
  against that stamped copy, refuses an unstamped, foreign or stray runner and an
  `ORT_DYLIB_PATH` of other bytes, and no longer puts `C:\onnxruntime\lib` on PATH.
  The runner's own chain copy therefore always wins over System32's.
  `runner\Release`, the MSIX copy, is rebuilt from a proven preset on every build
  and re-proved before `msix:create`. The Linux bundle takes `libonnxruntime*`
  from a fingerprinted chain directory only, and `check-bundle-closure.sh` runs
  G6 over it whenever a file is ORT-named or names the ORT ABI. The cat-stream
  pi-bundle is G6-proved in the image run that assembles it.
- **OrchestrANT** drops its Python 3.13 test legs (owner decision 2026-09-23):
  the chain wheels are cp314 and the images carry CPython 3.14 only. The hub's
  python-ci defaults (`PY_VERSIONS`, `COVERAGE_VERSION`) moved to 3.14 with it.

Two couplings to keep in mind:

- The consumers' packaging proof is this repo's G6, so it follows a move of
  `C:\temp\onnx-src` or `/opt/onnxruntime` (`Get-OrtChainSourceRoot`,
  `ort_census_chain_roots`). Literal copies of the fingerprint remain in their
  source pickers: AccelerANTgine's CMake, OmniAccelerANT's
  `rust_builder/linux/CMakeLists.txt` and `bundle-runtime.sh`, and OxidANT's
  `ort_runtime.rs`.
- Both images bake `ORT_DYLIB_PATH` (G3). Inside an image, OxidANT treats it as
  the only candidate, so an app's own staged copy is not the one loaded there,
  and a GPU consumer must point it at `onnxruntime-gpu`.

## Not proven by a build yet

No container build has run with any of this. The first run of each lane is the
real test. The likeliest first reds, all fail-closed:

- GenAI and OpenCV's G-API DirectML EP compiling against the 1.30 headers under
  clang-cl for the first time.
- A distro package in the Linux media closure that depends on `libonnxruntime1.x`
  (Ubuntu's `gstreamer1.0-plugins-bad` does).
- A G2 false positive on a real record path; the finding names the record and
  the path.
- A PyPI ORT that an earlier build left in a Linux uv or pip cache mount, now
  that G2 grades those mounts.

## Failure messages

| You see | Where | Meaning |
|---|---|---|
| `ORT gate (<consumer>): N finding(s), the build reached an ONNX Runtime other than the chain's` | Windows, end of a consumer build | G2; each `FAIL:` line above it names a file, record path or log line |
| `ORT-GATE FAIL (<consumer>): ...`, then `ORT-GATE FAILED` | Linux, end of a consumer build | G2, same rules |
| `uv's cache holds an ONNX Runtime wheel downloaded over HTTP`, `pip's HTTP cache holds an ONNX Runtime wheel` | Linux, G2 | a PyPI ORT in a cache mount, left by this build or an earlier one: [§ The fetch caches G2 grades](#the-fetch-caches-g2-grades) |
| `ERROR: ORT wheel manifest ...: no wheel in /opt/wheels holds these bytes any more` | Linux media runtime RUN, `repair-wheels.sh` | a wheel under the chain wheel's name replaced it after `collect-artifacts.sh` hashed it |
| `ERROR: ORT wheel manifest ...: other wheels share its name, platform tag aside` | the same | a second wheel of the chain wheel's name, version and ABI is in `/opt/wheels`; the retag or auditwheel would write it over the chain wheel |
| `ERROR: ORT wheel manifest ...: not exactly one rewritten wheel of that name carries it` | the same | after the strip and retag two wheels share the chain wheel's name, or its member is gone |
| `no build record names the chain ONNX Runtime` | either lane, G2 | the consumer built without ORT at all |
| `ORT census: STAMP ...` | smoke | the consumer's layer predates G2, or ran against another ORT build: rebuild that stage |
| `FOREIGN`, `STALE`, `UNPROVEN`, `ELSEWHERE`, `UNRESOLVED`, `UNREGISTERED`, `DIST`, `NONE` | smoke § 25 / SHIPPED-TRUTH E | G1 verdicts, defined in [`cross-build-verification.md` § E](cross-build-verification.md#e-ort-single-source) |
| `INBOX` | smoke § 25, `ORT in-box` (Windows amd64) | the base image now ships an ORT in its Windows directory: [§ The in-box ONNX Runtime](#the-in-box-onnx-runtime-windows-ml) |
| `ORT-CENSUS FAIL ...` | torch stage | [`failure-modes.md`](failure-modes.md#the-torch-stage-fails-with-ort-census-fail) |
| `uv.lock pins ... has no chain wheel of that family` | Windows torch stage, before `uv sync` | the store lacks that flavour's chain wheel: a media-stage problem |
| `ERROR: chain ORT: ...` | a consumer's `uv sync` | [`python-ci.md` § Trap 3](python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi) |
| `FAIL fix11: ...` | preflight `critical-fixes` | G4 found a re-armed download or a lost wiring row |
| `<id> is an ONNX Runtime package and is refused` | `Install-OptionalNuGetPackage` | the NuGet facility is chain-only |
