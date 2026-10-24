#!/usr/bin/env python3
"""Fake installers preserve shell policy and copied closures, not network or package-install correctness."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = Path(sys.argv.pop(1)).resolve()
STUB = r"""
record() { builtin printf '%s\n' "$@" >> "$TRACE"; }
mktemp() { record mktemp "$@"; builtin printf '%s\n' "$WORK/fixture path"; return "$TEMP_STATUS"; }
curl() { record curl "$@"; builtin printf partial > "$WORK/fixture path"; return "$CURL_STATUS"; }
sha256sum() { record sha256sum "$@"; cat >> "$TRACE"; return "$HASH_STATUS"; }
sh() { record sh "$@"; return "$SH_STATUS"; }
rm() { record rm "$@"; [ "$RM_STATUS" = 0 ] || return "$RM_STATUS"; command rm "$@"; }
info() { echo "$@"; }
die() { echo "$@" >&2; exit 1; }
uv() { echo uv-fixture; }
command() { if [ "$*" = '-v uv' ]; then [ "${UV_PRESENT:-0}" = 1 ]; return; fi; builtin command "$@"; }
trap 'declare -p rustup_init 2>/dev/null > "$STATE" || true' EXIT
"""


def function(file, name):
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1/linux/scripts/tests/test-harness.sh"; t_fn_src "$2" "$3"',
            "_",
            str(ROOT),
            str(file),
            name,
        ],
        text=True,
        capture_output=True,
        check=True,
    ).stdout


def installer_code(scripts, caller):
    file = scripts / (
        "01-core/python_uv.sh" if caller == "uv" else "02-toolchain/install-rust.sh"
    )
    text = file.read_text()
    helper = scripts / "01-core/verified-script-install.sh"
    prefix = helper.read_text() if helper.exists() else ""
    if caller == "uv":
        if "_uv_install_hash_failure() {" in text:
            prefix += function(file, "_uv_install_hash_failure")
        return (
            prefix + function(file, "uv_ensure_installed") + "\nuv_ensure_installed\n"
        )
    start = text.index(
        "_rust_install_hash_failure() {"
        if "_rust_install_hash_failure() {" in text
        else 'rustup_init="$(mktemp'
    )
    return prefix + text[start : text.index("rustc --version", start)]


def receipt(scripts, caller, stage, context, digest, versions=None, installed=False):
    with tempfile.TemporaryDirectory(prefix="ant-installer-receipt-") as directory:
        work = Path(directory)
        if versions is not None:
            (work / "core").mkdir()
            (work / "core/versions.env").write_text(versions)
        env = dict(
            os.environ,
            HOME="/fixture home",
            WORK=directory,
            _MODULE_DIR=str(work / "core"),
            UV_INSTALL_SH_SHA256=digest,
            UV_PRESENT="1" if installed else "0",
            RUSTUP_INIT_SHA256=digest,
            RUST_VERSION="1 fixture",
            TEMP_STATUS="0",
            CURL_STATUS="0",
            HASH_STATUS="0",
            SH_STATUS="0",
            RM_STATUS="0",
            TRACE=str(work / "trace"),
            STATE=str(work / "state"),
        )
        if stage != "success":
            env[
                {
                    "temp": "TEMP_STATUS",
                    "curl": "CURL_STATUS",
                    "hash": "HASH_STATUS",
                    "sh": "SH_STATUS",
                    "rm": "RM_STATUS",
                }[stage]
            ] = "23"
        body = installer_code(scripts, caller)
        driver = "set -euo pipefail\n" + STUB + "\n"
        if context == "conditional":
            driver += (
                "test_case() {\n"
                + body
                + "\n}\nif test_case; then echo STATUS:0; else echo STATUS:$?; fi\n"
            )
        else:
            driver += body
        process = subprocess.run(
            ["bash", "-c", driver],
            env=env,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        normalize = lambda value: value.replace(directory, "WORK")
        return {
            "rc": process.returncode,
            "out": normalize(process.stdout),
            "err": normalize(process.stderr),
            "trace": normalize((work / "trace").read_text())
            if (work / "trace").exists()
            else "",
            "state": normalize((work / "state").read_text())
            if (work / "state").exists()
            else "",
            "remaining": (work / "fixture path").read_text()
            if (work / "fixture path").exists()
            else None,
        }


def capture(scripts):
    return {
        f"{caller}:{stage}:{context}:{digest}": receipt(
            scripts, caller, stage, context, digest
        )
        for caller in ("uv", "rust")
        for stage in ("success", "temp", "curl", "hash", "sh", "rm")
        for context in ("strict", "conditional")
        for digest in ("pin", "")
    }


def import_receipt(caller, content, conditional, retry=False):
    with tempfile.TemporaryDirectory(prefix="ant-installer-import-") as directory:
        work = Path(directory)
        core = work / "core"
        core.mkdir()
        for leaf in ("logging.sh", "python-probe.sh", "load-versions-env.sh"):
            (core / leaf).write_text((SCRIPTS / "01-core" / leaf).read_text())
        companion = core / "verified-script-install.sh"
        if content is not None:
            companion.write_text(content)
        text = (
            SCRIPTS
            / (
                "01-core/python_uv.sh"
                if caller == "uv"
                else "02-toolchain/install-rust.sh"
            )
        ).read_text()
        if caller == "rust":
            text = text[: text.index("_rust_install_hash_failure() {")]
            text = text.replace("/opt/scripts/core", str(core))
            text = "rust_target_triple_for_arch() { printf fixture; }\n" + text
        subject = core / "subject.sh"
        subject.write_text(text)
        command = (
            "set -euo pipefail; export DEFAULT_PYTHON_VERSION=3.15 TARGETARCH=amd64; "
        )
        if conditional:
            command += 'status=0; if source "$1"; then :; else status=$?; fi; printf "STATUS:%s LOADED:%s\\n" "$status" "${_PYTHON_UV_LOADED-}"; '
        else:
            command += 'source "$1"; printf LOADED; '
        if retry:
            command += 'cp "$2" "$3"; source "$1"; declare -F verified_script_install >/dev/null; printf RETRIED; '
        result = subprocess.run(
            [
                "bash",
                "-c",
                command,
                "_",
                str(subject),
                str(SCRIPTS / "01-core/verified-script-install.sh"),
                str(companion),
            ],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        return (
            result.returncode,
            result.stdout,
            result.stderr.replace(directory, "WORK"),
        )


class VerifiedInstallers(unittest.TestCase):
    def test_original_lifecycle_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("verified-installer-receipts.json").read_text()
        )
        self.assertEqual(48, len(expected))
        actual = capture(SCRIPTS)
        for name, value in expected.items():
            with self.subTest(case=name):
                self.assertEqual(value, actual[name])

    def test_independent_failure_policies(self):
        actual = capture(SCRIPTS)
        self.assertEqual(23, actual["uv:curl:strict:pin"]["rc"])
        self.assertEqual("partial", actual["uv:curl:strict:pin"]["remaining"])
        self.assertIsNone(actual["uv:success:strict:pin"]["remaining"])
        self.assertEqual(1, actual["rust:hash:conditional:pin"]["rc"])
        self.assertNotIn("sha256sum", actual["rust:hash:strict:"]["trace"])
        self.assertIn(
            "-y\n--profile\nminimal\n--default-toolchain\n1 fixture",
            actual["rust:success:strict:pin"]["trace"],
        )
        self.assertNotIn("--profile", actual["uv:success:strict:pin"]["trace"])
        self.assertIn(
            'rustup_init="WORK/fixture path"',
            actual["rust:success:strict:pin"]["state"],
        )
        self.assertEqual("", actual["uv:success:strict:pin"]["state"])

    def test_uv_override_and_discovery(self):
        versions = "UV_INSTALL_SH_SHA256=file pin\n"
        from_file = receipt(SCRIPTS, "uv", "success", "strict", "", versions=versions)
        overridden = receipt(
            SCRIPTS, "uv", "success", "strict", "operator pin", versions=versions
        )
        installed = receipt(SCRIPTS, "uv", "success", "strict", "", installed=True)
        self.assertIn("file pin  WORK/fixture path\n", from_file["trace"])
        self.assertIn("operator pin  WORK/fixture path\n", overridden["trace"])
        self.assertNotIn("file pin", overridden["trace"])
        self.assertEqual("", installed["trace"])
        self.assertEqual("uv version: uv-fixture\n", installed["out"])

    def test_cold_copied_imports(self):
        valid = (SCRIPTS / "01-core/verified-script-install.sh").read_text()
        variants = [
            ("missing", None, 1),
            ("empty", "", 1),
            ("partial", "verified_script_install() { :; }\nreturn 23\n", 23),
            ("parse", "verified_script_install() { :; }\nif\n", 2),
            ("valid", valid, 0),
        ]
        for caller in ("uv", "rust"):
            for label, body, status in variants:
                for conditional in (False, True):
                    with self.subTest(
                        caller=caller, variant=label, conditional=conditional
                    ):
                        self.assert_import(caller, label, body, status, conditional)
        rc, out, _ = import_receipt("uv", "return 23\n", True, retry=True)
        self.assertEqual(0, rc)
        self.assertIn("STATUS:23 LOADED:\n", out)
        self.assertIn("RETRIED", out)

    def assert_import(self, caller, label, body, status, conditional):
        rc, out, err = import_receipt(caller, body, conditional)
        expected_rc = 0 if caller == "uv" and conditional else status
        self.assertEqual(expected_rc, rc)
        if caller == "uv" and conditional:
            self.assertIn(f"STATUS:{status} LOADED:{'1' if status == 0 else ''}\n", out)
        if label == "empty":
            self.assertIn(
                "requires verified_script_install from verified-script-install.sh", err
            )

    def test_rust_docker_closure(self):
        docker = (ROOT / "linux/Dockerfile.toolchain").read_text().replace("\\\n", " ")
        runs = [
            line
            for line in docker.splitlines()
            if line.startswith("RUN ")
            and "bash /opt/scripts/toolchain/install-rust.sh" in line
        ]
        self.assertEqual(1, len(runs))
        self.assertIn(
            "--mount=type=bind,source=linux/scripts/01-core/verified-script-install.sh,target=/opt/scripts/core/verified-script-install.sh,ro",
            runs[0],
        )


if __name__ == "__main__":
    unittest.main()
