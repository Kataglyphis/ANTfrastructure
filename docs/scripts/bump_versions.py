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
_GITHUB_HOSTS = {"github.com", "api.github.com", "raw.githubusercontent.com"}


def _headers(url: str, extra: dict | None = None) -> dict:
    h = dict(UA)
    tok = os.environ.get("GITHUB_TOKEN")
    # GitHub's token goes to GitHub only; Bitbucket answers a foreign bearer with 400.
    if tok and urllib.parse.urlsplit(url).hostname in _GITHUB_HOSTS:
        h["Authorization"] = f"Bearer {tok}"
    if extra:
        h.update(extra)
    return h


def http_json(url: str):
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers(url)), timeout=60) as r:
        return json.load(r)


def http_text(url: str) -> str:
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers(url)), timeout=60) as r:
        return r.read().decode("utf-8", errors="replace")


def http_bytes(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers(url)), timeout=60) as r:
        return r.read()


def http_header(url: str, header: str, accept: str, auth: str | None = None) -> str:
    extra = {"Accept": accept}
    if auth:
        extra["Authorization"] = auth
    req = urllib.request.Request(url, headers=_headers(url, extra), method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.headers.get(header, "")


# sha256("") marks a silently empty download; committed as a pin it bricks the consuming stage.
_EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def sha256_of_gz_stream(url: str) -> str:
    """Hash a .tar.gz's decompressed stream, which outlives GitHub's gzip stability pledge; pairs with download_verified_file()'s "stream" mode."""
    import gzip
    h = hashlib.sha256()
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers(url)), timeout=600) as r:
        with gzip.GzipFile(fileobj=r) as gz:
            for chunk in iter(lambda: gz.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def sha256_of_url(url: str) -> str:
    """Stream-download and hash (for artifacts without a published digest)."""
    h = hashlib.sha256()
    n = 0
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers(url)), timeout=600) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
            n += len(chunk)
    digest = h.hexdigest()
    if n == 0 or digest == _EMPTY_SHA256:
        raise RuntimeError(f"empty download for {url} — refusing sha256('') as a pin (BT2)")
    return digest


def artifact_exists(url: str) -> bool:
    """Probe an artifact URL with a one-byte GET (BT2: report artifacts, not just git tags)."""
    try:
        # Not HEAD: the CDN behind an authenticated GitHub release download answers HEAD with 401.
        req = urllib.request.Request(url, headers=_headers(url, {"Range": "bytes=0-0"}))
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
    return protoc_from_protobuf_cmake(text)


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
                rf"^({re.escape(key)})=.*$", rf"\g<1>={value}", text, count=1, flags=re.M
            )
            if n and new_text != text:
                changed.append(key)
                text = new_text
        if text != before:
            path.write_text(text, encoding="utf-8", newline="")
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


def node_pins(v, keys) -> dict[str, str]:
    """The linux-x64/linux-arm64 tarball digests from nodejs.org's SHASUMS256.txt, as {key: sha256}."""
    sums = http_text(f"https://nodejs.org/dist/v{v}/SHASUMS256.txt")
    pins = {}
    for env_key, plat in zip(keys, ("linux-x64", "linux-arm64")):
        asset = f"node-v{v}-{plat}.tar.xz"
        m = re.search(rf"^([0-9a-f]{{64}})\s+{re.escape(asset)}$", sums, re.M)
        if not m:
            raise RuntimeError(f"node {v}: SHASUMS256.txt lists no {asset}")
        pins[env_key] = m.group(1)
    return pins


def _same_major_node(cur):
    major = cur.split(".")[0]
    idx = http_json("https://nodejs.org/dist/index.json")
    return next(e["version"].lstrip("v") for e in idx if e["version"].lstrip("v").split(".")[0] == major)


def spec_node(cur):
    v = _same_major_node(cur)
    extras = node_pins(v, ("NODE_AMD64_SHA256", "NODE_ARM64_SHA256")) if v != cur and WRITE_MODE else {}
    return v, extras


def spec_renovate_node(cur):
    """Renovate's own Node: same major only, since Renovate declares engines.node for one major (tool-pins.env)."""
    v = _same_major_node(cur)
    keys = ("RENOVATE_NODE_LINUX_X64_SHA256", "RENOVATE_NODE_LINUX_ARM64_SHA256")
    return v, (node_pins(v, keys) if v != cur and WRITE_MODE else {})


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
            ("SHELLCHECK_LINUX_AARCH64_SHA256", f"shellcheck-{v}.linux.aarch64.tar.xz"),
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


def spec_wix_firewall(cur):
    return _nuget_pkg_latest("WixToolset.Firewall.wixext", same_major_as=cur), {}


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
    # Stream-hash the tarball; LunarG's sdk/sha/<v>/linux/<tarball>.txt is the second source to compare by hand.
    if v != cur and WRITE_MODE:
        url = f"https://sdk.lunarg.com/sdk/download/{v}/linux/vulkansdk-linux-x86_64-{v}.tar.xz"
        extras["VULKAN_SDK_SHA256"] = sha256_of_url(url)
        extras["VULKAN_RT_WINDOWS_ZIP_SHA256"] = vulkan_rt_windows_zip_sha256(v)
        extras["VULKAN_RT_WINDOWS_ARM64_ZIP_SHA256"] = vulkan_rt_windows_zip_sha256(v, arch="ARM64")
    return v, extras


def vulkan_rt_windows_zip_sha256(v, arch="X64"):
    """A Windows loader zip (x64 under windows/, ARM64 under warm/): LunarG's published digest, else a stream-hash."""
    platform = "windows" if arch == "X64" else "warm"
    name = f"VulkanRT-{arch}-{v}-Components.zip"
    try:
        text = http_text(f"https://sdk.lunarg.com/sdk/sha/{v}/{platform}/{name}.txt")
    except Exception:  # noqa: BLE001 — fall back to hashing the zip itself
        text = ""
    m = re.search(rf"^([0-9a-fA-F]{{64}})\s+{re.escape(name)}\s*$", text, re.M)
    return m.group(1).lower() if m else sha256_of_url(f"https://sdk.lunarg.com/sdk/download/{v}/{platform}/{name}")


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
    for ver_key, sha_key, comp in _CUDA_WINDOWS_ARM64_COMPONENTS:
        entry = manifest.get(comp, {}).get("windows-arm64")
        if not entry:
            raise RuntimeError(f"CUDA redist manifest has no windows-arm64 {comp}")
        m = re.search(rf"{re.escape(comp)}-windows-arm64-(\d+(?:\.\d+)+)-archive\.zip$", entry["relative_path"])
        if not m:
            raise RuntimeError(f"unexpected windows-arm64 {comp} path {entry['relative_path']}")
        pins[ver_key] = m.group(1)
        pins[sha_key] = entry["sha256"]
    return pins


def spec_cuda(cur):
    """CUDA from the redist index; a changed version re-downloads the ~4 GB Windows installer (13.4+ name) for its hash."""
    v = nvidia_redist_latest("cuda")
    extras = {}
    if v and v != cur and WRITE_MODE:
        extras["CUDA_INSTALLER_SHA256"] = sha256_of_url(
            f"https://developer.download.nvidia.com/compute/cuda/{v}/local_installers/cuda_{v}_windows_x86_64.exe"
        )
        extras.update(cuda_windows_arm64_pins(
            http_json(f"https://developer.download.nvidia.com/compute/cuda/redist/redistrib_{v}.json")))
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
        extras["CUDNN_WINDOWS_ARM64_ZIP_SHA256"] = cudnn_windows_arm64_sha256(manifest, cuda_major)
    return full_version, extras


def cudnn_windows_arm64_sha256(manifest, cuda_major) -> str:
    """The windows-arm64 cuDNN zip's sha256 for one CUDA major, from a parsed cuDNN redist manifest."""
    entry = manifest.get("cudnn", {}).get("windows-arm64", {}).get(cuda_major)
    if not entry or not entry.get("sha256"):
        raise RuntimeError(f"cuDNN manifest has no windows-arm64 {cuda_major} zip")
    return entry["sha256"]


def spec_llama_cpp_hip(cur):
    """Newest llama.cpp bNNNN publishing both the win-cpu-x64 and win-vulkan-x64 zips; ggml-hip builds from that tag's source."""
    tags = sorted((t for t in ls_remote_tags("ggml-org/llama.cpp") if re.fullmatch(r"b\d+", t)),
                  key=_vkey, reverse=True)
    for tag in tags[:30]:
        cpu = f"llama-{tag}-bin-win-cpu-x64.zip"
        vulkan = f"llama-{tag}-bin-win-vulkan-x64.zip"
        base = f"https://github.com/ggml-org/llama.cpp/releases/download/{tag}"
        if not (artifact_exists(f"{base}/{cpu}") and artifact_exists(f"{base}/{vulkan}")):
            continue
        v = tag[1:]
        extras = {}
        if v != cur and WRITE_MODE:
            commit = extras["LLAMA_CPP_HIP_COMMIT"] = ls_remote_tag_commit("ggml-org/llama.cpp", tag)
            extras["LLAMA_CPP_HIP_SOURCE_SHA256"] = sha256_of_url(f"https://github.com/ggml-org/llama.cpp/archive/{commit}.tar.gz")
            extras["LLAMA_CPP_CPU_SHA256"] = asset_sha256("ggml-org/llama.cpp", tag, cpu)
            extras["LLAMA_CPP_VULKAN_SHA256"] = asset_sha256("ggml-org/llama.cpp", tag, vulkan)
            extras["LLAMA_CPP_HIP_LICENSE_SHA256"] = sha256_of_url(
                f"https://raw.githubusercontent.com/ggml-org/llama.cpp/{tag}/LICENSE")
        return v, extras
    raise RuntimeError("none of the newest 30 ggml-org/llama.cpp builds publishes both a win-cpu-x64 and a win-vulkan-x64 zip")


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


def gh_asset_digest(repo: str, tag: str, asset: str) -> str:
    """GitHub's own sha256 for a release asset, sparing a GB-sized download; hashes the asset when the API has none."""
    try:
        rel = http_json(f"https://api.github.com/repos/{repo}/releases/tags/{tag}")
        for a in rel.get("assets", []):
            if a.get("name") == asset and str(a.get("digest", "")).startswith("sha256:"):
                return a["digest"].split(":", 1)[1].lower()
    except Exception:  # noqa: BLE001 — fall back to hashing the asset itself
        pass
    return asset_sha256(repo, tag, asset)


def _asset_pins(repo, tag, pairs, sums=()) -> dict[str, str]:
    return {key: asset_sha256(repo, tag, asset, sums=sums) for key, asset in pairs}


def cargo_qa_pins(tool: str, v: str) -> dict[str, str]:
    """The prebuilt cargo QA binaries setup-package-image.sh installs (its _web_lane_asset_url), as {key: sha256}."""
    if tool == "cargo-audit":
        # Its aarch64 build is glibc, not musl.
        return _asset_pins("rustsec/rustsec", f"cargo-audit%2Fv{v}", [
            ("CARGO_AUDIT_LINUX_X86_64_SHA256", f"cargo-audit-x86_64-unknown-linux-musl-v{v}.tgz"),
            ("CARGO_AUDIT_LINUX_AARCH64_SHA256", f"cargo-audit-aarch64-unknown-linux-gnu-v{v}.tgz"),
        ])
    if tool == "cargo-deny":
        return _asset_pins("EmbarkStudios/cargo-deny", v, [
            ("CARGO_DENY_LINUX_X86_64_SHA256", f"cargo-deny-{v}-x86_64-unknown-linux-musl.tar.gz"),
            ("CARGO_DENY_LINUX_AARCH64_SHA256", f"cargo-deny-{v}-aarch64-unknown-linux-musl.tar.gz"),
        ])
    if tool == "cargo-tarpaulin":
        return _asset_pins("xd009642/tarpaulin", v, [
            ("CARGO_TARPAULIN_LINUX_X86_64_SHA256", "cargo-tarpaulin-x86_64-unknown-linux-musl.tar.gz"),
            ("CARGO_TARPAULIN_LINUX_AARCH64_SHA256", "cargo-tarpaulin-aarch64-unknown-linux-musl.tar.gz"),
        ])
    raise ValueError(tool)


def spec_cargo_audit(cur):
    # rustsec/rustsec is a monorepo, so only the cargo-audit/v* tags are cargo-audit releases.
    v = gh_latest("rustsec/rustsec", pattern=r"^cargo-audit/v\d+\.\d+\.\d+$").split("/v", 1)[1]
    return v, (cargo_qa_pins("cargo-audit", v) if v != cur and WRITE_MODE else {})


def spec_cargo_deny(cur):
    v = gh_latest("EmbarkStudios/cargo-deny")
    return v, (cargo_qa_pins("cargo-deny", v) if v != cur and WRITE_MODE else {})


def spec_cargo_tarpaulin(cur):
    v = gh_latest("xd009642/tarpaulin")
    return v, (cargo_qa_pins("cargo-tarpaulin", v) if v != cur and WRITE_MODE else {})


def web_lane_pins(tool: str, v: str) -> dict[str, str]:
    """wasm-pack's and flutter_rust_bridge_codegen's linux-musl release binaries, as {key: sha256}."""
    if tool == "wasm-pack":
        return _asset_pins("rustwasm/wasm-pack", f"v{v}", [
            ("WASM_PACK_LINUX_X86_64_SHA256", f"wasm-pack-v{v}-x86_64-unknown-linux-musl.tar.gz"),
            ("WASM_PACK_LINUX_AARCH64_SHA256", f"wasm-pack-v{v}-aarch64-unknown-linux-musl.tar.gz"),
        ])
    if tool == "flutter_rust_bridge_codegen":
        return _asset_pins("fzyzcjy/flutter_rust_bridge", f"v{v}", [
            ("FLUTTER_RUST_BRIDGE_LINUX_X86_64_SHA256",
             f"flutter_rust_bridge_codegen-x86_64-unknown-linux-musl-v{v}.tgz"),
            ("FLUTTER_RUST_BRIDGE_LINUX_AARCH64_SHA256",
             f"flutter_rust_bridge_codegen-aarch64-unknown-linux-musl-v{v}.tgz"),
        ])
    raise ValueError(tool)


def spec_wasm_pack(cur):
    v = gh_latest("rustwasm/wasm-pack").lstrip("v")
    return v, (web_lane_pins("wasm-pack", v) if v != cur and WRITE_MODE else {})


def spec_flutter_rust_bridge(cur):
    """Report tier: consumers pin the flutter_rust_bridge crate to this exact version, so the codegen moves with them."""
    v = gh_latest("fzyzcjy/flutter_rust_bridge").lstrip("v")
    return v, (web_lane_pins("flutter_rust_bridge_codegen", v) if v != cur and WRITE_MODE else {})


def gitleaks_pins(v: str) -> dict[str, str]:
    return _asset_pins("gitleaks/gitleaks", f"v{v}", [
        ("GITLEAKS_LINUX_X64_SHA256", f"gitleaks_{v}_linux_x64.tar.gz"),
        ("GITLEAKS_LINUX_ARM64_SHA256", f"gitleaks_{v}_linux_arm64.tar.gz"),
        ("GITLEAKS_WINDOWS_X64_SHA256", f"gitleaks_{v}_windows_x64.zip"),
    ], sums=(f"gitleaks_{v}_checksums.txt",))


def spec_gitleaks(cur):
    v = gh_latest("gitleaks/gitleaks").lstrip("v")
    return v, (gitleaks_pins(v) if v != cur and WRITE_MODE else {})


def mold_pins(v: str) -> dict[str, str]:
    return _asset_pins("rui314/mold", f"v{v}", [
        ("MOLD_LINUX_X86_64_SHA256", f"mold-{v}-x86_64-linux.tar.gz"),
        ("MOLD_LINUX_AARCH64_SHA256", f"mold-{v}-aarch64-linux.tar.gz"),
        ("MOLD_LINUX_RISCV64_SHA256", f"mold-{v}-riscv64-linux.tar.gz"),
    ])


def spec_mold(cur):
    v = gh_latest("rui314/mold").lstrip("v")
    return v, (mold_pins(v) if v != cur and WRITE_MODE else {})


def lavapipe_pins(v: str) -> dict[str, str]:
    return _asset_pins("mmozeiko/build-mesa", v, [
        ("LAVAPIPE_WINDOWS_X64_SHA256", f"mesa-lavapipe-x64-{v}.7z"),
        ("LAVAPIPE_WINDOWS_ARM64_SHA256", f"mesa-lavapipe-arm64-{v}.7z"),
    ])


def spec_lavapipe(cur):
    v = gh_latest("mmozeiko/build-mesa")
    return v, (lavapipe_pins(v) if v != cur and WRITE_MODE else {})


def sqlite3_wasm_pin(v: str) -> dict[str, str]:
    return {"SQLITE3_WASM_SHA256": asset_sha256("simolus3/sqlite3.dart", f"sqlite3-{v}", "sqlite3.wasm")}


def spec_sqlite3_wasm(cur):
    """Report tier: the wasm must match the sqlite3 Dart package a consumer locks; sqlite3.dart tags it sqlite3-<v>."""
    v = gh_latest("simolus3/sqlite3.dart", pattern=r"^sqlite3-\d+\.\d+\.\d+$").removeprefix("sqlite3-")
    return v, (sqlite3_wasm_pin(v) if v != cur and WRITE_MODE else {})


def x265_pin(v: str) -> dict[str, str]:
    return {"X265_SHA256": sha256_of_url(f"https://bitbucket.org/multicoreware/x265_git/downloads/x265_{v}.tar.gz")}


def spec_x265(cur):
    """The newest x265_<v>.tar.gz in Bitbucket's downloads, the tarball Build-FfmpegCodecs.ps1 fetches; tags alone are not releases."""
    data = http_json("https://api.bitbucket.org/2.0/repositories/multicoreware/x265_git/downloads?pagelen=100")
    found = [m.group(1) for d in data.get("values", [])
             if (m := re.fullmatch(r"x265_(\d+(?:\.\d+)+)\.tar\.gz", d.get("name", "")))]
    if not found:
        raise RuntimeError("Bitbucket lists no x265_<version>.tar.gz download")
    v = max(found, key=_vkey)
    return v, (x265_pin(v) if v != cur and WRITE_MODE else {})


def gstreamer_wrap_pin(gst_version: str, wrap: str) -> tuple[str, str]:
    """(version, source_hash) of a GStreamer subprojects/<wrap>.wrap at a GStreamer tag."""
    text = http_text(f"https://gitlab.freedesktop.org/gstreamer/gstreamer/-/raw/{gst_version}/subprojects/{wrap}.wrap")
    d = re.search(r"^directory\s*=\s*\S+?-(\d+(?:\.\d+)+)\s*$", text, re.M)
    h = re.search(r"^source_hash\s*=\s*([0-9a-fA-F]{64})\s*$", text, re.M)
    if not (d and h):
        raise RuntimeError(f"GStreamer {gst_version}: {wrap}.wrap has no versioned directory or source_hash")
    return d.group(1), h.group(1).lower()


def spec_dav1d(cur):
    """Slaved to GSTREAMER_VERSION: the Windows codec build uses exactly the dav1d tarball GStreamer's wrap pins."""
    v, sha = gstreamer_wrap_pin(read_env()["GSTREAMER_VERSION"], "dav1d")
    return v, ({"DAV1D_SHA256": sha} if v != cur and WRITE_MODE else {})


def spec_x264_meson(cur):
    """Slaved to GSTREAMER_VERSION: x264.wrap names a meson-ports branch, and its head commit pins it."""
    text = http_text(
        f"https://gitlab.freedesktop.org/gstreamer/gstreamer/-/raw/{read_env()['GSTREAMER_VERSION']}/subprojects/x264.wrap")
    url = re.search(r"^url\s*=\s*(\S+)\s*$", text, re.M)
    rev = re.search(r"^revision\s*=\s*(\S+)\s*$", text, re.M)
    if not (url and rev):
        raise RuntimeError("GStreamer's x264.wrap names no url or revision")
    extras = {}
    if rev.group(1) != cur and WRITE_MODE:
        extras["X264_MESON_COMMIT"] = ls_remote_branch_commit(url.group(1), rev.group(1))
    return rev.group(1), extras


def ls_remote_branch_commit(url: str, branch: str) -> str:
    """Head commit of one branch of any git remote."""
    out = subprocess.run(["git", "ls-remote", url, f"refs/heads/{branch}"],
                         capture_output=True, text=True, timeout=120, check=False)
    m = re.match(r"([0-9a-f]{40})\t", out.stdout)
    if out.returncode or not m:
        raise RuntimeError(f"git ls-remote found no branch {branch} on {url}: {out.stderr.strip()[:200]}")
    return m.group(1)


def spec_webdavclient(cur):
    """The owner's WebDavClient has no releases; report its default branch's head against the pinned commit."""
    out = subprocess.run(["git", "ls-remote", "https://github.com/Kataglyphis/WebDavClient.git", "HEAD"],
                         capture_output=True, text=True, timeout=120, check=False)
    m = re.match(r"([0-9a-f]{40})\tHEAD", out.stdout)
    if out.returncode or not m:
        raise RuntimeError(f"git ls-remote HEAD failed for Kataglyphis/WebDavClient: {out.stderr.strip()[:200]}")
    return m.group(1), {}


def spec_pytorch_rocm_index(cur):
    """The newest download.pytorch.org rocmX.Y line carrying a cp314 x86_64 torch at PYTORCH_VERSION."""
    torch = read_env()["PYTORCH_VERSION"].lstrip("v")
    html = http_text("https://download.pytorch.org/whl/torch/")
    found = set(re.findall(
        rf"torch-{re.escape(torch)}(?:\+|%2B)(rocm\d+(?:\.\d+)+)-cp314-cp314-manylinux[\w.]*_x86_64\.whl", html))
    if not found:
        raise RuntimeError(f"download.pytorch.org lists no rocm cp314 x86_64 wheel of torch {torch}")
    return max(found, key=_vkey), {}


# install_opensource_deps.sh's nvds_rest_server dependencies: version key, commit key, GitHub repo.
_DEEPSTREAM_OSS_DEPS = (
    ("DEEPSTREAM_CIVETWEB_VERSION", "DEEPSTREAM_CIVETWEB_COMMIT", "civetweb/civetweb"),
    ("DEEPSTREAM_PROMETHEUS_CPP_VERSION", "DEEPSTREAM_PROMETHEUS_CPP_COMMIT", "jupp0r/prometheus-cpp"),
    ("DEEPSTREAM_OPENTELEMETRY_CPP_VERSION", "DEEPSTREAM_OPENTELEMETRY_CPP_COMMIT", "open-telemetry/opentelemetry-cpp"),
)


def deepstream_oss_pins(script: str, tag_commit=None) -> dict[str, str]:
    """Each dependency's tag (the script's `git clone --branch`) and that tag's commit."""
    tag_commit = tag_commit or ls_remote_tag_commit
    pins = {}
    for ver_key, commit_key, repo in _DEEPSTREAM_OSS_DEPS:
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
        "DEEPSTREAM_COMMIT": ls_remote_tag_commit(repo, tag),
        "DEEPSTREAM_BINARIES_AMD64_SHA256": gh_asset_digest(repo, tag, f"deepstream-binaries-x86_{v}_amd64.deb"),
        "DEEPSTREAM_BINARIES_ARM64_SHA256": gh_asset_digest(repo, tag, f"deepstream-binaries-aarch64_{v}_arm64.deb"),
        **deepstream_oss_pins(http_text(
            f"https://raw.githubusercontent.com/{repo}/{tag}/scripts/install_opensource_deps.sh")),
    }


def spec_deepstream(cur):
    """The newest tag whose own release carries deepstream.sh's runtime deb; v9.1.0.x tags have no release at all."""
    tags = sorted((t for t in ls_remote_tags("NVIDIA/DeepStream") if re.fullmatch(r"v\d+(?:\.\d+)+", t)),
                  key=_vkey, reverse=True)
    base = "https://github.com/NVIDIA/DeepStream/releases/download"
    for tag in tags[:10]:
        v = tag[1:]
        if artifact_exists(f"{base}/{tag}/deepstream-binaries-x86_{v}_amd64.deb"):
            return v, (deepstream_pins(v) if v != cur and WRITE_MODE else {})
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
    raw = gzip.decompress(http_bytes(
        f"https://developer.download.nvidia.com/compute/cuda/repos/{repo}/x86_64/Packages.gz")).decode("utf-8")
    return [dict(re.findall(r"^([A-Za-z0-9-]+): (.*)$", block, re.M)) for block in raw.split("\n\n")]


def deepstream_trt_pins(stanzas, trt_version: str, cuda: str) -> dict[str, str]:
    """Each TensorRT 10 deb's sha256 at <trt_version>-1+cuda<cuda>, from parsed Packages stanzas."""
    want = f"{trt_version}-1+cuda{cuda}"
    pins = {}
    for key, pkg in _DEEPSTREAM_TRT_DEBS:
        hit = next((s for s in stanzas if s.get("Package") == pkg and s.get("Version") == want), None)
        if not hit or "SHA256" not in hit:
            raise RuntimeError(f"Packages index has no {pkg} {want}")
        pins[key] = hit["SHA256"].lower()
    return pins


def spec_deepstream_trt(cur):
    """The newest TensorRT 10 (DeepStream links libnvinfer.so.10) the repo builds for DEEPSTREAM_TENSORRT_CUDA."""
    env = read_env()
    cuda = env["DEEPSTREAM_TENSORRT_CUDA"]
    stanzas = nvidia_apt_packages(env["DEEPSTREAM_TENSORRT_REPO"])
    found = [m.group(1) for s in stanzas if s.get("Package") == "libnvinfer10"
             if (m := re.fullmatch(rf"(10\.[\d.]+)-1\+cuda{re.escape(cuda)}", s.get("Version", "")))]
    if not found:
        raise RuntimeError(f"no libnvinfer10 10.x for cuda{cuda} in {env['DEEPSTREAM_TENSORRT_REPO']}")
    v = max(found, key=_vkey)
    return v, (deepstream_trt_pins(stanzas, v, cuda) if v != cur and WRITE_MODE else {})


def gh_archive_sha256(repo: str, tag: str) -> str:
    return sha256_of_url(f"https://github.com/{repo}/archive/refs/tags/{tag}.tar.gz")


def spec_hailort(cur):
    v = gh_latest("hailo-ai/hailort").lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        extras["HAILORT_COMMIT"] = ls_remote_tag_commit("hailo-ai/hailort", f"v{v}")
        extras["HAILORT_SOURCE_SHA256"] = gh_archive_sha256("hailo-ai/hailort", f"v{v}")
    return v, extras


def hailo_protobuf_version(hailort_version: str) -> str:
    """The protobuf HailoRT's cmake/external/protobuf.cmake fetches at a tag, from its GIT_TAG's '# vX.Y' comment."""
    text = http_text(f"https://raw.githubusercontent.com/hailo-ai/hailort/v{hailort_version}"
                     "/hailort/cmake/external/protobuf.cmake")
    m = re.search(r"GIT_TAG\s+[0-9a-f]{40}\s*#\s*v(\d+(?:\.\d+)+)", text)
    if not m:
        raise RuntimeError(f"HailoRT v{hailort_version}: protobuf.cmake names no '# vX.Y' GIT_TAG")
    return m.group(1)


def spec_hailo_protobuf(cur):
    """Slaved to HAILORT_VERSION: build-hailort.sh stages the protobuf HailoRT's own FetchContent pins."""
    v = hailo_protobuf_version(read_env()["HAILORT_VERSION"])
    extras = {}
    if v != cur and WRITE_MODE:
        extras["HAILO_PROTOBUF_SHA256"] = gh_archive_sha256("protocolbuffers/protobuf", f"v{v}")
    return v, extras


def spec_tappas(cur):
    v = gh_latest("hailo-ai/tappas").lstrip("v")
    return v, ({"TAPPAS_SOURCE_SHA256": gh_archive_sha256("hailo-ai/tappas", f"v{v}")} if v != cur and WRITE_MODE else {})


def spec_hailo_libzmq(cur):
    v = gh_latest("zeromq/libzmq").lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        extras["HAILO_LIBZMQ_SHA256"] = asset_sha256("zeromq/libzmq", f"v{v}", f"zeromq-{v}.tar.gz")
    return v, extras


def spec_hailo_cppzmq(cur):
    v = gh_latest("zeromq/cppzmq").lstrip("v")
    return v, ({"HAILO_CPPZMQ_SHA256": gh_archive_sha256("zeromq/cppzmq", f"v{v}")} if v != cur and WRITE_MODE else {})


_ROCM_TARBALL_BASE = "https://stable.repo.amd.com/rocm/core/tarball"


def rocm_windows_tarball_url(family: str, release: str) -> str:
    return f"{_ROCM_TARBALL_BASE}/therock-dist-windows-{family}-{release}.tar.gz"


def spec_rocm_windows(cur):
    """TheRock's newest Windows tarball for ROCM_WINDOWS_GFX_FAMILY; AMD publishes no checksum, so a bump hashes ~2.2 GB."""
    family = read_env()["ROCM_WINDOWS_GFX_FAMILY"]
    html = http_text(f"{_ROCM_TARBALL_BASE}/")
    found = re.findall(rf"therock-dist-windows-{re.escape(family)}-(\d+\.\d+\.\d+)\.tar\.gz", html)
    if not found:
        raise RuntimeError(f"AMD's tarball index lists no therock-dist-windows-{family}-<release>.tar.gz")
    v = max(found, key=_vkey)
    extras = {}
    if v != cur and WRITE_MODE:
        extras["ROCM_WINDOWS_TARBALL_SHA256"] = sha256_of_url(rocm_windows_tarball_url(family, v))
    return v, extras


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
    ("GITLEAKS_VERSION", spec_gitleaks, "none (host-side secret-scan bootstrap; linux+windows)"),
    ("MOLD_LINUX_VERSION", spec_mold, "none (opt-in linker, fetched on demand)"),
    ("RENOVATE_NODE_VERSION", spec_renovate_node, "none (renovate-local.sh bootstrap; same-major only)"),
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
    # The rocm venv's PyPI extra: URL + PyPI's own digest, re-derived by hand (recipe in versions.env).
    "TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_URL", "TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_SHA256",
    # The CUDA line and apt repo NVIDIA builds TensorRT 10 for; spec_deepstream_trt reads them, nothing publishes a successor.
    "DEEPSTREAM_TENSORRT_CUDA", "DEEPSTREAM_TENSORRT_REPO",
]


# Hand-pinned wheel stores: each <prefix>*_URL with a *_SHA256 beside it is that wheel's version, moved with the SHA.
WHEEL_URL_GROUPS = {
    "PYTEST_WINDOWS_ARM64_": "cp314 win_arm64 pytest closure at the versions OrchestrANT's x64 lock runs (CON67)",
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


def audit_sha_pairs() -> int:
    """Fail when a *_SHA256/*_SHA512 key is neither quoted in this source (a spec or MANUAL names it), held, exempt nor URL-paired."""
    env = read_env()
    holds = read_holds()
    url_paired = url_paired_sha_keys(env)
    src = Path(__file__).read_text(encoding="utf-8")
    counts = {"specced": 0, "held": 0, "exempt": 0, "url-paired": 0}
    stray: list[str] = []
    for key in sorted(env):
        if not (key.endswith("_SHA256") or key.endswith("_SHA512")):
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
    ap.add_argument(
        "--audit-unclassified", action="store_true",
        help="Offline: fail when a pin-file key is in no tier, derivation, wheel group, "
             "renovate annotation or the non-version filter (the --check self-audit, as a gate).")
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
        r"|^APP_REF$)"  # a tracked branch, resolved to a commit per run
    )
    return sorted(k for k in env if k not in covered and not nonversion.search(k))


def _print_unclassified(env):
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
    names = ", ".join(str(p.relative_to(REPO_ROOT)) for p in pin_files())
    print(f"\nWrote {len(changed)} key(s) to {names}.")
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
