# Qualcomm AI Runtime (QAIRT / "QNN") SDK drop — Linux ARM64, optional override

Since 2026-11-05 the Linux arm64 lane needs nothing here: `resolve_qnn_sdk` fetches the public
"Qualcomm AI Runtime Community" zip pinned in `versions.env` (`QNN_SDK_VERSION`,
`QNN_SDK_ZIP_SHA256`) through the asset mirror; `docs/qnn-linux.md` § Staging has the
mechanism, the licence note and the bump path. This directory is the override:

1. Exactly **one** `*.zip` here is used instead of the download (an offline copy, or a build
   host without mirror and upstream access). It must match `QNN_SDK_ZIP_SHA256`; a
   different SDK is a re-pin of both keys in the same commit.
2. `QNN_SDK_SOURCE=drop` restores the pre-2026-11-05 contract: no zip here, no QNN.
3. The Windows lane does the same with the same zip and the same pin (`windows/qnn-sdk/README.md`).
4. If a newer SDK renames the lib subdirectory, `QNN_SDK_LINUX_LIBDIR`
   (env override only — NOT a versions.env key; `qnn-sdk.sh` defaults it with
   `:=` to `aarch64-oe-linux-gcc11.2`) is the
   single knob — `resolve_qnn_sdk` anchors its `libQnnCpu.so` presence check on
   it, so a wrong value fails loudly rather than silently shipping no backend.

The zip is git-ignored (`linux/qnn-sdk/*` except this README). It rides into the
BuildKit context only when present — five media RUNs (ORT cpu, ORT genai,
LiteRT, TVM, app-wheelhouse) bind-mount this directory at `/opt/scripts/qnn-sdk`.
NB: the root `.dockerignore` excludes only `linux/qnn-sdk/*.md`, so a staged zip is uploaded
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
  (HTP/NPU on Snapdragon, the actual point of the EP): Qualcomm's plugin QNN EP for ONNX Runtime,
  built from its pinned fork (`docs/qnn-linux.md#the-plugin-ep`; the in-tree EP left the ORT build on 2026-11-08).
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
— see `docs/refactoring-backlog-archive-2026-09-03.md` § A2. QNN-LINUX). Staged
QAIRT v2.49.0.260730: `cross-media-arm64` build GREEN,
`libonnxruntime_providers_qnn.so` compiled and linked, 45 `libQnn*.so` backend
libs + 7 `hexagon-v*` skel dirs staged, `verify-media-artifacts.sh
onnxruntime-cpu` PASS. The upstream `QNN_ARCH_ABI` risk is RESOLVED — ORT CMake
defaults it to `aarch64-android` on Linux aarch64, but it is a cache var
guarded by `if(NOT QNN_ARCH_ABI)` (cmake/CMakeLists.txt:921), so
`-DQNN_ARCH_ABI=aarch64-oe-linux-gcc11.2` overrides it; no source patch
needed. Framework fan-out (GenAI/LiteRT/TVM/IREE) is WIRED 2026-08-30 —
fail-safe by construction (no zip = byte-identical) — and the validation build
with the zip staged ran on 2026-09-03; its results and the `QAIRT_HEADERS_DIR`
defect it found are in `docs/qnn-linux.md`. See `docs/windows-cross-builds.md`
(QNN section, #121) for the Windows lane.
