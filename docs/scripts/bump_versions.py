#!/usr/bin/env python3
"""Refresh the versions.env keys Renovate does not own, with the *_SHA256/*_COMMIT pins a bump drags along.

After --write: sync_versions.py --write, verify-arg-consistency.sh, preflight.sh (AGENTS.md § Version Bumping).
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from collections.abc import Callable
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
VERSIONS_ENV = REPO_ROOT / "linux/scripts/01-core/versions.env"

UA = {"User-Agent": "kataglyphis-bump-versions"}

# Set under --write: the checksum downloads (some GBs) only run when the result is written.
WRITE_MODE = False


# HTTP helpers
def _headers(extra: dict | None = None) -> dict:
    h = dict(UA)
    tok = os.environ.get("GITHUB_TOKEN")
    if tok:
        h["Authorization"] = f"Bearer {tok}"
    if extra:
        h.update(extra)
    return h


def http_json(url: str):
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers()), timeout=60) as r:
        return json.load(r)


def http_text(url: str) -> str:
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers()), timeout=60) as r:
        return r.read().decode("utf-8", errors="replace")


def http_bytes(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers()), timeout=60) as r:
        return r.read()


def http_header(url: str, header: str, accept: str, auth: str | None = None) -> str:
    extra = {"Accept": accept}
    if auth:
        extra["Authorization"] = auth
    req = urllib.request.Request(url, headers=_headers(extra), method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.headers.get(header, "")


# sha256("") marks a silently empty download; committed as a pin it bricks the consuming stage.
_EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def sha256_of_gz_stream(url: str) -> str:
    """Hash a .tar.gz's decompressed stream, which outlives GitHub's gzip stability pledge; pairs with download_verified_file()'s "stream" mode."""
    import gzip
    h = hashlib.sha256()
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers()), timeout=600) as r:
        with gzip.GzipFile(fileobj=r) as gz:
            for chunk in iter(lambda: gz.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def sha256_of_url(url: str) -> str:
    """Stream-download and hash (for artifacts without a published digest)."""
    h = hashlib.sha256()
    n = 0
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers()), timeout=600) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
            n += len(chunk)
    digest = h.hexdigest()
    if n == 0 or digest == _EMPTY_SHA256:
        raise RuntimeError(f"empty download for {url} — refusing sha256('') as a pin (BT2)")
    return digest


def artifact_exists(url: str) -> bool:
    """HEAD-probe an artifact URL (BT2: report artifacts, not just git tags)."""
    try:
        req = urllib.request.Request(url, headers=_headers(), method="HEAD")
        with urllib.request.urlopen(req, timeout=30) as r:
            return 200 <= r.status < 300
    except Exception:
        return False


# Datasources: GitHub via `git ls-remote`, not the REST API, so there is no rate limit.
PRERELEASE_RX = re.compile(r"(?i)(rc|alpha|beta|preview|pre[0-9._-]|dev|init|test|next|nightly)")


def ls_remote_tags(repo: str) -> list[str]:
    out = subprocess.run(
        ["git", "ls-remote", "--tags", f"https://github.com/{repo}.git"],
        capture_output=True, text=True, timeout=120, check=False,
    )
    if out.returncode:
        raise RuntimeError(f"git ls-remote failed for {repo}: {out.stderr.strip()[:200]}")
    tags = []
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].startswith("refs/tags/") and not parts[1].endswith("^{}"):
            tags.append(parts[1][len("refs/tags/"):])
    return tags


def _vkey(name: str) -> list[int]:
    return [int(x) for x in re.findall(r"\d+", name)]


def ls_remote_tag_commit(repo: str, tag: str) -> str:
    """Peeled commit SHA of a tag via git ls-remote; a lightweight tag falls back to its own ref."""
    out = subprocess.run(
        ["git", "ls-remote", f"https://github.com/{repo}.git",
         f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
        capture_output=True, text=True, timeout=120, check=False,
    )
    if out.returncode:
        raise RuntimeError(f"git ls-remote failed for {repo} {tag}: {out.stderr.strip()[:200]}")
    shas = {}
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            shas[parts[1]] = parts[0]
    sha = shas.get(f"refs/tags/{tag}^{{}}") or shas.get(f"refs/tags/{tag}")
    if not sha:
        raise RuntimeError(f"tag {tag} not found on {repo}")
    return sha


def gh_latest(repo: str, pattern: str | None = None) -> str:
    """Newest non-prerelease version tag of a GitHub repo; `pattern` restricts the tag shape."""
    rx = re.compile(pattern) if pattern else re.compile(r"^(v|version_)?\d+(?:[._]\d+)*$")
    cand = [t for t in ls_remote_tags(repo) if rx.match(t) and not PRERELEASE_RX.search(t)]
    if not cand:
        raise RuntimeError(f"no matching tags for {repo} (pattern {rx.pattern})")
    return max(cand, key=_vkey)


def asset_sha256(repo: str, tag: str, asset: str, sums: tuple[str, ...] = ()) -> str:
    """sha256 of a release asset from the project's sums file, else by downloading and hashing it."""
    base = f"https://github.com/{repo}/releases/download/{tag}/"
    for sums_name in sums:
        try:
            text = http_text(base + sums_name)
        except Exception:  # noqa: BLE001 — try the next candidate / fallback
            continue
        m = re.search(rf"([0-9a-fA-F]{{64}})[ \t*]+\.?/?{re.escape(asset)}\s*$", text, re.M)
        if m:
            return m.group(1).lower()
    return sha256_of_url(base + asset)


def dockerhub_manifest_digest(repo: str, tag: str) -> str:
    tok = http_json(
        f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
    )["token"]
    return http_header(
        f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}",
        "Docker-Content-Digest",
        "application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json",
        auth=f"Bearer {tok}",
    )


def mcr_manifest_digest(repo: str, tag: str) -> str:
    return http_header(
        f"https://mcr.microsoft.com/v2/{repo}/manifests/{tag}",
        "Docker-Content-Digest",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    )


def nvidia_redist_latest(product: str) -> str:
    """Newest redistrib_<version>.json in NVIDIA's redist index for a product."""
    html = http_text(f"https://developer.download.nvidia.com/compute/{product}/redist/")
    versions = re.findall(r"redistrib_(\d+(?:\.\d+)+)\.json", html)
    return max(versions, key=lambda v: [int(x) for x in v.split(".")]) if versions else ""


# versions.env access
def read_env() -> dict[str, str]:
    vals = {}
    for line in VERSIONS_ENV.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
        if m:
            vals[m.group(1)] = m.group(2).strip().strip('"')
    return vals


def read_holds() -> set[str]:
    """Keys whose contiguous leading comment block holds 'bump:hold', which blocks every automated write."""
    holds: set[str] = set()
    block_held = False
    # A blank line between marker and KEY= silently disarms a hold, so fail on any marker that never attaches.
    pending_marker_lines: list[int] = []
    orphaned: list[int] = []
    for lineno, line in enumerate(VERSIONS_ENV.read_text(encoding="utf-8").splitlines(), 1):
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
            orphaned.extend(pending_marker_lines)
            pending_marker_lines.clear()
        block_held = False
    orphaned.extend(pending_marker_lines)  # marker at EOF with no key
    if orphaned:
        for ln in orphaned:
            print(
                f"ERROR: versions.env:{ln}: 'bump:hold' marker is NOT attached "
                "to any KEY= line (a blank/stray line broke the comment block) "
                "— the hold is silently DISARMED. Re-join the comment block.",
                file=sys.stderr,
            )
        raise SystemExit(2)
    return holds


def derive_protoc_from_litert_lm(litert_lm_version: str) -> str | None:
    """The slaved PROTOC_VERSION for a LiteRT-LM tag, from its pinned protobuf runtime (v6.31.1 -> '31.1'); None if unrecognizable."""
    url = (
        "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/"
        f"v{litert_lm_version.lstrip('v')}/cmake/packages/protobuf/protobuf.cmake"
    )
    try:
        text = http_text(url)
    except Exception:  # noqa: BLE001 — advisory only, never abort the sweep
        return None
    m = re.search(r"GIT_TAG\s+v?(\d+)\.(\d+)\.(\d+)", text)
    if not m:
        return None
    # protobuf runtime MAJOR.MINOR.PATCH -> protoc release is MINOR.PATCH
    return f"{m.group(2)}.{m.group(3)}"


# The Windows rocm lane's LiteRT-LM GPU payload (Build-LitertLmBazel.ps1): key -> DLL.
_LITERT_LM_GPU_DLL_PINS = (
    ("LITERT_LM_WEBGPU_ACCELERATOR_SHA256", "libLiteRtWebGpuAccelerator.dll"),
    ("LITERT_LM_WEBGPU_SAMPLER_SHA256", "libLiteRtTopKWebGpuSampler.dll"),
    ("LITERT_LM_WEBGPU_DAWN_SHA256", "libwebgpu_dawn.dll"),
)


def litert_lm_gpu_pins(tag_text) -> dict[str, str]:
    """The rocm lane's LiteRT-LM GPU pins at a tag: each DLL's git-LFS oid is its sha256, WORKSPACE pins the DXC zip."""
    pins = {}
    for key, dll in _LITERT_LM_GPU_DLL_PINS:
        m = re.search(r"^oid sha256:([0-9a-f]{64})$", tag_text(f"prebuilt/windows_x86_64/{dll}"), re.MULTILINE)
        if not m:
            raise RuntimeError(f"no git-LFS pointer for prebuilt/windows_x86_64/{dll}")
        pins[key] = m.group(1)
    m = re.search(r'name\s*=\s*"directx_shader_compiler"[^)]*?sha256\s*=\s*"([0-9a-fA-F]{64})"', tag_text("WORKSPACE"))
    if not m:
        raise RuntimeError("WORKSPACE has no sha256-pinned directx_shader_compiler http_archive")
    pins["LITERT_LM_DXC_ZIP_SHA256"] = m.group(1).lower()
    return pins


def spec_litert_lm(cur):
    """LITERT_LM_VERSION drags the four rocm-lane GPU payload pins with it (versions.env)."""
    v = gh_latest("google-ai-edge/LiteRT-LM").lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        base = f"https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/v{v}/"
        extras = litert_lm_gpu_pins(lambda path: http_text(base + path))
    return v, extras


def renovate_owned() -> set[str]:
    """Keys under a `# renovate:` hint, whose detection Renovate owns and the coverage audit counts as classified."""
    out: set[str] = set()
    lines = VERSIONS_ENV.read_text(encoding="utf-8").splitlines()
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
    text = VERSIONS_ENV.read_text(encoding="utf-8", newline="")
    changed = []
    for key, value in updates.items():
        new_text, n = re.subn(
            rf"^({re.escape(key)})=.*$", rf"\g<1>={value}", text, count=1, flags=re.M
        )
        if n and new_text != text:
            changed.append(key)
            text = new_text
    VERSIONS_ENV.write_text(text, encoding="utf-8", newline="")
    return changed


# Key specs: each returns (new_version, {paired_env_key: value}) or raises.
def spec_pwsh(cur):
    tag = gh_latest("PowerShell/PowerShell")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        extras["PWSH_ZIP_SHA256"] = asset_sha256(
            "PowerShell/PowerShell", tag, f"PowerShell-{v}-win-x64.zip", sums=("hashes.sha256",))
    return v, extras


def spec_git(cur):
    # Only .windows.1 releases: Install-ScoopTools.ps1 hardcodes that installer suffix.
    tag = gh_latest("git-for-windows/git", pattern=r"^v\d+\.\d+\.\d+\.windows\.1$")
    v = tag.split(".windows.")[0].lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        extras["GIT_WINDOWS_INSTALLER_SHA256"] = asset_sha256(
            "git-for-windows/git", tag, f"Git-{v}-64-bit.exe")
    return v, extras


def spec_nuget(cur):
    tools = http_json("https://dist.nuget.org/tools.json")
    v = next(t["version"] for t in tools["nuget.exe"] if t["stage"] == "ReleasedAndBlessed")
    extras = {}
    if v != cur and WRITE_MODE:
        extras["NUGET_EXE_SHA256"] = sha256_of_url(
            f"https://dist.nuget.org/win-x86-commandline/v{v}/nuget.exe"
        )
    return v, extras


def spec_uv(cur):
    tag = gh_latest("astral-sh/uv")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("UV_AMD64_SHA256", "uv-x86_64-unknown-linux-gnu.tar.gz"),
            ("UV_ARM64_SHA256", "uv-aarch64-unknown-linux-gnu.tar.gz"),
            ("UV_RISCV64_SHA256", "uv-riscv64gc-unknown-linux-gnu.tar.gz"),
            ("UV_WINDOWS_ARM64_SHA256", "uv-aarch64-pc-windows-msvc.zip"),
        ]:
            extras[env_key] = asset_sha256("astral-sh/uv", tag, asset, sums=(f"{asset}.sha256",))
    return v, extras


def spec_node(cur):
    major = cur.split(".")[0]
    idx = http_json("https://nodejs.org/dist/index.json")
    v = next(e["version"].lstrip("v") for e in idx if e["version"].lstrip("v").split(".")[0] == major)
    extras = {}
    if v != cur and WRITE_MODE:
        sums = http_text(f"https://nodejs.org/dist/v{v}/SHASUMS256.txt")
        for env_key, asset in [
            ("NODE_AMD64_SHA256", f"node-v{v}-linux-x64.tar.xz"),
            ("NODE_ARM64_SHA256", f"node-v{v}-linux-arm64.tar.xz"),
        ]:
            m = re.search(rf"^([0-9a-f]{{64}})\s+{re.escape(asset)}$", sums, re.M)
            if m:
                extras[env_key] = m.group(1)
    return v, extras


def spec_cmake(cur):
    tag = gh_latest("Kitware/CMake")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("CMAKE_AMD64_SHA256", f"cmake-{v}-linux-x86_64.tar.gz"),
            ("CMAKE_ARM64_SHA256", f"cmake-{v}-linux-aarch64.tar.gz"),
        ]:
            extras[env_key] = asset_sha256("Kitware/CMake", tag, asset, sums=(f"cmake-{v}-SHA-256.txt",))
    return v, extras


def spec_ollama(cur):
    tag = gh_latest("ollama/ollama")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("OLLAMA_AMD64_SHA256", "ollama-linux-amd64.tar.zst"),
            ("OLLAMA_ARM64_SHA256", "ollama-linux-arm64.tar.zst"),
        ]:
            extras[env_key] = asset_sha256("ollama/ollama", tag, asset, sums=("sha256sum.txt",))
    return v, extras


def spec_pandoc(cur):
    v = gh_latest("jgm/pandoc")  # pandoc tags have no v prefix
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("PANDOC_SHA256_AMD64", f"pandoc-{v}-1-amd64.deb"),
            ("PANDOC_SHA256_ARM64", f"pandoc-{v}-1-arm64.deb"),
        ]:
            extras[env_key] = asset_sha256("jgm/pandoc", v, asset)
    return v, extras


def spec_chrome_for_testing(cur):
    """Google's Stable Chrome for Testing; the bucket publishes md5 only, so each zip is hashed."""
    v = http_json("https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
                  )["channels"]["Stable"]["version"]
    extras = {}
    if v != cur and WRITE_MODE:
        base = f"https://storage.googleapis.com/chrome-for-testing-public/{v}"
        for env_key, plat, comp in [
            ("CHROME_FOR_TESTING_LINUX64_SHA256", "linux64", "chrome"),
            ("CHROME_FOR_TESTING_LINUX_ARM64_SHA256", "linux-arm64", "chrome"),
            ("CHROMEDRIVER_LINUX64_SHA256", "linux64", "chromedriver"),
            ("CHROMEDRIVER_LINUX_ARM64_SHA256", "linux-arm64", "chromedriver"),
        ]:
            extras[env_key] = sha256_of_url(f"{base}/{plat}/{comp}-{plat}.zip")
    return v, extras


def spec_binaryen(cur):
    v = gh_latest("WebAssembly/binaryen", pattern=r"^version_\d+$")
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("BINARYEN_LINUX_X86_64_SHA256", f"binaryen-{v}-x86_64-linux.tar.gz"),
            # lib/wasm-opt.sh consumes the aarch64 tarball on arm64.
            ("BINARYEN_LINUX_AARCH64_SHA256", f"binaryen-{v}-aarch64-linux.tar.gz"),
            ("BINARYEN_WINDOWS_X86_64_SHA256", f"binaryen-{v}-x86_64-windows.tar.gz"),
        ]:
            extras[env_key] = asset_sha256("WebAssembly/binaryen", v, asset)
    return v, extras


def spec_shellcheck(cur):
    # No sums file, so asset_sha256 downloads and hashes; the env keeps the leading v.
    v = gh_latest("koalaman/shellcheck")
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("SHELLCHECK_LINUX_X86_64_SHA256", f"shellcheck-{v}.linux.x86_64.tar.xz"),
            ("SHELLCHECK_WINDOWS_SHA256", f"shellcheck-{v}.zip"),
        ]:
            extras[env_key] = asset_sha256("koalaman/shellcheck", v, asset)
    return v, extras


def spec_gstreamer(cur):
    # The repo pins an odd-minor development release, so compare with the newest tag overall.
    tags = http_json(
        "https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fgstreamer/repository/tags?per_page=100")
    v = max((t["name"] for t in tags if re.match(r"^\d+\.\d+\.\d+$", t["name"])),
            key=lambda s: [int(x) for x in s.split(".")], default="")
    extras = {}
    # From the android tarball's .sha256sum sidecar; a dev tag without an android build fails loud here.
    if v and v != cur and WRITE_MODE:
        url = (f"https://gstreamer.freedesktop.org/data/pkg/android/{v}/"
               f"gstreamer-1.0-android-universal-{v}.tar.xz.sha256sum")
        extras["GSTREAMER_ANDROID_UNIVERSAL_SHA256"] = http_text(url).split()[0]
    return v, extras


def spec_hadolint(cur):
    v = gh_latest("hadolint/hadolint")  # keep the leading v (env stores it)
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("HADOLINT_LINUX_X86_64_SHA256", "hadolint-linux-x86_64"),
            ("HADOLINT_LINUX_ARM64_SHA256", "hadolint-linux-arm64"),
            ("HADOLINT_WINDOWS_X86_64_SHA256", "hadolint-windows-x86_64.exe"),
        ]:
            extras[env_key] = asset_sha256("hadolint/hadolint", v, asset, sums=("checksums.sha256",))
    return v, extras


def spec_amf_headers(cur):
    # Only vX.Y.Z tags carry the AMF-headers-<tag>.tar.gz asset; the env stores the tag.
    tag = gh_latest("GPUOpen-LibrariesAndSDKs/AMF", pattern=r"^v\d+\.\d+\.\d+$")
    extras = {}
    if tag != cur and WRITE_MODE:
        extras["AMF_HEADERS_SHA256"] = asset_sha256(
            "GPUOpen-LibrariesAndSDKs/AMF", tag, f"AMF-headers-{tag}.tar.gz")
    return tag, extras


def spec_actionlint(cur):
    tag = gh_latest("rhysd/actionlint")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("ACTIONLINT_LINUX_AMD64_SHA256", f"actionlint_{v}_linux_amd64.tar.gz"),
            ("ACTIONLINT_LINUX_ARM64_SHA256", f"actionlint_{v}_linux_arm64.tar.gz"),
            ("ACTIONLINT_WINDOWS_AMD64_SHA256", f"actionlint_{v}_windows_amd64.zip"),
        ]:
            extras[env_key] = asset_sha256(
                "rhysd/actionlint", tag, asset, sums=(f"actionlint_{v}_checksums.txt", "checksums.txt"))
    return v, extras


def spec_rust(cur):
    return gh_latest("rust-lang/rust").lstrip("v"), {}


def spec_cargo_c(cur):
    return gh_latest("lu-zero/cargo-c").lstrip("v"), {}


def spec_flutter(cur):
    # GitHub's "latest release" is stale; flutter_infra_release is the authoritative stable pointer.
    data = http_json("https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json")
    stable_hash = data["current_release"]["stable"]
    rel = next(r for r in data["releases"] if r["hash"] == stable_hash and r["channel"] == "stable")
    v = rel["version"]
    extras = {}
    # The same release object carries the SDK tarball's sha256.
    if v != cur and WRITE_MODE and rel.get("sha256"):
        extras["FLUTTER_SDK_SHA256"] = rel["sha256"]
    return v, extras


def _nuget_pkg_latest(pkg: str, same_major_as: str = "") -> str:
    idx = http_json(f"https://api.nuget.org/v3-flatcontainer/{pkg.lower()}/index.json")
    stable = [v for v in idx["versions"] if "-" not in v]
    if same_major_as:
        major = same_major_as.split(".")[0]
        stable = [v for v in stable if v.split(".")[0] == major] or stable[-1:]
    return stable[-1] if stable else idx["versions"][-1]


def spec_wix(cur):
    # Same major only: a WiX major changes the CLI and authoring model.
    return _nuget_pkg_latest("wix", same_major_as=cur), {}


def spec_wix_ui(cur):
    return _nuget_pkg_latest("WixToolset.UI.wixext", same_major_as=cur), {}


def spec_python(cur):
    minor = ".".join(cur.split(".")[:2])  # stay on the pinned minor (3.14.x)
    tag = gh_latest("python/cpython", pattern=rf"^v{re.escape(minor)}\.\d+$")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        extras["PYTHON_TGZ_SHA256"] = sha256_of_url(
            f"https://www.python.org/ftp/python/{v}/Python-{v}.tgz"
        )
    return v, extras


def spec_vulkan(cur):
    # One key feeds the linux and windows lanes and LunarG versions per platform, so take the oldest of the two.
    latest = json.loads(http_text("https://vulkan.lunarg.com/sdk/latest.json"))
    consumed = {p: str(latest[p]).strip() for p in ("linux", "windows") if latest.get(p)}
    if not consumed:
        raise RuntimeError("vulkan: latest.json carried neither a linux nor a windows version")

    def _key(s):
        return tuple(int(x) for x in re.findall(r"\d+", s))

    v = min(consumed.values(), key=_key)
    if len(set(consumed.values())) > 1:
        print(
            f"  note: vulkan platforms disagree ({', '.join(f'{p}={x}' for p, x in sorted(consumed.items()))})"
            f" -- pinning the oldest ({v}), since VULKAN_VERSION feeds both lanes"
        )
    extras = {}
    # LunarG publishes no linux digest, so stream-hash the tarball.
    if v != cur and WRITE_MODE:
        url = f"https://sdk.lunarg.com/sdk/download/{v}/linux/vulkansdk-linux-x86_64-{v}.tar.xz"
        extras["VULKAN_SDK_SHA256"] = sha256_of_url(url)
        extras["VULKAN_RT_WINDOWS_ZIP_SHA256"] = vulkan_rt_windows_zip_sha256(v)
    return v, extras


def vulkan_rt_windows_zip_sha256(v):
    """The rocm lane's Windows loader zip (Dockerfile.rocm): LunarG's published digest, else a stream-hash."""
    name = f"VulkanRT-X64-{v}-Components.zip"
    try:
        text = http_text(f"https://sdk.lunarg.com/sdk/sha/{v}/windows/{name}.txt")
    except Exception:  # noqa: BLE001 — fall back to hashing the zip itself
        text = ""
    m = re.search(rf"^([0-9a-fA-F]{{64}})\s+{re.escape(name)}\s*$", text, re.M)
    return m.group(1).lower() if m else sha256_of_url(f"https://sdk.lunarg.com/sdk/download/{v}/windows/{name}")


def spec_abseil(cur):
    """ABSEIL_VERSION drags its immutable commit and that archive's decompressed-stream sha256 along."""
    v = gh_latest("abseil/abseil-cpp")  # tags are bare datestamps (20260817.0)
    extras = {}
    if v != cur and WRITE_MODE:
        commit = ls_remote_tag_commit("abseil/abseil-cpp", v)
        extras["ABSEIL_COMMIT"] = commit
        extras["ABSEIL_TARBALL_STREAM_SHA256"] = sha256_of_gz_stream(
            f"https://github.com/abseil/abseil-cpp/archive/{commit}.tar.gz")
    return v, extras


def spec_appimagetool(cur):
    """Report tier until packaging-deps.sh reads the *_SHA256 keys instead of its own literals."""
    v = gh_latest("AppImage/appimagetool")
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("APPIMAGETOOL_X86_64_SHA256", "appimagetool-x86_64.AppImage"),
            ("APPIMAGETOOL_AARCH64_SHA256", "appimagetool-aarch64.AppImage"),
            ("APPIMAGETOOL_ARMHF_SHA256", "appimagetool-armhf.AppImage"),
            ("APPIMAGETOOL_I686_SHA256", "appimagetool-i686.AppImage"),
        ]:
            extras[env_key] = asset_sha256("AppImage/appimagetool", v, asset)
    return v, extras


def spec_ubuntu_digest(cur):
    env = read_env()
    return dockerhub_manifest_digest("library/ubuntu", env["UBUNTU_VERSION"]), {}


def spec_windows_digest(cur):
    env = read_env()
    return mcr_manifest_digest("windows/servercore", f"ltsc{env['WINDOWS_LTSC']}"), {}


def spec_cuda(cur):
    """CUDA from the redist index; a changed version re-downloads the ~4 GB Windows installer (13.4+ name) for its hash."""
    v = nvidia_redist_latest("cuda")
    extras = {}
    if v and v != cur and WRITE_MODE:
        extras["CUDA_INSTALLER_SHA256"] = sha256_of_url(
            f"https://developer.download.nvidia.com/compute/cuda/{v}/local_installers/cuda_{v}_windows_x86_64.exe"
        )
    return v, extras


def spec_cudnn(cur):
    """cuDNN's full 4-part version and zip sha256 from the redist manifest, preferring CUDA_VERSION's major."""
    label = nvidia_redist_latest("cudnn")
    if not label:
        return "", {}
    manifest = http_json(
        f"https://developer.download.nvidia.com/compute/cudnn/redist/redistrib_{label}.json"
    )
    win = manifest.get("cudnn", {}).get("windows-x86_64", {})
    cuda_major = "cuda" + read_env().get("CUDA_VERSION", "13").split(".")[0]
    entry = win.get(cuda_major) or (win[max(win)] if win else None)
    if not entry:
        return label, {}
    m = re.search(r"cudnn-windows-x86_64-(\d+(?:\.\d+)+)_cuda", entry.get("relative_path", ""))
    full_version = m.group(1) if m else label
    extras = {}
    if full_version != cur and WRITE_MODE and entry.get("sha256"):
        extras["CUDNN_ZIP_SHA256"] = entry["sha256"]
    return full_version, extras


def spec_llama_cpp_hip(cur):
    """Newest llama.cpp bNNNN publishing both the win-rocm-<major.minor> and win-vulkan-x64 zips, which share one pin."""
    rocm = ".".join(read_env()["ROCM_WINDOWS_RELEASE"].split(".")[:2])
    tags = sorted((t for t in ls_remote_tags("ggml-org/llama.cpp") if re.fullmatch(r"b\d+", t)),
                  key=_vkey, reverse=True)
    for tag in tags[:30]:
        asset = f"llama-{tag}-bin-win-rocm-{rocm}-x64.zip"
        vulkan = f"llama-{tag}-bin-win-vulkan-x64.zip"
        base = f"https://github.com/ggml-org/llama.cpp/releases/download/{tag}"
        if not (artifact_exists(f"{base}/{asset}") and artifact_exists(f"{base}/{vulkan}")):
            continue
        v = tag[1:]
        extras = {}
        if v != cur and WRITE_MODE:
            extras["LLAMA_CPP_HIP_ASSET"] = asset
            extras["LLAMA_CPP_HIP_SHA256"] = asset_sha256("ggml-org/llama.cpp", tag, asset)
            extras["LLAMA_CPP_VULKAN_SHA256"] = asset_sha256("ggml-org/llama.cpp", tag, vulkan)
            extras["LLAMA_CPP_HIP_LICENSE_SHA256"] = sha256_of_url(
                f"https://raw.githubusercontent.com/ggml-org/llama.cpp/{tag}/LICENSE")
        return v, extras
    raise RuntimeError(f"none of the newest 30 ggml-org/llama.cpp builds publishes both a win-rocm-{rocm} and a win-vulkan-x64 zip")


def spec_ort_webgpu_dxc(cur):
    """DXC's newest release zip (dxcompiler.dll + dxil.dll); its dated name and SHA move with the tag."""
    rel = http_json("https://api.github.com/repos/microsoft/DirectXShaderCompiler/releases/latest")
    tag = rel["tag_name"]
    zips = [a["name"] for a in rel.get("assets", []) if re.fullmatch(r"dxc_\d{4}_\d{2}_\d{2}\.zip", a["name"])]
    if len(zips) != 1:
        raise RuntimeError(f"DXC {tag}: expected one dxc_<date>.zip asset, found {zips}")
    extras = {}
    if tag != cur and WRITE_MODE:
        extras["ORT_WEBGPU_WINDOWS_DXC_ASSET"] = zips[0]
        extras["ORT_WEBGPU_WINDOWS_DXC_SHA256"] = asset_sha256("microsoft/DirectXShaderCompiler", tag, zips[0])
    return tag, extras


# Report-only latest lookups (high-risk stack pins)
def _r(repo, strip_v=True, pattern=None, prefix=""):
    def fn(cur):
        pat = pattern
        if pat is None and prefix:
            pat = rf"^{re.escape(prefix)}\d+(?:[._-]\d+)*$"
        tag = gh_latest(repo, pattern=pat)
        v = tag.removeprefix(prefix)
        return (v.lstrip("v") if strip_v else v), {}
    return fn


SAFE: list[tuple[str, Callable, str]] = [
    # Keys whose bump also moves a paired *_SHA256, which a Renovate datasource cannot compute.
    ("PWSH_VERSION", spec_pwsh, "windows base (full — pwsh is layer 1)"),
    ("GIT_VERSION", spec_git, "windows base scoop layer"),
    ("NUGET_VERSION", spec_nuget, "windows toolchain run (cheap)"),
    ("UV_VERSION", spec_uv, "linux base uv layer + tail"),
    ("NODE_VERSION", spec_node, "linux base node layer + tail (same-major only)"),
    ("CMAKE_VERSION", spec_cmake, "linux base + windows scoop layer"),
    ("OLLAMA_VERSION", spec_ollama, "llm-stack image only"),
    ("PANDOC_VERSION", spec_pandoc, "documentation image only"),
    ("BINARYEN_VERSION", spec_binaryen, "none (host-side bootstrap)"),
    ("CHROME_FOR_TESTING_VERSION", spec_chrome_for_testing, "linux package chrome layer (amd64, arm64)"),
    ("HADOLINT_VERSION", spec_hadolint, "none (host-side lint bootstrap)"),
    ("ACTIONLINT_VERSION", spec_actionlint, "none (host-side lint bootstrap)"),
    ("SHELLCHECK_VERSION", spec_shellcheck, "none (host-side lint bootstrap; linux+windows)"),
    ("FLUTTER_VERSION", spec_flutter, "linux sdk flutter layer"),
    ("WIX_VERSION", spec_wix, "windows base scoop layer"),
    ("WIX_UI_EXT_VERSION", spec_wix_ui, "windows base scoop layer"),
    ("PYTHON_VERSION", spec_python, "linux+windows toolchain CPython builds (same-minor only)"),
    ("VULKAN_VERSION", spec_vulkan, "linux base/sdk + windows scoop layer + windows rocm sdk loader"),
    ("GSTREAMER_VERSION", spec_gstreamer, "linux media gstreamer stage (+ android universal)"),
    ("UBUNTU_DIGEST", spec_ubuntu_digest, "linux base (full chain)"),
    ("WINDOWS_BASE_DIGEST", spec_windows_digest, "windows base (full chain)"),
]


REPORT: list[tuple[str, Callable]] = [
    # What a datasource cannot do: paired extras, artifact gating, and PROTOC's derivation from LiteRT-LM.
    ("LITERT_LM_VERSION", spec_litert_lm),
    ("PROTOC_VERSION", _r("protocolbuffers/protobuf")),
    # TF stopped publishing the libtensorflow C tarball, so gate on the artifact, not the tag.
    ("TENSORFLOW_C_VERSION", lambda cur: (
        (lambda tag: tag if artifact_exists(
            f"https://storage.googleapis.com/tensorflow/versions/{tag}/libtensorflow-cpu-linux-x86_64.tar.gz")
         else cur)(gh_latest("tensorflow/tensorflow").lstrip("v")), {})),
    # These drag hashes a datasource cannot compute, refreshed under --write-all.
    ("ABSEIL_VERSION", spec_abseil),
    ("CUDA_VERSION", spec_cuda),
    ("CUDNN_VERSION", spec_cudnn),
    # Report-only until its consumer reads the SHA keys.
    ("APPIMAGETOOL_VERSION", spec_appimagetool),
    # Windows rocm lane's FFmpeg AMF headers; the header asset's SHA moves with the tag.
    ("AMF_HEADERS_VERSION", spec_amf_headers),
    # Windows rocm lane's llama.cpp ROCm + Vulkan zips; the asset name and both SHAs move with the build.
    ("LLAMA_CPP_HIP_BUILD", spec_llama_cpp_hip),
    # Windows rocm lane's WebGPU ORT runtime: DXC's zip; the dated asset name and its SHA move with the tag.
    ("ORT_WEBGPU_WINDOWS_DXC_VERSION", spec_ort_webgpu_dxc),
]


MANUAL = [
    # Pinned for SCCACHE_BASEDIRS (>=0.14.0); a bump needs fresh SHA256s for both targets.
    "SCCACHE_LINUX_VERSION",
    "SCCACHE_LINUX_X86_64_SHA256",
    "SCCACHE_LINUX_AARCH64_SHA256",
    # Slaved to LiteRT's vendored protobuf (bump:hold and recipe in versions.env); no feed of its own.
    "LITERT_TFLITE_PROTOC_VERSION",
    # No reliable programmatic source, platform choices, or deliberate pins.
    "TENSORRT_VERSION", "MIGRAPHX_VERSION",
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
    "FLATPAK_RUNTIME_VERSION",     # freedesktop runtime BRANCH (24.08), not a package version
    # No feed at all: per-arch overrides, a version embedded in a patch, the SQLITE3_WASM tag-shape exception.
    "CMAKE_VERSION_RISCV64", "NODE_VERSION_RISCV64",
    "CMAKE_POLICY_VERSION_MINIMUM",
    "ANDROID_AGP_VERSION", "ANDROID_GRADLE_VERSION",
    # A bump must re-prove an arm64 app boot under the image's ndk_translation (CON50).
    "ANDROID_EMULATOR_VERSION", "ANDROID_EMULATOR_BUILD", "ANDROID_EMULATOR_API", "ANDROID_EMULATOR_SYSIMG_REVISION",
    "SQLITE3_WASM_VERSION",
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
    # The rocm venv's PyPI extra: URL + PyPI's own digest, re-derived by hand (recipe in versions.env).
    "TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_URL", "TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_SHA256",
]


def audit_sha_pairs() -> int:
    """Fail when a *_SHA256/*_SHA512 key is not named in this source (a spec refreshes it), held, or allowlisted."""
    env = read_env()
    holds = read_holds()
    allow = {
        # EULA-gated manual download, deliberately empty.
        "TENSORRT_ZIP_SHA256",
        # Login-gated Qualcomm SDK zip, staged by hand.
        "QNN_SDK_ZIP_SHA256",
        # Always-latest bootstrap installers: the hash is re-reviewed by hand on each deliberate update.
        "RUSTUP_INIT_SHA256",   # sh.rustup.rs
        "UV_INSTALL_SH_SHA256",  # astral.sh/uv/install.sh
        "SCOOP_INSTALLER_SHA256",  # get.scoop.sh
        # Paired with the MANUAL ANDROID_SDK_VERSION; recipe and sha1 cross-check beside the key.
        "ANDROID_CMDLINE_TOOLS_SHA256",
        # Paired with the MANUAL ANDROID_EMULATOR_* pins; sha1 cross-check beside the keys.
        "ANDROID_EMULATOR_SHA256", "ANDROID_EMULATOR_SYSIMG_SHA256",
        # Slaved to the MANUAL LLVM_WINDOWS_VERSION, bumped together.
        "LLVM_WINDOWS_SRC_SHA256",
        # Slaved to MIGRAPHX_WINDOWS_COMMIT / ORT_AMDGPU_EP_COMMIT, re-measured by hand.
        "MIGRAPHX_WINDOWS_SOURCE_SHA256", "MIGRAPHX_WINDOWS_ABSEIL_SHA256", "MIGRAPHX_WINDOWS_PROTOBUF_SHA256",
        "MIGRAPHX_WINDOWS_MSGPACK_SHA256", "MIGRAPHX_WINDOWS_SQLITE_SHA256",
        "ORT_AMDGPU_EP_SOURCE_SHA256", "ORT_AMDGPU_EP_FMT_SHA256", "ORT_AMDGPU_EP_GSL_SHA256",
        "ORT_AMDGPU_EP_JSON_SHA256", "ORT_AMDGPU_EP_ZLIB_SHA256", "ORT_AMDGPU_EP_PROTOBUF_SHA256",
        "ORT_AMDGPU_EP_ABSEIL_SHA256", "ORT_AMDGPU_EP_ONNX_SHA256", "ORT_AMDGPU_EP_FLATBUFFERS_SHA256",
        "ORT_AMDGPU_EP_RANGE_V3_SHA256",
    }
    src = Path(__file__).read_text(encoding="utf-8")
    stray: list[str] = []
    for key in sorted(env):
        if not (key.endswith("_SHA256") or key.endswith("_SHA512")):
            continue
        if key in allow or key in holds:
            continue
        if key in src:
            continue  # a bump spec refreshes it
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
    return 0


def _parse_args():
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
    return ap.parse_args()


def _lookup(key, spec, cur):
    """(failed, latest, extras) for one key; a failure is printed and counted, never aborts the sweep."""
    try:
        latest, extras = spec(cur)
    except Exception as e:  # noqa: BLE001 — report and move on, never abort the sweep
        print(f"{key:32} {cur:22} {'?':22} lookup failed: {e}")
        return True, "", {}
    return False, latest, extras


def _record(key, latest, extras, updates):
    updates[key] = latest
    updates.update(extras)
    for ek, ev in extras.items():
        print(f"  {ek:30} -> {ev}")


def _safe_row(key, cur, latest, extras, impact, holds, updates, write):
    if latest == cur:
        print(f"{key:32} {cur:22} {latest:22} up to date")
    elif key in holds:
        print(f"{key:32} {cur:22} {latest:22} HELD (bump:hold in versions.env)")
    else:
        print(f"{key:32} {cur:22} {latest:22} BUMP - rebuilds: {impact}")
        if write:
            _record(key, latest, extras, updates)


def _report_row(key, cur, latest, extras, env, holds, updates, write_all):
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


def _sweep(entries, env, holds, only, updates, args, *, report):
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


def _print_manual(env):
    print("\n-- manual (no reliable programmatic source / deliberate pins) --")
    for key in MANUAL:
        print(f"{key:32} {env.get(key, ''):22} {'-':22} check vendor release notes")


def _print_unclassified(env):
    # Every versions.env key must sit in a tier or match the non-version filter.
    covered = ({k for k, _, _ in SAFE} | {k for k, _ in REPORT} | set(MANUAL) | renovate_owned())
    nonversion = re.compile(
        r"(SHA256|^ORT_|_ENABLE_|^USE_|^FAST_UBUNTU|^IMAGE_REGISTRY_PREFIX$"
        r"|^CROSS_DEFAULT_ARCHES$|^VENV_PATH$|_OUTPUT_DIR$|^GSTREAMER_PREFIX$"
        r"|_COMMIT$|_ASSET$|^CUDA_ARCHITECTURES$|^WINDOWS_TARGET_ARCH(ES)?$"
        r"|^CI_IMAGE_|^ANDROID_TARGET_ABI$|^GENAI_ALLOW_RISCV64$|^JDK_PACKAGE$)"
    )
    unclassified = sorted(k for k in env if k not in covered and not nonversion.search(k))
    if unclassified:
        print("\n-- UNCLASSIFIED versions.env keys (add to SAFE/REPORT/MANUAL or the non-version filter) --")
        for k in unclassified:
            print(f"{k:32} {env.get(k, ''):22}")


def _write_phase(updates, lookup_failures):
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
    print(f"\nWrote {len(changed)} key(s) to {VERSIONS_ENV.relative_to(REPO_ROOT)}.")
    print("Finish the ritual:")
    print("  python docs/scripts/sync_versions.py --write")
    print("  bash linux/scripts/01-core/verify-arg-consistency.sh")
    print("  bash linux/scripts/preflight.sh")
    return None


def _lookup_verdict(lookup_failures):
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
