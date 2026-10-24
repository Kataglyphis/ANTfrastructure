"""Stubbed optional probes preserve report bytes, not real pkg-config metadata or plugin loading."""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

WORKER = r"""
set -uo pipefail
[ "$STRICT" = 0 ] || set -e
shopt -s expand_aliases
command() {
 printf 'LOOKUP:<%s>\n' "$*" >> "$WORK/trace"
 case "$*" in
 '-v pkg-config') return "$PKG_AVAILABLE" ;;
 '-v gst-inspect-1.0') return "$GST_AVAILABLE" ;;
 esac
 builtin command "$@"
}
pkg() {
 printf 'PKG:%s:<%s>\n' "$PHASE" "$*" >> "$WORK/trace"
 printf 'pkg diagnostic\n' >&2
 case "$1" in --exists) printf 'probe stdout\n'; return "$PKG_RC";; *) printf '%s\n' 'fixture version with spaces'; return "$VERSION_RC";; esac
}
gst() {
 printf 'GST:%s:<%s>\n' "$PHASE" "$*" >> "$WORK/trace"
 printf 'gst diagnostic\n' >&2
 printf 'probe stdout\n'
 return "$GST_RC"
}
early_pkg() { PHASE=early pkg "$@"; }
late_pkg() { PHASE=late pkg "$@"; }
early_gst() { PHASE=early gst "$@"; }
late_gst() { PHASE=late gst "$@"; }
pkg-config() { PHASE=plain pkg "$@"; }
gst-inspect-1.0() { PHASE=plain gst "$@"; }
if [ "$ALIASES" != plain ]; then
 alias pkg-config=early_pkg
 alias gst-inspect-1.0=early_gst
fi
source "$WORK/$SOURCE-functions.sh"
if [ "$ALIASES" = after ]; then
 alias pkg-config=late_pkg
 alias gst-inspect-1.0=late_gst
fi
PATH='/fixture/report/path'
LIBCAMERA_PREFIX='/fixture camera' MULTIARCH_TRIPLET='fixture triplet'
PKG_CONFIG_PATH='' LD_LIBRARY_PATH='/fixture libs' GST_PLUGIN_PATH='' PYTHONPATH='fixture python'
if [ "$CONTEXT" = conditional ]; then
 if libcamera_env_show; then printf 'STATUS:0\n'; else printf 'STATUS:%s\n' "$?"; fi
else
 libcamera_env_show
 printf 'STATUS:%s\n' "$?"
fi
"""


def check_report(work, row):
    case, expected = row
    strict, context, aliases, pkg_available, gst_available, pkg_rc, gst_rc, version_rc = case
    env = dict(os.environ, WORK=str(work), STRICT=str(strict), CONTEXT=context,
               ALIASES=aliases, PKG_AVAILABLE=str(pkg_available), GST_AVAILABLE=str(gst_available),
               PKG_RC=str(pkg_rc), GST_RC=str(gst_rc), VERSION_RC=str(version_rc), SOURCE="current")
    (work / "trace").write_text("")
    result = subprocess.run(["bash", "-c", WORKER], env=env, capture_output=True,
                            text=True, timeout=10, check=False)
    receipt = [result.returncode, result.stdout, result.stderr, (work / "trace").read_text()]
    assert receipt == expected, (case, receipt, expected)


def check_dynamic_scope(work):
    code = r'''
set -euo pipefail
source "$1/current-functions.sh"
LIBCAMERA_PREFIX=x MULTIARCH_TRIPLET=x PKG_CONFIG_PATH=x LD_LIBRARY_PATH=x GST_PLUGIN_PATH=x PYTHONPATH=x
tool=outer-tool probe=outer-probe success=outer-success missing=outer-missing
pkg-config() { if [ "$1" = --modversion ]; then printf '%s/%s/%s/%s' "$tool" "$probe" "$success" "$missing"; fi; }
gst-inspect-1.0() { :; }
libcamera_env_show
caller() {
 local tool=caller-tool probe=caller-probe success=caller-success missing=caller-missing
 libcamera_env_show
}
caller
printf 'GLOBALS:%s/%s/%s/%s\n' "$tool" "$probe" "$success" "$missing"
'''
    result = subprocess.run(["bash", "-c", code, "_", str(work)], capture_output=True,
                            text=True, timeout=10, check=False)
    assert result.returncode == 0, result
    assert "  pkg-config: libcamera found -> outer-tool/outer-probe/outer-success/outer-missing\n" in result.stdout, result
    assert "  pkg-config: libcamera found -> caller-tool/caller-probe/caller-success/caller-missing\n" in result.stdout, result
    assert result.stdout.endswith("GLOBALS:outer-tool/outer-probe/outer-success/outer-missing\n"), result
    assert result.stderr == "", result


def check_prefix_argv(work):
    code = r"""
set -euo pipefail
shopt -s expand_aliases
PATH=/fixture/path LIBCAMERA_PREFIX=fixture MULTIARCH_TRIPLET=triplet PKG_CONFIG_PATH=fixture LD_LIBRARY_PATH=fixture GST_PLUGIN_PATH=fixture PYTHONPATH=fixture
pkg_prefix() {
 printf 'PKG' >> "$WORK/argv-trace"; printf '<%s>' "$@" >> "$WORK/argv-trace"; printf '\n' >> "$WORK/argv-trace"
 case "${*: -2}" in '--modversion libcamera') printf fixture-version;; esac
}
gst_prefix() { printf 'GST' >> "$WORK/argv-trace"; printf '<%s>' "$@" >> "$WORK/argv-trace"; printf '\n' >> "$WORK/argv-trace"; }
alias pkg-config='pkg_prefix "${1-}" "$@"'
alias gst-inspect-1.0='gst_prefix "${1-}" "$@"'
source "$1"
libcamera_env_show 'head with spaces' '' tail
"""
    (work / "argv-trace").write_text("")
    result = subprocess.run(["bash", "-c", code, "_", str(work / "current-functions.sh")],
                            env=dict(os.environ, WORK=str(work)), capture_output=True,
                            text=True, timeout=10, check=False)
    expected = json.loads(Path(__file__).with_name("libcamera-report-argv-receipt.json").read_text())
    actual = [result.returncode, result.stdout, result.stderr, (work / "argv-trace").read_text()]
    assert actual == expected, (actual, expected)


def main():
    text = Path(sys.argv[1]).read_text()
    names = ("_libcamera_report_available_probe", "_libcamera_pkg_probe", "_libcamera_pkg_found",
             "_libcamera_gst_probe", "_libcamera_gst_found", "libcamera_env_show")
    functions = []
    for name in names:
        match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", text, re.MULTILINE | re.DOTALL)
        assert match is not None, name
        functions.append(match.group() + "\n")
    rows = json.loads(Path(__file__).with_name("libcamera-report-receipts.json").read_text())
    assert len(rows) == 384
    with tempfile.TemporaryDirectory(prefix="libcamera-report-") as directory:
        work = Path(directory)
        (work / "current-functions.sh").write_text("".join(functions))
        for row in rows:
            check_report(work, row)
        check_dynamic_scope(work)
        check_prefix_argv(work)
    print(f"{len(rows)} original report receipts and dynamic-scope contract passed")


if __name__ == "__main__":
    main()
