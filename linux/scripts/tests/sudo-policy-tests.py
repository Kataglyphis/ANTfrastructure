"""Frozen UID inputs share a seam; extra controls retain real Bash EUID without changing oracles."""
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path
from typing import Any

WORKER = r"""
set -uo pipefail
shopt -s expand_aliases
command_impl() {
 printf 'COMMAND:%s:' "$1"; shift; printf '<%s>' "$@"; printf '\n'
 case "${!#}" in
  sudo) return "$AVAILABLE";;
  _ensure_sudo_wrapper) [ "$DELEGATE" = 1 ];;
  *) builtin command -v "${!#}";;
 esac
}
early_command() { command_impl early "$@"; }
late_command() { command_impl late "$@"; }
command() { command_impl plain "$@"; }
id_impl() { printf 'ID:%s:' "$1" >&2; shift; printf '<%s>' "$@" >&2; printf '\n' >&2; printf 1001; }
early_id() { id_impl early "$@"; }
late_id() { id_impl late "$@"; }
id() { id_impl plain "$@"; }
die_impl() {
 printf 'DIE:%s:' "$1" >&2; shift; printf '<%s>' "$@" >&2; printf '\n' >&2
 [ "$DIE_ACTION" != exit ] || exit 17
 return 7
}
early_die() { die_impl early "$@"; }
late_die() { die_impl late "$@"; }
set_aliases() {
 alias command='early_command "$@"'
 alias id='early_id "$@"'
 [ "$ORDER/$PHASE" != boot-common/between ] || alias die='early_die "$@"'
}
set_late_aliases() {
 alias command='late_command "$@"'
 alias id='late_id "$@"'
 alias die='late_die "$@"'
}
[ "$PHASE" != before ] || set_aliases
if [ "$ORDER" = common-boot ]; then
 source "$WORK/common-core/common.sh"
 [ "$PHASE" != between ] || set_aliases
 source "$WORK/toolchain/bootstrap.sh"
 source_toolchain_common_or_fallback "$WORK/toolchain"
else
 source "$WORK/toolchain/bootstrap.sh"
 source_toolchain_common_or_fallback "$WORK/toolchain"
 [ "$PHASE" != between ] || set_aliases
 source "$WORK/common-core/common.sh"
fi
[ "$PHASE" != after ] || { set_aliases; set_late_aliases; }
function die { die_impl plain "$@"; }
_ensure_sudo_wrapper() { printf 'DELEGATE:<%s>\n' "$*"; SUDO=delegated; SUDO_WRAP=delegated-wrap; return 19; }
SUDO=seed-sudo SUDO_WRAP=seed-wrap
case "$READONLY" in sudo) readonly SUDO;;wrap) readonly SUDO_WRAP;;esac
[ "$STRICT" = 0 ] && set +e || set -e
result=UNREACHED
@CALL@
boundary=$?
printf 'RESULT:%s BOUNDARY:%s SUDO:<%s> WRAP:<%s>\n' "$result" "$boundary" "$SUDO" "$SUDO_WRAP"
"""

DEPENDENCIES = ("compiler-cache-utils.sh", "load-versions-env.sh", "versions.env",
                "platform.sh", "cross-active-fallback.sh")


def populate(work: Path, scripts: Path) -> str:
    for folder in ("common-core", "01-core", "toolchain", "no-installed"):
        (work / folder).mkdir()
    for name in DEPENDENCIES:
        shutil.copyfile(scripts / "01-core" / name, work / "common-core" / name)
    leaf = (scripts / "01-core/sudo-policy.sh").read_text()
    (work / "01-core/sudo-policy.sh").write_text(leaf)
    (work / "common-core/sudo-policy.sh").write_text(leaf)
    return leaf


def environment(work: Path, case: Sequence[Any]) -> dict[str, str]:
    order, phase, uid, available, die_action, readonly, strict, context, delegate = case
    result = dict(os.environ, WORK=str(work), ORDER=order, PHASE=phase, TEST_EUID=uid,
                  AVAILABLE=str(available), DIE_ACTION=die_action, READONLY=readonly,
                  STRICT=str(strict), CONTEXT=context, DELEGATE=str(delegate))
    for key in ("BASH_ENV", "_COMMON_SH_LOADED", "_VERSIONS_ENV_LOADED", "_PLATFORM_SH_LOADED"):
        result.pop(key, None)
    return result


def check_receipt(work: Path, scripts: Path, leaf: str, row: Sequence[Sequence[Any]], real_euid: bool = False) -> None:
    case, expected = row
    context, delegate = case[7], case[8]
    common = (scripts / "01-core/common.sh").read_text()
    bootstrap = (scripts / "02-toolchain/bootstrap.sh").read_text()
    if not real_euid:
        common = common.replace("${EUID:", "${TEST_EUID:")
        bootstrap = bootstrap.replace("${EUID:", "${TEST_EUID:")
    bootstrap = bootstrap.replace("/opt/scripts/core", str(work / "no-installed"))
    (work / "common-core/common.sh").write_text(common)
    (work / "toolchain/bootstrap.sh").write_text(bootstrap)
    if delegate:
        (work / "common-core/sudo-policy.sh").unlink(missing_ok=True)
    else:
        (work / "common-core/sudo-policy.sh").write_text(leaf)
    call = ("if require_sudo 'head with spaces' ''; then result=0; else result=$?; fi"
            if context == "conditional" else "require_sudo 'head with spaces' ''\nresult=$?")
    result = subprocess.run(["bash", "-c", WORKER.replace("@CALL@", call)],
                            env=environment(work, case), capture_output=True, text=True,
                            timeout=10, check=False)
    stderr = re.sub(r"@WORK@/[^:\n]+: line \d+:", "@SOURCE@:",
                    result.stderr.replace(str(work), "@WORK@"))
    actual = [result.returncode, result.stdout.replace(str(work), "@WORK@"), stderr]
    assert actual == expected, (case, actual, expected)


COLD_WORKER = r'''
set -uo pipefail
[ "$STRICT" = 0 ] || set -e
command() {
 if [ "$*" = '-v sudo' ]; then return 0; fi
 builtin command "$@"
}
sudo_policy_select() { printf 'STALE\n'; SUDO=stale; }
case "$MODE" in readonly-helper|readonly-stale-wrong|delegated|matched|external-matched) readonly -f sudo_policy_select;;esac
if [ "$MODE" = delegated ] || [[ "$MODE" = *matched ]]; then
 _ensure_sudo_wrapper() { printf 'DELEGATED\n'; SUDO=delegated; SUDO_WRAP=delegated-wrap; return 19; }
fi
run_selected() {
 if [ "$CALLER" = common ]; then
  source "$WORK/common-core/common.sh"
 else
  if [ "$MODE" = external-bare ]; then
   cd "$WORK/toolchain"
   source bootstrap.sh
  else
   source "$WORK/toolchain/bootstrap.sh"
  fi
  [ "$STRICT" = 0 ] && set +e || set -e
  if [[ "$MODE" = external-* ]]; then
   source_toolchain_common_or_fallback "$WORK/project"
  else
   source_toolchain_common_or_fallback "$WORK/toolchain"
  fi
 fi
 SUDO=seed-sudo SUDO_WRAP=seed-wrap
 require_sudo head ''
 status=$?
 printf 'STATUS:%s SUDO:<%s> WRAP:<%s>\n' "$status" "$SUDO" "$SUDO_WRAP"
 if [ "$MODE" = delegated ] || [[ "$MODE" = *matched ]]; then
  declare -F _ensure_sudo_wrapper >/dev/null || return 91
  declare -F sudo_policy_select >/dev/null || return 92
 fi
 return "$status"
}
if [ "$CONTEXT" = conditional ]; then
 if run_selected; then result=0; else result=$?; fi
else
 run_selected
 result=$?
fi
exit "$result"
'''


def prepare_cold(work: Path, scripts: Path, mode: str) -> None:
    populate(work, scripts)
    common = (scripts / "01-core/common.sh").read_text()
    bootstrap = (scripts / "02-toolchain/bootstrap.sh").read_text()
    (work / "common-core/common.sh").write_text(common)
    (work / "toolchain/bootstrap.sh").write_text(
        bootstrap.replace("/opt/scripts/core", str(work / "no-installed")))
    (work / "toolchain/sudo-policy.sh").write_text("printf POISON; exit 93\n")
    if mode in {"missing", "delegated", "matched", "external-matched"}:
        for directory in ("common-core", "01-core"):
            (work / directory / "sudo-policy.sh").unlink()
    elif mode in {"wrong", "stale-wrong", "readonly-stale-wrong"}:
        for directory in ("common-core", "01-core"):
            (work / directory / "sudo-policy.sh").write_text(":\n")
    elif mode == "failed":
        for directory in ("common-core", "01-core"):
            (work / directory / "sudo-policy.sh").write_text(
                "sudo_policy_select() { printf BAD; }\nreturn 7\n")
    if mode == "matched":
        (work / "toolchain/common.sh").write_text("require_sudo() { SUDO=provided; }\n")
    if mode.startswith("external-"):
        (work / "project").mkdir()
    if mode == "external-matched":
        (work / "project/common.sh").write_text("require_sudo() { SUDO=provided; }\n")
        (work / "toolchain/common.sh").write_text("printf WRONG_COMMON; exit 94\n")
    elif mode == "external-installed":
        (work / "01-core/sudo-policy.sh").unlink()
        shutil.copyfile(scripts / "01-core/sudo-policy.sh", work / "no-installed/sudo-policy.sh")


def check_cold(scripts: Path, case: Sequence[Any]) -> None:
    caller, mode, strict, context = case
    with tempfile.TemporaryDirectory(prefix="sudo-cold-") as directory:
        work = Path(directory)
        prepare_cold(work, scripts, mode)
        code = COLD_WORKER
        if mode == "wrong":
            code = code.replace("sudo_policy_select() { printf 'STALE\\n'; SUDO=stale; }", "")
        env = dict(os.environ, WORK=directory, CALLER=caller, MODE=mode,
                   STRICT=str(strict), CONTEXT=context)
        for key in ("BASH_ENV", "_COMMON_SH_LOADED", "_VERSIONS_ENV_LOADED", "_PLATFORM_SH_LOADED"):
            env.pop(key, None)
        result = subprocess.run(["bash", "-c", code], env=env, capture_output=True,
                                text=True, timeout=10, check=False)
        expected = {"complete": 0, "missing": 1, "wrong": 1, "stale-wrong": 1,
                    "failed": 7, "readonly-helper": 1, "readonly-stale-wrong": 1,
                    "delegated": 19, "matched": 0,
                    "external-complete": 0, "external-installed": 0, "external-matched": 0,
                    "external-bare": 0}[mode]
        assert result.returncode == expected, (case, result)
        assert all(token not in result.stdout for token in ("STALE", "BAD", "POISON", "WRONG_COMMON")), (case, result)
        check_cold_message(case, result)


def check_cold_message(case: Sequence[Any], result: subprocess.CompletedProcess[str]) -> None:
    caller, mode, strict, context = case
    if mode in {"complete", "delegated", "matched", "external-complete", "external-installed", "external-matched", "external-bare"}:
        assert result.stderr == "", (case, result)
    elif mode == "missing":
        assert "sudo-policy.sh" in result.stderr, (case, result)
    elif mode in {"wrong", "stale-wrong"}:
        diagnostic = ("ERROR: sudo policy API missing\n" if caller == "common"
                      else "ERROR: toolchain bootstrap requires sudo_policy_select from sudo-policy.sh\n")
        assert result.stderr == diagnostic, (case, result)
    elif mode in {"readonly-helper", "readonly-stale-wrong"}:
        assert "sudo_policy_select" in result.stderr and "readonly" in result.stderr, (case, result)
    elif caller == "bootstrap" and (not strict or context == "conditional"):
        assert "source sudo-policy.sh failed with status 7" in result.stderr, (case, result)
    if mode == "delegated":
        assert result.stdout.startswith("DELEGATED\n"), (case, result)
    elif mode in {"matched", "external-matched"}:
        assert result.stdout == "STATUS:0 SUDO:<provided> WRAP:<seed-wrap>\n", (case, result)


PROTOCOL_WORKER = r'''
set -uo pipefail
source "$1"
events=() side=seed
nonroot() { events+=("PRED:$(printf '<%s>' "$@")"); return "$NONROOT"; }
available() { events+=("AVAILABLE:$(printf '<%s>' "$@")"); printf noisy; printf noisy >&2; return "$AVAILABLE"; }
denied() { events+=("DIE:$(printf '<%s>' "$@")"); printf 'denied\n' >&2; return 7; }
publish_nonroot() { events+=("NONROOT:$(printf '<%s>' "$@")"); side=nonroot; return "$PUBLISH_STATUS"; }
publish_root() { events+=("ROOT:$(printf '<%s>' "$@")"); side=root; return "$PUBLISH_STATUS"; }
sudo_policy_select nonroot available denied publish_nonroot publish_root 'head with spaces' ''
status=$?
printf '%s\n' "${events[@]}"
printf 'STATUS:%s SIDE:%s\n' "$status" "$side"
'''


def check_protocol(scripts: Path) -> None:
    for nonroot, available, status in itertools.product((0, 1), (0, 1), (0, 23)):
        env = dict(os.environ, NONROOT=str(nonroot), AVAILABLE=str(available), PUBLISH_STATUS=str(status))
        result = subprocess.run(["bash", "-c", PROTOCOL_WORKER, "_",
                                 str(scripts / "01-core/sudo-policy.sh")],
                                env=env, capture_output=True, text=True, timeout=10, check=False)
        suffix = '<head with spaces><>\n'
        expected = "PRED:" + suffix
        if nonroot == 0:
            expected += "AVAILABLE:" + suffix
            if available:
                expected += "DIE:" + suffix
            expected += "NONROOT:" + suffix
        else:
            expected += "ROOT:" + suffix
        side = "nonroot" if nonroot == 0 else "root"
        expected += f"STATUS:{status} SIDE:{side}\n"
        stderr = "denied\n" if nonroot == 0 and available else ""
        assert (result.returncode, result.stdout, result.stderr) == (0, expected, stderr), result


CWD_WORKER = r'''
set -uo pipefail
load_bootstrap() { source "$1"; }
pwd() { printf SDK_PWD_HOOK; return 99; }
run_imports() {
 for number in 1 2; do
  if [ "$number" = 1 ]; then
   owner="$WORK/hub-one/toolchain" project="$WORK/projects/one" start="$WORK/imports/one"
   relative='../../hub-one/toolchain/bootstrap.sh'
  else
   owner="$WORK/hub two/toolchain" project="$WORK/clients/two app" start="$WORK/imports/two"
   relative='../../hub two/toolchain/bootstrap.sh'
  fi
  if [[ "$IMPORT_STYLE" = bare* ]]; then
   cd "$owner"
   [ "$IMPORT_STYLE" != bare-unset-pwd ] || unset PWD
   load_bootstrap bootstrap.sh
  else
   cd "$start"
   load_bootstrap "$relative"
  fi
  if [ "$IMPORT_STYLE" = bare-unset-pwd ]; then
   [ "${PWD+set}" != set ] || return 97
  fi
  [ "$STRICT" = 0 ] && set +e || set -e
  cd "$project"
  SUDO=seed-sudo SUDO_WRAP=seed-wrap
  source_toolchain_common_or_fallback "$project"
  [ "$SUDO/$SUDO_WRAP" = seed-sudo/seed-wrap ] || return 94
  case "$_TOOLCHAIN_BOOTSTRAP_OWNER_DIR" in /*) ;; *) return 95;;esac
  case "${_TOOLCHAIN_BOOTSTRAP_OWNER_DIR@a}" in *x*) return 96;;esac
  shopt -s extdebug
  printf 'REQUIRE:'; declare -F require_sudo
  printf 'POLICY:'; declare -F sudo_policy_select
  printf 'PWD:%s\n' "$PWD"
 done
}
if [ "$CONTEXT" = conditional ]; then
 if run_imports; then status=0; else status=$?; fi
else
 run_imports
 status=$?
fi
exit "$status"
'''


def check_changed_directory(scripts: Path, style: str, strict: int, context: str) -> None:
    with tempfile.TemporaryDirectory(prefix="sudo-cwd-") as directory:
        work = Path(directory)
        (work / "installed").mkdir()
        owners = [work / "hub-one", work / "hub two"]
        for owner in owners:
            shutil.copytree(scripts / "01-core", owner / "01-core")
            (owner / "toolchain").mkdir()
            bootstrap = (scripts / "02-toolchain/bootstrap.sh").read_text()
            (owner / "toolchain/bootstrap.sh").write_text(
                bootstrap.replace("/opt/scripts/core", str(work / "installed")))
        projects = [work / "projects/one", work / "clients/two app"]
        starts = [work / "imports/one", work / "imports/two"]
        for path in projects + starts:
            path.mkdir(parents=True)
        env = dict(os.environ, WORK=directory, IMPORT_STYLE=style, STRICT=str(strict), CONTEXT=context,
                   _TOOLCHAIN_BOOTSTRAP_OWNER_DIR="stale-exported-owner")
        env.pop("BASH_ENV", None)
        result = subprocess.run(["bash", "-c", CWD_WORKER], env=env, capture_output=True,
                                text=True, timeout=10, check=False)
        assert result.returncode == 0 and result.stderr == "", (style, strict, context, result)
        lines = result.stdout.splitlines()
        assert len(lines) == 6, result
        for index, owner in enumerate(owners):
            require_line, policy_line, cwd = lines[index * 3:index * 3 + 3]
            require_path = Path(require_line.split(" ", 2)[2])
            if not require_path.is_absolute():
                require_path = (owner / "toolchain" if style.startswith("bare") else starts[index]) / require_path
            assert Path(os.path.normpath(require_path)) == owner / "toolchain/bootstrap.sh", result
            policy_path = Path(policy_line.split(" ", 2)[2])
            assert policy_path.is_absolute(), result
            assert Path(os.path.normpath(policy_path)) == owner / "01-core/sudo-policy.sh", result
            assert cwd == f"PWD:{projects[index]}", result


def main() -> None:
    scripts = Path(sys.argv[1]).resolve()
    rows = json.loads(Path(__file__).with_name("sudo-policy-receipts.json").read_text())
    assert len(rows) == 904
    with tempfile.TemporaryDirectory(prefix="sudo-policy-") as directory:
        work = Path(directory)
        leaf = populate(work, scripts)
        for row in rows:
            check_receipt(work, scripts, leaf, row)
        euid = subprocess.run(["bash", "-c", 'printf %s "$EUID"'], capture_output=True,
                              text=True, check=True).stdout
        uid_class = "0" if euid == "0" else "1000"
        real_rows = [row for row in rows if row[0][1:5] == ["after", uid_class, 0, "return"]
                     and row[0][8] == 0]
        assert len(real_rows) == 24
        for row in real_rows:
            check_receipt(work, scripts, leaf, row, real_euid=True)
    cold = list(itertools.product(("common", "bootstrap"),
                                  ("complete", "missing", "wrong", "stale-wrong", "failed", "readonly-helper", "readonly-stale-wrong"),
                                  (0, 1), ("direct", "conditional")))
    cold += [(caller, mode, strict, context) for caller, mode in
             (("common", "delegated"), ("bootstrap", "matched"))
             for strict, context in itertools.product((0, 1), ("direct", "conditional"))]
    cold += [("bootstrap", mode, strict, context) for mode in
             ("external-complete", "external-installed", "external-matched", "external-bare")
             for strict, context in itertools.product((0, 1), ("direct", "conditional"))]
    for case in cold:
        check_cold(scripts, case)
    check_protocol(scripts)
    for style, strict, context in itertools.product(("bare", "relative", "bare-unset-pwd"), (0, 1), ("direct", "conditional")):
        check_changed_directory(scripts, style, strict, context)
    print(f"{len(rows)} original receipts, {len(real_rows)} real EUID, {len(cold)} cold, 8 protocol and 12 CWD controls passed")


if __name__ == "__main__":
    main()
