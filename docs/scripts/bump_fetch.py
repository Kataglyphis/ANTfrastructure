#!/usr/bin/env python3
"""Network and digest helpers for bump_versions.py: HTTP, git ls-remote, release assets and registry digests."""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import urllib.parse
import urllib.request
from typing import Any

import bump_versions as bv  # tests patch names on bump_versions; every call reads them through it

UA = {"User-Agent": "kataglyphis-bump-versions"}


# HTTP helpers
_GITHUB_HOSTS = {"github.com", "api.github.com", "raw.githubusercontent.com"}


def _headers(url: str, extra: dict | None = None) -> dict:
    h = dict(bv.UA)
    tok = os.environ.get("GITHUB_TOKEN")
    # GitHub's token goes to GitHub only; Bitbucket answers a foreign bearer with 400.
    if tok and urllib.parse.urlsplit(url).hostname in bv._GITHUB_HOSTS:
        h["Authorization"] = f"Bearer {tok}"
    if extra:
        h.update(extra)
    return h


def http_json(url: str) -> Any:
    with urllib.request.urlopen(urllib.request.Request(url, headers=bv._headers(url)), timeout=60) as r:
        return json.load(r)


def http_text(url: str) -> str:
    with urllib.request.urlopen(urllib.request.Request(url, headers=bv._headers(url)), timeout=60) as r:
        return r.read().decode("utf-8", errors="replace")


def http_bytes(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=bv._headers(url)), timeout=60) as r:
        return r.read()


def http_header(url: str, header: str, accept: str, auth: str | None = None) -> str:
    extra = {"Accept": accept}
    if auth:
        extra["Authorization"] = auth
    req = urllib.request.Request(url, headers=bv._headers(url, extra), method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.headers.get(header, "")


# sha256("") marks a silently empty download; committed as a pin it bricks the consuming stage.
_EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def sha256_of_gz_stream(url: str) -> str:
    """Hash a .tar.gz's decompressed stream, which outlives GitHub's gzip stability pledge; pairs with download_verified_file()'s "stream" mode."""
    import gzip
    h = hashlib.sha256()
    with urllib.request.urlopen(urllib.request.Request(url, headers=bv._headers(url)), timeout=600) as r, \
            gzip.GzipFile(fileobj=r) as gz:
        for chunk in iter(lambda: gz.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_of_url(url: str) -> str:
    """Stream-download and hash (for artifacts without a published digest)."""
    h = hashlib.sha256()
    n = 0
    with urllib.request.urlopen(urllib.request.Request(url, headers=bv._headers(url)), timeout=600) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
            n += len(chunk)
    digest = h.hexdigest()
    if n == 0 or digest == bv._EMPTY_SHA256:
        raise RuntimeError(f"empty download for {url} — refusing sha256('') as a pin (BT2)")
    return digest


def artifact_exists(url: str) -> bool:
    """Probe an artifact URL with a one-byte GET (BT2: report artifacts, not just git tags)."""
    try:
        # Not HEAD: the CDN behind an authenticated GitHub release download answers HEAD with 401.
        req = urllib.request.Request(url, headers=bv._headers(url, {"Range": "bytes=0-0"}))
        with urllib.request.urlopen(req, timeout=30) as r:
            return 200 <= r.status < 300
    except OSError:
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
    cand = [t for t in bv.ls_remote_tags(repo) if rx.match(t) and not bv.PRERELEASE_RX.search(t)]
    if not cand:
        raise RuntimeError(f"no matching tags for {repo} (pattern {rx.pattern})")
    return max(cand, key=bv._vkey)


def asset_sha256(repo: str, tag: str, asset: str, sums: tuple[str, ...] = ()) -> str:
    """sha256 of a release asset from the project's sums file, else by downloading and hashing it."""
    base = f"https://github.com/{repo}/releases/download/{tag}/"
    for sums_name in sums:
        try:
            text = bv.http_text(base + sums_name)
        except OSError:
            text = None
        if text is None:
            continue
        m = re.search(rf"([0-9a-fA-F]{{64}})[ \t*]+\.?/?{re.escape(asset)}\s*$", text, re.MULTILINE)
        if m:
            return m.group(1).lower()
    return bv.sha256_of_url(base + asset)


def dockerhub_manifest_digest(repo: str, tag: str) -> str:
    tok = bv.http_json(
        f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
    )["token"]
    return bv.http_header(
        f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}",
        "Docker-Content-Digest",
        "application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json",
        auth=f"Bearer {tok}",
    )


def mcr_manifest_digest(repo: str, tag: str) -> str:
    return bv.http_header(
        f"https://mcr.microsoft.com/v2/{repo}/manifests/{tag}",
        "Docker-Content-Digest",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    )


def nvidia_redist_latest(product: str) -> str:
    """Newest redistrib_<version>.json in NVIDIA's redist index for a product."""
    html = bv.http_text(f"https://developer.download.nvidia.com/compute/{product}/redist/")
    versions = re.findall(r"redistrib_(\d+(?:\.\d+)+)\.json", html)
    return max(versions, key=lambda v: [int(x) for x in v.split(".")]) if versions else ""


def _nuget_pkg_latest(pkg: str, same_major_as: str = "") -> str:
    idx = bv.http_json(f"https://api.nuget.org/v3-flatcontainer/{pkg.lower()}/index.json")
    stable = [v for v in idx["versions"] if "-" not in v]
    if same_major_as:
        major = same_major_as.split(".")[0]
        stable = [v for v in stable if v.split(".")[0] == major] or stable[-1:]
    return stable[-1] if stable else idx["versions"][-1]


def gh_asset_digest(repo: str, tag: str, asset: str) -> str:
    """GitHub's own sha256 for a release asset, sparing a GB-sized download; hashes the asset when the API has none."""
    try:
        rel = bv.http_json(f"https://api.github.com/repos/{repo}/releases/tags/{tag}")
    except (OSError, json.JSONDecodeError):
        rel = None
    if rel is not None:
        for a in rel.get("assets", []):
            if a.get("name") == asset and str(a.get("digest", "")).startswith("sha256:"):
                return a["digest"].split(":", 1)[1].lower()
    return bv.asset_sha256(repo, tag, asset)


def ls_remote_branch_commit(url: str, branch: str) -> str:
    """Head commit of one branch of any git remote."""
    out = subprocess.run(["git", "ls-remote", url, f"refs/heads/{branch}"],
                         capture_output=True, text=True, timeout=120, check=False)
    m = re.match(r"([0-9a-f]{40})\t", out.stdout)
    if out.returncode or not m:
        raise RuntimeError(f"git ls-remote found no branch {branch} on {url}: {out.stderr.strip()[:200]}")
    return m.group(1)


def gh_archive_sha256(repo: str, tag: str) -> str:
    return bv.sha256_of_url(f"https://github.com/{repo}/archive/refs/tags/{tag}.tar.gz")
