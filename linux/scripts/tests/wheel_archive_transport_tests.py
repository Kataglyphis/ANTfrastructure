"""Actual wheel caller argv, status and cleanup use offline tools; wheel metadata and real strip are excluded."""

import itertools
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORKER = r"""
set -u
WORK="$1" caller="$2" MODE="$3" context="$4" strict="$5"
source "$WORK/functions"
trace() { printf '%s\0' "$@" >> "$WORK/trace"; }
mktemp() { trace mktemp "$@"; /usr/bin/mkdir -p "$WORK/tmp"; printf '%s\n' "$WORK/tmp"; }
rm() { trace rm "$@"; if [ "$MODE" = cleanup-fail ] && [ "${2:-}" = "$WORK/tmp" ]; then return 19; fi; /usr/bin/rm "$@"; }
mv() { trace mv "$@"; [ "$MODE" != rename-fail ] || return 17; /usr/bin/mv "$@"; }
first_match() { /usr/bin/find "$@" -print -quit; }
info() { printf 'INFO:%s\n' "$*"; }
warn() { printf 'WARN:%s\n' "$*" >&2; }
_resolve_media_strip_bin() { printf '%s' 'strip with spaces'; }
apply_shared_library_action() { trace strip "$@"; printf STRIPPED > "$1/dist one/payload.so"; }
runner() {
 trace "$@"
 local action="$3" src="$4" dest="$6"
 if [ "$1" = run ]; then action="$5"; src="$6"; dest="$8"; fi
 printf 'runner stdout\n'; printf 'runner stderr\n' >&2
 if [ "$action" = unpack ]; then
  if [ "$MODE" = second-unpack-fail ] && [[ "$src" = *second* ]]; then return 7; fi
  [ "$MODE" != unpack-fail ] || return 7
  /usr/bin/mkdir -p "$dest/dist one"
  if [ "$MODE" != no-payload ]; then
   /usr/bin/printf ORIGINAL > "$dest/dist one/payload.so"
   /usr/bin/printf RENAME > "$dest/dist one/_pywrap_tensorflow_interpreter_wrapper.so"
  fi
 else
  [ "$MODE" != pack-fail ] || return 9
  [ "$MODE" != no-packed ] || return 0
  /usr/bin/mkdir -p "$dest"
  /usr/bin/printf PACKED > "$dest/rebuilt.whl"
 fi
}
custom_python() { runner "$@"; }
uv() { runner "$@"; }
PYTHON=custom_python LITERT_PREFIX="$WORK/litert" WHEELS_DIR="$WORK/wheels" MEDIA_STRIP=1
[ "$MODE" != disabled ] || MEDIA_STRIP=0
[ "$MODE" != missing-python ] || PYTHON=missing_runner
if [ "$strict" = strict ]; then set -e; fi
operation() { if [ "$caller" = litert ]; then _litert_fix_pywrap_ext_name; else strip_cross_wheels; fi; }
if [ "$context" = conditional ]; then
 if operation; then status=0; else status=$?; fi
else
 operation
 status=$?
fi
printf 'TAIL:%s\n' "$status"
"""


def definitions(paths):
    harness = ROOT / "linux/scripts/tests/test-harness.sh"
    chunks = []
    for leaf, name in [
        ("litert-wheel.sh", "_litert_fix_pywrap_ext_name"),
        ("repair-wheels.sh", "_repair_wheel_uv"),
        ("repair-wheels.sh", "strip_cross_wheels"),
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
    if "wheel_archive_run() {" in paths["common.sh"].read_text():
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; t_fn_src "$2" wheel_archive_run',
                "_",
                str(harness),
                str(paths["common.sh"]),
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
        chunks.append(result.stdout)
    return "\n".join(chunks)


def run(funcs, row):
    mode = row[1]
    with tempfile.TemporaryDirectory(prefix="ant wheel transport ") as tmp:
        work = pathlib.Path(tmp)
        (work / "trace").write_bytes(b"")
        for d in ("litert/wheels", "wheels"):
            (work / d).mkdir(parents=True)
        if mode != "no-wheel":
            (work / "litert/wheels/ai_edge_litert-1.whl").write_text("INPUT")
            (work / "wheels/original.whl").write_text("INPUT")
        if mode == "pure":
            (work / "wheels/original.whl").rename(work / "wheels/pure-none-any.whl")
        if mode == "second-unpack-fail":
            (work / "litert/wheels/ai_edge_litert-second.whl").write_text("SECOND")
            (work / "wheels/second.whl").write_text("SECOND")
        (work / "functions").write_text(funcs)
        p = subprocess.run(
            ["/bin/bash", "-c", WORKER, "_", tmp, *row], capture_output=True, timeout=5, check=False
        )

        def clean(b) -> str:
            return b.decode().replace(tmp, "[WORK]")

        files = {
            str(p.relative_to(work)): p.read_text()
            for p in sorted(work.rglob("*"))
            if p.is_file() and p.name not in ("trace", "functions")
        }
        return {"rc": p.returncode, "out": clean(p.stdout), "err": clean(p.stderr),
                "trace": clean((work / "trace").read_bytes()), "files": files}


rows = list(
    itertools.product(
        ("litert", "runtime"),
        (
            "healthy",
            "unpack-fail",
            "pack-fail",
            "no-wheel",
            "no-payload",
            "cleanup-fail",
            "rename-fail",
            "no-packed",
            "disabled",
            "missing-python",
            "pure",
            "second-unpack-fail",
        ),
        ("direct", "conditional"),
        ("relaxed", "strict"),
    )
)


def main():
    paths = dict(
        zip(
            ("litert-wheel.sh", "repair-wheels.sh", "common.sh"),
            map(pathlib.Path, sys.argv[1:]),
            strict=True,
        )
    )
    expected = json.loads(
        pathlib.Path(__file__).with_name("wheel-archive-receipts.json").read_text()
    )
    funcs = definitions(paths)
    failures = []
    assertions = 1
    if [list(row) for row in rows] != [entry["case"] for entry in expected]:
        failures.append("frozen original scenario inventory changed")
    for row, wanted in zip(rows, expected, strict=True):
        actual = run(funcs, row)
        for field in ("rc", "out", "err", "trace", "files"):
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
