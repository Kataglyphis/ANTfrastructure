"""Offline QNN fixtures cover shallow-library selection and copied imports, not SDK or EP correctness."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from itertools import product
from pathlib import Path
from typing import TypedDict

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = Path(sys.argv.pop(1)).resolve()
DRIVER = r"""set -uo pipefail
find() { printf '%s\0' "$@" >> "$WORK/find"; command find "$@"; local rc=$?; [ "$FIND_STATUS" = 0 ] && return "$rc"; return "$FIND_STATUS"; }
grep() { printf '%s\0' "$@" >> "$WORK/grep"; command grep "$@"; local rc=$?; [ "$GREP_STATUS" = 0 ] && return "$rc"; return "$GREP_STATUS"; }
info() { printf 'INFO:%s\n' "$*"; }
err() { printf 'ERROR:%s\n' "$*" >&2; exit 1; }
"""

class QueryResult(TypedDict):
    rc: int
    out: str
    err: str
    tree: list[list[str]]
    find: str
    grep: str


def verification_run() -> str:
    text = (ROOT / "linux/Dockerfile.media").read_text().replace("\\\n", " ")
    run = next(
        line
        for line in text.splitlines()
        if line.startswith("RUN ")
        and "bash /opt/scripts/03-media/runtime/verify-media-artifacts.sh onnxruntime-cpu"
        in line
    )
    return run


def verification_mounts() -> dict[str, str]:
    return {
        target: source
        for source, target in re.findall(
            r"--mount=type=bind,source=([^, ]+),target=([^, ]+),readonly",
            verification_run(),
        )
    }


def create(path: Path, kind: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if kind == "regular":
        path.write_text("bytes")
    elif kind == "directory":
        path.mkdir()
    elif kind == "symlink":
        path.symlink_to(path.parent / "libonnxruntime.so")
    elif kind == "nested":
        (path / "child").mkdir(parents=True)
        (path / "child/libQnnCpu.so").write_text("nested")


def prefix_fixture(work: Path, kind: str, provider: str | None) -> Path:
    prefix = work / "prefix [*]"
    (prefix / "lib").mkdir(parents=True)
    (prefix / "include/onnxruntime/core/session").mkdir(parents=True)
    (prefix / "include/onnxruntime/core/session/onnxruntime_c_api.h").write_text(
        "header"
    )
    (prefix / "lib/libonnxruntime.so").write_text("runtime")
    if provider:
        create(prefix / "lib/libonnxruntime_providers_qnn.so", provider)
    create(prefix / "lib/libQnnCpu.so", kind)
    return prefix


def stage_fixture(work: Path, kind: str) -> tuple[Path, str]:
    target = work / "target"
    (target / "lib").mkdir(parents=True)
    create(target / "lib/libtarget.so", kind)
    (target / "deep").mkdir()
    (target / "deep/libnested.so").write_text("nested")
    sdk = work / "sdk/lib/aarch64-oe-linux-gcc11.2"
    sdk.mkdir(parents=True)
    (sdk / "libQnnCpu.so").write_text("backend")
    skel = work / "sdk/lib/hexagon-v73"
    skel.mkdir()
    (skel / "payload").write_text("skel")
    return (
        SCRIPTS / "01-core/qnn-sdk.sh",
        'source "$SCRIPT"; stage_qnn_runtime "$WORK/sdk" "$WORK/target"\n',
    )


def verification_fixture(work: Path, companion: str) -> tuple[Path, str]:
    for destination, source in verification_mounts().items():
        path = work / destination.lstrip("/")
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(SCRIPTS / source.removeprefix("linux/scripts/"), path)
    leaf = work / "opt/scripts/01-core/qnn-sdk.sh"
    variants = {
        "missing": None,
        "empty": "",
        "partial": "qnn_has_runtime_libraries() { :; }\nreturn 23\n",
        "parse": "qnn_has_runtime_libraries() { :; }\nif\n",
    }
    if companion in variants:
        leaf.unlink(missing_ok=True)
        variant = variants[companion]
        if variant is not None:
            leaf.parent.mkdir(parents=True, exist_ok=True)
            leaf.write_text(variant)
    script = work / "opt/scripts/03-media/runtime/verify-media-artifacts.sh"
    return script, 'source "$SCRIPT" onnxruntime-cpu "$PREFIX"\n'


def run(
    domain: str,
    kind: str,
    provider: str | None,
    context: str,
    strict: bool,
    find_status: int = 0,
    grep_status: int = 0,
    companion: str = "valid",
) -> QueryResult:
    with tempfile.TemporaryDirectory(prefix="ant-qnn-query-") as directory:
        work = Path(directory)
        prefix = prefix_fixture(work, kind, provider)
        script, body = (
            stage_fixture(work, kind)
            if domain == "stage"
            else verification_fixture(work, companion)
        )
        code = (
            DRIVER
            + ("set -e\n" if strict else "set +e\n")
            + "run_case() {\n"
            + body
            + "\n}\n"
        )
        code += (
            "if run_case; then echo STATUS:0; else echo STATUS:$?; fi"
            if context == "conditional"
            else "run_case"
        )
        env = dict(
            os.environ,
            WORK=str(work),
            SCRIPT=str(script),
            PREFIX=str(prefix),
            FIND_STATUS=str(find_status),
            GREP_STATUS=str(grep_status),
            QNN_SDK_LINUX_LIBDIR="aarch64-oe-linux-gcc11.2",
        )
        result = subprocess.run(
            ["bash", "-c", code],
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        normalize = lambda value: value.replace(directory, "WORK")
        tree = stage_tree(work) if domain == "stage" else []
        tool_output = {
            tool: normalize((work / tool).read_text())
            if (work / tool).exists()
            else ""
            for tool in ("find", "grep")
        }
        return {
            "rc": result.returncode,
            "out": normalize(result.stdout),
            "err": normalize(result.stderr),
            "tree": tree,
            "find": tool_output["find"],
            "grep": tool_output["grep"],
        }


def stage_tree(work: Path) -> list[list[str]]:
    tree = []
    for path in sorted((work / "target").rglob("*")):
        value = (
            "link:" + str(path.readlink()).replace(str(work), "WORK")
            if path.is_symlink()
            else "dir"
            if path.is_dir()
            else path.read_text()
        )
        tree.append([str(path.relative_to(work)), value])
    return tree


def capture() -> dict[str, QueryResult]:
    results: dict[str, QueryResult] = {}
    cases = product(
        ["stage", "verify"],
        ["missing", "regular", "directory", "symlink", "nested"],
        [None, "regular"],
        ["direct", "conditional"],
        [False, True],
        [(0, 0), (37, 0), (0, 41)],
    )
    for domain, kind, provider, context, strict, (fs, gs) in cases:
        key = str((domain, kind, provider, context, strict, fs, gs))
        results[key] = run(domain, kind, provider, context, strict, fs, gs)
    return results


class QnnRuntimeQuery(unittest.TestCase):
    def test_original_domain_receipts(self) -> None:
        expected = json.loads(
            Path(__file__).with_name("qnn-query-receipts.json").read_text()
        )
        self.assertEqual(240, len(expected))
        self.assertEqual(expected, capture())

    def test_independent_shallow_regular_policy(self) -> None:
        for kind in ["missing", "regular", "directory", "symlink", "nested"]:
            with self.subTest(kind=kind):
                got = run("verify", kind, "regular", "direct", True)
                self.assertEqual(0 if kind == "regular" else 1, got["rc"])
                self.assertEqual(
                    kind == "regular",
                    "QNN EP present, backend libs staged" in got["out"],
                )
        fault = run("verify", "regular", "regular", "direct", True, find_status=37)
        self.assertNotIn("QNN EP present", fault["out"])
        staged = run("stage", "missing", None, "direct", True)
        self.assertEqual(0, staged["rc"])
        self.assertIn(["target/deep/libQnnCpu.so", "backend"], staged["tree"])
        self.assertIn(["target/deep/hexagon-v73/payload", "skel"], staged["tree"])

    def test_cold_companions_are_branch_lazy_and_fail_closed(self) -> None:
        for companion, status in [
            ("missing", 1),
            ("empty", 1),
            ("partial", 23),
            ("parse", 2),
            ("valid", 0),
        ]:
            for context in ["direct", "conditional"]:
                with self.subTest(companion=companion, context=context):
                    self.assert_import(companion, status, context)

    def test_query_retains_inherited_pipeline_status(self) -> None:
        for pipefail, find_status, grep_status in product(
            [False, True], [0, 37], [0, 41]
        ):
            command = r"""set -u
source "$1"
find() { printf fixture; return "$2"; }
grep() { cat >/dev/null; return "$3"; }
""".replace('return "$2"', f"return {find_status}").replace(
                'return "$3"', f"return {grep_status}"
            )
            command += "set " + ("-" if pipefail else "+") + "o pipefail\n"
            command += 'if qnn_has_runtime_libraries fixture "*.so"; then exit 0; else exit "$?"; fi'
            result = subprocess.run(
                ["bash", "-c", command, "_", str(SCRIPTS / "01-core/qnn-sdk.sh")],
                text=True,
                capture_output=True,
                check=False,
                timeout=5,
            )
            expected = (grep_status or find_status) if pipefail else grep_status
            self.assertEqual(expected, result.returncode)
            self.assertEqual("", result.stdout)
            self.assertEqual("", result.stderr)

    def assert_import(self, companion: str, status: int, context: str) -> None:
        selected = run(
            "verify", "regular", "regular", context, True, companion=companion
        )
        self.assertEqual(status, selected["rc"])
        if companion == "empty":
            self.assertIn(
                "requires qnn_has_runtime_libraries from qnn-sdk.sh", selected["err"]
            )
        absent = run("verify", "regular", None, context, True, companion=companion)
        self.assertEqual(0, absent["rc"])
        self.assertEqual("", absent["out"])
        self.assertNotIn("qnn-sdk.sh", absent["err"])

    def test_actual_cpu_run_carries_canonical_companion(self) -> None:
        mounts = verification_mounts()
        self.assertEqual(
            "linux/scripts/01-core/qnn-sdk.sh",
            mounts.get("/opt/scripts/01-core/qnn-sdk.sh"),
        )
        self.assertEqual(
            "linux/scripts/03-media/runtime/verify-media-artifacts.sh",
            mounts.get("/opt/scripts/03-media/runtime/verify-media-artifacts.sh"),
        )

    def test_single_child_run_retains_original_shell_status(self) -> None:
        verifier = SCRIPTS / "03-media/runtime/verify-media-artifacts.sh"
        self.assertEqual("set -euo pipefail", verifier.read_text().splitlines()[1])
        parsed = subprocess.run(
            ["bash", "-n", str(verifier)], check=False, capture_output=True
        )
        self.assertEqual(0, parsed.returncode)
        current = re.sub(
            r"--mount=[^ ]+", "", verification_run().removeprefix("RUN ")
        ).strip()
        path = "/opt/scripts/03-media/runtime/verify-media-artifacts.sh"
        original = "set -euo pipefail; bash " + path + " onnxruntime-cpu"
        with tempfile.TemporaryDirectory(prefix="ant-qnn-run-") as directory:
            child = Path(directory) / "child.sh"
            child.write_text(
                'set -euo pipefail\nprintf "child:%s\\n" "$*"\nprintf child-stderr >&2\nexit "$CHILD_STATUS"\n'
            )
            for status in [0, 23]:
                outputs = []
                for command in [original, current]:
                    command = command.replace(path, str(child))
                    syntax = subprocess.run(
                        ["bash", "-n", "-c", command], check=False, capture_output=True
                    )
                    self.assertEqual(0, syntax.returncode)
                    result = subprocess.run(
                        ["bash", "--noprofile", "--norc", "-lc", command],
                        env=dict(os.environ, CHILD_STATUS=str(status)),
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    outputs.append((result.returncode, result.stdout, result.stderr))
                self.assertEqual(
                    [(status, "child:onnxruntime-cpu\n", "child-stderr")] * 2, outputs
                )


if __name__ == "__main__":
    unittest.main()
