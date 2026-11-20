"""Verify invocation ownership and final container state; this does not prove payload success."""

import json
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from host_commands import checked_output


def container_id(value: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("the engine returned an invalid owned container ID")
    return value


def stopped(state: dict[str, object]) -> bool:
    return state.get("Running") is False and type(state.get("Pid")) is int and state["Pid"] == 0 and state.get("Status") in ("created", "exited")


@dataclass(frozen=True)
class OwnedContainers:
    engine: str
    label: str
    run_id: str

    def __post_init__(self) -> None:
        if not re.fullmatch(r"org\.kataglyphis\.[a-z0-9.-]+", self.label):
            raise ValueError("ownership requires an org.kataglyphis label")
        if not re.fullmatch(r"[0-9a-f]{32}", self.run_id):
            raise ValueError("ownership requires a fresh UUID hex token")

    def ids(self, *, owned: bool) -> set[str]:
        command = [self.engine, "ps", "-a", "--no-trunc"]
        if owned:
            command += ["--filter", f"label={self.label}={self.run_id}"]
        result = checked_output([*command, "--format", "{{.ID}}"])
        return {container_id(value) for value in result.splitlines()}

    def state(self, cid: str) -> dict[str, object]:
        records = json.loads(checked_output([self.engine, "inspect", cid]))
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise ValueError("container inspection did not return one object")
        record = records[0]
        config = record.get("Config")
        labels = config.get("Labels") if isinstance(config, dict) else None
        if record.get("Id") != cid or not isinstance(labels, dict) or labels.get(self.label) != self.run_id:
            raise ValueError("container ID or invocation ownership does not match")
        state = record.get("State")
        if not isinstance(state, dict):
            raise TypeError("container inspection has no state object")
        return state

    def settled(self, cid: str, *, retain: bool) -> bool:
        for _ in range(5):
            if cid not in self.ids(owned=False):
                return True
            if retain:
                state = self.state(cid)
                if stopped(state):
                    return True
            time.sleep(0.2)
        return False

    def verify_cidfile(self, cidfile: Path | None, owned: set[str]) -> None:
        if cidfile is not None and cidfile.exists():
            expected = container_id(cidfile.read_text().strip())
            if expected not in owned and expected in self.ids(owned=False):
                raise ValueError("CID file names a container outside this invocation")

    def cleanup(self, *, retain: bool = False, cidfile: Path | None = None) -> int:
        owned = self.ids(owned=True)
        self.verify_cidfile(cidfile, owned)
        status = 0
        for cid in sorted(owned):
            state = self.state(cid)
            if retain and stopped(state):
                continue
            command = ["stop", "--time", "10"] if retain else ["rm", "--force"]
            result = subprocess.run([self.engine, *command, cid], timeout=45, check=False)
            status = status or result.returncode
            if not self.settled(cid, retain=retain):
                status = status or 1
        remaining = self.ids(owned=True)
        if remaining - owned or (remaining and not retain):
            status = status or 1
        return status
