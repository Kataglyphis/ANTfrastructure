"""Exercise the DXGI vendor and software-adapter checks without GPU hardware."""

import contextlib
import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "diagnostics/verify-dxgi-adapter.py"
SPEC = importlib.util.spec_from_file_location("verify_dxgi_adapter", PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DxgiAdapterTest(unittest.TestCase):
    def test_vendor_and_software_flags(self) -> None:
        MODULE.require_vendor(SimpleNamespace(vendor=0x1002, flags=0), "amd")
        MODULE.require_vendor(SimpleNamespace(vendor=0x10DE, flags=0), "nvidia")
        for vendor, flags in ((0x8086, 0), (0x10DE, 0), (0x1002, 2)):
            with (
                self.subTest(vendor=vendor, flags=flags),
                self.assertRaises(ValueError),
            ):
                MODULE.require_vendor(
                    SimpleNamespace(vendor=vendor, flags=flags), "amd"
                )

    def test_cli_checks_the_requested_index(self) -> None:
        desc = SimpleNamespace(vendor=0x1002, flags=0, description="AMD fixture")
        output = io.StringIO()
        with (
            patch.object(sys, "argv", [str(PATH), "--vendor", "amd", "--index", "3"]),
            patch.object(MODULE, "describe_adapter", return_value=desc) as getter,
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(MODULE.main(), 0)
        getter.assert_called_once_with(3)
        self.assertEqual(json.loads(output.getvalue())["index"], 3)

    def test_cli_rejects_wrong_vendor(self) -> None:
        desc = SimpleNamespace(vendor=0x8086, flags=0, description="Intel fixture")
        with (
            patch.object(sys, "argv", [str(PATH), "--vendor", "amd", "--index", "0"]),
            patch.object(MODULE, "describe_adapter", return_value=desc),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(MODULE.main(), 1)


if __name__ == "__main__":
    unittest.main()
