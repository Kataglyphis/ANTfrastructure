#!/usr/bin/env python3
"""Reject empty Python test and coverage reports before CI accepts a leg."""

import argparse
from decimal import Decimal, InvalidOperation
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def junit_passes(path: Path) -> int:
    root = ET.parse(path).getroot()
    suites = list(root.iter("testsuite"))
    if not suites:
        raise ValueError(f"{path}: no JUnit testsuite")
    cases = list(root.iter("testcase"))
    if not cases:
        raise ValueError(f"{path}: no tests ran")
    if any(int(suite.get(name, "0")) for suite in suites for name in ("failures", "errors")):
        raise ValueError(f"{path}: JUnit records failed or errored tests")
    passed = sum(not any(case.find(tag) is not None for tag in ("skipped", "failure", "error")) for case in cases)
    if passed == 0:
        raise ValueError(f"{path}: every test was skipped or failed")
    if any(case.find(tag) is not None for case in cases for tag in ("failure", "error")):
        raise ValueError(f"{path}: JUnit contains failed or errored test cases")
    return passed


def coverage_percent(path: Path) -> Decimal:
    root = ET.parse(path).getroot()
    if root.tag != "coverage":
        raise ValueError(f"{path}: expected a Cobertura coverage report")
    valid = int(root.attrib["lines-valid"])
    covered = int(root.attrib["lines-covered"])
    if valid <= 0 or covered <= 0 or covered > valid:
        raise ValueError(f"{path}: no measured, covered package lines")
    return Decimal(covered) * 100 / Decimal(valid)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--junit", required=True, type=Path)
    parser.add_argument("--coverage", required=True, type=Path)
    parser.add_argument("--min-coverage", default="0", help="minimum covered line percent, 0-100")
    args = parser.parse_args()
    try:
        floor = Decimal(args.min_coverage)
        if not floor.is_finite() or not 0 <= floor <= 100:
            raise ValueError("--min-coverage must be a finite number from 0 to 100")
        passed = junit_passes(args.junit)
        percent = coverage_percent(args.coverage)
        if percent < floor:
            raise ValueError(f"{args.coverage}: {percent:.2f}% is below the {floor}% floor")
    except (OSError, ET.ParseError, ValueError, KeyError, InvalidOperation) as exc:
        print(f"test report check failed: {exc}", file=sys.stderr)
        return 1
    print(f"test report check: {passed} passed; package coverage {percent:.2f}% (minimum {floor}%)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
