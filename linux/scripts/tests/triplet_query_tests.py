"""Actual triplet callers use offline filesystem and callback fixtures, without modifying host libraries or running compilers."""

import itertools
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]


def definitions(paths):
    harness = ROOT / "linux/scripts/tests/test-harness.sh"
    chunks = []
    for leaf, name in [
        ("compiler-resolution.sh", "_compiler_target_is_foreign"),
        ("compiler-resolution.sh", "pin_target_libstdcxx"),
        ("build-gst-plugins-rs.sh", "configure_gstreamer_prefix_for_cargo"),
    ]:
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; t_fn_src "$2" "$3"',
                "_",
                str(harness),
                str(paths[leaf]),
                name,
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
        chunks.append(result.stdout)
    return "\n".join(chunks)


WORKER = r"""
set -u
WORK="$1" caller="$2" chosen="$3" defaults="$4" mapper="$5" layout="$6" context="$7" strict="$8" inherit="$9"
trace() { printf '%s\0' "$@" >> "$WORK/trace"; }
source "$WORK/platform.sh"
source "$WORK/functions"
case "${10:-healthy}" in
 missing) unset -f deb_multiarch_triplet_best_effort ;;
 failed) deb_multiarch_triplet_best_effort() { return 23; } ;;
esac
command() { trace command "$@"; builtin command "$@"; }
if [ "$mapper" = missing ]; then unset -f arch_deb_multiarch_triplet_for; else
 arch_deb_multiarch_triplet_for() {
  trace map "$@"
  printf 'map diagnostic\n' >&2
  case "$mapper" in
   empty) return 0 ;;
   failed-empty) return 7 ;;
   failed-output) printf 'fixture-triplet\n\n'; return 7 ;;
   spaces) printf 'fixture triplet\n' ;;
   multiline) printf 'fixture\ntriplet\n' ;;
   inner-fail) false; printf fixture-triplet ;;
   *) printf 'fixture-triplet\n' ;;
  esac
 }
fi
build_arch_oci() { trace build; printf amd64; }
_target_gcc_libstdcxx() { trace gcc "$@"; if [ "$layout" != missing-source ]; then printf '%s' "$WORK/gcc/libstdc++.so.6.99"; fi; }
ln() { trace ln "$@"; if [ "$layout" = ln-fail ]; then return 17; fi; /usr/bin/ln "$1" "$2" "$WORK$3"; }
function [ {
 local _test_arg
 local -a _test_args=()
 for _test_arg in "$@"; do
  case "$_test_arg" in /usr/lib/*) _test_arg="$WORK$_test_arg" ;; esac
  _test_args+=("$_test_arg")
 done
 builtin [ "${_test_args[@]}"
}
unset TARGET_ARCH TARGETARCH ARCH PKG_CONFIG_PATH LD_LIBRARY_PATH
case "$defaults" in
 target) TARGET_ARCH=riscv64 ;;
 targetarch) TARGETARCH=arm64 ;;
 arch) ARCH=arm64 ;;
 precedence) TARGET_ARCH=riscv64 TARGETARCH=arm64 ARCH=amd64; export PKG_CONFIG_PATH='old pc path' LD_LIBRARY_PATH='old ld path' ;;
esac
GSTREAMER_PREFIX="$WORK/gst prefix"
state() { declare -p PKG_CONFIG_PATH LD_LIBRARY_PATH > "$WORK/state" 2>/dev/null || :; }
trap state EXIT
if [ "$strict" = strict ]; then set -e; fi
if [ "$inherit" = inherited ]; then shopt -s inherit_errexit; fi
operation() {
 if [ "$caller" = pin ]; then pin_target_libstdcxx "$chosen"; else configure_gstreamer_prefix_for_cargo; fi
}
if [ "$context" = conditional ]; then
 if operation; then status=0; else status=$?; fi
else operation; status=$?; fi
printf 'TAIL:%s\n' "$status"
"""


def cases():
    rows = []
    for caller, arch, mapper, layout, context, strict in itertools.product(
        ("pin", "gst"),
        ("arm64", "riscv64", "amd64"),
        (
            "missing",
            "empty",
            "ok",
            "failed-output",
            "failed-empty",
            "spaces",
            "multiline",
        ),
        ("present", "missing-dest", "missing-source"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
    ):
        rows.append((caller, arch, "unset", mapper, layout, context, strict, "default"))
    for caller, arch, defaults, context, strict in itertools.product(
        ("pin", "gst"),
        ("", "arm64"),
        ("unset", "target", "targetarch", "arch", "precedence"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
    ):
        rows.append(
            (caller, arch, defaults, "ok", "present", context, strict, "default")
        )
    for caller, context, strict, inherit in itertools.product(
        ("pin", "gst"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
        ("default", "inherited"),
    ):
        rows.append(
            (
                caller,
                "arm64",
                "unset",
                "inner-fail",
                "present",
                context,
                strict,
                inherit,
            )
        )
    for context, strict in itertools.product(
        ("direct", "conditional"), ("relaxed", "strict")
    ):
        rows.append(
            ("pin", "arm64", "unset", "ok", "ln-fail", context, strict, "default")
        )
    return rows


def capture(paths, funcs, row, api="healthy"):
    with tempfile.TemporaryDirectory(prefix="ant triplet query ") as directory:
        work = pathlib.Path(directory)
        (work / "trace").write_bytes(b"")
        (work / "platform.sh").write_bytes(paths["platform.sh"].read_bytes())
        (work / "functions").write_text(funcs)
        (work / "gcc").mkdir()
        (work / "gcc/libstdc++.so.6.99").write_text("TARGET_LIBRARY")
        mapper = row[3]
        triplet = {"spaces": "fixture triplet", "multiline": "fixture\ntriplet"}.get(
            mapper, "fixture-triplet"
        )
        if row[4] != "missing-dest":
            for name in {triplet, "aarch64-linux-gnu", "riscv64-linux-gnu"}:
                (work / "usr/lib" / name).mkdir(parents=True, exist_ok=True)
                (work / "gst prefix/lib" / name / "pkgconfig").mkdir(
                    parents=True, exist_ok=True
                )
        (work / "gst prefix/lib/pkgconfig").mkdir(parents=True, exist_ok=True)
        p = subprocess.run(
            ["/bin/bash", "-c", WORKER, "_", directory, *row, api],
            capture_output=True,
            timeout=5,
            check=False,
        )

        def clean(value):
            return value.decode().replace(directory, "[WORK]")

        files = (
            {
                str(p.relative_to(work)): clean(str(p.readlink()).encode())
                for p in sorted((work / "usr").rglob("*"))
                if p.is_symlink()
            }
            if (work / "usr").exists()
            else {}
        )
        return {"rc": p.returncode, "out": clean(p.stdout), "err": clean(p.stderr),
                "trace": clean((work / "trace").read_bytes()), "state": clean((work / "state").read_bytes()),
                "links": files}


def required_api_contract(paths, funcs):
    assertions = 0
    failures = []
    for caller, api, context, strict in itertools.product(
        ("pin", "gst"),
        ("missing", "failed"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
    ):
        row = (caller, "arm64", "unset", "ok", "present", context, strict, "default")
        actual = capture(paths, funcs, row, api)
        status = 127 if api == "missing" else 23
        stopped = context == "direct" and strict == "strict"
        checks = (
            actual["rc"] == (status if stopped else 0),
            actual["out"] == ("" if stopped else f"TAIL:{status}\n"),
            actual["state"] == "",
            actual["links"] == {},
            actual["err"].endswith(
                "deb_multiarch_triplet_best_effort: command not found\n"
            )
            if api == "missing"
            else actual["err"] == "",
        )
        assertions += len(checks)
        if not all(checks):
            failures.append(f"required API {caller}/{api}/{context}/{strict}: {actual}")
    return assertions, failures


def main():
    paths = dict(
        zip(
            ("platform.sh", "compiler-resolution.sh", "build-gst-plugins-rs.sh"),
            map(pathlib.Path, sys.argv[1:]),
            strict=True,
        )
    )
    funcs = definitions(paths)
    expected = json.loads(
        pathlib.Path(__file__).with_name("triplet-query-receipts.json").read_text()
    )
    rows = cases()
    failures = []
    assertions = 1
    if [list(row) for row in rows] != [entry["case"] for entry in expected]:
        failures.append("frozen original scenario inventory changed")
    for row, wanted in zip(rows, expected, strict=True):
        actual = capture(paths, funcs, row)
        for field in ("rc", "out", "err", "trace", "state", "links"):
            assertions += 1
            if actual[field] != wanted["receipt"][field]:
                failures.append(
                    f"{row} {field}: expected {wanted['receipt'][field]!r}, got {actual[field]!r}"
                )
    count, errors = required_api_contract(paths, funcs)
    assertions += count
    failures.extend(errors)
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    print(f"  {assertions} assertion(s), {len(failures)} failure(s)")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
