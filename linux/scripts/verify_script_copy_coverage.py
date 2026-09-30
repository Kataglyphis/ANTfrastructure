#!/usr/bin/env python3
"""Every /opt/scripts/*.sh an image runs, transitively, was COPY'd or mounted into it; relative sourcing is out of scope.

docs/cross-build-verification.md#failure-classes-from-build-history
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_SRC = REPO_ROOT / "linux" / "scripts"

# Per Dockerfile, path prefixes provided by a mechanism this check does not model, verified by hand.
KNOWN_BASE_PROVIDED: dict[str, list[str]] = {
    # A mount templated on a mid-path ${ANDROID_LIB}, plus the per-lib 01-core mount and cp.
    "Dockerfile.android": [
        "/opt/scripts/03-media/gstreamer/android/build-gstreamer.sh",
        "/opt/scripts/03-media/litert/android/build-android.sh",
        "/opt/scripts/03-media/onnxruntime/android/build-android.sh",
        "/opt/scripts/03-media/opencv/android/build-android.sh",
        "/opt/scripts/03-media/iree/android/build-android.sh",
        "/opt/scripts/core/cross-apt.sh",
        "/opt/scripts/core/modules.sh",
    ],
    # Inherited from the sdk FROM base, which COPYs it with the setup-dependencies.sh closure.
    "Dockerfile.media": [
        "/opt/scripts/toolchain/vulkan.sh",
    ],
}

OPT = "/opt/scripts/"
REF_RE = re.compile(r"/opt/scripts/[A-Za-z0-9._/-]+\.sh")
# --mount=type=bind,source=linux/scripts/...,target=/opt/scripts/...[,ro]
MOUNT_RE = re.compile(r"--mount=type=bind,[^ ]*")
KV_RE = re.compile(r"(source|target)=([^,\s]+)")


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def join_continuations(text: str) -> list[str]:
    """Collapse backslash-newline line continuations into logical lines."""
    return [line for _, line in join_continuations_numbered(text)]


def join_continuations_numbered(text: str) -> list[tuple[int, str]]:
    """join_continuations with each logical line's 1-based starting line number."""
    out: list[tuple[int, str]] = []
    buf, start = "", 0
    for i, line in enumerate(text.splitlines(), start=1):
        if line.rstrip().endswith("\\"):
            if not buf:
                start = i
            buf += line.rstrip()[:-1] + " "
        else:
            out.append((start if buf else i, buf + line))
            buf = ""
    if buf:
        out.append((start, buf))
    return out


def _expand_var_dirs(src: str) -> list[Path]:
    """Existing paths for a repo src, with any ${VAR} segment treated as a glob wildcard."""
    rel = src.rstrip("/")
    if "${" not in rel:
        p = REPO_ROOT / rel
        return [p] if p.exists() else []
    glob_rel = re.sub(r"\$\{[^}]+\}", "*", rel)
    return [p for p in REPO_ROOT.glob(glob_rel)]


def _add_provision(provided: dict[str, Path], src: str, dest: str) -> None:
    """Record `src` as provided at `dest`; directories expand to every *.sh, ${VAR} is a wildcard."""
    if OPT not in dest or not src.startswith("linux/scripts/"):
        return
    for src_path in _expand_var_dirs(src):
        # Substitute this src's ${VAR} match back into dest.
        this_dest = dest
        if "${" in dest:
            this_dest = re.sub(r"\$\{[^}]+\}", src_path.name, dest)
        if src.endswith("/") or src_path.is_dir():
            if not src_path.is_dir():
                continue
            for f in src_path.rglob("*.sh"):
                rel = f.relative_to(src_path).as_posix()
                provided[this_dest.rstrip("/") + "/" + rel] = f
        else:
            provided[this_dest + src_path.name if this_dest.endswith("/") else this_dest] = src_path


def build_provided(dockerfile: Path) -> dict[str, Path]:
    """Provided /opt/scripts/* path -> repo source, from COPYs and per-RUN bind mounts alike."""
    provided: dict[str, Path] = {}
    for line in join_continuations(read(dockerfile)):
        s = line.strip()
        # Bind mounts can appear on any RUN line.
        for m in MOUNT_RE.findall(s):
            kv = dict(KV_RE.findall(m))
            if "source" in kv and "target" in kv:
                _add_provision(provided, kv["source"], kv["target"])
        if not s.upper().startswith("COPY "):
            continue
        # Drop 'COPY' and any --flags; keep the src... dest tokens.
        toks = [t for t in s.split()[1:] if not t.startswith("--")]
        if len(toks) < 2:
            continue
        srcs, dest = toks[:-1], toks[-1]
        for src in srcs:
            _add_provision(provided, src, dest)
    return provided


def entry_scripts(dockerfile: Path) -> set[str]:
    """/opt/scripts/*.sh paths the Dockerfile directly RUNs."""
    refs: set[str] = set()
    for line in join_continuations(read(dockerfile)):
        s = line.strip()
        if s.upper().startswith("RUN ") or s.upper().startswith("CMD ") or s.upper().startswith("ENTRYPOINT "):
            refs.update(REF_RE.findall(s))
    return refs


def collect_refs(opt_path: str, provided: dict[str, Path],
                 seen: set[str], out: set[str]) -> None:
    """Transitively collect /opt/scripts/*.sh references starting from opt_path."""
    if opt_path in seen:
        return
    seen.add(opt_path)
    out.add(opt_path)
    src = provided.get(opt_path)
    if src is None or not src.is_file():
        return  # missing file is reported by the caller; can't recurse into it
    for ref in REF_RE.findall(read(src)):
        collect_refs(ref, provided, seen, out)


def check_dockerfile(dockerfile: Path) -> list[str]:
    provided = build_provided(dockerfile)
    base_ok = KNOWN_BASE_PROVIDED.get(dockerfile.name, [])

    def is_provided(p: str) -> bool:
        return p in provided or any(p.startswith(pre) for pre in base_ok)

    referenced: set[str] = set()
    seen: set[str] = set()
    for entry in entry_scripts(dockerfile):
        collect_refs(entry, provided, seen, referenced)

    missing = []
    for ref in sorted(referenced):
        if not is_provided(ref):
            missing.append(ref)
    return missing


def report_core_usage() -> int:
    """--report-core-usage: core files each whole-01-core RUN mount uses; a lower bound, never a verdict."""
    core_dir = SCRIPTS_SRC / "01-core"
    core_total = len(list(core_dir.rglob("*.sh")))
    for df in sorted((REPO_ROOT / "linux").glob("Dockerfile.*")):
        provided = build_provided(df)
        rows = []
        for lineno, line in join_continuations_numbered(read(df)):
            s = line.strip()
            if not s.upper().startswith("RUN "):
                continue
            targets = []
            for m in MOUNT_RE.findall(s):
                kv = dict(KV_RE.findall(m))
                if kv.get("source", "").rstrip("/") == "linux/scripts/01-core" and "target" in kv:
                    targets.append(kv["target"].rstrip("/"))
            if not targets:
                continue
            seen: set[str] = set()
            refs: set[str] = set()
            for entry in REF_RE.findall(s):
                collect_refs(entry, provided, seen, refs)
            for target in targets:
                used = sorted(r[len(target) + 1:] for r in refs if r.startswith(target + "/"))
                rows.append((lineno, target, used))
        if not rows:
            continue
        print(f"\n{df.name}: {len(rows)} whole-01-core bind mount(s)")
        for lineno, target, used in rows:
            print(f"  L{lineno} -> {target}: uses {len(used)}/{core_total} core scripts")
            for u in used:
                print(f"      {u}")
    return 0


def main() -> int:
    if "--report-core-usage" in sys.argv[1:]:
        return report_core_usage()
    dockerfiles = sorted((REPO_ROOT / "linux").glob("Dockerfile.*"))
    if not dockerfiles:
        print("no Dockerfiles found", file=sys.stderr)
        return 1
    total_missing = 0
    for df in dockerfiles:
        missing = check_dockerfile(df)
        if missing:
            total_missing += len(missing)
            print(f"\033[0;31m✗\033[0m {df.name}: {len(missing)} referenced script(s) not COPY'd:")
            for m in missing:
                # Best-effort: name a script that references it, for debugging.
                print(f"    {m}")
        else:
            print(f"\033[0;32m✓\033[0m {df.name}: all referenced /opt/scripts paths are provided")
    if total_missing:
        print(f"\n{total_missing} missing script reference(s). Add the COPY, or list an "
              f"inherited path in KNOWN_BASE_PROVIDED if it comes from the FROM base.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
