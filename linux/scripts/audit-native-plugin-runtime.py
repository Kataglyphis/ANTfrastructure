#!/usr/bin/env python3
"""Require CPU and two distinct V2 plugin-session profiles; finished packages and detector parity remain separate."""

import argparse
import subprocess
import sys
from pathlib import Path

from source_ci.common import fingerprint, require, save


def audit(directory: Path) -> dict[str, object]:
    lines = (directory / "sessions.tsv").read_text(encoding="utf-8").splitlines()
    require(len(lines) == 4 and lines[-1] == "NATIVE-PLUGIN-RUNTIME PASS: CPU and two real V2 GPU sessions", "Incomplete runtime sessions")
    rows = [line.split("\t") for line in lines[:-1]]
    require(all(len(row) == 2 for row in rows), "Malformed session profile rows")
    require([row[0] for row in rows] == ["CPUExecutionProvider", "MIGraphX", "MIGraphX"], "Wrong session providers")
    verifier = Path(__file__).resolve().parents[2] / "shared/python/verify_ort_profile.py"
    evidence = []
    profiles: set[Path] = set()
    for provider, filename in rows:
        profile = Path(filename).resolve(strict=True)
        require(profile.parent == directory.resolve() and profile not in profiles, "Foreign or repeated session profile")
        profiles.add(profile)
        device = "cpu" if provider == "CPUExecutionProvider" else "migraphx-plugin"
        subprocess.run([sys.executable, str(verifier), str(profile), "--device", device, "--min-runs", "1"], check=True)
        evidence.append({"provider": provider, "profile": str(profile), "sha256": fingerprint(profile)})
    return {"status": "passed-real-native-helper-tiny-CPU-and-V2-GPU-sessions", "sessions": evidence, "scope": __doc__}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    save(args.directory / "runtime-proof.json", audit(args.directory))


if __name__ == "__main__":
    main()
