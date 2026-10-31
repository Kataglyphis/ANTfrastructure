"""Exercise scope validation and output publication without GitHub Actions."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "gpu_invocation_scope.py"


class ScopeTest(unittest.TestCase):
    def invoke(
        self, output: Path, scope: str | None, *args: str
    ) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "GITHUB_OUTPUT": str(output)}
        env.pop("GPU_INVOCATION_SCOPE", None)
        if scope is not None:
            env["GPU_INVOCATION_SCOPE"] = scope
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_valid_scopes_append_only_the_expected_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / "output"
            for scope, expected in (
                (None, ""),
                ("default", ""),
                ("one", "-scope-one"),
                ("all-2", "-scope-all-2"),
                ("a" * 32, "-scope-" + "a" * 32),
            ):
                with self.subTest(scope=scope):
                    output.write_text("prior=value\n", encoding="utf-8")
                    result = self.invoke(output, scope)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        output.read_text(encoding="utf-8"),
                        f"prior=value\nsuffix={expected}\n",
                    )

    def test_invalid_scopes_never_open_or_change_output(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / "output"
            for scope in (
                "",
                "A",
                "-a",
                "0",
                "a" * 33,
                "a/b",
                "a_b",
                "a\nname=bad",
                "é",
                "a ",
            ):
                with self.subTest(scope=scope):
                    output.unlink(missing_ok=True)
                    result = self.invoke(output, scope)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())
                    output.write_text("preserve\n", encoding="utf-8")
                    self.assertNotEqual(self.invoke(output, scope).returncode, 0)
                    self.assertEqual(output.read_text(encoding="utf-8"), "preserve\n")

    def test_extra_arguments_and_unwritable_output_fail(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / "output"
            self.assertNotEqual(self.invoke(output, "valid", "extra").returncode, 0)
            self.assertFalse(output.exists())
            self.assertNotEqual(self.invoke(Path(work), "valid").returncode, 0)
        env = {**os.environ, "GPU_INVOCATION_SCOPE": "valid"}
        env.pop("GITHUB_OUTPUT", None)
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
