#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Test one immutable image against frozen consumer checkouts and record its receipt."""
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PLAN = ROOT / "shared/config/image-consumers.json"
SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")
MEDIA = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"
MANIFEST_MEDIA = {"application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"}


def fingerprint(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def image_parts(image, pinned=True):
    if not image.startswith("ghcr.io/"):
        raise ValueError("image acceptance supports the family's GHCR images")
    repository, separator, ref = image.removeprefix("ghcr.io/").rpartition("@" if pinned else ":")
    if not separator or not re.fullmatch(r"[a-z0-9][a-z0-9_./-]*", repository):
        raise ValueError(f"invalid image reference: {image}")
    if pinned and not DIGEST.fullmatch(ref):
        raise ValueError("consumer tests require an immutable sha256 image reference")
    if not pinned and not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", ref):
        raise ValueError("invalid image tag")
    return repository, ref


class Registry:
    def __init__(self, repository, *, write=False):
        self.repository = repository
        scope = f"repository:{repository}:pull" + (",push" if write else "")
        headers = {}
        if write:
            username, password = self.credentials()
            auth = base64.b64encode(f"{username}:{password}".encode()).decode()
            headers["Authorization"] = "Basic " + auth
        url = "https://ghcr.io/token?" + urllib.parse.urlencode({"service": "ghcr.io", "scope": scope})
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
            self.token = json.load(response)["token"]

    @staticmethod
    def credentials():
        if os.environ.get("GHCR_TOKEN"):
            return os.environ.get("GITHUB_ACTOR", "oauth2"), os.environ["GHCR_TOKEN"]
        config_path = Path(os.environ.get("DOCKER_CONFIG", str(Path.home() / ".docker"))) / "config.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        entry = config.get("auths", {}).get("ghcr.io", {})
        if entry.get("auth"):
            return base64.b64decode(entry["auth"]).decode().split(":", 1)
        helper = config.get("credHelpers", {}).get("ghcr.io") or config.get("credsStore")
        if helper and re.fullmatch(r"[A-Za-z0-9_.-]+", helper):
            result = subprocess.run([f"docker-credential-{helper}", "get"], input="ghcr.io\n",
                                    text=True, capture_output=True, check=True, timeout=30)
            value = json.loads(result.stdout)
            return value["Username"], value["Secret"]
        raise ValueError("promotion needs GHCR_TOKEN or existing GHCR login credentials")

    def manifest(self, ref):
        url = f"https://ghcr.io/v2/{self.repository}/manifests/{ref}"
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + self.token, "Accept": MEDIA})
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            media_type = response.headers["Content-Type"].split(";", 1)[0]
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        if DIGEST.fullmatch(ref) and digest != ref:
            raise ValueError("registry manifest bytes do not match their requested digest")
        return raw, media_type, digest

    def publish(self, tag, raw, media_type):
        url = f"https://ghcr.io/v2/{self.repository}/manifests/{tag}"
        request = urllib.request.Request(url, data=raw, method="PUT",
                                         headers={"Authorization": "Bearer " + self.token, "Content-Type": media_type})
        with urllib.request.urlopen(request, timeout=60) as response:
            response.read()


def validate_consumer(row):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", row["name"]):
        raise ValueError("invalid consumer name")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", row["repository"]):
        raise ValueError("invalid consumer repository")
    if not isinstance(row.get("command"), list) or not row["command"] or not all(isinstance(value, str) and value for value in row["command"]):
        raise ValueError("consumer command must be a nonempty argument array")
    if not isinstance(row.get("ref"), str) or not re.fullmatch(r"[A-Za-z0-9_./-]+", row["ref"]) or row["ref"].startswith("-"):
        raise ValueError("consumer ref must identify a branch")


def read_plan(path):
    plan = json.loads(Path(path).read_text(encoding="utf-8"))
    consumers = plan.get("consumers", [])
    names = [row.get("name") for row in consumers]
    if plan.get("schema_version") != 1 or not names or len(names) != len(set(names)):
        raise ValueError("acceptance plan must contain unique, nonempty consumers")
    for row in consumers:
        validate_consumer(row)
    if not re.fullmatch(r"linux/(amd64|arm64|riscv64)", plan.get("platform", "")):
        raise ValueError("acceptance platform must be a supported Linux architecture")
    if not 1 <= plan.get("timeout_seconds", 0) <= 7200:
        raise ValueError("acceptance timeout must be between 1 and 7200 seconds")
    return plan


def git(root, *args):
    return subprocess.run(["git", "-c", f"safe.directory={root}", "-C", str(root), *args],
                          text=True, capture_output=True, check=True, timeout=300).stdout.strip()


def source_snapshot(root, spec, expected=None):
    if not (root / ".git").exists():
        root.mkdir(parents=True, exist_ok=True)
        git(root, "init", "--quiet")
        git(root, "remote", "add", "origin", "https://github.com/" + spec["repository"] + ".git")
        revision = expected["revision"] if expected else "refs/heads/" + spec["ref"]
        git(root, "fetch", "--quiet", "--depth", "1", "origin", revision)
        git(root, "checkout", "--quiet", "--detach", "FETCH_HEAD")
        git(root, "submodule", "update", "--init", "--recursive", "--depth", "1")
    if git(root, "status", "--porcelain", "--ignore-submodules=none"):
        raise ValueError(f"{spec['name']}: acceptance source checkout is dirty")
    revision = git(root, "rev-parse", "HEAD")
    if not SHA.fullmatch(revision):
        raise ValueError("consumer HEAD is not a full commit")
    submodules = git(root, "submodule", "status", "--recursive")
    if any(line.startswith(("-", "+", "U")) for line in submodules.splitlines()):
        raise ValueError(f"{spec['name']}: submodule checkout differs from the recorded pins")
    locks = {path: fingerprint(root / path) for path in git(root, "ls-files", "--recurse-submodules").splitlines()
             if Path(path).name in ("models.lock", "assets.lock")}
    result = {"repository": spec["repository"], "revision": revision, "submodules": submodules, "data_locks": locks}
    if expected and any(result[key] != expected[key] for key in result):
        raise ValueError(f"{spec['name']}: replay sources differ from the original receipt")
    return result


def lock_path(root, relative):
    path = Path(relative)
    if path.is_absolute() or "\\" in relative or ":" in relative or ".." in path.parts or path.name not in ("Cargo.lock", "pubspec.lock", "uv.lock"):
        raise ValueError("receipt contains an invalid dependency lock path")
    target = (root / path).resolve()
    if not target.is_relative_to(root.resolve()):
        raise ValueError("dependency lock escapes its checkout")
    return target


def collect_locks(root):
    names = {"Cargo.toml": "Cargo.lock", "pubspec.yaml": "pubspec.lock", "pyproject.toml": "uv.lock"}
    result = {}
    for source in git(root, "ls-files", "--recurse-submodules").splitlines():
        path = Path(source)
        if path.name not in names:
            continue
        relative = path.with_name(names[path.name]).as_posix()
        lock = lock_path(root, relative)
        if lock.is_file():
            data = lock.read_bytes()
            result[relative] = {"sha256": hashlib.sha256(data).hexdigest(), "content": data.decode("utf-8")}
    return result


def restore_locks(root, locks):
    for relative, value in locks.items():
        data = value["content"].encode("utf-8")
        if hashlib.sha256(data).hexdigest() != value["sha256"]:
            raise ValueError("dependency lock content does not match its receipt hash")
        target = lock_path(root, relative)
        if target.is_file() and target.read_bytes() != data:
            raise ValueError(f"existing dependency lock differs from receipt: {relative}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def validate_consumer_result(result, spec):
    if result.get("name") != spec["name"] or result.get("exit_code") != 0:
        raise ValueError("consumer failed, skipped or was reordered")
    if result.get("repository") != spec["repository"] or result.get("command") != spec["command"] or not SHA.fullmatch(result.get("revision", "")):
        raise ValueError("consumer source or command is not recorded")
    if not HASH.fullmatch(result.get("log_sha256", "")) or not isinstance(result.get("submodules"), str) or not isinstance(result.get("data_locks"), dict) or not isinstance(result.get("resolved_locks"), dict):
        raise ValueError("consumer evidence is missing")


def validate_receipt(receipt, image, plan_path):
    plan = read_plan(plan_path)
    image_parts(image)
    if receipt.get("schema_version") != 1 or receipt.get("image") != image:
        raise ValueError("receipt belongs to another image or schema")
    if receipt.get("plan_sha256") != fingerprint(plan_path) or receipt.get("status") != "passed":
        raise ValueError("acceptance did not pass this exact plan")
    if not SHA.fullmatch(receipt.get("hub_revision", "")) or receipt.get("platform") != plan["platform"]:
        raise ValueError("receipt does not identify its tooling and test platform")
    rows = receipt.get("consumers", [])
    if len(rows) != len(plan["consumers"]):
        raise ValueError("receipt is missing consumers")
    for result, spec in zip(rows, plan["consumers"]):
        validate_consumer_result(result, spec)
    return receipt


def run_consumer(args, plan, work, index, spec, row, expected, rootless):
    checkout = work / spec["name"]
    row.update(source_snapshot(checkout, spec, expected))
    if expected:
        restore_locks(checkout, expected["resolved_locks"])
    log = work / (spec["name"] + ".log")
    name = f"image-acceptance-{os.getpid()}-{index}"
    command = [args.engine, "run", "--rm", "--pull", "never", "--name", name,
               "--platform", plan["platform"], "-v", f"{checkout}:/workspace", "-w", "/workspace",
               "-v", f"{ROOT}:/opt/antfrastructure:ro"]
    if rootless:
        command += ["--user", "0:0", "-e", "TAR_OPTIONS=--no-same-owner"]
    if spec["name"] == "ANThology":
        command += ["-e", "ANTFRASTRUCTURE_DIR=/opt/antfrastructure"]
    command += [args.image, *spec["command"]]
    started = time.monotonic()
    try:
        with log.open("wb") as stream:
            row["exit_code"] = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                              timeout=plan["timeout_seconds"], check=False).returncode
    except subprocess.TimeoutExpired:
        row["exit_code"] = 124
        raise
    finally:
        subprocess.run([args.engine, "rm", "--force", name], capture_output=True, timeout=60, check=False)
        row["seconds"] = round(time.monotonic() - started, 3)
        row["log_sha256"] = fingerprint(log)
        row["log"] = str(log)
        row["resolved_locks"] = collect_locks(checkout)
    if expected and row["resolved_locks"] != expected["resolved_locks"]:
        raise ValueError(f"{spec['name']}: dependency resolution changed during replay")
    if row["exit_code"] != 0:
        raise ValueError(f"{spec['name']}: consumer smoke failed; see {log}")
    changes = git(checkout, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=none")
    if changes:
        row["source_changes"] = changes
        raise ValueError(f"{spec['name']}: consumer modified tracked acceptance sources")


def check(args):
    image_parts(args.image)
    plan = read_plan(args.plan)
    work = Path(args.workspace).resolve()
    work.mkdir(parents=True, exist_ok=True)
    if git(ROOT, "status", "--porcelain"):
        raise ValueError("commit the hub tooling before creating an acceptance receipt")
    receipt = {"schema_version": 1, "image": args.image, "plan_sha256": fingerprint(args.plan),
               "hub_revision": git(ROOT, "rev-parse", "HEAD"), "platform": plan["platform"],
               "status": "failed", "consumers": []}
    previous = None
    if args.replay:
        previous = json.loads(Path(args.replay).read_text(encoding="utf-8"))
        validate_receipt(previous, args.image, args.plan)
        if previous["hub_revision"] != receipt["hub_revision"]:
            raise ValueError("replay must use the hub revision recorded by the receipt")
    receipt["started_at"] = datetime.now(UTC).isoformat()
    try:
        pull_started = time.monotonic()
        subprocess.run([args.engine, "pull", "--platform", plan["platform"], args.image], check=True, timeout=1800)
        receipt["pull_seconds"] = round(time.monotonic() - pull_started, 3)
        engine_info = subprocess.run([args.engine, "info"], text=True, capture_output=True, check=True, timeout=60).stdout
        rootless = sys.platform.startswith("linux") and "rootless" in engine_info
        for index, spec in enumerate(plan["consumers"]):
            row = {"name": spec["name"], "command": spec["command"], "exit_code": None}
            receipt["consumers"].append(row)
            expected = previous["consumers"][index] if previous else None
            run_consumer(args, plan, work, index, spec, row, expected, rootless)
        receipt["status"] = "passed"
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        receipt["error"] = str(exc)
    output = Path(args.receipt)
    receipt["finished_at"] = datetime.now(UTC).isoformat()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    if receipt["status"] != "passed":
        raise ValueError(receipt["error"])
    validate_receipt(receipt, args.image, args.plan)


def manifest_descriptor(entry):
    if not isinstance(entry, dict) or entry.get("mediaType") not in MANIFEST_MEDIA or not isinstance(entry.get("digest"), str) or not DIGEST.fullmatch(entry["digest"]) or type(entry.get("size")) is not int or entry["size"] <= 0:
        raise ValueError("index contains an invalid manifest descriptor")
    platform = entry.get("platform", {})
    annotations = entry.get("annotations", {})
    if not isinstance(platform, dict) or not isinstance(annotations, dict):
        raise ValueError("index contains invalid platform metadata")  # noqa: TRY004 -- Reject malformed registry input uniformly.
    return platform, annotations


def runtime_platform(entry):
    platform, annotations = manifest_descriptor(entry)
    if platform == {"os": "unknown", "architecture": "unknown"} and annotations.get("vnd.docker.reference.type") == "attestation-manifest":
        return None
    parts = [platform.get("os", ""), platform.get("architecture", "")]
    if "variant" in platform:
        parts.append(platform["variant"])
    if any(not isinstance(part, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", part) or part == "unknown" for part in parts):
        raise ValueError("index contains an unidentified runtime platform")
    return "/".join(parts)


def runtime_platforms(raw, media_type):
    index = json.loads(raw)
    if not isinstance(index, dict) or media_type not in MEDIA.split(",") or index.get("schemaVersion") != 2 or not isinstance(index.get("manifests"), list) or not index["manifests"]:
        raise ValueError("promotion requires a multi-platform index")
    platforms, digests, attestations = set(), set(), []
    for entry in index["manifests"]:
        name = runtime_platform(entry)
        if name is None:
            attestations.append(entry["annotations"].get("vnd.docker.reference.digest"))
            continue
        if name in platforms:
            raise ValueError(f"index repeats runtime platform {name}")
        platforms.add(name)
        digests.add(entry["digest"])
    if not platforms or any(not isinstance(reference, str) or reference not in digests for reference in attestations):
        raise ValueError("index contains no runtime platforms or an unbound attestation")
    return platforms


def promote(args):
    receipt = json.loads(Path(args.receipt).read_text(encoding="utf-8"))
    validate_receipt(receipt, receipt["image"], args.plan)
    repository, digest = image_parts(receipt["image"])
    destination, tag = image_parts(args.target, pinned=False)
    if repository != destination:
        raise ValueError("promotion must preserve the source repository and its layers")
    registry = Registry(repository, write=True)
    raw, media_type, _ = registry.manifest(digest)
    platforms = runtime_platforms(raw, media_type)
    if receipt["platform"] not in {"/".join(platform.split("/")[:2]) for platform in platforms}:
        raise ValueError("tested platform is missing from the candidate index")
    try:
        current, current_type, _ = registry.manifest(tag)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        error.close()
    else:
        missing = runtime_platforms(current, current_type) - platforms
        if missing:
            raise ValueError("promotion would remove published runtime platforms: " + ", ".join(sorted(missing)))
    registry.publish(tag, raw, media_type)
    if registry.manifest(tag)[2] != digest:
        raise ValueError("published tag does not resolve to the tested index")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    resolve = commands.add_parser("resolve")
    resolve.add_argument("image")
    test = commands.add_parser("check")
    test.add_argument("--image", required=True)
    test.add_argument("--plan", default=str(DEFAULT_PLAN))
    test.add_argument("--workspace", required=True)
    test.add_argument("--receipt", required=True)
    test.add_argument("--engine", default=os.environ.get("NERDCTL_BIN", "nerdctl"))
    test.add_argument("--replay", help="recheck the image, source SHAs and dependency locks in a passed receipt")
    publish = commands.add_parser("promote")
    publish.add_argument("--receipt", required=True)
    publish.add_argument("--plan", default=str(DEFAULT_PLAN))
    publish.add_argument("--target", required=True)
    args = parser.parse_args()
    if args.action == "resolve":
        repository, tag = image_parts(args.image, pinned=False)
        digest = Registry(repository).manifest(tag)[2]
        print(f"ghcr.io/{repository}@{digest}")
    elif args.action == "check":
        check(args)
    else:
        promote(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"image-acceptance: {error}", file=sys.stderr)
        sys.exit(1)
