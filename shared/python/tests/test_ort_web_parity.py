#!/usr/bin/env python3
"""The ORT Web parity report over fixture builds: verdicts, tolerance edges, refusals and the report's shape."""

import argparse
import base64
import contextlib
import hashlib
import io
import json
import struct
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from typing import Any

# Consumers run this file with python -I, which leaves the module's directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ort_web_parity as web  # noqa: E402

# main() is tested with run() patched out; the fixture keeps the real one.
REAL_RUN = web.run

SIDE = 640
# Cat A low in the photo at 0.875, cat B beside it at 0.5 (IoU 0.48), a chair: compare_detector_parity's CPU baseline holds.
CAT_A = [0.0, 240.0, 600.0, 640.0, 0.875, 15.0]
CAT_B = [0.0, 0.0, 400.0, 640.0, 0.5, 15.0]
CHAIR = [2.0, 2.0, 640.0, 630.0, 0.625, 56.0]
WEBGPU_LOG = [
    "[V:onnxruntime:, session_state.cc:1578 VerifyEachNodeIsAssignedToAnEp] Node placements",
    "[V:onnxruntime:, session_state.cc:1584 VerifyEachNodeIsAssignedToAnEp]  Node(s) placed on [CPUExecutionProvider]. Number of nodes: 2",
    "[V:onnxruntime:, session_state.cc:1586 VerifyEachNodeIsAssignedToAnEp]   Tile (/model/decoder/Tile)",
    "[V:onnxruntime:, session_state.cc:1586 VerifyEachNodeIsAssignedToAnEp]   Tile (/post/Tile_1)",
    "[V:onnxruntime:, session_state.cc:1584 VerifyEachNodeIsAssignedToAnEp]  Node(s) placed on [WebGpuExecutionProvider]. Number of nodes: 6",
    "[V:onnxruntime:, session_state.cc:1586 VerifyEachNodeIsAssignedToAnEp]   GridSample (/model/decoder/GridSample)",
]
CPU_LOG = ["[V:onnxruntime:, session_state.cc:1581 VerifyEachNodeIsAssignedToAnEp]  All nodes placed on [CPUExecutionProvider]. Number of nodes: 717"]


def output(*rows: list[float]) -> list[float]:
    flat = [value for row in rows for value in row]
    return flat + [0.0] * (300 * 6 - len(flat))


def page(*runs: list[float], logs: list[str] | None = None, **extra: Any) -> dict[str, Any]:
    data = [base64.b64encode(struct.pack("<1800f", *values)).decode() for values in runs]
    return {"chrome": "Chrome/157", "flags": [], "ep": "webgpu", "crossOriginIsolated": True, "jspi": True,
            "adapter": {"vendor": "google", "architecture": "swiftshader"}, "createMs": 1.0, "error": None,
            "runs": [{"ms": 2.0, "dims": [1, 300, 6], "type": "float32", "data": item} for item in data],
            "logs": WEBGPU_LOG if logs is None else logs, **extra}


class Fixture:
    """A staged site of fake builds, a fake model and photo whose digests the module is told to expect."""

    def __init__(self, root: Path, builds: tuple[str, ...] = ("jspi", "asyncify", "cpu", "jsep"), bundles: bool = True) -> None:
        self.root = root
        self.site = root / "site"
        entries = []
        for name in builds:
            prefix = web.BUILDS[name][0]
            directory = self.site / "ort" / f"1.31.1-{name}"
            directory.mkdir(parents=True)
            files = {f"ort-wasm-simd-threaded.{name}.wasm": "wasm", f"ort-wasm-simd-threaded.{name}.mjs": "loader"}
            if bundles:
                files[f"{prefix}.min.mjs"] = "bundle"
                files[f"{prefix}.bundle.min.mjs"] = "bundle"
            listed = []
            for file, role in files.items():
                (directory / file).write_text(f"{name} {file}\n", encoding="utf-8")
                listed.append({"file": file, "role": role, "sha256": hashlib.sha256(f"{name} {file}\n".encode()).hexdigest()})
            entries.append({"build": name, "build_hash": name, "path": f"ort/1.31.1-{name}/", "files": listed})
        manifest = {"schema_version": 1, "ort": {"version": "1.31.1"}, "builds": entries}
        (self.site / "ort" / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        self.model = root / "model.onnx"
        self.image = root / "two_cats.jpg"
        self.model.write_bytes(b"model")
        self.image.write_bytes(b"photo")
        self.pages: dict[str, dict[str, Any]] = {}
        self.native = output(CAT_A, CAT_B, CHAIR)
        self.commands: list[list[str]] = []

    def args(self, *extra: str) -> argparse.Namespace:
        return web.arguments(["--site", str(self.site), "--model", str(self.model), "--image", str(self.image),
                              "--out", str(self.root / "report"), *extra])

    def runner(self, command: list[str]) -> int:
        self.commands.append(command)
        build = next(name for name in web.BUILDS if f"1.31.1-{name}/" in command[command.index("--wasm-dir") + 1])
        Path(command[command.index("--out") + 1]).write_text(json.dumps(self.pages.get(build, page(self.native, self.native))), encoding="utf-8")
        return 0

    def run(self, *extra: str) -> list[dict[str, Any]]:
        return REAL_RUN(self.args(*extra), runner=self.runner, native=lambda *_: self.native,
                       photo=lambda _: (bytes(SIDE * SIDE * 3), SIDE, SIDE))

    def by_build(self, *extra: str) -> dict[str, dict[str, Any]]:
        return {entry["build"]: entry for entry in self.run(*extra)}


class ParityReportTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.fx = Fixture(Path(temp.name))
        for name, digest in (("MODEL_SHA256", self.fx.model), ("FIXTURE_SHA256", self.fx.image)):
            original = getattr(web, name)
            setattr(web, name, hashlib.sha256(digest.read_bytes()).hexdigest())
            self.addCleanup(setattr, web, name, original)
        # The CPU build places every node on the CPU provider, as ORT logs it.
        self.fx.pages["cpu"] = page(self.fx.native, self.fx.native, logs=CPU_LOG)

    def test_matching_builds_ship_and_the_report_has_its_shape(self) -> None:
        reports = self.fx.run()
        self.assertEqual([entry["build"] for entry in reports], ["jspi", "asyncify", "cpu"])
        for entry in reports:
            self.assertEqual(set(entry), web.REPORT_KEYS)
            self.assertEqual((entry["verdict"], entry["reasons"], entry["decides"]), ("ship", [], True))
            self.assertEqual(entry["tolerances"], {"min_iou": 0.9, "max_score_delta": 0.05, "min_score": 0.25})
            self.assertEqual(entry["cats"], {"minimum": 2, "score": 0.4, "per_run": [2, 2], "passed": True})
            self.assertEqual(entry["js"]["from"], "manifest")
            self.assertTrue(entry["js"]["file"].endswith(".min.mjs") and ".bundle." not in entry["js"]["file"])
        jspi = reports[0]
        self.assertEqual(jspi["providers"]["counts"], {"CPUExecutionProvider": 2, "WebGpuExecutionProvider": 6})
        self.assertEqual(jspi["providers"]["shares"], {"WebGpuExecutionProvider": 0.75, "CPUExecutionProvider": 0.25})
        self.assertEqual(jspi["providers"]["elsewhere"], {"CPUExecutionProvider": {"Tile": 2}})
        self.assertEqual(jspi["parity"]["min_iou"], 1.0)
        self.assertEqual(jspi["parity"]["max_score_delta"], 0.0)
        self.assertEqual(jspi["native"], {"provider": "CPUExecutionProvider", "detections": 3, "cats": 2})
        out = self.fx.root / "report"
        summary = json.loads((out / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual([item["verdict"] for item in summary["builds"]], ["ship"] * 3)
        self.assertEqual(set(summary["builds"][0]), {"build", "path", "verdict", "decides", "reasons"})
        self.assertEqual(json.loads((out / "jspi-run1.json").read_text(encoding="utf-8"))["detections"][0]["class"], 15)
        self.assertTrue((out / "native-cpu.json").is_file())
        self.assertEqual(json.loads((out / "jspi-page.json").read_text(encoding="utf-8"))["logs"], WEBGPU_LOG)

    def test_each_build_runs_with_its_own_provider_and_gpu(self) -> None:
        self.fx.run("--jsep")
        modes = [(c[c.index("--module") + 1], c[c.index("--ep") + 1], c[c.index("--gpu") + 1]) for c in self.fx.commands]
        self.assertEqual(modes, [
            ("site/ort/1.31.1-jspi/ort.jspi.min.mjs", "webgpu", "webgpu"),
            ("site/ort/1.31.1-asyncify/ort.webgpu.min.mjs", "webgpu", "webgpu"),
            ("site/ort/1.31.1-cpu/ort.wasm.min.mjs", "wasm", "none"),
            ("site/ort/1.31.1-jsep/ort.min.mjs", "webgpu", "webgpu"),
        ])

    def test_score_tolerance_edges(self) -> None:
        inside = [*CAT_B[:4], 0.5 - 0.046875, 15.0]
        outside = [*CAT_B[:4], 0.5 - 0.0546875, 15.0]
        self.fx.pages["jspi"] = page(output(CAT_A, inside, CHAIR), output(CAT_A, inside, CHAIR))
        self.fx.pages["asyncify"] = page(output(CAT_A, outside, CHAIR), output(CAT_A, outside, CHAIR))
        got = self.fx.by_build()
        self.assertEqual(got["jspi"]["verdict"], "ship")
        self.assertEqual(got["jspi"]["parity"]["max_score_delta"], 0.046875)
        self.assertEqual(got["asyncify"]["verdict"], "refuse")
        self.assertFalse(got["asyncify"]["parity"]["passed"])
        self.assertIn("do not match within tolerance", got["asyncify"]["reasons"][0])

    def test_iou_tolerance_edges(self) -> None:
        at_edge = [0.0, 240.0, 600.0, 600.0, 0.875, 15.0]  # IoU 216000 / 240000 = 0.9 exactly
        below = [0.0, 240.0, 600.0, 599.0, 0.875, 15.0]  # IoU 0.8975
        self.fx.pages["jspi"] = page(output(at_edge, CAT_B, CHAIR), output(at_edge, CAT_B, CHAIR))
        self.fx.pages["asyncify"] = page(output(below, CAT_B, CHAIR), output(below, CAT_B, CHAIR))
        got = self.fx.by_build()
        self.assertEqual((got["jspi"]["verdict"], got["jspi"]["parity"]["min_iou"]), ("ship", 0.9))
        self.assertEqual(got["asyncify"]["verdict"], "refuse")
        self.assertEqual(got["asyncify"]["parity"]["min_iou"], 0.8975)

    def test_fewer_than_two_confident_cats_refuse_even_with_parity(self) -> None:
        self.fx.native = output(CAT_A, [*CAT_B[:4], 0.4375, 15.0], CHAIR)
        weak = output(CAT_A, [*CAT_B[:4], 0.390625, 15.0], CHAIR)
        self.fx.pages["jspi"] = page(weak, weak)
        got = self.fx.by_build()["jspi"]
        self.assertTrue(got["parity"]["passed"])
        self.assertEqual(got["cats"]["per_run"], [1, 1])
        self.assertEqual(got["reasons"], ["1 cat(s) at 0.4 or more, fewer than 2"])

    def test_a_repeat_that_differs_refuses(self) -> None:
        self.fx.pages["asyncify"] = page(self.fx.native, output(CAT_A, [*CAT_B[:4], 0.75, 15.0], CHAIR))
        got = self.fx.by_build()["asyncify"]
        self.assertTrue(got["parity"]["passed"])
        self.assertFalse(got["repeat"]["passed"])
        self.assertIn("run 2 against run 1", got["reasons"][0])

    def test_an_extra_detection_refuses(self) -> None:
        self.fx.pages["jspi"] = page(output(CAT_A, CAT_B, CHAIR, [5.0, 5.0, 50.0, 50.0, 0.3, 0.0]), self.fx.native)
        self.assertIn("detection counts differ", self.fx.by_build()["jspi"]["reasons"][0])

    def test_a_webgpu_build_whose_nodes_all_ran_on_the_cpu_refuses(self) -> None:
        self.fx.pages["jspi"] = page(self.fx.native, self.fx.native, logs=CPU_LOG)
        self.fx.pages["asyncify"] = page(self.fx.native, self.fx.native, logs=[])
        got = self.fx.by_build()
        self.assertEqual(got["jspi"]["reasons"], ["no node placed on WebGpuExecutionProvider: {'CPUExecutionProvider': 717}"])
        self.assertEqual(got["jspi"]["providers"]["shares"], {"CPUExecutionProvider": 1.0})
        self.assertEqual(got["asyncify"]["reasons"], ["no node placement in the log: the provider that ran is unproven"])

    def test_jsep_must_reach_its_own_provider(self) -> None:
        self.fx.pages["jsep"] = page(self.fx.native, self.fx.native)
        got = self.fx.by_build("--jsep")["jsep"]
        self.assertEqual(got["providers"]["required"], "JsExecutionProvider")
        self.assertEqual(got["verdict"], "refuse")

    def test_page_errors_and_wrong_outputs_refuse(self) -> None:
        self.fx.pages["jspi"] = page(error="Error: no available backend found\n    at x")
        self.fx.pages["asyncify"] = page(self.fx.native, self.fx.native)
        self.fx.pages["asyncify"]["runs"][0]["dims"] = [1, 300, 4]
        self.fx.pages["cpu"] = page(self.fx.native, logs=CPU_LOG)
        got = self.fx.by_build()
        self.assertEqual(got["jspi"]["reasons"][0], "the page failed: Error: no available backend found")
        self.assertIn("not float32 [1, 300, 6]", got["asyncify"]["reasons"][0])
        self.assertEqual(got["cpu"]["reasons"], ["1 run(s): parity needs a run and its repeat"])

    def test_a_missing_build_is_refused_and_nothing_is_written(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        fx = Fixture(Path(temp.name), builds=("asyncify", "cpu"))
        with self.assertRaisesRegex(web.ParityError, "build jspi is not staged"):
            web.run(fx.args(), runner=fx.runner, native=lambda *_: fx.native, photo=lambda _: (b"", 0, 0))
        with self.assertRaisesRegex(web.ParityError, "build jsep is not staged"):
            web.run(fx.args("--build", "cpu", "--jsep"), runner=fx.runner)
        self.assertFalse((fx.root / "report").exists())
        self.assertEqual(fx.commands, [])

    def test_changed_bytes_another_model_or_an_old_report_are_refused(self) -> None:
        (self.fx.site / "ort" / "1.31.1-cpu" / "ort.wasm.min.mjs").write_text("changed\n", encoding="utf-8")
        with self.assertRaisesRegex(web.ParityError, "ort.wasm.min.mjs: sha256 .* differs from the manifest"):
            self.fx.run()
        self.fx.model.write_bytes(b"another model")
        with self.assertRaisesRegex(web.ParityError, "is not the DEIM model"):
            self.fx.run("--build", "jspi")
        self.fx.model.write_bytes(b"model")
        (self.fx.root / "report").mkdir()
        with self.assertRaisesRegex(web.ParityError, "report exists"):
            self.fx.run("--build", "jspi")
        self.assertEqual(self.fx.commands, [])

    def test_a_build_without_bundle_is_not_run_and_another_js_layer_decides_nothing(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        fx = Fixture(Path(temp.name), bundles=False)
        fx.pages["cpu"] = page(fx.native, fx.native, logs=CPU_LOG)
        got = {entry["build"]: entry for entry in fx.run()}
        self.assertEqual(fx.commands, [])
        self.assertEqual((got["cpu"]["js"], got["cpu"]["decides"], got["cpu"]["verdict"]), (None, False, "refuse"))
        self.assertIn("no JS bundle staged", got["cpu"]["reasons"][0])
        js = fx.root / "js"
        js.mkdir()
        (js / "ort.wasm.mjs").write_text("upstream\n", encoding="utf-8")
        (fx.root / "report").rename(fx.root / "old")
        cpu = fx.by_build("--build", "cpu", "--js-dir", str(js))["cpu"]
        self.assertEqual(fx.commands[0][fx.commands[0].index("--module") + 1], "js/ort.wasm.mjs")
        self.assertEqual((cpu["verdict"], cpu["decides"], cpu["js"]["from"]), ("ship", False, "js-dir"))

    def test_decode_follows_vision_core(self) -> None:
        rows = output([64.0, 64.0, 128.0, 128.0, 0.25, 15.0], [0.0, 0.0, 1.0, 1.0, 0.2499, 15.0],
                      [0.0, 0.0, 1.0, 1.0, 0.9, 80.0], [0.0, 0.0, 1.0, 1.0, 0.9, float("nan")],
                      [5.0, 0.0, 1.0, 1.0, 0.9, 1.0], [-64.0, 0.0, 700.0, 640.0, 0.9, 2.7])
        got = web.decode(rows, 1280, 960)
        self.assertEqual(got["detections"], [{"class": 15, "score": 0.25, "box": [128.0, 96.0, 256.0, 192.0]},
                                             {"class": 2, "score": 0.9, "box": [0.0, 0.0, 1280.0, 960.0]}])
        with self.assertRaisesRegex(web.ParityError, "not 300x6"):
            web.decode([0.0] * 6, 1, 1)

    def test_stretch_is_nearest_neighbour_in_rgb_planes(self) -> None:
        rgb = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 51, 102, 153])  # 2x2: red green / blue grey
        tensor = web.stretch_nchw(rgb, 2, 2, size=4)
        self.assertEqual(list(tensor[:4]), [1.0, 1.0, 0.0, 0.0])
        self.assertEqual(list(tensor[8:12]), [0.0, 0.0, tensor[8 + 2], tensor[8 + 3]])
        self.assertAlmostEqual(tensor[8 + 2], 0.2, places=6)
        self.assertEqual(len(tensor), 3 * 16)
        self.assertEqual(list(tensor[16:20]), [0.0, 0.0, 1.0, 1.0])
        with self.assertRaisesRegex(web.ParityError, "not a 2x2 RGB image"):
            web.stretch_nchw(rgb[:-1], 2, 2)

    def test_main_exits_one_when_a_build_is_refused(self) -> None:
        def fake_run(args: argparse.Namespace) -> list[dict[str, Any]]:
            return self.fx.run("--build", "jspi", "--build", "cpu")

        self.fx.pages["jspi"] = page(self.fx.native, self.fx.native, logs=[])
        stdout = io.StringIO()
        with mock.patch.object(web, "run", fake_run), contextlib.redirect_stdout(stdout):
            code = web.main(["--site", "s", "--model", "m", "--image", "i", "--out", "o"])
        self.assertEqual(code, 1)
        self.assertIn("ORT-WEB-PARITY REFUSE: jspi (ort/1.31.1-jspi/) [no placement]", stdout.getvalue())
        self.assertIn("ORT-WEB-PARITY SHIP: cpu (ort/1.31.1-cpu/) [CPUExecutionProvider 100%]", stdout.getvalue())


    def test_main_exits_zero_when_only_the_requested_jsep_is_refused(self) -> None:
        def fake_run(args: argparse.Namespace) -> list[dict[str, Any]]:
            reports = self.fx.run("--build", "cpu")
            return [*reports, {**reports[0], "build": "jsep", "verdict": "refuse", "reasons": ["MaxPool ceil_mode"]}]

        with mock.patch.object(web, "run", fake_run), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(web.main(["--site", "s", "--model", "m", "--image", "i", "--out", "o", "--jsep"]), 0)

    def test_main_lets_jsep_decide_when_it_ran_alone(self) -> None:
        def fake_run(args: argparse.Namespace) -> list[dict[str, Any]]:
            reports = self.fx.run("--build", "cpu")
            return [{**reports[0], "build": "jsep", "verdict": "refuse", "reasons": ["MaxPool ceil_mode"]}]

        with mock.patch.object(web, "run", fake_run), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(web.main(["--site", "s", "--model", "m", "--image", "i", "--out", "o", "--build", "jsep"]), 1)


if __name__ == "__main__":
    unittest.main()
