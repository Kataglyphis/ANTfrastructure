# Qualcomm AI Runtime (QAIRT / "QNN") SDK drop — Windows, optional override

Since 2026-11-05 the Windows lane needs nothing here: `Resolve-QnnSdk` fetches the public
"Qualcomm AI Runtime Community" zip pinned in `versions.env` (`QNN_SDK_VERSION`,
`QNN_SDK_ZIP_SHA256`, one pin for both lanes) into the `qnn-sdk-winamd64` cache mount the
four QNN RUNs of `Dockerfile.media-builder` carry, and builds ONNX Runtime with the QNN
execution provider from it. `docs/windows-cross-builds.md` § QNN execution provider has the
mechanism; `docs/qnn-linux.md` § Staging the licence note and the bump path. This directory
is the override:

1. Exactly **one** `*.zip` here is used instead of the download (an offline copy, or a build
   host without upstream access). It must match `QNN_SDK_ZIP_SHA256`; a different SDK is a
   re-pin of both keys in the same commit.
2. `QNN_SDK_SOURCE=drop` in the RUN's environment restores the pre-2026-11-05 contract: no
   zip here, no QNN.

The zip is git-ignored (`windows/qnn-sdk/*` except this README) and rides into the
BuildKit context only when present — the media-core `onnx` and `genai` RUNs and the
`litert` and `tvm` RUNs bind-mount this directory at `C:\temp\qnn-sdk`.

## What the build does with it

- Extracts the zip, locates the version dir (`include\QNN\QnnInterface.h` is the anchor)
  and passes it as `onnxruntime_QNN_HOME`.
- Enables `onnxruntime_USE_QNN=ON` on **both** lanes: arm64 (HTP/NPU on Snapdragon X, the
  actual point of the EP) and amd64 (CPU backend only — useful for graph-compatibility
  checks, not for speed).
- Stages the per-arch backend DLLs (`QnnHtp*.dll`, `QnnCpu.dll`, `QnnSystem.dll`, …) plus
  the `hexagon-v*` skel directories beside `onnxruntime.dll`, so a target host finds them
  on the DLL search path without any extra `PATH` surgery.

Status: **BUILD-TIME PATH PROVEN 2026-08-31** — the staged zip
(`qairt-2.44.0.260225`, SHA-pinned) was exercised by a full `:winarm64` cross
chain: ONNX built the QNN provider with the `aarch64-windows-msvc` backend set,
and the backend DLLs were staged beside all five frameworks (arch gate
1168/0, import walk 0 unresolved, smoke 97/0/15). Execution on a Snapdragon
device is still the standing open item. See `docs/windows-cross-builds.md`
(QNN section) and backlog #121 in `docs/windows-refactor-backlog.md`.
