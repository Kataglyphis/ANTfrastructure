#!/usr/bin/env python3
# Exercises selected CAB extraction, not real MSI database or 7-Zip implementations.
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import BinaryIO, cast
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "verify_package_license.py"
spec = importlib.util.spec_from_file_location("license_verifier", SCRIPT)
assert spec is not None and spec.loader is not None
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class MsiBatchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.package = Path(self.temp.name) / "test.msi"
        self.package.touch()
        self.members = {"one.cab": {"f1": b"License one", "f2": b"License two"},
                        "two.cab": {"f3": b"License three"}}
        self.extra = {}
        self.extractions = []
        self.patcher = mock.patch.object(verifier.subprocess, "run", side_effect=self.run_7z)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def run_7z(self, args: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        operation = args[1]
        if operation == "l":
            archive = Path(args[-1])
            if archive == self.package:
                records = [(name, 0) for name in self.members]
            else:
                cabinet = archive.read_text()
                records = [(name, len(data)) for name, data in self.members[cabinet].items()]
                records += self.extra.get(cabinet, [])
            listing = "----------\n" + "\n".join(f"Path = {name}\nSize = {size}\n" for name, size in records)
            return subprocess.CompletedProcess(args, 0, stdout=listing)
        if operation == "e":
            cast(BinaryIO, kwargs["stdout"]).write(args[-1].encode())
            return subprocess.CompletedProcess(args, 0)
        if operation == "x":
            index = args.index("--")
            cabinet = Path(args[index + 1]).read_text()
            names = args[index + 2:]
            output = Path(next(arg[2:] for arg in args if arg.startswith("-o")))
            self.extractions.append((cabinet, names))
            for name in names:
                (output / name).write_bytes(self.members[cabinet][name])
            return subprocess.CompletedProcess(args, 0)
        raise AssertionError(args)

    def test_multi_cabinet_batch_and_glob(self) -> None:
        rules = [("one.cab::f1", b"License one"), ("one.cab::f2", b"License two"),
                 ("two.cab::f*", b"License three")]
        self.assertEqual([], verifier.check_package(self.package, rules))
        self.assertEqual([("one.cab", ["f1", "f2"]), ("two.cab", ["f3"])], self.extractions)

    def test_missing_and_tampered(self) -> None:
        rules = [("one.cab::f1", b"License one"), ("one.cab::f2", b"different"),
                 ("two.cab::missing", b"absent")]
        self.assertEqual(["one.cab::f2", "two.cab::missing"], verifier.check_package(self.package, rules))

    def test_duplicate_alias_and_oversized_rejected(self) -> None:
        for extra in [[("f1", 11)], [("F1", 11)], [("./f1", 11)], [("dir/f1", 11)], [("f4", verifier.MAX_LICENSE_BYTES + 1)]]:
            with self.subTest(extra=extra):
                self.extra = {"one.cab": extra}
                with self.assertRaises(ValueError):
                    verifier.check_package(self.package, [("one.cab::*", b"License one")])

    def test_adjacent_member_records_are_not_collapsed(self) -> None:
        listing = "----------\nPath = f1\nSize = 11\nPath = f1\nSize = 12\nPath = f2\n"
        with mock.patch.object(verifier.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=listing)):
            self.assertEqual([("f1", 11), ("f1", 12), ("f2", None)], verifier.sevenzip_member_records(self.package))


if __name__ == "__main__":
    unittest.main()
