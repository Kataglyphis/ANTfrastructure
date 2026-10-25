"""Build and mutate the paired PEP Git report used by the shell transaction suite."""

import json
import shlex
import sys
from pathlib import Path


def create(report_path: Path, config_path: Path) -> None:
    native = []
    regex = []
    for package, repo, old, new, git_count, wheel_count in (
        ("torch", "pytorch/pytorch", "v2.14.1", "v2.15.0", 4, 4),
        ("torchvision", "pytorch/vision", "v0.29.1", "v0.30.0", 3, 4),
    ):
        spec = f"@ git+https://github.com/{repo}.git@{old} "
        native.extend(
            {
                "depName": package,
                "currentValue": spec,
                "skipReason": "invalid-value",
                "updates": [],
            }
            for _ in range(git_count - (package == "torch"))
        )
        native.extend(
            {
                "depName": package,
                "currentValue": "==" + old[1:],
                "updates": [{"newValue": "==" + new[1:]}],
            }
            for _ in range(wheel_count)
        )
        regex.extend(
            {
                "depName": repo,
                "packageName": repo,
                "datasource": "github-tags",
                "currentValue": old,
                "currentVersion": old,
                "updates": [{"newValue": new}],
            }
            for _ in range(git_count)
        )
    report = {
        "repositories": {
            "local": {
                "packageFiles": {
                    "pep621": [{"packageFile": "pyproject.toml", "deps": native}],
                    "regex": [{"packageFile": "pyproject.toml", "deps": regex}],
                }
            }
        }
    }
    config = {
        "pep621": {"managerFilePatterns": ["/(^|/)pyproject\\.toml$/"]},
        "regex": {"managerFilePatterns": ["/(^|/)pyproject\\.toml$/"]},
        "packageRules": [
            {
                "matchManagers": ["pep621"],
                "matchDepNames": ["torch", "torchvision"],
                "dependencyDashboardApproval": True,
            }
        ],
    }
    report_path.write_text(json.dumps(report), encoding="utf-8")
    config_path.write_text(json.dumps(config), encoding="utf-8")


def drop_lookup(report_path: Path) -> None:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    report["repositories"]["local"]["packageFiles"]["regex"][0]["deps"].pop()
    report_path.write_text(json.dumps(report), encoding="utf-8")


def add_uncovered_spec(report_path: Path, manifest_path: Path) -> None:
    with manifest_path.open("a", encoding="utf-8") as fh:
        fh.write('\n[dependency-groups]\nuncovered = ["torch>=2.14"]\n')
    report = json.loads(report_path.read_text(encoding="utf-8"))
    report["repositories"]["local"]["packageFiles"]["pep621"][0]["deps"].append(
        {
            "depName": "torch",
            "currentValue": ">=2.14",
            "updates": [{"newValue": ">=2.15"}],
        }
    )
    report_path.write_text(json.dumps(report), encoding="utf-8")


def invalidate_lookup_without_native_skip(report_path: Path) -> None:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    files = report["repositories"]["local"]["packageFiles"]
    files["pep621"][0]["deps"] = [
        dep
        for dep in files["pep621"][0]["deps"]
        if dep.get("skipReason") != "invalid-value"
    ]
    files["regex"][0]["deps"][0]["currentVersion"] = "v0.0.0"
    report_path.write_text(json.dumps(report), encoding="utf-8")


def stale_without_updates(report_path: Path) -> None:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    for files in report["repositories"]["local"]["packageFiles"].values():
        for package_file in files:
            for dep in package_file["deps"]:
                dep["updates"] = []
    report_path.write_text(json.dumps(report), encoding="utf-8")


def spoof_package_name(report_path: Path) -> None:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    report["repositories"]["local"]["packageFiles"]["regex"][0]["deps"][0][
        "packageName"
    ] = "somewhere/else"
    report_path.write_text(json.dumps(report), encoding="utf-8")


def write_lock(path: Path, torch_tag: str, vision_tag: str) -> None:
    lines = ["version = 1"]
    for package, repo, tag, sha in (
        ("torch", "pytorch/pytorch", torch_tag, "a" * 40),
        ("torchvision", "pytorch/vision", vision_tag, "b" * 40),
    ):
        bare = tag.removeprefix("v")
        lines.extend(
            (
                "[[package]]",
                f'name = "{package}"',
                f'version = "{bare}a0+git{sha[:7]}"',
                f'source = {{ git = "https://github.com/{repo}.git?rev={tag}#{sha}" }}',
                "[[package]]",
                f'name = "{package}"',
                f'version = "{bare}"',
                'source = { registry = "https://pypi.org/simple" }',
            )
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_uv_stub(
    path: Path, mode: str, argv_log: str, python: str, fixture: str
) -> None:
    if mode == "success":
        body = (
            f"printf 'uv | %s\\n' \"$*\" >> {shlex.quote(argv_log)}\n"
            f"{shlex.quote(python)} {shlex.quote(fixture)} "
            "write-lock uv.lock v2.15.0 v0.30.0\n"
        )
    elif mode == "noop":
        body = "exit 0\n"
    elif mode == "failure":
        body = "printf broken > uv.lock\nexit 9\n"
    else:
        raise ValueError(f"unknown uv stub mode {mode}")
    path.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
    path.chmod(0o755)


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "create" and len(sys.argv) == 4:
        create(Path(sys.argv[2]), Path(sys.argv[3]))
    elif mode == "drop-lookup" and len(sys.argv) == 3:
        drop_lookup(Path(sys.argv[2]))
    elif mode == "add-uncovered-spec" and len(sys.argv) == 4:
        add_uncovered_spec(Path(sys.argv[2]), Path(sys.argv[3]))
    elif mode == "invalidate-lookup" and len(sys.argv) == 3:
        invalidate_lookup_without_native_skip(Path(sys.argv[2]))
    elif mode == "stale-no-updates" and len(sys.argv) == 3:
        stale_without_updates(Path(sys.argv[2]))
    elif mode == "spoof-package" and len(sys.argv) == 3:
        spoof_package_name(Path(sys.argv[2]))
    elif mode == "write-lock" and len(sys.argv) == 5:
        write_lock(Path(sys.argv[2]), sys.argv[3], sys.argv[4])
    elif mode == "write-uv-stub" and len(sys.argv) == 7:
        write_uv_stub(
            Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
        )
    else:
        sys.exit(
            "usage: renovate_pep_git_fixture.py create <report> <config> | "
            "drop-lookup <report> | add-uncovered-spec <report> <manifest> | "
            "invalidate-lookup <report> | stale-no-updates <report> | "
            "spoof-package <report> | write-lock <path> <torch-tag> <vision-tag> | "
            "write-uv-stub <path> <success|noop|failure> <argv-log> <python> <fixture>"
        )
