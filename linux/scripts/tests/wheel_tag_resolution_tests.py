"""Actual wheel and GStreamer guards run with offline callbacks; no compilers, installers or build engines run."""

import itertools
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]


def fn(path, name):
    harness = ROOT / "linux/scripts/tests/test-harness.sh"
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            'source "$1"; t_fn_src "$2" "$3"',
            "_",
            str(harness),
            str(path),
            name,
        ],
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
    )
    return result.stdout


def gst_blocks(text, current):
    if current:
        return [
            text[m.start() : text.index("\nfi", m.start()) + 3]
            for m in re.finditer(r"^declare _gst_foreign_target$", text, re.MULTILINE)
        ]
    return [
        text[m.start() : text.index("\nfi", m.start()) + 3]
        for m in re.finditer(
            r"^if cross_build_is_active && \\\n   command -v cross_target_arch >/dev/null 2>&1; then$",
            text,
            re.MULTILINE,
        )
    ]


WORKER = r"""
set -u
WORK="$1" kind="$2" primary="$3" map="$4" target="$5" active="$6" context="$7" strict="$8" inherit="$9" initial="${10}"
trace() { printf '%s\0' "$@" >> "$WORK/trace"; }
command() { trace command "$@"; builtin command "$@"; }
if [ "$primary" != missing ]; then
 cross_wheel_platform_tag() { trace primary; printf 'PRIMARY\n'; printf 'primary diagnostic\n' >&2; [ "$primary" = healthy ] || return 7; }
fi
if [ "$map" != missing ]; then
 arch_linux_platform_tag_for() { trace map "$@"; printf 'MAP:%s\n' "$1"; printf 'map diagnostic\n' >&2; [ "$map" = healthy ] || return 9; }
fi
if [ "$target" != missing ]; then
 cross_target_arch() {
  trace target
  printf 'target diagnostic\n' >&2
  if [ "$target" = inner-fail ]; then false; trace after-inner-failure; printf arm64; return 0; fi
  case "$target" in
   fail-output) printf arm64; return 11 ;;
   fail-empty) return 13 ;;
   empty) return 0 ;;
   *) printf '%s' "$target" ;;
  esac
 }
fi
if [ "$active" != missing ]; then cross_build_is_active() { trace active; return "$active"; }; fi
if [ "$initial" = preset ]; then USE_LLD=original CXXFLAGS='existing flags' gi_cross_wrapper_arch=original; fi
state() { declare -p USE_LLD CXXFLAGS gi_cross_wrapper_arch _gst_foreign_target > "$WORK/state" 2>/dev/null || :; }
trap state EXIT
source "$WORK/functions"
if [ "$strict" = strict ]; then set -e; fi
if [ "$inherit" = inherited ]; then shopt -s inherit_errexit; fi
if [ "$context" = conditional ]; then
 if operation; then status=0; else status=$?; fi
else
 operation
 status=$?
fi
printf 'TAIL:%s\n' "$status"
"""


def sources(root):
    litert = root / "linux/scripts/03-media/build/litert/build-litert.sh"
    torch = root / "linux/scripts/05-frameworks/torch/build-app-wheelhouse.sh"
    setup = root / "linux/scripts/03-media/build/gstreamer/common/setup-gstreamer.sh"
    pre = root / "linux/scripts/03-media/build/gstreamer/common/pre-setup.sh"
    common = root / "linux/scripts/01-core/common.sh"
    media = root / "linux/scripts/03-media/core/common.sh"
    definitions = {}
    for key, path, name in [
        ("litert", litert, "litert_cross_wheel_platform_tag"),
        ("torch", torch, "wheel_platform_tag"),
    ]:
        helper = (
            fn(common, "wheel_platform_tag_with_fallback")
            if "wheel_platform_tag_with_fallback() {" in common.read_text()
            else ""
        )
        definitions[key] = (
            helper + "\n" + fn(path, name) + "\noperation() { " + name + "; }"
        )
    current = "media_gstreamer_foreign_target _gst_foreign_target" in setup.read_text()
    helper = (
        fn(media, "media_gstreamer_foreign_target")
        if "media_gstreamer_foreign_target() {" in media.read_text()
        else ""
    )
    for key, block in [
        ("gst-lld", gst_blocks(setup.read_text(), current)[0]),
        ("gst-cxx", gst_blocks(setup.read_text(), current)[1]),
        ("gst-gi", gst_blocks(pre.read_text(), current)[0]),
    ]:
        definitions[key] = (
            helper
            + "\noperation() {\n"
            + ('gi_cross_wrapper_arch=""\n' if key == "gst-gi" else "")
            + block
            + "\n}"
        )
    return definitions


def cases():
    rows = []
    for caller, p, m, t, c, s, i in itertools.product(
        ("litert", "torch"),
        ("missing", "healthy", "failed"),
        ("missing", "healthy", "failed"),
        (
            "missing",
            "arm64",
            "riscv64",
            "amd64",
            "empty",
            "fail-output",
            "fail-empty",
            "inner-fail",
        ),
        ("direct", "conditional"),
        ("relaxed", "strict"),
        ("default", "inherited"),
    ):
        rows.append((caller, p, m, t, "0", c, s, i, "unset"))
    for caller, t, a, c, s, i, initial in itertools.product(
        ("gst-lld", "gst-cxx", "gst-gi"),
        (
            "missing",
            "arm64",
            "riscv64",
            "amd64",
            "empty",
            "fail-output",
            "fail-empty",
            "inner-fail",
        ),
        ("0", "1", "7"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
        ("default", "inherited"),
        ("unset", "preset"),
    ):
        rows.append((caller, "missing", "missing", t, a, c, s, i, initial))
    return rows


def capture(functions, row):
    with tempfile.TemporaryDirectory(prefix="ant wheel tag ") as directory:
        work = pathlib.Path(directory)
        (work / "trace").write_bytes(b"")
        (work / "functions").write_text(functions[row[0]])
        result = subprocess.run(
            ["/bin/bash", "-c", WORKER, "_", directory, *row],
            capture_output=True,
            timeout=5,
            check=False,
        )

        def clean(value) -> str:
            return re.sub(
                r": line [0-9]+:",
                ": line [LINE]:",
                value.decode().replace(directory, "[WORK]"),
            )

        return {
            "rc": result.returncode,
            "out": clean(result.stdout),
            "err": clean(result.stderr),
            "trace": clean((work / "trace").read_bytes()),
            "state": clean((work / "state").read_bytes()),
        }


def main():
    root = pathlib.Path(sys.argv[1]).resolve()
    functions = sources(root)
    expected = json.loads(
        pathlib.Path(__file__).with_name("wheel-tag-receipts.json").read_text()
    )
    rows = cases()
    failures = []
    assertions = 1
    if [list(row) for row in rows] != [entry["case"] for entry in expected]:
        failures.append("frozen original scenario inventory changed")
    for row, wanted in zip(rows, expected, strict=True):
        actual = capture(functions, row)
        for field in ("rc", "out", "err", "trace", "state"):
            assertions += 1
            if actual[field] != wanted["receipt"][field]:
                failures.append(
                    f"{row} {field}: expected {wanted['receipt'][field]!r}, got {actual[field]!r}"
                )
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    print(f"  {assertions} assertion(s), {len(failures)} failure(s)")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
