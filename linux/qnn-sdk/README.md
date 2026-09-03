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
3. Integrity pin: the `QNN_SDK_LINUX_ZIP_SHA256` key in
   `linux/scripts/01-core/versions.env` holds the zip's SHA-256. This is
   IMPLEMENTED and already POPULATED (`resolve_qnn_sdk` in
   `01-core/qnn-sdk.sh` verifies it before extracting; a mismatch is a hard
   `err`, an empty value extracts with a WARN). The pinned value is the hash of
   the **QAIRT v2.49.0.260730** zip proven on 2026-08-30, so:
   - re-staging that same version needs **no re-pin** — the existing hash
     validates it, and a mismatch means you downloaded a different build;
   - staging a *newer* SDK requires recomputing the pin
     (`sha256sum <zip>`) and updating that key in the same commit.
   The existing `QNN_SDK_ZIP_SHA256` is the **Windows** zip hash — do not reuse
   it for Linux.
4. If a newer SDK renames the lib subdirectory, `QNN_SDK_LINUX_LIBDIR`
   (env override only — NOT a versions.env key; `qnn-sdk.sh` defaults it with
   `:=` to `aarch64-oe-linux-gcc11.2`) is the
   single knob — `resolve_qnn_sdk` anchors its `libQnnCpu.so` presence check on
   it, so a wrong value fails loudly rather than silently shipping no backend.

The zip is git-ignored (`linux/qnn-sdk/*` except this README). It rides into the
BuildKit context only when present — the media `onnxruntime` RUN will
bind-mount this directory at `/opt/scripts/qnn-sdk`. NB: the root
`.dockerignore` does not exclude `linux/qnn-sdk/`, so a staged zip is uploaded
in the context for every stage build that shares the root context (base,
compiler, sdk, media, …). Stage the zip immediately before a media rebuild and
remove it after, the same discipline as the TensorRT zip.

## What the build does with it

- Extracts the zip, anchors the SDK root on `include/QNN/QnnInterface.h` (shared
  resolver `resolve_qnn_sdk` in `01-core/qnn-sdk.sh`, loaded by
  `media_common_init`), and passes it to each framework as `QNN_HOME` /
  `onnxruntime_QNN_HOME` via cmake flags — mirroring the Windows lane's #121
  wiring exactly.
- Enable the QNN target on the **arm64** lane for all five consumers
  (HTP/NPU on Snapdragon, the actual point of the EP): ONNX Runtime
  (`onnxruntime_USE_QNN=ON`) and ONNX Runtime GenAI (inherits ORT at runtime).
  LiteRT gets `QAIRT_HEADERS_DIR=<root>/include/QNN` — the dir HOLDING
  `Qnn*.h`, not the include root; see `docs/qnn-linux.md` — which auto-enables
  `LITERT_ENABLE_QUALCOMM`. TVM and IREE get NOTHING: they have no Qualcomm path
  upstream, and the flags this README used to list (`USE_QNN`,
  `IREE_TARGET_BACKEND_QNN`, and LiteRT's `TFLITE_ENABLE_QNN`) were invented —
  CMake dropped them silently. Corrected 2026-08-31; see Windows backlog #154.
  They still get the runtime staged beside them, which only ORT loads.
  amd64/riscv64 stay QNN-off.
- Stage the backend shared libraries (`libQnnHtp.so`, `libQnnCpu.so`,
  `libQnnSystem.so`, …) plus the `hexagon-v*` skel directories beside each
  framework's install (`stage_qnn_runtime`), so a target host finds them on
  `LD_LIBRARY_PATH` without extra setup. IREE is wheel-only on this lane — no
  install dir to stage beside.
- `validate-media-runtime.sh` already skips `libQnn*` ELF arch checks
  (`VENDOR_ARCH_SKIP_PATTERNS`), so the foreign-arch vendor libs ship as-is.
- All of it is gated on the zip: no zip = today's behavior byte-for-byte on
  every arch.

Build status: the ORT QNN wiring is LANDED and **PROVEN 2026-08-30** (resolve
helper, build script, Dockerfile mount, versions.env pin, artifact verification
— see `docs/refactoring-backlog.md` A2. QNN-LINUX, items 1-6 DONE). Staged
QAIRT v2.49.0.260730: `cross-media-arm64` build GREEN,
`libonnxruntime_providers_qnn.so` compiled and linked, 45 `libQnn*.so` backend
libs + 7 `hexagon-v*` skel dirs staged, `verify-media-artifacts.sh
onnxruntime-cpu` PASS. The upstream `QNN_ARCH_ABI` risk is RESOLVED — ORT CMake
defaults it to `aarch64-android` on Linux aarch64, but it is a cache var
guarded by `if(NOT QNN_ARCH_ABI)` (cmake/CMakeLists.txt:921), so
`-DQNN_ARCH_ABI=aarch64-oe-linux-gcc11.2` overrides it; no source patch
needed. Framework fan-out (GenAI/LiteRT/TVM/IREE) is WIRED 2026-08-30 —
fail-safe by construction (no zip = byte-identical), validation build with the
zip staged still PENDING. See `docs/refactoring-backlog.md` (QNN-LINUX) and
`docs/windows-cross-builds.md` (QNN section, #121) for the cross-lane plan.
