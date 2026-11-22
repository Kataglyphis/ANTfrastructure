"""Protocol doubles for pair transport; no native core, ONNX inference or GPU is executed."""

import json
import os
import sys
from pathlib import Path


def runner(args: list[str]) -> int:
    prefix, model, shape, data, device, destination = args
    output = Path(destination)
    if prefix != "prefix argument with spaces" or shape != "1,3,640,640":
        raise ValueError("Runner argument boundaries changed")
    if any(name.startswith(("ORT_MIGRAPHX_", "MIGRAPHX_")) for name in os.environ):
        raise ValueError("Tuning overrides reached the fixture")
    mode = os.environ["PAIR_MODE"]
    if mode == "native-" + device:
        return 41 if device == "cpu" else 43
    output.mkdir()
    (output / "tensors").mkdir()
    (output / "runner.json").write_text(
        json.dumps([prefix, model, shape, data, device])
    )
    count = {"no-profile": 0, "extra-profile": 2}.get(mode, 1)
    for number in range(count):
        (output / f"profile-{number}.json").write_text("{}")
    return 0


def python_probe(args: list[str]) -> int:
    if args[0] != "-I":
        raise ValueError("Probe interpreter is not isolated")
    tool = Path(args[1]).name
    mode = os.environ["PAIR_MODE"]
    if tool == "verify_ort_profile.py":
        profile = Path(args[2])
        expected = "cpu" if profile.parent.name == "cpu" else "migraphx-plugin"
        if (
            args[3:] != ["--device", expected, "--min-runs", "2"]
            or not profile.is_file()
        ):
            raise ValueError("Profile protocol changed")
        return 37 if mode == "profile" else 0
    if tool != "summarize_detector_tensors.py":
        raise ValueError("Unknown probe protocol")
    cpu, gpu = Path(args[2]), Path(args[3])
    if args[4:7] != ["--runs", "2", "--output"]:
        raise ValueError("Summary protocol changed")
    if not all((p.parent / "runner.json").is_file() for p in (cpu, gpu)):
        raise ValueError("Both native executions are required")
    if mode == "summary":
        return 39
    Path(args[7]).write_text(json.dumps({"acceptance": False}))
    return 0


if __name__ == "__main__":
    operation = runner if sys.argv[1] == "runner" else python_probe
    raise SystemExit(operation(sys.argv[2:]))
