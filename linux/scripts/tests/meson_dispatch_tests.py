"""Actual Meson dispatch uses offline callbacks and temporary cross files, without configuring projects or running builds."""

import itertools
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]


def function(path, name):
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            'source "$1"; t_fn_src "$2" "$3"',
            "_",
            str(ROOT / "linux/scripts/tests/test-harness.sh"),
            str(path),
            name,
        ],
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
    )
    return result.stdout


def definitions(paths):
    common = paths["common.sh"]
    gst = paths["build-gstreamer-monorepo.sh"]
    camera = paths["build-libcamera.sh"].read_text()
    chunks = [
        function(common, name)
        for name in (
            "_common_meson_cross",
            "_common_meson_native",
            "append_available_meson_provider",
        )
    ]
    if "append_available_meson_toolchain_flags() {" in common.read_text():
        chunks.append(function(common, "append_available_meson_toolchain_flags"))
    if "_gst_monorepo_cross_pkgconfig() {" in gst.read_text():
        chunks.append(function(gst, "_gst_monorepo_cross_pkgconfig"))
    chunks.extend(
        function(gst, name)
        for name in (
            "_gst_monorepo_meson_cross",
            "_gst_monorepo_meson_native",
        )
    )
    chunks.append(
        function(gst, "_gst_monorepo_cross_flags").replace(
            "/tmp/gstreamer-debug-info.log", '"${WORK}/debug-output"'
        )
    )
    end = camera.index('\n\nif ! "${UV_RUN_PREFIX[@]}" meson setup')
    start = camera.rfind("\nfi\n\n", 0, end) + len("\nfi\n\n")
    return "\n".join(chunks), camera[start:end]


WORKER = r"""
set -u
WORK="$1" caller="$2" cross="$3" native="$4" file="$5" context="$6" strict="$7" inherit="$8" initial="$9" python="${10}"
source "$WORK/functions"
if [ "${11:-healthy}" = missing ]; then
 if [ "$caller" = camera ]; then unset -f append_available_meson_provider; else unset -f append_available_meson_toolchain_flags; fi
fi
trace() { printf '%s\0' "$@" >> "$WORK/trace"; }
command() { trace command "$@"; builtin command "$@"; }
provider() {
 local kind="$1" mode="$2" token
 shift 2
 trace "$kind" "$@"
 printf '%s stdout\n' "$kind"; printf '%s stderr\n' "$kind" >&2
 case "$mode" in
  inner-fail) false; trace "$kind-after-false" ;;
  subshell-fail) token="$(false; printf TOKEN)"; trace "$kind-subshell" "$token" ;;
 esac
 local -n _fixture_flags="$1"
 _fixture_flags+=("$kind flag with spaces" '')
 [ "$mode" != failed ] || return 7
}
if [ "$cross" != missing ]; then append_meson_cross_flags() { provider cross "$cross" "$@"; }; fi
if [ "$native" != missing ]; then append_meson_native_flags() { provider native "$native" "$@"; }; fi
sed() { trace sed "$@"; [ "$file" != sed-fail ] || return 19; /usr/bin/sed "$@"; [ "$file" != sed-partial-fail ] || return 19; }
append_meson_arg() { trace python "$@"; MESON_FLAGS+=("$1"); }
media_prepare_cross_compilers() { trace prepare; }
_gst_monorepo_wrap_flags() { trace wrap; }
dump_debug_info() { trace debug; printf 'debug stdout\n'; printf 'debug stderr\n' >&2; return 23; }
MESON_FLAGS=() MESON_SETUP_ARGS=()
if [ "$initial" = preset ]; then MESON_FLAGS=('seed flag' '' $'seed\nline'); MESON_SETUP_ARGS=('seed flag' '' $'seed\nline'); fi
MESON_CROSS_FILE="$WORK/cross config with spaces"
case "$python" in
 enabled) CROSS_PYTHON_BUILD_CONFIG='/target py config'; GSTREAMER_ENABLE_PYTHON_BINDINGS=true ;;
 disabled) CROSS_PYTHON_BUILD_CONFIG='/target py config'; GSTREAMER_ENABLE_PYTHON_BINDINGS=false ;;
 *) unset CROSS_PYTHON_BUILD_CONFIG GSTREAMER_ENABLE_PYTHON_BINDINGS ;;
esac
state() { declare -p MESON_FLAGS MESON_SETUP_ARGS > "$WORK/state"; }
trap state EXIT
if [ "$strict" = strict ]; then set -e; fi
if [ "$inherit" = inherited ]; then shopt -s inherit_errexit; fi
operation() { if [ "$caller" = gst ]; then _gst_monorepo_cross_flags; else source "$WORK/camera"; fi; }
if [ "$context" = conditional ]; then
 if operation; then status=0; else status=$?; fi
else operation; status=$?; fi
printf 'TAIL:%s\n' "$status"
"""


def cases():
    rows = []
    for caller, cross, native, file, context, strict in itertools.product(
        ("gst", "camera"),
        ("missing", "ok", "failed", "inner-fail"),
        ("missing", "ok", "failed", "inner-fail"),
        ("missing", "present", "sed-fail", "sed-partial-fail"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
    ):
        rows.append(
            (
                caller,
                cross,
                native,
                file,
                context,
                strict,
                "default",
                "preset",
                "enabled",
            )
        )
    for caller, context, strict in itertools.product(
        ("gst", "camera"), ("direct", "conditional"), ("relaxed", "strict")
    ):
        rows.append(
            (
                caller,
                "ok",
                "ok",
                "present",
                context,
                strict,
                "default",
                "empty",
                "enabled",
            )
        )
    for caller, kind, context, strict, inherit in itertools.product(
        ("gst", "camera"),
        ("cross", "native"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
        ("default", "inherited"),
    ):
        rows.append(
            (
                caller,
                "subshell-fail" if kind == "cross" else "ok",
                "subshell-fail" if kind == "native" else "ok",
                "present",
                context,
                strict,
                inherit,
                "preset",
                "enabled",
            )
        )
    for python, context, strict in itertools.product(
        ("disabled", "unset"), ("direct", "conditional"), ("relaxed", "strict")
    ):
        rows.append(
            ("gst", "ok", "ok", "present", context, strict, "default", "preset", python)
        )
    return rows


def capture(parts, row, api="healthy"):
    with tempfile.TemporaryDirectory(prefix="ant meson flags ") as directory:
        work = pathlib.Path(directory)
        (work / "trace").write_bytes(b"")
        (work / "functions").write_text(parts[0])
        (work / "camera").write_text(parts[1])
        if row[3] != "missing":
            (work / "cross config with spaces").write_text(
                "pkg_config_libdir = 'host path'\n pkg_config_libdir = 'retained'\nother = 'value'\npkg_config_libdir = 'other host'\n"
            )
        p = subprocess.run(
            ["/bin/bash", "-c", WORKER, "_", directory, *row, api],
            capture_output=True,
            timeout=5,
            check=False,
        )

        def clean(v):
            return v.decode().replace(directory, "[WORK]")

        return {
            "rc": p.returncode,
            "out": clean(p.stdout),
            "err": clean(p.stderr),
            "trace": clean((work / "trace").read_bytes()),
            "state": clean((work / "state").read_bytes()),
            "files": {
                name: clean((work / name).read_bytes())
                for name in ("cross config with spaces", "debug-output")
                if (work / name).exists()
            },
        }


def required_api_contract(parts, expected):
    frozen = {tuple(entry["case"]): entry["receipt"] for entry in expected}
    failures = []
    assertions = 0
    for caller, context, strict in itertools.product(
        ("gst", "camera"), ("direct", "conditional"), ("relaxed", "strict")
    ):
        row = (
            caller,
            "missing",
            "missing",
            "present",
            context,
            strict,
            "default",
            "preset",
            "enabled",
        )
        oracle = frozen[row]
        actual = capture(parts, row, "missing")
        stopped = caller == "camera" or (context == "direct" and strict == "strict")
        prefix = oracle["trace"].split("command\0-v\0append_meson_cross_flags\0", 1)[0]
        checks = (
            actual["rc"] == (1 if stopped else 0),
            actual["out"] == ("" if stopped else "TAIL:1\n"),
            actual["err"]
            == f"ERROR: common.sh does not provide {'append_available_meson_provider' if caller == 'camera' else 'append_available_meson_toolchain_flags'}\n",
            actual["state"] == oracle["state"],
            actual["trace"] == prefix,
            actual["files"]
            == {
                key: value
                for key, value in oracle["files"].items()
                if key != "debug-output"
            },
        )
        assertions += len(checks)
        if not all(checks):
            failures.append(f"required API {caller}/{context}/{strict}: {actual}")
    return assertions, failures


def main():
    paths = dict(
        zip(
            ("common.sh", "build-gstreamer-monorepo.sh", "build-libcamera.sh"),
            map(pathlib.Path, sys.argv[1:]),
            strict=True,
        )
    )
    parts = definitions(paths)
    expected = json.loads(
        pathlib.Path(__file__).with_name("meson-dispatch-receipts.json").read_text()
    )
    rows = cases()
    failures = []
    assertions = 1
    if [list(row) for row in rows] != [entry["case"] for entry in expected]:
        failures.append("frozen original scenario inventory changed")
    for row, wanted in zip(rows, expected, strict=True):
        actual = capture(parts, row)
        for field in ("rc", "out", "err", "trace", "state", "files"):
            assertions += 1
            if actual[field] != wanted["receipt"][field]:
                failures.append(
                    f"{row} {field}: expected {wanted['receipt'][field]!r}, got {actual[field]!r}"
                )
    count, errors = required_api_contract(parts, expected)
    assertions += count
    failures.extend(errors)
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    print(f"  {assertions} assertion(s), {len(failures)} failure(s)")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
