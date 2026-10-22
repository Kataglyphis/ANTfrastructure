#!/usr/bin/env python3
"""Spec lookups for bump_versions.py: the GPU-stack, media, NPU and QA-tool pins in versions.env."""
from __future__ import annotations

import gzip
import hashlib
import re
import subprocess

import bump_versions as bv  # tests patch names on bump_versions; every call reads them through it


# Install-Cuda.ps1's windows-arm64 redist set: key infix -> manifest component.
_CUDA_WINDOWS_ARM64_COMPONENTS = (
    ("CUDA_WINDOWS_ARM64_CUDART_VERSION", "CUDA_WINDOWS_ARM64_CUDART_SHA256", "cuda_cudart"),
    ("CUDA_WINDOWS_ARM64_CUBLAS_VERSION", "CUDA_WINDOWS_ARM64_CUBLAS_SHA256", "libcublas"),
    ("CUDA_WINDOWS_ARM64_CUFFT_VERSION", "CUDA_WINDOWS_ARM64_CUFFT_SHA256", "libcufft"),
    ("CUDA_WINDOWS_ARM64_CURAND_VERSION", "CUDA_WINDOWS_ARM64_CURAND_SHA256", "libcurand"),
    ("CUDA_WINDOWS_ARM64_NVJITLINK_VERSION", "CUDA_WINDOWS_ARM64_NVJITLINK_SHA256", "libnvjitlink"),
    ("CUDA_WINDOWS_ARM64_NPP_VERSION", "CUDA_WINDOWS_ARM64_NPP_SHA256", "libnpp"),
    ("CUDA_WINDOWS_ARM64_CUSOLVER_VERSION", "CUDA_WINDOWS_ARM64_CUSOLVER_SHA256", "libcusolver"),
    ("CUDA_WINDOWS_ARM64_CUSPARSE_VERSION", "CUDA_WINDOWS_ARM64_CUSPARSE_SHA256", "libcusparse"),
    ("CUDA_WINDOWS_ARM64_NVRTC_VERSION", "CUDA_WINDOWS_ARM64_NVRTC_SHA256", "cuda_nvrtc"),
    ("CUDA_WINDOWS_ARM64_CUPTI_VERSION", "CUDA_WINDOWS_ARM64_CUPTI_SHA256", "cuda_cupti"),
)


def cuda_windows_arm64_pins(manifest) -> dict[str, str]:
    """Each arm64 component's version and sha256 from a parsed redistrib_<CUDA_VERSION>.json."""
    pins = {}
    for ver_key, sha_key, comp in bv._CUDA_WINDOWS_ARM64_COMPONENTS:
        entry = manifest.get(comp, {}).get("windows-arm64")
        if not entry:
            raise RuntimeError(f"CUDA redist manifest has no windows-arm64 {comp}")
        m = re.search(rf"{re.escape(comp)}-windows-arm64-(\d+(?:\.\d+)+)-archive\.zip$", entry["relative_path"])
        if not m:
            raise RuntimeError(f"unexpected windows-arm64 {comp} path {entry['relative_path']}")
        pins[ver_key] = m.group(1)
        pins[sha_key] = entry["sha256"]
    return pins


def cuda_network_installer_sha256(v: str) -> str:
    """SHA256 of the network installer Install-Cuda.ps1 runs (13.4+), taken only once its MD5 is NVIDIA's own."""
    # NVIDIA publishes MD5 only; the full installer's digest pinned the wrong file on 2026-10-14.
    name = f"cuda_{v}_windows_x86_64_network.exe"
    base = f"https://developer.download.nvidia.com/compute/cuda/{v}"
    published = {}
    for line in bv.http_text(f"{base}/docs/sidebar/md5sum.txt").splitlines():
        parts = line.split()
        if len(parts) == 2:
            published[parts[1]] = parts[0].lower()
    if name not in published:
        raise RuntimeError(f"NVIDIA's md5sum.txt for CUDA {v} lists no {name}")
    blob = bv.http_bytes(f"{base}/network_installers/{name}")
    md5 = hashlib.md5(blob, usedforsecurity=False).hexdigest()
    if md5 != published[name]:
        raise RuntimeError(f"{name}: MD5 {md5} is not NVIDIA's {published[name]}")
    return hashlib.sha256(blob).hexdigest()


def spec_cuda(cur):
    """CUDA from the redist index; a changed version re-hashes the network installer Install-Cuda.ps1 downloads."""
    v = bv.nvidia_redist_latest("cuda")
    extras = {}
    if v and v != cur and bv.WRITE_MODE:
        extras["CUDA_INSTALLER_SHA256"] = bv.cuda_network_installer_sha256(v)
        extras.update(bv.cuda_windows_arm64_pins(
            bv.http_json(f"https://developer.download.nvidia.com/compute/cuda/redist/redistrib_{v}.json")))
    return v, extras


def spec_cudnn(cur):
    """cuDNN's full 4-part version and zip sha256 from the redist manifest, preferring CUDA_VERSION's major."""
    label = bv.nvidia_redist_latest("cudnn")
    if not label:
        return "", {}
    manifest = bv.http_json(
        f"https://developer.download.nvidia.com/compute/cudnn/redist/redistrib_{label}.json"
    )
    win = manifest.get("cudnn", {}).get("windows-x86_64", {})
    cuda_major = "cuda" + bv.read_env().get("CUDA_VERSION", "13").split(".")[0]
    entry = win.get(cuda_major) or (win[max(win)] if win else None)
    if not entry:
        return label, {}
    m = re.search(r"cudnn-windows-x86_64-(\d+(?:\.\d+)+)_cuda", entry.get("relative_path", ""))
    full_version = m.group(1) if m else label
    extras = {}
    if full_version != cur and bv.WRITE_MODE and entry.get("sha256"):
        extras["CUDNN_ZIP_SHA256"] = entry["sha256"]
        extras["CUDNN_WINDOWS_ARM64_ZIP_SHA256"] = bv.cudnn_windows_arm64_sha256(manifest, cuda_major)
    return full_version, extras


def cudnn_windows_arm64_sha256(manifest, cuda_major) -> str:
    """The windows-arm64 cuDNN zip's sha256 for one CUDA major, from a parsed cuDNN redist manifest."""
    entry = manifest.get("cudnn", {}).get("windows-arm64", {}).get(cuda_major)
    if not entry or not entry.get("sha256"):
        raise RuntimeError(f"cuDNN manifest has no windows-arm64 {cuda_major} zip")
    return entry["sha256"]


def spec_llama_cpp_hip(cur):
    """Newest llama.cpp bNNNN publishing both the win-cpu-x64 and win-vulkan-x64 zips; ggml-hip builds from that tag's source."""
    tags = sorted((t for t in bv.ls_remote_tags("ggml-org/llama.cpp") if re.fullmatch(r"b\d+", t)),
                  key=bv._vkey, reverse=True)
    for tag in tags[:30]:
        cpu = f"llama-{tag}-bin-win-cpu-x64.zip"
        vulkan = f"llama-{tag}-bin-win-vulkan-x64.zip"
        base = f"https://github.com/ggml-org/llama.cpp/releases/download/{tag}"
        if not (bv.artifact_exists(f"{base}/{cpu}") and bv.artifact_exists(f"{base}/{vulkan}")):
            continue
        v = tag[1:]
        extras = {}
        if v != cur and bv.WRITE_MODE:
            commit = extras["LLAMA_CPP_HIP_COMMIT"] = bv.ls_remote_tag_commit("ggml-org/llama.cpp", tag)
            extras["LLAMA_CPP_HIP_SOURCE_SHA256"] = bv.sha256_of_url(f"https://github.com/ggml-org/llama.cpp/archive/{commit}.tar.gz")
            extras["LLAMA_CPP_CPU_SHA256"] = bv.asset_sha256("ggml-org/llama.cpp", tag, cpu)
            extras["LLAMA_CPP_VULKAN_SHA256"] = bv.asset_sha256("ggml-org/llama.cpp", tag, vulkan)
            extras["LLAMA_CPP_HIP_LICENSE_SHA256"] = bv.sha256_of_url(
                f"https://raw.githubusercontent.com/ggml-org/llama.cpp/{tag}/LICENSE")
        return v, extras
    raise RuntimeError("none of the newest 30 ggml-org/llama.cpp builds publishes both a win-cpu-x64 and a win-vulkan-x64 zip")


def spec_ort_webgpu_dxc(cur):
    """DXC's newest release zip (dxcompiler.dll + dxil.dll); its dated name and SHA move with the tag."""
    rel = bv.http_json("https://api.github.com/repos/microsoft/DirectXShaderCompiler/releases/latest")
    tag = rel["tag_name"]
    zips = [a["name"] for a in rel.get("assets", []) if re.fullmatch(r"dxc_\d{4}_\d{2}_\d{2}\.zip", a["name"])]
    if len(zips) != 1:
        raise RuntimeError(f"DXC {tag}: expected one dxc_<date>.zip asset, found {zips}")
    extras = {}
    if tag != cur and bv.WRITE_MODE:
        extras["ORT_WEBGPU_WINDOWS_DXC_ASSET"] = zips[0]
        extras["ORT_WEBGPU_WINDOWS_DXC_SHA256"] = bv.asset_sha256("microsoft/DirectXShaderCompiler", tag, zips[0])
    return tag, extras


def _asset_pins(repo, tag, pairs, sums=()) -> dict[str, str]:
    return {key: bv.asset_sha256(repo, tag, asset, sums=sums) for key, asset in pairs}


def cargo_qa_pins(tool: str, v: str) -> dict[str, str]:
    """The prebuilt cargo QA binaries setup-package-image.sh installs (its _web_lane_asset_url), as {key: sha256}."""
    if tool == "cargo-audit":
        # Its aarch64 build is glibc, not musl.
        return bv._asset_pins("rustsec/rustsec", f"cargo-audit%2Fv{v}", [
            ("CARGO_AUDIT_LINUX_X86_64_SHA256", f"cargo-audit-x86_64-unknown-linux-musl-v{v}.tgz"),
            ("CARGO_AUDIT_LINUX_AARCH64_SHA256", f"cargo-audit-aarch64-unknown-linux-gnu-v{v}.tgz"),
        ])
    if tool == "cargo-deny":
        return bv._asset_pins("EmbarkStudios/cargo-deny", v, [
            ("CARGO_DENY_LINUX_X86_64_SHA256", f"cargo-deny-{v}-x86_64-unknown-linux-musl.tar.gz"),
            ("CARGO_DENY_LINUX_AARCH64_SHA256", f"cargo-deny-{v}-aarch64-unknown-linux-musl.tar.gz"),
        ])
    if tool == "cargo-tarpaulin":
        return bv._asset_pins("xd009642/tarpaulin", v, [
            ("CARGO_TARPAULIN_LINUX_X86_64_SHA256", "cargo-tarpaulin-x86_64-unknown-linux-musl.tar.gz"),
            ("CARGO_TARPAULIN_LINUX_AARCH64_SHA256", "cargo-tarpaulin-aarch64-unknown-linux-musl.tar.gz"),
        ])
    raise ValueError(tool)


def spec_cargo_audit(cur):
    # rustsec/rustsec is a monorepo, so only the cargo-audit/v* tags are cargo-audit releases.
    v = bv.gh_latest("rustsec/rustsec", pattern=r"^cargo-audit/v\d+\.\d+\.\d+$").split("/v", 1)[1]
    return v, (bv.cargo_qa_pins("cargo-audit", v) if v != cur and bv.WRITE_MODE else {})


def spec_cargo_deny(cur):
    v = bv.gh_latest("EmbarkStudios/cargo-deny")
    return v, (bv.cargo_qa_pins("cargo-deny", v) if v != cur and bv.WRITE_MODE else {})


def spec_cargo_tarpaulin(cur):
    v = bv.gh_latest("xd009642/tarpaulin")
    return v, (bv.cargo_qa_pins("cargo-tarpaulin", v) if v != cur and bv.WRITE_MODE else {})


def web_lane_pins(tool: str, v: str) -> dict[str, str]:
    """wasm-pack's and flutter_rust_bridge_codegen's linux-musl release binaries, as {key: sha256}."""
    if tool == "wasm-pack":
        return bv._asset_pins("rustwasm/wasm-pack", f"v{v}", [
            ("WASM_PACK_LINUX_X86_64_SHA256", f"wasm-pack-v{v}-x86_64-unknown-linux-musl.tar.gz"),
            ("WASM_PACK_LINUX_AARCH64_SHA256", f"wasm-pack-v{v}-aarch64-unknown-linux-musl.tar.gz"),
        ])
    if tool == "flutter_rust_bridge_codegen":
        return bv._asset_pins("fzyzcjy/flutter_rust_bridge", f"v{v}", [
            ("FLUTTER_RUST_BRIDGE_LINUX_X86_64_SHA256",
             f"flutter_rust_bridge_codegen-x86_64-unknown-linux-musl-v{v}.tgz"),
            ("FLUTTER_RUST_BRIDGE_LINUX_AARCH64_SHA256",
             f"flutter_rust_bridge_codegen-aarch64-unknown-linux-musl-v{v}.tgz"),
        ])
    raise ValueError(tool)


def spec_wasm_pack(cur):
    v = bv.gh_latest("rustwasm/wasm-pack").lstrip("v")
    return v, (bv.web_lane_pins("wasm-pack", v) if v != cur and bv.WRITE_MODE else {})


def spec_flutter_rust_bridge(cur):
    """Report tier: consumers pin the flutter_rust_bridge crate to this exact version, so the codegen moves with them."""
    v = bv.gh_latest("fzyzcjy/flutter_rust_bridge").lstrip("v")
    return v, (bv.web_lane_pins("flutter_rust_bridge_codegen", v) if v != cur and bv.WRITE_MODE else {})


def gitleaks_pins(v: str) -> dict[str, str]:
    return bv._asset_pins("gitleaks/gitleaks", f"v{v}", [
        ("GITLEAKS_LINUX_X64_SHA256", f"gitleaks_{v}_linux_x64.tar.gz"),
        ("GITLEAKS_LINUX_ARM64_SHA256", f"gitleaks_{v}_linux_arm64.tar.gz"),
        ("GITLEAKS_WINDOWS_X64_SHA256", f"gitleaks_{v}_windows_x64.zip"),
    ], sums=(f"gitleaks_{v}_checksums.txt",))


def spec_gitleaks(cur):
    v = bv.gh_latest("gitleaks/gitleaks").lstrip("v")
    return v, (bv.gitleaks_pins(v) if v != cur and bv.WRITE_MODE else {})


def mold_pins(v: str) -> dict[str, str]:
    return bv._asset_pins("rui314/mold", f"v{v}", [
        ("MOLD_LINUX_X86_64_SHA256", f"mold-{v}-x86_64-linux.tar.gz"),
        ("MOLD_LINUX_AARCH64_SHA256", f"mold-{v}-aarch64-linux.tar.gz"),
        ("MOLD_LINUX_RISCV64_SHA256", f"mold-{v}-riscv64-linux.tar.gz"),
    ])


def spec_mold(cur):
    v = bv.gh_latest("rui314/mold").lstrip("v")
    return v, (bv.mold_pins(v) if v != cur and bv.WRITE_MODE else {})


def lavapipe_pins(v: str) -> dict[str, str]:
    return bv._asset_pins("mmozeiko/build-mesa", v, [
        ("LAVAPIPE_WINDOWS_X64_SHA256", f"mesa-lavapipe-x64-{v}.7z"),
        ("LAVAPIPE_WINDOWS_ARM64_SHA256", f"mesa-lavapipe-arm64-{v}.7z"),
    ])


def spec_lavapipe(cur):
    v = bv.gh_latest("mmozeiko/build-mesa")
    return v, (bv.lavapipe_pins(v) if v != cur and bv.WRITE_MODE else {})


def sqlite3_wasm_pin(v: str) -> dict[str, str]:
    return {"SQLITE3_WASM_SHA256": bv.asset_sha256("simolus3/sqlite3.dart", f"sqlite3-{v}", "sqlite3.wasm")}


def spec_sqlite3_wasm(cur):
    """Report tier: the wasm must match the sqlite3 Dart package a consumer locks; sqlite3.dart tags it sqlite3-<v>."""
    v = bv.gh_latest("simolus3/sqlite3.dart", pattern=r"^sqlite3-\d+\.\d+\.\d+$").removeprefix("sqlite3-")
    return v, (bv.sqlite3_wasm_pin(v) if v != cur and bv.WRITE_MODE else {})


def x265_pin(v: str) -> dict[str, str]:
    return {"X265_SHA256": bv.sha256_of_url(f"https://bitbucket.org/multicoreware/x265_git/downloads/x265_{v}.tar.gz")}


def spec_x265(cur):
    """The newest x265_<v>.tar.gz in Bitbucket's downloads, the tarball Build-FfmpegCodecs.ps1 fetches; tags alone are not releases."""
    data = bv.http_json("https://api.bitbucket.org/2.0/repositories/multicoreware/x265_git/downloads?pagelen=100")
    found = [m.group(1) for d in data.get("values", [])
             if (m := re.fullmatch(r"x265_(\d+(?:\.\d+)+)\.tar\.gz", d.get("name", "")))]
    if not found:
        raise RuntimeError("Bitbucket lists no x265_<version>.tar.gz download")
    v = max(found, key=bv._vkey)
    return v, (bv.x265_pin(v) if v != cur and bv.WRITE_MODE else {})


def gstreamer_wrap_pin(gst_version: str, wrap: str) -> tuple[str, str]:
    """(version, source_hash) of a GStreamer subprojects/<wrap>.wrap at a GStreamer tag."""
    text = bv.http_text(f"https://gitlab.freedesktop.org/gstreamer/gstreamer/-/raw/{gst_version}/subprojects/{wrap}.wrap")
    d = re.search(r"^directory\s*=\s*\S+?-(\d+(?:\.\d+)+)\s*$", text, re.M)
    h = re.search(r"^source_hash\s*=\s*([0-9a-fA-F]{64})\s*$", text, re.M)
    if not (d and h):
        raise RuntimeError(f"GStreamer {gst_version}: {wrap}.wrap has no versioned directory or source_hash")
    return d.group(1), h.group(1).lower()


def spec_dav1d(cur):
    """Slaved to GSTREAMER_VERSION: the Windows codec build uses exactly the dav1d tarball GStreamer's wrap pins."""
    v, sha = bv.gstreamer_wrap_pin(bv.read_env()["GSTREAMER_VERSION"], "dav1d")
    return v, ({"DAV1D_SHA256": sha} if v != cur and bv.WRITE_MODE else {})


def spec_x264_meson(cur):
    """Slaved to GSTREAMER_VERSION: x264.wrap names a meson-ports branch, and its head commit pins it."""
    text = bv.http_text(
        f"https://gitlab.freedesktop.org/gstreamer/gstreamer/-/raw/{bv.read_env()['GSTREAMER_VERSION']}/subprojects/x264.wrap")
    url = re.search(r"^url\s*=\s*(\S+)\s*$", text, re.M)
    rev = re.search(r"^revision\s*=\s*(\S+)\s*$", text, re.M)
    if not (url and rev):
        raise RuntimeError("GStreamer's x264.wrap names no url or revision")
    extras = {}
    if rev.group(1) != cur and bv.WRITE_MODE:
        extras["X264_MESON_COMMIT"] = bv.ls_remote_branch_commit(url.group(1), rev.group(1))
    return rev.group(1), extras


def spec_webdavclient(cur):
    """The owner's WebDavClient has no releases; report its default branch's head against the pinned commit."""
    out = subprocess.run(["git", "ls-remote", "https://github.com/Kataglyphis/WebDavClient.git", "HEAD"],
                         capture_output=True, text=True, timeout=120, check=False)
    m = re.match(r"([0-9a-f]{40})\tHEAD", out.stdout)
    if out.returncode or not m:
        raise RuntimeError(f"git ls-remote HEAD failed for Kataglyphis/WebDavClient: {out.stderr.strip()[:200]}")
    return m.group(1), {}


def spec_pytorch_rocm_index(cur):
    """The newest download.pytorch.org rocmX.Y line carrying an x86_64 torch at PYTORCH_VERSION for PYTHON_VERSION's tag."""
    env = bv.read_env()
    torch = env["PYTORCH_VERSION"].lstrip("v")
    cp = "cp" + "".join(env["PYTHON_VERSION"].split(".")[:2])
    html = bv.http_text("https://download.pytorch.org/whl/torch/")
    found = set(re.findall(
        rf"torch-{re.escape(torch)}(?:\+|%2B)(rocm\d+(?:\.\d+)+)-{cp}-{cp}-manylinux[\w.]*_x86_64\.whl", html))
    if not found:
        raise RuntimeError(f"download.pytorch.org lists no rocm {cp} x86_64 wheel of torch {torch}")
    return max(found, key=bv._vkey), {}


# install_opensource_deps.sh's nvds_rest_server dependencies: version key, commit key, GitHub repo.
_DEEPSTREAM_OSS_DEPS = (
    ("DEEPSTREAM_CIVETWEB_VERSION", "DEEPSTREAM_CIVETWEB_COMMIT", "civetweb/civetweb"),
    ("DEEPSTREAM_PROMETHEUS_CPP_VERSION", "DEEPSTREAM_PROMETHEUS_CPP_COMMIT", "jupp0r/prometheus-cpp"),
    ("DEEPSTREAM_OPENTELEMETRY_CPP_VERSION", "DEEPSTREAM_OPENTELEMETRY_CPP_COMMIT", "open-telemetry/opentelemetry-cpp"),
)


def deepstream_oss_pins(script: str, tag_commit=None) -> dict[str, str]:
    """Each dependency's tag (the script's `git clone --branch`) and that tag's commit."""
    tag_commit = tag_commit or bv.ls_remote_tag_commit
    pins = {}
    for ver_key, commit_key, repo in bv._DEEPSTREAM_OSS_DEPS:
        m = re.search(rf"--branch\s+(\S+)\s*\\?\s*https://github\.com/{re.escape(repo)}\.git", script)
        if not m:
            raise RuntimeError(f"install_opensource_deps.sh clones no {repo} at a --branch")
        pins[ver_key] = m.group(1)
        pins[commit_key] = tag_commit(repo, m.group(1))
    return pins


def deepstream_pins(v: str) -> dict[str, str]:
    """DEEPSTREAM_VERSION's tag commit, both runtime debs' GitHub digests and its open-source deps' tags."""
    repo, tag = "NVIDIA/DeepStream", f"v{v}"
    return {
        "DEEPSTREAM_COMMIT": bv.ls_remote_tag_commit(repo, tag),
        "DEEPSTREAM_BINARIES_AMD64_SHA256": bv.gh_asset_digest(repo, tag, f"deepstream-binaries-x86_{v}_amd64.deb"),
        "DEEPSTREAM_BINARIES_ARM64_SHA256": bv.gh_asset_digest(repo, tag, f"deepstream-binaries-aarch64_{v}_arm64.deb"),
        **bv.deepstream_oss_pins(bv.http_text(
            f"https://raw.githubusercontent.com/{repo}/{tag}/scripts/install_opensource_deps.sh")),
    }


def spec_deepstream(cur):
    """The newest tag whose own release carries deepstream.sh's runtime deb; v9.1.0.x tags have no release at all."""
    tags = sorted((t for t in bv.ls_remote_tags("NVIDIA/DeepStream") if re.fullmatch(r"v\d+(?:\.\d+)+", t)),
                  key=bv._vkey, reverse=True)
    base = "https://github.com/NVIDIA/DeepStream/releases/download"
    for tag in tags[:10]:
        v = tag[1:]
        if bv.artifact_exists(f"{base}/{tag}/deepstream-binaries-x86_{v}_amd64.deb"):
            return v, (bv.deepstream_pins(v) if v != cur and bv.WRITE_MODE else {})
    raise RuntimeError("none of the newest 10 NVIDIA/DeepStream tags publishes deepstream-binaries-x86_<v>_amd64.deb")


# deepstream.sh's ds_trt_debs: key -> apt package.
_DEEPSTREAM_TRT_DEBS = (
    ("DEEPSTREAM_TRT_LIBNVINFER10_SHA256", "libnvinfer10"),
    ("DEEPSTREAM_TRT_LIBNVINFER_PLUGIN10_SHA256", "libnvinfer-plugin10"),
    ("DEEPSTREAM_TRT_LIBNVONNXPARSERS10_SHA256", "libnvonnxparsers10"),
    ("DEEPSTREAM_TRT_LIBNVINFER_HEADERS_DEV_SHA256", "libnvinfer-headers-dev"),
    ("DEEPSTREAM_TRT_LIBNVINFER_HEADERS_PLUGIN_DEV_SHA256", "libnvinfer-headers-plugin-dev"),
    ("DEEPSTREAM_TRT_LIBNVONNXPARSERS_DEV_SHA256", "libnvonnxparsers-dev"),
)


def nvidia_apt_packages(repo: str) -> list[dict[str, str]]:
    """The stanzas of NVIDIA's CUDA apt repo Packages index for x86_64."""
    raw = gzip.decompress(bv.http_bytes(
        f"https://developer.download.nvidia.com/compute/cuda/repos/{repo}/x86_64/Packages.gz")).decode("utf-8")
    return [dict(re.findall(r"^([A-Za-z0-9-]+): (.*)$", block, re.M)) for block in raw.split("\n\n")]


def deepstream_trt_pins(stanzas, trt_version: str, cuda: str) -> dict[str, str]:
    """Each TensorRT 10 deb's sha256 at <trt_version>-1+cuda<cuda>, from parsed Packages stanzas."""
    want = f"{trt_version}-1+cuda{cuda}"
    pins = {}
    for key, pkg in bv._DEEPSTREAM_TRT_DEBS:
        hit = next((s for s in stanzas if s.get("Package") == pkg and s.get("Version") == want), None)
        if not hit or "SHA256" not in hit:
            raise RuntimeError(f"Packages index has no {pkg} {want}")
        pins[key] = hit["SHA256"].lower()
    return pins


def spec_deepstream_trt(cur):
    """The newest TensorRT 10 (DeepStream links libnvinfer.so.10) the repo builds for DEEPSTREAM_TENSORRT_CUDA."""
    env = bv.read_env()
    cuda = env["DEEPSTREAM_TENSORRT_CUDA"]
    stanzas = bv.nvidia_apt_packages(env["DEEPSTREAM_TENSORRT_REPO"])
    found = [m.group(1) for s in stanzas if s.get("Package") == "libnvinfer10"
             if (m := re.fullmatch(rf"(10\.[\d.]+)-1\+cuda{re.escape(cuda)}", s.get("Version", "")))]
    if not found:
        raise RuntimeError(f"no libnvinfer10 10.x for cuda{cuda} in {env['DEEPSTREAM_TENSORRT_REPO']}")
    v = max(found, key=bv._vkey)
    return v, (bv.deepstream_trt_pins(stanzas, v, cuda) if v != cur and bv.WRITE_MODE else {})


def spec_hailort(cur):
    v = bv.gh_latest("hailo-ai/hailort").lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        extras["HAILORT_COMMIT"] = bv.ls_remote_tag_commit("hailo-ai/hailort", f"v{v}")
        extras["HAILORT_SOURCE_SHA256"] = bv.gh_archive_sha256("hailo-ai/hailort", f"v{v}")
    return v, extras


def hailo_protobuf_version(hailort_version: str) -> str:
    """The protobuf HailoRT's cmake/external/protobuf.cmake fetches at a tag, from its GIT_TAG's '# vX.Y' comment."""
    text = bv.http_text(f"https://raw.githubusercontent.com/hailo-ai/hailort/v{hailort_version}"
                     "/hailort/cmake/external/protobuf.cmake")
    m = re.search(r"GIT_TAG\s+[0-9a-f]{40}\s*#\s*v(\d+(?:\.\d+)+)", text)
    if not m:
        raise RuntimeError(f"HailoRT v{hailort_version}: protobuf.cmake names no '# vX.Y' GIT_TAG")
    return m.group(1)


def spec_hailo_protobuf(cur):
    """Slaved to HAILORT_VERSION: build-hailort.sh stages the protobuf HailoRT's own FetchContent pins."""
    v = bv.hailo_protobuf_version(bv.read_env()["HAILORT_VERSION"])
    extras = {}
    if v != cur and bv.WRITE_MODE:
        extras["HAILO_PROTOBUF_SHA256"] = bv.gh_archive_sha256("protocolbuffers/protobuf", f"v{v}")
    return v, extras


def spec_tappas(cur):
    v = bv.gh_latest("hailo-ai/tappas").lstrip("v")
    return v, ({"TAPPAS_SOURCE_SHA256": bv.gh_archive_sha256("hailo-ai/tappas", f"v{v}")} if v != cur and bv.WRITE_MODE else {})


def spec_hailo_libzmq(cur):
    v = bv.gh_latest("zeromq/libzmq").lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        extras["HAILO_LIBZMQ_SHA256"] = bv.asset_sha256("zeromq/libzmq", f"v{v}", f"zeromq-{v}.tar.gz")
    return v, extras


def spec_hailo_cppzmq(cur):
    v = bv.gh_latest("zeromq/cppzmq").lstrip("v")
    return v, ({"HAILO_CPPZMQ_SHA256": bv.gh_archive_sha256("zeromq/cppzmq", f"v{v}")} if v != cur and bv.WRITE_MODE else {})


_ROCM_TARBALL_BASE = "https://stable.repo.amd.com/rocm/core/tarball"


def rocm_windows_tarball_url(family: str, release: str) -> str:
    return f"{bv._ROCM_TARBALL_BASE}/therock-dist-windows-{family}-{release}.tar.gz"


def spec_rocm_windows(cur):
    """TheRock's newest Windows tarball for ROCM_WINDOWS_GFX_FAMILY; AMD publishes no checksum, so a bump hashes ~2.2 GB."""
    family = bv.read_env()["ROCM_WINDOWS_GFX_FAMILY"]
    html = bv.http_text(f"{bv._ROCM_TARBALL_BASE}/")
    found = re.findall(rf"therock-dist-windows-{re.escape(family)}-(\d+\.\d+\.\d+)\.tar\.gz", html)
    if not found:
        raise RuntimeError(f"AMD's tarball index lists no therock-dist-windows-{family}-<release>.tar.gz")
    v = max(found, key=bv._vkey)
    extras = {}
    if v != cur and bv.WRITE_MODE:
        extras["ROCM_WINDOWS_TARBALL_SHA256"] = bv.sha256_of_url(bv.rocm_windows_tarball_url(family, v))
    return v, extras
