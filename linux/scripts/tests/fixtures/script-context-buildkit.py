#!/usr/bin/env python3
"""Emit controlled BuildKit-shaped fixtures; no cache, image or compiler actually runs."""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def command_inputs(argv: list[str]) -> tuple[str, str, Path]:
    assert argv[0] == "build"
    assert all(value in argv for value in ("--platform=linux/amd64", "--progress=plain", "--pull=false"))
    assert not any("push=true" in value or value == "--no-cache" for value in argv)
    contexts = [argv[index + 1] for index, value in enumerate(argv) if value == "--build-context"]
    assert len(contexts) == 2 and any("=oci-layout://" in value for value in contexts)
    scripts = Path(next(value.split("=", 1)[1] for value in contexts if value.startswith("hub-scripts=")))
    nonce = next(value.removeprefix("CACHE_NONCE=") for value in argv if value.startswith("CACHE_NONCE="))
    context = Path(argv[-1])
    assert sorted(path.name for path in context.iterdir()) == ["Dockerfile"]
    text = (context / "Dockerfile").read_text()
    assert "RUN --network=none" in text and "FROM scratch AS result" in text
    assert "COPY --from=consumer /cache-proof.txt /cache-proof.txt" in text
    key = next(value.removeprefix("HUB_SCRIPTS_KEY=") for value in argv if value.startswith("HUB_SCRIPTS_KEY="))
    digest = hashlib.sha256((scripts / key / "files/SCRIPT-CLOSURE.json").read_bytes()).hexdigest()
    assert digest == key
    output = Path(argv[argv.index("--output") + 1].removeprefix("type=local,dest="))
    return nonce, digest, output


def emit_step(mode: str, output: Path, nonce: str, digest: str) -> None:
    cached = output.parent.name == "unselected-change"
    if mode == "warm-executed":
        cached = False
    if mode == "selected-cached" and output.parent.name == "selected-change":
        cached = True
    print("#8 [consumer 1/1] RUN set -eu; echo SCRIPT_CLOSURE_PROBE")
    if cached:
        print("#8 CACHED")
    else:
        if mode != "missing-marker":
            print(f"#8 0.001 SCRIPT_CLOSURE_PROBE {nonce} {digest}")
        print("#8 DONE 0.002s")


def change_input(mode: str, output: Path) -> None:
    final = output.parent.name == "selected-change" and output.parents[1].name == "migraphx-image"
    if not final:
        return
    if mode == "source-head":
        subprocess.run(["git", "-C", os.environ["SCRIPT_CONTEXT_FIXTURE_SOURCE"], "-c", "user.name=t", "-c", "user.email=t@t",
                        "commit", "--allow-empty", "-qm", "fixture head change"], check=True, timeout=10)
    elif mode == "source-input":
        path = Path(os.environ["SCRIPT_CONTEXT_FIXTURE_SOURCE"]) / "linux/scripts/01-core/logging.sh"
        path.write_bytes(path.read_bytes() + b"\n# A changed original input must refuse a receipt.\n")
    elif mode == "original-oci":
        base = Path(os.environ["SCRIPT_CONTEXT_FIXTURE_BASE"])
        digest = json.loads((base / "index.json").read_text())["manifests"][0]["digest"]
        manifest = json.loads((base / "blobs/sha256" / digest.split(":")[1]).read_text())
        path = base / "blobs/sha256" / manifest["config"]["digest"].split(":")[1]
        path.write_bytes(path.read_bytes() + b"\n")
    elif mode == "derived-index":
        path = Path(os.environ["SCRIPT_CONTEXT_FIXTURE_DERIVED"]) / "index.json"
        path.write_bytes(path.read_bytes() + b"\n")
    elif mode == "base-index":
        path = Path(os.environ["SCRIPT_CONTEXT_FIXTURE_BASE"]) / "index.json"
        path.write_bytes(path.read_bytes() + b"\n")


def main() -> int:
    nonce, digest, output = command_inputs(sys.argv[1:])
    mode = os.environ.get("SCRIPT_CONTEXT_FIXTURE_MODE", "")
    if mode == "exit":
        print("fixture raw status 47")
        return 47
    emit_step(mode, output, nonce, digest)
    output.mkdir()
    value = f"{nonce} {digest}\n" if mode != "bad-artifact" else "foreign artifact\n"
    (output / "cache-proof.txt").write_text(value)
    change_input(mode, output)
    return 47 if mode == "exit-with-evidence" else 0


if __name__ == "__main__":
    raise SystemExit(main())
