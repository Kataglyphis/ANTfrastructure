#!/usr/bin/env python3
"""Check traced ORT/library origins; paths and process identity do not prove bytes, one session, clean hosts or licences."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Pattern

CORE = "libonnxruntime.so"
CORE_NAME = re.compile(r"libonnxruntime\.so(?:\.[0-9]+)*")
LIBRARY_NAME = re.compile(r"[A-Za-z0-9_+.-]+\.so(?:\.[0-9]+)*")


def normalized_path(value: str, *, absolute: bool) -> PurePosixPath:
    path = PurePosixPath(value)
    if (
        path.is_absolute() != absolute
        or not path.parts
        or str(path) != value
        or ".." in path.parts
        or "\\" in value
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise ValueError("noncanonical loader path")
    return path


def selected_library(value: str, required: tuple[str, ...]) -> str | None:
    name = PurePosixPath(value).name
    if name.startswith(CORE):
        if not CORE_NAME.fullmatch(name):
            raise ValueError("malformed ORT soname in loader trace")
        return CORE
    return name if name in required else None


def trace_records(trace: Path, expected_pid: int | None) -> list[str]:
    if trace.is_symlink() or not trace.is_file():
        raise ValueError("missing or linked loader trace")
    result = []
    for line in trace.read_text(encoding="utf-8").splitlines():
        if "calling init: " not in line:
            continue
        prefix, value = line.split("calling init: ", 1)
        if expected_pid is not None and not re.fullmatch(rf"\s*{expected_pid}:\s*", prefix):
            raise ValueError("loader trace process differs from profile")
        result.append(value.strip())
    return result


def validate_origin(value: str, directory: Pattern[str], real_root: Path | None) -> None:
    path = normalized_path(value, absolute=True)
    if not directory.fullmatch(str(path.parent)):
        raise ValueError("library loaded outside the expected package")
    if real_root is not None:
        if not Path(value).resolve(strict=True).is_relative_to(real_root.resolve(strict=True)):
            raise ValueError("loaded library symlink escapes package")


def verify_loader_traces(
    traces: list[Path],
    directory: Pattern[str],
    required: tuple[str, ...] = (CORE,),
    *,
    expected_pid: int | None = None,
    real_root: Path | None = None,
) -> dict[str, list[str]]:
    if not traces or not required or CORE not in required:
        raise ValueError("missing loader traces or ORT requirement")
    found: dict[str, set[str]] = {name: set() for name in required}
    for trace in traces:
        for value in trace_records(trace, expected_pid):
            name = selected_library(value, required)
            if name is not None:
                validate_origin(value, directory, real_root)
                found[name].add(value)
    if any(not paths for paths in found.values()):
        raise ValueError("missing required library loader evidence")
    return {name: sorted(paths) for name, paths in found.items()}


def profile_identity(profile: Path, device: str, minimum: int) -> tuple[int, str]:
    payload = profile.read_bytes()
    verifier = Path(__file__).with_name("verify_ort_profile.py")
    if verifier.is_symlink() or not verifier.is_file():
        raise ValueError("missing canonical ORT profile verifier")
    with tempfile.TemporaryDirectory(prefix="ort-loader-profile-") as work:
        copy = Path(work) / "profile.json"
        copy.write_bytes(payload)
        subprocess.run(
            [sys.executable, "-I", str(verifier), str(copy), "--device", device,
             "--min-runs", str(minimum)],
            stdout=sys.stderr, check=True, timeout=60,
        )
    events = json.loads(payload)
    pids = {
        event["pid"] for event in events
        if isinstance(event, dict) and event.get("cat") == "Session"
        and event.get("name") == "model_run" and event.get("ph") == "X"
    }
    if len(pids) != 1 or any(type(pid) is not int or pid <= 0 for pid in pids):
        raise ValueError("profile does not identify one positive process ID")
    return pids.pop(), hashlib.sha256(payload).hexdigest()


def expected_directory(root: str, appimage_subdir: str | None) -> Pattern[str]:
    normalized_path(root, absolute=True)
    pattern = re.escape(root)
    if appimage_subdir is not None:
        normalized_path(appimage_subdir, absolute=False)
        pattern += r"/appimage_extracted_[0-9a-f]{32}/" + re.escape(appimage_subdir)
    return re.compile(pattern)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace-prefix", type=Path, required=True)
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--appimage-subdir")
    parser.add_argument("--plugin", action="append", default=[])
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--device")
    parser.add_argument("--min-runs", type=int, default=2)
    parser.add_argument("--resolve-root", type=Path)
    args = parser.parse_args()
    if bool(args.profile) != bool(args.device) or args.min_runs < 1:
        parser.error("profile/device are paired and min-runs must be positive")
    if len(set(args.plugin)) != len(args.plugin) or CORE in args.plugin:
        parser.error("duplicate library requirements")
    if any(not LIBRARY_NAME.fullmatch(name) for name in args.plugin):
        parser.error("plugin must be a library basename")
    return args


def main() -> int:
    args = arguments()
    try:
        directory = expected_directory(args.runtime_root, args.appimage_subdir)
        pid, digest = profile_identity(args.profile, args.device, args.min_runs) if args.profile else (None, None)
        prefix = args.trace_prefix
        traces = [Path(f"{prefix}.{pid}")] if pid is not None else sorted(prefix.parent.glob(prefix.name + ".*"))
        loaded = verify_loader_traces(
            traces, directory, (CORE, *args.plugin), expected_pid=pid, real_root=args.resolve_root,
        )
        print(json.dumps({"status": "checked-loader-origins", "profile_pid": pid,
                          "profile_sha256": digest, "loaded": loaded,
                          "scope": __doc__}, sort_keys=True))
    except (OSError, ValueError, TypeError, UnicodeError, subprocess.SubprocessError) as error:
        print(f"Invalid ORT loader evidence: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
