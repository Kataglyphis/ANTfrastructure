"""Shared real-key fixtures keep every private test directory outside the source checkout."""

import shutil
import tempfile
import unittest
from pathlib import Path
from types import ModuleType


class QairtKeyFixture(unittest.TestCase):
    handoff: ModuleType

    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(prefix="qairt-key-fixture-", dir="/tmp")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.key = cls.root / "original-key"
        cls.record = cls.handoff.keygen(cls.key)

    def setUp(self) -> None:
        self.working = tempfile.TemporaryDirectory(prefix="case-", dir=self.root)
        self.addCleanup(self.working.cleanup)
        self.directory = Path(self.working.name) / "private key with spaces"
        shutil.copytree(self.key, self.directory)
