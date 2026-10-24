"""Offline pin fixtures cover binding and failure policies, not actual compiler or library repair."""

import itertools
import json
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = (
    Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else ROOT / "linux/scripts"
)


def fn(text, name):
    return (
        re.search(
            r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", text, re.MULTILINE | re.DOTALL
        ).group()
        + "\n"
    )


ff_text = (SCRIPTS / "03-media/build/ffmpeg/build-ffmpeg.sh").read_text()
gst_text = (
    SCRIPTS / "03-media/build/gstreamer/common/build-gstreamer-stage.sh"
).read_text()
core = (SCRIPTS / "03-media/core/common.sh").read_text()
helper = (
    fn(core, "media_pin_target_libstdcxx_if_available")
    if "media_pin_target_libstdcxx_if_available() {" in core
    else ""
)


def gst(text):
    return (
        text[
            text.index("# The onnx plugin link") : text.index(
                "\ncd /opt", text.index("# The onnx plugin link")
            )
        ]
        + "\n"
    )


base = r"""
set -uo pipefail
shopt -s expand_aliases
cross_build_is_active() { [ "$CROSS" = 1 ]; }
setup_linux_cross_env() { printf 'SETUP\n'; }
cross_target_arch() { printf 'ARCH\n' >&2; printf 'ARCH\n' >> "$TRACE_FILE"; printf riscv64; }
resolve_ffmpeg_host_compiler() { :; }
record_pin() { printf 'PIN:<%s>:' "$1"; shift; printf '<%s>' "$@"; printf ':SCOPE:<%s>\n' "${host_cc-UNSET}"; PIN_CALLED=1; return "$PIN_RC"; }
early_pin() { record_pin early "$@"; }
late_pin() { record_pin late "$@"; }
pin_target_libstdcxx() { record_pin function "$@"; }
TARGET_ARCH=riscv64 CROSS_TARGET_TRIPLET=no-such-target BUILD_MODE=cross
PIN_CALLED=0
"""


def provider_setup(phase, provider, command_alias, missing, status, cross):
    code = base + f"PIN_RC={status} CROSS={cross}\n"
    if command_alias:
        code += 'command_early() { LOOKUP_PHASE=early; LOOKUP_ARGV="$*"; builtin command -v pin_target_libstdcxx; }\ncommand_late() { LOOKUP_PHASE=late; LOOKUP_ARGV="$*"; builtin command -v pin_target_libstdcxx; }\nalias command=\'command_early "$@"\'\n'
    if not missing:
        code += helper
    if command_alias:
        code += "alias command='command_late \"$@\"'\n"
    if provider == "missing":
        code += "unset -f pin_target_libstdcxx\n"
    if provider == "alias":
        code += "alias pin_target_libstdcxx='early_pin \"$@\"'\n"
    if phase == "before" and provider == "alias":
        code += "alias pin_target_libstdcxx='late_pin \"$@\"'\n"
    return code


def caller_source(subject, phase, provider, cross, module_path):
    code = ""
    late = (
        "alias pin_target_libstdcxx='late_pin \"$@\"'\n"
        if phase == "after" and provider == "alias"
        else ""
    )
    if subject == "ff":
        if "_ffmpeg_pin_available() {" in ff_text:
            code += fn(ff_text, "_ffmpeg_pin_available") + fn(
                ff_text, "_ffmpeg_pin_target_libstdcxx"
            )
        code += fn(ff_text, "_ffmpeg_cross_args") + late + "declare -a cfg=()\n"
        return code, "_ffmpeg_cross_args cfg 'tail [*]' ''"
    module = ""
    if "_gst_pin_available() {" in gst_text:
        module += fn(gst_text, "_gst_pin_available") + fn(
            gst_text, "_gst_pin_target_libstdcxx"
        )
    module_path.write_text(module + gst(gst_text))
    code += late
    code += "BUILD_MODE=native\n" if cross == 0 else ""
    return code, "source " + shlex.quote(str(module_path)) + " '1.2.3' '/prefix [*]' ''"


def run(
    subject,
    strict,
    context,
    phase,
    provider,
    status,
    cross,
    command_alias=False,
    missing=False,
    target=("riscv64", ""),
    trace=False,
):
    code = provider_setup(phase, provider, command_alias, missing, status, cross)
    code += (
        "TARGET_ARCH="
        + shlex.quote(target[0])
        + " TARGETARCH="
        + shlex.quote(target[1])
        + "\n"
    )
    code += "set -e\n" if strict else "set +e\n"
    with tempfile.TemporaryDirectory(prefix="ant-media-pin-source-") as directory:
        declaration, call = caller_source(
            subject, phase, provider, cross, Path(directory) / "stage-pin.sh"
        )
        trace_file = Path(directory) / "arch-calls"
        trace_file.write_text("")
        code += "TRACE_FILE=" + shlex.quote(str(trace_file)) + "\n"
        code += declaration
        code += (
            "if " + call + "; then rc=0; else rc=$?; fi\n"
            if context == "conditional"
            else call + "\nrc=$?\n"
        )
        code += 'printf "STATUS:%s PIN:%s LOOKUP:%s:<%s>\\n" "$rc" "$PIN_CALLED" "${LOOKUP_PHASE:-}" "${LOOKUP_ARGV:-}"\n'
        if subject == "ff":
            code += "declare -p cfg\n"
        result = subprocess.run(
            ["bash", "-c", code],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        calls = len(trace_file.read_text().splitlines())
    receipt = [result.returncode, result.stdout, result.stderr]
    return receipt + [calls] if trace else receipt


class PinAdvisoryTests(unittest.TestCase):
    def test_original_receipts(self):
        rows = json.loads(
            Path(__file__).with_name("media-pin-advisory-receipts.json").read_text()
        )
        self.assertEqual(192, len(rows))
        for row in rows:
            with self.subTest(case=row["case"]):
                subject, *args = row["case"]
                self.assertEqual(row["receipt"], run(subject, *args))

    def test_literal_alias_arguments_and_scope(self):
        for subject in ["ff", "gst"]:
            result = run(subject, True, "direct", "before", "alias", 23, 1, True)
            self.assertEqual(0, result[0])
            prefix = "cfg tail [*] " if subject == "ff" else "1.2.3 /prefix [*] "
            self.assertIn(
                "LOOKUP:late:<" + prefix + " -v pin_target_libstdcxx>", result[1]
            )
            self.assertIn("PIN:<late>:", result[1])
            self.assertIn(":SCOPE:<UNSET>", result[1])
            self.assertEqual("ARCH\n" * 3 if subject == "ff" else "", result[2])

    def test_pin_target_query_is_lazy(self):
        for provider, cross in itertools.product(
            ["function", "alias", "missing"], [0, 1]
        ):
            result = run(
                "ff", True, "direct", "before", provider, 23, cross, trace=True
            )
            expected = 0 if not cross else (2 if provider == "missing" else 3)
            self.assertEqual(expected, result[3])

    def test_gstreamer_target_fallback_and_amd64_gate(self):
        for target, fallback, selected in [
            ("arm64", "riscv64", "arm64"),
            ("", "arm64", "arm64"),
            ("", "", ""),
            ("amd64", "arm64", None),
            ("", "amd64", None),
        ]:
            result = run(
                "gst",
                True,
                "conditional",
                "before",
                "function",
                23,
                1,
                target=(target, fallback),
            )
            self.assertEqual(0, result[0])
            if selected is None:
                self.assertNotIn("PIN:<", result[1])
            else:
                self.assertIn("PIN:<function>:<" + selected + ">", result[1])

    def test_old_owner_fails_only_when_selected(self):
        for subject, cross, context in itertools.product(
            ["ff", "gst"], [0, 1], ["direct", "conditional"]
        ):
            result = run(
                subject,
                True,
                context,
                "before",
                "function",
                0,
                cross,
                missing=True,
            )
            self.assertEqual(
                bool(cross),
                "ERROR: runtime pinning requires media_pin_target_libstdcxx_if_available from media common.sh"
                in result[2],
            )
            if not cross:
                self.assertEqual(0, result[0])
                self.assertIn("STATUS:0 PIN:0", result[1])
            elif subject == "ff" and context == "conditional":
                self.assertIn("STATUS:1 PIN:0", result[1])
            self.assertNotIn("PIN:<", result[1])
            if cross and (subject == "gst" or context == "direct"):
                self.assertEqual(1, result[0])


if __name__ == "__main__":
    unittest.main()
