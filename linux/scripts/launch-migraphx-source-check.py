#!/usr/bin/env python3
"""Replay one reviewed local source-proof profile; this does not build vendor libraries or prove CI/GPU acceptance."""

import argparse
import hashlib
import json
import re
import runpy
import shlex
import shutil
import sys
import uuid
from pathlib import Path

from host_commands import checked_output, run_logged
from owned_containers import OwnedContainers
from source_ci.common import require

ROOT = Path(__file__).resolve().parents[2]
WORKER = "/workspace/linux/scripts/03-media/build/migraphx/source-proof.sh"
LOCKS = ("quality/pyproject.toml", "quality/uv.lock", "quality/cmake-format/pyproject.toml", "quality/cmake-format/uv.lock")


def selected_recipes(source: Path, manifests: list[Path]) -> list[dict[str, str]]:
    registry = json.loads((source / "docs/scripts/mutations.json").read_text())
    current = {entry["id"]: entry for entry in registry}
    require(len(current) == len(registry), "Duplicate current mutation IDs")
    wanted: set[str] = set()
    for path in manifests:
        entries = json.loads(path.read_text())
        names = [entry["id"] for entry in entries]
        require(bool(names) and len(names) == len(set(names)), "Empty or duplicate input mutation IDs")
        wanted.update(names)
    require(bool(wanted) and not (wanted - current.keys()), "Missing or unknown selected mutation IDs")
    return [entry for entry in registry if entry["id"] in wanted]


def replay_command(template: dict[str, object], output: Path, unit: str, token: str) -> list[str]:
    command = template["command"]
    if not isinstance(command, list) or not all(isinstance(value, str) for value in command):
        raise ValueError("Invalid source-proof command")
    require(command[:2] == ["systemd-run", "--user"] and command[-1] == WORKER, "Not the reviewed source-proof worker")
    require(template["owner_label"] == "org.kataglyphis.migraphx-source", "Wrong source-proof owner label")
    for value in ["--no-block", "--expand-environment=no", "Type=oneshot", "RemainAfterExit=yes",
                  "TimeoutStartSec=1200", "TimeoutStopSec=300", "--init"]:
        require(value in command, "Missing bounded source-proof property: " + value)
    payload = command[command.index("run") + 1:]
    for flag, expected in [("--network", "none"), ("--pull", "never"), ("--security-opt", "apparmor=unconfined"),
                           ("--cpus", "4"), ("--memory", "8g"), ("--user", "0:0")]:
        require(payload.count(flag) == 1 and payload[payload.index(flag) + 1] == expected, "Changed source-proof transport: " + flag)
    require("--entrypoint" not in command and "--privileged" not in command, "Source proof requires the normal image entrypoint")
    old_output = str(Path(str(template["source"])).parent)
    substitutions = {old_output: str(output), str(template["unit"]).removesuffix(".service"): unit.removesuffix(".service"),
                     str(template["run_id"]): token}
    pattern = re.compile("|".join(re.escape(value) for value in substitutions))
    def replace(value: str) -> str:
        return pattern.sub(lambda match: substitutions[match[0]], value)
    result = []
    for value in command:
        if value.startswith("ExecStopPost="):
            value = "ExecStopPost=" + shlex.join([replace(part) for part in shlex.split(value.split("=", 1)[1])])
        else:
            value = replace(value)
        result.append(value)
    return result


def run(args: argparse.Namespace) -> int:
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.service", args.unit) is not None, "Pass one explicit source-proof unit")
    state = checked_output(["systemctl", "--user", "show", "--property=LoadState", "--value", args.unit]).strip()
    require(state == "not-found", "Preserve the existing unit and choose a fresh name")
    template = json.loads(args.template.read_text())
    owner = OwnedContainers("unused", str(template["owner_label"]), uuid.uuid4().hex)
    command = replay_command(template, args.output, args.unit, owner.run_id)
    freeze = runpy.run_path(str(ROOT / "linux/scripts/launch-migraphx-configure-proof.py"))["freeze_owner_source"]
    source, head, patch = freeze(args.output)
    previous_source = Path(str(template["source"]))
    for relative in LOCKS:
        require((source / relative).read_bytes() == (previous_source / relative).read_bytes(), "Quality tool lock changed: " + relative)
    shutil.copytree(previous_source / "quality/.venv", source / "quality/.venv", symlinks=True)
    selected = selected_recipes(source, args.manifest)
    (args.output / "selected-mutations.json").write_text(json.dumps(selected, indent=1) + "\n")
    record = {"unit": args.unit, "run_id": owner.run_id, "owner_label": template["owner_label"], "command": command,
              "source": str(source), "head": head, "patch_sha256": hashlib.sha256(patch).hexdigest(),
              "registry": len(json.loads((source / "docs/scripts/mutations.json").read_text())),
              "selected_mutations": len(selected), "template": str(args.template), "scope": __doc__}
    (args.output / "invocation.json").write_text(json.dumps(record, indent=2) + "\n")
    return run_logged(command, args.output / "launch.log")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--manifest", type=Path, action="append", required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    try:
        return run(args)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"Source proof refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
