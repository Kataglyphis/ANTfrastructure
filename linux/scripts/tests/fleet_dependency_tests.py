"""Tiny graph fixtures cover dependency queries and convergence, not Git walking or Renovate execution."""

import itertools
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Iterator
from pathlib import Path
from typing import TypeAlias, cast

ROOT = Path(__file__).resolve().parents[3]
SUBJECT = Path(sys.argv.pop(1)).resolve()
Case: TypeAlias = tuple[str, str, int, str, list[str], list[str], list[str]]
Receipt: TypeAlias = list[int | str]
BASH = shutil.which("bash") or "bash"
DRIVER = r"""set -u
source "$1"; shift
IFS= read -r -d '' mode
IFS= read -r -d '' strict
IFS= read -r -d '' context
IFS= read -r -d '' ifsmode
IFS= read -r -d '' index
IFS= read -r -d '' target
IFS= read -r -d '' n
OWN_IDS=(); OWN_NAMES=(); OWN_DEPS=(); CYCLES=()
for ((i=0;i<n;i++));do IFS= read -r -d '' item; OWN_IDS+=("$item");done
for ((i=0;i<n;i++));do IFS= read -r -d '' item; OWN_NAMES+=("$item");done
for ((i=0;i<n;i++));do IFS= read -r -d '' item; OWN_DEPS+=("$item");done
case "$ifsmode" in comma) IFS=,;; unset) unset IFS;; esac
BASH_REMATCH=(seed stable)
_FLEET_FIXTURE_STEPS=0
set -T
trap '_FLEET_FIXTURE_STEPS=$((_FLEET_FIXTURE_STEPS+1)); if [ "$_FLEET_FIXTURE_STEPS" -gt 100000 ]; then printf "fixture graph exceeded command budget\n" >&2; exit 97; fi' DEBUG
invoke() { case "$mode" in add) add_dep "$index" "$target";; closure) close_deps;; cycles) find_cycles;; esac; }
[ "$strict" != strict ] || set -e
if [ "$context" = conditional ]; then if invoke; then status=0; else status=$?;fi
else invoke;status=$?;fi
printf '%s\0' "$status" "${#OWN_DEPS[@]}"
for entry in "${OWN_DEPS[@]}";do printf '%s\0' "$entry";done
printf '%s\0' "${#CYCLES[@]}"
for entry in "${CYCLES[@]}";do printf '%s\0' "$entry";done
printf '%s\0' "${#BASH_REMATCH[@]}"
for entry in "${BASH_REMATCH[@]}";do printf '%s\0' "$entry";done
"""


def cases() -> Iterator[Case]:
    ids = ["a", "b", "c"]
    names = ["Alpha", "Beta", "Gamma"]
    edges = list(itertools.permutations(range(3), 2))
    for mask in range(64):
        deps = [" "] * 3
        for bit, (a, b) in enumerate(edges):
            if mask & (1 << bit):
                deps[a] += ids[b] + " "
        for mode in ["cycles", "closure"]:
            yield (mode, "default", 0, "b", ids, names, deps)
    for value in [
        "",
        "a",
        "b",
        "bigger",
        "a b",
        "a*b",
        "a?b",
        "b[1]",
        "line\nbreak",
        "tab\tvalue",
    ]:
        for existing in [" ", f" {value} ", f" before {value} after ", f" {value}x "]:
            yield ("add", "default", 0, value, ids, names, [existing, " ", " "])
    for ifsmode in ["default", "comma", "unset"]:
        for mode in ["cycles", "closure"]:
            for data in [
                (["a", "b", "c"], [" a b unknown ", " c ", " a "]),
                ([], []),
                (["same", "same"], [" same ", " same "]),
            ]:
                yield (
                    mode,
                    ifsmode,
                    0,
                    "",
                    data[0],
                    ["name " + str(i) for i in range(len(data[0]))],
                    data[1],
                )


def functions(subject: Path) -> bytes:
    script = 'source "$1"\nfor name in fleet_has_dep add_dep own_index close_deps find_cycles; do if grep -Eq "^${name}\\(\\)" "$2"; then t_fn_src "$2" "$name"; fi; done'
    r = subprocess.run(
        [
            BASH,
            "-c",
            script,
            "fleet-test",
            str(ROOT / "linux/scripts/tests/test-harness.sh"),
            str(subject),
        ],
        capture_output=True,
        check=True,
    )
    return r.stdout


def records(subject: Path) -> Iterator[tuple[str, Receipt]]:
    with tempfile.TemporaryDirectory(prefix="ant-fleet-deps-") as td:
        fn = Path(td) / "functions.sh"
        fn.write_bytes(functions(subject))
        for strict, context in itertools.product(
            ["strict", "relaxed"], ["direct", "conditional"]
        ):
            for index, case in enumerate(cases()):
                mode, ifsmode, slot, target, ids, names, deps = case
                value = run(
                    fn, mode, strict, context, ifsmode, slot, target, ids, names, deps
                )
                yield f"{strict}:{context}:{index}", value


def run(
    fn: Path,
    mode: str,
    strict: str,
    context: str,
    ifsmode: str,
    slot: int,
    target: str,
    ids: list[str],
    names: list[str],
    deps: list[str],
) -> Receipt:
    args = [
        mode,
        strict,
        context,
        ifsmode,
        str(slot),
        target,
        str(len(ids)),
        *ids,
        *names,
        *deps,
    ]
    wire = b"\0".join(value.encode() for value in args) + b"\0"
    result = subprocess.run(
        [BASH, "-c", DRIVER, "fleet-fixture", str(fn)],
        capture_output=True,
        input=wire,
        env={**os.environ, "LC_ALL": "C"},
        check=False,
    )
    return [
        result.returncode,
        result.stdout.hex(),
        result.stderr.replace(str(fn.parent).encode(), b"WORK").decode(),
    ]


def state(receipt: Receipt) -> tuple[int, list[str], list[str], list[str]]:
    fields = bytes.fromhex(cast(str, receipt[1])).decode().split("\0")[:-1]
    status = int(fields.pop(0))
    arrays: list[list[str]] = []
    for _ in range(3):
        count = int(fields.pop(0))
        arrays.append(fields[:count])
        del fields[:count]
    return status, arrays[0], arrays[1], arrays[2]


class FleetDependencyTests(unittest.TestCase):
    def test_original_receipts(self) -> None:
        expected = json.loads(
            Path(__file__).with_name("fleet-dependency-receipts.json").read_text()
        )
        visited = set()
        for key, actual in records(SUBJECT):
            self.assertEqual(expected[key], actual, key)
            visited.add(key)
        self.assertEqual(set(expected), visited)

    def test_independent_graph_expectations(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            fn = Path(td) / "functions.sh"
            fn.write_bytes(functions(SUBJECT))
            ids, names = ["a", "b", "c"], ["Alpha", "Beta", "Gamma"]
            vectors = [
                (
                    "cycles",
                    [" b c ", " a c ", " a b "],
                    [" b c ", " a c ", " a b "],
                    [
                        "Alpha and Beta vendor EACH OTHER",
                        "Alpha and Gamma vendor EACH OTHER",
                        "Beta and Gamma vendor EACH OTHER",
                    ],
                ),
                ("cycles", [" b ", " c ", " a "], [" b ", " c ", " a "], []),
                ("closure", [" b ", " c ", " "], [" b c ", " c ", " "], []),
            ]
            for mode, deps, expected_deps, expected_cycles in vectors:
                receipt = run(
                    fn, mode, "strict", "direct", "default", 0, "", ids, names, deps
                )
                self.assertEqual(0, receipt[0], receipt[2])
                self.assertEqual(
                    (0, expected_deps, expected_cycles, ["seed", "stable"]),
                    state(receipt),
                )
            for target, initial, expected in [
                ("bet", " beta ", " beta bet "),
                ("b*", " bX ", " bX b* "),
                ("", " x ", " x  "),
                ("", " x  ", " x  "),
            ]:
                receipt = run(
                    fn,
                    "add",
                    "strict",
                    "direct",
                    "default",
                    0,
                    target,
                    ids,
                    names,
                    [initial, " ", " "],
                )
                self.assertEqual(0, receipt[0], receipt[2])
                self.assertEqual([expected, " ", " "], state(receipt)[1])

    def test_nonconvergence_cannot_hang_the_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            fn = Path(td) / "functions.sh"
            fn.write_text("close_deps() { while :; do :; done; }\n")
            receipt = run(
                fn, "closure", "strict", "direct", "default", 0, "", [], [], []
            )
            self.assertEqual(97, receipt[0])
            self.assertEqual("", receipt[1])
            self.assertEqual("fixture graph exceeded command budget\n", receipt[2])


if __name__ == "__main__":
    unittest.main()
