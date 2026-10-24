"""Host callback receipts use offline provider functions; no real compiler wrapper, Cargo build or package operation runs."""

import itertools
import json
import pathlib
import re
import subprocess
import sys
import tempfile

SCRIPTS = pathlib.Path(sys.argv[1]).resolve()
TESTS = pathlib.Path(__file__).parent


WORKER = r"""
set -u
work="$1" caller="$2" scenario="$3" active="$4" context="$5" strict="$6" aliases="$7" inherit="$8"
shopt -s expand_aliases
trace() { printf '<%s>' "$@" >> "$work/trace"; printf '\n' >> "$work/trace"; }
cross_build_is_active() { [[ "$active" = cross ]]; }
cross_build_upper_rust() { printf CUSTOM; }
cross_build_lower_rust() { printf custom; }
resolve_host_gcc_for_cargo() {
 trace resolve-c
 case "$scenario" in cc-empty|both-empty) return 0;; cc-resolve-failed) printf '/partial cc'; return 11;; esac
 printf '/host compiler/cc'
}
resolve_host_gxx_for_cargo() {
 trace resolve-cxx
 case "$scenario" in cxx-empty|both-empty) return 0;; cxx-resolve-failed) printf '/partial cxx'; return 12;; esac
 printf '/host compiler/cxx'
}
prepare_impl() {
 local _audit_kind="$1"; shift
 trace "prepare-$_audit_kind" "$@" "$cargo_host_cc" "$cargo_host_linker" "$cargo_host_cxx" "$cargo_host_cxx_wrapper"
 [[ "$#" -eq 1 ]] || return 94
 cargo_host_cxx=CHILD_ONLY_CXX BINDING_c=CHILD_ONLY_BINDING
 case "$scenario" in
  "$_audit_kind-wrapper-inner-failed") false; trace after-wrapper-false ;;
  "$_audit_kind-wrapper-empty") return 0 ;;
  "$_audit_kind-wrapper-failed") printf '/partial wrapper'; return 13 ;;
 esac
 printf '/wrapped host/%s' "$_audit_kind"
}
prepare_cargo_host_linker_wrapper() { prepare_impl c "$@"; }
prepare_cargo_host_cxx_wrapper() { prepare_impl cxx "$@"; }
provided_prepare_c() { if [[ "$scenario" = alias-contract ]]; then trace ALIAS_PREPARE "$#"; fi; prepare_impl c "$@"; }
provided_prepare_cxx() { if [[ "$scenario" = alias-contract ]]; then trace ALIAS_PREPARE "$#"; fi; prepare_impl cxx "$@"; }
export_impl() {
 trace export "$@" "$cargo_host_cc" "$cargo_host_linker" "$cargo_host_cxx" "$cargo_host_cxx_wrapper"
 if [[ "$caller" = setup ]]; then [[ "$#" -eq 5 ]] || return 95; else [[ "$#" -eq 4 ]] || return 96; fi
 if [[ "$scenario" = "$3-export-failed" ]]; then return 17; fi
 builtin printf -v "BINDING_$3" '%s' "$*"
}
export_cargo_compiler_binding() { export_impl "$@"; }
provided_export() { if [[ "$scenario" = alias-contract ]]; then trace ALIAS_PUBLISH "$#"; fi; export_impl "$@"; }
install_prefix_aliases() {
 alias prepare_cargo_host_linker_wrapper='provided_prepare_c "$@"' prepare_cargo_host_cxx_wrapper='provided_prepare_cxx "$@"' export_cargo_compiler_binding='provided_export "$@"'
}
if [[ "$aliases" = prefix ]]; then install_prefix_aliases; fi
source "$work/functions"
if [[ "$aliases" = late-prefix ]]; then install_prefix_aliases; fi
_gst_prepare_target_cargo_env() { trace target; }
if [[ "$scenario" = delegate && "$caller" = standalone ]]; then prepare_host_cargo_toolchain_env() { trace delegate; }; fi
BINDING_c=seed_c BINDING_cxx=seed_cxx
invoke() {
 local cargo_host_cc='' cargo_host_linker='' cargo_host_cxx='' cargo_host_cxx_wrapper=''
 if [[ "$caller" = setup ]]; then prepare_host_cargo_toolchain_env; else _gst_rs_host_cargo_config; fi
}
snapshot() { declare -p BINDING_c BINDING_cxx > "$work/state"; }
trap snapshot EXIT
if [[ "$strict" = strict ]]; then set -e; fi
if [[ "$inherit" = inherited ]]; then shopt -s inherit_errexit; fi
if [[ "$context" = conditional ]]; then
 if invoke; then status=0; else status=$?; fi
else invoke; status=$?; fi
printf 'TAIL:%s\n' "$status"
"""


def extract(leaf, names):
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; t_source_functions "$2" "${@:3}" || exit; declare -f "${@:3}"',
            "_",
            str(TESTS / "test-harness.sh"),
            str(SCRIPTS / leaf),
            *names,
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=5,
    ).stdout


def definitions():
    result = {}
    helper = extract(
        "01-core/compiler-resolution.sh", ["prepare_and_publish_host_cargo_compiler"]
    )
    for caller, leaf, prefix, entry in (
        ("setup", "setup-gstreamer.sh", "_gsh", "prepare_host_cargo_toolchain_env"),
        ("standalone", "build-gst-plugins-rs.sh", "_gsrh", "_gst_rs_host_cargo_config"),
    ):
        names = [
            prefix + "_" + action + "_" + language
            for language in ("c", "cxx")
            for action in ("prepare", "publish")
        ]
        body = extract("03-media/build/gstreamer/common/" + leaf, [*names, entry])
        result[caller, "healthy"] = body + "\n" + helper
        result[caller, "cold"] = body
    return result


def capture(body, row):
    with tempfile.TemporaryDirectory(prefix="ant host Cargo ") as directory:
        work = pathlib.Path(directory)
        (work / "functions").write_text(body)
        (work / "trace").write_text("")
        process = subprocess.run(
            ["bash", "-c", WORKER, "_", directory, *row],
            capture_output=True,
            check=False,
            timeout=5,
        )

        def clean(data):
            return re.sub(
                r": line \d+:",
                ": line [LINE]:",
                data.decode().replace(directory, "[WORK]"),
            )

        return {
            "rc": process.returncode,
            "out": clean(process.stdout),
            "err": clean(process.stderr),
            "trace": clean((work / "trace").read_bytes()),
            "state": clean((work / "state").read_bytes()),
        }


def cold_contract(parts):
    checks = 0
    for caller, active, context, strict, scenario in itertools.product(
        ("setup", "standalone"),
        ("cross", "native"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
        ("success", "delegate"),
    ):
        bad = active == "cross" and not (
            caller == "standalone" and scenario == "delegate"
        )
        stopped = bad and context == "direct" and strict == "strict"
        row = (caller, scenario, active, context, strict, "none", "default")
        actual = capture(parts[caller, "cold"], row)
        expected = {
            "rc": int(stopped),
            "out": "" if stopped else "TAIL:" + ("1" if bad else "0") + "\n",
            "err": "ERROR: compiler-resolution.sh lacks prepare_and_publish_host_cargo_compiler\n"
            if bad
            else "",
            "trace": "<delegate>\n"
            if caller == "standalone" and scenario == "delegate"
            else "",
        }
        for field, wanted in expected.items():
            assert actual[field] == wanted, (row, field, wanted, actual[field])
            checks += 1
    return checks


def alias_contract(parts):
    checks = 0
    for caller, phase in itertools.product(
        ("setup", "standalone"), ("prefix", "late-prefix")
    ):
        row = (caller, "alias-contract", "cross", "direct", "strict", phase, "default")
        actual = capture(parts[caller, "healthy"], row)
        count = 2 if phase == "prefix" else 0
        arity = 5 if caller == "setup" else 4
        assert actual["rc"] == 0, (row, actual)
        assert actual["out"] == "TAIL:0\n", (row, actual)
        assert actual["err"] == "", (row, actual)
        assert actual["trace"].count("<ALIAS_PREPARE><1>\n") == count, (row, actual)
        assert actual["trace"].count(f"<ALIAS_PUBLISH><{arity}>\n") == count, (
            row,
            actual,
        )
        checks += 5
    return checks


def main():
    parts = definitions()
    frozen = json.loads((TESTS / "host-cargo-preparation-receipts.json").read_text())
    assert len(frozen["cases"]) == 960, "all original scenarios must remain covered"
    checks = 1
    for entry in frozen["cases"]:
        actual = capture(parts[entry["case"][0], "healthy"], entry["case"])
        for field, wanted in entry["receipt"].items():
            if field != "rc":
                wanted = frozen["strings"][wanted]
            assert actual[field] == wanted, (
                entry["case"],
                field,
                wanted,
                actual[field],
            )
            checks += 1
    checks += cold_contract(parts)
    checks += alias_contract(parts)
    print(
        f"PASS: 960 original host receipts, 32 cold cases, 4 literal-alias cases; {checks} assertions"
    )


if __name__ == "__main__":
    main()
