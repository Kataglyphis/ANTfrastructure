#!/usr/bin/env python3
"""bump_versions.py — automated updater for linux/scripts/01-core/versions.env.

Queries every upstream (GitHub releases with per-asset sha256 digests, registry
manifests, nuget/nodejs/LunarG endpoints), then:

  --check          report current vs latest for ALL tracked keys (default)
  --write          bump the SAFE set to latest and refresh the paired *_SHA256
                   pins in one pass; HIGH-RISK keys are always report-only
  --only K1,K2     restrict --write to specific keys (must be in the safe set)

Safe vs report-only:
  * SAFE keys are self-contained tool/app pins whose failures surface at
    download/install time (pwsh, git, cmake, node, uv, ollama, ...).
  * REPORT-ONLY keys (GCC, LLVM, CUDA/cuDNN/TensorRT, ONNX/LiteRT/TVM/IREE,
    GStreamer, PyAV, Android, ROCm) carry source patches and multi-hour build
    entanglement — bump them deliberately, one at a time, by hand.

After a --write, finish with (same ritual as AGENTS.md § Version Bumping):
    python docs/scripts/sync_versions.py --write
    bash linux/scripts/01-core/verify-arg-consistency.sh
    bash linux/scripts/preflight.sh

GitHub is queried via `git ls-remote --tags` (NOT the REST API), so there is
no rate limit to wait for. Checksums come from each project's published
sums-file release asset where one exists (pwsh hashes.sha256, uv *.sha256,
cmake SHA-256.txt, ollama sha256sum.txt, hadolint/actionlint checksums, node
SHASUMS256.txt, NVIDIA redist manifests) and otherwise from downloading the
artifact and hashing it (release downloads are not rate-limited either).
"""
from __future__ import annotations

import argparse
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

# Set by main() under --write: extras (checksum downloads, some GBs) are only
# computed when the result will actually be written.
WRITE_MODE = False


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
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


def http_header(url: str, header: str, accept: str, auth: str | None = None) -> str:
    extra = {"Accept": accept}
    if auth:
        extra["Authorization"] = auth
    req = urllib.request.Request(url, headers=_headers(extra), method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.headers.get(header, "")


def sha256_of_url(url: str) -> str:
    """Stream-download and hash (for artifacts without a published digest)."""
    h = hashlib.sha256()
    with urllib.request.urlopen(urllib.request.Request(url, headers=_headers()), timeout=600) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Datasources — GitHub via `git ls-remote` (NO REST API => NO rate limit).
# Checksums come from published sums-file assets where a project ships them,
# else by downloading the asset and hashing it (release downloads are not
# API-rate-limited either).
# ---------------------------------------------------------------------------
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


def gh_latest(repo: str, pattern: str | None = None) -> str:
    """Newest version tag of a GitHub repo via ls-remote. `pattern` restricts
    the tag shape (default: plain version tags); prerelease-looking tags are
    always excluded."""
    rx = re.compile(pattern) if pattern else re.compile(r"^(v|version_)?\d+(?:[._]\d+)*$")
    cand = [t for t in ls_remote_tags(repo) if rx.match(t) and not PRERELEASE_RX.search(t)]
    if not cand:
        raise RuntimeError(f"no matching tags for {repo} (pattern {rx.pattern})")
    return max(cand, key=_vkey)


def asset_sha256(repo: str, tag: str, asset: str, sums: tuple[str, ...] = ()) -> str:
    """sha256 of a release asset: prefer the project's published sums file(s);
    fall back to downloading the asset itself and hashing it."""
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


def npm_latest(pkg: str) -> str:
    return http_json(f"https://registry.npmjs.org/{urllib.parse.quote(pkg, safe='')}/latest")["version"]


def gitlab_latest_tag(host: str, project: str, pattern: str) -> str:
    """Newest tag matching `pattern` on a GitLab instance (tags are updated-desc)."""
    rx = re.compile(pattern)
    tags = http_json(f"https://{host}/api/v4/projects/{urllib.parse.quote(project, safe='')}/repository/tags?per_page=100")
    matches = [t["name"] for t in tags if rx.match(t["name"])]
    return max(matches, key=lambda v: [int(x) for x in re.findall(r"\d+", v)]) if matches else ""


def nvidia_redist_latest(product: str) -> str:
    """Newest redistrib_<version>.json in NVIDIA's redist index for a product."""
    html = http_text(f"https://developer.download.nvidia.com/compute/{product}/redist/")
    versions = re.findall(r"redistrib_(\d+(?:\.\d+)+)\.json", html)
    return max(versions, key=lambda v: [int(x) for x in v.split(".")]) if versions else ""


def rocm_apt_latest() -> str:
    """Newest ROCm version directory in AMD's apt repo index."""
    html = http_text("https://repo.radeon.com/rocm/apt/")
    versions = re.findall(r'href="(\d+\.\d+(?:\.\d+)?)/"', html)
    return max(versions, key=lambda v: [int(x) for x in v.split(".")]) if versions else ""


# ---------------------------------------------------------------------------
# versions.env access
# ---------------------------------------------------------------------------
def read_env() -> dict[str, str]:
    vals = {}
    for line in VERSIONS_ENV.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
        if m:
            vals[m.group(1)] = m.group(2).strip().strip('"')
    return vals


def read_holds() -> set[str]:
    """Keys whose contiguous leading comment block contains 'bump:hold'.

    A hold pins a key against ANY automated write (safe tier and --write-all)
    until a human removes the marker — used when upstream's latest release is
    broken (e.g. LiteRT-LM v0.14.0's incomplete GitHub CMake export). Blank
    lines end a comment block, so the marker must sit directly above the key.
    """
    holds: set[str] = set()
    block_held = False
    # Structural validation (backlog F4): a hold only attaches via a CONTIGUOUS
    # comment block, so an innocently inserted blank line between the marker
    # and its KEY= silently DISARMS the hold — for protoc that is precisely the
    # 2026-08-03 gencode-#error incident replayed. Track every marker line and
    # hard-fail if any never attached to a key.
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
            # Non-comment, non-key line (blank line, stray text) ended the
            # block without attaching — the hold is disarmed.
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
    """Derive the CORRECT host protoc for LITERT_LM_VERSION (a slaved pin).

    PROTOC_VERSION is not independent software: it must match the protobuf
    runtime pinned inside LiteRT-LM's cmake/packages/protobuf/protobuf.cmake
    (GIT_TAG vMAJOR.MINOR.PATCH, e.g. v6.31.1 -> protoc 31.1). Auto-bumping it
    to latest once shipped gencode the pinned runtime #error'd on (2026-08-03).
    Returns e.g. '31.1', or None when the file/tag layout is unrecognizable.
    """
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


def write_env_values(updates: dict[str, str]) -> list[str]:
    """Rewrite KEY=value lines in place, preserving everything else byte-for-byte.

    Held keys (see read_holds) are dropped here as a last line of defense; the
    tier loops in main() already skip them with a visible HELD note.
    """
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


# ---------------------------------------------------------------------------
# Key specs — each returns (new_version, {other_env_key: value}) or raises.
# `impact` documents which build layers a bump invalidates (cost awareness).
# ---------------------------------------------------------------------------
def spec_pwsh(cur):
    tag = gh_latest("PowerShell/PowerShell")
    v = tag.lstrip("v")
    extras = {}
    if v != cur and WRITE_MODE:
        extras["PWSH_ZIP_SHA256"] = asset_sha256(
            "PowerShell/PowerShell", tag, f"PowerShell-{v}-win-x64.zip", sums=("hashes.sha256",))
    return v, extras


def spec_git(cur):
    # ONLY .windows.1 releases: setup-scoop-tools.ps1 derives the installer URL
    # with a hardcoded ".windows.1" tag suffix (respins need -GitInstallerUrl).
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


def spec_binaryen(cur):
    v = gh_latest("WebAssembly/binaryen", pattern=r"^version_\d+$")
    extras = {}
    if v != cur and WRITE_MODE:
        for env_key, asset in [
            ("BINARYEN_LINUX_X86_64_SHA256", f"binaryen-{v}-x86_64-linux.tar.gz"),
            # F6: aarch64 tarball ships in every release alongside x86_64 (asset
            # name verified on version_131) and is consumed by lib/wasm-opt.sh for
            # arm64 — refresh it in step so a binaryen bump can't freeze it stale.
            ("BINARYEN_LINUX_AARCH64_SHA256", f"binaryen-{v}-aarch64-linux.tar.gz"),
            ("BINARYEN_WINDOWS_X86_64_SHA256", f"binaryen-{v}-x86_64-windows.tar.gz"),
        ]:
            extras[env_key] = asset_sha256("WebAssembly/binaryen", v, asset)
    return v, extras


def spec_shellcheck(cur):
    # F6: shellcheck ships byte-stable release ASSETS (not archive tarballs), so
    # both pins refresh cleanly on a bump. koalaman/shellcheck publishes no sums
    # file, so asset_sha256 falls back to download-and-hash. Both current SHAs
    # verified to match v0.11.0's assets. Keep the leading v (env stores it).
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
    # The repo deliberately pins an odd-minor (development-series) release, so the
    # newest tag overall is the right comparison — not stable-only.
    tags = http_json(
        "https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fgstreamer/repository/tags?per_page=100")
    v = max((t["name"] for t in tags if re.match(r"^\d+\.\d+\.\d+$", t["name"])),
            key=lambda s: [int(x) for x in s.split(".")], default="")
    extras = {}
    # F6: the android-universal tarball ships a `.sha256sum` sidecar on freedesktop
    # (verified for 1.29.2) — refresh GSTREAMER_ANDROID_UNIVERSAL_SHA256 from it so
    # a gstreamer bump can't freeze it stale. Not every dev tag publishes an
    # android build; a --write to such a version fails loud on the missing sidecar.
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
    # flutter/flutter's GitHub "latest release" is unmaintained (returns stale
    # betas); the flutter_infra_release JSON is the authoritative stable pointer.
    data = http_json("https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json")
    stable_hash = data["current_release"]["stable"]
    rel = next(r for r in data["releases"] if r["hash"] == stable_hash and r["channel"] == "stable")
    v = rel["version"]
    extras = {}
    # F6: the same release object carries the SDK tarball's sha256 — refresh
    # FLUTTER_SDK_SHA256 in step so a flutter bump can't freeze it stale.
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
    # Same-major lock: WiX majors (4 -> 5 -> 7) change the CLI/authoring model —
    # newer majors show up in the report note, not as an automatic bump.
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
    return http_text("https://vulkan.lunarg.com/sdk/latest/linux.txt").strip(), {}


def spec_app_ref(cur):
    # The app repo publishes TAGS, not GitHub releases — same tag-scan
    # build.ps1's -LatestApp uses via ls-remote.
    return gh_latest("Kataglyphis/Kataglyphis-Orchestr-ANT-ion", pattern=r"^v?\d+(\.\d+)*$"), {}


def spec_ubuntu_digest(cur):
    env = read_env()
    return dockerhub_manifest_digest("library/ubuntu", env["UBUNTU_VERSION"]), {}


def spec_windows_digest(cur):
    env = read_env()
    return mcr_manifest_digest("windows/servercore", f"ltsc{env['WINDOWS_LTSC']}"), {}


def spec_cuda(cur):
    """CUDA latest from the redist index; a CHANGED version also re-downloads
    the full Windows installer (~3.7 GB, background-tolerable) to refresh
    CUDA_INSTALLER_SHA256 — a stale hash would fail the next GPU base build."""
    v = nvidia_redist_latest("cuda")
    extras = {}
    if v and v != cur and WRITE_MODE:
        extras["CUDA_INSTALLER_SHA256"] = sha256_of_url(
            f"https://developer.download.nvidia.com/compute/cuda/{v}/local_installers/cuda_{v}_windows.exe"
        )
    return v, extras


def spec_cudnn(cur):
    """cuDNN: the redist index lists 3-part labels, but the download URLs need
    the FULL 4-part version — read it (and the zip's sha256) from the redist
    manifest itself, preferring the cuda major that matches CUDA_VERSION."""
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


# --- report-only latest lookups (high-risk stack pins) ---
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
    # (env key, spec, rebuild impact of a bump)
    ("PWSH_VERSION", spec_pwsh, "windows base (full — pwsh is layer 1)"),
    ("GIT_VERSION", spec_git, "windows base scoop layer"),
    ("NUGET_VERSION", spec_nuget, "windows toolchain run (cheap)"),
    ("UV_VERSION", spec_uv, "linux base uv layer + tail"),
    ("NODE_VERSION", spec_node, "linux base node layer + tail (same-major only)"),
    ("CMAKE_VERSION", spec_cmake, "linux base + windows scoop layer"),
    ("OLLAMA_VERSION", spec_ollama, "llm-stack image only"),
    ("PANDOC_VERSION", spec_pandoc, "documentation image only"),
    ("BINARYEN_VERSION", spec_binaryen, "none (host-side bootstrap)"),
    ("HADOLINT_VERSION", spec_hadolint, "none (host-side lint bootstrap)"),
    ("ACTIONLINT_VERSION", spec_actionlint, "none (host-side lint bootstrap)"),
    ("SHELLCHECK_VERSION", spec_shellcheck, "none (host-side lint bootstrap; linux+windows)"),
    ("RUST_VERSION", spec_rust, "linux toolchain rust layer + tail"),
    ("CARGO_C_VERSION", spec_cargo_c, "linux toolchain rust layer + tail"),
    ("FLUTTER_VERSION", spec_flutter, "linux sdk flutter layer"),
    ("WIX_VERSION", spec_wix, "windows base scoop layer"),
    ("WIX_UI_EXT_VERSION", spec_wix_ui, "windows base scoop layer"),
    ("PYTHON_VERSION", spec_python, "linux+windows toolchain CPython builds (same-minor only)"),
    ("VULKAN_VERSION", spec_vulkan, "linux base/sdk + windows scoop layer"),
    ("GSTREAMER_VERSION", spec_gstreamer, "linux media gstreamer stage (+ android universal)"),
    ("APP_REF", spec_app_ref, "torch + final leaves (minutes)"),
    ("UBUNTU_DIGEST", spec_ubuntu_digest, "linux base (full chain)"),
    ("WINDOWS_BASE_DIGEST", spec_windows_digest, "windows base (full chain)"),
]

REPORT: list[tuple[str, Callable]] = [
    ("LLVM_RELEASE", _r("llvm/llvm-project", prefix="llvmorg-")),
    ("GCC_VERSION", _r("gcc-mirror/gcc", pattern=r"^releases/gcc-\d+\.\d+\.\d+$", prefix="releases/gcc-")),
    ("ONNXRUNTIME_VERSION", _r("microsoft/onnxruntime", strip_v=False)),
    ("ONNXRUNTIME_GENAI_VERSION", _r("microsoft/onnxruntime-genai", strip_v=False)),
    ("LITERT_VERSION", _r("google-ai-edge/LiteRT", strip_v=False)),
    ("LITERT_LM_VERSION", _r("google-ai-edge/LiteRT-LM")),
    ("TVM_REF", _r("apache/tvm", strip_v=False)),
    ("IREE_VERSION", _r("iree-org/iree", strip_v=False)),
    # GSTREAMER_VERSION moved to SPECS (spec_gstreamer) so it also refreshes the
    # android-universal tarball SHA (F6); the version-detection logic is unchanged.
    ("PYAV_VERSION", _r("PyAV-Org/PyAV")),
    ("NV_CODEC_HEADERS_REF", _r("FFmpeg/nv-codec-headers", strip_v=False, pattern=r"^n[\d.]+$")),
    # -- media/library build deps --
    ("VVDEC_VERSION", _r("fraunhoferhhi/vvdec", strip_v=False)),
    ("TENSORFLOW_C_VERSION", _r("tensorflow/tensorflow")),
    ("OPENVINO_VERSION", _r("openvinotoolkit/openvino")),
    ("ARMNN_VERSION", _r("ARM-software/armnn", strip_v=False, pattern=r"^v\d+\.\d+$")),
    ("ACL_VERSION", _r("ARM-software/ComputeLibrary", strip_v=False, pattern=r"^v\d+\.\d+(\.\d+)?$")),
    ("RICE_VERSION", _r("ystreet/librice", strip_v=False, pattern=r"^v\d+\.\d+\.\d+$")),
    ("ABSEIL_VERSION", _r("abseil/abseil-cpp", strip_v=False)),
    ("FREETYPE_VERSION", lambda cur: (
        gh_latest("freetype/freetype", pattern=r"^VER-\d+-\d+-\d+$")
        .removeprefix("VER-").replace("-", "."), {})),
    ("LIBPNG_VERSION", _r("pnggroup/libpng", pattern=r"^v\d+\.\d+\.\d+$")),
    ("GOBJECT_INTROSPECTION_VERSION", lambda cur: (
        gitlab_latest_tag("gitlab.gnome.org", "GNOME/gobject-introspection", r"^\d+\.\d+\.\d+$"), {})),
    # -- npm-vendored web runtimes (media litert stage) --
    ("LITERTJS_VERSION", lambda cur: (npm_latest("@litertjs/core"), {})),
    ("MEDIAPIPE_GENAI_VERSION", lambda cur: (npm_latest("@mediapipe/tasks-genai"), {})),
    # -- riscv64 cross wheel builds --
    ("PYTORCH_VERSION", _r("pytorch/pytorch", strip_v=False)),
    ("TORCHVISION_VERSION", _r("pytorch/vision", strip_v=False)),
    # -- GPU stacks (vendor indexes; versions are LISTINGS, driver compat is on you) --
    ("CUDA_VERSION", spec_cuda),
    ("CUDNN_VERSION", spec_cudnn),
    ("ROCM_VERSION", lambda cur: (rocm_apt_latest(), {})),
    # -- assorted build deps --
    ("ANTLR_VERSION", _r("antlr/antlr4")),
    # protoc/protobuf are a COUPLED pair: protoc X.Y ships as python protobuf
    # (X+? major offset) — bump them together or codegen and runtime disagree.
    ("PROTOC_VERSION", _r("protocolbuffers/protobuf")),
    ("PROTOBUF_VERSION", lambda cur: (
        http_json("https://pypi.org/pypi/protobuf/json")["info"]["version"], {})),
    ("VCPKG_REF", _r("microsoft/vcpkg", strip_v=False)),
]

MANUAL = [
    # No reliable programmatic source, platform choices, or deliberate pins:
    # TensorRT (EULA portal), MIGraphX (rides the ROCm release), Android
    # cmdline-tools/NDK (repository XML is a moving matrix), host/base platform
    # pins, the deliberately-dated Rust nightly, and the branch trackers.
    "TENSORRT_VERSION", "MIGRAPHX_VERSION",
    "ANDROID_SDK_VERSION", "ANDROID_NDK_VERSION", "ANDROID_COMPILE_SDK",
    "ANDROID_BUILD_TOOLS", "ANDROID_CMAKE_VERSION", "ANDROID_API_LEVEL",
    "UBUNTU_VERSION", "UBUNTU_CODENAME", "WINDOWS_LTSC", "WINDOWS_SDK_BUILD",
    "VISUAL_STUDIO_VERSION", "RUST_NIGHTLY_TOOLCHAIN",
    "OPENCV_VERSION", "FFMPEG_VERSION",
    "JRE_VERSION", "LIBFFI_MESON_VERSION",
]


def audit_sha_pairs() -> int:
    """Backlog F6 prep: no *_SHA256/*_SHA512 key may sit outside the refresh net.

    Coverage heuristic (documented, deliberately simple): a pin key counts as
    covered when its NAME appears in this script's source — every bump spec
    hardcodes the sha keys it refreshes in its extras dict. Keys under
    bump:hold are frozen by definition; the allowlist carries the documented
    exceptions. Anything else = a version bump would silently freeze its SHA,
    surfacing only as a download-verify failure mid-chain.
    """
    env = read_env()
    holds = read_holds()
    allow = {
        # EULA-gated manual download — deliberately empty, documented in
        # versions.env next to the key.
        "TENSORRT_ZIP_SHA256",
        # F6: unversioned bootstrap installer scripts — their upstream URL is
        # always-latest (no release tag to bump in step with), so they cannot be
        # tracked by a version bump. The hash is pinned and re-reviewed BY HAND
        # on each deliberate update (the fetch recipe lives in versions.env next
        # to each key). Allowlisted, not held: they DO change, just not on a
        # version schedule.
        "RUSTUP_INIT_SHA256",   # sh.rustup.rs
        "UV_INSTALL_SH_SHA256",  # astral.sh/uv/install.sh
        "SCOOP_INSTALLER_SHA256",  # get.scoop.sh
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


def main() -> int:
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
    args = ap.parse_args()
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
    # Lookup failures must not abort the sweep (a single flaky registry would
    # hide every other key's status) — but they must not vanish into a rc-0
    # report either: a cron/CI caller previously read "success" while half the
    # keys said "lookup failed". Count them; nonzero exit at the end.
    lookup_failures = 0
    print(f"{'KEY':32} {'CURRENT':22} {'LATEST':22} NOTE")
    print("-" * 100)

    for key, spec, impact in SAFE:
        if only and key not in only:
            continue
        cur = env.get(key, "")
        try:
            latest, extras = spec(cur)
        except Exception as e:  # noqa: BLE001 — report and move on, never abort the sweep
            print(f"{key:32} {cur:22} {'?':22} lookup failed: {e}")
            lookup_failures += 1
            continue
        if latest == cur:
            print(f"{key:32} {cur:22} {latest:22} up to date")
            continue
        if key in holds:
            print(f"{key:32} {cur:22} {latest:22} HELD (bump:hold in versions.env)")
            continue
        print(f"{key:32} {cur:22} {latest:22} BUMP - rebuilds: {impact}")
        if args.write:
            updates[key] = latest
            updates.update(extras)
            for ek, ev in extras.items():
                print(f"  {ek:30} -> {ev}")

    tier_label = "WRITTEN under --write-all" if args.write_all else "bump by hand, one at a time"
    print(f"\n-- report tier ({tier_label} - patches/build entanglement) --")
    for key, spec in REPORT:
        if only:
            continue
        cur = env.get(key, "")
        try:
            # NB: extras (paired *_SHA256 refreshes, e.g. CUDA installer / cuDNN
            # zip) MUST be applied under --write-all — discarding them once
            # shipped a 13.3.1 version pin with 13.3.0's installer hash, which
            # the download gate then (correctly) refused mid-build.
            latest, extras = spec(cur)
        except Exception as e:  # noqa: BLE001
            print(f"{key:32} {cur:22} {'?':22} lookup failed: {e}")
            lookup_failures += 1
            continue
        if not latest:
            print(f"{key:32} {cur:22} {'?':22} lookup returned nothing")
            continue
        if latest.lstrip("v") == cur.lstrip("v"):
            print(f"{key:32} {cur:22} {latest:22} up to date")
            continue
        if key in holds:
            note = "HELD (bump:hold in versions.env)"
            if key == "PROTOC_VERSION":
                derived = derive_protoc_from_litert_lm(env.get("LITERT_LM_VERSION", ""))
                if derived:
                    ok = "matches" if derived == cur else f"MISMATCH — set PROTOC_VERSION={derived}"
                    note += f"; slaved pin derived from LiteRT-LM's protobuf.cmake: {derived} ({ok})"
            print(f"{key:32} {cur:22} {latest:22} {note}")
            continue
        marker = "BUMP (--write-all)" if args.write_all else "NEWER AVAILABLE"
        print(f"{key:32} {cur:22} {latest:22} {marker}")
        if key == "LITERT_LM_VERSION":
            # F4 soft rider: PROTOC_VERSION is a slaved, bump:hold'd pin — a
            # LiteRT-LM bump without re-deriving it replays the 2026-08-03
            # gencode-#error incident. Nudge with the NEW tag's derivation.
            _derived = derive_protoc_from_litert_lm(latest)
            _hint = "PROTOC_VERSION is SLAVED to this pin (bump:hold) — re-derive when bumping"
            if _derived:
                _hint += f"; the new tag's protobuf.cmake wants protoc {_derived}"
            print(f"  NOTE: {_hint}")
        if args.write_all:
            updates[key] = latest
            updates.update(extras)
            for ek, ev in extras.items():
                print(f"  {ek:30} -> {ev}")

    print("\n-- manual (no reliable programmatic source / deliberate pins) --")
    for key in MANUAL:
        print(f"{key:32} {env.get(key, ''):22} {'-':22} check vendor release notes")

    # Coverage self-audit: every versions.env key must be SAFE, REPORT, MANUAL,
    # or a recognized non-version key (checksums/digests are refreshed as the
    # paired extras of their version key; toggles/paths/registry aren't
    # versions). Anything else prints here — add it to a tier when it appears.
    covered = {k for k, _, _ in SAFE} | {k for k, _ in REPORT} | set(MANUAL)
    nonversion = re.compile(
        r"(SHA256|^ORT_|_ENABLE_|^USE_|^FAST_UBUNTU|^IMAGE_REGISTRY_PREFIX$"
        r"|^CROSS_DEFAULT_ARCHES$|^VENV_PATH$|_OUTPUT_DIR$|^GSTREAMER_PREFIX$"
        r"|_COMMIT$|^CUDA_ARCHITECTURES$)"
    )
    unclassified = sorted(k for k in env if k not in covered and not nonversion.search(k))
    if unclassified:
        print("\n-- UNCLASSIFIED versions.env keys (add to SAFE/REPORT/MANUAL or the non-version filter) --")
        for k in unclassified:
            print(f"{k:32} {env.get(k, ''):22}")

    if args.write:
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
    if lookup_failures:
        print(
            f"\nWARNING: {lookup_failures} lookup(s) failed — the report above is "
            "INCOMPLETE for those keys. Exiting nonzero so scripted callers notice.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
