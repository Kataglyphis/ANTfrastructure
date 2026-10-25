"""Exercise duplication report modes in a disposable consumer checkout."""

import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch


def run_gate(gate: Path, root: Path, expected: int, *args: str) -> str:
    result = subprocess.run(
        [sys.executable, str(gate), "--root", str(root), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout + result.stderr
    if result.returncode != expected:
        raise AssertionError(f"expected {expected}, got {result.returncode}: {output}")
    return output


def require(text: str, output: str) -> None:
    if text not in output:
        raise AssertionError(f"missing {text!r} in: {output}")


def require_pruned_scan(gate: Path, root: Path) -> None:
    spec = importlib.util.spec_from_file_location("consumer_dupes", gate)
    if spec is None or spec.loader is None:
        raise AssertionError("cannot import duplication scanner")
    scanner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = scanner
    spec.loader.exec_module(scanner)
    vars(scanner)["REPO_ROOT"] = root
    excluded = (root / "third_party", root / "antfrastructure-tools")
    original = os.scandir

    def guarded(path: str) -> object:
        if any(Path(path).is_relative_to(parent) for parent in excluded):
            raise AssertionError(f"entered excluded tooling tree: {path}")
        return original(path)

    with patch.object(os, "scandir", guarded):
        scanner.collect()


def main() -> None:
    gate = Path(sys.argv[1]).resolve()
    twin = sys.argv[2]
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "app.py").write_text('print("ok")\n', encoding="utf-8")
        run_gate(gate, root, 2)
        require("no supported files in scope", run_gate(gate, root, 0, "--allow-empty"))
        run_gate(gate, root, 2, "--allow-empty", "--baseline")
        run_gate(gate, root / "missing", 2, "--allow-empty")

        scripts = root / "scripts"
        scripts.mkdir()
        (scripts / "a.sh").write_text(twin + "\n", encoding="utf-8")
        (scripts / "b.sh").write_text(twin + "\n", encoding="utf-8")
        run_gate(gate, root, 1, "--allow-empty")
        require(
            "code duplication gate: 1 copied block(s)",
            run_gate(gate, root, 0, "--allow-empty", "--report-only"),
        )
        (scripts / "b.sh").unlink()
        tooling = root / "antfrastructure-tools"
        tooling.mkdir()
        (tooling / "b.sh").write_text(twin + "\n", encoding="utf-8")
        run_gate(gate, root, 0, "--allow-empty")
        vendor = root / "third_party" / "ANTfrastructure" / "nested"
        vendor.mkdir(parents=True)
        (vendor / "same.sh").write_text(twin + "\n", encoding="utf-8")
        require_pruned_scan(gate, root)
        run_gate(gate, root / "missing", 2, "--allow-empty", "--report-only")
        run_gate(gate, root, 2, "--baseline", "--report-only")
        (root / "code-dupes.allow").write_text("malformed budget row\n", encoding="utf-8")
        run_gate(gate, root, 2, "--report-only")


if __name__ == "__main__":
    main()
