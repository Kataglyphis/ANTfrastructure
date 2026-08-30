# Qualcomm AI Engine Direct (QAIRT / "QNN") SDK drop — Linux ARM64 (backlog QNN-LINUX)

This directory is the **opt-in** drop point for the Qualcomm AI Engine Direct SDK
zip on the **Linux ARM64** lane. When a zip is staged here, the ONNX Runtime QNN
execution provider is built for `aarch64` (`onnxruntime_USE_QNN=ON`), and the QNN
runtime shared libraries are staged beside the ORT install. When the directory
holds nothing but this README, the build skips the QNN EP with a one-line notice
— no zip is the default, supported state. Mirrors `windows/qnn-sdk/` (#121) with
the same contract, different SDK.

## Why a manual drop

The SDK is **login-gated** (Qualcomm Package Manager / Qualcomm ID) and
EULA-bound, so it cannot be downloaded by the build. Same contract as the
TensorRT zip in `windows/downloads/`: you stage it, the build verifies and
consumes it.

## Which SDK to stage (Linux, not the Windows one)

The Windows lane stages the **Windows** SDK (`lib\aarch64-windows-msvc\`). The
Linux lane needs the **Linux AArch64** SDK, a different download:

1. Download the Linux SDK from
   https://qpm.qualcomm.com/#/main/tools/details/qualcomm_ai_engine_direct
   (package "Qualcomm AI Engine Direct SDK", Linux). The archive extracts to
   `qairt/<version>/` with `include/QNN/` and `lib/aarch64-oe-linux-gcc11.2/`
   (HTP/NPU + CPU backends for Linux-on-AArch64). This lib dir name — not
   `aarch64-windows-msvc` — is what the Linux resolve helper must anchor on.
2. Copy the zip into this directory. Exactly **one** `*.zip` may sit here; the
   build takes that one (any name).
3. Integrity pin: a `QNN_SDK_LINUX_ZIP_SHA256` key in
   `linux/scripts/01-core/versions.env` (planned, backlog QNN-LINUX work item
   #2) holds the zip's SHA-256. When set, the build refuses a zip whose hash
   differs; empty means "unpinned" (documented-deliberate, like
   `TENSORRT_ZIP_SHA256` before it was populated). The existing
   `QNN_SDK_ZIP_SHA256` is the **Windows** zip hash — do not reuse it for Linux.

The zip is git-ignored (`linux/qnn-sdk/*` except this README). It rides into the
BuildKit context only when present — the media `onnxruntime` RUN will
bind-mount this directory at `/opt/scripts/qnn-sdk`. NB: the root
`.dockerignore` does not exclude `linux/qnn-sdk/`, so a staged zip is uploaded
in the context for every stage build that shares the root context (base,
compiler, sdk, media, …). Stage the zip immediately before a media rebuild and
remove it after, the same discipline as the TensorRT zip.

## What the build does with it

- Extracts the zip, anchors the SDK root on `include/QNN/QnnInterface.h`, and
  passes it as `onnxruntime_QNN_HOME` via `--cmake_extra_defines`.
- Enable `onnxruntime_USE_QNN=ON` on the **arm64** lane (HTP/NPU on Snapdragon,
  the actual point of the EP). amd64/riscv64 stay QNN-off.
- Stage the backend shared libraries (`libQnnHtp.so`, `libQnnCpu.so`,
  `libQnnSystem.so`, …) plus the `hexagon-v*` skel directories beside the ORT
  install, so a target host finds them on `LD_LIBRARY_PATH` without extra setup.
- `validate-media-runtime.sh` already skips `libQnn*` ELF arch checks
  (`VENDOR_ARCH_SKIP_PATTERNS`), so the foreign-arch vendor libs ship as-is.

Build status: the ORT QNN wiring is LANDED (resolve helper, build script,
Dockerfile mount, versions.env pin, artifact verification — see
`docs/refactoring-backlog.md` A2. QNN-LINUX, items 1-6 DONE). No SDK has been
staged on this host, so the QNN branch is **unproven** — the first staged zip
will validate it (upstream risk: ORT CMake `onnxruntime_QNN_HOME` may hardcode
`aarch64-android` ABI; verify on first use). Framework fan-out to LiteRT, TVM
and IREE is OPEN. See `docs/refactoring-backlog.md` (QNN-LINUX) and
`docs/windows-cross-builds.md` (QNN section, #121) for the cross-lane plan.
