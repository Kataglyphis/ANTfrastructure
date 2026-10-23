#!/usr/bin/env python3
"""Offline argument receipts preserve individual inspect and registry failure policies, not container or registry behavior."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CORE = Path(sys.argv.pop(1)).resolve()
REFERENCE = "registry.example:5443/repo with spaces:tag"
TOOL = """#!/usr/bin/env bash
printf 'tool:%s\\n' "${0##*/}" >> "$CALLS"
printf 'arg:%s\\n' "$@" >> "$CALLS"
printf 'TOOL_STDERR\\n' >&2
if [ "$PAYLOAD" = valid ]; then
  printf '{"Descriptor":{"digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}}\\n'
else
  printf 'not JSON\\n'
fi
exit "$TOOL_STATUS"
"""
CALLER = """mode="$1"; library="$2"; function_name="$3"; conditional="$4"; shift 4
case "$mode" in strict) set -euo pipefail ;; relaxed) set +eu; set +o pipefail ;; pipefail) set -uo pipefail; set +e ;; esac
unset _BUILD_HELPERS_LOADED _DIGEST_PINNING_SH_LOADED _ELF_STRIP_LOADED _IMAGE_REF_ARGS_SH_LOADED
source "$library"
if [ "$conditional" = yes ]; then
  if "$function_name" "$@"; then status=0; else status=$?; fi
  exit "$status"
fi
"$function_name" "$@"
"""
CASES = [
    ("default", {}),
    ("empty-default", {"override": ""}),
    ("override", {"override": "override"}),
    ("explicit", {"args": "explicit", "override": "override"}),
    ("extras", {"args": "extras"}),
    ("empty-reference", {"args": "empty-reference"}),
    ("strict-zero", {"args": "zero"}),
    ("relaxed-zero", {"args": "zero", "mode": "relaxed"}),
    ("explicit-empty-tool", {"args": "empty-tool", "mode": "relaxed"}),
    ("command-is-not-argv", {"override": "command-string", "mode": "relaxed"}),
    ("strict-tool-failure", {"tool_status": 17}),
    ("conditional-tool-failure", {"tool_status": 17, "conditional": True}),
    ("relaxed-tool-failure", {"tool_status": 17, "mode": "relaxed"}),
    ("pipefail-tool-failure", {"tool_status": 17, "mode": "pipefail"}),
    ("strict-invalid", {"payload": "invalid"}),
    ("conditional-invalid", {"payload": "invalid", "conditional": True}),
    ("relaxed-invalid", {"payload": "invalid", "mode": "relaxed"}),
]


def normalize(text, root):
    text = text.replace(str(root), "ROOT")
    return re.sub(r"^.*?: line \d+:", "SOURCE: line @LINE@:", text, flags=re.MULTILINE)


def run_case(core, api, config):
    with tempfile.TemporaryDirectory(prefix="ant-image-cli-") as directory:
        root = Path(directory)
        bundle = root / "copied core"
        bundle.mkdir()
        for name in (
            "build-helpers.sh",
            "digest-pinning.sh",
            "elf-strip.sh",
            "registry-digest.py",
            "image-ref-args.sh",
        ):
            if (core / name).is_file():
                shutil.copy2(core / name, bundle / name)
        tools = root / "tools with spaces"
        tools.mkdir()
        for name in ("nerdctl", "explicit tool", "override tool"):
            tool = tools / name
            tool.write_text(TOOL)
            tool.chmod(0o755)
        temporary = root / "temporary"
        temporary.mkdir()
        calls = root / "calls"
        env = dict(
            os.environ,
            PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
            TMPDIR=str(temporary),
            CALLS=str(calls),
            PAYLOAD=config.get("payload", "valid"),
            TOOL_STATUS=str(config.get("tool_status", 0)),
        )
        env.pop("NERDCTL_BIN", None)
        if "override" in config:
            env["NERDCTL_BIN"] = {
                "": "",
                "override": str(tools / "override tool"),
                "command-string": "nerdctl --namespace fixture",
            }[config["override"]]
        arguments = {
            "default": [REFERENCE],
            "explicit": [str(tools / "explicit tool"), REFERENCE],
            "extras": [
                str(tools / "explicit tool"),
                REFERENCE,
                "ignored extra",
                "last",
            ],
            "empty-reference": [""],
            "zero": [],
            "empty-tool": ["", REFERENCE],
        }[config.get("args", "default")]
        library = "build-helpers.sh" if api == "image_exists" else "digest-pinning.sh"
        result = subprocess.run(
            [
                "bash",
                "-c",
                CALLER,
                "_",
                config.get("mode", "strict"),
                str(bundle / library),
                api,
                "yes" if config.get("conditional") else "no",
                *arguments,
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        return {
            "status": result.returncode,
            "stdout": normalize(result.stdout, root),
            "stderr": normalize(result.stderr, root),
            "calls": normalize(calls.read_text(), root) if calls.exists() else "",
            "temporary": sorted(
                normalize(file.read_text(), root) for file in temporary.iterdir()
            ),
        }


def receipts(core):
    return {
        f"{api}:{name}": run_case(core, api, config)
        for api in ("image_exists", "registry_pin_ref")
        for name, config in CASES
    }


class ImageRefPolicy(unittest.TestCase):
    def test_toolchain_mount_closure(self):
        dockerfile = CORE.parent.parent / "Dockerfile.toolchain"
        text = dockerfile.read_text()
        runs = re.split(r"(?m)^RUN ", text)[1:]
        builders = [
            run for run in runs if "target=/opt/scripts/core/build-helpers.sh,ro" in run
        ]
        self.assertEqual(2, len(builders))
        for run in builders:
            self.assertIn(
                "--mount=type=bind,source=linux/scripts/01-core/image-ref-args.sh,target=/opt/scripts/core/image-ref-args.sh,ro",
                run,
            )

    def test_original_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("image-ref-cli-receipts.json").read_text()
        )
        actual = receipts(CORE)
        for name, receipt in expected.items():
            with self.subTest(name=name):
                self.assertEqual(receipt, actual[name])

    def test_missing_companions_fail_during_conditional_import(self):
        for library in ("build-helpers.sh", "digest-pinning.sh"):
            with (
                self.subTest(library=library),
                tempfile.TemporaryDirectory() as temporary,
            ):
                bundle = Path(temporary)
                for name in (library, "elf-strip.sh", "registry-digest.py"):
                    shutil.copy2(CORE / name, bundle / name)
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        'if source "$1"; then exit 0; else exit 73; fi',
                        "_",
                        str(bundle / library),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=10,
                )
                self.assertEqual(1, result.returncode)
                self.assertIn("image-ref-args.sh", result.stderr)


if __name__ == "__main__":
    unittest.main()
