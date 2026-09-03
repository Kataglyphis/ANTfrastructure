<!-- QNN-LINUX: the Qualcomm QAIRT/QNN lane on Linux. -->

# QNN on Linux (QAIRT)

arm64-only, and **opt-in**: the lane is off unless a QAIRT SDK zip is staged in
`linux/qnn-sdk/`. With no zip the build is byte-identical to a QNN-less build on
every arch. See `linux/qnn-sdk/README.md` for the staging discipline.

## Staging

The zip is login-gated (qpm.qualcomm.com, Qualcomm ID + EULA). Drop exactly one
`*.zip` in `linux/qnn-sdk/`; `Dockerfile.media` bind-mounts that directory at
`/opt/scripts/qnn-sdk` on every heavy RUN.

`QNN_SDK_LINUX_ZIP_SHA256` in `versions.env` is populated with the
**v2.49.0.260730** hash, so re-staging that exact version needs **no re-pin** —
the existing hash validates it and a mismatch means a different build was
downloaded. Only a newer SDK needs `sha256sum <zip>` plus a `versions.env` update
in the same commit.

`resolve_qnn_sdk` (`01-core/qnn-sdk.sh`) verifies the hash, extracts, and asserts
three canaries: the `include/QNN/QnnInterface.h` anchor, `libQnnCpu.so` under
`lib/${QNN_SDK_LINUX_LIBDIR}` (default `aarch64-oe-linux-gcc11.2`), and
`QNN_OP_STFT` in `QnnOpDef.h` — the QNN API 2.25+ marker ORT 1.29 needs.

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
2.47.0.260601 from softwarecenter.qualcomm.com — **no `EXPECTED_HASH`, no
`STATUS` check**, and *not* gated on `LITERT_ENABLE_QUALCOMM`, so it fires even
on builds that want no NPU.

It cannot be dodged with a stub path: any non-empty `QAIRT_HEADERS_DIR`
force-enables Qualcomm (`:331-334`) with headers we do not have. So
`_litert_disable_qairt_header_download` patches the guard itself to `if(FALSE)`.
The patch is idempotent and fails loudly if the anchor moves.

MediaTek's NeuroPilot fetch (AWS S3) and the Samsung LiteCore fetch *are* dodged
with stub header dirs — both gate on the header EXISTING, so a stub is safe.

> **Still open — backlog YA:** this guard is unreachable from the **android**
> LiteRT lane, which builds its own tree via `android-dispatch.sh` and still
> pulls the unverified 2.47.0.260601 on every build.

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
