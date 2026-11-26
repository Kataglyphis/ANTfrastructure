#!/usr/bin/env python3
# Exercises NSIS member selection and extraction against a fake 7-Zip; a real setup is read only on a Windows host.
import importlib.util
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent


def load(name: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, TESTS.parent / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


license_verifier = load("verify_package_license")
binary_verifier = load("verify_package_binary")


class NsisSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.setup = self.root / "demo-x64-setup.exe"
        self.setup.write_bytes(b"MZ")
        self.members = {"$PLUGINSDIR\\System.dll": b"plugin", "app.exe": b"MZ app", "share\\LICENSE": b"MIT terms",
                        "Uninstall.exe": b"MZ un"}
        self.extra: list[str] = []
        self.dropped: set[str] = set()
        self.rogue = False
        self.calls: list[list[str]] = []
        patcher = mock.patch("subprocess.run", side_effect=self.run_7z)
        patcher.start()
        self.addCleanup(patcher.stop)

    def source(self, name: str, data: bytes) -> Path:
        path = self.root / name
        path.write_bytes(data)
        return path

    def run_7z(self, args: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        self.calls.append(args)
        if "-tNsis" not in args:
            raise AssertionError(f"an NSIS setup must be read as NSIS: {args}")
        names = args[args.index("--") + 2:]
        if args[1] == "l":
            listing = "----------\n" + "".join(f"Path = {name}\nSize = \n" for name in [*self.members, *self.extra])
            return subprocess.CompletedProcess(args, 0, stdout=listing)
        if args[1] == "x":
            output = Path(next(arg[2:] for arg in args if arg.startswith("-o")))
            for name in names:
                if name in self.dropped:
                    continue
                target = output / name.replace("\\", "/")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(self.members.get(name, b"duplicate"))
            if self.rogue:
                (output / "rogue.dll").write_bytes(b"MZ rogue")
            return subprocess.CompletedProcess(args, 0)
        raise AssertionError(args)

    def binary(self, *rules: str) -> int:
        with mock.patch("sys.argv", ["verify_package_binary.py", str(self.setup), *(f"--require={rule}" for rule in rules)]):
            return binary_verifier.main()

    def test_license_text_is_read_from_the_installed_path_only(self) -> None:
        rules = [("share/LICENSE", b"MIT terms"), ("share/*", b"MIT terms")]
        self.assertEqual([], license_verifier.check_package(self.setup, rules))
        extract = [call for call in self.calls if call[1] == "x"]
        self.assertEqual([["share\\LICENSE"]], [call[call.index("--") + 2:] for call in extract], "only the selected member is extracted")
        self.assertEqual(["share/LICENSE"], license_verifier.check_package(self.setup, [("share/LICENSE", b"GPL terms")]))

    def test_installer_internals_never_match(self) -> None:
        self.assertEqual(["*System.dll"], license_verifier.check_package(self.setup, [("*System.dll", b"plugin")]))

    def test_binary_members_match_bytes_and_case(self) -> None:
        app = self.source("app.exe", b"MZ app")
        self.assertEqual(0, self.binary(f"app.exe={app}", f"share/LICENSE={self.source('LICENSE', b'MIT terms')}"))
        self.assertEqual(1, self.binary(f"app.exe={self.source('other.exe', b'MZ other')}"))
        self.assertEqual(1, self.binary(f"APP.exe={app}"))
        self.assertEqual(1, self.binary(f"absent.dll={app}"))

    def test_duplicate_and_short_or_extra_extraction_fail(self) -> None:
        app = self.source("app.exe", b"MZ app")
        self.extra = ["APP.EXE"]
        self.assertEqual(1, self.binary(f"app.exe={app}"))
        with self.assertRaisesRegex(ValueError, "duplicate NSIS setup member"):
            license_verifier.check_package(self.setup, [("app.exe", b"MZ app")])
        self.extra = []
        for dropped, rogue in (({"app.exe"}, False), (set(), True)):
            self.dropped, self.rogue = dropped, rogue
            self.assertEqual(1, self.binary(f"app.exe={app}"))
            with self.assertRaisesRegex(ValueError, "unexpected members"):
                license_verifier.check_package(self.setup, [("app.exe", b"MZ app")])


if __name__ == "__main__":
    unittest.main()
