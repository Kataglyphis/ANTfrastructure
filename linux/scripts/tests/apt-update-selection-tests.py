"""Empty PATH blocks unqualified tools; absolute tools and real apt or SDK operations are outside fixture coverage."""

import itertools
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import TypedDict

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = (
    Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else ROOT / "linux/scripts"
)
APT = (SCRIPTS / "01-core/cross-apt.sh").read_text()
GST = (SCRIPTS / "03-media/build/gstreamer/common/pre-setup.sh").read_text()
MARKER = "# ANT_APT_UPDATE_SOURCE_API=1\n"
GUARD = r"""
PATH=/nonexistent-ant-fixture-bin
export PATH
_APT_STUB_CALLS=0
_apt_guard_failure() { printf 'FORBIDDEN:' >> "$GUARD_LOG"; printf '<%s>' "$@" >> "$GUARD_LOG"; printf '\n' >> "$GUARD_LOG"; exit 97; }
_apt_guard_exit() {
 local _agt_status="$1" _agt_line
 while IFS= read -r _agt_line; do
  case "$_agt_line" in FORBIDDEN:*) exit 97;; esac
 done < "$GUARD_LOG"
 exit "$_agt_status"
}
trap '_apt_guard_exit "$?"' EXIT
command_not_found_handle() { _apt_guard_failure "$@"; }
apt-get() { printf 'STUB:apt-get:' >> "$GUARD_LOG"; printf '<%s>' "$@" >> "$GUARD_LOG"; printf '\n' >> "$GUARD_LOG"; _APT_STUB_CALLS=$((_APT_STUB_CALLS + 1)); return 0; }
dirname() { [ "$#" = 1 ] || _apt_guard_failure dirname "$@"; case "$1" in */*) printf '%s\n' "${1%/*}";; *) printf '.\n';; esac; }
"""
FUNCTION_WORKER = r"""
set -uo pipefail
shopt -s expand_aliases
trace() { printf '<%s>' "$@" >> "$TRACE"; printf '\n' >> "$TRACE"; }
lookup() { trace lookup "$@"; LOOKUP_COUNT=$((LOOKUP_COUNT + 1)); builtin command -v cross_apt_update; }
cross_call() { trace cross "$@"; declare -p extra_args >> "$TRACE"; _CROSS_ENV_APT_UPDATED=1; printf 'CROSS OUT\n'; printf 'CROSS ERR\n' >&2; return "$RESULT"; }
apt_call() { trace apt "$@"; declare -p extra_args >> "$TRACE"; _CROSS_ENV_APT_UPDATED=system; printf 'APT OUT\n'; printf 'APT ERR\n' >&2; return "$RESULT"; }
cross_apt_update() { cross_call function "$@"; }
apt-get() { apt_call function "$@"; }
command() { lookup plain "$@"; }
lookup_a() { lookup a "$@"; }; lookup_b() { lookup b "$@"; }
cross_a() { cross_call a "$@"; }; cross_b() { cross_call b "$@"; }
apt_a() { apt_call a "$@"; }; apt_b() { apt_call b "$@"; }
LOOKUP_COUNT=0 _CROSS_ENV_APT_UPDATED=seed
extra_args=(global 'global [*]')
"""
PHYSICAL_WORKER = r"""
set -u
_CROSS_ENV_APT_UPDATED=seed SDK_PROVIDER=seed
extra_args=(global)
cross_mode_requested() { printf 'MODE:false\n' >> "$GUARD_LOG"; return 1; }
cross_apt_update() { SDK_PROVIDER=called; printf 'PROVIDED\n' >> "$GUARD_LOG"; return 0; }
provided_cross() { [ "$#" = 0 ] || return 94; SDK_PROVIDER=called; printf 'PROVIDED\n' >> "$GUARD_LOG"; }
SDK_BEFORE="$(declare -f cross_apt_update)"
snapshot_exit() {
 local _ase_status="$1"
 {
  printf 'STATE:%s:%s:%s\n' "${_CROSS_APT_LOADED-unset}" "$_CROSS_ENV_APT_UPDATED" "$SDK_PROVIDER"
  declare -p extra_args
  if [ "$SDK_BEFORE" = "$(declare -f cross_apt_update)" ]; then printf 'PROVIDER_SAME:yes\n'; else printf 'PROVIDER_SAME:no\n'; fi
 } > "$SNAPSHOT"
 _apt_guard_exit "$_ase_status"
}
trap 'snapshot_exit "$?"' EXIT
set -- 'outer [*]' ''
"""
ENTRY = {"apt": "apt_update_smart", "gst": "_apt_refresh"}
ADAPTERS = {
    "apt": (
        "_apt_smart_cross_available",
        "_apt_smart_cross_update",
        "_apt_smart_system_update",
    ),
    "gst": (
        "_gst_cross_apt_available",
        "_gst_cross_apt_update",
        "_gst_system_apt_update",
    ),
}

type FunctionCase = tuple[str, Sequence[str], Sequence[str], str, bool, int, bool, str]


class BashResult(TypedDict):
    rc: int
    out: str
    err: str
    guard: str


class FunctionResult(TypedDict):
    rc: int
    out: str
    err: str
    trace: str


class PhysicalResult(TypedDict):
    rc: int
    out: str
    err: str
    guard: str
    state: str


def function(text: str, name: str) -> str:
    match = re.search(
        r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", text, re.MULTILINE | re.DOTALL
    )
    if match is None:
        raise ValueError(f"Bash function is missing: {name}")
    return match.group() + "\n"


def invoke_bash(work: Path, body: str) -> BashResult:
    guard = work / "guard"
    guard.write_text("")
    code = "GUARD_LOG=" + shlex.quote(str(guard)) + "\n" + GUARD + "\n" + body
    env = dict(os.environ)
    env.pop("BASH_ENV", None)
    result = subprocess.run(
        ["/bin/bash", "-c", code],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    return {
        "rc": result.returncode,
        "out": result.stdout,
        "err": result.stderr.replace(str(work), "WORK"),
        "guard": guard.read_text(),
    }


def require_isolation(result: BashResult) -> None:
    assert "FORBIDDEN:" not in result["guard"], result


def private_tree(work: Path, owner: str = APT) -> tuple[Path, Path]:
    core = work / "scripts/01-core"
    core.mkdir(parents=True)
    (core / "cross-apt.sh").write_text(owner)
    directory = work / "scripts/03-media/build/gstreamer/common"
    directory.mkdir(parents=True)
    (work / "apt-sources").mkdir()
    return core, directory


def function_definitions(work: Path, order: Sequence[str], aliases: bool, owner: str) -> str:
    code = ""
    for index, subject in enumerate(order):
        phase = "a" if index == 0 else "b"
        if aliases:
            code += (
                "alias command='lookup_"
                + phase
                + " \"$@\"'\nalias apt-get='apt_"
                + phase
                + ' "$@"\'\n'
            )
            if owner != "missing":
                code += "alias cross_apt_update='cross_" + phase + ' "$@"\'\n'
        text = APT if subject == "apt" else GST
        if subject == "gst":
            text = text.replace(
                "/opt/scripts/core/cross-apt.sh",
                shlex.quote(str(work / "installed/cross-apt.sh")),
            )
        names = [n for n in ADAPTERS[subject] if n + "() {" in text] + [ENTRY[subject]]
        module = work / (subject + ".sh")
        module.write_text("".join(function(text, name) for name in names))
        code += "source " + shlex.quote(str(module)) + "\n"
    return code


def function_case(case: FunctionCase) -> FunctionResult:
    subject, args, order, provider, aliases, status, strict, context = case
    with tempfile.TemporaryDirectory(prefix="ant apt function ") as directory:
        work = Path(directory)
        _, gst_directory = private_tree(work)
        trace = work / "trace"
        trace.write_text("")
        code = (
            FUNCTION_WORKER
            + "TRACE="
            + shlex.quote(str(trace))
            + "\nRESULT="
            + str(status)
            + "\n"
        )
        code += (
            "_PRE_SETUP_DIR="
            + shlex.quote(str(gst_directory))
            + "\n_CROSS_APT_SOURCES_DIR="
            + shlex.quote(str(work / "apt-sources"))
            + "\n_CROSS_APT_LOADED=sentinel\n"
        )
        if provider == "missing":
            code += "unset -f cross_apt_update\n"
        if "apt_update_select() {" in APT:
            code += function(APT, "apt_update_select")
        code += function_definitions(work, order, aliases, provider)
        code += "set -e\n" if strict else "set +e\n"
        call = ENTRY[subject] + " " + shlex.join(args)
        code += (
            "if " + call + "; then status=0; else status=$?; fi\n"
            if context == "conditional"
            else call + "\nstatus=$?\n"
        )
        code += 'printf "STATUS:%s UPDATED:%s LOOKUPS:%s\\n" "$status" "$_CROSS_ENV_APT_UPDATED" "$LOOKUP_COUNT"\ndeclare -p extra_args\n'
        result = invoke_bash(work, code)
        require_isolation(result)
        return {
            "rc": result["rc"],
            "out": result["out"],
            "err": result["err"],
            "trace": trace.read_text(),
        }


def physical_files(
    work: Path, consumer: str, owner: str | None, layout: str, sdk_owner: str | None = None
) -> Path:
    core, gst_directory = private_tree(work)
    target = core / "cross-apt.sh"
    target.unlink()
    installed = work / "installed/cross-apt.sh"
    installed.parent.mkdir()
    if owner is not None:
        (
            installed if layout == "installed" and consumer == "gst" else target
        ).write_text(owner)
    if sdk_owner is not None:
        installed.write_text(sdk_owner)
    if consumer != "gst":
        return target
    common = work / "scripts/03-media/core/common.sh"
    common.parent.mkdir(parents=True, exist_ok=True)
    common.write_text(
        "media_common_init() { :; }\nmedia_load_vulkan_toolchain() { :; }\n"
    )
    prefix = GST[: GST.index("\n_apt_refresh\n") + len("\n_apt_refresh\n")]
    prefix = prefix.replace(
        "/opt/scripts/core/cross-apt.sh", shlex.quote(str(installed))
    )
    module = gst_directory / "pre-setup.sh"
    module.write_text(prefix)
    return module


def physical_setup(
    work: Path, consumer: str, strict: bool, stale: bool, readonly: bool,
    loaded: str | None, alias: bool,
) -> str:
    code = ("set -e\n" if strict else "set +e\n") + PHYSICAL_WORKER
    code += (
        "_CROSS_APT_SOURCES_DIR="
        + shlex.quote(str(work / "apt-sources"))
        + "\nSNAPSHOT="
        + shlex.quote(str(work / "state"))
        + "\n"
    )
    if consumer != "normal":
        code += "readonly -f cross_apt_update\n"
        if loaded is not None:
            code += "_CROSS_APT_LOADED=" + shlex.quote(loaded) + "\n"
    if stale:
        code += "apt_update_select() { printf STALE; return 0; }\n"
    if readonly:
        code += "readonly -f apt_update_select\n"
    if alias:
        code += (
            "shopt -s expand_aliases\nalias cross_apt_update='provided_cross \"$@\"'\n"
        )
    return code


def physical_case(
    consumer: str,
    owner: str | None = APT,
    context: str = "conditional",
    strict: bool = True,
    stale: bool = False,
    layout: str = "repo",
    readonly: bool = False,
    loaded: str | None = "seed",
    alias: bool = False,
    sdk_owner: str | None = None,
) -> PhysicalResult:
    with tempfile.TemporaryDirectory(prefix="ant apt physical ") as directory:
        work = Path(directory)
        module = physical_files(work, consumer, owner, layout, sdk_owner)
        code = physical_setup(work, consumer, strict, stale, readonly, loaded, alias)
        call = (
            "source "
            + shlex.quote(str(module))
            + (" --ant-source-apt-update-only" if consumer == "helper" else "")
        )
        code += (
            "if " + call + "; then src=0; else src=$?; fi\n"
            if context == "conditional"
            else call + "\nsrc=$?\n"
        )
        code += 'printf "SOURCE:%s STUBS:%s\\n" "$src" "$_APT_STUB_CALLS"\nprintf "ARGS:"; printf "<%s>" "$@"; printf "\\n"\n'
        if consumer == "normal":
            code += 'if [ "$src" = 0 ]; then if apt_update_smart; then fn=0; else fn=$?; fi; printf "FUNCTION:%s STUBS:%s FLAG:%s\\n" "$fn" "$_APT_STUB_CALLS" "${_CROSS_ENV_APT_UPDATED:-}"; fi\n'
        if consumer == "helper":
            code += 'if declare -F apt_update_select >/dev/null; then printf "API:1\\n"; else printf "API:0\\n"; fi\n'
        result = invoke_bash(work, code)
        require_isolation(result)
        state = (work / "state").read_text()
        if consumer != "normal":
            assert "PROVIDER_SAME:yes" in state, result
        return {**result, "state": state}


def cold_owners() -> dict[str, str | None]:
    helper = function(APT, "apt_update_select")
    return {
        "good": APT,
        "missing": None,
        "old-danger": "SDK_PROVIDER=corrupted\ncurl forbidden\n",
        "wrong-api": "# ANT_APT_UPDATE_SOURCE_API=2\nSDK_PROVIDER=corrupted\ncurl forbidden\n",
        "misplaced-api": "# wrong first line\n"
        + MARKER
        + "SDK_PROVIDER=corrupted\ncurl forbidden\n",
        "no-export": MARKER + ":\n",
        "owner-no-export": APT.replace(helper, ":\n", 1),
        "status23": MARKER + "return 23\n",
        "export-status23": MARKER + helper + "return 23\n",
        "parse": MARKER + "apt_update_select() {\n",
        "inner-false": MARKER + "false\n" + APT[len(MARKER) :],
    }


class AptUpdateSelectionTests(unittest.TestCase):
    def test_original_receipts(self) -> None:
        frozen = json.loads(
            Path(__file__).with_name("apt-update-selection-receipts.json").read_text()
        )
        self.assertEqual(512, len(frozen))
        for row in frozen:
            with self.subTest(case=row["case"]):
                self.assertEqual(row["receipt"], function_case(row["case"]))

    def test_defaults_and_parent_state(self) -> None:
        for subject, argument in [("apt", "<-y>"), ("gst", "")]:
            result = function_case(
                (subject, (), ("apt", "gst"), "missing", False, 0, True, "direct")
            )
            self.assertEqual(0, result["rc"])
            self.assertIn("<apt><function><update>" + argument + "\n", result["trace"])
            self.assertIn("STATUS:0 UPDATED:system LOOKUPS:1", result["out"])

    def test_physical_positive_owners(self) -> None:
        for consumer, context, strict in itertools.product(
            ["normal", "gst"], ["direct", "conditional"], [False, True]
        ):
            result = physical_case(consumer, context=context, strict=strict)
            self.assertEqual(0, result["rc"])
            self.assertEqual("", result["err"])
            self.assertIn("ARGS:<outer [*]><>\n", result["out"])
            if consumer == "normal":
                self.assertEqual(
                    "MODE:false\nSTUB:apt-get:<update><-y>\n", result["guard"]
                )
                self.assertIn("FUNCTION:0 STUBS:1 FLAG:1", result["out"])
            else:
                self.assertEqual("PROVIDED\n", result["guard"])
                self.assertIn("STATE:seed:seed:called", result["state"])

    def test_helper_mode_is_scope_neutral(self) -> None:
        for context, strict, loaded in itertools.product(
            ["direct", "conditional"], [False, True], [None, "seed"]
        ):
            result = physical_case(
                "helper", context=context, strict=strict, loaded=loaded, stale=True
            )
            self.assertEqual(
                (0, "", ""), (result["rc"], result["err"], result["guard"])
            )
            self.assertIn("SOURCE:0", result["out"])
            self.assertIn("API:1\n", result["out"])
            self.assertIn("ARGS:<outer [*]><>\n", result["out"])
            self.assertIn(
                "STATE:" + ("unset" if loaded is None else loaded) + ":seed:seed",
                result["state"],
            )

    def test_gstreamer_mode_precedes_owner_initialization(self) -> None:
        for context, strict, alias, layout in itertools.product(
            ["direct", "conditional"],
            [False, True],
            [False, True],
            ["repo", "installed"],
        ):
            result = physical_case(
                "gst",
                context=context,
                strict=strict,
                alias=alias,
                layout=layout,
                loaded=None,
            )
            self.assertEqual(
                (0, "", "PROVIDED\n"), (result["rc"], result["err"], result["guard"])
            )
            self.assertIn("SOURCE:0 STUBS:0", result["out"])
            self.assertIn("STATE:unset:seed:called", result["state"])

    def test_repository_helper_preserves_old_sdk_provider(self) -> None:
        sdk = "SDK_PROVIDER=corrupted\ncurl forbidden\n"
        for context, strict, alias in itertools.product(
            ["direct", "conditional"], [False, True], [False, True]
        ):
            result = physical_case(
                "gst",
                context=context,
                strict=strict,
                alias=alias,
                loaded=None,
                sdk_owner=sdk,
            )
            self.assertEqual(
                (0, "", "PROVIDED\n"), (result["rc"], result["err"], result["guard"])
            )
            self.assertIn("SOURCE:0 STUBS:0", result["out"])
            self.assertIn("STATE:unset:seed:called", result["state"])

    def test_cold_owners_fail_before_update(self) -> None:
        for (name, owner), context, strict, stale, layout in itertools.product(
            cold_owners().items(),
            ["direct", "conditional"],
            [False, True],
            [False, True],
            ["repo", "installed"],
        ):
            with self.subTest(
                owner=name, context=context, strict=strict, stale=stale, layout=layout
            ):
                result = physical_case(
                    "gst",
                    owner=owner,
                    context=context,
                    strict=strict,
                    stale=stale,
                    layout=layout,
                )
                good = name == "good" or (
                    name == "inner-false" and context == "conditional"
                )
                status = (
                    23
                    if name in ["status23", "export-status23"]
                    else 2
                    if name == "parse"
                    else 1
                )
                self.assertNotIn("STALE", result["out"])
                if good:
                    self.assertEqual(
                        (0, "", "PROVIDED\n"),
                        (result["rc"], result["err"], result["guard"]),
                    )
                    self.assertIn("SOURCE:0 STUBS:0", result["out"])
                    self.assertIn("STATE:seed:seed:called", result["state"])
                else:
                    self.assertEqual((status, ""), (result["rc"], result["guard"]))
                    self.assertIn("STATE:seed:seed:seed", result["state"])
                    self.assertNotIn("SOURCE:0", result["out"])

    def test_raw_unset_failure_status(self) -> None:
        for consumer, context, strict in itertools.product(
            ["helper", "gst"], ["direct", "conditional"], [False, True]
        ):
            result = physical_case(
                consumer, context=context, strict=strict, stale=True, readonly=True
            )
            self.assertIn("readonly function", result["err"])
            self.assertEqual("", result["guard"])
            self.assertIn("STATE:seed:seed:seed", result["state"])
            if consumer == "gst" or (context == "direct" and strict):
                self.assertEqual(1, result["rc"])
            else:
                self.assertEqual(0, result["rc"])
                self.assertIn("SOURCE:1 STUBS:0", result["out"])

    def test_physical_sdk_prefix_alias(self) -> None:
        for context, layout in itertools.product(
            ["direct", "conditional"], ["repo", "installed"]
        ):
            result = physical_case("gst", context=context, layout=layout, alias=True)
            self.assertEqual(
                (0, "", "PROVIDED\n"), (result["rc"], result["err"], result["guard"])
            )
            self.assertIn("SOURCE:0 STUBS:0", result["out"])
            self.assertIn("STATE:seed:seed:called", result["state"])

    def test_source_only_guard_uses_execution_identity(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="ant apt execution identity "
        ) as directory:
            work = Path(directory)
            core, _ = private_tree(work)
            owner = core / "cross-apt.sh"
            code = (
                "BASH_ARGV0="
                + shlex.quote(str(owner))
                + "\nsource "
                + shlex.quote(str(owner))
                + " --ant-source-apt-update-only\n"
            )
            result = invoke_bash(work, code)
        self.assertEqual((1, "", ""), (result["rc"], result["out"], result["guard"]))
        self.assertEqual(
            "ERROR: --ant-source-apt-update-only must be sourced\n", result["err"]
        )

    def test_tool_boundaries_cannot_be_masked(self) -> None:
        for body in [
            "if absent_unstubbed_tool; then :; else :; fi; printf MASKED",
            "if command apt-get update; then :; else :; fi; printf MASKED",
            "sudo apt-get update",
        ]:
            with tempfile.TemporaryDirectory(prefix="ant apt boundary ") as directory:
                result = invoke_bash(Path(directory), body)
            self.assertEqual(97, result["rc"])
            self.assertIn("FORBIDDEN:", result["guard"])
            self.assertNotIn("STUB:apt-get:", result["guard"])


if __name__ == "__main__":
    unittest.main()
