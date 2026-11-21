# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Exercise real Git and byte staging with synthetic notices, not upstream authenticity, compilation or full licence closure."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MONOREPO = (
    "LICENSE",
    "subprojects/gstreamer/COPYING",
    "subprojects/gst-plugins-base/COPYING",
    "subprojects/gst-plugins-good/COPYING",
    "subprojects/gst-plugins-bad/COPYING",
    "subprojects/gst-plugins-ugly/COPYING",
    "subprojects/gst-libav/COPYING",
    "subprojects/gst-plugins-rs.wrap",
    "subprojects/gstreamer/README.static-linking",
)
RUST = (
    "LICENSE-APACHE",
    "LICENSE-MIT",
    "LICENSE-MPL-2.0",
    "video/gtk4/LICENSE-MPL-2.0",
    "Cargo.toml",
    "video/gtk4/Cargo.toml",
)


def fixture(root: Path) -> None:
    for index, relative in enumerate(MONOREPO + RUST):
        file = root / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(b"original\r\n\xff\n" + str(index).encode() + b"\n")
    (root / "Cargo.toml").write_text('[workspace.package]\nversion = "0.16.0-alpha"\n')
    (root / "video/gtk4/Cargo.toml").write_text(
        '[package]\nname = "gst-plugin-gtk4"\nversion.workspace = true\nlicense = "MPL-2.0"\n'
    )
    (root / "source.c").write_text("source before build patches\n")


class NoticeTests(unittest.TestCase):
    subject: Path
    fixture: Path

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(
            prefix="gst-notices-", dir=os.environ.get("TMPDIR")
        )
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tree = self.root / "source with space"
        shutil.copytree(self.fixture, self.tree)
        self.output = self.root / "staged"
        self.policy_file = self.root / "policy.json"
        self.policy = json.loads(
            self.subject.with_name("original-notices.json").read_text()
        )
        self.refresh_policy()

    def git(self, *arguments: str) -> bytes:
        return subprocess.run(
            ["git", "-C", str(self.tree), *arguments], check=True, capture_output=True
        ).stdout

    def refresh_policy(self) -> None:
        for kind, paths in (("monorepo", MONOREPO), ("rust", RUST)):
            self.policy[kind]["commit"] = self.git("rev-parse", "HEAD").decode().strip()
            self.policy[kind]["files"] = {
                name: hashlib.sha256((self.tree / name).read_bytes()).hexdigest()
                for name in paths
            }

    def command(self, kind: str = "monorepo", version: str = "1.29.2") -> list[str]:
        return [
            sys.executable,
            "-B",
            str(self.subject),
            "--source",
            str(self.tree),
            "--destination",
            str(self.output),
            "--policy",
            str(self.policy_file),
            "--kind",
            kind,
            "--version",
            version,
        ]

    def run_stage(
        self, kind: str = "monorepo", version: str = "1.29.2"
    ) -> subprocess.CompletedProcess[str]:
        self.policy_file.write_text(json.dumps(self.policy))
        return subprocess.run(
            self.command(kind, version), text=True, capture_output=True, check=False
        )

    def refused(self, kind: str = "monorepo", version: str = "1.29.2") -> None:
        result = self.run_stage(kind, version)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("GStreamer original notice staging refused:", result.stderr)

    def commit(self) -> None:
        self.git("add", "-A")
        self.git(
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "changed source",
        )

    def test_exact_originals_and_patch(self) -> None:
        (self.tree / "source.c").write_bytes(b"patched\r\nsource\n")
        for kind, paths in (("monorepo", MONOREPO), ("rust", RUST)):
            with self.subTest(kind=kind):
                self.output = self.root / kind
                result = self.run_stage(kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in paths:
                    self.assertEqual(
                        (self.output / name).read_bytes(),
                        (self.tree / name).read_bytes(),
                    )
                self.assertEqual(
                    (self.output / "source.patch").read_bytes(),
                    self.git("diff", "HEAD", "--binary", "--full-index"),
                )
                record = json.loads((self.output / "source-record.json").read_text())
                self.assertFalse(
                    record["binary_linkage_or_complete_license_source_closure_proven"]
                )
                if kind == "rust":
                    self.assertEqual(
                        record["gtk4_package"],
                        {
                            "name": "gst-plugin-gtk4",
                            "version": "0.16.0-alpha",
                            "license_expression": "MPL-2.0",
                        },
                    )

    def test_version(self) -> None:
        self.git("tag", "1.29.999")
        self.refused(version="1.29.999")
        self.assertFalse(self.output.exists())

    def test_modified_build_context(self) -> None:
        cargo = self.tree / "Cargo.toml"
        cargo.write_text(cargo.read_text() + "\n[workspace]\nmembers = []\n")
        result = self.run_stage("rust")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.output / "Cargo.toml").read_bytes(),
            self.git("show", "HEAD:Cargo.toml"),
        )
        self.assertEqual(
            (self.output / "working-context/Cargo.toml").read_bytes(),
            cargo.read_bytes(),
        )
        record = json.loads((self.output / "source-record.json").read_text())
        self.assertEqual(
            record["working_context_sha256"]["Cargo.toml"],
            hashlib.sha256(cargo.read_bytes()).hexdigest(),
        )

    def test_working_rust_identity(self) -> None:
        cargo = self.tree / "Cargo.toml"
        cargo.write_text(cargo.read_text().replace('"0.16.0-alpha"', '"9.9.9"'))
        self.refused("rust")

    def test_pinned_policy_matches_build(self) -> None:
        policy = json.loads(self.subject.with_name("original-notices.json").read_text())
        pins = (
            (self.subject.parents[4] / "01-core/versions.env").read_text().splitlines()
        )
        self.assertIn("GSTREAMER_VERSION=" + policy["release"], pins)
        self.assertEqual(set(policy["monorepo"]["files"]), set(MONOREPO))
        self.assertEqual(set(policy["rust"]["files"]), set(RUST))

    def test_borrowed_git_root(self) -> None:
        nested = self.tree / "nested"
        for name in MONOREPO + RUST:
            target = nested / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.tree / name, target)
        self.tree = nested
        self.refused()

    def test_destination_in_source(self) -> None:
        self.output = self.tree / "staged"
        self.refused()

    def test_hash(self) -> None:
        self.policy["monorepo"]["files"]["LICENSE"] = "0" * 64
        self.refused()

    def test_incomplete_policy(self) -> None:
        del self.policy["monorepo"]["files"]["subprojects/gst-libav/COPYING"]
        self.refused()

    def test_git_original_bytes(self) -> None:
        (self.tree / "LICENSE").write_bytes(b"replacement license\n")
        self.refresh_policy()
        self.refused()

    def test_commit(self) -> None:
        self.policy["monorepo"]["commit"] = "0" * 40
        self.refused()

    def test_moved_tag(self) -> None:
        original = self.git("rev-parse", "HEAD").decode().strip()
        (self.tree / "source.c").write_text("different source\n")
        self.commit()
        self.git("tag", "-f", "1.29.2")
        self.git("checkout", "--detach", original)
        self.refused()

    def test_empty_original(self) -> None:
        (self.tree / "LICENSE").write_bytes(b"")
        self.commit()
        self.git("tag", "-f", "1.29.2")
        self.refresh_policy()
        self.refused()

    def test_missing_original(self) -> None:
        (self.tree / "LICENSE").unlink()
        self.refused()

    def test_oversized_original(self) -> None:
        (self.tree / "LICENSE").write_bytes(b"x" * (1024 * 1024 + 1))
        self.commit()
        self.git("tag", "-f", "1.29.2")
        self.refresh_policy()
        self.refused()

    def test_oversized_patch(self) -> None:
        (self.tree / "source.c").write_bytes(b"x" * (9 * 1024 * 1024))
        self.refused()

    def test_linked_original(self) -> None:
        file = self.tree / "LICENSE"
        original = self.root / "original"
        file.rename(original)
        file.symlink_to(original)
        self.refused()

    def test_hardlinked_original(self) -> None:
        os.link(self.tree / "LICENSE", self.root / "shared-original")
        self.refused()

    def test_linked_source_parent(self) -> None:
        directory = self.tree / "subprojects/gstreamer"
        directory.rename(self.root / "outside")
        directory.symlink_to(self.root / "outside", target_is_directory=True)
        self.refused()

    def test_reused_output(self) -> None:
        self.output.mkdir()
        (self.output / "retained").write_bytes(b"retained bytes")
        self.refused()
        self.assertEqual((self.output / "retained").read_bytes(), b"retained bytes")

    def test_linked_output_parent(self) -> None:
        (self.root / "real").mkdir()
        (self.root / "linked").symlink_to(self.root / "real", target_is_directory=True)
        self.output = self.root / "linked/staged"
        self.refused()
        self.assertEqual(list((self.root / "real").iterdir()), [])

    def test_rust_version(self) -> None:
        self.policy["rust"]["gtk4_package_version"] = "1.29.2"
        self.refused("rust")

    def test_rust_license(self) -> None:
        self.policy["rust"]["gtk4_license_expression"] = "MIT"
        self.refused("rust")

    def test_duplicate_policy_key(self) -> None:
        data = json.dumps(self.policy).replace(
            '"schema": 1', '"schema": 1, "schema": 1'
        )
        self.policy_file.write_text(data)
        result = subprocess.run(
            self.command(), text=True, capture_output=True, check=False
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_entry_failures_before_cleanup(self) -> None:
        setup = self.subject.with_name("setup-gstreamer.sh")
        text = setup.read_text()
        tail = text.split("build_gstreamer_monorepo\n", 1)[1].split('\necho "Done.', 1)[
            0
        ]
        selected = self.root / "entry-tail.sh"
        selected.write_text(tail)
        fake = self.root / "python"
        fake.write_text(
            '#!/usr/bin/env bash\ncase "$*" in *"/$FAIL_DEST") exit 67 ;; esac\nexit 0\n'
        )
        fake.chmod(0o755)
        harness = self.subject.parents[4] / "tests/test-harness.sh"
        command = (
            'source "$1"; eval "$(t_fn_src "$2" stage_gstreamer_original_notices)"\n'
            "HOST_PYTHON=$3; _SETUP_GST_DIR=/unused; BUILD_DIR=/unused; GSTREAMER_VERSION=1.29.2; GSTREAMER_PREFIX=/unused\n"
            "cross_build_is_active() { [[ $CROSS_MODE == 1 ]]; }\nbuild_standalone_gst_plugins_rs() { :; }\n"
            'if source "$4"; then echo inner-continued; fi\necho outer-continued'
        )
        for cross, failed, expected in (
            ("0", "unused-control", 0),
            ("0", "monorepo", 67),
            ("0", "rust-standalone", 67),
            ("1", "rust-monorepo", 67),
        ):
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    command,
                    "_",
                    str(harness),
                    str(setup),
                    str(fake),
                    str(selected),
                ],
                env={**os.environ, "FAIL_DEST": failed, "CROSS_MODE": cross},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, expected, result.stderr)


def main() -> None:
    if sys.argv[1] == "--fixture":
        fixture(Path(sys.argv[2]))
        return
    NoticeTests.subject, NoticeTests.fixture = map(Path, sys.argv[1:3])
    unittest.main(argv=[sys.argv[0]], verbosity=2)


if __name__ == "__main__":
    main()
