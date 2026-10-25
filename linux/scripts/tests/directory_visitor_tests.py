"""Raw paths and loop slots use offline filesystem probes; no compiler, container engine or host library is modified."""

import itertools
import json
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "linux/scripts"))
from verify_dockerfile_context_paths import copy_sources
from verify_dockerfile_env_order import instructions


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
    chunks = []
    for leaf, name in [
        ("platform.sh", "path_visit_existing_directories"),
        ("platform.sh", "path_require_directory_visitor"),
        ("cross-env.sh", "_cross_append_library_path"),
        ("llvm.sh", "_llvm_append_runtime_library_path"),
    ]:
        if name + "() {" in paths[leaf].read_text():
            chunks.append(function(paths[leaf], name))
    cross = function(paths["cross-env.sh"], "_export_library_path").replace(
        '  if [ -n "${target_link_path}" ]; then',
        '  trace end-loop "${dir-unset}" "${target_link_path-unset}" "${path-unset}"\n  if [ -n "${target_link_path}" ]; then',
    )
    llvm = function(paths["llvm.sh"], "llvm_cross_target_runtime_library_path").replace(
        "  printf '%s' \"${path}\"",
        '  trace end-loop "${dir-unset}" "${target_link_path-unset}" "${path-unset}"\n  printf \'%s\' "${path}"',
    )
    return "\n".join(chunks + [cross, llvm])


WORKER = r"""
set -u
WORK="$1" caller="$2" shape="$3" layout="$4" libstate="$5" ifsmode="$6" context="$7" strict="$8" printfmode="$9" query="${10}"
source "$WORK/config"
source "$WORK/functions"
case "${11:-healthy}" in
 ready) unset -f path_require_directory_visitor ;;
 visitor) unset -f path_visit_existing_directories ;;
 callback) if [[ "$caller" = cross ]]; then unset -f _cross_append_library_path; else unset -f _llvm_append_runtime_library_path; fi ;;
esac
trace() { builtin printf '%s\0' "$@" >> "$WORK/trace"; }
llvm_cross_install_prefix() { trace prefix "$@"; builtin printf '%s' "$PREFIX_DATA"; [ "$query" != prefix-fail ] || return 7; }
arch_deb_multiarch_triplet_for() { trace triplet "$@"; builtin printf '%s' "$TRIPLET_DATA"; [ "$query" != triplet-fail ] || return 9; }
gcc_toolchain_prefix() { trace gcc; [ "$query" != gcc-empty ] || return 11; builtin printf '%s' "$GCC_DATA"; [ "$query" != gcc-output ] || return 11; }
version_major() { trace major "$@"; builtin printf 16; [ "$query" != major-fail ] || return 13; }
function [ {
 local _test_value="$2"
 if [[ "$1" = -d ]]; then
  trace probe "$2" "${dir-unset}" "${target_link_path-unset}" "${path-unset}"
  if [[ "$_test_value" != "$WORK"/* ]]; then _test_value="$WORK/system$_test_value"; fi
  if [[ "$layout" = probe-error && "$2" = "$LAST_CANDIDATE" ]]; then builtin printf 'probe failure\n' >&2; return 2; fi
  builtin [ -d "$_test_value" ]
 else builtin [ "$@"; fi
}
printf() {
 trace printf "$@" "${dir-unset}"
 if [[ "$printfmode" = failed ]]; then builtin printf PRINTF-PARTIAL; builtin printf 'printf failure\n' >&2; return 23; fi
 builtin printf "$@"
}
export() { trace export "$@" "${dir-unset}"; builtin export "$@"; }
declare -A table=([runtime_libdir]="$RUNTIME_DATA" [gcc_prefix]="$GCC_DATA" [triplet]="$TRIPLET_DATA")
case "$query" in
 missing-runtime) unset 'table[runtime_libdir]' ;;
 missing-gcc) unset 'table[gcc_prefix]' ;;
 missing-triplet) unset 'table[triplet]' ;;
esac
GCC_VERSION=fixture GCC_WANTED=16 SUDO='DO-NOT-RUN --poison *' dir=global-slot
if [[ "$query" = sudo-unset ]]; then unset SUDO; fi
unset LIBRARY_PATH path target_link_path
case "$libstate" in
 empty) LIBRARY_PATH='' ;;
 preset) LIBRARY_PATH=$'old\npaths:\n' ;;
 exported) export LIBRARY_PATH=$'old\npaths:\n' ;;
 readonly-empty) readonly LIBRARY_PATH='' ;;
 readonly-preset) readonly LIBRARY_PATH='READONLY LIBRARY' ;;
 readonly-slot) readonly dir ;;
 readonly-internal) if [[ "$caller" = cross ]]; then readonly target_link_path=READONLY; else readonly path=READONLY; fi ;;
esac
case "$ifsmode" in
 unset) unset IFS ;;
 empty) IFS='' ;;
 colon) IFS=: ;;
 newline) IFS=$'\n\t' ;;
esac
state() { declare -p LIBRARY_PATH dir path target_link_path > "$WORK/state" 2>/dev/null || :; }
trap state EXIT
if [[ "$strict" = strict ]]; then set -e; fi
operation() { if [[ "$caller" = cross ]]; then _export_library_path table; else llvm_cross_target_runtime_library_path arm64; fi; }
if [[ "$context" = conditional ]]; then
 if operation; then status=0; else status=$?; fi
else operation; status=$?; fi
builtin printf 'TAIL:%s\n' "$status"
"""
SHAPES = ("normal", "special", "colon", "newline", "trailing-lf", "duplicate", "empty")


CASE_FIELDS = (
    "caller",
    "shape",
    "layout",
    "libstate",
    "ifs",
    "context",
    "strict",
    "printfmode",
    "query",
)
CASE_DEFAULTS = dict(
    zip(
        CASE_FIELDS,
        (
            "cross",
            "normal",
            "all",
            "preset",
            "default",
            "direct",
            "relaxed",
            "healthy",
            "healthy",
        ),
        strict=True,
    )
)
CONTEXTS = ("direct", "conditional")
STRICTNESS = ("relaxed", "strict")
CALLERS = ("cross", "llvm")
CASE_PROFILES = (
    {
        "caller": CALLERS,
        "shape": SHAPES,
        "layout": ("all", "none", "alternate", "last-missing"),
        "libstate": ("unset", "empty", "preset", "exported"),
        "ifs": ("default", "colon"),
        "context": CONTEXTS,
        "strict": STRICTNESS,
    },
    {
        "caller": CALLERS,
        "shape": SHAPES,
        "ifs": ("unset", "empty", "newline"),
        "context": CONTEXTS,
        "strict": STRICTNESS,
    },
    {
        "caller": CALLERS,
        "libstate": (
            "readonly-empty",
            "readonly-preset",
            "readonly-slot",
            "readonly-internal",
        ),
        "layout": ("all", "none"),
        "context": CONTEXTS,
        "strict": STRICTNESS,
    },
    {
        "caller": ("llvm",),
        "shape": SHAPES,
        "layout": ("all", "none", "alternate", "last-missing"),
        "context": CONTEXTS,
        "strict": STRICTNESS,
        "printfmode": ("failed",),
    },
    {
        "caller": CALLERS,
        "layout": ("last-file", "last-symlink", "last-broken", "probe-error"),
        "context": CONTEXTS,
        "strict": STRICTNESS,
    },
    {"caller": CALLERS, "context": CONTEXTS, "strict": STRICTNESS, "query": ("sudo-unset",)},
    {
        "caller": CALLERS,
        "layout": ("all", "none", "last-file"),
        "libstate": ("preset", "readonly-slot"),
        "context": CONTEXTS,
        "strict": STRICTNESS,
        "query": ("global-slot",),
    },
    {
        "query": ("missing-runtime", "missing-gcc", "missing-triplet"),
        "context": CONTEXTS,
        "strict": STRICTNESS,
    },
    {
        "caller": ("llvm",),
        "query": ("prefix-fail", "triplet-fail", "gcc-empty", "gcc-output", "major-fail"),
        "context": CONTEXTS,
        "strict": STRICTNESS,
    },
)


def cases():
    rows = []
    for profile in CASE_PROFILES:
        for values in itertools.product(*profile.values()):
            row = CASE_DEFAULTS | dict(zip(profile, values, strict=True))
            rows.append(tuple(row[field] for field in CASE_FIELDS))
    return rows


def paths(work, shape, query):
    prefix = str(work / "prefix")
    gcc = str(work / "gcc")
    triplet = "fixture-triplet"
    runtime = str(work / "runtime")
    if shape == "special":
        prefix = str(work / "prefix *?[x]")
        gcc = str(work / "gcc $literal `name`")
        triplet = "triplet *?"
        runtime = str(work / "runtime ; literal")
    if shape == "colon":
        prefix = str(work / "prefix:one")
        gcc = str(work / "gcc:one")
        triplet = "triplet:one"
        runtime = str(work / "runtime:one")
    if shape == "newline":
        prefix = str(work / "prefix\nline")
        gcc = str(work / "gcc\nline")
        triplet = "triplet\nline"
        runtime = str(work / "runtime\nline")
    if shape == "trailing-lf":
        prefix = str(work / "prefix\n")
        gcc = str(work / "gcc\n")
        triplet = "triplet\n"
        runtime = str(work / "runtime\n")
    if shape == "duplicate":
        prefix = gcc
        runtime = f"{gcc}/{triplet}/lib"
    if shape == "empty":
        prefix = gcc = triplet = runtime = ""
    cross = [
        runtime,
        f"{gcc}/{triplet}/lib",
        f"/usr/lib/{triplet}",
        f"/lib/{triplet}",
        f"/usr/{triplet}/lib",
    ]
    lp = prefix.rstrip("\n")
    lt = triplet.rstrip("\n")
    lg = gcc.rstrip("\n") if query != "gcc-empty" else ""
    lg = lg or "/opt/gcc-fixture"
    llvm = [
        f"{lp}/lib",
        f"{lp}/lib64",
        f"{lg}/lib/gcc/{lt}/16",
        f"{lg}/{lt}/lib",
        f"{lg}/{lt}/lib64",
        f"{lg}/lib64",
        f"{lg}/lib",
        f"/lib/{lt}",
        f"/usr/lib/{lt}",
        f"/usr/{lt}/lib",
    ]
    return (
        {
            "PREFIX_DATA": prefix,
            "GCC_DATA": gcc,
            "TRIPLET_DATA": triplet,
            "RUNTIME_DATA": runtime,
        },
        cross,
        llvm,
    )


def physical_path(work, path):
    return (
        pathlib.Path(path)
        if path.startswith(str(work) + "/")
        else work / "system" / path.lstrip("/")
    )


def prepare_directories(work, candidates, layout):
    selected = {"all": candidates, "none": [], "alternate": candidates[::2]}.get(
        layout, candidates[:-1]
    )
    for path in selected:
        if path:
            physical_path(work, path).mkdir(parents=True, exist_ok=True)
    if layout in ("last-file", "last-symlink", "last-broken"):
        output = physical_path(work, candidates[-1])
        output.parent.mkdir(parents=True, exist_ok=True)
        if layout == "last-file":
            output.write_text("not a directory")
        else:
            target = work / "link-target"
            if layout == "last-symlink":
                target.mkdir()
            output.symlink_to(target, target_is_directory=True)


def capture(funcs, row, api="healthy"):
    with tempfile.TemporaryDirectory(prefix="ant existing dirs ") as directory:
        work = pathlib.Path(directory)
        (work / "trace").write_bytes(b"")
        if row[8] == "global-slot":
            funcs = funcs.replace(
                'local target_link_path="" dir', 'local target_link_path=""'
            ).replace('runtime_libdir path="" dir', 'runtime_libdir path=""')
        (work / "functions").write_text(funcs)
        config, cross, llvm = paths(work, row[1], row[8])
        candidates = cross if row[0] == "cross" else llvm
        config["LAST_CANDIDATE"] = candidates[-1]
        (work / "config").write_text(
            "\n".join(f"{key}={shlex.quote(value)}" for key, value in config.items())
        )
        prepare_directories(work, candidates, row[2])
        result = subprocess.run(
            ["/bin/bash", "-c", WORKER, "_", directory, *row, api],
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


def load_receipts():
    data = json.loads(
        pathlib.Path(__file__).with_name("directory-visitor-receipts.json").read_text()
    )
    return [
        {
            "case": entry["case"],
            "receipt": {
                field: data["values"][field][index]
                for field, index in entry["receipt"].items()
            },
        }
        for entry in data["cases"]
    ]


def required_api_contract(funcs, expected):
    frozen = {tuple(entry["case"]): entry["receipt"] for entry in expected}
    assertions = 0
    failures = []
    for caller, api, context, strict in itertools.product(
        ("cross", "llvm"),
        ("ready", "visitor", "callback"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
    ):
        row = (
            caller,
            "normal",
            "all",
            "preset",
            "default",
            context,
            strict,
            "healthy",
            "healthy",
        )
        oracle = frozen[row]
        unchanged = frozen[(caller, "normal", "none", "preset", "default", context, strict, "healthy", "healthy")]
        actual = capture(funcs, row, api)
        callback = (
            "_cross_append_library_path"
            if caller == "cross"
            else "_llvm_append_runtime_library_path"
        )
        status = 127 if api == "ready" else 1
        stopped = context == "direct" and strict == "strict"
        prefix = oracle["trace"].split("probe\0", 1)[0]
        if api != "ready":
            prefix += (
                "printf\0ERROR: directory visitor requires path_visit_existing_directories and %s\\n\0"
                + callback
                + "\0unset\0"
            )
        diagnostic = (
            actual["err"].endswith(
                ": path_require_directory_visitor: command not found\n"
            )
            if api == "ready"
            else actual["err"]
            == f"ERROR: directory visitor requires path_visit_existing_directories and {callback}\n"
        )
        checks = (
            actual["rc"] == (status if stopped else 0),
            actual["out"] == ("" if stopped else f"TAIL:{status}\n"),
            actual["state"] == unchanged["state"],
            actual["trace"] == prefix,
            diagnostic,
        )
        assertions += len(checks)
        if not all(checks):
            failures.append(f"required API {caller}/{api}/{context}/{strict}: {actual}")
    return assertions, failures


def fresh_copy(stage, source, target):
    mapping = {}
    for _, text in instructions(ROOT / "linux" / f"Dockerfile.{stage}"):
        sources = copy_sources(text)
        if not sources:
            continue
        destination = text.split()[-1]
        for leaf in sources:
            if not leaf.startswith("linux/scripts/"):
                continue
            if (ROOT / leaf).is_dir():
                if pathlib.PurePosixPath(source).is_relative_to(leaf):
                    relative = pathlib.PurePosixPath(source).relative_to(leaf)
                    mapping[str(pathlib.PurePosixPath(destination) / relative)] = source
            else:
                output = destination
                if len(sources) > 1 or destination.endswith("/"):
                    output = (
                        destination.rstrip("/") + "/" + pathlib.PurePosixPath(leaf).name
                    )
                mapping[output] = leaf
    return mapping.get(target) == source


def closure_contract():
    pairs = []
    failures = []
    for path in sorted((ROOT / "linux").glob("Dockerfile*")):
        if not path.is_file():
            continue
        for line, text in instructions(path):
            if not text.startswith("RUN "):
                continue
            mounts = re.findall(
                r"--mount=type=bind,source=([^,\s]+),target=([^,\s]+)([^\s]*)", text
            )
            for source, target, _ in mounts:
                if source != "linux/scripts/01-core/cross-env.sh":
                    continue
                required = str(pathlib.PurePosixPath(target).parent / "platform.sh")
                paired = any(
                    src == "linux/scripts/01-core/platform.sh"
                    and dst == required
                    and (",ro" in opts or ",readonly" in opts)
                    for src, dst, opts in mounts
                )
                pairs.append(paired)
                if not paired:
                    failures.append(
                        f"{path.name}:{line} lacks its fresh read-only platform owner"
                    )
    if len(pairs) != 6:
        failures.append(
            f"expected six audited cross-env RUN closures, found {len(pairs)}"
        )
    for stage in ("sdk", "torch"):
        if not fresh_copy(
            stage, "linux/scripts/01-core/platform.sh", "/opt/scripts/core/platform.sh"
        ):
            failures.append(f"{stage} lacks its fresh platform COPY")
    if not fresh_copy(
        "sdk", "linux/scripts/02-toolchain/llvm.sh", "/opt/scripts/toolchain/llvm.sh"
    ):
        failures.append(
            "SDK lacks its current LLVM entry alongside the fresh platform owner"
        )
    return len(pairs) + 4, failures


def main():
    paths = dict(
        zip(
            ("platform.sh", "cross-env.sh", "llvm.sh"),
            map(pathlib.Path, sys.argv[1:]),
            strict=True,
        )
    )
    funcs = definitions(paths)
    expected = load_receipts()
    rows = cases()
    failures = []
    assertions = 1
    if [list(row) for row in rows] != [entry["case"] for entry in expected]:
        failures.append("frozen original scenario inventory changed")
    for row, wanted in zip(rows, expected, strict=True):
        actual = capture(funcs, row)
        for field in ("rc", "out", "err", "trace", "state"):
            assertions += 1
            if actual[field] != wanted["receipt"][field]:
                failures.append(
                    f"{row} {field}: expected {wanted['receipt'][field]!r}, got {actual[field]!r}"
                )
    for count, errors in (required_api_contract(funcs, expected), closure_contract()):
        assertions += count
        failures.extend(errors)
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    print(f"  {assertions} assertion(s), {len(failures)} failure(s)")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
