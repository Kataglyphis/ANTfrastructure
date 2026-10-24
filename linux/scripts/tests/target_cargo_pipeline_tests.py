"""Existing captures run with offline SDK hooks; no Cargo build, compiler or package operation is executed."""

import itertools
import json
import pathlib
import re
import subprocess
import sys
import tempfile

from host_cargo_preparation_tests import extract

SCRIPTS = pathlib.Path(sys.argv[1]).resolve()
TESTS = pathlib.Path(__file__).parent


WORKER = r"""
set -uo pipefail
work="$1" role="$2" target_mode="$3" present="$4" scenario="$5" context="$6" strict="$7" inherit="$8" aliases="$9"
shopt -s expand_aliases
source "$work/core"
trace() { builtin printf '<%s>' "$@" >> "$work/trace"; builtin printf '\n' >> "$work/trace"; }
command() {
 if [[ "$1" = -v && "$2" = resolve_cross_cc_cxx_for_arch ]]; then
  builtin printf 'lookup output\n'; builtin printf 'lookup diagnostic\n' >&2
  trace AVAILABLE
  if [[ "$scenario" = availability-installs-alias ]]; then install_prefix_aliases; fi
  if [[ "$scenario" = availability-mutates ]]; then rust_target=mutated-target; target_rust_env=MUTATED_ENV; fi
  if [[ "$scenario" = readonly-cc ]]; then
   if [[ "$role" = rice ]]; then readonly rice_cross_cc=readonly-seed; else readonly target_cc=readonly-seed; fi
  fi
 fi
 builtin command "$@"
}
cross_target_upper_rust() { [[ "$target_mode" != empty ]] || return 0; if [[ "$target_mode" = raw ]]; then builtin printf 'TARGET space\n*[literal]'; else builtin printf TARGET_ENV; fi; }
cross_target_lower_rust() { [[ "$target_mode" != empty ]] || return 0; if [[ "$target_mode" = raw ]]; then builtin printf 'target space\n*[literal]'; else builtin printf target_env; fi; }
cross_target_arch() { trace ARCH; builtin printf 'target arch'; }
resolve_impl() {
 local _audit_n
 IFS= read -r _audit_n < "$work/count"
 _audit_n=$((_audit_n+1)); builtin printf '%s\n' "$_audit_n" > "$work/count"
 trace RESOLVE "$#" "$@"
 [[ "$#" -eq 1 ]] || return 94
 if [[ "$scenario" = resolve-inner-false ]]; then false; trace RESOLVE_AFTER_FALSE; fi
 export CC="child cc $_audit_n" CXX="child cxx $_audit_n"
 CHILD_STATE=changed
 builtin printf 'resolver-noise\n'; builtin printf 'resolver-error\n' >&2
 [[ "$scenario" != resolve-fail ]] || return 7
}
provided_resolver() { trace ALIAS_RESOLVER "$#"; resolve_impl "$@"; }
if [[ "$present" = yes ]]; then resolve_cross_cc_cxx_for_arch() { resolve_impl "$@"; }; fi
provided_printf() {
 trace PRINTF "$#" "$@"
 [[ "$#" -eq 2 ]] || return 95
 if [[ "$scenario" = printf-inner-false ]]; then false; trace PRINTF_AFTER_FALSE; fi
 builtin printf "$@"
 [[ "$scenario" != printf-fail ]] || return 17
}
echo() { if [[ "$scenario" = echo-fail ]]; then trace ECHO; return 23; fi; builtin echo "$@"; }
export_cargo_target_linker() {
 trace PUBLISH "$#" "$@" "$CC" "$CXX" "$CHILD_STATE"
 if [[ "$role" = gst ]]; then declare -p _tgt_arch >> "$work/trace"; [[ "$#" -eq 4 ]] || return 96; else [[ "$#" -eq 3 ]] || return 97; fi
 BINDING="$*"; TARGET_ARCH=published-arch
 [[ "$scenario" != publish-fail ]] || return 19
}
provided_export() { trace ALIAS_PUBLISH "$#"; export_cargo_target_linker "$@"; }
provided_command() { trace ALIAS_COMMAND "$#"; [[ "$#" -eq 2 ]] || return 98; command "$@"; }
install_prefix_aliases() {
 alias command='provided_command "$@"' export_cargo_target_linker='provided_export "$@"'
 alias printf='provided_printf "$@"'
 if [[ "$present" = yes ]]; then alias resolve_cross_cc_cxx_for_arch='provided_resolver "$@"'; fi
}
if [[ "$aliases" = prefix ]]; then install_prefix_aliases; fi
source "$work/functions"
TARGET_ARCH=original-arch TARGETARCH=secondary-arch CC=parent-cc CXX=parent-cxx CHILD_STATE=parent BINDING=seed
rust_target=aarch64-unknown-linux-gnu
[[ "$target_mode" != empty ]] || rust_target=''
if [[ "$target_mode" = raw ]]; then rust_target=$'arch space\n*[literal]-unknown-linux-gnu'; fi
rice_cross_cc=prior-cc rice_rust_env=prior-env rice_rust_lower=prior-lower
if [[ "$scenario" = arch-scope ]]; then _tgt_arch=parent-arch; fi
snapshot() { declare -p TARGET_ARCH CC CXX CHILD_STATE BINDING rice_cross_cc rice_rust_env rice_rust_lower > "$work/state"; if [[ "$scenario" = arch-scope ]]; then declare -p _tgt_arch >> "$work/state"; fi; }
trap snapshot EXIT
operation() {
 if [[ "$role" = field-probe ]]; then
  _field_resolve() { trace FIELD_RESOLVE; export CC=field-child CXX=field-cxx; builtin printf 'resolver noise'; }
  _field_emit() { trace FIELD_EMIT; builtin printf '%s' "$1"; }
  if _field_result="$(cargo_resolved_compiler_field BAD_FIELD _field_resolve _field_emit)"; then _field_status=0; else _field_status=$?; fi
  builtin printf 'FIELD_RESULT:%s:<%s>\n' "$_field_status" "$_field_result"
 elif [[ "$role" = gst ]]; then _gst_prepare_target_cargo_env; else source "$work/rice"; fi
 builtin printf 'OPERATION_TAIL\n'
}
if [[ "$strict" = strict ]]; then set -e; fi
if [[ "$inherit" = inherited ]]; then shopt -s inherit_errexit; fi
if [[ "$context" = conditional ]]; then
 if operation; then status=0; else status=$?; fi
else operation; status=$?; fi
builtin printf 'TAIL:%s\n' "$status"
"""


def definitions():
    rust = extract("01-core/cross-env.sh", ["cross_collect_target_rust_env"])
    helpers = {
        name: extract("01-core/compiler-resolution.sh", [name])
        for name in (
            "cargo_target_pipeline",
            "cargo_resolved_compiler_field",
        )
    }
    gst = extract(
        "03-media/build/gstreamer/common/setup-gstreamer.sh",
        [
            "_gst_target_resolver_available",
            "_gst_target_publish",
            "_gst_target_prepare_publish",
            "_gst_prepare_target_cargo_env",
        ],
    )
    rice = (
        SCRIPTS / "03-media/build/gstreamer/common/install-rice-proto.sh"
    ).read_text()
    start = rice.index(
        "# Without a target linker cargo links the cdylib with the host cc;"
    )
    end = rice.index("\n\n  # openssl-sys", start)
    return rust, helpers, gst, rice[start:end] + "\nbuiltin printf 'SOURCE_TAIL\\n'\n"


def capture(parts, row, missing=None, observe_return=False):
    rust, helpers, gst, rice = parts
    body = (
        WORKER.replace(" builtin printf 'OPERATION_TAIL\\n'\n", "")
        if missing or observe_return
        else WORKER
    )
    with tempfile.TemporaryDirectory(prefix="ant target Cargo ") as directory:
        work = pathlib.Path(directory)
        (work / "core").write_text(
            rust
            + "\n"
            + "\n".join(value for key, value in helpers.items() if key != missing)
        )
        (work / "functions").write_text(gst if row[0] == "gst" else "")
        (work / "rice").write_text(rice if row[0] == "rice" else "")
        (work / "trace").write_text("")
        (work / "count").write_text("0\n")
        process = subprocess.run(
            ["bash", "-c", body, "_", directory, *row],
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
    for role, target, context, strict, missing in itertools.product(
        ("gst", "rice"),
        ("nonempty", "empty"),
        ("direct", "conditional"),
        ("relaxed", "strict"),
        ("cargo_target_pipeline", "cargo_resolved_compiler_field"),
    ):
        row = (role, target, "yes", "success", context, strict, "default", "none")
        actual = capture(parts, row, missing)
        stopped = role == "rice" or (context == "direct" and strict == "strict")
        expected = {
            "rc": int(stopped),
            "out": "" if stopped else "TAIL:1\n",
            "err": "ERROR: compiler-resolution.sh lacks target cargo pipeline exports\n",
            "trace": "",
        }
        for field, wanted in expected.items():
            assert actual[field] == wanted, (row, missing, field, wanted, actual[field])
            checks += 1
    return checks


def result_contract(parts):
    checks = 0
    for context, strict, aliases in itertools.product(
        ("direct", "conditional"), ("relaxed", "strict"), ("none", "prefix")
    ):
        row = (
            "gst",
            "nonempty",
            "yes",
            "echo-fail",
            context,
            strict,
            "default",
            aliases,
        )
        actual = capture(parts, row, observe_return=True)
        stopped = context == "direct" and strict == "strict"
        assert actual["rc"] == (23 if stopped else 0), (row, actual)
        assert actual["out"] == ("" if stopped else "TAIL:23\n"), (row, actual)
        assert actual["err"] == "", (row, actual)
        assert actual["trace"].count("<ECHO>\n") == 1, (row, actual)
        checks += 4
    row = (
        "field-probe",
        "nonempty",
        "yes",
        "success",
        "conditional",
        "strict",
        "default",
        "none",
    )
    actual = capture(parts, row, observe_return=True)
    expected = {
        "rc": 0,
        "out": "FIELD_RESULT:2:<>\nTAIL:0\n",
        "err": "",
        "trace": "<FIELD_RESOLVE>\n",
    }
    for field, wanted in expected.items():
        assert actual[field] == wanted, (field, wanted, actual[field])
        checks += 1
    return checks


def arch_scope_contract(parts):
    checks = 0
    for context, strict, aliases in itertools.product(
        ("direct", "conditional"), ("relaxed", "strict"), ("none", "prefix")
    ):
        row = (
            "gst",
            "nonempty",
            "yes",
            "arch-scope",
            context,
            strict,
            "default",
            aliases,
        )
        actual = capture(parts, row)
        assert actual["rc"] == 0, (row, actual)
        assert actual["state"].endswith('declare -- _tgt_arch="parent-arch"\n'), (
            row,
            actual,
        )
        checks += 2
    return checks


def owner_export_contract():
    process = subprocess.run(
        [
            "bash",
            "-eu",
            "-c",
            'unset -f cargo_target_pipeline cargo_resolved_compiler_field; unset _COMPILER_RESOLUTION_SH_LOADED _PLATFORM_SH_LOADED _CROSS_GCC_LOADED; source "$1"; declare -F cargo_target_pipeline cargo_resolved_compiler_field >/dev/null; printf "owner-ready\\n"',
            "_",
            str(SCRIPTS / "01-core/compiler-resolution.sh"),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    assert process.returncode == 0, process
    assert process.stdout == "owner-ready\n", process
    assert process.stderr == "", process
    return 3


def main():
    parts = definitions()
    frozen = json.loads((TESTS / "target-cargo-pipeline-receipts.json").read_text())
    assert len(frozen["cases"]) == 1728, "every independent original case must remain"
    checks = 1
    for entry in frozen["cases"]:
        row = tuple(frozen["strings"][index] for index in entry["case"])
        actual = capture(parts, row)
        for field, wanted in entry["receipt"].items():
            if field != "rc":
                wanted = frozen["strings"][wanted]
            assert actual[field] == wanted, (row, field, wanted, actual[field])
            checks += 1
    checks += cold_contract(parts)
    checks += result_contract(parts)
    checks += arch_scope_contract(parts)
    checks += owner_export_contract()
    print(
        f"PASS: 1728 original target receipts, 32 cold cases, 9 result controls, 8 architecture-scope controls; {checks} assertions"
    )


if __name__ == "__main__":
    main()
