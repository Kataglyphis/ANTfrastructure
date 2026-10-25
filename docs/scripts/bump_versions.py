#!/usr/bin/env python3
"""Refresh the versions.env keys Renovate does not own, with the *_SHA256/*_COMMIT pins a bump drags along.

After --write: sync_versions.py --write, verify-arg-consistency.sh, preflight.sh (AGENTS.md § Version Bumping).
"""
from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

type Spec = Callable[[str], tuple[str, dict[str, str]]]

# Run as a script this file is __main__; alias it so the spec modules do not import a second copy.
if __name__ == "__main__":
    sys.modules.setdefault("bump_versions", sys.modules[__name__])

from bump_fetch import (  # noqa: F401  re-exported: tests and the spec modules reach these as bv.<name>
    _EMPTY_SHA256,
    _GITHUB_HOSTS,
    PRERELEASE_RX,
    UA,
    _headers,
    _nuget_pkg_latest,
    _vkey,
    artifact_exists,
    asset_sha256,
    dockerhub_manifest_digest,
    gh_archive_sha256,
    gh_asset_digest,
    gh_latest,
    http_bytes,
    http_header,
    http_json,
    http_text,
    ls_remote_branch_commit,
    ls_remote_tag_commit,
    ls_remote_tags,
    mcr_manifest_digest,
    nvidia_redist_latest,
    sha256_of_gz_stream,
    sha256_of_url,
)
from bump_images import (  # noqa: F401  re-exported: tests and the spec modules reach these as bv.<name>
    _CUDA_WINDOWS_ARM64_COMPONENTS,
    _DEEPSTREAM_OSS_DEPS,
    _DEEPSTREAM_TRT_DEBS,
    _ROCM_TARBALL_BASE,
    _asset_pins,
    cargo_qa_pins,
    cuda_network_installer_sha256,
    cuda_windows_arm64_pins,
    cudnn_windows_arm64_sha256,
    deepstream_oss_pins,
    deepstream_pins,
    deepstream_trt_pins,
    gitleaks_pins,
    gstreamer_wrap_pin,
    hailo_protobuf_version,
    lavapipe_pins,
    mold_pins,
    nvidia_apt_packages,
    rocm_windows_tarball_url,
    spec_cargo_audit,
    spec_cargo_deny,
    spec_cargo_tarpaulin,
    spec_cuda,
    spec_cudnn,
    spec_dav1d,
    spec_deepstream,
    spec_deepstream_trt,
    spec_flutter_rust_bridge,
    spec_gitleaks,
    spec_hailo_cppzmq,
    spec_hailo_libzmq,
    spec_hailo_protobuf,
    spec_hailort,
    spec_lavapipe,
    spec_llama_cpp_hip,
    spec_mold,
    spec_ort_webgpu_dxc,
    spec_pytorch_rocm_index,
    spec_rocm_windows,
    spec_sqlite3_wasm,
    spec_tappas,
    spec_wasm_pack,
    spec_webdavclient,
    spec_x264_meson,
    spec_x265,
    sqlite3_wasm_pin,
    web_lane_pins,
    x265_pin,
)
from bump_tools import (  # noqa: F401  re-exported: tests and the spec modules reach these as bv.<name>
    _LITERT_LM_GPU_DLL_PINS,
    _same_major_node,
    derive_protoc_from_litert_lm,
    litert_lm_gpu_pins,
    node_pins,
    protoc_from_protobuf_cmake,
    spec_abseil,
    spec_actionlint,
    spec_amf_headers,
    spec_appimagetool,
    spec_binaryen,
    spec_cargo_c,
    spec_chrome_for_testing,
    spec_cmake,
    spec_flutter,
    spec_git,
    spec_gstreamer,
    spec_hadolint,
    spec_litert_lm,
    spec_node,
    spec_nuget,
    spec_ollama,
    spec_pandoc,
    spec_psscriptanalyzer,
    spec_pwsh,
    spec_python,
    spec_renovate_node,
    spec_rust,
    spec_shellcheck,
    spec_ubuntu_digest,
    spec_uv,
    spec_vulkan,
    spec_windows_digest,
    spec_wix,
    spec_wix_firewall,
    spec_wix_ui,
    vulkan_rt_windows_zip_sha256,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
VERSIONS_ENV = REPO_ROOT / "linux/scripts/01-core/versions.env"

# Set under --write: the checksum downloads (some GBs) only run when the result is written.
WRITE_MODE = False


# versions.env access
def pin_files() -> list[Path]:
    """versions.env, then tool-pins.env beside it (CON59: host-tool pins no image build reads)."""
    return [p for p in (VERSIONS_ENV, VERSIONS_ENV.with_name("tool-pins.env")) if p.exists()]


def read_env() -> dict[str, str]:
    vals = {}
    for path in pin_files():
        for line in path.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
            if m:
                vals[m.group(1)] = m.group(2).strip().strip('"')
    return vals


def read_holds() -> set[str]:
    """Keys whose contiguous leading comment block holds 'bump:hold', which blocks every automated write."""
    holds: set[str] = set()
    # A blank line between marker and KEY= silently disarms a hold, so fail on any marker that never attaches.
    orphaned: list[tuple[str, int]] = []
    for path in pin_files():
        block_held = False
        pending_marker_lines: list[int] = []
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                if "bump:hold" in line:
                    block_held = True
                    pending_marker_lines.append(lineno)
                continue
            m = re.match(r"^([A-Z][A-Z0-9_]*)=", line)
            if m and block_held:
                holds.add(m.group(1))
                pending_marker_lines.clear()
            elif pending_marker_lines:
                # A blank or stray line ended the block before any key.
                orphaned.extend((path.name, ln) for ln in pending_marker_lines)
                pending_marker_lines.clear()
            block_held = False
        orphaned.extend((path.name, ln) for ln in pending_marker_lines)  # marker at EOF with no key
    if orphaned:
        for name, ln in orphaned:
            print(
                f"ERROR: {name}:{ln}: 'bump:hold' marker is NOT attached "
                "to any KEY= line (a blank/stray line broke the comment block) "
                "— the hold is silently DISARMED. Re-join the comment block.",
                file=sys.stderr,
            )
        raise SystemExit(2)
    return holds


def renovate_owned() -> set[str]:
    """Keys under a `# renovate:` hint, whose detection Renovate owns and the coverage audit counts as classified."""
    out: set[str] = set()
    for path in pin_files():
        lines = path.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            if not line.startswith("# renovate:"):
                continue
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and lines[j].strip() == "# noforward":
                j += 1
            m = re.match(r"([A-Z0-9_]+)=", lines[j]) if j < len(lines) else None
            if m:
                out.add(m.group(1))
    return out


def write_env_values(updates: dict[str, str]) -> list[str]:
    """Rewrite KEY=value lines in place, byte for byte otherwise; held keys are dropped as a last defense."""
    for held in read_holds() & set(updates):
        updates.pop(held)
    changed = []
    # Each key is rewritten in the file that holds it.
    for path in pin_files():
        text = path.read_text(encoding="utf-8", newline="")
        before = text
        for key, value in updates.items():
            new_text, n = re.subn(
                rf"^({re.escape(key)})=.*$", rf"\g<1>={value}", text, count=1, flags=re.MULTILINE
            )
            if n and new_text != text:
                changed.append(key)
                text = new_text
        if text != before:
            path.write_text(text, encoding="utf-8", newline="")
    return changed


# Report-only latest lookups (high-risk stack pins)
def _r(
    repo: str, strip_v: bool = True, pattern: str | None = None, prefix: str = ""
) -> Spec:
    def fn(cur: str) -> tuple[str, dict[str, str]]:
        pat = pattern
        if pat is None and prefix:
            pat = rf"^{re.escape(prefix)}\d+(?:[._-]\d+)*$"
        tag = gh_latest(repo, pattern=pat)
        v = tag.removeprefix(prefix)
        return (v.lstrip("v") if strip_v else v), {}
    return fn


SAFE: list[tuple[str, Spec, str]] = [
    # Keys whose bump also moves a paired *_SHA256, which a Renovate datasource cannot compute.
    ("PWSH_VERSION", spec_pwsh, "windows base (full — pwsh is layer 1) + linux package pwsh layer"),
    ("PSSCRIPTANALYZER_VERSION", spec_psscriptanalyzer, "linux package pwsh layer"),
    ("GIT_VERSION", spec_git, "windows base scoop layer"),
    ("NUGET_VERSION", spec_nuget, "windows toolchain run (cheap)"),
    ("UV_VERSION", spec_uv, "linux base uv layer + tail"),
    ("NODE_VERSION", spec_node, "linux base node layer + tail (same-major only)"),
    ("CMAKE_VERSION", spec_cmake, "linux base + windows scoop layer"),
    ("OLLAMA_VERSION", spec_ollama, "llm-stack image only"),
    ("PANDOC_VERSION", spec_pandoc, "documentation image only"),
    ("BINARYEN_VERSION", spec_binaryen, "none (host-side bootstrap)"),
    ("CHROME_FOR_TESTING_VERSION", spec_chrome_for_testing, "linux package chrome layer (amd64, arm64)"),
    ("HADOLINT_VERSION", spec_hadolint, "torch stage (every arch; riscv64 source build) + host-side lint bootstrap"),
    ("ACTIONLINT_VERSION", spec_actionlint, "none (host-side lint bootstrap)"),
    ("SHELLCHECK_VERSION", spec_shellcheck, "torch stage (every arch) + host-side lint bootstrap; linux+windows"),
    ("GITLEAKS_VERSION", spec_gitleaks, "none (host-side secret-scan bootstrap; linux+windows)"),
    ("MOLD_LINUX_VERSION", spec_mold, "none (opt-in linker, fetched on demand)"),
    ("RENOVATE_NODE_VERSION", spec_renovate_node, "none (renovate-local.sh bootstrap; same-major minimum, exact cache)"),
    ("CARGO_AUDIT_VERSION", spec_cargo_audit, "linux package image cargo QA layer"),
    ("CARGO_DENY_VERSION", spec_cargo_deny, "linux package image cargo QA layer"),
    ("CARGO_TARPAULIN_VERSION", spec_cargo_tarpaulin, "linux package image cargo QA layer"),
    ("WASM_PACK_VERSION", spec_wasm_pack, "linux package image web-lane layer"),
    ("LAVAPIPE_VERSION", spec_lavapipe, "windows lavapipe ICD (amd64 + arm64)"),
    ("FLUTTER_VERSION", spec_flutter, "linux sdk flutter layer"),
    ("WIX_VERSION", spec_wix, "windows base scoop layer"),
    ("WIX_UI_EXT_VERSION", spec_wix_ui, "windows base scoop layer"),
    ("WIX_FIREWALL_EXT_VERSION", spec_wix_firewall, "windows final stage"),
    ("PYTHON_VERSION", spec_python, "linux+windows toolchain CPython builds (same-minor only)"),
    ("VULKAN_VERSION", spec_vulkan, "linux base/sdk + windows scoop layer + windows rocm sdk loader"),
    ("GSTREAMER_VERSION", spec_gstreamer, "linux media gstreamer stage (+ android universal)"),
    ("UBUNTU_DIGEST", spec_ubuntu_digest, "linux base (full chain)"),
    ("WINDOWS_BASE_DIGEST", spec_windows_digest, "windows base (full chain)"),
]


def spec_tensorflow_c(cur: str) -> tuple[str, dict[str, str]]:
    tag = gh_latest("tensorflow/tensorflow").lstrip("v")
    if not artifact_exists(
        f"https://storage.googleapis.com/tensorflow/versions/{tag}/libtensorflow-cpu-linux-x86_64.tar.gz"
    ):
        tag = cur
    return tag, {}


REPORT: list[tuple[str, Spec]] = [
    # What a datasource cannot do: paired extras, artifact gating, and PROTOC's derivation from LiteRT-LM.
    ("LITERT_LM_VERSION", spec_litert_lm),
    ("PROTOC_VERSION", _r("protocolbuffers/protobuf")),
    # TF stopped publishing the libtensorflow C tarball, so gate on the artifact, not the tag.
    ("TENSORFLOW_C_VERSION", spec_tensorflow_c),
    # These drag hashes a datasource cannot compute, refreshed under --write-all.
    ("ABSEIL_VERSION", spec_abseil),
    ("CUDA_VERSION", spec_cuda),
    ("CUDNN_VERSION", spec_cudnn),
    # Report-only until its consumer reads the SHA keys.
    ("APPIMAGETOOL_VERSION", spec_appimagetool),
    # Windows rocm lane's FFmpeg AMF headers; the header asset's SHA moves with the tag.
    ("AMF_HEADERS_VERSION", spec_amf_headers),
    # Windows rocm lane's llama.cpp: ggml-hip's source pin, the CPU + Vulkan zips' SHAs and the LICENSE move with the build.
    ("LLAMA_CPP_HIP_BUILD", spec_llama_cpp_hip),
    # Windows rocm lane's WebGPU ORT runtime: DXC's zip; the dated asset name and its SHA move with the tag.
    ("ORT_WEBGPU_WINDOWS_DXC_VERSION", spec_ort_webgpu_dxc),
    # Consumer-coupled: a consumer locks the frb crate and the sqlite3 Dart package to these.
    ("FLUTTER_RUST_BRIDGE_VERSION", spec_flutter_rust_bridge),
    ("SQLITE3_WASM_VERSION", spec_sqlite3_wasm),
    # Source builds whose tarball SHA moves with the version.
    ("X265_VERSION", spec_x265),
    ("DAV1D_VERSION", spec_dav1d),
    ("X264_MESON_BRANCH", spec_x264_meson),
    ("PYTORCH_ROCM_INDEX", spec_pytorch_rocm_index),
    ("WEBDAVCLIENT_REF", spec_webdavclient),
    ("DEEPSTREAM_VERSION", spec_deepstream),
    ("DEEPSTREAM_TENSORRT_VERSION", spec_deepstream_trt),
    ("HAILORT_VERSION", spec_hailort),
    ("HAILO_PROTOBUF_VERSION", spec_hailo_protobuf),
    ("TAPPAS_VERSION", spec_tappas),
    ("HAILO_LIBZMQ_VERSION", spec_hailo_libzmq),
    ("HAILO_CPPZMQ_VERSION", spec_hailo_cppzmq),
    ("ROCM_WINDOWS_RELEASE", spec_rocm_windows),
]


MANUAL = [
    # The hub's own sccache build: a bump is a new rev, a sccache-release.yml run and its sums (shared/upstream/sccache).
    "SCCACHE_LINUX_VERSION", "SCCACHE_LINUX_X86_64_SHA256", "SCCACHE_LINUX_AARCH64_SHA256", "SCCACHE_LINUX_RISCV64_SHA256",
    "SCCACHE_SOURCE_REPO", "SCCACHE_SOURCE_REV", "SCCACHE_BUILD_ID", "SCCACHE_DOWNLOAD_BASE",
    # Slaved to LiteRT's vendored protobuf (bump:hold and recipe in versions.env); no feed of its own.
    "LITERT_TFLITE_PROTOC_VERSION",
    # No reliable programmatic source, platform choices, or deliberate pins.
    "TENSORRT_VERSION", "TENSORRT_LINUX_CUDA", "MIGRAPHX_VERSION",
    # Windows rocm lane: slaved to MIGRAPHX_WINDOWS_COMMIT's requirements.txt, re-derived with it.
    "MIGRAPHX_WINDOWS_ABSEIL_VERSION", "MIGRAPHX_WINDOWS_PROTOBUF_VERSION",
    "MIGRAPHX_WINDOWS_MSGPACK_VERSION", "MIGRAPHX_WINDOWS_SQLITE_VERSION", "MIGRAPHX_WINDOWS_SQLITE_YEAR",
    "ANDROID_SDK_VERSION", "ANDROID_NDK_VERSION", "ANDROID_COMPILE_SDK",
    "ANDROID_BUILD_TOOLS", "ANDROID_EXTRA_COMPILE_SDK", "ANDROID_EXTRA_BUILD_TOOLS",
    "ANDROID_CMAKE_VERSION", "ANDROID_API_LEVEL",
    "UBUNTU_VERSION", "UBUNTU_CODENAME", "WINDOWS_LTSC", "WINDOWS_SDK_BUILD",
    "VISUAL_STUDIO_VERSION", "RUST_NIGHTLY_TOOLCHAIN",
    "OPENCV_VERSION", "FFMPEG_VERSION",
    "JRE_VERSION", "LIBFFI_MESON_VERSION",
    # Deliberate pins and non-versions
    "PY_SETUPTOOLS_LT82_VERSION",  # deliberate <82 compat pin — pairs with PY_SETUPTOOLS_VERSION
    "FLATPAK_RUNTIME_VERSION",     # freedesktop runtime BRANCH (26.08), not a package version
    # No feed at all: per-arch overrides, a version embedded in a patch.
    "CMAKE_VERSION_RISCV64", "NODE_VERSION_RISCV64",
    "CMAKE_POLICY_VERSION_MINIMUM",
    "ANDROID_AGP_VERSION", "ANDROID_GRADLE_VERSION",
    # A bump must re-prove an arm64 app boot under the image's ndk_translation (CON50).
    "ANDROID_EMULATOR_VERSION", "ANDROID_EMULATOR_BUILD", "ANDROID_EMULATOR_API", "ANDROID_EMULATOR_SYSIMG_REVISION",
    # Windows-lane pins: bumped via the Windows backlog, not this tool
    "LLVM_WINDOWS_VERSION", "NASM_WINDOWS_VERSION",
    "NINJA_WINDOWS_VERSION", "SCCACHE_WINDOWS_VERSION",
    # SCCACHE_WINDOWS_VERSION's zip checksum, refreshed by hand.
    "SCCACHE_WINDOWS_ZIP_SHA256",
    # The PYTORCH_VERSION/TORCHVISION_VERSION tags' commits, moved by hand with them.
    "TORCH_ROCM_WINDOWS_PYTORCH_COMMIT", "TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT",
    # No feed or published hashes: re-measured by hand with ROCM_WINDOWS_RELEASE.
    "TORCH_ROCM_WINDOWS_ROCM_URL", "TORCH_ROCM_WINDOWS_ROCM_SHA256",
    "TORCH_ROCM_WINDOWS_SDK_CORE_URL", "TORCH_ROCM_WINDOWS_SDK_CORE_SHA256",
    "TORCH_ROCM_WINDOWS_SDK_LIBRARIES_URL", "TORCH_ROCM_WINDOWS_SDK_LIBRARIES_SHA256",
    "TORCH_ROCM_WINDOWS_SDK_DEVICE_URL", "TORCH_ROCM_WINDOWS_SDK_DEVICE_SHA256",
    "TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL", "TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_SHA256",
    # Build-LitertLmBazel.ps1's tools and their release digests, moved together by hand (recipe in versions.env, hub #185).
    "LITERT_LM_BAZEL_WINDOWS_VERSION", "LITERT_LM_BAZEL_WINDOWS_AMD64_SHA256", "TEMURIN_JDK_WINDOWS_VERSION",
    "TEMURIN_JDK_WINDOWS_X64_SHA256", "GIT_LFS_WINDOWS_VERSION", "GIT_LFS_WINDOWS_AMD64_SHA256",
    # The source-built ai-edge-litert's accelerator carrier: URL + PyPI's digest, and the DLL's own (recipe in versions.env).
    "LITERT_WINDOWS_ACCELERATOR_WHEEL_URL", "LITERT_WINDOWS_ACCELERATOR_WHEEL_SHA256", "LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256",
    # LITERT_VERSION's commit and its .bazelversion's bazel, moved with it; Build-LitertWheelBazel.ps1 throws on a mismatch.
    "LITERT_WINDOWS_SOURCE_COMMIT", "LITERT_BAZEL_WINDOWS_VERSION", "LITERT_BAZEL_WINDOWS_AMD64_SHA256",
    # The CUDA line and apt repo NVIDIA builds TensorRT 10 for; spec_deepstream_trt reads them, nothing publishes a successor.
    "DEEPSTREAM_TENSORRT_CUDA", "DEEPSTREAM_TENSORRT_REPO",
]


# Hand-pinned wheel stores: each <prefix>*_URL with a *_SHA256 beside it is that wheel's version, moved with the SHA.
WHEEL_URL_GROUPS = {
    "PYTEST_WINDOWS_ARM64_": "PYTHON_VERSION's cpXY win_arm64 pytest closure at the versions OrchestrANT's x64 lock runs (CON67)",
    "TORCH_WINDOWS_ARM64_": "cp313 win_arm64 torch stack; torch/torchvision follow PYTORCH_VERSION/TORCHVISION_VERSION",
}


def wheel_url_keys(env: dict[str, str]) -> set[str]:
    return {k for k in env if k.endswith("_URL") and k.startswith(tuple(WHEEL_URL_GROUPS))
            and k.removesuffix("_URL") + "_SHA256" in env}


def derived_keys() -> dict[str, str]:
    """Version keys a spec writes as extras of its owning key, read from the tables those specs walk."""
    out = {ver: "CUDA_VERSION" for ver, _, _ in _CUDA_WINDOWS_ARM64_COMPONENTS}
    out.update({ver: "DEEPSTREAM_VERSION" for ver, _, _ in _DEEPSTREAM_OSS_DEPS})
    return out


# SHA pins no spec refreshes, each for a stated reason; a *_URL-paired pin needs no entry (url_paired_sha_keys).
SHA_PAIR_EXEMPT = {
    # EULA-gated manual download, deliberately empty.
    "TENSORRT_ZIP_SHA256",
    # Login-gated Qualcomm SDK zips, staged by hand per lane.
    "QNN_SDK_ZIP_SHA256", "QNN_SDK_LINUX_ZIP_SHA256",
    # Always-latest bootstrap installers: the hash is re-reviewed by hand on each deliberate update.
    "RUSTUP_INIT_SHA256",   # sh.rustup.rs
    "UV_INSTALL_SH_SHA256",  # astral.sh/uv/install.sh
    "SCOOP_INSTALLER_SHA256",  # get.scoop.sh
    # Paired with the MANUAL ANDROID_SDK_VERSION; recipe and sha1 cross-check beside the key.
    "ANDROID_CMDLINE_TOOLS_SHA256",
    # Paired with the MANUAL ANDROID_EMULATOR_* pins; sha1 cross-check beside the keys.
    "ANDROID_EMULATOR_SHA256", "ANDROID_EMULATOR_SYSIMG_SHA256",
    # Slaved to the MANUAL LLVM_WINDOWS_VERSION (source tarball, aarch64 release archive), bumped together.
    "LLVM_WINDOWS_SRC_SHA256", "LLVM_WINDOWS_AARCH64_RT_SHA256",
    # Slaved to MIGRAPHX_WINDOWS_COMMIT / ORT_AMDGPU_EP_COMMIT, re-measured by hand.
    "MIGRAPHX_WINDOWS_SOURCE_SHA256", "MIGRAPHX_WINDOWS_ABSEIL_SHA256", "MIGRAPHX_WINDOWS_PROTOBUF_SHA256",
    "MIGRAPHX_WINDOWS_MSGPACK_SHA256", "MIGRAPHX_WINDOWS_SQLITE_SHA256",
    "ORT_AMDGPU_EP_SOURCE_SHA256", "ORT_AMDGPU_EP_FMT_SHA256", "ORT_AMDGPU_EP_GSL_SHA256",
    "ORT_AMDGPU_EP_JSON_SHA256", "ORT_AMDGPU_EP_ZLIB_SHA256", "ORT_AMDGPU_EP_PROTOBUF_SHA256",
    "ORT_AMDGPU_EP_ABSEIL_SHA256", "ORT_AMDGPU_EP_ONNX_SHA256", "ORT_AMDGPU_EP_FLATBUFFERS_SHA256",
    "ORT_AMDGPU_EP_RANGE_V3_SHA256",
    # Slaved to the Renovate-moved PY_PSUTIL_VERSION; Build-TargetSdistWheel.ps1 stops the arm64 merge until it moves too.
    "PY_PSUTIL_SDIST_SHA256",
}


def url_paired_sha_keys(env: dict[str, str]) -> set[str]:
    """SHA keys whose sibling <name>_URL is their version: no tool moves that URL, so the hand edit moves both."""
    automated = renovate_owned() | {k for k, _, _ in SAFE} | {k for k, _ in REPORT}
    out = set()
    for key in env:
        for suffix in ("_SHA256", "_SHA512"):
            url_key = key.removesuffix(suffix) + "_URL"
            if key.endswith(suffix) and url_key in env and url_key not in automated:
                out.add(key)
    return out


SPEC_MODULES = ("bump_fetch", "bump_tools", "bump_images")


def _spec_sources() -> str:
    """The text a spec's key literal may sit in: this file and the spec modules beside it."""
    here = Path(__file__)
    texts = [here.read_text(encoding="utf-8")]
    for mod in SPEC_MODULES:
        sibling = here.with_name(f"{mod}.py")
        if sibling.exists():
            texts.append(sibling.read_text(encoding="utf-8"))
    return "\n".join(texts)


def audit_sha_pairs() -> int:
    """Fail when a *_SHA256/*_SHA512 key is neither quoted in a spec module or MANUAL, held, exempt nor URL-paired."""
    env = read_env()
    holds = read_holds()
    url_paired = url_paired_sha_keys(env)
    src = _spec_sources()
    counts = {"specced": 0, "held": 0, "exempt": 0, "url-paired": 0}
    stray: list[str] = []
    for key in sorted(env):
        if not key.endswith(("_SHA256", "_SHA512")):
            continue
        if key in SHA_PAIR_EXEMPT:
            counts["exempt"] += 1
        elif key in holds:
            counts["held"] += 1
        elif key in url_paired:
            counts["url-paired"] += 1
        elif f'"{key}"' in src:
            counts["specced"] += 1  # a string literal, so a comment naming the key does not count
        else:
            stray.append(key)
    if stray:
        print("SHA pins with NO refresh spec, NO bump:hold, NO allowlist entry")
        print("(their version key can bump while the SHA silently freezes):")
        for key in stray:
            print(f"  {key}")
        print("\nFix: add the pair to the owning bump spec's extras, hold it, or")
        print("allowlist it here WITH a justification.")
        return 1
    print("sha-pair audit: every *_SHA256/*_SHA512 key is refresh-covered, held, or allowlisted.")
    print("  " + ", ".join(f"{n} {label}" for label, n in counts.items()))
    return 0


def _parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="report only (default)")
    ap.add_argument("--write", action="store_true", help="bump the safe set + refresh checksums")
    ap.add_argument(
        "--write-all", action="store_true",
        help="ALSO write the report-tier keys (ONNX/LiteRT/TVM/media deps, GPU "
             "stack listings). These carry source patches and multi-hour build "
             "entanglement — expect to fix breakage per library. Deliberate use only.",
    )
    ap.add_argument("--only", default="", help="comma-separated safe keys to restrict --write to")
    ap.add_argument(
        "--audit-sha-pairs", action="store_true",
        help="Audit that every *_SHA256/*_SHA512 key in versions.env is either "
             "refreshed by a bump spec here, bump:hold-annotated, or explicitly "
             "allowlisted. Catches the scattered-pair hazard: a NEW version+SHA "
             "pair added OUTSIDE this script's refresh registry gets its version "
             "bumped while the far-away SHA silently freezes (backlog F6).")
    ap.add_argument(
        "--audit-unclassified", action="store_true",
        help="Offline: fail when a pin-file key is in no tier, derivation, wheel group, "
             "renovate annotation or the non-version filter (the --check self-audit, as a gate).")
    return ap.parse_args()


def _lookup(key: str, spec: Spec, cur: str) -> tuple[bool, str, dict[str, str]]:
    """(failed, latest, extras) for one key; a failure is printed and counted, never aborts the sweep."""
    try:
        latest, extras = spec(cur)
    except Exception as e:  # noqa: BLE001 — report and move on, never abort the sweep
        print(f"{key:32} {cur:22} {'?':22} lookup failed: {e}")
        return True, "", {}
    return False, latest, extras


def _record(key: str, latest: str, extras: dict[str, str], updates: dict[str, str]) -> None:
    updates[key] = latest
    updates.update(extras)
    for ek, ev in extras.items():
        print(f"  {ek:30} -> {ev}")


def _safe_row(
    key: str, cur: str, latest: str, extras: dict[str, str], impact: str,
    holds: set[str], updates: dict[str, str], write: bool,
) -> None:
    if latest == cur and write and extras:
        print(f"{key:32} {cur:22} {latest:22} up to date; refreshing {', '.join(sorted(extras))}")
        _record(key, latest, extras, updates)
    elif latest == cur:
        print(f"{key:32} {cur:22} {latest:22} up to date")
    elif key in holds:
        print(f"{key:32} {cur:22} {latest:22} HELD (bump:hold in versions.env)")
    else:
        print(f"{key:32} {cur:22} {latest:22} BUMP - rebuilds: {impact}")
        if write:
            _record(key, latest, extras, updates)


def _report_row(
    key: str, cur: str, latest: str, extras: dict[str, str], env: dict[str, str],
    holds: set[str], updates: dict[str, str], write_all: bool,
) -> None:
    if not latest:
        print(f"{key:32} {cur:22} {'?':22} lookup returned nothing")
        return
    if latest.lstrip("v") == cur.lstrip("v"):
        print(f"{key:32} {cur:22} {latest:22} up to date")
        return
    if key in holds:
        note = "HELD (bump:hold in versions.env)"
        if key == "PROTOC_VERSION":
            derived = derive_protoc_from_litert_lm(env.get("LITERT_LM_VERSION", ""))
            if derived:
                ok = "matches" if derived == cur else f"MISMATCH — set PROTOC_VERSION={derived}"
                note += f"; slaved pin derived from LiteRT-LM's protobuf.cmake: {derived} ({ok})"
        print(f"{key:32} {cur:22} {latest:22} {note}")
        return
    marker = "BUMP (--write-all)" if write_all else "NEWER AVAILABLE"
    print(f"{key:32} {cur:22} {latest:22} {marker}")
    if key == "LITERT_LM_VERSION":
        # PROTOC_VERSION is slaved to this pin; nudge with the new tag's derivation.
        _derived = derive_protoc_from_litert_lm(latest)
        _hint = "PROTOC_VERSION is SLAVED to this pin (bump:hold) — re-derive when bumping"
        if _derived:
            _hint += f"; the new tag's protobuf.cmake wants protoc {_derived}"
        print(f"  NOTE: {_hint}")
    if write_all:
        # Extras land with the version, or the download gate refuses the stale hash mid-build.
        _record(key, latest, extras, updates)


def _sweep(
    entries: Sequence[Any], env: dict[str, str], holds: set[str], only: set[str],
    updates: dict[str, str], args: argparse.Namespace, *, report: bool,
) -> int:
    """One tier's loop (SAFE and REPORT differ only in row renderer and write switch); returns the lookup-failure count."""
    failures = 0
    for entry in entries:
        key, spec = entry[0], entry[1]
        if only and (report or key not in only):
            continue
        cur = env.get(key, "")
        failed, latest, extras = _lookup(key, spec, cur)
        if failed:
            failures += 1
            continue
        if report:
            _report_row(key, cur, latest, extras, env, holds, updates, args.write_all)
        else:
            _safe_row(key, cur, latest, extras, entry[2], holds, updates, args.write)
    return failures


def _print_manual(env: dict[str, str]) -> None:
    print("\n-- manual (no reliable programmatic source / deliberate pins) --")
    for key in MANUAL:
        print(f"{key:32} {env.get(key, ''):22} {'-':22} check vendor release notes")
    wheels = wheel_url_keys(env)
    for prefix, why in WHEEL_URL_GROUPS.items():
        n = sum(k.startswith(prefix) for k in wheels)
        print(f"{prefix + '*_URL':32} {f'{n} wheels':22} {'-':22} {why}")


def unclassified_keys(env: dict[str, str]) -> list[str]:
    """Keys in no tier, derivation, wheel group, renovate annotation or the non-version filter."""
    covered = ({k for k, _, _ in SAFE} | {k for k, _ in REPORT} | set(MANUAL) | renovate_owned()
               | set(derived_keys()) | wheel_url_keys(env))
    nonversion = re.compile(
        r"(SHA256|^ORT_|_ENABLE_|^USE_|^FAST_UBUNTU|^IMAGE_REGISTRY_PREFIX$"
        r"|^CROSS_DEFAULT_ARCHES$|^VENV_PATH$|_OUTPUT_DIR$|^GSTREAMER_PREFIX$"
        r"|_COMMIT$|_ASSET$|^CUDA_ARCHITECTURES$|^WINDOWS_TARGET_ARCH(ES)?$"
        r"|^CI_IMAGE_|^ANDROID_TARGET_ABI$|^GENAI_ALLOW_RISCV64$|^FT_TORCH_TWIN$|^JDK_PACKAGE$"
        r"|^ROCM_WINDOWS_GFX_FAMILY$"  # a GPU target set, like CUDA_ARCHITECTURES
        r"|^APP_REF$"  # a tracked branch, resolved to a commit per run
        r"|^HADOLINT_HACKAGE_INDEX_STATE$)"  # a snapshot date spec_hadolint writes with HADOLINT_VERSION
    )
    return sorted(k for k in env if k not in covered and not nonversion.search(k))


def _print_unclassified(env: dict[str, str]) -> None:
    unclassified = unclassified_keys(env)
    if unclassified:
        print("\n-- UNCLASSIFIED versions.env keys (add to SAFE/REPORT/MANUAL or the non-version filter) --")
        for k in unclassified:
            print(f"{k:32} {env.get(k, ''):22}")


def audit_unclassified() -> int:
    """Fail, offline, when a pin-file key is in no class; --check only prints the same list."""
    env = read_env()
    stray = unclassified_keys(env)
    if stray:
        print(f"UNCLASSIFIED versions.env keys ({len(stray)}): no tier, derivation, wheel group, renovate line or non-version match")
        for key in stray:
            print(f"  {key}")
        return 1
    print(f"unclassified audit: all {len(env)} pin-file keys are classified.")
    return 0


def _write_phase(updates: dict[str, str], lookup_failures: int) -> int | None:
    """Apply the write and print the ritual; returns an exit code, or None to fall through to the verdict."""
    if not updates:
        print("\nNothing to write — safe set already at latest.")
        if lookup_failures:
            print(
                f"WARNING: {lookup_failures} lookup(s) failed — 'already at latest' "
                "is unverified for those keys.",
                file=sys.stderr,
            )
            return 1
        return 0
    changed = write_env_values(updates)
    names = ", ".join(str(p.relative_to(REPO_ROOT)) for p in pin_files())
    print(f"\nWrote {len(changed)} key(s) to {names}.")
    print("Finish the ritual:")
    print("  python docs/scripts/sync_versions.py --write")
    print("  bash linux/scripts/01-core/verify-arg-consistency.sh")
    print("  bash linux/scripts/preflight.sh")
    return None


def _lookup_verdict(lookup_failures: int) -> int:
    if lookup_failures:
        print(
            f"\nWARNING: {lookup_failures} lookup(s) failed — the report above is "
            "INCOMPLETE for those keys. Exiting nonzero so scripted callers notice.",
            file=sys.stderr,
        )
        return 1
    return 0


def main() -> int:
    args = _parse_args()
    if args.audit_sha_pairs:
        return audit_sha_pairs()
    if args.audit_unclassified:
        return audit_unclassified()
    if args.write_all:
        args.write = True
    global WRITE_MODE
    WRITE_MODE = args.write

    env = read_env()
    holds = read_holds()
    only = {k.strip() for k in args.only.split(",") if k.strip()}
    unknown = only - {k for k, _, _ in SAFE}
    if unknown:
        print(f"ERROR: --only keys not in the safe set: {', '.join(sorted(unknown))}", file=sys.stderr)
        return 2

    updates: dict[str, str] = {}
    print(f"{'KEY':32} {'CURRENT':22} {'LATEST':22} NOTE")
    print("-" * 100)
    lookup_failures = _sweep(SAFE, env, holds, only, updates, args, report=False)
    tier_label = "WRITTEN under --write-all" if args.write_all else "bump by hand, one at a time"
    print(f"\n-- report tier ({tier_label} - patches/build entanglement) --")
    lookup_failures += _sweep(REPORT, env, holds, only, updates, args, report=True)
    _print_manual(env)
    _print_unclassified(env)

    if args.write:
        rc = _write_phase(updates, lookup_failures)
        if rc is not None:
            return rc
    return _lookup_verdict(lookup_failures)


if __name__ == "__main__":
    sys.exit(main())
