"""Strict log/artifact controls and a fake engine exercise the probe; only a separate real BuildKit run proves cache reuse."""

import argparse
import hashlib
import json
import os
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "linux/scripts"
with mock.patch("sys.path", [str(SCRIPTS), *sys.path]):
    API = runpy.run_path(str(SCRIPTS / "script_context_cache.py"))
NONCE = "a" * 32
DIGEST = "b" * 64
HEADER = "#8 [consumer 1/1] RUN printf SCRIPT_CLOSURE_PROBE\n"
EXECUTED = HEADER + f"#8 0.001 SCRIPT_CLOSURE_PROBE {NONCE} {DIGEST}\n#8 DONE 0.002s\n"


class ContextCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="real context probe controls ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def base(self, config_payload: bytes = b'{"architecture":"amd64","os":"linux"}', schema_version: int = 2) -> tuple[Path, str]:
        root = self.root / "base"
        blob = root / "blobs/sha256"
        blob.mkdir(parents=True)
        def store(payload: bytes, media: str) -> dict[str, str | int]:
            digest = hashlib.sha256(payload).hexdigest()
            (blob / digest).write_bytes(payload)
            return {"digest": "sha256:" + digest, "size": len(payload), "mediaType": media}
        config = store(config_payload, "application/vnd.oci.image.config.v1+json")
        layer = store(b"fixture layer bytes,not a real image", "application/vnd.oci.image.layer.v1.tar")
        payload = json.dumps({"schemaVersion": schema_version, "config": config, "layers": [layer]}).encode()
        manifest = store(payload, "application/vnd.oci.image.manifest.v1+json")
        (root / "index.json").write_text(json.dumps({"schemaVersion": 2, "manifests": [manifest]}))
        return root, str(manifest["digest"])

    def source(self) -> Path:
        root = self.root / "source"
        target = root / "linux/scripts"
        for profile, dockerfile, _transport in API["PROFILES"]:
            API["mirror_inputs"](SCRIPTS, profile, target)
            shutil.copyfile(ROOT / "linux" / dockerfile, root / "linux" / dockerfile)
        subprocess.run(["bash", "-euc", 'source "$1"; git init -q "$2"; t_git_commit "$2"', "_",
                        str(SCRIPTS / "tests/test-harness.sh"), str(root)],
                       capture_output=True, text=True, check=True, timeout=20)
        return root

    def arguments(self) -> argparse.Namespace:
        context, digest = self.base()
        return argparse.Namespace(source=self.source(), base_context=context, base_digest=digest,
                                  output=self.root / "output", engine=str(SCRIPTS / "tests/fixtures/script-context-buildkit.py"),
                                  buildkit_host=None)

    def test_real_execution_and_cache_markers_have_one_exact_consumer_owner(self) -> None:
        self.assertEqual(API["consumer_step"](EXECUTED, NONCE, DIGEST, False), "8")
        self.assertEqual(API["consumer_step"](HEADER + "#8 CACHED\n", NONCE, DIGEST, True), "8")

    def test_echoed_commands_foreign_steps_duplicates_and_unfinished_runs_refuse(self) -> None:
        cases = [HEADER + "#8 DONE 0.002s\n", EXECUTED.replace("#8 0.001", "#9 0.001"),
                 EXECUTED.replace(NONCE, "foreign"), EXECUTED.replace(DIGEST, "foreign"),
                 EXECUTED.replace("#8 DONE 0.002s\n", ""), EXECUTED + "#8 CACHED\n",
                 EXECUTED + f"#8 0.002 SCRIPT_CLOSURE_PROBE {NONCE} {DIGEST}\n",
                 EXECUTED + HEADER, EXECUTED.replace("[consumer", "[other")]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                API["consumer_step"](value, NONCE, DIGEST, False)

    def test_warm_control_requires_cached_and_rejects_execution_or_wrong_step(self) -> None:
        for value in (EXECUTED, HEADER + "#9 CACHED\n", HEADER, HEADER + "#8 CACHED\n#8 CACHED\n", EXECUTED + "#8 CACHED\n"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                API["consumer_step"](value, NONCE, DIGEST, True)

    def test_artifact_requires_exact_bytes_and_a_single_regular_file(self) -> None:
        path = self.root / "cache-proof.txt"
        path.write_text(f"{NONCE} {DIGEST}\n")
        expected = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertEqual(API["artifact"](self.root, NONCE, DIGEST), expected)
        path.write_text("foreign\n")
        with self.assertRaisesRegex(ValueError, "bind"):
            API["artifact"](self.root, NONCE, DIGEST)
        path.write_text(f"{NONCE} {DIGEST}\n")
        extra = self.root / "extra"
        extra.write_text("foreign")
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            API["artifact"](self.root, NONCE, DIGEST)
        extra.unlink()
        original = self.root.parent / (self.root.name + "-bytes")
        original.write_bytes(path.read_bytes())
        self.addCleanup(original.unlink)
        path.unlink()
        path.symlink_to(original)
        with self.assertRaisesRegex(ValueError, "regular"):
            API["artifact"](self.root, NONCE, DIGEST)

    def test_base_pin_requires_the_supplied_index_and_its_exact_bytes(self) -> None:
        context, digest = self.base()
        self.assertEqual(API["base_identity"](context, digest), hashlib.sha256((context / "index.json").read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, "explicit SHA256"):
            API["base_identity"](context, "latest")
        foreign = b"another valid base index"
        foreign_digest = hashlib.sha256(foreign).hexdigest()
        (context / "blobs/sha256" / foreign_digest).write_bytes(foreign)
        with self.assertRaisesRegex(ValueError, "does not match"):
            API["base_identity"](context, "sha256:" + foreign_digest)
        (context / "blobs/sha256" / digest.split(":")[1]).write_text("tampered")
        with self.assertRaisesRegex(ValueError, "bytes"):
            API["base_identity"](context, digest)

    def test_native_layout_derivation_preserves_exact_original_blobs(self) -> None:
        context, digest = self.base()
        original = {path.name: path.read_bytes() for path in (context / "blobs/sha256").iterdir()}
        output = self.root / "native"
        proof = API["native_base"](context, digest, output)
        self.assertEqual(proof["digest"], digest)
        self.assertEqual(json.loads((output / "oci-layout").read_text()), {"imageLayoutVersion": "1.0.0"})
        self.assertEqual(len(json.loads((output / "index.json").read_text())["manifests"]), 1)
        self.assertEqual({path.name: path.read_bytes() for path in (output / "blobs/sha256").iterdir()}, original)
        for name, payload in original.items():
            self.assertEqual((context / "blobs/sha256" / name).read_bytes(), payload)

    def test_multiplatform_input_selects_only_its_unique_native_child(self) -> None:
        context, digest = self.base()
        leaf = json.loads((context / "index.json").read_text())["manifests"][0]
        leaf["platform"] = {"os": "linux", "architecture": "amd64"}
        index = {"schemaVersion": 2, "manifests": [leaf, {**leaf, "platform": {"os": "linux", "architecture": "arm64"}}]}
        raw = json.dumps(index).encode()
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        (context / "blobs/sha256" / digest.split(":")[1]).write_bytes(raw)
        descriptor = {"digest": digest, "size": len(raw), "mediaType": "application/vnd.oci.image.index.v1+json"}
        (context / "index.json").write_text(json.dumps({"manifests": [descriptor]}))
        self.assertEqual(API["native_base"](context, digest, self.root / "native")["digest"], leaf["digest"])
        index["manifests"].append(leaf)
        raw = json.dumps(index).encode()
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        (context / "blobs/sha256" / digest.split(":")[1]).write_bytes(raw)
        descriptor.update(digest=digest, size=len(raw))
        (context / "index.json").write_text(json.dumps({"manifests": [descriptor]}))
        with self.assertRaisesRegex(ValueError, "one exact"):
            API["native_base"](context, digest, self.root / "ambiguous")
        self.assertFalse((self.root / "ambiguous").exists())

    def test_bad_blob_hash_size_symlink_and_foreign_config_refuse(self) -> None:
        context, digest = self.base()
        row = json.loads((context / "index.json").read_text())["manifests"][0]
        with self.assertRaisesRegex(ValueError, "size"):
            API["oci_blob"](context, {**row, "size": row["size"] + 1})
        path = context / "blobs/sha256" / digest.split(":")[1]
        raw = path.read_bytes()
        path.write_bytes(raw.replace(b"layers", b"fakers"))
        with self.assertRaisesRegex(ValueError, "hash"):
            API["oci_blob"](context, row)
        path.write_bytes(raw)
        original = self.root / "original-blob"
        original.write_bytes(raw)
        path.unlink()
        path.symlink_to(original)
        with self.assertRaisesRegex(ValueError, "regular file"):
            API["oci_blob"](context, row)
        path.unlink()
        path.write_bytes(raw)
        manifest = json.loads(raw)
        config = b'{"architecture":"arm64","os":"linux"}'
        config_digest = hashlib.sha256(config).hexdigest()
        (context / "blobs/sha256" / config_digest).write_bytes(config)
        manifest["config"].update(digest="sha256:" + config_digest, size=len(config))
        raw = json.dumps(manifest).encode()
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        (context / "blobs/sha256" / digest.split(":")[1]).write_bytes(raw)
        row.update(digest=digest, size=len(raw))
        (context / "index.json").write_text(json.dumps({"manifests": [row]}))
        with self.assertRaisesRegex(ValueError, "platform"):
            API["native_base"](context, digest, self.root / "foreign")
        self.assertFalse((self.root / "foreign").exists())

    def test_native_root_media_and_layer_closure_refuse_before_copying(self) -> None:
        context, digest = self.base()
        row = json.loads((context / "index.json").read_text())["manifests"][0]
        (context / "index.json").write_text(json.dumps({"manifests": [row, row]}))
        with self.assertRaisesRegex(ValueError, "one pinned"):
            API["native_base"](context, digest, self.root / "duplicate")
        wrong_media = {**row, "mediaType": "application/vnd.oci.image.index.v1+json"}
        (context / "index.json").write_text(json.dumps({"manifests": [wrong_media]}))
        with self.assertRaisesRegex(ValueError, "native OCI"):
            API["native_base"](context, digest, self.root / "wrong-media")
        manifest = json.loads((context / "blobs/sha256" / digest.split(":")[1]).read_text())
        manifest["layers"] = []
        raw = json.dumps(manifest).encode()
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        (context / "blobs/sha256" / digest.split(":")[1]).write_bytes(raw)
        row.update(digest=digest, size=len(raw))
        (context / "index.json").write_text(json.dumps({"manifests": [row]}))
        with self.assertRaisesRegex(ValueError, "no layers"):
            API["native_base"](context, digest, self.root / "empty")

    def test_corrupt_native_copy_cannot_write_a_complete_index(self) -> None:
        context, digest = self.base()
        output = self.root / "corrupt-copy"
        copy = shutil.copyfile
        def corrupt(source: Path, target: Path) -> None:
            copy(source, target)
            target.write_bytes(target.read_bytes() + b"corrupt")
        with mock.patch("shutil.copyfile", side_effect=corrupt), self.assertRaisesRegex(ValueError, "size"):
            API["native_base"](context, digest, output)
        self.assertFalse((output / "index.json").exists())

    def test_original_oci_blob_and_derived_index_changes_refuse_final_receipts(self) -> None:
        args = self.arguments()
        original = {path: path.read_bytes() for path in (args.base_context / "blobs/sha256").iterdir()}
        for index, mode in enumerate(("original-oci", "derived-index")):
            args.output = self.root / ("oci-changed" + str(index))
            with self.subTest(mode=mode), mock.patch.dict(os.environ, SCRIPT_CONTEXT_FIXTURE_MODE=mode,
                                                        SCRIPT_CONTEXT_FIXTURE_BASE=str(args.base_context),
                                                        SCRIPT_CONTEXT_FIXTURE_DERIVED=str(args.output / "native-base")), self.assertRaisesRegex(ValueError, "Original OCI blobs|Derived OCI index"):
                API["run"](args)
            self.assertFalse((args.output / "proof.json").exists())
            for path, payload in original.items():
                path.write_bytes(payload)

    def test_nonlinux_config_and_non_v2_manifest_refuse(self) -> None:
        context, digest = self.base(config_payload=b'{"architecture":"amd64","os":"windows"}')
        with self.assertRaisesRegex(ValueError, "platform"):
            API["native_base"](context, digest, self.root / "nonlinux")
        self.assertFalse((self.root / "nonlinux").exists())
        self.root = self.root / "schema-control"
        self.root.mkdir()
        context, digest = self.base(schema_version=3)
        with self.assertRaisesRegex(ValueError, "native OCI"):
            API["native_base"](context, digest, self.root / "wrong-schema")

    def test_production_transport_and_recipe_keep_copy_alias_or_readonly_mount(self) -> None:
        source = self.source()
        for profile, name, transport in API["PROFILES"]:
            text = API["recipe"](transport)
            self.assertIn("RUN --network=none", text)
            self.assertIn('ARG CACHE_NONCE', text)
            self.assertIn("FROM scratch AS result", text)
            self.assertEqual(API["production_contract"](source, profile, name, transport),
                             hashlib.sha256((source / "linux" / name).read_bytes()).hexdigest())
            fragment = "COPY --from=sdk-core-scripts /${HUB_SCRIPTS_KEY}/files/ /opt/scripts/" if transport == "copy" else "--mount=type=bind,from=hub-scripts,source=/${HUB_SCRIPTS_KEY}/files,target=/opt/scripts,ro"
            self.assertIn(fragment, text)
            if transport == "copy":
                self.assertIn("FROM hub-scripts AS sdk-core-scripts", text)
            path = source / "linux" / name
            path.write_text(path.read_text().replace(fragment, "missing"))
            with self.assertRaisesRegex(ValueError, "transport"):
                API["production_contract"](source, profile, name, transport)

    def test_production_profile_label_must_match_the_requested_probe(self) -> None:
        source = self.source()
        path = source / "linux/Dockerfile.sdk"
        path.write_text(path.read_text().replace("build-script-closure=sdk-core", "build-script-closure=migraphx-image"))
        with self.assertRaisesRegex(ValueError, "profile"):
            API["production_contract"](source, "sdk-core", "Dockerfile.sdk", "copy")

    def test_a_control_file_that_becomes_selected_refuses_before_mirroring(self) -> None:
        source = self.source() / "linux/scripts"
        plan = source / "script-closures/sdk-core.txt"
        plan.write_text(plan.read_text() + "\n01-core/context-management.sh|core/extra.sh\n")
        output = self.root / "invalid-mirror"
        with self.assertRaisesRegex(ValueError, "controls"):
            API["mirror_inputs"](source, "sdk-core", output)
        self.assertFalse(output.exists())

    def test_command_boundaries_keep_local_output_pinned_base_and_selected_context(self) -> None:
        args = self.arguments()
        args.buildkit_host = "unix:///fixture/socket with spaces"
        command = API["build_command"](args, self.root / "context", self.root / "selected", self.root / "export", NONCE, DIGEST)
        self.assertEqual(command[-1], str(self.root / "context"))
        self.assertEqual(command[command.index("--buildkit-host") + 1], args.buildkit_host)
        self.assertIn("hub-scripts=" + str(self.root / "selected"), command)
        self.assertIn("ubuntu@" + args.base_digest + "=oci-layout://" + str(args.base_context), command)
        self.assertIn("CACHE_NONCE=" + NONCE, command)
        self.assertIn("HUB_SCRIPTS_KEY=" + DIGEST, command)
        self.assertIn("type=local,dest=" + str(self.root / "export"), command)

    def test_full_fake_transport_runs_all_six_phases_and_preserves_original_source(self) -> None:
        args = self.arguments()
        API["run"](args)
        proof = json.loads((args.output / "proof.json").read_text())
        self.assertEqual(proof["status"], "passed-selected-context-cache-transport-only")
        self.assertEqual([row["source_files"] for row in proof["profiles"]], [24, 76])
        for row in proof["profiles"]:
            self.assertEqual([phase["cached"] for phase in row["phases"]], [False, True, False])
            self.assertTrue(row["original_inputs_unchanged"])
            for phase in ("cold", "unselected-change", "selected-change"):
                status = json.loads((args.output / row["profile"] / phase / "command-status.json").read_text())
                self.assertEqual(status["exit_status"], 0)
        self.assertEqual(subprocess.run(["git", "-C", str(args.source), "status", "--porcelain"], capture_output=True, text=True, check=True).stdout, "")

    def test_missing_marker_bad_artifact_false_warm_and_false_selected_hits_refuse(self) -> None:
        args = self.arguments()
        for index, mode in enumerate(("exit", "exit-with-evidence", "missing-marker", "bad-artifact", "warm-executed", "selected-cached")):
            args.output = self.root / ("failed" + str(index))
            with self.subTest(mode=mode), mock.patch.dict(os.environ, SCRIPT_CONTEXT_FIXTURE_MODE=mode), self.assertRaises(ValueError):
                API["run"](args)
            self.assertFalse((args.output / "proof.json").exists())
            if mode in ("exit", "exit-with-evidence"):
                status = json.loads((args.output / "sdk-core/cold/command-status.json").read_text())
                self.assertEqual(status["exit_status"], 47)

    def test_wrong_namespace_key_refuses_before_build_dispatch(self) -> None:
        args = self.arguments()
        def wrong_key(_root: Path, _profile: str, output: Path) -> str:
            path = output / DIGEST / "files"
            path.mkdir(parents=True)
            (path / "SCRIPT-CLOSURE.json").write_bytes(b"foreign receipt")
            return DIGEST
        output = self.root / "wrong-phase"
        with mock.patch.dict(API["execute_phase"].__globals__, stage_context=wrong_key), self.assertRaisesRegex(ValueError, "context key"):
            API["execute_phase"](args, output, args.source / "linux/scripts", "sdk-core", "copy", NONCE, False)
        self.assertFalse((output / "invocation.json").exists())

    def test_missing_equal_size_control_refuses_before_the_selected_solve(self) -> None:
        args = self.arguments()
        path = args.source / "linux/scripts/01-core/logging.sh"
        path.write_bytes(b"no comment token\n")
        args.output.mkdir()
        with self.assertRaisesRegex(ValueError, "control must change"):
            API["replay_profile"](args, *API["PROFILES"][0], NONCE)
        self.assertFalse((args.output / "sdk-core/selected-change").exists())

    def test_dirty_sources_refuse_before_output_allocation(self) -> None:
        args = self.arguments()
        path = args.source / "linux/Dockerfile.sdk"
        path.write_text(path.read_text() + "\n# Changed source input.\n")
        with self.assertRaisesRegex(ValueError, "clean"):
            API["run"](args)
        self.assertFalse(args.output.exists())

    def test_existing_output_is_preserved(self) -> None:
        args = self.arguments()
        args.output.mkdir()
        marker = args.output / "preserve"
        marker.write_text("original")
        with self.assertRaises(FileExistsError):
            API["run"](args)
        self.assertEqual(marker.read_text(), "original")

    def test_source_head_change_after_successful_steps_cannot_produce_a_receipt(self) -> None:
        args = self.arguments()
        with mock.patch.dict(os.environ, SCRIPT_CONTEXT_FIXTURE_MODE="source-head", SCRIPT_CONTEXT_FIXTURE_SOURCE=str(args.source)), self.assertRaisesRegex(ValueError, "source identity"):
            API["run"](args)
        self.assertFalse((args.output / "proof.json").exists())

    def test_original_input_or_base_index_change_cannot_produce_a_receipt(self) -> None:
        args = self.arguments()
        for index, mode in enumerate(("source-input", "base-index")):
            args.output = self.root / ("changed" + str(index))
            if mode == "base-index":
                subprocess.run(["git", "-C", str(args.source), "restore", "linux/scripts/01-core/logging.sh"], check=True, timeout=10)
            with self.subTest(mode=mode), mock.patch.dict(os.environ, SCRIPT_CONTEXT_FIXTURE_MODE=mode,
                                                        SCRIPT_CONTEXT_FIXTURE_SOURCE=str(args.source),
                                                        SCRIPT_CONTEXT_FIXTURE_BASE=str(args.base_context)), self.assertRaisesRegex(ValueError, "Original source inputs|OCI base index changed"):
                API["run"](args)
            self.assertFalse((args.output / "proof.json").exists())

    def test_receipt_and_artifact_comparisons_each_guard_warm_and_selected_controls(self) -> None:
        args = self.arguments()
        base = {"receipt_sha256": "A", "artifact_sha256": "A"}
        changed = {"receipt_sha256": "B", "artifact_sha256": "B"}
        cases = [([base, {"receipt_sha256": "B", "artifact_sha256": "A"}, changed], "Unselected"),
                 ([base, {"receipt_sha256": "A", "artifact_sha256": "B"}, changed], "Unselected"),
                 ([base, base, {"receipt_sha256": "A", "artifact_sha256": "B"}], "Selected"),
                 ([base, base, {"receipt_sha256": "B", "artifact_sha256": "A"}], "Selected")]
        for index, (records, message) in enumerate(cases):
            args.output = self.root / ("comparison" + str(index))
            args.output.mkdir()
            with self.subTest(index=index), mock.patch.dict(API["replay_profile"].__globals__,
                                                           execute_phase=mock.Mock(side_effect=records)), self.assertRaisesRegex(ValueError, message):
                API["replay_profile"](args, *API["PROFILES"][0], NONCE)

    def test_cli_failures_remain_nonzero_without_a_success_marker(self) -> None:
        args = self.arguments()
        command = ["python3", str(SCRIPTS / "probe-script-context-cache.py"), "--source", str(args.source),
                   "--base-context", str(args.base_context), "--base-digest", args.base_digest, "--output", str(args.output), "--engine", args.engine]
        result = subprocess.run(command, env=dict(os.environ, SCRIPT_CONTEXT_FIXTURE_MODE="exit"),
                                capture_output=True, text=True, check=False, timeout=20)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("BuildKit solve failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
