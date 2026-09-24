#!/usr/bin/env python3
"""ORT census probe (G1/G6): facts about every ONNX Runtime binary and consumer under a root.

Prints TAB-separated fact lines and decides nothing: ort_census_verdicts in
check-ort-provenance.sh reads them. Paths are IMAGE paths; --root is where the image's
/ lives ('/' inside the image, a directory for a bundle). Does NOT see provenance that
ships no bytes (a consumer compiled against foreign headers), nor what the running user
cannot read. docs/cross-build-verification.md#e-ort-single-source
"""
import argparse
import fnmatch
import hashlib
import json
import mmap
import os
import posixpath
import re
import stat
import struct
import zipfile

ABI = (b"OrtGetApiBase", b"CreateEpFactories", b"RegisterCustomOps")
# A whole ORT source-file path ending in NUL, as __FILE__ puts it into every ORT build. A consumer that
# names the chain DIRECTORY as data is not ORT: docs/onnxruntime-single-source.md#what-the-chain-ort-is
MARK = re.compile(rb"onnxruntime[\\/](?:core|contrib_ops)[\\/][\w.+\\/-]*?\.(?:cc|cpp|cxx|c|h|hpp|inc|cu|cuh)(?:\x00|\Z)")
INSTANCE = re.compile(r"^(?:lib)?onnxruntime(?:_providers_[a-z0-9_]+)?\.(?:dll|so(?:\.[0-9]+)*)$"
                      r"|^onnxruntime_pybind11_state[^/]*\.(?:pyd|so)$", re.IGNORECASE)
ARCHIVE_EXT = (".whl", ".aar", ".jar", ".zip", ".nupkg", ".apk")
MEMBER = re.compile(r"(?:\.so(?:\.[0-9]+)*|\.dll|\.pyd|\.wasm|\.node)$", re.IGNORECASE)
MAGIC = (b"\x7fELF", b"\0asm")
SKIP_TOP = ("/proc", "/sys", "/dev", "/run")
CHUNK = 16 << 20
OVERLAP = 512


def emit(*fields):
    print("\t".join("-" if f in (None, "") else str(f) for f in fields))


def host(root, path):
    return path if root == "/" else os.path.join(root, *[p for p in path.split("/") if p])


def source_root(run):
    """The build root a printable run before a path marker names: '' = relative, None = a URL."""
    if re.search(r"[A-Za-z][A-Za-z0-9+.-]*://", run):
        return None
    drives = list(re.finditer(r"[A-Za-z]:[\\/]", run))
    if drives:
        return run[drives[-1].start():].replace("/", "\\").rstrip("\\")
    return run.rstrip("/") if run.startswith("/") else ""


def roots_in(buf, min_end=0):
    out = []
    for m in MARK.finditer(buf):
        if m.end() <= min_end:
            continue
        start, floor = m.start(), max(0, m.start() - 400)
        while start > floor and 0x20 <= buf[start - 1] <= 0x7E:
            start -= 1
        root = source_root(bytes(buf[start:m.start()]).decode("latin-1"))
        if root is not None and root not in out:
            out.append(root)
    return out


def scan_stream(read):
    """sha256, ABI markers and ORT source roots over chunked reads (archive members)."""
    sha, abi, roots, carry = hashlib.sha256(), set(), [], b""
    while True:
        chunk = read(CHUNK)
        if not chunk:
            break
        sha.update(chunk)
        buf = carry + chunk
        abi.update(a.decode() for a in ABI if a in buf)
        if b"onnxruntime" in buf:
            roots.extend(r for r in roots_in(buf, len(carry)) if r not in roots)
        carry = buf[-OVERLAP:]
    return sha.hexdigest(), sorted(abi), roots


def _elf_image(mm):
    """(is64, byte order, PT_LOAD spans, dynamic entries) from an ELF's program headers; None without PT_DYNAMIC."""
    if mm[:4] != MAGIC[0]:
        return None
    is64, end = mm[4] == 2, "<" if mm[5] == 1 else ">"
    phoff = struct.unpack_from(end + ("Q" if is64 else "I"), mm, 32 if is64 else 28)[0]
    phentsize, phnum = struct.unpack_from(end + "HH", mm, 54 if is64 else 42)
    loads, dyn = [], None
    for i in range(phnum):
        if is64:
            p_type, _f, p_off, p_vaddr, _p, p_filesz = struct.unpack_from(end + "IIQQQQ", mm, phoff + i * phentsize)
        else:
            p_type, p_off, p_vaddr, _p, p_filesz = struct.unpack_from(end + "IIIII", mm, phoff + i * phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_off, p_filesz))
        elif p_type == 2:
            dyn = (p_off, p_filesz)
    if not dyn:
        return None
    step, fmt = (16, end + "qQ") if is64 else (8, end + "iI")
    entries = []
    for off in range(dyn[0], dyn[0] + dyn[1], step):
        tag, val = struct.unpack_from(fmt, mm, off)
        if tag == 0:
            break
        entries.append((tag, val))
    return is64, end, loads, entries


def _file_offset(loads, vaddr):
    return next((o + vaddr - v for v, o, n in loads if v <= vaddr < v + n), None)


def elf_dynamic(mm):
    """DT_NEEDED / DT_RPATH / DT_RUNPATH of an ELF, read from its program headers; {} if none."""
    try:
        image = _elf_image(mm)
        return _dynamic_entries(mm, image[2], image[3]) if image else {}
    except (struct.error, ValueError, IndexError):
        return {}


def _dynamic_entries(mm, loads, entries):
    base = _file_offset(loads, dict(entries).get(5, -1))
    if base is None:
        return {}
    out = {"needed": [], "rpath": [], "runpath": []}
    for tag, val in entries:
        key = {1: "needed", 15: "rpath", 29: "runpath"}.get(tag)
        if key:
            text = bytes(mm[base + val:mm.find(b"\0", base + val)]).decode("utf-8", "replace")
            out[key].extend([text] if key == "needed" else [d for d in text.split(":") if d])
    return out


def elf_defines(mm, name):
    """True when ld.so's hash lookup finds `name` DEFINED in the ELF's dynamic symbols: ORT under any name."""
    try:
        image = _elf_image(mm)
        if image is None:
            return False
        is64, end, loads, entries = image
        tags = dict(entries)
        sym, strtab = _file_offset(loads, tags.get(6, -1)), _file_offset(loads, tags.get(5, -1))
        if sym is None or strtab is None:
            return False
        size, shndx = (24, 6) if is64 else (16, 14)
        for i in _hash_chain(mm, end, 8 if is64 else 4, loads, tags, name):
            at = sym + i * size
            st_name = strtab + struct.unpack_from(end + "I", mm, at)[0]
            if struct.unpack_from(end + "H", mm, at + shndx)[0] and mm[st_name:st_name + len(name) + 1] == name + b"\0":
                return True
        return False
    except (struct.error, ValueError, IndexError, ZeroDivisionError):
        return False


def user_facts(mm, abi, roots):
    """(kind, sha, abi, roots, dyn) of an unnamed, unfingerprinted file that mentions ORT: 'use', or 'def'."""
    sha = hashlib.sha256(mm).hexdigest()
    # An ORT under another name with its fingerprints stripped still defines its entry point.
    if "OrtGetApiBase" in abi and elf_defines(mm, b"OrtGetApiBase"):
        return "def", sha, abi, roots, {}
    return "use", sha, abi, roots, elf_dynamic(mm) if mm[:4] == MAGIC[0] else None


def _hash_chain(mm, end, word, loads, tags, name):
    """The symbol indices ld.so compares for `name`: DT_GNU_HASH's chain, else DT_HASH's."""
    def u32(off):
        return struct.unpack_from(end + "I", mm, off)[0]
    gnu, sysv = _file_offset(loads, tags.get(0x6FFFFEF5, -1)), _file_offset(loads, tags.get(4, -1))
    if gnu is not None:
        h = 5381
        for c in name:
            h = (h * 33 + c) & 0xFFFFFFFF
        nbuckets, symoffset, bloom = u32(gnu), u32(gnu + 4), u32(gnu + 8)
        buckets = gnu + 16 + bloom * word
        i = u32(buckets + 4 * (h % nbuckets))
        while i and i >= symoffset:
            link = u32(buckets + 4 * nbuckets + 4 * (i - symoffset))
            if (link | 1) == (h | 1):
                yield i
            if link & 1:
                return
            i += 1
    elif sysv is not None:
        h = 0
        for c in name:
            h = ((h << 4) + c) & 0xFFFFFFFF
            h = (h ^ ((h & 0xF0000000) >> 24)) & ~(h & 0xF0000000) & 0xFFFFFFFF
        nbucket, nchain = u32(sysv), u32(sysv + 4)
        i = u32(sysv + 8 + 4 * (h % nbucket))
        for _ in range(nchain):
            if not i:
                return
            yield i
            i = u32(sysv + 8 + 4 * nbucket + 4 * i)


def resolve(root, path):
    """Follow symlinks component by component INSIDE root: an absolute target is root-relative."""
    parts, cur, i, hops = [p for p in path.split("/") if p], "/", 0, 0
    while i < len(parts):
        nxt = posixpath.join(cur, parts[i])
        if os.path.islink(host(root, nxt)):
            hops += 1
            if hops > 40:
                return None
            target = os.readlink(host(root, nxt))
            base = target if target.startswith("/") else posixpath.normpath(posixpath.join(cur, target))
            parts, cur, i = [p for p in base.split("/") if p] + parts[i + 1:], "/", 0
            continue
        cur, i = nxt, i + 1
    return cur if os.path.isfile(host(root, cur)) else None


def ld_conf_dirs(root, conf="/etc/ld.so.conf", seen=None):
    """ld.so.conf directories in the order ldconfig reads them (includes expanded, sorted)."""
    seen = set() if seen is None else seen
    if conf in seen:
        return []
    seen.add(conf)
    try:
        with open(host(root, conf), encoding="utf-8", errors="replace") as fh:
            lines = [ln.split("#", 1)[0].strip() for ln in fh]
    except OSError:
        return []
    out = []
    for line in lines:
        if line.startswith("include "):
            pattern = line.split(None, 1)[1]
            pattern = pattern if pattern.startswith("/") else posixpath.join("/etc", pattern)
            folder = posixpath.dirname(pattern)
            try:
                names = sorted(os.listdir(host(root, folder)))
            except OSError:
                names = []
            for n in (n for n in names if fnmatch.fnmatch(n, posixpath.basename(pattern))):
                out.extend(ld_conf_dirs(root, posixpath.join(folder, n), seen))
        elif line.startswith("/"):
            out.append(line.rstrip("/"))
    return out


def dist_owners(root, site):
    """Distributions whose RECORD installs the `onnxruntime` import package into one site dir."""
    owners = []
    for d in sorted(os.listdir(host(root, site))):
        record = host(root, posixpath.join(site, d, "RECORD"))
        if not d.endswith(".dist-info") or not os.path.isfile(record):
            continue
        with open(record, encoding="utf-8", errors="replace") as fh:
            if any(line.startswith("onnxruntime/") for line in fh):
                owners.append(re.sub(r"[-_.]+", "-", d[: -len(".dist-info")].rsplit("-", 1)[0]).lower())
    return owners


def stamp_fields(root, path):
    """(consumer, sha-like values) of a G2 stamp, or None when it is missing or unreadable."""
    try:
        with open(host(root, path), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    shas = [str(v).lower() for v in data.values() if re.fullmatch(r"[0-9a-fA-F]{64}", str(v))]
    return str(data.get("consumer", "")), shas


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def reference_manifest(root, manifest):
    """REF lines from a sha256sum list of the chain wheel's members (built beside the wheel)."""
    try:
        with open(host(root, manifest), encoding="utf-8") as fh:
            for sha, label in (ln.split(None, 1) for ln in fh if ln.strip()):
                emit("REF", sha.lower(), label.strip(), "?")
    except FileNotFoundError:
        emit("NOMANIFEST", manifest)
    except (OSError, ValueError) as exc:
        emit("UNREAD", manifest, f"manifest: {exc}")


class Census:
    def __init__(self, args):
        self.root = args.root
        self.contract = [c.split("|") for c in args.contract]
        self.sha_cache, self.sites, self.files, self.skipped, self.uses = {}, [], 0, 0, []
        self.ldpath = [d for d in (args.ld_library_path or "").split(":") if d]
        self.search = []
        if args.image:
            multi = [posixpath.join(d, n) for d in ("/lib", "/usr/lib") for n in self._list(d)
                     if n.endswith("-linux-gnu")]
            self.search = ld_conf_dirs(self.root) + multi + ["/lib", "/usr/lib", "/lib64", "/usr/lib64"]

    def _list(self, image_dir):
        try:
            return sorted(os.listdir(host(self.root, image_dir)))
        except OSError:
            return []

    def sha(self, image_path):
        if image_path not in self.sha_cache:
            self.sha_cache[image_path] = file_sha(host(self.root, image_path))
        return self.sha_cache[image_path]

    def entry(self, name):
        if not self.contract:
            return "*"
        return next((c[0] for c in self.contract if any(fnmatch.fnmatch(name, g) for g in c[1].split(","))), "")

    def walk(self, top, root):
        """(image path, host path, lstat) of every regular file under `top`, one filesystem only."""
        htop = host(root, top)
        try:
            dev = os.lstat(htop).st_dev
        except OSError:
            return
        for dirpath, dirnames, filenames in os.walk(htop, onerror=self._skip):
            rel = os.path.relpath(dirpath, host(root, "/")).replace(os.sep, "/")
            ipath = "/" if rel == "." else "/" + rel
            keep = []
            for d in sorted(dirnames):
                child = posixpath.join(ipath, d)
                try:
                    same = os.lstat(os.path.join(dirpath, d)).st_dev == dev
                except OSError:
                    same = False
                if same and not (root == "/" and child in SKIP_TOP):
                    keep.append(d)
                    if d in ("site-packages", "dist-packages") and root == self.root:
                        self.sites.append(child)
            dirnames[:] = keep
            for n in sorted(filenames):
                try:
                    st = os.lstat(os.path.join(dirpath, n))
                except OSError:
                    continue
                if stat.S_ISREG(st.st_mode):
                    yield posixpath.join(ipath, n), os.path.join(dirpath, n), st

    def _skip(self, _err):
        self.skipped += 1

    def members(self, ipath, hpath):
        """(label, name, sha, abi, roots) per native member of an archive; raises on a bad one."""
        with zipfile.ZipFile(hpath) as zf:
            for info in zf.infolist():
                base = posixpath.basename(info.filename)
                if info.is_dir() or not (MEMBER.search(base) or INSTANCE.match(base)):
                    continue
                with zf.open(info) as fh:
                    sha, abi, roots = scan_stream(fh.read)
                yield ipath + "!" + info.filename, base, sha, abi, roots

    def facts(self, ipath, hpath, st):
        """(kind, sha, abi, roots, dyn) of one on-disk file; kind None = not ORT-related."""
        named = bool(INSTANCE.match(posixpath.basename(ipath)))
        if st.st_size == 0:
            return ("bin", hashlib.sha256(b"").hexdigest(), [], [], {}) if named else (None,) * 5
        with open(hpath, "rb") as fh:
            if fh.read(4) not in MAGIC and not named:
                return (None,) * 5
            with mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                has_ort = mm.find(b"onnxruntime") != -1
                abi = sorted(a.decode() for a in ABI if mm.find(a) != -1)
                roots = roots_in(mm) if has_ort else []
                if named or roots:
                    return "bin", hashlib.sha256(mm).hexdigest(), abi, roots, {}
                if not (abi or has_ort):
                    return (None,) * 5
                return user_facts(mm, abi, roots)

    def one(self, ipath, hpath, st, kind_ref):
        """Emit the REF/BIN/USE/UNREAD facts of one file (archive members included)."""
        name = posixpath.basename(ipath)
        if name.lower().endswith(ARCHIVE_EXT):
            try:
                for label, base, sha, abi, roots in self.members(ipath, hpath):
                    self._record(kind_ref, label, base, sha, abi, roots, None)
            except (OSError, ValueError, zipfile.BadZipFile) as exc:
                if "onnxruntime" in name.lower():
                    emit("UNREAD", ipath, f"archive: {exc}")
            return
        if st.st_size < 1024 and not INSTANCE.match(name):
            return
        try:
            kind, sha, abi, roots, dyn = self.facts(ipath, hpath, st)
        except (OSError, ValueError) as exc:
            if INSTANCE.match(name):
                emit("UNREAD", ipath, exc)
            return
        if kind:
            self._record(kind_ref, ipath, name, sha, abi, roots, dyn, kind == "def")

    def _record(self, kind_ref, label, name, sha, abi, roots, dyn, defines=False):
        instance = bool(INSTANCE.match(name) or roots) or defines
        # A relative root prints as '.': emit() turns '' into '-', which means "no fingerprint at all".
        joined = "|".join(r or "." for r in roots)
        if kind_ref:
            emit("REF", sha, label, joined)
        elif instance:
            emit("BIN", sha, label, joined, "name" if INSTANCE.match(name) else "fp" if roots else "def")
        elif abi or dyn is not None:
            needed = [n for n in (dyn or {}).get("needed", []) if INSTANCE.match(n)]
            if abi or needed:
                emit("USE", label, self.entry(name), ",".join(abi), ",".join(needed), sha)
                if dyn is not None:
                    self.uses.append((label, abi, needed, dyn))

    def ld_lookup(self, importer, dyn, name):
        """ld.so's order: DT_RPATH (only without DT_RUNPATH), LD_LIBRARY_PATH, DT_RUNPATH, cache, defaults."""
        origin = posixpath.dirname(importer)

        def expand(dirs):
            return [d.replace("${ORIGIN}", origin).replace("$ORIGIN", origin) for d in dirs]
        runpath = expand(dyn.get("runpath", []))
        rpath = [] if runpath else expand(dyn.get("rpath", []))
        for d in rpath + self.ldpath + runpath + self.search:
            hit = resolve(self.root, posixpath.join(d, name)) if d.startswith("/") else None
            if hit:
                return hit
        return None

    def resolutions(self):
        for importer, abi, needed, dyn in self.uses:
            for name in needed or (["libonnxruntime.so"] if "OrtGetApiBase" in abi else []):
                hit = self.ld_lookup(importer, dyn, name)
                emit("RES", importer, name, hit, self.sha(hit) if hit else None)


def emit_reference(census, args):
    """REF lines for the chain ORT (directories and wheel manifests), CORE lines for its core lib."""
    for ref in args.ref:
        for ipath, hpath, st in census.walk(ref, args.ref_root):
            census.one(ipath, hpath, st, True)
    for manifest in args.ref_manifest:
        reference_manifest(args.ref_root, manifest)
    for core in args.core:
        hit = resolve(args.ref_root, core)
        if hit:
            emit("CORE", file_sha(host(args.ref_root, hit)), hit)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default="/")
    ap.add_argument("--scan", action="append", default=[], help="image path to scan (default /)")
    ap.add_argument("--image", action="store_true", help="model ld.so.conf and the default dirs")
    ap.add_argument("--ref", action="append", default=[], help="chain ORT directory (image path)")
    ap.add_argument("--ref-manifest", action="append", default=[], help="sha256sum list of chain wheel members")
    ap.add_argument("--chain-root", action="append", default=[])
    ap.add_argument("--core", action="append", default=[], help="the chain core lib(s) a stamp must name")
    ap.add_argument("--allow", action="append", default=[], help="allowed home of a chain copy (image mode)")
    ap.add_argument("--contract", action="append", default=[], help="name|glob,glob|stamp path")
    ap.add_argument("--ld-library-path", default=None)
    ap.add_argument("--ref-root", default=None, help="where --ref/--ref-manifest/--core live (default --root)")
    args = ap.parse_args()
    args.ref_root = args.ref_root or args.root
    if args.image and args.ld_library_path is None:
        args.ld_library_path = os.environ.get("LD_LIBRARY_PATH", "")
    census = Census(args)
    for kind, values in (("CHAIN", args.chain_root), ("ALLOW", args.allow)):
        for v in values:
            emit(kind, v)
    emit_reference(census, args)
    for top in args.scan or ["/"]:
        for ipath, hpath, st in census.walk(top, census.root):
            census.files += 1
            census.one(ipath, hpath, st, False)
    census.resolutions()
    for site in dict.fromkeys(census.sites):
        emit("DIST", site, ",".join(dist_owners(census.root, site)))
    for name, _globs, path in census.contract:
        fields = stamp_fields(census.root, path)
        emit("STAMP", name, path, *(fields[0], ",".join(fields[1])) if fields else ("MISSING", None))
    emit("SCAN", census.files, census.skipped)
    emit("PROBE_DONE")


if __name__ == "__main__":
    main()
