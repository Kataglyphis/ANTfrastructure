"""Trusted-profile replay doubles cover selection and transport; no actual unit or image is launched here."""

import argparse
import copy
import json
import runpy
import shlex
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import TypedDict
from unittest import mock


class SourceProofTemplate(TypedDict):
    """The local replay fixture retains separate text metadata and command argument types."""

    unit: str
    source: str
    run_id: str
    owner_label: str
    command: list[str]


class MigraphxSourceLauncherTests(unittest.TestCase):
    """A replay keeps the reviewed profile while selecting current recipe definitions by immutable IDs."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="source launcher ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        script = Path(__file__).resolve().parents[1] / "launch-migraphx-source-check.py"
        with mock.patch("sys.path", [str(script.parent), *sys.path]):
            self.api = runpy.run_path(str(script))
        self.globals = self.api["run"].__globals__
        self.old = self.root / "old proof"
        self.old_source = self.old / "source"
        self.template: SourceProofTemplate = {
            "unit": "old-proof.service", "source": str(self.old_source),
            "run_id": "a" * 32, "owner_label": "org.kataglyphis.migraphx-source",
            "command": [
                "systemd-run", "--user", "--no-block", "--expand-environment=no", "--unit=old-proof.service",
                "-p", "Type=oneshot", "-p", "RemainAfterExit=yes", "-p", "TimeoutStartSec=1200",
                "-p", "TimeoutStopSec=300",
                "-p", "ExecStopPost=" + shlex.join([
                    "python3", str(self.old_source / "linux/scripts/cleanup-owned-containers.py"),
                    "--owner-label", "org.kataglyphis.migraphx-source", "--run-id", "a" * 32,
                    "--cidfile", str(self.old / "container.cid")]),
                "nerdctl", "run", "--network", "none", "--pull", "never", "--init", "--security-opt",
                "apparmor=unconfined", "--cpus", "4", "--memory", "8g", "--user", "0:0",
                "--label", "org.kataglyphis.migraphx-source=" + "a" * 32,
                "-v", str(self.old_source) + ":/workspace", "/bin/bash", self.api["WORKER"],
            ],
        }

    def test_replay_relocates_once_and_keeps_cleanup_argv_boundaries(self) -> None:
        original = copy.deepcopy(self.template)
        output = self.root / "old-proof's new proof"
        command = self.api["replay_command"](self.template, output, "old-proof-again.service", "b" * 32)
        self.assertEqual(self.template, original)
        self.assertIn("--unit=old-proof-again.service", command)
        self.assertNotIn("--unit=old-proof-again-again.service", command)
        cleanup = shlex.split(next(value.split("=", 1)[1] for value in command if value.startswith("ExecStopPost=")))
        self.assertEqual(cleanup[1], str(output / "source/linux/scripts/cleanup-owned-containers.py"))
        self.assertEqual(cleanup[cleanup.index("--cidfile") + 1], str(output / "container.cid"))
        self.assertEqual(cleanup[cleanup.index("--run-id") + 1], "b" * 32)
        self.assertIn(str(output / "source") + ":/workspace", command)

    def test_changed_profile_owner_worker_or_bounds_refuse(self) -> None:
        cases = []
        item = copy.deepcopy(self.template)
        item["owner_label"] = "org.kataglyphis.foreign"
        cases.append(item)
        for value in ["--no-block", "Type=oneshot", "RemainAfterExit=yes", "TimeoutStartSec=1200",
                      "TimeoutStopSec=300", "--expand-environment=no", "--init"]:
            item = copy.deepcopy(self.template)
            item["command"].remove(value)
            cases.append(item)
        for flag in ["--network", "--pull", "--security-opt", "--cpus", "--memory", "--user"]:
            item = copy.deepcopy(self.template)
            item["command"][item["command"].index(flag, item["command"].index("run") + 1) + 1] = "changed"
            cases.append(item)
        item = copy.deepcopy(self.template)
        item["command"][-1] = "/different/worker.sh"
        cases.append(item)
        item = copy.deepcopy(self.template)
        item["command"].insert(-1, "--entrypoint")
        cases.append(item)
        for item in cases:
            with self.subTest(template=item), self.assertRaises(ValueError):
                self.api["replay_command"](item, self.root / "new proof", "new-proof.service", "b" * 32)

    def prepare_selection(self) -> tuple[Path, Path, Path]:
        source = self.root / "selected source"
        directory = source / "docs/scripts"
        directory.mkdir(parents=True)
        registry = [{"id": "one", "test": "current test"}, {"id": "two", "test": "second test"}]
        (directory / "mutations.json").write_text(json.dumps(registry))
        first = self.root / "first.json"
        second = self.root / "second.json"
        first.write_text(json.dumps([{"id": "one", "test": "obsolete test"}]))
        second.write_text(json.dumps([{"id": "one"}, {"id": "two"}]))
        return source, first, second

    def test_selection_uses_current_registry_and_deduplicates_across_inputs(self) -> None:
        source, first, second = self.prepare_selection()
        selected = self.api["selected_recipes"](source, [first, second])
        self.assertEqual(selected, [{"id": "one", "test": "current test"}, {"id": "two", "test": "second test"}])

    def test_empty_unknown_or_internally_duplicated_selection_refuses(self) -> None:
        source, first, second = self.prepare_selection()
        for values in [[], [{"id": "absent"}], [{"id": "one"}, {"id": "one"}]]:
            first.write_text(json.dumps(values))
            with self.assertRaises(ValueError):
                self.api["selected_recipes"](source, [first, second])
        registry = source / "docs/scripts/mutations.json"
        entries = json.loads(registry.read_text())
        registry.write_text(json.dumps(entries + [entries[0]]))
        with self.assertRaises(ValueError):
            self.api["selected_recipes"](source, [second])

    def main_doubles(self, state: str = "not-found", changed_lock: bool = False) -> tuple[argparse.Namespace, mock.Mock, mock.Mock]:
        source, first, _second = self.prepare_selection()
        for relative in self.api["LOCKS"]:
            path = self.old_source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("locked\n")
        (self.old_source / "quality/.venv").mkdir()
        (self.old_source / "quality/.venv/preserved").write_text("venv")
        template = self.root / "template.json"
        template.write_text(json.dumps(self.template))
        args = argparse.Namespace(template=template, output=self.root / "new proof",
                                  unit="new-proof.service", manifest=[first])
        def freeze(output: Path) -> tuple[Path, str, bytes]:
            output.mkdir()
            result = output / "source"
            (result / "docs/scripts").mkdir(parents=True)
            (result / "docs/scripts/mutations.json").write_bytes((source / "docs/scripts/mutations.json").read_bytes())
            for relative in self.api["LOCKS"]:
                path = result / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("changed\n" if changed_lock else "locked\n")
            return result, "c" * 40, b"exact staged patch"
        freezer = mock.Mock(side_effect=freeze)
        launch = mock.Mock(return_value=37)
        patcher = mock.patch.dict(self.globals, {
            "checked_output": mock.Mock(return_value=state),
            "runpy": SimpleNamespace(run_path=mock.Mock(return_value={"freeze_owner_source": freezer})),
            "run_logged": launch,
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        return args, freezer, launch

    def test_busy_unit_and_changed_tool_locks_cannot_launch(self) -> None:
        args, freezer, launch = self.main_doubles(state="loaded")
        with self.assertRaises(ValueError):
            self.api["run"](args)
        freezer.assert_not_called()
        launch.assert_not_called()
        self.globals["checked_output"].return_value = "not-found"
        changed = {"relative": ""}
        def freeze_changed(output: Path) -> tuple[Path, str, bytes]:
            output.mkdir()
            result = output / "source"
            (result / "docs/scripts").mkdir(parents=True)
            (result / "docs/scripts/mutations.json").write_text(json.dumps([{"id": "one", "test": "current"}]))
            for relative in self.api["LOCKS"]:
                path = result / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("foreign tool lock" if relative == changed["relative"] else "locked\n")
            return result, "c" * 40, b"patch"
        freezer.side_effect = freeze_changed
        for index, relative in enumerate(self.api["LOCKS"]):
            changed["relative"] = relative
            args.output = self.root / ("changed lock proof " + str(index))
            with self.assertRaisesRegex(ValueError, "lock changed"):
                self.api["run"](args)
            launch.assert_not_called()

    def test_raw_launch_status_and_current_selected_receipt_are_preserved(self) -> None:
        args, _freezer, launch = self.main_doubles()
        self.assertEqual(self.api["run"](args), 37)
        record = json.loads((args.output / "invocation.json").read_text())
        self.assertEqual(record["head"], "c" * 40)
        self.assertEqual(record["selected_mutations"], 1)
        self.assertEqual(record["command"], launch.call_args.args[0])
        self.assertEqual((args.output / "source/quality/.venv/preserved").read_text(), "venv")
        self.assertEqual(json.loads((args.output / "selected-mutations.json").read_text()),
                         [{"id": "one", "test": "current test"}])


if __name__ == "__main__":
    unittest.main()
