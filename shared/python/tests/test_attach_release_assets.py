#!/usr/bin/env python3
"""Exercise release tag, collision and no-overwrite checks without GitHub writes."""

import importlib.util
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "attach_release_assets.py"
spec = importlib.util.spec_from_file_location("attach_release_assets", MODULE)
assert spec is not None and spec.loader is not None
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)
SHA = "a" * 40


class AttachTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        (self.directory / "gpu-a.deb").write_bytes(b"a")
        (self.directory / "gpu-b.tar.gz").write_bytes(b"b")

    def call(self, dry_run: bool = False) -> None:
        subject.attach("owner/repo", "v1.2.3", SHA, self.directory, dry_run)

    @patch.object(subject.subprocess, "run")
    @patch.object(subject, "release_assets", return_value=[])
    @patch.object(subject, "tag_commit", return_value=SHA)
    @patch.object(
        subject, "api", return_value={"id": 7, "tag_name": "v1.2.3", "draft": False}
    )
    def test_upload_exact_files_without_clobber(self, _api, _tag, _assets, run) -> None:
        self.call()
        command = run.call_args.args[0]
        self.assertEqual(command[:5], ["gh", "release", "upload", "v1.2.3", "--repo"])
        self.assertNotIn("--clobber", command)
        self.assertEqual(
            {Path(x).name for x in command[6:]}, {"gpu-a.deb", "gpu-b.tar.gz"}
        )

    @patch.object(subject.subprocess, "run")
    @patch.object(subject, "release_assets", return_value=[{"name": "GPU-A.DEB"}])
    @patch.object(subject, "tag_commit", return_value=SHA)
    @patch.object(
        subject, "api", return_value={"id": 7, "tag_name": "v1.2.3", "draft": False}
    )
    def test_collision_refuses_all_uploads(self, _api, _tag, _assets, run) -> None:
        with self.assertRaises(ValueError):
            self.call()
        run.assert_not_called()

    @patch.object(subject.subprocess, "run")
    @patch.object(subject, "release_assets", return_value=[])
    @patch.object(subject, "tag_commit", return_value="b" * 40)
    @patch.object(
        subject, "api", return_value={"id": 7, "tag_name": "v1.2.3", "draft": False}
    )
    def test_wrong_commit_refuses_upload(self, _api, _tag, _assets, run) -> None:
        with self.assertRaises(ValueError):
            self.call()
        run.assert_not_called()

    @patch.object(subject.subprocess, "run")
    @patch.object(subject, "release_assets", return_value=[])
    @patch.object(subject, "tag_commit", return_value=SHA)
    @patch.object(
        subject, "api", return_value={"id": 7, "tag_name": "v1.2.3", "draft": True}
    )
    def test_draft_refuses_upload(self, _api, _tag, _assets, run) -> None:
        with self.assertRaises(ValueError):
            self.call()
        run.assert_not_called()

    @patch.object(subject.subprocess, "run")
    def test_dry_run_makes_no_github_call(self, run) -> None:
        self.call(True)
        run.assert_not_called()

    @patch.object(subject.subprocess, "run")
    @patch.object(subject, "release_assets")
    @patch.object(subject, "tag_commit", return_value=SHA)
    @patch.object(
        subject, "api", return_value={"id": 7, "tag_name": "v1.2.3", "draft": False}
    )
    def test_check_only_verifies_tag_without_upload(
        self, _api, tag, listing, run
    ) -> None:
        subject.attach("owner/repo", "v1.2.3", SHA, None, False, True)
        tag.assert_called_once_with("owner/repo", "v1.2.3")
        listing.assert_not_called()
        run.assert_not_called()

    @patch.object(subject, "api")
    def test_annotated_tag_is_peeled(self, api) -> None:
        api.side_effect = [
            {"object": {"type": "tag", "sha": "b" * 40}},
            {"object": {"type": "commit", "sha": SHA}},
        ]
        self.assertEqual(subject.tag_commit("owner/repo", "v1.2.3"), SHA)

    def test_empty_or_nested_assets_are_refused(self) -> None:
        (self.directory / "nested").mkdir()
        with self.assertRaises(ValueError):
            self.call(True)

    def test_gh_display_label_syntax_is_refused(self) -> None:
        (self.directory / "gpu#alternate.deb").write_bytes(b"a")
        with self.assertRaises(ValueError):
            self.call(True)

    @patch.object(subject.subprocess, "run")
    def test_asset_pagination_reads_every_page(self, run) -> None:
        run.return_value = CompletedProcess(
            [], 0, stdout='[[{"name":"one"}],[{"name":"two"}]]'
        )
        self.assertEqual(
            subject.release_assets("owner/repo", 7), [{"name": "one"}, {"name": "two"}]
        )
        self.assertIn("--paginate", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
