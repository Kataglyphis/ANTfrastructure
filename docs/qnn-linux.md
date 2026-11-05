<!-- QNN-LINUX: the Qualcomm QAIRT/QNN lane on Linux. -->

# QNN on Linux (QAIRT)

arm64-only, and **on by default since 2026-11-05**: the media stage fetches the public
"Qualcomm AI Runtime Community" zip at `QNN_SDK_VERSION` (`versions.env`) through the asset
mirror, verified against `QNN_SDK_LINUX_ZIP_SHA256`. A zip staged in `linux/qnn-sdk/` is used
instead of the download; `QNN_SDK_SOURCE=drop` restores the pre-2026-11-05 contract, where only
a staged zip turns the lane on. amd64 and riscv64 stay QNN-less on every path.

## Staging

Nothing to stage: `resolve_qnn_sdk` (`01-core/qnn-sdk.sh`, loaded by `media_common_init`)
downloads `softwarecenter.qualcomm.com/.../Qualcomm_AI_Runtime_Community/All/<v>/v<v>.zip`
with `download_verified_file` (asset mirror first, `QNN_SDK_LINUX_ZIP_SHA256` the only gate) into
the `qnn-sdk-<arch>` cache mount every QNN-resolving media RUN carries
(`/var/cache/qnn-sdk`, `QNN_SDK_CACHE_DIR`), once per chain. The zip is ~3 GB; it never lands in
a layer. The Community zip carries every target (`aarch64-oe-linux-gcc11.2`, the Windows
`aarch64-windows-msvc`, android, the hexagon skels); the Windows lane still stages its own
login-gated zip by hand (`windows/qnn-sdk/README.md`).

The pin moves with `bump_versions.py` `spec_qnn_sdk` (the sweep `renovate-local.sh` runs):
Qualcomm's software center lists no versions, so the pin follows the zip LiteRT main builds
against (`third_party/qairt/workspace.bzl`), refuses one the center does not serve, and moves
the sha with the version ([dependency-updates.md](dependency-updates.md#the-sweep-rides-the-renovate-call)).

**Licence.** The Community zip's `LICENSE.pdf` grants distribution of the Software "solely in
object code format" as part of a product and "not on a standalone basis". The arm64 image ships
only the backend `.so` files beside ORT, as the hand-staged zip did; the zip itself stays in the
cache mount. The row in `docs/third-party-licenses.md` carries `LicenseRef-Proprietary-EULA`,
TensorRT's class.

A zip in `linux/qnn-sdk/` (exactly one `*.zip`) is used instead of the download and must match
the same pin: it is an offline copy, not a way to ship other bytes. Re-pin for a different SDK
(`sha256sum <zip>` into `QNN_SDK_LINUX_ZIP_SHA256`, `QNN_SDK_VERSION` to match) in the same commit.

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

* `QNN: SDK zip SHA256 verified (QNN_SDK_LINUX_ZIP_SHA256)` — the existing pin
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
