"""The --json records of the size, complexity, duplication and hub-reuse scanners equal their text verdicts."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SIZE = ROOT / "linux/scripts/verify_code_size.py"
COMPLEXITY = ROOT / "linux/scripts/verify_code_complexity.py"
DUPES = ROOT / "docs/scripts/verify_code_dupes.py"
REUSE = ROOT / "docs/scripts/verify_hub_reuse.py"

COPIED = """stage_payload() {
  local source="$1" target="$2" mode="$3"
  if [ ! -d "$source" ]; then
    printf 'missing payload %s\\n' "$source" >&2
    return 1
  fi
  mkdir -p "$target" || return 1
  find "$source" -type f -name '*.bin' -print0 | sort -z | xargs -0 -r cp -t "$target"
  case "$mode" in
    strict) sha256sum "$target"/*.bin > "$target/SHA256SUMS" ;;
    loose) : ;;
  esac
  printf 'staged %s into %s for %s\\n' "$source" "$target" "$mode"
}
"""
PY_COPIED = '''def merge_rows(left, right, key):
    """Join two row lists on one key."""
    index = {row[key]: row for row in right}
    merged = []
    for row in left:
        other = index.get(row[key])
        if other is None:
            continue
        merged.append({**other, **row, "joined": True})
    merged.sort(key=lambda item: (item[key], len(item)))
    return merged
'''
NESTED = "def nested(a):\n" + "".join(
    "    " * (depth + 1) + f"if a > {depth}:\n" for depth in range(6)) + "    " * 7 + "return a\n"
BRANCHY = "branchy() {\n" + "".join(
    f'  if [ "$1" = {n} ]; then echo {n}; fi\n' for n in range(16)) + "}\n"
RUST = ("fn long_rs() {\n" + "    let _x = 1;\n" * 83 + "}\n"
        "/* nested /* } */ */\nfn short() -> u8 { 1 }\n")
DART = "class A {\n  int get x {\n    return 1;\n  }\n}\nvoid main() {\n}\n"
CPP = "int big(int a) {\n" + "  a += 1;\n" * 80 + "  return a;\n}\n"

# Each tree holds hand-counted units; a scanner's JSON must equal both its text verdict and these counts.
CONSUMER: dict[str, str] = {
    "tools/big.sh": "big() {\n" + "  :\n" * 85 + "}\nsmall() {\n  echo hi\n}\n" + BRANCHY,
    "tools/copy_a.sh": COPIED,
    "tools/copy_b.sh": COPIED.replace("stage_payload", "copy_payload"),
    "pkg/mod.py": "def long_fn():\n" + "    x = 1\n" * 89 + "    return x\n\n\n" + NESTED,
    "pkg/dup_a.py": PY_COPIED,
    "pkg/dup_b.py": PY_COPIED.replace("merge_rows", "join_rows"),
    "pkg/huge.py": "X = 1\n" * 805,
    "src/lib.rs": RUST,
    "app/main.dart": DART,
    "native/big.cpp": CPP,
}
HUB: dict[str, str] = {"linux/scripts/shared.sh": COPIED.replace("stage_payload", "hub_stage")}


def _git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(root), *args], check=True,
                   capture_output=True, text=True, encoding="utf-8")


def _tree(root: Path, files: dict[str, str]) -> Path:
    root.mkdir()
    _git(root, "init", "-q")
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    _git(root, "add", "-A")
    return root


class ScannerCase(unittest.TestCase):
    """One fixture consumer and hub per class, scanned by subprocess as CI runs them."""

    temp: tempfile.TemporaryDirectory[str]
    consumer: Path
    hub: Path

    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        base = Path(cls.temp.name)
        cls.consumer = _tree(base / "consumer", CONSUMER)
        cls.hub = _tree(base / "hub", HUB)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def run_scanner(self, gate: Path, *options: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(gate), *options], capture_output=True,
                              text=True, encoding="utf-8", check=False)

    def with_json(self, gate: Path, *options: str) -> tuple[subprocess.CompletedProcess[str], dict]:
        """Run with --json; the text, streams and status must equal a run without it."""
        path = Path(self.temp.name) / "out.json"
        plain = self.run_scanner(gate, *options)
        result = self.run_scanner(gate, *options, "--json", str(path))
        self.assertEqual((plain.returncode, plain.stdout, plain.stderr),
                         (result.returncode, result.stdout, result.stderr))
        record = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(1, record["schema_version"])
        # A file pair counts for both of its files, so only a per-file unit sums to its total.
        for key, total in record["totals"].items():
            rows = [row[key] for row in record["files"].values() if key in row]
            if rows and not (key == "pairs" and record["scanner"] == "code-dupes"):
                self.assertEqual(total, sum(rows), key)
        return result, record

    def counts(self, pattern: str, text: str) -> tuple[int, ...]:
        m = re.search(pattern, text)
        self.assertIsNotNone(m, f"no {pattern!r} in:\n{text}")
        assert m is not None
        return tuple(int(g) for g in m.groups())


class SizeJson(ScannerCase):
    def test_report_verdict_equals_json(self) -> None:
        result, record = self.with_json(SIZE, "--root", str(self.consumer), "--report-only")
        verdict = self.counts(r"REPORT: (\d+) oversized functions, (\d+) oversized files",
                              result.stdout)
        totals = record["totals"]
        self.assertEqual(verdict, (totals["oversized_functions"], totals["oversized_files"]))
        self.assertEqual((2, 1, 9, 7), (totals["oversized_functions"], totals["oversized_files"],
                                        totals["functions"], totals["files"]))
        self.assertEqual(1, record["files"]["pkg/huge.py"]["oversized_file"])

    def test_gate_verdict_equals_json(self) -> None:
        result, record = self.with_json(SIZE, "--root", str(self.consumer))
        self.assertEqual(1, result.returncode)
        functions = self.counts(r"functions: (\d+) over", result.stdout)
        files = self.counts(r"files: +(\d+) over", result.stdout)
        self.assertEqual(functions + files, (record["totals"]["oversized_functions"],
                                             record["totals"]["oversized_files"]))

    def test_extra_languages_report_only(self) -> None:
        base = ("--root", str(self.consumer), "--report-only")
        plain = self.run_scanner(SIZE, *base)
        result, record = self.with_json(SIZE, *base, "--extra-languages")
        self.assertEqual(plain.returncode, result.returncode)
        self.assertTrue(result.stdout.startswith(plain.stdout))
        extra = record["report_only"]
        verdict = self.counts(r"REPORT-ONLY: (\d+) oversized Rust, Dart or C/C\+\+ functions in "
                              r"(\d+) functions, (\d+) files", result.stdout)
        self.assertEqual(verdict, (extra["totals"]["oversized_functions"],
                                   extra["totals"]["functions"], extra["totals"]["files"]))
        self.assertEqual((2, 5, 3), verdict)
        gate = self.run_scanner(SIZE, "--root", str(self.consumer), "--extra-languages")
        self.assertEqual(1, gate.returncode)

    def test_unwritable_json_fails(self) -> None:
        blocker = Path(self.temp.name) / "blocker"
        blocker.write_text("", encoding="utf-8")
        result = self.run_scanner(SIZE, "--root", str(self.consumer), "--report-only",
                                  "--json", str(blocker / "out.json"))
        self.assertEqual(2, result.returncode)
        self.assertIn("cannot write --json", result.stderr)


class ComplexityJson(ScannerCase):
    def test_report_verdict_equals_json(self) -> None:
        result, record = self.with_json(COMPLEXITY, "--root", str(self.consumer), "--report-only")
        verdict = self.counts(r"REPORT: (\d+) functions over a complexity limit", result.stdout)
        self.assertEqual(verdict, (record["totals"]["over_limit"],))
        self.assertEqual((2, 9), (record["totals"]["over_limit"], record["totals"]["functions"]))

    def test_gate_verdict_equals_json(self) -> None:
        result, record = self.with_json(COMPLEXITY, "--root", str(self.consumer))
        self.assertEqual(1, result.returncode)
        cc = self.counts(r"cc: +(\d+) over", result.stdout)
        nesting = self.counts(r"nesting: +(\d+) over", result.stdout)
        self.assertEqual(cc + nesting, (record["totals"]["over_cc"],
                                        record["totals"]["over_nesting"]))
        self.assertEqual((1, 1), cc + nesting)


class DupesJson(ScannerCase):
    def test_gate_verdict_equals_json(self) -> None:
        result, record = self.with_json(DUPES, "--root", str(self.consumer))
        self.assertEqual(1, result.returncode)
        verdict = self.counts(r"code duplication gate: (\d+) copied block", result.stderr)
        self.assertEqual(verdict, (record["totals"]["findings"],))
        self.assertEqual((1, 1), (record["totals"]["findings"], record["totals"]["pairs"]))

    def test_report_verdict_equals_json(self) -> None:
        result, record = self.with_json(DUPES, "--root", str(self.consumer), "--report-only")
        verdict = self.counts(r"scanned (\d+) units in (\d+) files", result.stdout)
        self.assertEqual(verdict, (record["totals"]["units"], record["totals"]["files"]))
        self.assertEqual(3, record["totals"]["files"])

    def test_extra_languages_report_only(self) -> None:
        base = ("--root", str(self.consumer), "--report-only")
        plain = self.run_scanner(DUPES, *base)
        result, record = self.with_json(DUPES, *base, "--extra-languages")
        self.assertEqual(plain.returncode, result.returncode)
        self.assertEqual(plain.stderr, result.stderr)
        extra = record["report_only"]["totals"]
        verdict = self.counts(r"REPORT-ONLY: (\d+) Python file pair\(s\) over \d+ shared shingles "
                              r"in (\d+) units in (\d+) files", result.stdout)
        self.assertEqual(verdict, (extra["pairs"], extra["units"], extra["files"]))
        self.assertEqual((1, 4), (extra["pairs"], extra["files"]))

    def test_json_refuses_answer_modes(self) -> None:
        result = self.run_scanner(DUPES, "--root", str(self.consumer), "--json", "x.json",
                                  "--explain", "tools/copy_a.sh")
        self.assertEqual(2, result.returncode)


class HubReuseJson(ScannerCase):
    def test_verdict_equals_json(self) -> None:
        result, record = self.with_json(REUSE, "--root", str(self.consumer), "--hub",
                                        str(self.hub), "--report-only")
        verdict = self.counts(r"hub reuse: (\d+) overlapping unit pair\(s\) in (\d+) consumer "
                              r"unit\(s\), (\d+) consumer and (\d+) hub script\(s\); (\d+) "
                              r"declared synced copy/copies skipped; (\d+) idiom", result.stdout)
        totals = record["totals"]
        self.assertEqual(verdict, (totals["pairs"], totals["consumer_units"],
                                   totals["consumer_scripts"], totals["hub_scripts"],
                                   totals["synced"], totals["suppressed"]))
        self.assertEqual((2, 3, 1), (totals["pairs"], totals["consumer_scripts"],
                                     totals["hub_scripts"]))
        self.assertEqual(1, record["files"]["tools/copy_a.sh"]["pairs"])


if __name__ == "__main__":
    unittest.main()
