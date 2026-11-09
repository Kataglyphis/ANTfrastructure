#!/usr/bin/env python3
"""Report ordered preflight output; these observations do not establish image or test acceptance."""

import argparse
import json
import re
from pathlib import Path

BITES = re.compile(r"^\[\d+/\d+\]\s+bites\s+", re.MULTILINE)
FAILURES = re.compile(r"^\[\d+/\d+\]\s+(?:FAIL\b|SURVIVED\b|ERROR\b|STALE\b|INVALID\b|TIMEOUT\b).*$", re.MULTILINE)


def find_jobs(root: Path) -> Path | None:
    candidates = []
    for directory in root.glob("ordered-jobs.*"):
        first = directory / "0.out"
        if first.is_file() and "no w/crlf" in first.read_text(errors="replace"):
            candidates.append(directory)
    if len(candidates) > 1:
        raise ValueError("multiple preflight job directories; select --jobs-dir explicitly")
    return candidates[0] if candidates else None


def job_results(directory: Path) -> dict[str, int]:
    results = {}
    for path in directory.glob("*.rc"):
        value = path.read_text().strip()
        if value:
            results[path.stem] = int(value)
    return results


def read_status(directory: Path | None) -> dict[str, object]:
    if directory is None:
        return {"status": "jobs-not-found", "mutation": None}
    results = job_results(directory)
    mutation = None
    script_tests = None
    for path in directory.glob("*.out"):
        text = path.read_text(errors="replace")
        if "=== mutation gate: can these tests fail? ===" in text[:4096]:
            lines = text.splitlines()
            mutation = {"proved": len(BITES.findall(text)), "failures": FAILURES.findall(text),
                        "last": lines[-1][:600] if lines else "", "exit_code": results.get(path.stem)}
        matches = re.findall(r"All linux script test suites passed \((\d+) suites, (\d+) assertions\)\.", text)
        if matches:
            suites, assertions = matches[-1]
            script_tests = {"suites": int(suites), "assertions": int(assertions),
                            "exit_code": results.get(path.stem)}
    return {"status": "observed", "jobs_dir": str(directory), "completed_jobs": len(results),
            "failed_jobs": {key: value for key, value in results.items() if value},
            "mutation": mutation, "script_tests": script_tests}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/tmp"))
    parser.add_argument("--jobs-dir", type=Path)
    args = parser.parse_args()
    directory = args.jobs_dir if args.jobs_dir is not None else find_jobs(args.root)
    if directory is not None and not directory.is_dir():
        raise ValueError(f"preflight job directory does not exist: {directory}")
    print(json.dumps(read_status(directory)))


if __name__ == "__main__":
    main()
