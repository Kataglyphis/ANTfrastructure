"""Original caller receipts cover literal provider bindings without executing build entrypoints."""
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ALIAS_WORKER = r"""
set -uo pipefail
[ "$STRICT" = 0 ] || set -e
shopt -s expand_aliases
provider_context() {
 printf '%s' "$1" >> "$WORK/trace"
 shift
 printf '<%s>' "$@" >> "$WORK/trace"
 printf '\n' >> "$WORK/trace"
 case "$PROVIDER" in partial) printf 'hidden diagnostic\n' >&2;; esac
 case "$KIND" in include_dir) printf '%s/include' "$WORK";; library) printf '%s/library.so' "$WORK";; pkgconfig_dir) printf '%s/pkgconfig' "$WORK";;esac
 [ "$PROVIDER" != partial ] || return 17
}
include_provider() { KIND=include_dir provider_context include "$@"; }
library_provider() { KIND=library provider_context library "$@"; }
pkgconfig_provider() { KIND=pkgconfig_dir provider_context pkgconfig "$@"; }
install_aliases() {
 alias cross_target_python_include_dir='include_provider "${1-}" "$@"'
 alias cross_target_python_library='library_provider "${1-}" "$@"'
 alias cross_target_python_pkgconfig_dir='pkgconfig_provider "${1-}" "$@"'
}
cross_target_python_include_dir() { include_provider "$@"; }
cross_target_python_library() { library_provider "$@"; }
cross_target_python_pkgconfig_dir() { pkgconfig_provider "$@"; }
if [ "$PHASE" != after ]; then
 unset -f cross_target_python_include_dir cross_target_python_library cross_target_python_pkgconfig_dir
fi
[ "$PHASE" != before_owner ] || install_aliases
source "$WORK/owner"
[ "$PHASE" != between ] || install_aliases
source "$WORK/caller"
[ "$PHASE" != after ] || install_aliases
cross_target_triplet() { printf triplet; }
cross_build_is_active() { return 0; }
_gst_xpy_check_meson() { return 0; }
_gst_xpy_write_config() { printf 'VALUES:%s|%s|%s\n' "$target_python_include" "$target_python_library" "$target_python_pkgconfig_dir"; }
setup_host_python_environment() { :; }
uv() { :; }
python_module_include() { printf '%s/include' "$WORK"; }
WITH_PYTHON=true HOST_PYTHON='/host python' OPENCV_PYTHON_VERSION=3.99
target_python_include='' target_python_library='' target_python_pkgconfig_dir=''
opts=()
run() {
 if [ "$SUBJECT" = gst ]; then
  prepare_cross_python_build_config "$@"
 else
  _opencv_cmake_python_opts "$@"
  printf 'OPTIONS'; printf '<%s>' "${opts[@]}"; printf '\n'
 fi
}
set -- opts 'tail with spaces' ''
if [ "$CONTEXT" = conditional ]; then
 if run "$@"; then printf 'STATUS:0\n'; else printf 'STATUS:%s\n' "$?"; fi
else
 run "$@"
 printf 'STATUS:%s\n' "$?"
fi
if declare -F _gst_python_provider >/dev/null || declare -F _opencv_python_provider >/dev/null; then printf LEAK; else printf CLEAN; fi
"""

TESTS = Path(__file__).resolve().parent
SUBJECTS = {
    "gst": ("03-media/build/gstreamer/common/setup-gstreamer.sh", "_gst_xpy_resolve_target_paths"),
    "opencv": ("03-media/build/opencv/build-opencv.sh", "_opencv_cmake_python_opts"),
}


def function(text, name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", text, re.MULTILINE | re.DOTALL)
    assert match is not None, name
    return match.group() + "\n"


def check_original_receipts(scripts):
    rows = json.loads((TESTS / "python-provider-context-receipts.json").read_text())
    assert len(rows) == 48
    worker = ALIAS_WORKER
    owner = (scripts / "01-core/cross-python.sh").read_text()
    with tempfile.TemporaryDirectory(prefix="python-provider-context-") as directory:
        work = Path(directory)
        (work / "include").mkdir()
        (work / "owner").write_text(function(owner, "cross_capture_python_dev_path")
                                    + function(owner, "cross_python_provider_api_ready"))
        for case, expected in rows:
            subject, phase, strict, context, provider = case
            file, name = SUBJECTS[subject]
            caller_text = (scripts / file).read_text()
            caller_functions = function(caller_text, name)
            if subject == "gst":
                caller_functions += function(caller_text, "prepare_cross_python_build_config")
            (work / "caller").write_text(caller_functions)
            (work / "trace").write_text("")
            env = dict(os.environ, WORK=directory, SUBJECT=subject, PHASE=phase,
                       STRICT=str(strict), CONTEXT=context, PROVIDER=provider)
            result = subprocess.run(["bash", "-c", worker], env=env, capture_output=True,
                                    text=True, timeout=10, check=False)
            receipt = [result.returncode, result.stdout, result.stderr, (work / "trace").read_text()]
            receipt = [value.replace(directory, "@WORK@") if isinstance(value, str) else value
                       for value in receipt]
            assert receipt == expected, (case, receipt, expected)
    return len(rows)


COLD_WORKER = r'''
set -uo pipefail
[ "$STRICT" = 0 ] || set -e
unset _CROSS_PYTHON_LOADED _PLATFORM_SH_LOADED
[ "$OWNER_MODE" != guarded ] || _CROSS_PYTHON_LOADED=1
source "$WORK/core/cross-python.sh"
cross_target_triplet() { printf triplet; }
cross_build_is_active() { return 0; }
cross_target_python_include_dir() { printf '%s/include' "$WORK"; }
cross_target_python_library() { printf '%s/library.so' "$WORK"; }
cross_target_python_pkgconfig_dir() { printf '%s/pkgconfig' "$WORK"; }
setup_host_python_environment() { :; }
uv() { :; }
python_module_include() { printf '%s/include' "$WORK"; }
WITH_PYTHON=true HOST_PYTHON='/host python' OPENCV_PYTHON_VERSION=3.99
target_python_include='' target_python_library='' target_python_pkgconfig_dir=''
source "$WORK/caller"
opts=()
run() {
 if [ "$SUBJECT" = gst ]; then _gst_xpy_resolve_target_paths '';
 else _opencv_cmake_python_opts opts tail ''; fi
}
if [ "$CONTEXT" = conditional ]; then
 if run; then rc=0; else rc=$?; fi
else
 run
 rc=$?
fi
printf 'RESULT:%s\n' "$rc"
exit "$rc"
'''


def check_cold_owner(scripts, case):
    subject, mode, strict, context = case
    with tempfile.TemporaryDirectory(prefix="python-cold-owner-") as directory:
        work = Path(directory)
        (work / "core").mkdir()
        (work / "include").mkdir()
        for name in ("cross-python.sh", "platform.sh"):
            shutil.copyfile(scripts / "01-core" / name, work / "core" / name)
        owner = work / "core/cross-python.sh"
        text = owner.read_text()
        if mode in {"old", "partial"}:
            text = text.replace(function(text, "cross_capture_python_dev_path"), "")
        if mode == "old":
            text = text.replace(function(text, "cross_python_provider_api_ready"), "")
        owner.write_text(text)
        if mode == "missing-platform":
            (work / "core/platform.sh").unlink()
        file, name = SUBJECTS[subject]
        (work / "caller").write_text(function((scripts / file).read_text(), name))
        env = dict(os.environ, WORK=directory, SUBJECT=subject, STRICT=str(strict), CONTEXT=context,
                   OWNER_MODE=mode)
        result = subprocess.run(["bash", "-c", COLD_WORKER], env=env, capture_output=True,
                                text=True, timeout=10, check=False)
        expected = {"complete": 0, "old": 127, "guarded": 127, "partial": 1, "missing-platform": 1}[mode]
        assert result.returncode == expected, (case, result)
        if mode == "complete":
            assert result.stdout.endswith("RESULT:0\n"), (case, result)
            assert result.stderr == "", (case, result)
        elif mode in {"old", "guarded"}:
            assert "cross_python_provider_api_ready: command not found" in result.stderr, (case, result)
        elif mode == "partial":
            assert result.stderr == "ERROR: target Python probes require cross_capture_python_dev_path\n", (case, result)
        else:
            assert "platform.sh" in result.stderr, (case, result)


def main():
    scripts = Path(sys.argv[1]).resolve()
    count = check_original_receipts(scripts)
    cold = list(itertools.product(SUBJECTS, ("complete", "old", "partial", "missing-platform", "guarded"),
                                  (0, 1), ("direct", "conditional")))
    for case in cold:
        check_cold_owner(scripts, case)
    print(f"{count} original argv/alias receipts and {len(cold)} copied-owner controls passed")


if __name__ == "__main__":
    main()
