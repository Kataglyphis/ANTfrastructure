"""Measure real BuildKit selected-context reuse; this does not prove compiler-cache hits, vendor builds or image/GPU acceptance."""

import argparse
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

from script_closure import profile_for, read_profile, selected_file, stage
from source_ci.common import fingerprint, git, read, require, save, timestamp

ROOT = Path(__file__).resolve().parents[2]
PROFILES = (("sdk-core", "Dockerfile.sdk", "copy"), ("migraphx-image", "Dockerfile.amd", "mount"))
UNSELECTED = "01-core/context-management.sh"
SELECTED = "01-core/logging.sh"


def require_digest(digest: str) -> None:
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", digest), "Pass an explicit SHA256 digest")


def base_identity(context: Path, digest: str) -> str:
    require_digest(digest)
    index = read(context / "index.json")
    require(any(row["digest"] == digest for row in index["manifests"]), "OCI base index does not match the supplied digest")
    blob = context / "blobs/sha256" / digest.split(":")[1]
    require(fingerprint(blob) == digest.split(":")[1], "OCI base index bytes differ")
    return fingerprint(context / "index.json")


def oci_blob(context: Path, descriptor: dict[str, Any]) -> Path:
    digest = descriptor["digest"]
    require_digest(digest)
    path = selected_file(context, "blobs/sha256/" + digest.split(":")[1])
    require(type(descriptor["size"]) is int and descriptor["size"] > 0 and path.stat().st_size == descriptor["size"], "OCI blob size differs")
    require(fingerprint(path) == digest.removeprefix("sha256:"), "OCI blob hash differs")
    return path


def native_base(context: Path, digest: str, output: Path) -> dict[str, Any]:
    base_identity(context, digest)
    matches = [row for row in read(context / "index.json")["manifests"] if row["digest"] == digest]
    require(len(matches) == 1, "Expected one pinned OCI root descriptor")
    descriptor = matches[0]
    document = read(oci_blob(context, descriptor))
    if "manifests" in document:
        matches = [row for row in document["manifests"] if row.get("platform") == {"os": "linux", "architecture": "amd64"}]
        require(len(matches) == 1, "Expected one exact linux/amd64 child")
        descriptor = matches[0]
        document = read(oci_blob(context, descriptor))
    require(descriptor["mediaType"] == "application/vnd.oci.image.manifest.v1+json" and document.get("schemaVersion") == 2, "Expected a native OCI image manifest")
    config = read(oci_blob(context, document["config"]))
    require(config.get("architecture") == "amd64" and config.get("os") == "linux", "Native OCI config platform differs")
    require(isinstance(document["layers"], list) and bool(document["layers"]), "Native OCI image has no layers")
    closure = [descriptor, document["config"], *document["layers"]]
    originals = {row["digest"]: oci_blob(context, row) for row in closure}
    output.mkdir()
    (output / "blobs/sha256").mkdir(parents=True)
    for digest_name, path in originals.items():
        shutil.copyfile(path, output / "blobs/sha256" / digest_name.removeprefix("sha256:"))
    for row in closure:
        oci_blob(output, row)
    save(output / "index.json", {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [descriptor]})
    save(output / "oci-layout", {"imageLayoutVersion": "1.0.0"})
    return {"digest": descriptor["digest"], "index_sha256": fingerprint(output / "index.json"),
            "source_blobs": {str(path): name.removeprefix("sha256:") for name, path in originals.items()}}


def recipe(transport: str) -> str:
    require(transport in ("copy", "mount"), "Unknown selected-context transport")
    lines = ["# syntax=docker/dockerfile:1.28.0", "ARG BASE_IMAGE"]
    if transport == "copy":
        lines.append("FROM hub-scripts AS sdk-core-scripts")
    lines += ["FROM ${BASE_IMAGE} AS consumer", "ARG CACHE_NONCE"]
    if transport == "copy":
        lines.append("COPY --from=sdk-core-scripts / /opt/scripts/")
    mount = "--mount=type=bind,from=hub-scripts,source=/,target=/opt/scripts,ro " if transport == "mount" else ""
    lines.append("RUN --network=none " + mount +
                 'set -eu; digest="$(sha256sum /opt/scripts/SCRIPT-CLOSURE.json)"; digest="${digest%% *}"; '
                 'printf "%s %s\\n" "$CACHE_NONCE" "$digest" > /cache-proof.txt; '
                 'printf "SCRIPT_CLOSURE_PROBE %s %s\\n" "$CACHE_NONCE" "$digest"')
    lines += ["FROM scratch AS result", "COPY --from=consumer /cache-proof.txt /cache-proof.txt"]
    return "\n".join(lines) + "\n"


def production_contract(source: Path, profile: str, dockerfile: str, transport: str) -> str:
    path = source / "linux" / dockerfile
    require(profile_for(path) == profile, "Production Dockerfile profile differs")
    text = path.read_text()
    fragments = ("FROM hub-scripts AS sdk-core-scripts", "COPY --from=sdk-core-scripts / /opt/scripts/") if transport == "copy" else (
        "--mount=type=bind,from=hub-scripts,source=/,target=/opt/scripts,ro",)
    require(all(text.count(fragment) == 1 for fragment in fragments), "Production selected-context transport differs")
    return fingerprint(path)


def consumer_step(log: str, nonce: str, digest: str, cached: bool) -> str:
    headers = re.findall(r"^#(\d+) \[consumer \d+/\d+\] RUN .+$", log, re.MULTILINE)
    require(len(headers) == 1, "Expected exactly one actual consumer RUN step")
    step = headers[0]
    cache_lines = re.findall(r"^#" + step + r" CACHED$", log, re.MULTILINE)
    markers = re.findall(r"^#" + step + r" \d+(?:\.\d+)? SCRIPT_CLOSURE_PROBE (\S+) (\S+)$", log, re.MULTILINE)
    if cached:
        require(len(cache_lines) == 1 and not markers, "Unselected source change did not reuse the consumer RUN")
    else:
        require(not cache_lines and markers == [(nonce, digest)], "Required consumer execution marker is absent or mismatched")
        require(re.search(r"^#" + step + r" DONE \d+(?:\.\d+)?s$", log, re.MULTILINE), "Consumer step did not finish")
    return step


def artifact(directory: Path, nonce: str, digest: str) -> str:
    path = directory / "cache-proof.txt"
    require(sorted(item.name for item in directory.iterdir()) == ["cache-proof.txt"], "Unexpected exported cache-probe files")
    require(not path.is_symlink() and path.is_file(), "Cache-probe artifact must be a regular file")
    require(path.read_bytes() == f"{nonce} {digest}\n".encode(), "Exported artifact does not bind the selected receipt")
    return fingerprint(path)


def mirror_inputs(scripts: Path, profile: str, output: Path) -> dict[Path, str]:
    manifests: set[Path] = set()
    selected = read_profile(scripts, profile, manifests=manifests)
    inputs = {*selected.values(), *manifests, scripts / UNSELECTED}
    require(scripts / SELECTED in selected.values() and scripts / UNSELECTED not in selected.values(), "Cache probe source controls no longer match the profile")
    fingerprints = {path: fingerprint(path) for path in inputs}
    for path in inputs:
        destination = output / path.relative_to(scripts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
    return fingerprints


def build_command(args: argparse.Namespace, context: Path, scripts: Path, output: Path, nonce: str) -> list[str]:
    command = [args.engine, "build", "--platform=linux/amd64", "--progress=plain", "--pull=false"]
    if args.buildkit_host:
        command += ["--buildkit-host", args.buildkit_host]
    command += ["--build-arg", "BASE_IMAGE=ubuntu@" + args.base_digest, "--build-arg", "CACHE_NONCE=" + nonce,
                "--build-context", "ubuntu@" + args.base_digest + "=oci-layout://" + str(args.base_context),
                "--build-context", "hub-scripts=" + str(scripts), "--output", "type=local,dest=" + str(output), str(context)]
    return command


def execute_phase(args: argparse.Namespace, output: Path, mirror: Path, profile: str, transport: str, nonce: str, cached: bool) -> dict[str, Any]:
    output.mkdir()
    scripts = output / "scripts"
    stage(mirror, profile, scripts)
    digest = fingerprint(scripts / "SCRIPT-CLOSURE.json")
    context = output / "build-context"
    context.mkdir()
    dockerfile = context / "Dockerfile"
    dockerfile.write_text(recipe(transport))
    command = build_command(args, context, scripts, output / "export", nonce)
    save(output / "invocation.json", {"command": command, "receipt_sha256": digest, "expected_cached": cached,
                                      "dockerfile_sha256": fingerprint(dockerfile)})
    with (output / "build.log").open("wb") as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=False, timeout=120)
    require(result.returncode == 0, "BuildKit solve failed; retain its build.log")
    step = consumer_step((output / "build.log").read_text(), nonce, digest, cached)
    record = {"receipt_sha256": digest, "artifact_sha256": artifact(output / "export", nonce, digest),
              "consumer_step": step, "cached": cached, "command_exit_status": result.returncode}
    save(output / "phase-proof.json", record)
    return record


def replay_profile(args: argparse.Namespace, profile: str, dockerfile: str, transport: str, nonce: str) -> dict[str, Any]:
    scripts = args.source / "linux/scripts"
    production = production_contract(args.source, profile, dockerfile, transport)
    output = args.output / profile
    output.mkdir()
    mirror = output / "source-mirror"
    original = mirror_inputs(scripts, profile, mirror)
    first = execute_phase(args, output / "cold", mirror, profile, transport, nonce, False)
    unselected = mirror / UNSELECTED
    unselected.write_bytes(unselected.read_bytes() + b"\n# The isolated unselected control must leave staged bytes unchanged.\n")
    warm = execute_phase(args, output / "unselected-change", mirror, profile, transport, nonce, True)
    require(first["receipt_sha256"] == warm["receipt_sha256"] and first["artifact_sha256"] == warm["artifact_sha256"],
            "Unselected source change altered the staged or exported bytes")
    selected = mirror / SELECTED
    selected.write_bytes(selected.read_bytes() + b"\n# The isolated selected control must invalidate the consumer RUN.\n")
    changed = execute_phase(args, output / "selected-change", mirror, profile, transport, nonce, False)
    require(changed["receipt_sha256"] != first["receipt_sha256"] and changed["artifact_sha256"] != first["artifact_sha256"],
            "Selected source change did not alter staged and exported bytes")
    require(all(fingerprint(path) == digest for path, digest in original.items()), "Original source inputs changed during the probe")
    return {"profile": profile, "transport": transport, "source_files": len(read_profile(scripts, profile)), "production_dockerfile_sha256": production,
            "original_inputs_unchanged": True, "phases": [first, warm, changed]}


def run(args: argparse.Namespace) -> None:
    require(not git(args.source, "status", "--porcelain").strip(), "Preserve a clean source input")
    head = git(args.source, "rev-parse", "HEAD").decode().strip()
    index = base_identity(args.base_context, args.base_digest)
    args.output.mkdir()
    nonce = uuid.uuid4().hex
    save(args.output / "input.json", {"source": str(args.source), "source_revision": head, "nonce": nonce,
                                     "base_digest": args.base_digest, "base_index_sha256": index, "scope": __doc__})
    native = native_base(args.base_context, args.base_digest, args.output / "native-base")
    solve_args = argparse.Namespace(**{**vars(args), "base_context": args.output / "native-base", "base_digest": native["digest"]})
    records = [replay_profile(solve_args, *profile, nonce) for profile in PROFILES]
    require(all(fingerprint(Path(path)) == digest for path, digest in native["source_blobs"].items()), "Original OCI blobs changed")
    require(base_identity(solve_args.base_context, solve_args.base_digest) == native["index_sha256"], "Derived OCI index changed")
    require(base_identity(args.base_context, args.base_digest) == index, "OCI base index changed during the probe")
    require(git(args.source, "rev-parse", "HEAD").decode().strip() == head
            and not git(args.source, "status", "--porcelain").strip(), "Original source identity changed")
    save(args.output / "proof.json", {"status": "passed-selected-context-cache-transport-only", "observed_at": timestamp(),
                                     "source_revision": head, "base_digest": args.base_digest, "native_base": native, "profiles": records, "scope": __doc__})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT)
    parser.add_argument("--base-context", type=Path, required=True)
    parser.add_argument("--base-digest", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--engine", default="nerdctl")
    parser.add_argument("--buildkit-host")
    args = parser.parse_args()
    try:
        args.source = args.source.resolve(strict=True)
        args.base_context = args.base_context.resolve(strict=True)
        args.output = args.output.absolute()
        run(args)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print("Selected-context cache probe failed: " + str(error), file=sys.stderr)
        return 2
    print("Selected-context BuildKit cache transport passed; compiler/image/GPU acceptance remains separate")
    return 0
