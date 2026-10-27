#!/usr/bin/env python3
"""Spec lookups for bump_versions.py: the tool, toolchain and base-image pins in versions.env."""
from __future__ import annotations

import json
import re
from collections.abc import Callable

import bump_versions as bv  # tests patch names on bump_versions; every call reads them through it

SpecResult = tuple[str, dict[str, str]]


def derive_protoc_from_litert_lm(litert_lm_version: str) -> str | None:
    """The slaved PROTOC_VERSION for a LiteRT-LM tag, from its pinned protobuf runtime (v6.31.1 -> '31.1'); None if unrecognizable."""
    url = (
        "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/"
        f"v{litert_lm_version.lstrip('v')}/cmake/packages/protobuf/protobuf.cmake"
    )
    try:
        text = bv.http_text(url)
    except Exception:  # noqa: BLE001 — advisory only, never abort the sweep
        return None
    return bv.protoc_from_protobuf_cmake(text)


def protoc_from_protobuf_cmake(text: str) -> str | None:
    """protoc for a protobuf.cmake: LITERTLM_PROTOBUF_TAG "v36.1" (0.18+) or GIT_TAG v35.1 is protoc itself; a 3-part runtime tag v6.31.1 maps to 31.1."""
    m = (re.search(r'LITERTLM_PROTOBUF_TAG\s+"v?(\d+)\.(\d+)(?:\.(\d+))?"', text)
         or re.search(r"GIT_TAG\s+v?(\d+)\.(\d+)(?:\.(\d+))?\b", text))
    if not m:
        return None
    if m.group(3):
        return f"{m.group(2)}.{m.group(3)}"
    return f"{m.group(1)}.{m.group(2)}"


# The Windows rocm lane's LiteRT-LM GPU payload (Build-LitertLmBazel.ps1): key -> DLL.
_LITERT_LM_GPU_DLL_PINS = (
    ("LITERT_LM_WEBGPU_ACCELERATOR_SHA256", "libLiteRtWebGpuAccelerator.dll"),
    ("LITERT_LM_WEBGPU_SAMPLER_SHA256", "libLiteRtTopKWebGpuSampler.dll"),
    ("LITERT_LM_WEBGPU_DAWN_SHA256", "webgpu_dawn.dll"),
)


def litert_lm_gpu_pins(tag_text: Callable[[str], str]) -> dict[str, str]:
    """The rocm lane's LiteRT-LM GPU pins at a tag: each DLL's git-LFS oid is its sha256, WORKSPACE pins the DXC zip."""
    pins = {}
    for key, dll in bv._LITERT_LM_GPU_DLL_PINS:
        m = re.search(r"^oid sha256:([0-9a-f]{64})$", tag_text(f"prebuilt/windows_x86_64/{dll}"), re.MULTILINE)
        if not m:
            raise RuntimeError(f"no git-LFS pointer for prebuilt/windows_x86_64/{dll}")
        pins[key] = m.group(1)
    m = re.search(r'name\s*=\s*"directx_shader_compiler"[^)]*?sha256\s*=\s*"([0-9a-fA-F]{64})"', tag_text("WORKSPACE"))
    if not m:
        raise RuntimeError("WORKSPACE has no sha256-pinned directx_shader_compiler http_archive")
    pins["LITERT_LM_DXC_ZIP_SHA256"] = m.group(1).lower()
    return pins


def spec_litert_lm(cur: str) -> SpecResult:
    """LITERT_LM_VERSION drags the four rocm-lane GPU payload pins with it (versions.env)."""
    v = bv.gh_latest("google-ai-edge/LiteRT-LM").lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        base = f"https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/v{v}/"
        extras = bv.litert_lm_gpu_pins(lambda path: bv.http_text(base + path))
    return v, extras


# Key specs: each returns (new_version, {paired_env_key: value}) or raises.
def spec_pwsh(cur: str) -> SpecResult:
    tag = bv.gh_latest("PowerShell/PowerShell")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        extras["PWSH_ZIP_SHA256"] = bv.asset_sha256(
            "PowerShell/PowerShell", tag, f"PowerShell-{v}-win-x64.zip", sums=("hashes.sha256",))
        # The Linux package stage's tarballs (CON131).
        for key, arch in (("PWSH_LINUX_X64_SHA256", "x64"), ("PWSH_LINUX_ARM64_SHA256", "arm64")):
            extras[key] = bv.asset_sha256(
                "PowerShell/PowerShell", tag, f"powershell-{v}-linux-{arch}.tar.gz", sums=("hashes.sha256",))
    return v, extras


def spec_psscriptanalyzer(cur: str) -> SpecResult:
    v = bv.gh_latest("PowerShell/PSScriptAnalyzer")
    pins = {"PSSCRIPTANALYZER_NUPKG_SHA256": bv.asset_sha256(
        "PowerShell/PSScriptAnalyzer", v, f"PSScriptAnalyzer.{v}.nupkg")} if v != cur and bv.WRITE_MODE else {}
    return v, pins


def spec_git(cur: str) -> SpecResult:
    # Only .windows.1 releases: Install-ScoopTools.ps1 hardcodes that installer suffix.
    tag = bv.gh_latest("git-for-windows/git", pattern=r"^v\d+\.\d+\.\d+\.windows\.1$")
    v = tag.split(".windows.")[0].lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        extras["GIT_WINDOWS_INSTALLER_SHA256"] = bv.asset_sha256(
            "git-for-windows/git", tag, f"Git-{v}-64-bit.exe")
    return v, extras


def spec_nuget(cur: str) -> SpecResult:
    tools = bv.http_json("https://dist.nuget.org/tools.json")
    v = next(t["version"] for t in tools["nuget.exe"] if t["stage"] == "ReleasedAndBlessed")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        extras["NUGET_EXE_SHA256"] = bv.sha256_of_url(
            f"https://dist.nuget.org/win-x86-commandline/v{v}/nuget.exe"
        )
    return v, extras


def spec_uv(cur: str) -> SpecResult:
    tag = bv.gh_latest("astral-sh/uv")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("UV_AMD64_SHA256", "uv-x86_64-unknown-linux-gnu.tar.gz"),
            ("UV_ARM64_SHA256", "uv-aarch64-unknown-linux-gnu.tar.gz"),
            ("UV_RISCV64_SHA256", "uv-riscv64gc-unknown-linux-gnu.tar.gz"),
        ]:
            extras[env_key] = bv.asset_sha256("astral-sh/uv", tag, asset, sums=(f"{asset}.sha256",))
    return v, extras


def node_pins(v: str, keys: tuple[str, str]) -> dict[str, str]:
    """The linux-x64/linux-arm64 tarball digests from nodejs.org's SHASUMS256.txt, as {key: sha256}."""
    sums = bv.http_text(f"https://nodejs.org/dist/v{v}/SHASUMS256.txt")
    pins = {}
    for env_key, plat in zip(keys, ("linux-x64", "linux-arm64")):
        asset = f"node-v{v}-{plat}.tar.xz"
        m = re.search(rf"^([0-9a-f]{{64}})\s+{re.escape(asset)}$", sums, re.MULTILINE)
        if not m:
            raise RuntimeError(f"node {v}: SHASUMS256.txt lists no {asset}")
        pins[env_key] = m.group(1)
    return pins


def _same_major_node(cur: str) -> str:
    major = cur.split(".")[0]
    idx = bv.http_json("https://nodejs.org/dist/index.json")
    return next(e["version"].lstrip("v") for e in idx if e["version"].lstrip("v").split(".")[0] == major)


def spec_node(cur: str) -> SpecResult:
    v = bv._same_major_node(cur)
    extras = bv.node_pins(v, ("NODE_AMD64_SHA256", "NODE_ARM64_SHA256")) if v != cur and bv.WRITE_MODE else {}
    return v, extras


def spec_renovate_node(cur: str) -> SpecResult:
    """Renovate's own Node: same major only, since Renovate declares engines.node for one major (tool-pins.env)."""
    v = bv._same_major_node(cur)
    keys = ("RENOVATE_NODE_LINUX_X64_SHA256", "RENOVATE_NODE_LINUX_ARM64_SHA256")
    return v, (bv.node_pins(v, keys) if v != cur and bv.WRITE_MODE else {})


def spec_cmake(cur: str) -> SpecResult:
    tag = bv.gh_latest("Kitware/CMake")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("CMAKE_AMD64_SHA256", f"cmake-{v}-linux-x86_64.tar.gz"),
            ("CMAKE_ARM64_SHA256", f"cmake-{v}-linux-aarch64.tar.gz"),
        ]:
            extras[env_key] = bv.asset_sha256("Kitware/CMake", tag, asset, sums=(f"cmake-{v}-SHA-256.txt",))
    return v, extras


def spec_ollama(cur: str) -> SpecResult:
    tag = bv.gh_latest("ollama/ollama")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("OLLAMA_AMD64_SHA256", "ollama-linux-amd64.tar.zst"),
            ("OLLAMA_ARM64_SHA256", "ollama-linux-arm64.tar.zst"),
        ]:
            extras[env_key] = bv.asset_sha256("ollama/ollama", tag, asset, sums=("sha256sum.txt",))
    return v, extras


def spec_pandoc(cur: str) -> SpecResult:
    v = bv.gh_latest("jgm/pandoc")  # pandoc tags have no v prefix
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("PANDOC_SHA256_AMD64", f"pandoc-{v}-1-amd64.deb"),
            ("PANDOC_SHA256_ARM64", f"pandoc-{v}-1-arm64.deb"),
        ]:
            extras[env_key] = bv.asset_sha256("jgm/pandoc", v, asset)
    return v, extras


def spec_chrome_for_testing(cur: str) -> SpecResult:
    """Google's Stable Chrome for Testing; the bucket publishes md5 only, so each zip is hashed."""
    v = bv.http_json("https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
                  )["channels"]["Stable"]["version"]
    extras = {}
    if v != cur and bv.WRITE_MODE:
        base = f"https://storage.googleapis.com/chrome-for-testing-public/{v}"
        for env_key, plat, comp in [
            ("CHROME_FOR_TESTING_LINUX64_SHA256", "linux64", "chrome"),
            ("CHROME_FOR_TESTING_LINUX_ARM64_SHA256", "linux-arm64", "chrome"),
            ("CHROMEDRIVER_LINUX64_SHA256", "linux64", "chromedriver"),
            ("CHROMEDRIVER_LINUX_ARM64_SHA256", "linux-arm64", "chromedriver"),
        ]:
            extras[env_key] = bv.sha256_of_url(f"{base}/{plat}/{comp}-{plat}.zip")
    return v, extras


def spec_binaryen(cur: str) -> SpecResult:
    v = bv.gh_latest("WebAssembly/binaryen", pattern=r"^version_\d+$")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("BINARYEN_LINUX_X86_64_SHA256", f"binaryen-{v}-x86_64-linux.tar.gz"),
            # lib/wasm-opt.sh consumes the aarch64 tarball on arm64.
            ("BINARYEN_LINUX_AARCH64_SHA256", f"binaryen-{v}-aarch64-linux.tar.gz"),
            ("BINARYEN_WINDOWS_X86_64_SHA256", f"binaryen-{v}-x86_64-windows.tar.gz"),
        ]:
            extras[env_key] = bv.asset_sha256("WebAssembly/binaryen", v, asset)
    return v, extras


def spec_shellcheck(cur: str) -> SpecResult:
    # No sums file, so asset_sha256 downloads and hashes; the env keeps the leading v.
    v = bv.gh_latest("koalaman/shellcheck")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("SHELLCHECK_LINUX_X86_64_SHA256", f"shellcheck-{v}.linux.x86_64.tar.xz"),
            ("SHELLCHECK_LINUX_AARCH64_SHA256", f"shellcheck-{v}.linux.aarch64.tar.xz"),
            ("SHELLCHECK_LINUX_RISCV64_SHA256", f"shellcheck-{v}.linux.riscv64.tar.xz"),
            ("SHELLCHECK_WINDOWS_SHA256", f"shellcheck-{v}.zip"),
        ]:
            extras[env_key] = bv.asset_sha256("koalaman/shellcheck", v, asset)
    return v, extras


def spec_gstreamer(cur: str) -> SpecResult:
    # The repo pins an odd-minor development release, so compare with the newest tag overall.
    tags = bv.http_json(
        "https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fgstreamer/repository/tags?per_page=100")
    v = max((t["name"] for t in tags if re.match(r"^\d+\.\d+\.\d+$", t["name"])),
            key=lambda s: [int(x) for x in s.split(".")], default="")
    extras = {}
    # From the android tarball's .sha256sum sidecar; a dev tag without an android build fails loud here.
    if v and v != cur and bv.WRITE_MODE:
        url = (f"https://gstreamer.freedesktop.org/data/pkg/android/{v}/"
               f"gstreamer-1.0-android-universal-{v}.tar.xz.sha256sum")
        extras["GSTREAMER_ANDROID_UNIVERSAL_SHA256"] = bv.http_text(url).split()[0]
    return v, extras


def spec_hadolint(cur: str) -> SpecResult:
    v = bv.gh_latest("hadolint/hadolint")  # keep the leading v (env stores it)
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("HADOLINT_LINUX_X86_64_SHA256", "hadolint-linux-x86_64"),
            ("HADOLINT_LINUX_ARM64_SHA256", "hadolint-linux-arm64"),
            ("HADOLINT_WINDOWS_X86_64_SHA256", "hadolint-windows-x86_64.exe"),
        ]:
            extras[env_key] = bv.asset_sha256("hadolint/hadolint", v, asset, sums=("checksums.sha256",))
    return v, extras


def spec_amf_headers(cur: str) -> SpecResult:
    # Only vX.Y.Z tags carry the AMF-headers-<tag>.tar.gz asset; the env stores the tag.
    tag = bv.gh_latest("GPUOpen-LibrariesAndSDKs/AMF", pattern=r"^v\d+\.\d+\.\d+$")
    extras = {}
    if tag != cur and bv.WRITE_MODE:
        extras["AMF_HEADERS_SHA256"] = bv.asset_sha256(
            "GPUOpen-LibrariesAndSDKs/AMF", tag, f"AMF-headers-{tag}.tar.gz")
    return tag, extras


def spec_actionlint(cur: str) -> SpecResult:
    tag = bv.gh_latest("rhysd/actionlint")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("ACTIONLINT_LINUX_AMD64_SHA256", f"actionlint_{v}_linux_amd64.tar.gz"),
            ("ACTIONLINT_LINUX_ARM64_SHA256", f"actionlint_{v}_linux_arm64.tar.gz"),
            ("ACTIONLINT_WINDOWS_AMD64_SHA256", f"actionlint_{v}_windows_amd64.zip"),
        ]:
            extras[env_key] = bv.asset_sha256(
                "rhysd/actionlint", tag, asset, sums=(f"actionlint_{v}_checksums.txt", "checksums.txt"))
    return v, extras


def spec_rust(cur: str) -> SpecResult:
    return bv.gh_latest("rust-lang/rust").lstrip("v"), {}


def spec_cargo_c(cur: str) -> SpecResult:
    return bv.gh_latest("lu-zero/cargo-c").lstrip("v"), {}


def spec_flutter(cur: str) -> SpecResult:
    # GitHub's "latest release" is stale; flutter_infra_release is the authoritative stable pointer.
    data = bv.http_json("https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json")
    stable_hash = data["current_release"]["stable"]
    rel = next(r for r in data["releases"] if r["hash"] == stable_hash and r["channel"] == "stable")
    v = rel["version"]
    extras = {}
    # The same release object carries the SDK tarball's sha256.
    if v != cur and bv.WRITE_MODE and rel.get("sha256"):
        extras["FLUTTER_SDK_SHA256"] = rel["sha256"]
    return v, extras


def spec_wix(cur: str) -> SpecResult:
    # Same major only: a WiX major changes the CLI and authoring model.
    return bv._nuget_pkg_latest("wix", same_major_as=cur), {}


def spec_wix_ui(cur: str) -> SpecResult:
    return bv._nuget_pkg_latest("WixToolset.UI.wixext", same_major_as=cur), {}


def spec_wix_firewall(cur: str) -> SpecResult:
    return bv._nuget_pkg_latest("WixToolset.Firewall.wixext", same_major_as=cur), {}


def spec_python(cur: str) -> SpecResult:
    # Patches only: a minor upgrade is a hand edit of PYTHON_VERSION, and this run then fills its checksum.
    minor = ".".join(cur.split(".")[:2])
    tag = bv.gh_latest("python/cpython", pattern=rf"^v{re.escape(minor)}\.\d+$")
    v = tag.lstrip("v")
    extras = {}
    if bv.WRITE_MODE:
        sha = bv.sha256_of_url(f"https://www.python.org/ftp/python/{v}/Python-{v}.tgz")
        if sha != bv.read_env().get("PYTHON_TGZ_SHA256"):
            extras["PYTHON_TGZ_SHA256"] = sha
    return v, extras


def spec_vulkan(cur: str) -> SpecResult:
    # One key feeds the linux and windows lanes and LunarG versions per platform, so take the oldest of the two.
    latest = json.loads(bv.http_text("https://vulkan.lunarg.com/sdk/latest.json"))
    consumed = {p: str(latest[p]).strip() for p in ("linux", "windows") if latest.get(p)}
    if not consumed:
        raise RuntimeError("vulkan: latest.json carried neither a linux nor a windows version")

    def _key(s: str) -> tuple[int, ...]:
        return tuple(int(x) for x in re.findall(r"\d+", s))

    v = min(consumed.values(), key=_key)
    if len(set(consumed.values())) > 1:
        print(
            f"  note: vulkan platforms disagree ({', '.join(f'{p}={x}' for p, x in sorted(consumed.items()))})"
            f" -- pinning the oldest ({v}), since VULKAN_VERSION feeds both lanes"
        )
    extras = {}
    # Stream-hash the tarball; LunarG's sdk/sha/<v>/linux/<tarball>.txt is the second source to compare by hand.
    if v != cur and bv.WRITE_MODE:
        url = f"https://sdk.lunarg.com/sdk/download/{v}/linux/vulkansdk-linux-x86_64-{v}.tar.xz"
        extras["VULKAN_SDK_SHA256"] = bv.sha256_of_url(url)
        extras["VULKAN_RT_WINDOWS_ZIP_SHA256"] = bv.vulkan_rt_windows_zip_sha256(v)
        extras["VULKAN_RT_WINDOWS_ARM64_ZIP_SHA256"] = bv.vulkan_rt_windows_zip_sha256(v, arch="ARM64")
    return v, extras


def vulkan_rt_windows_zip_sha256(v: str, arch: str = "X64") -> str:
    """A Windows loader zip (x64 under windows/, ARM64 under warm/): LunarG's published digest, else a stream-hash."""
    platform = "windows" if arch == "X64" else "warm"
    name = f"VulkanRT-{arch}-{v}-Components.zip"
    try:
        text = bv.http_text(f"https://sdk.lunarg.com/sdk/sha/{v}/{platform}/{name}.txt")
    except Exception:  # noqa: BLE001 — fall back to hashing the zip itself
        text = ""
    m = re.search(rf"^([0-9a-fA-F]{{64}})\s+{re.escape(name)}\s*$", text, re.MULTILINE)
    return m.group(1).lower() if m else bv.sha256_of_url(f"https://sdk.lunarg.com/sdk/download/{v}/{platform}/{name}")


def spec_abseil(cur: str) -> SpecResult:
    """ABSEIL_VERSION drags its immutable commit and that archive's decompressed-stream sha256 along."""
    v = bv.gh_latest("abseil/abseil-cpp")  # tags are bare datestamps (20260817.0)
    extras = {}
    if v != cur and bv.WRITE_MODE:
        commit = bv.ls_remote_tag_commit("abseil/abseil-cpp", v)
        extras["ABSEIL_COMMIT"] = commit
        extras["ABSEIL_TARBALL_STREAM_SHA256"] = bv.sha256_of_gz_stream(
            f"https://github.com/abseil/abseil-cpp/archive/{commit}.tar.gz")
    return v, extras


def spec_appimagetool(cur: str) -> SpecResult:
    """Report tier until packaging-deps.sh reads the *_SHA256 keys instead of its own literals."""
    v = bv.gh_latest("AppImage/appimagetool")
    extras = {}
    if v != cur and bv.WRITE_MODE:
        for env_key, asset in [
            ("APPIMAGETOOL_X86_64_SHA256", "appimagetool-x86_64.AppImage"),
            ("APPIMAGETOOL_AARCH64_SHA256", "appimagetool-aarch64.AppImage"),
            ("APPIMAGETOOL_ARMHF_SHA256", "appimagetool-armhf.AppImage"),
            ("APPIMAGETOOL_I686_SHA256", "appimagetool-i686.AppImage"),
        ]:
            extras[env_key] = bv.asset_sha256("AppImage/appimagetool", v, asset)
    return v, extras


def spec_ubuntu_digest(cur: str) -> SpecResult:
    env = bv.read_env()
    return bv.dockerhub_manifest_digest("library/ubuntu", env["UBUNTU_VERSION"]), {}


def spec_windows_digest(cur: str) -> SpecResult:
    env = bv.read_env()
    return bv.mcr_manifest_digest("windows/servercore", f"ltsc{env['WINDOWS_LTSC']}"), {}
