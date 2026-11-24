#!/usr/bin/env python3
"""Temporary fixtures prove retirement refusals, not host liveness, archive validity or caller authenticity."""

from __future__ import annotations

import copy
import importlib.util
import os
import shutil
import tempfile
import time
import unittest
from collections.abc import Callable
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "package_staging_cleanup", Path(__file__).resolve().parents[1] / "local-proof/cleanup-package-staging.py"
)
assert SPEC is not None and SPEC.loader is not None
WORKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKER)


class RetirementTests(unittest.TestCase):
    def fixture(self) -> tuple[dict[str, Any], Path, Path, Path]:
        directory = tempfile.TemporaryDirectory(prefix="package-staging-test-")
        self.addCleanup(directory.cleanup)
        base = Path(directory.name)
        root, archives = base / "staging", base / "archives"
        root.mkdir()
        archives.mkdir()
        for name in WORKER.SELECTED:
            (root / name).mkdir()
            (root / name / "payload").write_bytes(b"copied payload")
        (root / "home/.cache").mkdir(parents=True)
        (root / "home/.cache/keep").write_bytes(b"preserved cache")
        retained = []
        for suffix in (".tar.gz", ".deb", ".AppImage"):
            path = archives / ("oxidant-test" + suffix)
            path.write_bytes(b"retained archive" + suffix.encode())
            retained.append({"name": path.name, "bytes": path.stat().st_size, "sha256": WORKER.fingerprint(path)})
        token, cid = "a" * 32, "b" * 64
        unit, label = "webgpu-fixture.service", "org.kataglyphis.current-rust-packages"
        plan = {
            "schema": 1, "run_id": token, "CID": cid, "owner_label": label, "unit": unit,
            "host_staging": f"/home/fixture/gpu/run-tmp/amd-package-{token}/package-work",
            "staging_identity": [root.stat().st_dev, root.stat().st_ino],
            "closed_main_pid": 0, "closed_control_pid": 0, "cache_status": 0,
            "producer_cleanup_status": 0, "producer_status": 1, "archives": retained,
            "invocation_sha256": "c" * 64, "terminal_proof_sha256": "d" * 64,
            "observation": {
                "observed_unix": time.time(), "mount_conflicts": [], "nested_mounts": [],
                "unit": {"Id": unit, "LoadState": "not-found", "ActiveState": "inactive", "MainPID": "0", "ControlPID": "0"},
                "queries": [{"filter": value, "exit_status": 0, "stdout": "", "stderr": ""}
                            for value in ("id=" + cid, "label=" + label + "=" + token)],
            },
        }
        return plan, root, archives, base / "proof.json"

    def refused(self, change: Callable[..., Any], message: str) -> None:
        plan, root, archives, output = self.fixture()
        change(plan, root, archives, output)
        with self.assertRaisesRegex(ValueError, message):
            WORKER.execute(plan, root, archives, output)

    def test_preview_apply(self) -> None:
        plan, root, archives, output = self.fixture()
        preview = WORKER.execute(plan, root, archives, output)
        self.assertEqual(preview["status"], "preview-only")
        self.assertTrue(all((root / name).is_dir() for name in WORKER.SELECTED))
        applied = WORKER.execute(plan, root, archives, output.with_name("applied.json"), preview)
        self.assertEqual(applied["status"], "retired-copied-package-staging-only")
        self.assertEqual({p.name for p in root.iterdir()}, {"home"})
        self.assertEqual((root / "home/.cache/keep").read_bytes(), b"preserved cache")
        self.assertEqual(len(list(archives.iterdir())), 3)

    def test_observation_refusals(self) -> None:
        cases = [
            (lambda p: p["observation"].update(observed_unix=time.time() - 121), "fresh host"),
            (lambda p: p["observation"]["unit"].update(Id="other.service"), "identity differs"),
            (lambda p: p["observation"]["unit"].update(LoadState="loaded", ActiveState="active"), "must be closed"),
            (lambda p: p["observation"]["unit"].update(ControlPID="99"), "must be closed"),
            (lambda p: p["observation"].update(mount_conflicts=["writer"]), "registered or mounted"),
            (lambda p: p["observation"].update(nested_mounts=None), "registered or mounted"),
            (lambda p: p["observation"]["queries"].pop(), "exact CID"),
            (lambda p: p["observation"]["queries"][0].update(exit_status=1), "absence is unproved"),
            (lambda p: p["observation"]["queries"][1].update(stderr="unknown"), "absence is unproved"),
        ]
        for change, message in cases:
            with self.subTest(message=message):
                self.refused(lambda p, *_, selected=change: selected(p), message)

    def test_subject_refusals(self) -> None:
        cases = [
            ({"schema": 2}, "schema"), ({"run_id": "short"}, "nonce"),
            ({"CID": "short"}, "full producer CID"), ({"owner_label": "other"}, "recorded package"),
            ({"host_staging": "/other/package-work"}, "private AMD"),
            ({"closed_control_pid": 9}, "not terminal"), ({"cache_status": 1}, "incomplete producer"),
            ({"producer_cleanup_status": 1}, "incomplete producer"), ({"producer_status": False}, "raw producer"),
            ({"staging_identity": [-1, -1]}, "mount identity"),
        ]
        for values, message in cases:
            with self.subTest(values=values):
                plan, root, _archives, _ = self.fixture()
                plan.update(values)
                with self.assertRaisesRegex(ValueError, message):
                    WORKER.validate_subject(plan, root)
        self.refused(lambda p, r, *_: (r / "unknown").mkdir(), "unknown staging")
        plan, root, _, _ = self.fixture()
        linked = root.with_name("linked")
        linked.symlink_to(root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "literal staging"):
            WORKER.validate_subject(plan, linked)
        self.refused(self.replace_selected_root, "roots must be directories")

    @staticmethod
    def replace_selected_root(plan: dict[str, Any], root: Path, archives: Path, output: Path) -> None:
        shutil.rmtree(root / "deb")
        (root / "deb").write_bytes(b"not a directory")

    def test_archive_refusals(self) -> None:
        cases = [
            (lambda p, *_: p["archives"].append(copy.deepcopy(p["archives"][0])), "three distinct"),
            (lambda p, *_: p["archives"][0].update(name="../bad"), "archive name"),
            (lambda p, *_: p["archives"][0].update(bytes=0), "regular nonempty"),
            (lambda p, *_: p["archives"][0].update(sha256="0" * 64), "package bytes differ"),
            (self.replace_archive_kind, "TAR, DEB and AppImage"),
            (self.link_archive, "regular nonempty"),
        ]
        for change, message in cases:
            with self.subTest(message=message):
                self.refused(change, message)

    @staticmethod
    def replace_archive_kind(plan: dict[str, Any], root: Path, archives: Path, output: Path) -> None:
        entry = plan["archives"][-1]
        path = archives / entry["name"]
        entry["name"] = "oxidant-second.tar.gz"
        path.rename(archives / entry["name"])

    @staticmethod
    def link_archive(plan: dict[str, Any], root: Path, archives: Path, output: Path) -> None:
        path = archives / plan["archives"][0]["name"]
        real = path.with_name("real")
        path.rename(real)
        path.symlink_to(real)

    def test_tree_refusals(self) -> None:
        self.refused(lambda p, r, *_: (r / "deb/.git").mkdir(), "source or cache")
        self.refused(lambda p, r, *_: os.link(r / "deb/payload", r / "deb/copy"), "shared file")
        self.refused(lambda p, r, *_: os.mkfifo(r / "deb/pipe"), "special staging")
        self.refused(lambda p, r, *_: (r / "deb/payload").unlink(), "staging is empty")
        self.refused(lambda p, r, a, o: o.write_text("prior evidence"), "existing retirement")
        plan, root, archives, _ = self.fixture()
        with self.assertRaisesRegex(ValueError, "outside retained inputs"):
            WORKER.execute(plan, root, archives, root / "proof.json")

    def test_apply_refusals(self) -> None:
        for change in (lambda p: p.update(status="applied"), lambda p: p.update(snapshot_sha256="wrong")):
            plan, root, archives, output = self.fixture()
            preview = WORKER.execute(plan, root, archives, output)
            change(preview)
            with self.assertRaisesRegex(ValueError, "Changed or already-applied"):
                WORKER.execute(plan, root, archives, output.with_name("applied.json"), preview)
        plan, root, archives, output = self.fixture()
        preview = WORKER.execute(plan, root, archives, output)
        (root / "deb/payload").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Changed or already-applied"):
            WORKER.execute(plan, root, archives, output.with_name("changed.json"), preview)

    def test_removal_guards(self) -> None:
        for mode, message in (("unsafe", "descriptor-based"), ("changed-root", "root changed"),
                              ("noop", "removal is incomplete"), ("home", "private cache changed")):
            with self.subTest(mode=mode):
                self.removal_refusal(mode, message)

    def removal_refusal(self, mode: str, message: str) -> None:
        plan, root, archives, output = self.fixture()
        preview = WORKER.execute(plan, root, archives, output)
        remover, fstat = shutil.rmtree, os.fstat
        def remove(*args: Any, selected: str = mode, **kwargs: Any) -> None:
            if selected != "noop":
                remover(args[0], dir_fd=kwargs.get("dir_fd"))
            if selected == "home":
                (root / "home/.cache/keep").write_bytes(b"changed cache")
        replacement = mock.Mock(side_effect=remove, avoids_symlink_attacks=mode != "unsafe")
        calls = []
        def identity(fd: int, selected: str = mode) -> Any:
            current = fstat(fd)
            calls.append(fd)
            if selected == "changed-root" and len(calls) == 1:
                return SimpleNamespace(st_dev=-1, st_ino=-1)
            return current
        with (
            mock.patch.object(WORKER.shutil, "rmtree", replacement),
            mock.patch.object(WORKER.os, "fstat", identity),
            self.assertRaisesRegex(ValueError, message),
        ):
            WORKER.execute(plan, root, archives, output.with_name("applied.json"), preview)



if __name__ == "__main__":
    unittest.main()
