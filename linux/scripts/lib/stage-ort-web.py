#!/usr/bin/env python3
"""Stage the image's ORT Web builds under ort/<version>-<build hash>/ with a manifest. See docs/docs-sites.md#staging-ort-web-for-an-app"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

RECEIPT = "ort-webgpu-wasm.json"
PROBE_LICENSE = "ort-webgpu-factory-probe.LICENSE"
ORT_LICENSES = ("LICENSE", "ThirdPartyNotices.txt")
STEM = "ort-wasm-simd-threaded"
# name: (receipt flavor, file stem, JS bundle prefix); the order is the app's order of preference.
BUILDS: dict[str, tuple[str, str, str]] = {
    "jspi": ("jspi", f"{STEM}.jspi", "ort.jspi"),
    "asyncify": ("asyncify", f"{STEM}.asyncify", "ort.webgpu"),
    "cpu": ("cpu", STEM, "ort.wasm"),
    "jsep": ("jsep", f"{STEM}.jsep", "ort"),
}
DEFAULT_BUILDS = ("jspi", "asyncify", "cpu")
# The WebGPU builds are only ever proven by the factory receipt, so one without it is refused.
RECEIPT_REQUIRED = ("jspi", "asyncify")
HASH_LENGTH = 16
WASM_MAGIC = b"\0asm\x01\0\0\0"


class StageError(Exception):
    """A requested build, its receipt, its bytes or its license texts do not hold."""


def sha256(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise StageError(f"{path} is not a regular file")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise StageError(f"{path} is not a JSON object")
    return data


def load_receipt(source: Path) -> tuple[dict[str, Any], str]:
    """The image's schema 2 receipt and the ORT version its source ref names."""
    path = source / RECEIPT
    if not path.is_file():
        raise StageError(f"{path} is missing: the WebGPU builds have no proof")
    receipt = read_json(path)
    ref = receipt.get("source", {}).get("ref", "")
    revision = receipt.get("source", {}).get("revision", "")
    match = re.fullmatch(r"v?(\d+\.\d+\.\d+)", ref)
    if receipt.get("schema_version") != 2 or match is None or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise StageError(f"{path}: not a schema 2 receipt with a release ref and a full revision")
    if not isinstance(receipt.get("flavors"), dict):
        raise StageError(f"{path}: no flavors")
    return receipt, match.group(1)


def check_named(source: Path, entry: Any, name: str, what: str) -> str:
    """The receipt's sha256 for <name>, after the bytes on disk match it."""
    if not isinstance(entry, dict) or entry.get("path") != name:
        raise StageError(f"the receipt's {what} is not {name}")
    actual = sha256(source / name)
    if entry.get("sha256") != actual:
        raise StageError(f"{name}: sha256 {actual} differs from the receipt's {entry.get('sha256')}")
    return actual


def check_flavor(source: Path, receipt: dict[str, Any], build: str) -> tuple[dict[str, Any] | None, set[str]]:
    """The receipt's proof of one build and the files it names, after their bytes are checked; None where it has none."""
    flavor, stem, _ = BUILDS[build]
    phase = receipt["flavors"].get(flavor)
    if phase is None:
        if build in RECEIPT_REQUIRED:
            raise StageError(f"build {build}: the receipt has no {flavor} flavor")
        return None, set()
    product = phase.get("product", {})
    check_named(source, product, f"{stem}.wasm", f"{flavor} product")
    check_named(source, product.get("loader"), f"{stem}.mjs", f"{flavor} loader")
    named = {f"{stem}.wasm", f"{stem}.mjs"}
    if "probe_license" in product:
        check_named(source, product["probe_license"], PROBE_LICENSE, f"{flavor} probe license")
        named.add(PROBE_LICENSE)
    runtime = phase.get("runtime")
    if runtime is not None:
        check_named(source, runtime, runtime.get("path", ""), f"{flavor} runtime receipt")
        ran = read_json(source / runtime["path"])
        if ran.get("product") != product or ran.get("source") != receipt["source"] or ran.get("returncode") != 0:
            raise StageError(f"build {build}: its runtime receipt names other bytes or a failed probe")
    return {"flavor": flavor, "configured_flags": phase.get("configured_flags"),
            "cmake_cache_sha256": phase.get("cmake_cache_sha256"), "runtime": runtime}, named


def bundles(source: Path, prefix: str) -> list[str]:
    pattern = re.compile(re.escape(prefix) + r"(\.bundle)?(\.min)?\.mjs")
    return sorted(p.name for p in source.iterdir() if pattern.fullmatch(p.name))


def wheel_licenses(site_packages: Path, version: str) -> tuple[dict[str, Path], dict[str, str]]:
    """LICENSE and ThirdPartyNotices.txt of the onnxruntime wheel, only when it is the receipt's version."""
    for record in sorted(site_packages.glob("*.dist-info/RECORD")):
        rows = {line.split(",")[0]: line.split(",")[1] for line in record.read_text(encoding="utf-8").splitlines()
                if line.count(",") >= 2}
        if not all(f"onnxruntime/{name}" in rows for name in ORT_LICENSES):
            continue
        metadata = (record.parent / "METADATA").read_text(encoding="utf-8")
        distribution = re.search(r"^Name: (.+)$", metadata, re.MULTILINE)
        version_line = re.search(r"^Version: (.+)$", metadata, re.MULTILINE)
        wheel = version_line[1].strip() if version_line else "unknown"
        if wheel != version:
            raise StageError(f"the onnxruntime wheel is {wheel}, the receipt's ORT is {version}: its license texts are not this build's")
        files = {name: site_packages / "onnxruntime" / name for name in ORT_LICENSES}
        for name, path in files.items():
            digest = base64.urlsafe_b64encode(bytes.fromhex(sha256(path))).rstrip(b"=").decode()
            if rows[f"onnxruntime/{name}"] != f"sha256={digest}":
                raise StageError(f"{path} differs from its wheel's RECORD")
        return files, {"from": "wheel", "distribution": distribution[1].strip() if distribution else "unknown", "version": wheel}
    raise StageError(f"no wheel in {site_packages} ships onnxruntime/LICENSE and ThirdPartyNotices.txt")


def ort_licenses(source: Path, site_packages: Path | None, version: str) -> tuple[dict[str, Path], dict[str, str]]:
    """ORT's license texts from beside the web output when the image put them there, else from the wheel."""
    beside = {name: source / name for name in ORT_LICENSES}
    if all(path.is_file() for path in beside.values()):
        return beside, {"from": "image", "version": version}
    if site_packages is None:
        found = sorted(Path("/opt/venv/lib").glob("python3*/site-packages"))
        if len(found) != 1:
            raise StageError("no ORT license texts beside the web output and no single /opt/venv site-packages: pass --site-packages")
        site_packages = found[0]
    return wheel_licenses(site_packages, version)


def stage_build(source: Path, build: str, receipt: dict[str, Any], licenses: dict[str, Path], js: bool) -> dict[str, Any]:
    """One build's files, hashes and receipt, checked but not yet copied."""
    _, stem, prefix = BUILDS[build]
    wasm, loader = f"{stem}.wasm", f"{stem}.mjs"
    for name in (wasm, loader):
        if not (source / name).is_file():
            raise StageError(f"build {build}: {name} is missing; refusing to ship fewer builds")
    with (source / wasm).open("rb") as stream:
        if stream.read(8) != WASM_MAGIC:
            raise StageError(f"{wasm} is not a WebAssembly v1 module")
    proof, named = check_flavor(source, receipt, build)
    js_files = bundles(source, prefix) if js else []
    if js and not js_files:
        raise StageError(f"build {build}: no {prefix}*.mjs bundle beside its wasm (built on amd64 only; --no-js-bundles on arm64)")
    roles = {wasm: ("wasm", source / wasm), loader: ("loader", source / loader)}
    roles.update({name: ("bundle", source / name) for name in js_files})
    roles.update({name: ("license", path) for name, path in licenses.items()})
    roles[PROBE_LICENSE] = ("license", source / PROBE_LICENSE)
    if any(name.endswith(".bak") for name in roles):
        raise StageError(f"build {build}: a *.bak file would ship")
    files = [{"file": name, "role": role, "sha256": sha256(path), "size": path.stat().st_size,
              "hash_from": "receipt" if name in named else "bytes", "_from": path}
             for name, (role, path) in sorted(roles.items())]
    digest = hashlib.sha256("".join(f"{e['sha256']}  {e['file']}\n" for e in files).encode()).hexdigest()
    return {"build": build, "build_hash": digest[:HASH_LENGTH], "receipt": proof, "files": files}


def write_tree(out: Path, version: str, staged: list[dict[str, Any]], manifest: dict[str, Any]) -> None:
    target = out / "ort"
    if target.exists():
        raise StageError(f"{target} exists; remove it before staging")
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".ort-stage-", dir=out))
    try:
        for build in staged:
            build["path"] = f"ort/{version}-{build['build_hash']}/"
            directory = work / f"{version}-{build['build_hash']}"
            directory.mkdir()
            for entry in build["files"]:
                copied = directory / entry["file"]
                shutil.copyfile(entry.pop("_from"), copied)
                copied.chmod(0o644)
                if sha256(copied) != entry["sha256"]:
                    raise StageError(f"{copied} changed while it was copied")
        manifest["builds"] = staged
        (work / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        work.chmod(0o755)
        work.rename(target)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def stage(args: argparse.Namespace) -> dict[str, Any]:
    source: Path = args.source
    receipt, version = load_receipt(source)
    licenses, license_origin = ort_licenses(source, args.site_packages, version)
    if not (source / PROBE_LICENSE).is_file():
        raise StageError(f"{source / PROBE_LICENSE} is missing")
    builds = [*DEFAULT_BUILDS, *(("jsep",) if args.jsep else ())]
    staged = [stage_build(source, build, receipt, licenses, not args.no_js_bundles) for build in builds]
    manifest: dict[str, Any] = {
        "schema_version": 1,
        "ort": {"version": version, "ref": receipt["source"]["ref"], "revision": receipt["source"]["revision"],
                "config": receipt.get("config")},
        "image_receipt": {"path": RECEIPT, "sha256": sha256(source / RECEIPT)},
        "licenses": license_origin,
        "js_bundles": not args.no_js_bundles,
    }
    write_tree(args.out, version, staged, manifest)
    return manifest


def arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("/usr/local/lib/onnxruntime-web"),
                        help="the image's ORT Web output (default: %(default)s)")
    parser.add_argument("--out", type=Path, required=True, help="the site directory; ort/ is written below it")
    parser.add_argument("--jsep", action="store_true", help="also stage the JSEP build, after CPU")
    parser.add_argument("--no-js-bundles", action="store_true",
                        help="stage wasm and loader without the ort.*.mjs bundles, which only amd64 builds")
    parser.add_argument("--site-packages", type=Path,
                        help="where the onnxruntime wheel is, when ORT's license texts are not beside the web output")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = arguments(argv)
    try:
        manifest = stage(args)
    except (StageError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"ORT-WEB-STAGE FAIL: {error}", file=sys.stderr)
        return 1
    for build in manifest["builds"]:
        print(f"ORT-WEB-STAGE OK: {build['build']} -> {build['path']} ({len(build['files'])} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
