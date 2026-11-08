<!-- QNN-LINUX: the Qualcomm QAIRT/QNN lane on Linux. -->

# QNN on Linux (QAIRT)

arm64-only, and **on by default since 2026-11-05**: the media stage fetches the public
"Qualcomm AI Runtime Community" zip at `QNN_SDK_VERSION` (`versions.env`) through the asset
mirror, verified against `QNN_SDK_ZIP_SHA256`. **Since 2026-11-08 the EP is Qualcomm's plugin
EP, built from its pinned fork ([The plugin EP](#the-plugin-ep)); the ORT CPU build carries no
in-tree QNN EP any more (owner decision, BACKLOG CON232).** A zip staged in `linux/qnn-sdk/` is used
instead of the download; `QNN_SDK_SOURCE=drop` restores the pre-2026-11-05 contract, where only
a staged zip turns the lane on. amd64 and riscv64 stay QNN-less on every path. The Windows lane
follows the same contract with the same zip and pin.

## Staging

Nothing to stage: `resolve_qnn_sdk` (`01-core/qnn-sdk.sh`, loaded by `media_common_init`)
downloads `softwarecenter.qualcomm.com/.../Qualcomm_AI_Runtime_Community/All/<v>/v<v>.zip`
with `download_verified_file` (asset mirror first, `QNN_SDK_ZIP_SHA256` the only gate) into
the `qnn-sdk-<arch>` cache mount every QNN-resolving media RUN carries
(`/var/cache/qnn-sdk`, `QNN_SDK_CACHE_DIR`), once per chain. The zip is ~3 GB; it never lands in
a layer. The Community zip carries every target (`aarch64-oe-linux-gcc11.2`, the Windows
`aarch64-windows-msvc`, android, the hexagon skels), so one pin serves both lanes.

The pin moves with `bump_versions.py` `spec_qnn_sdk` (the sweep `renovate-local.sh` runs):
Qualcomm's software center lists no versions, so the pin follows the zip LiteRT main builds
against (`third_party/qairt/workspace.bzl`), refuses one the center does not serve, and moves
the sha with the version; the Windows lane fetches the same zip under the same pin
([windows-cross-builds.md](windows-cross-builds.md#qnn-execution-provider-121-2026-08-24-sdk-staged--multi-framework-2026-08-29)) ([dependency-updates.md](dependency-updates.md#the-sweep-rides-the-renovate-call)).

**Licence.** The Community zip's `LICENSE.pdf` grants distribution of the Software "solely in
object code format" as part of a product and "not on a standalone basis". The arm64 image ships
only the backend `.so` files beside ORT, as the hand-staged zip did; the zip itself stays in the
cache mount. The row in `docs/third-party-licenses.md` carries `LicenseRef-Proprietary-EULA`,
TensorRT's class.

A zip in `linux/qnn-sdk/` (exactly one `*.zip`) is used instead of the download and must match
the same pin: it is an offline copy, not a way to ship other bytes. Re-pin for a different SDK
(`sha256sum <zip>` into `QNN_SDK_ZIP_SHA256`, `QNN_SDK_VERSION` to match) in the same commit.

`resolve_qnn_sdk` (`01-core/qnn-sdk.sh`) verifies the hash, extracts, and asserts
three canaries: the `include/QNN/QnnInterface.h` anchor, `libQnnCpu.so` under
`lib/${QNN_SDK_LINUX_LIBDIR}` (default `aarch64-oe-linux-gcc11.2`), and
`QNN_OP_STFT` in `QnnOpDef.h` — the QNN API 2.25+ marker ORT has needed since
1.29.

Staging and the CPU artifact verifier share the shallow regular-library query in
`qnn-sdk.sh`. Staging keeps its `*.so*` pattern; verification keeps `libQnn*.so`.
Nested files and symlinks do not satisfy that query. The verifier imports the
canonical helper only after detecting a QNN provider. That RUN carries a fresh,
readonly `qnn-sdk.sh` mount at `/opt/scripts/01-core/qnn-sdk.sh`; a missing export
or failed selected import fails verification. Offline fixtures test path and
failure behavior, not QNN execution on hardware.

<a id="qairt_headers_dir"></a>
## The plugin EP

Qualcomm develops the QNN EP in [onnxruntime/onnxruntime-qnn](https://github.com/onnxruntime/onnxruntime-qnn),
a fork of ONNX Runtime that builds only the plugin library and ships monthly (2.5.0 in August,
2.7.0 in October 2026: new operators, QDQ fusions, `prepare_and_load`). The in-tree "Provider
Bridge EP" still ships upstream but gets none of that. We build the fork, never its wheels or
archives (the single-source rule counts a plugin EP as ORT, and the Python 3.11 to 3.14 wheels
would not fit the image's 3.15 anyway).

- **Pins.** `ORT_QNN_EP_VERSION` (the fork's tag) and `ORT_QNN_EP_SOURCE_SHA256` (its tag tarball) in
  `versions.env`, bumped by hand together. The fork's `cmake/deps.txt` keeps upstream's SHA1 pins, as
  the in-tree ORT build's does; one of them, `ort_core`, is microsoft/onnxruntime's source at the
  version the fork was developed against (1.29.0 for 2.7.0), fetched for the EP's internal headers.
  It does not have to match the chain's ORT: compatibility is the plugin ABI (`MIN_ORT_API_VERSION`
  24, ORT ≥ 1.24.1), and the chain's 1.31 is what loads it.
- **Build** (`03-media/build/onnxruntime/build/36-build-qnn-plugin-ep.sh`, the GPU RUN of
  `Dockerfile.media`, arm64 only; other arches leave the empty tree the merge stage COPYs). The fork's
  `tools/ci_build/build.py` runs twice, `--update` then `--build`, with `--use_qnn --qnn_home <QAIRT>
  --ort_home <shim>`: `--ort_home` makes `cmake/external/onnxruntime_prebuilt.cmake` skip building ORT
  core. The shim (`qnnep_ort_home`) carries the chain's library under the names the fork's copy step
  expects (`libonnxruntime.so.<ort_core version>` included, links into `/usr/local/lib/onnxruntime-cpu`)
  and, filled between the two steps, the public headers of the fork's own `ort_core` laid out flat as a
  release package has them (`qnnep_ort_home_headers`): the EP's source uses types of the ORT it was
  developed against (`Ort::Experimental::EpContextConfig` in 1.29) and does not compile against 1.31's
  headers. Compiling against its own version's headers and loading into the chain's newer runtime is
  the plugin ABI working as designed. Three traps: the fork's `tools/python/util` imports a helper it
  no longer ships whenever `torch` is importable, so build.py runs under `python -S`; a rerun in a dirty
  build dir fails the `ort_core` patch step, so the work dir is fresh every time; and the header set
  includes a `.inc` file, so every file of the three public dirs is linked, not only `*.h`. The fork's prebuilt step
  also copies `--ort_home`'s library into its build dir, so the "no ORT core of its own" check compares bytes with the
  chain's library instead of refusing the name (the first arm64 proof chain tripped on those copies).
- **Output.** `/usr/local/lib/onnxruntime-ep-qnn/lib/libonnxruntime_providers_qnn.so` with the QAIRT
  backends (`libQnn*.so`, the HTP skels) staged beside it by `stage_qnn_runtime`, `licenses/`
  (the fork's MIT text and ThirdPartyNotices, QAIRT's licence) and `provenance.txt` (tag, source
  sha256, QAIRT version). `ORT_QNN_EP_ROOT` names the root on arm64 and is empty elsewhere
  (`Dockerfile.package`).
- **Gates.** `verify-media-artifacts.sh onnxruntime-ep-qnn` (both exports, the HTP backend, the
  texts; a missing plugin fails arm64 and skips the others); `onnxruntime-cpu` fails a provider in
  the CPU prefix; the module's NEEDED set must be the chain's, QAIRT's or the C/C++ runtime
  (`qnnep_verify_library`, `ldd` cannot run a cross-built module); the plugin root is a census REF and its two build roots (the fork source under the work dir, the fetched
  `ort_core`) are census chain roots, since the census reads the build root out of the module's own strings
  ([single-source rule](onnxruntime-single-source.md#a-plugin-ep-built-from-an-ort-fork-is-a-chain-root));
  the wrapper's runtime probe (`check-gpu-runtime.sh`, `accel_qnn_plugin_verdict`) wants the root,
  the module, its exports and backends on arm64 and none of it elsewhere.
- **Using it.** Register once per process, select the device, pass plain options:
  `ort.register_execution_provider_library("QNNExecutionProvider", f"{root}/lib/libonnxruntime_providers_qnn.so")`,
  `so.add_provider_for_devices([d for d in ort.get_ep_devices() if d.ep_name == "QNNExecutionProvider"], {"backend_type": "htp"})`;
  run options carry the `qnn.` prefix. The consumer move is CON231 step 2's code path, shared with
  the MIGraphX plugin ([contract](consumer-image-contract.md#qualcomms-plugin-qnn-ep)).
- **GenAI** no longer inherits a QNN EP (it loaded ORT's in-tree provider); GenAI on the Hexagon is a
  separate question, not a regression anyone measured.
- **Not proven on hardware**, as the in-tree EP never was: there is no Linux Qualcomm device in the
  fleet. The Windows arm64 bundle makes the same move in `Build-OrtQnnEpFromSource.ps1`.

## `QAIRT_HEADERS_DIR` — the trap that cost a build

**Pass the directory that directly HOLDS `Qnn*.h`, i.e. `<sdk>/include/QNN` —
not `<sdk>/include`.**

Upstream's cache variable documents itself as *"Path to pre-downloaded QAIRT/QNN
headers (root containing Qnn\*.h)"* (`litert/vendors/CMakeLists.txt:20`), and
LiteRT's own vendor code includes it **bare**:

```c
#include "QnnLog.h"  // from @qairt        <- litert/vendors/qualcomm/core/common.h:13
```

It is easy to believe the include root works, because upstream *does* contain a
probe that tries `<dir>` and then `<dir>/QNN`:

```cmake
if(NOT QAIRT_HEADERS_DIR)          # :61
  ...
  foreach(_cand IN LISTS _qnn_candidates)          # :86
    if(_cand AND EXISTS "${_cand}/QnnCommon.h")
      set(QAIRT_HEADERS_DIR "${_cand}")
    elseif(_cand AND EXISTS "${_cand}/QNN/QnnCommon.h")
      set(QAIRT_HEADERS_DIR "${_cand}/QNN")        # :91
    endif()
  endforeach()
endif()                                            # :96
```

**That probe is inside `if(NOT QAIRT_HEADERS_DIR)`.** It only ever runs on the
path where upstream downloads the SDK itself. When we set the variable from the
outside — the whole point of staging our own SDK — the block is skipped and the
value is consumed verbatim at `:268`. There is no `/QNN` fallback.

Symptom when it is wrong, ~7 minutes into the LiteRT build:

```
litert/vendors/qualcomm/core/common.h:13:10: fatal error: QnnLog.h: No such file or directory
gmake[2]: *** [vendors/qualcomm/core/CMakeFiles/qnn_common.dir/build.make:79] Error 1
```

`_litert_qairt_include_dir` (`03-media/build/litert/build-litert.sh`) now builds
the path once for both the configure path and the wheel path, and **asserts
`QnnLog.h` is really there** before handing it to CMake — so a future SDK layout
change fails immediately with a clear message instead of deep inside a compile.

## The Hexagon skeletons are DSP payload

`qnn-sdk.sh` stages the backend `.so` files and the `hexagon-v<nn>/` skeleton dirs into the
ORT tree. The skeletons are Hexagon (QDSP6, ELF machine 164) objects the HTP backend uploads to
the DSP; the image's own loader never maps them. The runtime-image smoke's tree-arch gate
therefore skips `hexagon-v<nn>/` dirs, as it skips a cross toolchain's target payload, and names
a QDSP6 object anywhere else (`tree-arch.hexagon-skels-are-dsp-payload`,
`tree-arch.hexagon-filter-is-narrow`). The 2026-11-06 arm64 smoke found 107 of them under
`onnxruntime-cpu/lib/` before the filter existed.

## No staged SDK: upstream's unhashed 1.5 GB download

When `QAIRT_HEADERS_DIR` is empty, upstream `file(DOWNLOAD)`s QAIRT
2.50.0.260828 (LiteRT v2.3.0's `litert/vendors/CMakeLists.txt`) from softwarecenter.qualcomm.com — **no `EXPECTED_HASH`, no
`STATUS` check**, and *not* gated on `LITERT_ENABLE_QUALCOMM`, so it fires even
on builds that want no NPU.

It cannot be dodged with a stub path: any non-empty `QAIRT_HEADERS_DIR`
force-enables Qualcomm (`:331-334`) with headers we do not have. So
`_litert_disable_qairt_header_download` patches the guard itself to `if(FALSE)`.
The patch is idempotent and fails loudly if the anchor moves.

MediaTek's NeuroPilot fetch (AWS S3) and the Samsung LiteCore fetch *are* dodged
with stub header dirs — both gate on the header EXISTING, so a stub is safe.

The guard lives in `03-media/build/litert/android/litert-qairt-guard.sh` and is
sourced by **both** lanes. It has to be: the android lane clones its own tree, so
the cross lane's patched copy cannot cover it — which is exactly how it went
unnoticed until 2026-09-03 (backlog YA). It sits under `android/` because
`Dockerfile.android` COPYs only that directory, the same constraint that put
`litert-eigen-fetch.sh` there.

The android lane can never have a staged SDK anyway: the only zip this repo takes
is the **Linux** `aarch64-oe-linux-gcc11.2` build, the wrong ABI for android. So
its `QAIRT_HEADERS_DIR` is always empty and the download always fired — the
android build even carries a retry loop written around that download truncating
mid-transfer, which was the symptom without the cause.

## What is real, and what was invented

Windows #154 established that `TFLITE_ENABLE_QNN`, `USE_QNN` and
`IREE_TARGET_BACKEND_QNN` are **not upstream options**. CMake drops an undeclared
`-D` silently and exits 0, so all three logged success and did nothing. TVM and
IREE have no Qualcomm path at all.

| framework | real switch | state |
|---|---|---|
| onnxruntime | `onnxruntime_USE_QNN` | real, validated |
| LiteRT | `LITERT_ENABLE_QUALCOMM`, auto-forced by `QAIRT_HEADERS_DIR` | real, validated |
| TVM | — | no Qualcomm path; flag removed |
| IREE | — | no Qualcomm path; flag removed |

## Validation, 2026-09-03 (media-arm64, real v2.49.0.260730 staged)

* `QNN: SDK zip SHA256 verified (QNN_SDK_ZIP_SHA256)` — the existing pin
  validated the staged zip; no re-pin was needed.
* ORT: `Built target onnxruntime_providers_qnn` →
  `libonnxruntime_providers_qnn.so` linked.
* **The staged libs land.** 45 `libQnn*.so` were copied into
  `onnxruntime/capi` and into the wheel — the full backend set: HTP stubs for
  V68/V69/V73/V75/V79/V81, LPAI, DSP, GPU, `libQnnSystem.so`,
  `libQnnSaver.so`, and `libQnnTFLiteDelegate.so` on the LiteRT side.
* LiteRT: `Qualcomm dispatch ON`, with `LITERT_ENABLE_NPU=ON`.
* **First run FAILED** at `qnn_common` on the `QAIRT_HEADERS_DIR` trap above —
  which is exactly what this validation existed to find. Fixed, then re-run.
