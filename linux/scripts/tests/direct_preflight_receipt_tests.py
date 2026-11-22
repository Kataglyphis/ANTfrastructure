"""Real local Git and synthetic closed-run evidence test refusals; no live service, image or actual full preflight is exercised."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import TypedDict
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("direct_receipt", HERE.parent / "local-proof/complete-direct-preflight.py")
assert SPEC is not None and SPEC.loader is not None
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class Invocation(TypedDict):
    source: str
    source_selection: str
    source_base: str
    source_index_sha256: str
    source_patch_sha256: str
    unit: str
    run_id: str
    owner_label: str
    full_preflight: bool
    launch_status: int
    expected_default_groups: int
    expected_script_suites: int
    full_registry_count: int
    image: str
    command: list[str]


class Terminal(TypedDict):
    Id: str
    LoadState: str
    ActiveState: str
    SubState: str
    MainPID: str
    ExecMainStatus: str
    Result: str
    ExecMainExitTimestampMonotonic: str


class Seal(TypedDict):
    status: str
    unit: str
    unique_actual_mutations: int
    terminal: Terminal
    stopped: dict[str, str]
    inputs: dict[str, str]


class Cleanup(TypedDict):
    exit_status: int
    finished_at: str
    run_id: str
    owner_label: str
    cidfile: str


class ContainerConfig(TypedDict):
    Labels: dict[str, str]
    Env: list[str]


class Mount(TypedDict):
    Destination: str
    Source: str
    RW: bool


class Container(TypedDict):
    Id: str
    Image: str
    Config: ContainerConfig
    Mounts: list[Mount]


class DirectReceiptTests(unittest.TestCase):
    def put(self, path: Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="direct-preflight-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.out = self.root / "run"
        self.out.mkdir(mode=0o700)
        (self.out / "reports").mkdir(mode=0o755)
        result = subprocess.run(["bash", str(HERE / "consumer-source-git-fixture.sh"), str(self.root)],
                                capture_output=True, text=True, check=True, timeout=60)
        owner = Path(result.stdout.strip())
        for name in ("linux/scripts/preflight.sh", "linux/scripts/tests/test-one.sh", "linux/scripts/tests/test-two.sh"):
            path = owner / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture canonical source\n")
        for name in ("run-tests.sh", "test-harness.sh"):
            (owner / "linux/scripts/tests" / name).write_bytes((HERE / name).read_bytes())
        folder = owner / "linux/scripts/tests/test-folder.sh"
        folder.mkdir()
        (folder / "ignored.txt").write_text("A directory is not a runnable suite.\n")
        self.put(owner / "docs/scripts/mutations.json", [{"id": "one"}, {"id": "two"}])
        M.PRESERVER["git"](owner, "add", ".")
        M.PRESERVER["git"](owner, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "receipt fixture")
        self.source = self.root / "frozen"
        frozen = M.PRESERVER["preserve_working"](owner, self.source, self.root / "freeze", M.PRESERVER["head"](owner))
        self.selection = self.root / "selection.json"
        self.put(self.selection, frozen)
        self.reference = self.root / "reference.json"
        self.put(self.reference, {"status": "passed-complete-Linux-source-preflight-only", "source_snapshot": str(owner),
                                 "all_default_preflight_groups": ["fixture group"], "actual_preflight_group_count": 1})
        self.inv: Invocation = {"source": str(self.source), "source_selection": str(self.selection), "source_base": frozen["selected_base"],
                    "source_index_sha256": frozen["index_sha256"], "source_patch_sha256": frozen["patch_sha256"],
                    "unit": "fixture.service", "run_id": "a" * 32, "owner_label": "org.fixture.source", "full_preflight": True,
                    "launch_status": 0, "expected_default_groups": 1, "expected_script_suites": 2, "full_registry_count": 2,
                    "image": "fixture@sha256:" + "c" * 64, "command": []}
        hook = ["cleanup", "--run-id", self.inv["run_id"], "--owner-label", self.inv["owner_label"],
                "--cidfile", str(self.out / "container.cid"), "--output", str(self.out / "cleanup.json")]
        self.inv["command"] = ["systemd-run", "ExecStopPost=" + shlex.join(hook)]
        self.plant_evidence()

    def plant_evidence(self) -> None:
        self.mutations = (b"[1/2] bites one fixture\n[2/2] bites two fixture\ncoverage: proved 2 of 2: the whole manifest\n"
                          b"OK: every recorded mutation is caught by its tests\n")
        self.raw = ("== fixture group ==\n✓ fixture group\n== test-one.sh ==\n== test-two.sh ==\n"
                    "All linux script test suites passed (2 suites, 3 assertions).\nAll preflight checks passed.\n").encode() + self.mutations
        (self.out / "unit.log").write_bytes(self.raw)
        (self.out / "mutator.log").write_bytes(self.mutations)
        (self.out / "compiler-cache").mkdir()
        (self.out / "compiler-cache/exit-status.txt").write_text("command_status=0\ncache_stats_status=0\n")
        self.put(self.out / "compiler-cache/cache-stats.json", {"stats": {}})
        self.put(self.out / "mutator-extraction.json", {"source_sha256": M.fingerprint(self.out / "unit.log"),
                 "start_byte": len(self.raw) - len(self.mutations), "end_byte_exclusive": len(self.raw),
                 "mutation_job_sha256": M.fingerprint(self.out / "mutator.log")})
        self.seal: Seal = {"status": "passed-mutation-unit-only", "unit": self.inv["unit"], "unique_actual_mutations": 2,
                     "terminal": {"Id": self.inv["unit"], "LoadState": "loaded", "ActiveState": "active", "SubState": "exited",
                                  "MainPID": "0", "ExecMainStatus": "0", "Result": "success", "ExecMainExitTimestampMonotonic": "1"},
                     "stopped": {"MainPID": "0", "ActiveState": "inactive"},
                     "inputs": {str(path): M.fingerprint(path) for path in (self.source / "docs/scripts/mutations.json", self.out / "mutator.log")}}
        self.put(self.out / "mutation-proof-stopped.json", self.seal)
        self.cleanup: Cleanup = {"exit_status": 0, "finished_at": "fixture", "run_id": self.inv["run_id"],
                        "owner_label": self.inv["owner_label"], "cidfile": str(self.out / "container.cid")}
        self.put(self.out / "cleanup.json", self.cleanup)
        self.cid = "b" * 64
        (self.out / "container.cid").write_text(self.cid)
        self.container: Container = {"Id": self.cid, "Image": self.inv["image"].split("@", 1)[1],
                          "Config": {"Labels": {self.inv["owner_label"]: self.inv["run_id"]},
                                     "Env": ["ISOLATED_PREFLIGHT_REVISION=" + self.inv["source_base"], "PREFLIGHT_ONLY=",
                                             "PREFLIGHT_SKIP=", "PREFLIGHT_MUTATION_SHARD=", "PREFLIGHT_MUTATION_COSTS="]},
                          "Mounts": [{"Destination": "/source", "Source": str(self.source), "RW": False}]}
        self.put(self.out / "live-container-inspect-1.json", [self.container])
        self.put(self.out / "invocation.json", self.inv)
        self.engine = self.root / "bin/nerdctl"
        self.engine.parent.mkdir()
        self.engine.symlink_to(HERE / "operational_systemd_fixture.py")
        empty = self.root / "containers.jsonl"
        empty.write_text("")
        environment = mock.patch.dict(os.environ, OPERATIONAL_PS_FIXTURE=str(empty))
        environment.start()
        self.addCleanup(environment.stop)

    def test_complete_closed_run_assembles_without_resealing_or_cleanup(self) -> None:
        before = (self.out / "cleanup.json").read_bytes()
        proof = M.assemble(self.out, self.reference, str(self.engine), "proof")
        self.assertEqual(proof["actual_full_registry_mutations"], 2)
        self.assertEqual(proof["script_suites"], 2)
        self.assertEqual(proof["script_assertions"], 3)
        self.assertEqual((proof["command_exit_status"], proof["cache_capture_exit_status"], proof["cleanup_exit_status"]), (0, 0, 0))
        self.assertEqual((self.out / "cleanup.json").read_bytes(), before)
        with self.assertRaisesRegex(ValueError, "existing receipt"):
            M.assemble(self.out, self.reference, str(self.engine), "proof")

    def test_changed_source_modes_or_bytes_refuse(self) -> None:
        (self.source / "source.txt").write_text("changed source")
        with self.assertRaisesRegex(ValueError, "files or modes"):
            M.source_subject(self.inv)

    def test_group_missing_or_duplicate_refuses(self) -> None:
        marker = "✓ fixture group\n".encode()
        for old, new in ((marker, b""), (marker, marker + marker)):
            with self.subTest(new=new), self.assertRaisesRegex(ValueError, "canonical group"):
                M.execution_counts(self.source, M.read(self.reference), self.inv, self.raw.replace(old, new))

    def test_suite_inventory_cannot_duplicate_or_omit_a_suite(self) -> None:
        raw = self.raw.replace(b"test-two.sh", b"test-one.sh")
        with self.assertRaisesRegex(ValueError, "Suite execution"):
            M.execution_counts(self.source, M.read(self.reference), self.inv, raw)

    def test_canonical_harness_library_is_not_an_executed_suite(self) -> None:
        counts = M.execution_counts(self.source, M.read(self.reference), self.inv, self.raw)
        self.assertEqual(counts["script_suites"], 2)
        self.assertNotIn("test-harness.sh", counts["executed_script_suites"])
        self.assertNotIn("test-folder.sh", counts["executed_script_suites"])

    def test_changed_canonical_suite_runner_refuses(self) -> None:
        path = self.source / "linux/scripts/tests/run-tests.sh"
        path.write_bytes(path.read_bytes() + b"changed runner\n")
        with self.assertRaisesRegex(ValueError, "Canonical suite runner changed"):
            M.execution_counts(self.source, M.read(self.reference), self.inv, self.raw)

    def test_raw_command_failure_refuses(self) -> None:
        (self.out / "compiler-cache/exit-status.txt").write_text("command_status=23\ncache_stats_status=0\n")
        with self.assertRaisesRegex(ValueError, "cache capture failed"):
            M.sealed_execution(self.out, self.source, self.inv, self.raw)

    def test_malformed_cache_statistics_refuse(self) -> None:
        self.put(self.out / "compiler-cache/cache-stats.json", {"stats": []})
        with self.assertRaisesRegex(ValueError, "cache statistics"):
            M.assemble(self.out, self.reference, str(self.engine), "bad-cache")
        self.assertFalse((self.out / "bad-cache.json").exists())

    def test_failed_or_unobserved_terminal_refuses(self) -> None:
        for key, value in (("ExecMainStatus", "23"), ("LoadState", "not-found"), ("ExecMainExitTimestampMonotonic", "0")):
            seal = copy.deepcopy(self.seal)
            seal["terminal"][key] = value
            self.put(self.out / "mutation-proof-stopped.json", seal)
            with self.subTest(key=key), self.assertRaises(ValueError):
                M.sealed_execution(self.out, self.source, self.inv, self.raw)

    def test_exact_mutation_slice_refuses_changed_offset(self) -> None:
        path = self.out / "mutator-extraction.json"
        row = M.read(path)
        row["start_byte"] += 1
        self.put(path, row)
        with self.assertRaisesRegex(ValueError, "Mutation slice"):
            M.sealed_execution(self.out, self.source, self.inv, self.raw)

    def test_changed_sealed_inputs_refuse(self) -> None:
        seal = copy.deepcopy(self.seal)
        seal["inputs"][str(self.out / "mutator.log")] = "0" * 64
        self.put(self.out / "mutation-proof-stopped.json", seal)
        with self.assertRaisesRegex(ValueError, "inputs changed"):
            M.sealed_execution(self.out, self.source, self.inv, self.raw)

    def test_evidence_change_during_final_query_refuses(self) -> None:
        def drift(*_arguments: object) -> Path:
            (self.out / "unit.log").write_bytes(self.raw + b"changed after validation\n")
            return self.out / "query.json"

        with mock.patch.object(M, "absence", side_effect=drift), self.assertRaisesRegex(ValueError, "Evidence changed"):
            M.assemble(self.out, self.reference, str(self.engine), "drift")
        self.assertFalse((self.out / "drift.json").exists())

    def test_cleanup_failure_or_foreign_identity_refuses(self) -> None:
        for key, value in (("exit_status", 23), ("run_id", "foreign")):
            self.put(self.out / "cleanup.json", {**self.cleanup, key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                M.closed_container(self.out, self.inv)

    def test_cleanup_hook_and_report_mode_refuse_drift(self) -> None:
        changed = copy.deepcopy(self.inv)
        changed["command"][1] = changed["command"][1].replace("a" * 32, "d" * 32)
        with self.assertRaisesRegex(ValueError, "Cleanup hook differs"):
            M.closed_container(self.out, changed)
        (self.out / "reports").chmod(0o777)
        with self.assertRaisesRegex(ValueError, "permissions"):
            M.closed_container(self.out, self.inv)

    def test_live_filter_and_source_mount_refuse_drift(self) -> None:
        for mode in ("filter", "mount"):
            row = copy.deepcopy(self.container)
            if mode == "filter":
                row["Config"]["Env"][1] = "PREFLIGHT_ONLY=one"
            else:
                row["Mounts"][0]["RW"] = True
            self.put(self.out / "live-container-inspect-1.json", [row])
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                M.observed_container(self.out, self.inv, self.cid)

    def test_failed_or_nonempty_absence_query_cannot_be_success(self) -> None:
        for name, status, output in (("failed", 23, ""), ("present", 0, self.cid + "\n")):
            result = subprocess.CompletedProcess([], status, output, "diagnostic")
            with mock.patch.object(M.subprocess, "run", return_value=result), self.assertRaisesRegex(ValueError, "absence query failed"):
                M.absence(str(self.engine), self.out, self.inv, self.cid, name)
            self.assertTrue((self.out / (name + "-engine-query.json")).is_file())
            self.assertFalse((self.out / (name + ".json")).exists())


if __name__ == "__main__":
    unittest.main()
