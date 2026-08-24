# Qualcomm AI Engine Direct (QAIRT / "QNN") SDK drop — ONNX Runtime QNN EP (backlog #121)

This directory is the **opt-in** drop point for the Qualcomm AI Engine Direct SDK zip.
When a zip is staged here, `build-onnx-from-source.ps1` builds ONNX Runtime with the
**QNN execution provider** (`onnxruntime_USE_QNN=ON`) and stages the QNN runtime DLLs
beside `onnxruntime.dll`. When the directory holds nothing but this README, the build
skips the QNN EP with a one-line notice — no zip is the default, supported state.

## Why a manual drop

The SDK is **login-gated** (Qualcomm Package Manager / Qualcomm ID) and EULA-bound, so it
cannot be downloaded by the build. Same contract as the TensorRT zip in
`windows/downloads/`: you stage it, the build verifies and consumes it.

## How to stage

1. Download the Windows SDK from
   https://qpm.qualcomm.com/#/main/tools/details/qualcomm_ai_engine_direct
   (package "Qualcomm AI Engine Direct SDK", Windows). The archive is a zip that extracts
   to `qairt\<version>\` with `include\QNN\`, `lib\aarch64-windows-msvc\` (HTP/NPU + CPU
   backends for Windows-on-ARM) and `lib\x86_64-windows-msvc\` (CPU backend for x64).
2. Copy the zip into this directory. Exactly **one** `*.zip` may sit here; the build takes
   that one (any name).
3. Optional integrity pin: set `QNN_SDK_ZIP_SHA256` in `linux/scripts/01-core/versions.env`
   to the zip's SHA-256. When set, the build refuses a zip whose hash differs. Empty means
   "unpinned" (documented-deliberate, like `TENSORRT_ZIP_SHA256` before it was populated).

The zip is git-ignored (`windows/qnn-sdk/*` except this README) and rides into the
BuildKit context only when present — the media-core `onnx` RUN bind-mounts this directory
at `C:\temp\qnn-sdk`.

## What the build does with it

- Extracts the zip, locates the version dir (`include\QNN\QnnInterface.h` is the anchor)
  and passes it as `onnxruntime_QNN_HOME`.
- Enables `onnxruntime_USE_QNN=ON` on **both** lanes: arm64 (HTP/NPU on Snapdragon X, the
  actual point of the EP) and amd64 (CPU backend only — useful for graph-compatibility
  checks, not for speed).
- Stages the per-arch backend DLLs (`QnnHtp*.dll`, `QnnCpu.dll`, `QnnSystem.dll`, …) plus
  the `hexagon-v*` skel directories beside `onnxruntime.dll`, so a target host finds them
  on the DLL search path without any extra `PATH` surgery.

Scaffold status: the plumbing is exercised only when a zip is present. The host that
built this repo has never held the SDK, so the QNN branch is **unproven** — the first
staged zip will tell. See `docs/windows-cross-builds.md` (QNN section) and backlog #121 in
`docs/windows-builds.md`.
