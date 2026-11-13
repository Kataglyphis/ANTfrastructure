"""Stage deterministic selected script files; this does not prove builds, ABI, runtime acceptance or compiler-cache hits."""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path


def relative_path(value: str) -> Path:
    path = Path(value)
    if not path.parts or path.is_absolute() or "\\" in value or ".." in path.parts:
        raise ValueError("Script closure paths must stay relative")
    return path


def selected_file(root: Path, value: str) -> Path:
    path = root / relative_path(value)
    actual = path.resolve(strict=True)
    if path.is_symlink() or not actual.is_relative_to(root.resolve()) or not actual.is_file():
        raise ValueError("Script closure source must be a regular file inside the source root")
    return path


def read_profile(root: Path, profile: str, trail: tuple[str, ...] = (), manifests: set[Path] | None = None) -> dict[str, Path]:
    if re.fullmatch(r"[a-z][a-z0-9-]*", profile) is None or profile in trail:
        raise ValueError("Invalid or recursive script closure profile")
    manifest = selected_file(root, "script-closures/" + profile + ".txt")
    if manifests is not None:
        manifests.add(manifest)
    selected: dict[str, Path] = {}
    for line in manifest.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        if line.startswith("@"):
            entries = read_profile(root, line[1:], (*trail, profile), manifests)
        else:
            source, target = line.split("|")
            target_path = relative_path(target).as_posix()
            if target_path.split("/")[0] == "SCRIPT-CLOSURE.json":
                raise ValueError("The script closure receipt name is reserved")
            entries = {target_path: selected_file(root, source)}
        if selected.keys() & entries.keys():
            raise ValueError("Repeated script closure destination")
        selected.update(entries)
    if not selected:
        raise ValueError("Empty script closure profile")
    return selected


def closure_files(root: Path, profile: str) -> tuple[dict[str, bytes], dict[str, dict[str, str | int]]]:
    root = root.resolve(strict=True)
    selected = read_profile(root, profile)
    payloads = {target: source.read_bytes() for target, source in selected.items()}
    records: dict[str, dict[str, str | int]] = {}
    for target, payload in sorted(payloads.items()):
        mode = 0o755 if target.endswith(".sh") else 0o644
        records[target] = {"source": selected[target].relative_to(root).as_posix(),
                           "sha256": hashlib.sha256(payload).hexdigest(),
                           "size": len(payload), "mode": format(mode, "o")}
    return payloads, records


def _stage(root: Path, profile: str, output: Path, addressed: bool) -> str:
    payloads, records = closure_files(root, profile)
    receipt = {"schema_version": 1, "profile": profile, "files": records, "scope": __doc__}
    receipt_bytes = (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode()
    key = hashlib.sha256(receipt_bytes).hexdigest()
    output.mkdir()
    tree = output / key / "files" if addressed else output
    if addressed:
        tree.mkdir(parents=True)
    for target, payload in sorted(payloads.items()):
        destination = tree / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)
        destination.chmod(int(str(records[target]["mode"]), 8))
    (tree / "SCRIPT-CLOSURE.json").write_bytes(receipt_bytes)
    for path in [*sorted(output.rglob("*"), key=lambda item: len(item.parts), reverse=True), output]:
        if path.is_dir():
            path.chmod(0o755)
        os.utime(path, (0, 0))
    return key


def stage(root: Path, profile: str, output: Path) -> None:
    _stage(root, profile, output, False)


def stage_context(root: Path, profile: str, output: Path) -> str:
    return _stage(root, profile, output, True)


def profile_for(dockerfile: Path) -> str | None:
    """Read one literal build-context contract without executing the Dockerfile."""
    text = dockerfile.read_text()
    key = "org.kataglyphis.build-script-closure"
    profiles = re.findall(r"^LABEL " + re.escape(key) + r"=([a-z][a-z0-9-]*)$", text, re.MULTILINE)
    if not profiles and key not in text and "hub-scripts" not in text:
        return None
    if len(profiles) != 1:
        raise ValueError("Exactly one literal script closure profile is required")
    return profiles[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", nargs="?")
    parser.add_argument("--profile-for", type=Path)
    parser.add_argument("--context", action="store_true", help="Print the full receipt SHA and stage beneath that directory")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--output", type=Path, default=Path("/script-bundle"))
    args = parser.parse_args()
    try:
        if args.profile_for is not None:
            if args.profile is not None or args.context:
                raise ValueError("Choose a profile or a Dockerfile query")
            profile = profile_for(args.profile_for)
            if profile is not None:
                read_profile(args.root, profile)
                print(profile)
            return 0
        if args.profile is None:
            raise ValueError("A script closure profile is required")
        if args.context:
            print(stage_context(args.root, args.profile, args.output))
            return 0
        stage(args.root, args.profile, args.output)
    except (OSError, ValueError) as error:
        print("Script closure refused: " + str(error), file=sys.stderr)
        return 2
    print("SCRIPT_CLOSURE_STAGED " + args.profile)
    return 0
