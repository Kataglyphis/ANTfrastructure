"""Private header fixtures cover first-match policy and alias binding, not actual LiteRT or TensorRT builds."""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Sequence
from functools import lru_cache
from itertools import product
from pathlib import Path
from typing import TypedDict

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = Path(sys.argv.pop(1)).resolve()
SUBJECTS = {
    "litert": ("03-media/build/litert/build-litert.sh", "_install_manual_flatbuffers"),
    "ort": (
        "03-media/build/onnxruntime/build/30-build-native-nvidia.sh",
        "init_nvidia_defaults",
    ),
}


class ReceiptResult(TypedDict):
    rc: int
    out: str
    err: str
    trace: str
    state: str
    tree: list[list[str]]


class LegacyResult(TypedDict):
    rc: int
    out: str
    err: str
    trace: str
WORKER = r"""set -uo pipefail
shopt -s expand_aliases
record() { printf '%s\n' "$@" >> "$WORK/trace"; }
find_result() { record "$@"; if [ -n "$RESULT" ]; then printf '%s\n' "$RESULT"; fi; return "$FIND_STATUS"; }
find_early() { find_result early "$@"; }
find_late() { find_result late "$@"; }
find_latest() { find_result latest "$@"; }
info() { printf 'INFO:%s\n' "$*"; }
warn() { printf 'WARN:%s\n' "$*"; }
mkdir() { record mkdir "$@"; command mkdir "$@"; }
cp() { record cp "$@"; command cp "$@"; }
ln() { record ln "$@"; }
uname() { printf x86_64; }
unset NATIVE_GPU_OUTPUT_DIR CUDA_HOME CUDNN_HOME NATIVE_GPU_BUILD_DIR TRT_INC ARCH DEB_ARCH fb_found
alias find=find_early
source "$HELPER"
"""


@lru_cache
def extract(file: Path, name: str) -> str:
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1/linux/scripts/tests/test-harness.sh"; t_fn_src "$2" "$3"',
            "_",
            str(ROOT),
            str(file),
            name,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def sources(work: Path, subject: str, availability: str) -> str:
    for key, (relative, name) in SUBJECTS.items():
        source = extract(SCRIPTS / relative, name)
        source = re.sub(
            r"/usr/include|/usr/local|/usr/lib|/tmp/tensorrt|/usr",
            lambda match: str(work / "system" / match[0].lstrip("/")),
            source,
        )
        (work / key).write_text(source)
    helper = (SCRIPTS / "01-core/guard-helpers.sh").read_text()
    if availability == "missing":
        helper = ""
    elif availability == "legacy":
        helper = "first_match() { :; }\n"
    (work / "helper").write_text(helper)
    return str(work / subject)


def prepare(work: Path, subject: str, early: bool) -> Path:
    selected = work / "selected/include"
    selected.mkdir(parents=True)
    (selected / "NvInfer.h").write_text("tensor header")
    (selected / "flatbuffers.h").write_text("flat header")
    (work / "build").mkdir()
    (work / "include").mkdir()
    (work / "source/litert").mkdir(parents=True)
    if early and subject == "litert":
        dest = work / "build/_deps/flatbuffers-src/include"
        dest.mkdir(parents=True)
        (dest / "flatbuffers.h").write_text("early")
    if early and subject == "ort":
        (work / "trt/include").mkdir(parents=True)
        (work / "trt/include/NvInfer.h").write_text("early")
    return selected / ("flatbuffers.h" if subject == "litert" else "NvInfer.h")


def driver(
    subject: str, context: str, strict: bool, phase: str,
    order: tuple[str, str] | None, prefix: bool = False,
) -> str:
    code = WORKER
    if order is None:
        if phase in ("before", "after"):
            code += "alias find=find_late\n"
        code += 'source "$FUNCTION"\n'
        if phase == "after":
            code += "alias find=find_latest\n"
    else:
        code += f'source "$WORK/{order[0]}"\nalias find=find_late\nsource "$WORK/{order[1]}"\n'
        code += 'alias find=find_latest\nsource "$HELPER"\n'
    code += "set -e\n" if strict else "set +e\n"
    code += r"""trap 'for v in fb_found NATIVE_GPU_OUTPUT_DIR CUDA_HOME TENSORRT_HOME CUDNN_HOME NATIVE_GPU_BUILD_DIR TRT_INC ARCH DEB_ARCH; do declare -p "$v" 2>/dev/null || :; done > "$WORK/state"; declare -F _litert_header_find _ort_trt_header_find >> "$WORK/state" || :' EXIT
"""
    invocation = SUBJECTS[subject][1]
    if subject == "litert":
        invocation += ' "$WORK/build" "$WORK/include"'
    if prefix:
        invocation += " 'tail [*]' ''"
        code = re.sub(r"alias find=(find_\w+)", lambda match: "alias find='" + match[1] + ' "$@"' + "'", code)
    return code + (
        "if " + invocation + "; then echo STATUS:0; else echo STATUS:$?; fi"
        if context == "conditional"
        else invocation
    )


def receipt(
    subject: str,
    output: bool,
    status: int,
    context: str,
    strict: bool,
    phase: str = "same",
    early: bool = False,
    availability: str = "valid",
    order: tuple[str, str] | None = None,
    prefix: bool = False,
) -> ReceiptResult:
    with tempfile.TemporaryDirectory(prefix="ant-header-discovery-") as directory:
        work = Path(directory)
        result_path = prepare(work, subject, early)
        function = sources(work, subject, availability)
        env = dict(
            os.environ,
            WORK=directory,
            HELPER=str(work / "helper"),
            FUNCTION=function,
            LITERT_SRC=str(work / "source"),
            ORT_SRC_DIR=str(work / "ort"),
            TENSORRT_HOME=str(work / "trt"),
            RESULT=str(result_path) if output else "",
            FIND_STATUS=str(status),
        )
        result = subprocess.run(
            ["bash", "-c", driver(subject, context, strict, phase, order, prefix)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        normalize = lambda value: value.replace(directory, "WORK")
        return {
            "rc": result.returncode,
            "out": normalize(result.stdout),
            "err": normalize(result.stderr),
            "trace": normalize((work / "trace").read_text())
            if (work / "trace").exists()
            else "",
            "state": normalize((work / "state").read_text()),
            "tree": [
                [str(path.relative_to(work)), path.read_text()]
                for path in sorted((work / "include").rglob("*"))
                if path.is_file()
            ],
        }


def legacy_receipt(
    args: Sequence[str], strict: bool, conditional: bool, status: int
) -> LegacyResult:
    with tempfile.TemporaryDirectory(prefix="ant-first-match-legacy-") as directory:
        work = Path(directory)
        (work / "helper").write_text((SCRIPTS / "01-core/guard-helpers.sh").read_text())
        code = r"""set -uo pipefail
shopt -s expand_aliases
find_bound() { printf 'BOUND:%s\n' "$@" >> "$WORK/trace"; printf 'scope:%s\n' "${_path-unset}" >> "$WORK/trace"; printf 'partial\n'; printf hidden >&2; return "$FIND_STATUS"; }
find_late() { printf WRONG_ALIAS; }
alias find=find_bound
source "$WORK/helper"
alias find=find_late
""" + ("set -e\n" if strict else "set +e\n")
        code += (
            'if first_match "$@"; then echo STATUS:0; else echo STATUS:$?; fi'
            if conditional
            else 'first_match "$@"'
        )
        result = subprocess.run(
            ["bash", "-c", code, "_", *args],
            env=dict(os.environ, WORK=directory, FIND_STATUS=str(status)),
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        return {
            "rc": result.returncode,
            "out": result.stdout,
            "err": re.sub(
                r"line \d+:", "line N:", result.stderr.replace(directory, "WORK")
            ),
            "trace": (work / "trace").read_text() if (work / "trace").exists() else "",
        }


class HeaderDiscovery(unittest.TestCase):
    def test_original_whole_function_receipts(self) -> None:
        expected = json.loads(
            Path(__file__).with_name("header-discovery-receipts.json").read_text()
        )
        actual = {}
        for subject, output, status, context, strict in product(
            SUBJECTS,
            [False, True],
            [0, 23, 47],
            ["direct", "conditional"],
            [False, True],
        ):
            actual[str((subject, output, status, context, strict))] = receipt(
                subject, output, status, context, strict
            )
        self.assertEqual(48, len(expected))
        self.assertEqual(expected, actual)

    def test_legacy_first_match_receipts(self) -> None:
        expected = json.loads(
            Path(__file__).with_name("first-match-legacy-receipts.json").read_text()
        )
        for args, strict, conditional, status in product(
            [
                [],
                [""],
                ["root [*]"],
                ["root with space", "second root", "-name", "*.h"],
            ],
            [False, True],
            [False, True],
            [0, 23],
        ):
            with self.subTest(
                args=args, strict=strict, conditional=conditional, status=status
            ):
                self.assertEqual(
                    expected[str((args, strict, conditional, status))],
                    legacy_receipt(args, strict, conditional, status),
                )

    def test_late_aliases_and_multi_source_orders(self) -> None:
        for subject, phase in product(SUBJECTS, ["before", "after"]):
            result = receipt(subject, True, 23, "conditional", True, phase=phase)
            self.assertEqual(0, result["rc"])
            self.assertEqual(
                "late" if phase == "before" else "latest",
                result["trace"].splitlines()[0],
            )
            self.assertNotIn("_header_find", result["state"])
        for subject, order in product(SUBJECTS, [("litert", "ort"), ("ort", "litert")]):
            result = receipt(subject, True, 23, "conditional", True, order=order)
            self.assertEqual(0, result["rc"])
            self.assertEqual("latest", result["trace"].splitlines()[0])
            self.assertNotIn("_header_find", result["state"])

    def test_prefix_alias_keeps_enclosing_arguments(self) -> None:
        for subject, context, strict, phase, status, order in product(
            SUBJECTS, ["direct", "conditional"], [False, True],
            ["before", "after"], [0, 23],
            [None, ("litert", "ort"), ("ort", "litert")],
        ):
            with self.subTest(subject=subject, context=context, strict=strict,
                              phase=phase, status=status, order=order):
                result = receipt(subject, True, status, context, strict,
                                 phase=phase, prefix=True, order=order)
                self.assertEqual(0, result["rc"])
                enclosing = (["WORK/build", "WORK/include"]
                             if subject == "litert" else []) + ["tail [*]", ""]
                tool = (["WORK/source/litert", "-type", "f", "-path",
                         "*/flatbuffers/flatbuffers.h", "-print", "-quit"]
                        if subject == "litert" else
                        ["WORK/system/usr/include", "WORK/system/usr/local",
                         "-name", "NvInfer.h", "-print", "-quit"])
                expected_phase = "late" if phase == "before" and order is None else "latest"
                expected = [expected_phase] + enclosing + tool
                self.assertEqual(expected, result["trace"].splitlines()[:len(expected)])
                self.assertNotIn("_header_find", result["state"])

    def test_missing_api_is_selected_only(self) -> None:
        for subject, early, availability, context in product(
            SUBJECTS, [False, True], ["missing", "legacy"], ["direct", "conditional"]
        ):
            result = receipt(
                subject, False, 0, context, True, early=early, availability=availability
            )
            self.assertEqual(0 if early else 1, result["rc"])
            self.assertEqual(
                not early,
                "requires first_match_using from guard-helpers.sh" in result["err"],
            )
            self.assertNotIn("early\n", result["trace"])


if __name__ == "__main__":
    unittest.main()
