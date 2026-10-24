#!/usr/bin/env python3
"""Private fake tools cover smoke dispatch and verdict order, not media decoding, camera hardware or container execution."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
SUBJECTS = Path(sys.argv.pop(1)).resolve()
TOOL = r"""#!/usr/bin/env bash
printf 'tool:%s\n' "${0##*/}" >> "$TRACE"
printf 'arg:%s\n' "$@" >> "$TRACE"
case "${0##*/}" in
  pkg-config)
    if [ "$1" = --exists ]; then [ "$SCENARIO" != pkg-missing ]; else echo 1.fixture; fi ;;
  lc-compliance) : ;;
  cam) [ "$SCENARIO" != camera-failed ] && echo 'cam help' ;;
  gst-inspect-1.0)
    case "$1" in
      --version) case "$SCENARIO" in version-failed|sandbox) exit 17 ;; esac; echo 'gst fixture' ;;
      *) case "$SCENARIO" in plugin-missing|sandbox) echo 'missing plugin detail' >&2; exit 18 ;; esac ;;
    esac ;;
  gst-launch-1.0)
    [ "$SCENARIO" != pipeline-failed ] || exit 19
    for arg in "$@"; do
      case "$arg" in location=*) dir="${arg#location=}"; dir="${dir%/*}"; for n in 0 1 2 3; do echo jpeg > "$dir/f$n.jpg"; done ;;
      esac
    done ;;
  ffmpeg)
    case "$1:$2" in
      -version:*) case "$SCENARIO" in version-failed|sandbox) exit 17 ;; esac; echo 'ffmpeg fixture' ;;
      -hide_banner:-buildconf) echo '--enable-libx265 --enable-libdav1d --enable-libsvtav1 --enable-libvpx --enable-libopus --enable-libvvdec' ;;
      -hide_banner:-encoders|-hide_banner:-decoders)
        echo 'x265 dav1d svtav1 vpx opus vvdec'
        [ "$SCENARIO" = encode-unadvertised ] || echo libx264 ;;
      -hide_banner:-filters) [ "$SCENARIO" = filters-missing ] || echo 'drawtext scale_vulkan' ;;
      -hide_banner:-h) : ;;
      -y:-i) echo decode-stdout; echo decode-stderr >&2; [ "$SCENARIO" != decode-failed ] ;;
      *) echo encode-stdout; echo encode-stderr >&2; case "$SCENARIO" in encode-failed|encode-unadvertised) exit 21 ;; esac; printf encoded > "${@: -1}" ;;
    esac ;;
esac
"""
DRIVER = r"""set -euo pipefail
source "$TESTS/test-harness.sh"
cross_build_is_active() { builtin printf 'cross:%s\n' "$SCENARIO" >> "$TRACE"; [ "$SCENARIO" = cross ]; }
source "$COMMON"
smoke_is_elf() { builtin printf 'elf:%s\n' "$1" >> "$TRACE"; [ "$SCENARIO" != invalid-elf ]; }
command() {
  if [ "${1:-}" = -v ]; then
    case "${2:-}" in ffmpeg|cam|gst-inspect-1.0|gst-launch-1.0|pkg-config|lc-compliance)
      [ -x "$TOOLS/$2" ] || return 1 ;;
    esac
  fi
  builtin command "$@"
}
mktemp() {
  local count=0
  [ ! -f "$WORK/temp-count" ] || read -r count < "$WORK/temp-count"
  count=$((count+1)); builtin printf '%s\n' "$count" > "$WORK/temp-count"
  builtin printf 'mktemp:%s\n' "$count" >> "$TRACE"
  builtin command mkdir -p "$WORK/tmp/t$count"
  builtin printf '%s\n' "$WORK/tmp/t$count"
  [ "$SCENARIO:$count" != mktemp-failed:2 ]
}
rm() {
  local count=0
  [ ! -f "$WORK/remove-count" ] || read -r count < "$WORK/remove-count"
  count=$((count+1)); builtin printf '%s\n' "$count" > "$WORK/remove-count"
  builtin printf 'remove:%s\n' "$*" >> "$TRACE"
  [ "$SCENARIO:$count" != cleanup-failed:2 ] || return 23
  builtin command rm "$@"
}
for fn in _smoke_ffmpeg_features _smoke_ffmpeg_native _smoke_cam_native _smoke_gst_version; do
  if grep -q "^$fn()" "$MEDIA"; then t_source_functions "$MEDIA" "$fn"; fi
done
trap 'for name in FAILURES gst_ver _gst_inspect _gst_bin _ffmpeg_bin ffmpeg_ver tmpdir _gst_launch _ffmpeg_execok _ff_probe _gst_missing _gst_loaded _gst_deferred _p _gst_err _gst_tmp _ff_bc _ff_codecs _ff_filters _c _spec _ff_tmp _lc_prefix _lc_pc _cam_bin lc_ver PKG_CONFIG_PATH; do builtin printf "%s=%s\n" "$name" "${!name-<unset>}"; done > "$WORK/state"' EXIT
if [ "$CONTEXT" = conditional ]; then
  if source "$SECTION"; then exit 0; else exit "$?"; fi
fi
source "$SECTION"
"""
SCENARIOS = (
    "success",
    "cross",
    "missing",
    "compliance",
    "pkg-missing",
    "camera-failed",
    "version-failed",
    "invalid-elf",
    "pipeline-failed",
    "plugin-missing",
    "sandbox",
    "encode-failed",
    "encode-unadvertised",
    "decode-failed",
    "filters-missing",
    "mktemp-failed",
    "cleanup-failed",
)


def plant_tools(work, scenario):
    tools = work / "tools"
    tools.mkdir()
    names = ["pkg-config", "gst-launch-1.0"]
    if scenario not in ("missing", "compliance"):
        names += ["ffmpeg", "gst-inspect-1.0", "cam"]
    if scenario == "compliance":
        names.append("lc-compliance")
    for name in names:
        path = tools / name
        path.write_text(TOOL)
        path.chmod(0o755)
    return tools


def capture_case(subjects, scenario, context):
    with tempfile.TemporaryDirectory(prefix="ant-smoke-native-") as temporary:
        work = Path(temporary)
        text = (subjects / "smoke-media.sh").read_text()
        section = work / "section.sh"
        section.write_text(
            text[text.index("# GStreamer: version") : text.index("# GCC\n")]
        )
        tools = plant_tools(work, scenario)
        pc = work / "camera/lib/fixture/pkgconfig/libcamera.pc"
        pc.parent.mkdir(parents=True)
        pc.write_text("fixture")
        env = dict(
            os.environ,
            WORK=str(work),
            TESTS=str(TESTS),
            TRACE=str(work / "trace"),
            COMMON=str(subjects / "smoke-common.sh"),
            MEDIA=str(subjects / "smoke-media.sh"),
            SECTION=str(section),
            TOOLS=str(tools),
            PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
            CONTEXT=context,
            SCENARIO=scenario,
            GSTREAMER_PREFIX=str(work / "gstreamer"),
            FFMPEG_PREFIX=str(work / "ffmpeg"),
            LIBCAMERA_PREFIX=str(work / "camera"),
            PKG_CONFIG_PATH="prior pkg path",
        )
        result = subprocess.run(
            ["bash", "-c", DRIVER],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=20,
        )
        normalize = lambda text: text.replace(str(work), "WORK")
        return {
            "status": result.returncode,
            "stdout": normalize(result.stdout),
            "stderr": normalize(result.stderr),
            "trace": normalize((work / "trace").read_text())
            if (work / "trace").exists()
            else "",
            "state": normalize((work / "state").read_text())
            if (work / "state").exists()
            else "",
            "remaining": sorted(
                str(path.relative_to(work))
                for path in (work / "tmp").rglob("*")
                if path.is_file()
            ),
        }


def capture(subjects):
    return {
        f"{scenario}:{context}": capture_case(subjects, scenario, context)
        for scenario in SCENARIOS
        for context in ("strict", "conditional")
    }


class NativeSmokeDispatch(unittest.TestCase):
    def test_original_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("smoke-native-dispatch-receipts.json").read_text()
        )
        actual = capture(SUBJECTS)
        for case, receipt in expected.items():
            with self.subTest(case=case):
                self.assertEqual(receipt, actual[case])

    def test_callback_contract(self):
        command = r"""source "$1"
cross_build_is_active() { return 1; }
label=caller-label; path=caller-path; GLOBAL=40
callback() { GLOBAL=$((GLOBAL+2)); printf '%s|%s|%s|%s' "$label" "$path" "$1" "$2"; return 7; }
if smoke_native_dispatch tool '/path with spaces' callback 'arg with spaces' ''; then status=0; else status=$?; fi
printf '\nstatus=%s global=%s' "$status" "$GLOBAL"
"""
        result = subprocess.run(
            ["bash", "-c", command, "_", str(SUBJECTS / "smoke-common.sh")],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual(
            "caller-label|caller-path|arg with spaces|\nstatus=7 global=42",
            result.stdout,
        )
        command = r"""source "$1"
cross_build_is_active() { return 1; }
callback() { printf before; false; printf after; }
smoke_native_dispatch tool /path callback
"""
        result = subprocess.run(
            ["bash", "-c", command, "_", str(SUBJECTS / "smoke-common.sh")],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(1, result.returncode)
        self.assertEqual("before", result.stdout)

    def test_independent_verdicts_and_errexit(self):
        actual = capture(SUBJECTS)
        self.assertIn("PASS ffmpeg H.264 encode OK", actual["success:strict"]["stdout"])
        self.assertIn("PASS cam binary functional", actual["success:strict"]["stdout"])
        self.assertIn(
            "encode-stdout\n  PASS ffmpeg H.264 encode OK\ndecode-stdout\n  PASS ffmpeg H.264 decode OK",
            actual["success:strict"]["stdout"],
        )
        self.assertNotIn("encode-stderr", actual["success:strict"]["stderr"])
        self.assertNotIn("decode-stderr", actual["success:strict"]["stderr"])
        self.assertIn(
            "arg:testsrc=duration=1:size=32x32:rate=1\n",
            actual["success:strict"]["trace"],
        )
        self.assertIn(
            "arg:testsrc=duration=1:size=32x32:rate=2\n",
            actual["success:strict"]["trace"],
        )
        self.assertIn(
            "arg:libx264\narg:-preset\narg:ultrafast\n",
            actual["success:strict"]["trace"],
        )
        self.assertEqual("", actual["cross:strict"]["stderr"])
        self.assertNotIn("tool:ffmpeg", actual["cross:strict"]["trace"])
        self.assertNotIn("tool:cam", actual["cross:strict"]["trace"])
        self.assertIn(
            "ffmpeg H.264 encode FAILED", actual["encode-failed:strict"]["stderr"]
        )
        self.assertNotIn(
            "ffmpeg H.264 encode FAILED", actual["encode-unadvertised:strict"]["stderr"]
        )
        self.assertEqual(1, actual["mktemp-failed:strict"]["status"])
        self.assertEqual(0, actual["mktemp-failed:conditional"]["status"])
        self.assertEqual(23, actual["cleanup-failed:strict"]["status"])
        self.assertEqual(0, actual["cleanup-failed:conditional"]["status"])
        self.assertIn("FAILURES=0\n", actual["success:strict"]["state"])
        self.assertEqual(
            ["tmp/t2/smoke.mp4", "tmp/t3/s.mkv"],
            actual["cleanup-failed:strict"]["remaining"],
        )
        self.assertEqual(
            ["tmp/t3/s.mkv"], actual["cleanup-failed:conditional"]["remaining"]
        )
        self.assertEqual([], actual["success:strict"]["remaining"])


if __name__ == "__main__":
    unittest.main()
