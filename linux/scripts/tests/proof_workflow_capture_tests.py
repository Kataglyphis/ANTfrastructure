# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Prove mounted transcript bytes and raw worker exits; real containers and full source acceptance are not covered."""

import argparse
import os
import shlex
import subprocess
import unittest
from pathlib import Path


class WorkerTranscriptChecks(unittest.TestCase):
    root: Path
    output: Path
    scripts: Path
    def run_fixture(
        self, mode: str, args: argparse.Namespace | None = None
    ) -> tuple[int, dict[str, object], list[list[str]]]:
        raise NotImplementedError

    def test_complete_mounted_bytes_survive_a_clipped_attach_stream(self) -> None:
        status, record, _ = self.run_fixture("clipped-attach")
        self.assertEqual(status, 0)
        self.assertEqual(record["log_capture_exit_status"], 0)
        self.assertEqual((self.output / "engine-attach.log").read_bytes(), b"worker\xff\n")
        self.assertEqual((self.output / "preflight.log").read_bytes(), b"worker\xff\nfinal footer\n")

    def test_missing_or_linked_worker_transcript_cannot_pass(self) -> None:
        for mode in ("missing-transcript", "transcript-symlink"):
            with self.subTest(mode=mode):
                self.output = self.root / mode
                status, record, _ = self.run_fixture(mode)
                self.assertEqual(status, 1)
                self.assertEqual(record["status"], "failed")
                self.assertEqual(record["command_exit_status"], 0)
                self.assertEqual(record["cleanup_exit_status"], 0)
                self.assertEqual(record["log_capture_exit_status"], 1)
                self.assertFalse((self.output / "preflight.log").exists())
                self.assertEqual((self.output / "engine-attach.log").read_bytes(), b"worker\xff\n")

    def test_worker_redirects_both_streams_without_masking_make_status(self) -> None:
        worker = (self.scripts / "isolated-preflight/worker.sh").read_text()
        command = next(line for line in worker.splitlines() if line.startswith("exec make preflight"))
        executable = self.root / "make"
        executable.write_text(
            "#!/usr/bin/env python3\nimport os\nos.write(1, b'worker\\xff\\n')\n"
            "os.write(2, b'diagnostic\\x80\\n')\nraise SystemExit(int(os.environ['PROOF_MAKE_EXIT']))\n"
        )
        executable.chmod(0o755)
        for status in (0, 47):
            with self.subTest(status=status):
                result = subprocess.run(
                    ["bash", "-c", command.replace("/evidence", shlex.quote(str(self.root)))],
                    env=dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"], PROOF_MAKE_EXIT=str(status)),
                    capture_output=True, check=False,
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual((result.stdout, result.stderr), (b"", b""))
                self.assertEqual((self.root / "isolated-preflight-command.log").read_bytes(), b"worker\xff\ndiagnostic\x80\n")
