#!/usr/bin/env python3
"""Require a profiled ONNX model operator to execute on the requested provider."""

import argparse
import collections
import itertools
import json
import math
import re
import sys
from pathlib import Path
from typing import cast

PROVIDERS = {
    "cpu": "CPUExecutionProvider",
    "cuda": "CUDAExecutionProvider",
    # AMD's plugin reports the name it is registered under, and the family registers it as MIGraphX (CON231).
    "migraphx": "MIGraphX",
    "migraphx-plugin": "MIGraphX",
    "directml": "DmlExecutionProvider",
    "xnnpack": "XnnpackExecutionProvider",
    "dnnl": "DnnlExecutionProvider",
    # ORT Web's WebGPU builds (JSPI, Asyncify) and the JSEP build name their providers so; the CPU build is "cpu".
    "webgpu": "WebGpuExecutionProvider",
    "jsep": "JsExecutionProvider",
}
# ORT's session log at verbose, the browser's one record of where each node went: no profile file leaves the wasm.
PLACEMENT = re.compile(r"(?:All nodes|Node\(s\)) placed on \[([A-Za-z0-9_]+)\]\. Number of nodes: (\d+)")


def model_nodes(events: object) -> list[dict]:
    """The model Node events, each with its provider and operator; memcpy and other trace records prove nothing."""
    if not isinstance(events, list):
        raise TypeError("profile must be a list of events")
    return [
        event
        for event in events
        if isinstance(event, dict)
        and event.get("cat") == "Node"
        and isinstance(event.get("args"), dict)
        and isinstance(event["args"].get("provider"), str)
        and isinstance(event["args"].get("op_name"), str)
        and event["args"]["op_name"].strip()
        and not event["args"]["op_name"].strip().casefold().startswith("memcpy")
    ]


def operator_counts(events: object) -> collections.Counter[str]:
    """Model operators by provider: the one counting rule, which OrchestrANT's bundle imports too (CON289)."""
    return collections.Counter(event["args"]["provider"] for event in model_nodes(events))


def placement_counts(lines: object) -> collections.Counter[str]:
    """Nodes per provider from ORT's verbose placement lines; a second session's lines would double them, so one session only."""
    if not isinstance(lines, list):
        raise TypeError("log must be a list of lines")
    counts: collections.Counter[str] = collections.Counter()
    for line in lines:
        for provider, nodes in PLACEMENT.findall(line if isinstance(line, str) else ""):
            counts[provider] += int(nodes)
    return counts


def provider_shares(counts: collections.Counter[str]) -> dict[str, float]:
    """Each provider's share of the counted nodes, largest first; a share of 1.0 alone means nothing fell back."""
    total = sum(counts.values())
    return {provider: nodes / total for provider, nodes in counts.most_common() if nodes > 0} if total else {}


def interval(event: dict) -> tuple[int, float, float]:
    """Require a well-formed complete profiling interval and process identity."""
    pid, start, duration = event.get("pid"), event.get("ts"), event.get("dur")
    if (
        type(pid) is not int
        or type(start) not in (int, float)
        or type(duration) not in (int, float)
    ):
        raise ValueError("profile interval has invalid process or timing")
    start = cast(int | float, start)
    duration = cast(int | float, duration)
    if not math.isfinite(start) or not math.isfinite(duration):
        raise ValueError("profile interval has invalid process or timing")
    if start < 0 or duration < 0 or not math.isfinite(start + duration):
        raise ValueError("profile interval has invalid timing")
    return pid, start, start + duration


def require_profiled_runs(
    events: list, model_nodes: list, provider: str, minimum: int
) -> int:
    """Require a provider model operator inside each distinct sequential model run."""
    runs = [
        interval(event)
        for event in events
        if isinstance(event, dict)
        and event.get("cat") == "Session"
        and event.get("name") == "model_run"
        and event.get("ph") == "X"
    ]
    if len(runs) < minimum:
        raise ValueError(f"expected at least {minimum} complete model runs")
    runs.sort()
    for previous, current in itertools.pairwise(runs):
        if previous[0] != current[0] or previous[2] > current[1]:
            raise ValueError("model runs must be sequential in one process")
    nodes = [
        interval(event)
        for event in model_nodes
        if event["args"]["provider"] == provider and event.get("ph") == "X"
    ]
    for pid, start, end in runs:
        if not any(
            node_pid == pid and start <= node_start <= node_end <= end
            for node_pid, node_start, node_end in nodes
        ):
            raise ValueError(f"no {provider} model operator in a model run")
    return len(runs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("--device", choices=PROVIDERS, required=True)
    parser.add_argument(
        "--min-runs",
        type=int,
        default=None,
        help="require provider operators in every complete model run",
    )
    parser.add_argument(
        "--placements",
        action="store_true",
        help="the file is a JSON list of ORT's verbose log lines, as a browser gives them",
    )
    args = parser.parse_args()
    if args.min_runs is not None and args.min_runs < 1:
        parser.error("--min-runs must be positive")
    if args.placements and args.min_runs is not None:
        parser.error("--placements counts placed nodes, which have no runs")
    try:
        events = json.loads(args.profile.read_text(encoding="utf-8"))
        nodes = model_nodes(events)
        counts = collections.Counter(event["args"]["provider"] for event in nodes)
        if args.placements:
            counts = placement_counts(events)
        if args.min_runs is not None:
            require_profiled_runs(events, nodes, PROVIDERS[args.device], args.min_runs)
    except (OSError, TypeError, ValueError, OverflowError, UnicodeError) as error:
        print(f"Invalid ORT profile: {error}", file=sys.stderr)
        return 1
    provider = PROVIDERS[args.device]
    if counts[provider] == 0:
        print(
            f"No model operators executed on {provider}: {dict(counts)}",
            file=sys.stderr,
        )
        return 1
    print(f"{'Placed nodes' if args.placements else 'Profiled operators'}: {dict(counts)}")
    print("Provider shares: " + ", ".join(f"{name} {share:.1%}" for name, share in provider_shares(counts).items()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
