#!/usr/bin/env python3
"""Tests Cargo tree selection; this does not prove actual linked binary contents."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parents[1] / "06-packaging"
spec = importlib.util.spec_from_file_location(
    "cargo_license_tree", SCRIPT_DIR / "cargo_license_tree.py"
)
assert spec and spec.loader
tree = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tree)


def create_crate(root: Path, name: str, body: str = "") -> None:
    directory = root / name
    (directory / "src").mkdir(parents=True)
    (directory / "Cargo.toml").write_text(
        f'[package]\nname = "{name}"\nversion = "0.1.0"\nedition = "2021"\nlicense = "MIT"\n{body}',
        encoding="utf-8",
    )
    (directory / "src/lib.rs").write_text("", encoding="utf-8")
    (directory / "LICENSE").write_text(
        f"Fixture original license: {name}\n", encoding="utf-8"
    )


class CargoTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Cargo.toml").write_text(
            '[workspace]\nmembers = ["app", "dep", "helper", "builder", "macrodep"]\nresolver = "2"\n',
            encoding="utf-8",
        )
        create_crate(
            self.root,
            "app",
            '[dependencies]\ndep = { path = "../dep" }\nhelper = { path = "../helper", optional = true }\nmacrodep = { path = "../macrodep" }\n[build-dependencies]\nbuilder = { path = "../builder" }\n[features]\ndefault = ["enable"]\nenable = ["dep:helper"]\n',
        )
        for name in ("dep", "helper", "builder"):
            create_crate(self.root, name)
        create_crate(self.root, "macrodep", "[lib]\nproc-macro = true\n")
        (self.root / "policy.json").write_text(
            '{"version": 1, "packages": {}}', encoding="utf-8"
        )
        self.env = {**os.environ, "CARGO_HOME": str(self.root / "cargo-home")}
        subprocess.run(
            ["cargo", "generate-lockfile", "--offline"],
            cwd=self.root,
            env=self.env,
            check=True,
            capture_output=True,
        )
        version = subprocess.run(
            ["rustc", "-vV"], check=True, capture_output=True, text=True
        ).stdout
        self.target = next(
            line.removeprefix("host: ")
            for line in version.splitlines()
            if line.startswith("host: ")
        )
        metadata = subprocess.run(
            [
                "cargo",
                "metadata",
                "--locked",
                "--offline",
                "--filter-platform",
                self.target,
                "--format-version",
                "1",
            ],
            cwd=self.root,
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        )
        (self.root / "metadata.json").write_text(metadata.stdout, encoding="utf-8")

    def run_collector(self, name: str, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT_DIR / "stage-cargo-licenses.py"),
                "--workspace",
                str(self.root),
                "--root-package",
                "app",
                "--target",
                self.target,
                "--policy",
                str(self.root / "policy.json"),
                "--output-dir",
                str(self.root / name),
                *args,
            ],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def manifest(self, name: str) -> dict[str, Any]:
        return json.loads(
            (self.root / name / "manifest.json").read_text(encoding="utf-8")
        )

    def test_real_tree_respects_feature_selection_and_includes_build_and_macro(
        self,
    ) -> None:
        for name, args in (
            ("default", ()),
            ("no-default", ("--no-default-features",)),
            ("enabled", ("--no-default-features", "--features", "enable")),
            (
                "all",
                ("--all-features", "--no-default-features", "--features", "enable"),
            ),
        ):
            result = self.run_collector(
                name, "--graph-scope", "tree-normal-build", *args
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        names = lambda name: {p["name"] for p in self.manifest(name)["packages"]}
        self.assertEqual(names("no-default"), {"app", "dep", "builder", "macrodep"})
        self.assertEqual(names("default"), names("no-default") | {"helper"})
        self.assertEqual(names("enabled"), names("default"))
        self.assertEqual(names("all"), names("default"))
        selection = self.manifest("no-default")["selection"]
        self.assertEqual(selection["feature_arguments"], ["--no-default-features"])
        self.assertEqual(selection["mode"], "tree-normal-build")
        self.assertEqual(selection["toolchain"]["evidence"], "live")
        self.assertEqual(selection["toolchain"]["rustc_host"], self.target)
        self.assertTrue(selection["toolchain"]["cargo_version"].startswith("cargo "))
        self.assertEqual(selection["edge_kinds"], ["normal", "build"])
        macro = next(
            p
            for p in self.manifest("no-default")["packages"]
            if p["name"] == "macrodep"
        )
        self.assertIn("proc-macro", macro["target_kinds"])
        self.assertGreater(
            len(selection["selected_ids"]), len(selection["metadata_normal_ids"])
        )

    def test_invalid_features_and_untrusted_metadata_fail_without_output(self) -> None:
        for i, args in enumerate(
            (
                ("--features", "bogus"),
                ("--features", "--bad"),
                ("--features", "bad,,feature"),
                ("--metadata", str(self.root / "metadata.json")),
            )
        ):
            result = self.run_collector(
                f"failed-{i}", "--graph-scope", "tree-normal-build", *args
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / f"failed-{i}").exists())

    def test_tree_format_and_source_ambiguity_fail_closed(self) -> None:
        root = {"id": "root", "name": "app", "version": "0.1.0"}
        dep = {"id": "one", "name": "dep", "version": "1.0.0"}
        metadata = {"packages": [root, dep], "workspace_members": ["root"]}
        self.assertEqual(
            len(tree.resolve_tree(metadata, "app v0.1.0\ndep v1.0.0\n", "app")), 2
        )
        for output in (
            "",
            "dep v1.0.0\n",
            "app v0.1.0\n???\n",
            "app v0.1.0\nunknown v1.0.0\n",
        ):
            with self.assertRaises(ValueError):
                tree.resolve_tree(metadata, output, "app")
        metadata["packages"].append({**dep, "id": "another-source"})
        with self.assertRaises(ValueError):
            tree.resolve_tree(metadata, "app v0.1.0\ndep v1.0.0\n", "app")

    def test_cargo_arguments_are_shared_and_tree_includes_build_edges(self) -> None:
        feature_args = tree.feature_arguments(["app/enable"], False, True)
        with patch.object(tree.subprocess, "run") as run:
            run.return_value.stdout = ""
            tree.live_tree(self.root, self.target, "app", feature_args)
        argv = run.call_args.args[0]
        self.assertEqual(
            argv,
            [
                "cargo",
                "tree",
                "--locked",
                "--offline",
                "--target",
                self.target,
                "--package",
                "app",
                "--edges",
                "normal,build",
                "--prefix",
                "none",
                "--format",
                "{p}",
                "--color",
                "never",
                *feature_args,
            ],
        )

    def test_toolchain_report_rejects_missing_and_ambiguous_host(self) -> None:
        from types import SimpleNamespace

        for cargo, rustc in (
            ("not cargo", "host: x86_64-unknown-linux-gnu\n"),
            ("cargo 1.0.0", "rustc 1.0.0\n"),
            ("cargo 1.0.0", "host: one\nhost: two\n"),
        ):
            with (
                patch.object(
                    tree.subprocess,
                    "run",
                    side_effect=[
                        SimpleNamespace(stdout=cargo),
                        SimpleNamespace(stdout=rustc),
                    ],
                ),
                self.assertRaises(ValueError),
            ):
                tree.live_toolchain()


if __name__ == "__main__":
    unittest.main()
