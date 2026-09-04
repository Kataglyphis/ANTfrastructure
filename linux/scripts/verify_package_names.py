#!/usr/bin/env python3
"""Distro package names in linux/scripts vs the live Ubuntu indices.

Ubuntu 26.04 renamed libfreetype6-dev and dropped libopenexr-3-dev; the tree
only kept working because warm apt caches held the old index, and an unguarded
install_target_packages killed a stage four hours in. Full story + the
guarded/unguarded contract: docs/failure-modes.md#a-renamed-or-dropped-distro-package-kills-a-stage-hours-in

Exit 0 = clean or SKIPped (no network, no cache); 1 = a dead name at an
UNGUARDED call site; 2 = the extractor itself is broken (self-check).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS = os.path.join(REPO_ROOT, "linux", "scripts")
VERSIONS_ENV = os.path.join(SCRIPTS, "01-core", "versions.env")
MIRROR_SH = os.path.join(SCRIPTS, "01-core", "ubuntu-mirror.sh")

ARCHES = ("amd64", "arm64", "riscv64")
COMPONENTS = ("main", "restricted", "universe", "multiverse")
# Fallback pockets, queried only to confirm a name that looks dead in the base pocket.
EXTRA_POCKETS = ("-updates", "-security")

TARGET_INSTALLERS = ("install_target_packages", "install_optional_target_packages")
HOST_INSTALLERS = ("install_host_packages", "install_deps_preamble", "apt_install",
                   "apt_install_available")
# First arg is the destination array name, not a package.
APPEND_HELPERS = ("append_unique_packages", "append_available_packages")
# Helpers that probe apt and drop what it cannot resolve.
SELF_FILTERING = ("install_optional_target_packages", "append_available_packages",
                  "apt_install_available")
PROBE_CMDS = (
    "apt_package_exists", "apt_has_package", "cross_package_has_install_candidate",
    "dpkg -l", "dpkg -s", "dpkg-query", "apt-cache",
)

# Names here come from a NON-Ubuntu apt repo, so the Ubuntu indices cannot rule
# on them: a miss is reported UNVERIFIABLE, never dead. A stale entry fails.
VENDOR_REPO_FILES = (
    "linux/scripts/01-core/install-cuda-stack.sh",
    "linux/scripts/01-core/install-tensorrt.sh",
    "linux/scripts/01-core/setup-cuda-repo.sh",
    "linux/scripts/01-core/setup-rocm-repo.sh",
)
# Only vendor-shaped names are exempt; plain Ubuntu packages in the same file
# (curl, gpg, ...) stay failable. See docs/cross-build-verification.md.
VENDOR_NAME_RE = re.compile(r"^(lib)?(nccl|cudnn|cuda|tensorrt|nv|amdrocm|rocm|hip)")


def is_vendor(path, name):
    return path in VENDOR_REPO_FILES and bool(VENDOR_NAME_RE.match(name))

# Extraction self-check. Each sample is a shape that broke a real audit.
MUST_FIND = (
    ("linux/scripts/03-media/build/opencv/install-deps.sh", "libopenexr-dev", "one-per-line array"),
    ("linux/scripts/03-media/runtime/install-deps.sh", "dbus-x11", "several-per-line array row"),
    ("linux/scripts/03-media/build/gstreamer/install-deps.sh", "libvvdec-dev", "guarded call site"),
    ("linux/scripts/03-media/build/gstreamer/install-deps.sh", "libsndfile1-dev", "backslash-continued call"),
    ("linux/scripts/03-media/build/ffmpeg/install-deps.sh", "libsoxr-dev", "array row with trailing comment"),
    ("linux/scripts/01-core/package-lists.sh", "flatpak", "append_*_packages helper"),
    ("linux/scripts/01-core/package-lists.sh", "libgtk-3-dev", "base-image OS list"),
    ("linux/scripts/01-core/cpython-dev-packages.sh", "libsqlite3-dev", "CPython dev-package table"),
    ("linux/scripts/03-media/runtime/so-package-map.txt", "libevent-2.1-7t64", "soname->package map"),
    ("linux/scripts/01-core/setup-rocm-repo.sh", "ca-certificates", "bare apt-get install"),
    ("linux/scripts/01-core/common.sh", "ccache", "host installer helper"),
)
MUST_NOT_FIND = (
    ("linux/scripts/01-core/cross-apt.sh", "exited", "word from an echo string"),
    ("linux/scripts/02-toolchain/android-sdk.sh", "platform-tools", "sdkmanager component, not apt"),
    ("linux/scripts/01-core/cpython-dev-packages.sh", "required", "table column, not a package"),
    ("linux/scripts/03-media/runtime/so-package-map.txt", "source-built", "DENY sentinel, not a package"),
)

PKG_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")
ARRAY_NAME_RE = re.compile(r"(?i)(packages|pkgs)$")
CMD_RE = re.compile(
    r"(?<![\w./-])(" + "|".join(TARGET_INSTALLERS + HOST_INSTALLERS + APPEND_HELPERS)
    + r"|apt-get(?:\s+-[\w-]+)*\s+install)(?=\s|$)"
)
ARRAY_START_RE = re.compile(
    r"^\s*(?:local\s+(?:-[a-zA-Z]+\s+)?|declare\s+(?:-[a-zA-Z]+\s+)?|readonly\s+|export\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)\+?=\(\s*(.*)$"
)
FLAG_NOISE = {"install", "apt-get", "apt", "sudo", "env"}


def log(msg=""):
    print(msg, flush=True)


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


class Req:
    """One requested package name at one site."""

    __slots__ = ("guarded", "line", "name", "path", "scope", "why")

    def __init__(self, name, path, line, scope, guarded, why):
        self.name, self.path, self.line = name, path, line
        self.scope, self.guarded, self.why = scope, guarded, why


def strip_comment(text):
    out, quote = [], None
    for ch in text:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (not out or out[-1] in " \t"):
            break
        out.append(ch)
    return "".join(out)


def quoted_spans(text):
    spans, quote, start = [], None, 0
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                spans.append((start, i))
                quote = None
        elif ch in "'\"":
            quote, start = ch, i
    if quote:
        spans.append((start, len(text)))
    return spans


def in_quotes(spans, pos):
    return any(a < pos < b for a, b in spans)


def tokenize(args):
    """Package names out of an argument string. Splits on ANY whitespace."""
    names = []
    for raw in args.split():
        tok = raw.strip().strip('"').strip("'")
        if not tok or tok in FLAG_NOISE or tok.startswith("-"):
            continue
        if any(c in tok for c in "$*?[]{}()`=\\/:!<>|;&'\"#"):
            continue
        if PKG_RE.match(tok):
            names.append(tok)
    return names


def logical_lines(raw):
    """(lineno, text) with backslash continuations joined."""
    out, i = [], 0
    while i < len(raw):
        first, acc = i + 1, raw[i]
        while acc.rstrip().endswith("\\") and i + 1 < len(raw):
            acc = acc.rstrip()[:-1] + " " + raw[i + 1]
            i += 1
        out.append((first, acc))
        i += 1
    return out


ARRAY_REF_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]\}")


def _array_refs(text):
    """Names of the package arrays one line expands."""
    return {m.group(1) for m in ARRAY_REF_RE.finditer(text)}


def _scan_arrays(raw):
    """NAME=( ... ) literals whose name ends in packages/pkgs, bodies spanning lines
    and several names per line -> {name: [(lineno, [(lineno, package)])]}."""
    arrays, i = {}, 0
    while i < len(raw):
        m = ARRAY_START_RE.match(raw[i])
        if not (m and ARRAY_NAME_RE.search(m.group(1))):
            i += 1
            continue
        body, rest, j = [], m.group(2), i
        while True:
            seg = strip_comment(rest)
            cut = seg.find(")")
            if cut >= 0:
                body.append((j + 1, seg[:cut]))
                break
            body.append((j + 1, seg))
            j += 1
            if j >= len(raw):
                break
            rest = raw[j]
        entries = [(n, name) for n, seg in body for name in tokenize(seg)]
        arrays.setdefault(m.group(1), []).append((i + 1, entries))
        i = j + 1
    return arrays


def _scan_cpython_table(raw, rel):
    """The CPython dev-package table: rows of "<dev-package> <required|optional> <ext>..."."""
    out = []
    for n, text in enumerate(raw, 1):
        m = re.match(r'\s*"([a-z0-9][a-z0-9+.-]+)\s+(required|optional)\s', text)
        if m:
            out.append(Req(m.group(1), rel, n, "host+target", False, "cpython dev table"))
    return out


def _track_guard_stack(stripped, guard_stack):
    """The enclosing if/elif/fi conditions, so a call under an apt probe reads guarded."""
    if re.match(r"^(if|elif)\s", stripped):
        cond = stripped.split(";")[0]
        if re.match(r"^elif\s", stripped) and guard_stack:
            guard_stack[-1] = cond
        else:
            guard_stack.append(cond)
    elif re.match(r"^fi\b", stripped) and guard_stack:
        guard_stack.pop()


def _guard_disposition(cmd, pre, trailer, block_guard):
    """(guarded, why) for one call site: four ways a dead name cannot kill the stage."""
    in_cond = bool(re.match(r"\s*(if|elif|while|until|!)\s", pre)) or "$(" in pre
    if not (cmd in SELF_FILTERING or trailer.lstrip().startswith("||")
            or in_cond or block_guard):
        return False, ""
    if cmd in SELF_FILTERING:
        return True, "self-filtering helper"
    if trailer.lstrip().startswith("||"):
        return True, "|| fallback"
    if block_guard:
        return True, "apt probe in enclosing if"
    return True, "in a condition"


def _call_site(text, m, rel, lineno, block_guard):
    """One installer invocation -> (reqs, arrays it expands)."""
    cmd = re.sub(r"\s+", " ", m.group(1))
    base = cmd.split()[0] if cmd.startswith("apt-get") else cmd
    pre, post = text[: m.start()], text[m.end():]
    cut = re.search(r"(\|\||&&|;|\||\))", post)
    args = post[: cut.start()] if cut else post
    trailer = post[cut.start():] if cut else ""
    if cmd in APPEND_HELPERS:
        args = args.strip().split(" ", 1)[1] if " " in args.strip() else ""
    refs = set()
    if base in TARGET_INSTALLERS or base in HOST_INSTALLERS \
       or base in APPEND_HELPERS or base.startswith("apt-get"):
        refs = _array_refs(args)
    names = tokenize(args)
    if not names:
        return [], refs
    guarded, why = _guard_disposition(cmd, pre, trailer, block_guard)
    scope = "target" if cmd in TARGET_INSTALLERS else "host"
    if cmd in APPEND_HELPERS:
        scope = "host"
    return [Req(name, rel, lineno, scope, guarded, why) for name in names], refs


def _scan_call_sites(raw, rel):
    """Every installer call in one file -> (reqs, referenced arrays). A for-loop over
    an array installs it one name at a time, so its expansion counts as a reference."""
    reqs, refs, guard_stack = [], set(), []
    for lineno, acc in logical_lines(raw):
        text = strip_comment(acc)
        stripped = text.strip()
        _track_guard_stack(stripped, guard_stack)
        block_guard = any(p in c for c in guard_stack for p in PROBE_CMDS)
        if re.match(r"\s*for\s+\w+\s+in\s", stripped):
            refs |= _array_refs(text)
        spans = quoted_spans(text)
        for m in CMD_RE.finditer(text):
            if in_quotes(spans, m.start()):
                continue
            site_reqs, site_refs = _call_site(text, m, rel, lineno, block_guard)
            reqs.extend(site_reqs)
            refs |= site_refs
    return reqs, refs


def scan_file(path, rel):
    """-> (reqs, array_names_by_array, referenced_arrays)."""
    raw = read_text(path).split("\n")
    table = (_scan_cpython_table(raw, rel)
             if rel.endswith("01-core/cpython-dev-packages.sh") else [])
    call_reqs, refs = _scan_call_sites(raw, rel)
    return table + call_reqs, _scan_arrays(raw), refs


SO_PACKAGE_MAP = "linux/scripts/03-media/runtime/so-package-map.txt"


def scan_so_package_map():
    """soname<TAB>package rows; validate-media-runtime installs field 2."""
    path = os.path.join(REPO_ROOT, SO_PACKAGE_MAP)
    out = []
    if not os.path.exists(path):
        return out
    for lineno, row in enumerate(read_text(path).split("\n"), 1):
        row = row.split("#", 1)[0].strip()
        if not row:
            continue
        parts = row.split()
        if len(parts) < 2 or parts[1] == "source-built":
            continue
        if PKG_RE.match(parts[1]):
            out.append(Req(parts[1], SO_PACKAGE_MAP, lineno, "target", True, "so-package map"))
    return out


def collect():
    reqs, skipped_arrays, files = [], [], 0
    call_sites = 0
    for dirpath, dirnames, filenames in os.walk(SCRIPTS):
        dirnames[:] = [d for d in dirnames if d not in ("tests", "__pycache__", "patches")]
        for fname in sorted(filenames):
            if not fname.endswith(".sh"):
                continue
            path = os.path.join(dirpath, fname)
            rel = os.path.relpath(path, REPO_ROOT)
            file_reqs, arrays, refs = scan_file(path, rel)
            files += 1
            call_sites += len({(r.line, r.path) for r in file_reqs})
            reqs.extend(file_reqs)
            # An array counts only when the file hands it to an installer.
            for aname, entries in arrays.items():
                for lineno, rows in entries:
                    if not rows:
                        continue
                    if aname not in refs:
                        skipped_arrays.append((rel, lineno, aname, len(rows)))
                        continue
                    guarded, scope = _array_disposition(rel, aname)
                    for name_line, name in rows:
                        reqs.append(Req(name, rel, name_line, scope, guarded, "array"))
    reqs.extend(scan_so_package_map())
    return reqs, files, call_sites, skipped_arrays


_ARRAY_CACHE = {}


def _array_disposition(rel, aname):
    """Guard + arch scope of an array = those of the installers consuming it."""
    key = (rel, aname)
    if key in _ARRAY_CACHE:
        return _ARRAY_CACHE[key]
    lines = logical_lines(read_text(os.path.join(REPO_ROOT, rel)).split("\n"))
    users = []
    for idx, (_, acc) in enumerate(lines):
        line = strip_comment(acc)
        if (f"${{{aname}[@]}}") not in line and (f"${{{aname}[*]}}") not in line:
            continue
        body = [line]
        if re.match(r"for\s+\w+\s+in\s", line.strip()):
            for _, nxt in lines[idx + 1:idx + 12]:
                body.append(strip_comment(nxt))
                if re.match(r"done\b", nxt.strip()):
                    break
        for text in body:
            for m in CMD_RE.finditer(text):
                cmd = re.sub(r"\s+", " ", m.group(1))
                post = text[m.end():]
                cut = re.search(r"(\|\||&&|;|\||\))", post)
                trailer = post[cut.start():] if cut else ""
                users.append((
                    cmd in SELF_FILTERING or trailer.lstrip().startswith("||"),
                    "target" if cmd in TARGET_INSTALLERS else "host",
                ))
    if users:
        out = (all(g for g, _ in users),
               "target" if any(sc == "target" for _, sc in users) else "host")
    else:
        out = (True, "host+target")
    _ARRAY_CACHE[key] = out
    return out


def read_codename():
    text = read_text(VERSIONS_ENV)
    m = re.search(r"(?m)^UBUNTU_CODENAME=(\S+)", text)
    if not m:
        raise SystemExit(f"verify-package-names: UBUNTU_CODENAME missing from {VERSIONS_ENV}")
    return m.group(1)


def read_mirrors():
    archive = ports = None
    try:
        text = read_text(MIRROR_SH)
        for fn, var in (("ubuntu_default_archive_mirror_url", "archive"),
                        ("ubuntu_default_ports_mirror_url", "ports")):
            m = re.search(fn + r"\(\)\s*\{\s*printf\s+'%s'\s+'([^']+)'", text)
            if m:
                if var == "archive":
                    archive = m.group(1)
                else:
                    ports = m.group(1)
    except OSError:
        pass
    return (archive or "https://archive.ubuntu.com/ubuntu/",
            ports or "http://ports.ubuntu.com/ubuntu-ports/")


def cache_dir(codename):
    base = os.environ.get("PKG_NAMES_CACHE_DIR") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
        "containerhub-pkg-names")
    path = os.path.join(base, codename)
    os.makedirs(path, exist_ok=True)
    return path


def fetch(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "containerhub-verify-package-names"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def parse_index(blob):
    import lzma
    data = lzma.decompress(blob)
    real, virtual = set(), {}
    for m in re.finditer(rb"(?m)^(Package|Provides): (.+)$", data):
        field, value = m.group(1), m.group(2).decode("utf-8", "replace")
        if field == b"Package":
            real.add(value.strip())
            last = value.strip()
        else:
            for item in value.split(","):
                item = item.strip().split(" ")[0].split("(")[0].strip()
                if item:
                    virtual.setdefault(item, set()).add(last)
    return real, virtual


def _read_cache(stamp, vstamp):
    real = set(read_text(stamp).split())
    virtual = {}
    if os.path.exists(vstamp):
        for row in read_text(vstamp).split("\n"):
            key, _, provider = row.strip().partition(" ")
            if key:
                virtual[key] = {provider}
    return real, virtual


def load_arch(arch, codename, pocket, mirrors, cdir, ttl, timeout, refresh):
    """-> (real, virtual, source) or None when unreachable and uncached."""
    suffix = pocket or ""
    stamp = os.path.join(cdir, "{}{}.names".format(arch, suffix.replace("-", "_")))
    vstamp = stamp + ".virtual"
    fresh = os.path.exists(stamp) and (time.time() - os.path.getmtime(stamp)) < ttl
    if fresh and not refresh:
        real, virtual = _read_cache(stamp, vstamp)
        return real, virtual, "cache"

    base = (mirrors[0] if arch == "amd64" else mirrors[1]).rstrip("/") + "/"
    urls = [f"{base}dists/{codename}{suffix}/{c}/binary-{arch}/Packages.xz"
            for c in COMPONENTS]
    # A PARTIAL fetch is not a usable index: a missing component makes real
    # packages look dead and would fail the gate wrongly. All or nothing.
    real, virtual, ok_n = set(), {}, 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for blob in pool.map(lambda u: _try(u, timeout), urls):
            if blob is None:
                continue
            fresh_real, fresh_virtual = parse_index(blob)
            real |= fresh_real
            for key, providers in fresh_virtual.items():
                virtual.setdefault(key, set()).update(providers)
            ok_n += 1
    got = ok_n == len(urls)
    if ok_n and not got:
        sys.stderr.write(
            "WARN: {}{} index incomplete ({}/{} components); not caching, "
            "falling back\n".format(arch, suffix, ok_n, len(urls)))
        real, virtual = set(), {}
    if not got:
        if os.path.exists(stamp):
            real, virtual = _read_cache(stamp, vstamp)
            return real, virtual, "STALE cache"
        return None
    with open(stamp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(sorted(real)))
    with open(vstamp, "w", encoding="utf-8") as fh:
        for key in sorted(virtual):
            fh.write(f"{key} {min(virtual[key])}\n")
    return real, virtual, "network"


def _try(url, timeout):
    try:
        return fetch(url, timeout)
    except (urllib.error.URLError, OSError, ValueError):
        return None


def self_check(reqs):
    found = {(r.path, r.name) for r in reqs}
    broken = []
    for path in VENDOR_REPO_FILES:
        if not os.path.exists(os.path.join(REPO_ROOT, path)):
            broken.append(f"STALE vendor-repo exemption for {path} (file is gone)")
    for path, name, shape in MUST_FIND:
        if (path, name) not in found:
            broken.append(f"MISSED {name} in {path} ({shape})")
    for path, name, shape in MUST_NOT_FIND:
        if (path, name) in found:
            broken.append(f"BOGUS {name} from {path} ({shape})")
    return broken


def _installable(index):
    return {a: index[a][0] | set(index[a][1]) for a in ARCHES}


def _load_indices(codename, mirrors, cdir, args):
    """-> (index, sources), or None after logging the SKIP that unreachable must be."""
    index, sources = {}, {}
    for arch in ARCHES:
        got = load_arch(arch, codename, "", mirrors, cdir, args.ttl, args.timeout, args.refresh)
        if got is None:
            mirror = mirrors[0] if arch == "amd64" else mirrors[1]
            log(f"SKIP: cannot reach {mirror} and no cached index for "
                f"{codename}/{arch} — package names NOT verified.")
            log("      (offline is a SKIP, never a pass; re-run with a network for a verdict)")
            return None
        index[arch], sources[arch] = (got[0], got[1]), got[2]
    return index, sources


def _suspects(reqs, installable):
    """{name: [(req, the arches it is missing on)]}; a host-scope name only owes amd64."""
    out = {}
    for req in reqs:
        arches = ARCHES if req.scope != "host" else ("amd64",)
        missing = [a for a in arches if req.name not in installable[a]]
        if missing:
            out.setdefault(req.name, []).append((req, missing))
    return out


def _recheck_extra_pockets(suspects, index, codename, mirrors, cdir, args):
    """Second pass over -updates/-security, paid for only when a name would FAIL."""
    if not any(not r.guarded and not is_vendor(r.path, r.name)
               for rows in suspects.values() for r, _ in rows):
        return suspects
    for arch in ARCHES:
        for pocket in EXTRA_POCKETS:
            got = load_arch(arch, codename, pocket, mirrors, cdir, args.ttl,
                            args.timeout, args.refresh)
            if got:
                index[arch] = (index[arch][0] | got[0], index[arch][1] | got[1])
    installable = _installable(index)
    out = {}
    for name, rows in suspects.items():
        rows = [(r, [a for a in m if name not in installable[a]]) for r, m in rows]
        rows = [(r, m) for r, m in rows if m]
        if rows:
            out[name] = rows
    return out


def _classify(suspects):
    """-> (dead_unguarded, vendor, somap, dead_guarded): only the first one FAILS."""
    dead_unguarded, vendor, somap, dead_guarded = [], [], {}, {}
    for name, rows in sorted(suspects.items()):
        for req, missing in rows:
            if is_vendor(req.path, req.name):
                vendor.append((name, req))
            elif req.why == "so-package map":
                somap.setdefault(name, []).append(req.line)
            elif req.guarded:
                dead_guarded.setdefault((name, ",".join(missing)), []).append(req)
            else:
                dead_unguarded.append((name, req, missing))
    return dead_unguarded, vendor, somap, dead_guarded


def _log_notes(codename, skipped_arrays, virtual_only, vendor, somap, dead_guarded):
    """Everything that is worth saying but is not a verdict."""
    for rel, lineno, aname, count in skipped_arrays:
        log(f"note: {rel}:{lineno} {aname}[] ({count} names) is never handed "
            "to an installer — not checked")
    for name, provider in virtual_only:
        log(f"note: {name} is VIRTUAL only (provided by {provider}) — "
            "a Provides can vanish in a rename")
    if vendor:
        files_ = ", ".join(sorted({os.path.basename(r.path) for _, r in vendor}))
        listed = ", ".join(sorted({n for n, _ in vendor}))
        log(f"note: {len({n for n, _ in vendor})} name(s) live in a NON-Ubuntu repo "
            f"({files_}) — UNVERIFIABLE here, never dead: {listed}")
    if somap:
        log(f"note: {SO_PACKAGE_MAP}: {len(somap)} row(s) map an OLD soname to a package "
            f"that is gone on {codename} — harmless unless that soname is really NEEDED: "
            + ", ".join(sorted(somap)))
    for (name, missing), reqs_at in sorted(dead_guarded.items()):
        sites = ", ".join(f"{r.path}:{r.line}" for r in reqs_at)
        log(f"WARN: {name} does not exist on {missing} — {sites} "
            f"(guarded: {reqs_at[0].why or 'guarded'}); a wasted apt round-trip every run")


def _verdict(codename, args, reqs, names, skipped_arrays):
    """The network half: load the indices, then report. 0 = clean or SKIP, 1 = a dead
    name at an unguarded site. docs/cross-build-verification.md"""
    mirrors = read_mirrors()
    cdir = cache_dir(codename)
    loaded = _load_indices(codename, mirrors, cdir, args)
    if loaded is None:
        return 0
    index, sources = loaded
    log("indices: " + ", ".join(f"{a}={len(index[a][0])} names ({sources[a]})" for a in ARCHES))

    suspects = _recheck_extra_pockets(_suspects(reqs, _installable(index)), index,
                                      codename, mirrors, cdir, args)
    dead_unguarded, vendor, somap, dead_guarded = _classify(suspects)
    virtual_only = sorted(
        (n, min(index["amd64"][1].get(n, {"?"})))
        for n in names
        if n not in index["amd64"][0] and n in index["amd64"][1]
    )
    _log_notes(codename, skipped_arrays, virtual_only, vendor, somap, dead_guarded)

    stale = [a for a in ARCHES if sources[a] == "STALE cache"]
    if stale:
        log(f"WARN: used a STALE cached index for {','.join(stale)} (network unreachable)")

    if dead_unguarded:
        log("")
        log(f"FAIL: {len(dead_unguarded)} UNGUARDED request(s) for a package "
            f"that does not exist on {codename}:")
        for name, req, missing in dead_unguarded:
            log(f"  {req.path}:{req.line}  {name}  "
                f"(missing on {','.join(missing)}, scope={req.scope})")
        log("Fix the name, or guard the call (|| true / install_optional_target_packages)")
        log("if the package is genuinely optional. This is the four-hours-in stage kill.")
        return 1

    note_count = (len(virtual_only) + len(skipped_arrays)
                  + (1 if vendor else 0) + (1 if somap else 0))
    log(f"OK: every unguarded package name resolves on {codename} "
        f"({len(dead_guarded)} WARN, {note_count} note)")
    return 0


def _parse_args():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--list", action="store_true", help="print every extracted name and exit")
    ap.add_argument("--refresh", action="store_true", help="ignore the index cache")
    ap.add_argument("--offline", action="store_true", help="never hit the network")
    ap.add_argument("--ttl", type=int, default=int(os.environ.get("PKG_NAMES_TTL", "21600")))
    ap.add_argument("--timeout", type=float,
                    default=float(os.environ.get("PKG_NAMES_TIMEOUT", "20")))
    return ap.parse_args()


def main():
    args = _parse_args()
    codename = read_codename()
    reqs, files, call_sites, skipped_arrays = collect()
    names = sorted({r.name for r in reqs})

    log(f"=== distro package-name check ({codename}) ===")
    log(f"scanned {files} shell files: {call_sites} call sites, "
        f"{len(names)} distinct package names")

    if args.list:
        for req in sorted(reqs, key=lambda r: (r.path, r.line, r.name)):
            guard = "guarded" if req.guarded else "UNGUARDED"
            log(f"{req.path}:{req.line}\t{req.name}\t{req.scope}\t{guard}\t{req.why}")
        return 0

    broken = self_check(reqs)
    if broken:
        log("EXTRACTOR SELF-CHECK FAILED — the scan is not seeing what it claims:")
        for row in broken:
            log(f"  {row}")
        return 2
    log(f"extractor self-check: {len(MUST_FIND)} known shapes found, "
        f"{len(MUST_NOT_FIND)} decoys rejected")

    if args.offline or os.environ.get("PKG_NAMES_OFFLINE") == "1":
        log("SKIP: --offline/PKG_NAMES_OFFLINE=1 — package names NOT verified.")
        return 0

    return _verdict(codename, args, reqs, names, skipped_arrays)


if __name__ == "__main__":
    sys.exit(main())
