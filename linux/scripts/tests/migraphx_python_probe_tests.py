"""Loader/GIL/byte controls use explicit module doubles; actual compiled binding evidence is a separate image run."""

import hashlib
import json
import platform
import runpy
import sys
import sysconfig
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]


class MigraphxPythonProbeTests(unittest.TestCase):
    """The imported result must retain the selected interpreter, ABI, origin, bytes and GIL state."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="Python binding verdict ")
        self.addCleanup(temporary.cleanup)
        self.build = Path(temporary.name)
        self.binary = self.build / ("migraphx_python_probe" + sysconfig.get_config_var("EXT_SUFFIX"))
        self.binary.write_bytes(b"explicit module double data")
        self.file = self.build / "module-file.txt"
        self.file.write_text(str(self.binary) + "\n")
        script = ROOT / "linux/scripts/03-media/build/migraphx/run-python-probe.py"
        self.run_probe = runpy.run_path(str(script))["run"]
        self.module = SimpleNamespace(__file__=str(self.binary), constant_value=mock.Mock(return_value=42))
        self.loader = mock.Mock()
        self.spec = SimpleNamespace(loader=self.loader)
        util = self.run_probe.__globals__["importlib"].util
        for name, value in [("spec_from_file_location", self.spec), ("module_from_spec", self.module)]:
            patcher = mock.patch.object(util, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def probe(self) -> dict[str, object]:
        return self.run_probe(self.build, platform.python_version())

    def test_selected_module_value_origin_and_hash_are_observed(self) -> None:
        result = self.probe()
        self.assertEqual(result["status"], "passed-tiny-native-Python-binding-only")
        self.assertEqual(result["module"], str(self.binary))
        self.assertEqual(result["module_sha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertEqual(result["extension_suffix"], sysconfig.get_config_var("EXT_SUFFIX"))
        self.loader.exec_module.assert_called_once_with(self.module)
        self.module.constant_value.assert_called_once_with()
        json.dumps(result)

    def test_wrong_interpreter_ABI_or_outside_module_refuses_before_load(self) -> None:
        with self.assertRaises(ValueError):
            self.run_probe(self.build, "0.0.0")
        self.file.write_text(str(self.build / "migraphx_python_probe.foreign.so"))
        (self.build / "migraphx_python_probe.foreign.so").write_bytes(b"foreign module")
        with self.assertRaises(ValueError):
            self.probe()
        with tempfile.TemporaryDirectory(prefix="foreign binding ") as temporary:
            outside = Path(temporary) / self.binary.name
            outside.write_bytes(b"outside module")
            self.file.write_text(str(outside))
            with self.assertRaises(ValueError):
                self.probe()
        self.loader.exec_module.assert_not_called()

    def test_wrong_return_or_module_origin_cannot_pass(self) -> None:
        self.module.constant_value.return_value = 41
        with self.assertRaises(ValueError):
            self.probe()
        self.module.constant_value.return_value = 42
        for origin in [str(self.build / "other module"), None]:
            self.module.__file__ = origin
            with self.assertRaises(ValueError):
                self.probe()

    def test_changed_native_bytes_cannot_pass(self) -> None:
        def change(_module: object) -> None:
            self.binary.write_bytes(b"changed after native load")
        self.loader.exec_module.side_effect = change
        with self.assertRaises(ValueError):
            self.probe()

    def test_disabled_GIL_remains_disabled_and_reenable_is_fatal(self) -> None:
        with mock.patch.object(sys, "_is_gil_enabled", side_effect=[False, False], create=True):
            result = self.probe()
        self.assertFalse(result["gil_enabled_before"])
        self.assertFalse(result["gil_enabled_after"])
        with mock.patch.object(sys, "_is_gil_enabled", side_effect=[False, True], create=True), self.assertRaises(ValueError):
            self.probe()

    def test_missing_loader_or_native_import_error_never_passes(self) -> None:
        util = self.run_probe.__globals__["importlib"].util
        with mock.patch.object(util, "spec_from_file_location", return_value=None), self.assertRaises(ValueError):
            self.probe()
        self.spec.loader = None
        with self.assertRaises(ValueError):
            self.probe()
        self.spec.loader = self.loader
        self.loader.exec_module.side_effect = RuntimeError("raw native load failure")
        with self.assertRaisesRegex(RuntimeError, "raw native load failure"):
            self.probe()


if __name__ == "__main__":
    unittest.main()
