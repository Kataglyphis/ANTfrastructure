"""Actual provider phases and missing exports run offline with literal flags, private cross files and no builds."""

import itertools
import pathlib
import subprocess
import sys
import tempfile

from meson_dispatch_tests import function

SCRIPTS = pathlib.Path(sys.argv[1]).resolve()
WORKER = r"""
set -eu
shopt -s expand_aliases
root="$1" family="$2" phase="$3" missing="$4" prefix_alias="${5:-none}" context="${6:-empty}"
CALLER_ARGS=()
case "$context" in pair) CALLER_ARGS=("caller value" "");; raw) CALLER_ARGS=($'line\nvalue' '*?[literal]' '-n' "");; esac
EXPECTED_ARGS=("${CALLER_ARGS[@]}")
if [[ "$family" = default ]]; then
 EXPECTED_ARGS=(MESON_FLAGS)
 case "$context" in pair) EXPECTED_ARGS+=("");; raw) EXPECTED_ARGS+=(provided_after);; esac
fi
validate_alias_args() {
 if [[ "$prefix_alias" = yes ]]; then
  [[ "$#" -eq $((${#EXPECTED_ARGS[@]} + 1)) ]] || return 91
  for expected_arg in "${EXPECTED_ARGS[@]}"; do [[ "$1" = "$expected_arg" ]] || return 92; shift; done
 fi
 [[ "$#" -eq 1 ]] || return 93
 [[ "$1" = MESON_FLAGS || "$1" = MESON_SETUP_ARGS ]] || return 94
}
provided_after() { :; }
append_flag() { local -n _fixture_flags="$1"; _fixture_flags+=("$2"); }
append_meson_cross_flags() { append_flag "$1" BASE_CROSS; if [[ "$phase" = late ]]; then
  if [[ "$prefix_alias" = yes ]]; then alias append_meson_native_flags='provided_native "$@"'; else alias append_meson_native_flags=provided_native; fi
 fi; }
append_meson_native_flags() { append_flag "$1" BASE_NATIVE; }
provided_cross() { validate_alias_args "$@"; append_flag "${@: -1}" ALIAS_CROSS; }
provided_native() { validate_alias_args "$@"; append_flag "${@: -1}" ALIAS_NATIVE; }
if [[ "$phase" = core ]]; then
 if [[ "$prefix_alias" = yes ]]; then alias append_meson_cross_flags='provided_cross "$@"' append_meson_native_flags='provided_native "$@"'; else alias append_meson_cross_flags=provided_cross append_meson_native_flags=provided_native; fi
fi
source "$root/owner"
if [[ "$phase" = early ]]; then
 if [[ "$prefix_alias" = yes ]]; then alias append_meson_cross_flags='provided_cross "$@"' append_meson_native_flags='provided_native "$@"'; else alias append_meson_cross_flags=provided_cross append_meson_native_flags=provided_native; fi
fi
if [[ "$missing" != none ]]; then unset -f "$missing"; fi
MESON_FLAGS=() MESON_SETUP_ARGS=()
MESON_CROSS_FILE="$root/cross.ini"
printf 'pkg_config_libdir = old\nkeep = yes\n' > "$MESON_CROSS_FILE"
media_prepare_cross_compilers() { :; }
_gst_monorepo_wrap_flags() { :; }
dump_debug_info() { printf DEBUG; }
set -- "${CALLER_ARGS[@]}"
if [[ "$family" = default ]]; then
 append_available_meson_toolchain_flags "${EXPECTED_ARGS[@]}"
else
 source "$root/caller"
 if [[ "$family" = gst ]]; then _gst_monorepo_cross_flags; fi
fi
if [[ "$family" = camera ]]; then printf '<%s>\n' "${MESON_SETUP_ARGS[@]}"; else printf '<%s>\n' "${MESON_FLAGS[@]}"; fi
if [[ "$family" = gst ]]; then cat "$MESON_CROSS_FILE"; fi
"""


def source_parts():
    common = SCRIPTS / "01-core/common.sh"
    owner = "\n".join(
        function(common, name)
        for name in (
            "_common_meson_cross",
            "_common_meson_native",
            "append_available_meson_provider",
            "append_available_meson_toolchain_flags",
        )
    )
    gst = SCRIPTS / "03-media/build/gstreamer/common/build-gstreamer-monorepo.sh"
    caller = "\n".join(
        function(gst, name)
        for name in (
            "_gst_monorepo_meson_cross",
            "_gst_monorepo_meson_native",
            "_gst_monorepo_cross_pkgconfig",
            "_gst_monorepo_cross_flags",
        )
    ).replace("/tmp/gstreamer-debug-info.log", '"${root}/debug.log"')
    camera = (SCRIPTS / "03-media/build/libcamera/build-libcamera.sh").read_text()
    end = camera.index('\n\nif ! "${UV_RUN_PREFIX[@]}" meson setup')
    start = camera.rfind("\nfi\n\n", 0, end) + len("\nfi\n\n")
    return owner, {"gst": caller, "camera": camera[start:end], "default": ""}


EXPECTED_FLAGS = {
    ("gst", "early"): "<ALIAS_CROSS>\n<ALIAS_NATIVE>\nkeep = yes\n",
    ("gst", "late"): "<BASE_CROSS>\n<BASE_NATIVE>\nkeep = yes\n",
    ("gst", "core"): "<ALIAS_CROSS>\n<ALIAS_NATIVE>\nkeep = yes\n",
    ("camera", "early"): "<ALIAS_CROSS>\n<ALIAS_NATIVE>\n",
    ("camera", "late"): "<BASE_CROSS>\n<ALIAS_NATIVE>\n",
    ("camera", "core"): "<ALIAS_CROSS>\n<ALIAS_NATIVE>\n",
    ("default", "early"): "<BASE_CROSS>\n<BASE_NATIVE>\n",
    ("default", "late"): "<BASE_CROSS>\n<BASE_NATIVE>\n",
    ("default", "core"): "<ALIAS_CROSS>\n<ALIAS_NATIVE>\n",
}


def expected_receipt(family, phase, missing):
    if missing != "none" and (
        family == "gst" or missing == "append_available_meson_provider"
    ):
        api = (
            "append_available_meson_provider"
            if family == "camera"
            else "append_available_meson_toolchain_flags"
        )
        return 1, "", f"ERROR: common.sh does not provide {api}\n"
    return 0, EXPECTED_FLAGS[family, phase], ""


def main():
    owner, callers = source_parts()
    checks = 0
    cases = [
        (family, phase, missing, "none", "empty")
        for family, phase, missing in itertools.product(
            ("gst", "camera", "default"),
            ("early", "late", "core"),
            (
                "none",
                "append_available_meson_provider",
                "append_available_meson_toolchain_flags",
            ),
        )
        if family != "default" or missing == "none"
    ]
    cases.extend(
        (family, phase, "none", "yes", context)
        for family, phase, context in itertools.product(
            ("gst", "camera", "default"),
            ("early", "late", "core"),
            ("empty", "pair", "raw"),
        )
        if family != "gst" or context == "empty"
    )
    for family, phase, missing, prefix_alias, context in cases:
        with tempfile.TemporaryDirectory(prefix="ant meson alias ") as directory:
            root = pathlib.Path(directory)
            (root / "owner").write_text(owner)
            (root / "caller").write_text(callers[family])
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    WORKER,
                    "_",
                    directory,
                    family,
                    phase,
                    missing,
                    prefix_alias,
                    context,
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
            expected = expected_receipt(family, phase, missing)
            actual = (result.returncode, result.stdout, result.stderr)
            for index in range(3):
                assert actual[index] == expected[index], (
                    family,
                    phase,
                    missing,
                    expected,
                    actual,
                )
                checks += 1
    print(f"PASS: 42 binding/cold/prefix cases, {checks} assertions")


if __name__ == "__main__":
    main()
