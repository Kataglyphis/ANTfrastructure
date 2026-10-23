#!/usr/bin/env python3
"""Offline byte fixtures cover manifest order and failure policies, not wheel validity or image builds."""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
SOURCE = Path(sys.argv.pop(1)).resolve()
DRIVER = r"""set -Eeuo pipefail
source "$1/tests/test-harness.sh"
source "$2/lib-runtime-wheels.sh"
eval "$(t_fn_src "$2/06-packaging/setup-torch-venv.sh" _stv_wheelhouse_line)"
for tool in find sort xargs sha256sum awk; do
  eval "$tool() { command $tool \"\$@\"; if [ \"\$FAIL\" = $tool ]; then return 17; fi; }"
done
if [ "$CONTEXT" = conditional ]; then
  if "$API" "$WHEELS"; then exit 0; else exit "$?"; fi
fi
"$API" "$WHEELS"
"""
PAYLOADS = {"z wheel.whl": b"z\0binary", "a.whl": b"a", "sub/middle.whl": b"middle"}


def capture(source):
    result = {}
    with tempfile.TemporaryDirectory(prefix="ant-wheel-manifest-") as temporary:
        root = Path(temporary)
        wheels = root / "wheels"
        for name, payload in PAYLOADS.items():
            path = wheels / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        (wheels / "ignored symlink").symlink_to(wheels / "a.whl")
        for api in (
            "_runtime_wheels_manifest",
            "runtime_wheels_digest_line",
            "_stv_wheelhouse_line",
        ):
            for failure in (
                "none",
                "find",
                "sort",
                "xargs",
                "sha256sum",
                "awk",
                "absent",
            ):
                for context in ("strict", "conditional"):
                    env = dict(
                        os.environ,
                        API=api,
                        FAIL=failure,
                        CONTEXT=context,
                        WHEELS=str(root / "absent" if failure == "absent" else wheels),
                    )
                    probe = subprocess.run(
                        ["bash", "-c", DRIVER, "_", str(SCRIPTS), str(source)],
                        env=env,
                        capture_output=True,
                        text=True,
                        check=False,
                        timeout=10,
                    )
                    result[f"{api}:{failure}:{context}"] = {
                        "status": probe.returncode,
                        "stdout": probe.stdout.replace(str(root), "WORK"),
                        "stderr": re.sub(
                            r"SOURCE/[^:\n]+: line \d+:",
                            "SOURCE: line @LINE@:",
                            probe.stderr.replace(str(root), "WORK").replace(
                                str(source), "SOURCE"
                            ),
                        ),
                    }
    return result


class ManifestContracts(unittest.TestCase):
    def test_original_failure_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("wheelhouse-manifest-receipts.json").read_text()
        )
        actual = capture(SOURCE)
        for case, receipt in expected.items():
            with self.subTest(case=case):
                self.assertEqual(receipt, actual[case])

    def test_missing_companion_imports(self):
        with tempfile.TemporaryDirectory(prefix="ant-wheel-import-") as temporary:
            root = Path(temporary)
            library = root / "lib-runtime-wheels.sh"
            library.write_bytes((SOURCE / library.name).read_bytes())
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'if source "$1"; then exit 0; else exit 73; fi',
                    "_",
                    str(library),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(1, result.returncode)
            self.assertIn("wheelhouse-manifest.sh", result.stderr)
            core = root / "core"
            core.mkdir()
            (core / "module-bootstrap.sh").write_bytes(
                (SOURCE / "01-core/module-bootstrap.sh").read_bytes()
            )
            (core / "platform.sh").write_text("elf_unresolved_needed() { :; }\n")
            package = root / "package-image-wiring.sh"
            package.write_bytes(
                (SOURCE / "06-packaging/package-image-wiring.sh").read_bytes()
            )
            text = (SOURCE / "06-packaging/setup-torch-venv.sh").read_text()
            bootstrap = text[
                text.index("# Hard-require platform.sh") : text.index("\ncross_skip()")
            ]
            bootstrap = bootstrap.replace(
                "/opt/scripts/core/", str(core) + "/"
            ).replace("/opt/scripts/packaging/package-image-wiring.sh", str(package))
            child = root / "torch.sh"
            child.write_text(bootstrap + "\necho completed\n")
            result = subprocess.run(
                ["bash", "-euo", "pipefail", str(child)],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(1, result.returncode)
            self.assertIn("FATAL: wheelhouse-manifest.sh", result.stderr)
            self.assertNotIn("completed", result.stdout)

    def test_docker_companion_copy(self):
        text = (SOURCE.parent / "Dockerfile.torch").read_text()
        copy = "COPY --chmod=755 linux/scripts/01-core/wheelhouse-manifest.sh /opt/scripts/core/wheelhouse-manifest.sh"
        self.assertEqual(1, text.count(copy))
        self.assertLess(
            text.index(copy),
            text.index("bash /opt/scripts/packaging/setup-torch-venv.sh"),
        )

    def test_independent_byte_manifest(self):
        manifest = "".join(
            f"{hashlib.sha256(payload).hexdigest()}  ./{name}\n"
            for name, payload in sorted(PAYLOADS.items())
        )
        expected = (
            f"files=3 bytes=15 sha256={hashlib.sha256(manifest.encode()).hexdigest()}"
        )
        actual = capture(SOURCE)
        self.assertEqual(
            manifest, actual["_runtime_wheels_manifest:none:strict"]["stdout"]
        )
        self.assertEqual(
            expected, actual["runtime_wheels_digest_line:none:strict"]["stdout"]
        )
        self.assertEqual(
            f"[torch-venv] wheelhouse {expected}\n",
            actual["_stv_wheelhouse_line:none:strict"]["stdout"],
        )


if __name__ == "__main__":
    unittest.main()
