#!/usr/bin/env python3
"""DEIM on the two-cats photo in each staged ORT Web build, against the native ORT CPU run. See docs/docs-sites.md#detector-parity-of-the-ort-web-builds"""

from __future__ import annotations

import argparse
import array
import base64
import collections
import hashlib
import importlib
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

# python -I leaves this file's own directory off sys.path, and the comparator and the profile rule live beside it.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare_detector_parity as parity  # noqa: E402
import verify_ort_profile as profile  # noqa: E402

# ModelANT's deim_dfine_n_coco-v2 and its contracts/fixtures/two_cats.jpg, the photo every parity run reads.
MODEL_SHA256 = "0bf16e851fd6471653b5f8243bac2d65db05e353cdf2a7b9181b2a58e94d09bd"
FIXTURE_SHA256 = "6d375ac20fadfd400b3033084f8b0581dcc145f7c14e3b24b97975e379c52999"
SIZE = 640
ROWS, STRIDE = 300, 6
CAT, CLASSES = 15, 80
CATS_MINIMUM, CATS_SCORE = 2, 0.4
# build: (JS module prefix, ORT Web execution provider, Chrome's GPU mode, the provider the nodes must reach).
BUILDS: dict[str, tuple[str, str, str, str]] = {
    "jspi": ("ort.jspi", "webgpu", "webgpu", "webgpu"),
    "asyncify": ("ort.webgpu", "webgpu", "webgpu", "webgpu"),
    "cpu": ("ort.wasm", "wasm", "none", "cpu"),
    "jsep": ("ort", "webgpu", "webgpu", "jsep"),
}
DEFAULT_BUILDS = ("jspi", "asyncify", "cpu")
# A placed node's line under its provider's placement line: "...AssignedToAnEp]   Tile (/model/decoder/Tile)".
PLACED_NODE = re.compile(r"AssignedToAnEp\]   ([A-Za-z0-9_.]+) \(")
HARNESS = Path(__file__).resolve().parents[2] / "linux" / "scripts" / "ort-web-detector-parity.js"
REPORT_KEYS = {"schema_version", "build", "path", "build_hash", "ort_version", "js", "decides", "chrome", "flags",
               "ep", "cross_origin_isolated", "jspi", "adapter", "create_ms", "run_ms", "tolerances", "native",
               "parity", "repeat", "cats", "providers", "verdict", "reasons"}

Runner = Callable[[list[str]], int]


class ParityError(Exception):
    """A requested build, its bytes, the model or the photo do not hold: no report is written."""


def sha256(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ParityError(f"{path} is not a regular file")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load_manifest(site: Path, wanted: Sequence[str]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """The stager's manifest and each wanted build in it, after every staged file matches its hash."""
    path = site / "ort" / "manifest.json"
    if not path.is_file():
        raise ParityError(f"{path} is missing: stage the builds with stage-ort-web.py first")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1 or not isinstance(manifest.get("builds"), list):
        raise ParityError(f"{path} is not a schema 1 ORT Web manifest")
    staged = {entry.get("build"): entry for entry in manifest["builds"] if isinstance(entry, dict)}
    builds = []
    for name in wanted:
        if name not in staged:
            raise ParityError(f"build {name} is not staged in {path}: refusing to report fewer builds")
        entry = staged[name]
        directory = site / entry["path"]
        for item in entry["files"]:
            actual = sha256(directory / item["file"])
            if actual != item["sha256"]:
                raise ParityError(f"{entry['path']}{item['file']}: sha256 {actual} differs from the manifest's {item['sha256']}")
        builds.append(entry)
    return manifest, builds


def js_module(build: dict[str, Any], js_dir: Path | None) -> tuple[str, dict[str, Any]] | None:
    """The page's ORT module for a build: its own staged bundle, else one from --js-dir, else None."""
    prefix = BUILDS[build["build"]][0]
    names = (f"{prefix}.min.mjs", f"{prefix}.mjs", f"{prefix}.bundle.min.mjs")
    bundles = {item["file"]: item for item in build["files"] if item["role"] == "bundle"}
    for name in names:
        if name in bundles:
            return f"site/{build['path']}{name}", {"from": "manifest", "file": name, "sha256": bundles[name]["sha256"]}
    if js_dir is None:
        return None
    for name in names:
        candidate = js_dir / name
        if candidate.is_file():
            return f"js/{name}", {"from": "js-dir", "file": name, "sha256": sha256(candidate)}
    return None


def stretch_nchw(rgb: bytes, width: int, height: int, size: int = SIZE) -> array.array:
    """OxidANT vision_core's stretch: nearest neighbour by integer index, RGB planes, pixel / 255."""
    if len(rgb) != width * height * 3:
        raise ParityError(f"{len(rgb)} bytes are not a {width}x{height} RGB image")
    unit = [value / 255 for value in range(256)]
    columns = [(x * width // size) * 3 for x in range(size)]
    planes = [array.array("f", bytes(4 * size * size)) for _ in range(3)]
    for y in range(size):
        row = (y * height // size) * width * 3
        at = y * size
        for channel, plane in enumerate(planes):
            plane[at:at + size] = array.array("f", [unit[rgb[row + column + channel]] for column in columns])
    planes[0].extend(planes[1])
    planes[0].extend(planes[2])
    return planes[0]


def decode(values: Sequence[float], width: int, height: int) -> dict[str, Any]:
    """output0's rows as a schema 1 detector result: vision_core's rules, the stretch undone, clamped to the photo."""
    if len(values) != ROWS * STRIDE:
        raise ParityError(f"output0 holds {len(values)} values, not {ROWS}x{STRIDE}")
    detections = []
    for start in range(0, ROWS * STRIDE, STRIDE):
        x1, y1, x2, y2, score, cls = values[start:start + STRIDE]
        if not math.isfinite(score) or score < parity.MIN_SCORE:
            continue
        if math.isnan(cls) or cls < 0 or cls >= CLASSES:
            continue
        if not all(math.isfinite(corner) for corner in (x1, y1, x2, y2)) or x2 < x1 or y2 < y1:
            continue
        box = [min(max(x1 * width / SIZE, 0.0), width), min(max(y1 * height / SIZE, 0.0), height),
               min(max(x2 * width / SIZE, 0.0), width), min(max(y2 * height / SIZE, 0.0), height)]
        detections.append({"class": int(cls), "score": float(score), "box": box})
    return {"schema_version": 1, "width": width, "height": height, "detections": detections}


def floats(data: str) -> array.array:
    values = array.array("f")
    values.frombytes(base64.b64decode(data, validate=True))
    if sys.byteorder != "little":
        values.byteswap()
    return values


def native_output(model: Path, tensor: array.array, threads: int) -> list[float]:
    """The native ORT CPU run of the same tensor: the reference every browser build is held to."""
    # The image's packages, which the stdlib-only type lane cannot see; the report never needs them.
    np = importlib.import_module("numpy")
    ort = importlib.import_module("onnxruntime")
    options = ort.SessionOptions()
    options.intra_op_num_threads = threads
    session = ort.InferenceSession(str(model), options, providers=["CPUExecutionProvider"])
    blob = np.frombuffer(tensor.tobytes(), dtype=np.float32).reshape(1, 3, SIZE, SIZE)
    return [float(v) for v in session.run(["output0"], {session.get_inputs()[0].name: blob})[0].reshape(-1)]


def read_photo(image: Path) -> tuple[bytes, int, int]:
    with importlib.import_module("PIL.Image").open(image) as photo:
        rgb = photo.convert("RGB")
        return rgb.tobytes(), rgb.width, rgb.height


def placed_ops(lines: list[str], skip: str) -> dict[str, dict[str, int]]:
    """The operator types ORT placed on each provider but skip, from the node lines under each placement line."""
    ops: dict[str, collections.Counter[str]] = {}
    current = None
    for line in lines:
        header = profile.PLACEMENT.search(line)
        if header:
            current = header[1]
            continue
        node = PLACED_NODE.search(line)
        if node and current and current != skip:
            ops.setdefault(current, collections.Counter())[node[1]] += 1
    return {provider: dict(counter.most_common()) for provider, counter in ops.items()}


def cats(result: dict[str, Any]) -> int:
    return sum(1 for item in result["detections"] if item["class"] == CAT and item["score"] >= CATS_SCORE)


def closest(cpu: dict[str, Any], web: dict[str, Any]) -> dict[str, float | int | None]:
    """The measured worst pair: each CPU detection's best same-class partner by IoU, for the report only."""
    ious, deltas = [], []
    for item in cpu["detections"]:
        same = [other for other in web["detections"] if other["class"] == item["class"]]
        if not same:
            ious.append(0.0)
            continue
        best = max(same, key=lambda other: parity.iou(item["box"], other["box"]))
        ious.append(parity.iou(item["box"], best["box"]))
        deltas.append(abs(item["score"] - best["score"]))
    return {"cpu_detections": len(cpu["detections"]), "web_detections": len(web["detections"]),
            "min_iou": min(ious, default=None), "max_score_delta": max(deltas, default=None)}


def checked(path: Path, result: dict[str, Any]) -> dict[str, Any]:
    """The result through the comparator's own file validation, written where the report points."""
    path.write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
    return parity.load(path)


def decoded_runs(name: str, page: dict[str, Any], cpu: dict[str, Any], out: Path, reasons: list[str]) -> list[dict[str, Any]]:
    """Each run's output0 as a checked detector result; a run that cannot be read adds its reason instead."""
    runs = []
    if page.get("error"):
        reasons.append(f"the page failed: {str(page['error']).splitlines()[0]}")
    for index, run in enumerate(page.get("runs") or [], start=1):
        try:
            if run.get("dims") != [1, ROWS, STRIDE] or run.get("type") != "float32":
                raise ParityError(f"output0 is {run.get('type')} {run.get('dims')}, not float32 [1, {ROWS}, {STRIDE}]")
            runs.append(checked(out / f"{name}-run{index}.json", decode(floats(run["data"]), cpu["width"], cpu["height"])))
        except (ParityError, ValueError, TypeError, KeyError) as error:
            reasons.append(f"run {index}: {error}")
    if not reasons and len(runs) < 2:
        reasons.append(f"{len(runs)} run(s): parity needs a run and its repeat")
    return runs


def compared(cpu: dict[str, Any], runs: list[dict[str, Any]], reasons: list[str]) -> dict[str, Any]:
    """Parity of the first run with the native one, of every later run with the first, and the cats per run."""
    found: dict[str, Any] = {"passed": True, "error": None, **closest(cpu, runs[0])}
    try:
        parity.compare(cpu, runs[0])
    except ValueError as error:
        found.update(passed=False, error=str(error))
        reasons.append(f"parity with the native CPU run: {error}")
    repeat: dict[str, Any] = {"passed": True, "error": None}
    for index, again in enumerate(runs[1:], start=2):
        try:
            parity.compare(runs[0], again, pairwise=True)
        except ValueError as error:
            repeat = {"passed": False, "error": f"run {index}: {error}"}
            reasons.append(f"run {index} against run 1: {error}")
    counted = [cats(run) for run in runs]
    confident = {"minimum": CATS_MINIMUM, "score": CATS_SCORE, "per_run": counted, "passed": min(counted) >= CATS_MINIMUM}
    if not confident["passed"]:
        reasons.append(f"{min(counted)} cat(s) at {CATS_SCORE} or more, fewer than {CATS_MINIMUM}")
    return {"parity": found, "repeat": repeat, "cats": confident}


def placed(kind: str, logs: list[str], reasons: list[str]) -> dict[str, Any]:
    """Where ORT put the nodes; a build whose provider got none ran on something else."""
    counts = profile.placement_counts(logs)
    wanted = profile.PROVIDERS[kind]
    if not counts:
        reasons.append("no node placement in the log: the provider that ran is unproven")
    elif counts[wanted] == 0:
        reasons.append(f"no node placed on {wanted}: {dict(counts)}")
    return {"source": "node placement log", "required": wanted, "counts": dict(counts),
            "shares": profile.provider_shares(counts), "elsewhere": placed_ops(logs, wanted)}


def judge(build: dict[str, Any], kind: str, page: dict[str, Any], cpu: dict[str, Any], out: Path) -> dict[str, Any]:
    """One build's findings: parity with the CPU run, the repeat, the cats and where the nodes ran."""
    reasons: list[str] = []
    runs = decoded_runs(build["build"], page, cpu, out, reasons)
    result = compared(cpu, runs, reasons) if runs and not reasons else {"parity": None, "repeat": None, "cats": None}
    return {**result, "providers": placed(kind, page.get("logs") or [], reasons), "reasons": reasons}


def report(manifest: dict[str, Any], build: dict[str, Any], js: dict[str, Any] | None, page: dict[str, Any],
           judged: dict[str, Any], native: dict[str, Any]) -> dict[str, Any]:
    reasons = judged["reasons"]
    return {
        "schema_version": 1, "build": build["build"], "path": build["path"], "build_hash": build["build_hash"],
        "ort_version": manifest.get("ort", {}).get("version"), "js": js,
        # Only the build's own bundle can decide shipping: another JS layer proves the wasm, not what ships.
        "decides": js is not None and js["from"] == "manifest",
        "chrome": page.get("chrome"), "flags": page.get("flags"), "ep": page.get("ep"),
        "cross_origin_isolated": page.get("crossOriginIsolated"), "jspi": page.get("jspi"), "adapter": page.get("adapter"),
        "create_ms": page.get("createMs"), "run_ms": [run.get("ms") for run in page.get("runs") or []],
        "tolerances": {"min_iou": parity.MIN_IOU, "max_score_delta": parity.MAX_SCORE_DELTA, "min_score": parity.MIN_SCORE},
        "native": native, "parity": judged["parity"], "repeat": judged["repeat"], "cats": judged["cats"],
        "providers": judged["providers"], "verdict": "ship" if not reasons else "refuse", "reasons": reasons,
    }


def run_build(args: argparse.Namespace, build: dict[str, Any], module: str, work: Path, runner: Runner) -> dict[str, Any]:
    _, ep, gpu, _ = BUILDS[build["build"]]
    # The page's answer with ORT's whole log stays beside the report: a failed build is diagnosed from it.
    page_out = args.out / f"{build['build']}-page.json"
    command = ["node", str(args.harness), "--site", str(args.site), "--module", module, "--wasm-dir", f"site/{build['path']}",
               "--ep", ep, "--gpu", gpu, "--model", str(args.model), "--input", str(work / "input.bin"),
               "--out", str(page_out), "--runs", str(args.runs), "--threads", str(args.threads)]
    if args.js_dir:
        command += ["--js-dir", str(args.js_dir)]
    code = runner(command)
    if not page_out.is_file():
        return {"error": f"the harness exited {code} without a result"}
    return json.loads(page_out.read_text(encoding="utf-8"))


def subprocess_runner(command: list[str]) -> int:
    return subprocess.run(command, check=False).returncode


def run(args: argparse.Namespace, runner: Runner | None = None,
        native: Callable[[Path, array.array, int], list[float]] | None = None,
        photo: Callable[[Path], tuple[bytes, int, int]] | None = None) -> list[dict[str, Any]]:
    """Every wanted build's report under args.out, after the native run; the callables default to Chrome, ORT and Pillow."""
    runner, native, photo = runner or subprocess_runner, native or native_output, photo or read_photo
    wanted = list(args.builds or DEFAULT_BUILDS) + (["jsep"] if args.jsep and "jsep" not in (args.builds or ()) else [])
    manifest, builds = load_manifest(args.site, wanted)
    for path, expected, what in ((args.model, MODEL_SHA256, "DEIM model"), (args.image, FIXTURE_SHA256, "two-cats photo")):
        if sha256(path) != expected:
            raise ParityError(f"{path} is not the {what} the parity rules were taken from (sha256 {expected})")
    if args.out.exists():
        raise ParityError(f"{args.out} exists; remove it before a new report")
    work = Path(tempfile.mkdtemp(prefix="ort-web-parity-"))
    try:
        rgb, width, height = photo(args.image)
        tensor = stretch_nchw(rgb, width, height)
        (work / "input.bin").write_bytes(tensor.tobytes() if sys.byteorder == "little" else _swapped(tensor))
        args.out.mkdir(parents=True)
        cpu = checked(args.out / "native-cpu.json", decode(native(args.model, tensor, args.threads), width, height))
        parity.compare(cpu, cpu)
        native_entry = {"provider": "CPUExecutionProvider", "detections": len(cpu["detections"]), "cats": cats(cpu)}
        reports = []
        for build in builds:
            kind = BUILDS[build["build"]][3]
            chosen = js_module(build, args.js_dir)
            if chosen is None:
                page: dict[str, Any] = {"error": "no JS bundle staged for this build (the image builds them on amd64 only) and none in --js-dir"}
                js = None
            else:
                module, js = chosen
                page = run_build(args, build, module, work, runner)
            judged = judge(build, kind, page, cpu, args.out)
            entry = report(manifest, build, js, page, judged, native_entry)
            (args.out / f"{build['build']}.json").write_text(json.dumps(entry, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            reports.append(entry)
        summary = {"schema_version": 1, "ort_version": manifest.get("ort", {}).get("version"),
                   "builds": [{key: entry[key] for key in ("build", "path", "verdict", "decides", "reasons")} for entry in reports]}
        (args.out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return reports
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _swapped(tensor: array.array) -> bytes:
    copy = array.array("f", tensor)
    copy.byteswap()
    return copy.tobytes()


def arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", type=Path, required=True, help="the directory stage-ort-web.py wrote ort/ below")
    parser.add_argument("--model", type=Path, required=True, help="ModelANT's deim_dfine_n_coco.onnx (v2)")
    parser.add_argument("--image", type=Path, required=True, help="ModelANT's contracts/fixtures/two_cats.jpg")
    parser.add_argument("--out", type=Path, required=True, help="the report directory, which must not exist")
    parser.add_argument("--build", dest="builds", action="append", choices=BUILDS, help="only this build (repeatable)")
    parser.add_argument("--jsep", action="store_true", help="also run the JSEP build, which must be staged")
    parser.add_argument("--js-dir", type=Path, help="ort.*.mjs for builds staged without a bundle; such a report decides nothing")
    parser.add_argument("--runs", type=int, default=2, help="runs per session, compared pairwise (default: %(default)s)")
    parser.add_argument("--threads", type=int, default=2, help="wasm and native CPU threads (default: %(default)s)")
    parser.add_argument("--harness", type=Path, default=HARNESS, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.runs < 2 or args.threads < 1:
        parser.error("--runs takes 2 or more, --threads 1 or more")
    return args


def main(argv: list[str]) -> int:
    args = arguments(argv)
    try:
        reports = run(args)
    except (ParityError, OSError, ValueError, KeyError, TypeError, ImportError) as error:
        print(f"ORT-WEB-PARITY FAIL: {error}", file=sys.stderr)
        return 1
    for entry in reports:
        shares = ", ".join(f"{name} {share:.0%}" for name, share in entry["providers"]["shares"].items())
        print(f"ORT-WEB-PARITY {entry['verdict'].upper()}: {entry['build']} ({entry['path']}) "
              f"[{shares or 'no placement'}]{'' if entry['decides'] else ' (decides nothing: not its own bundle)'}"
              + "".join(f"\n  - {reason}" for reason in entry["reasons"]))
    # JSEP runs only on request and cannot run DEIM, so the shipping builds decide unless none was run.
    deciding = [entry for entry in reports if entry["build"] in DEFAULT_BUILDS] or reports
    return 0 if all(entry["verdict"] == "ship" for entry in deciding) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
