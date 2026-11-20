"""Share checked host command transport while keeping raw subprocess failures observable."""

import subprocess


def checked_run(command: list[str], timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, check=True, timeout=timeout)


def command_bytes(command: list[str]) -> bytes:
    return subprocess.run(command, capture_output=True, check=True, timeout=60).stdout


def command_text(command: list[str]) -> str:
    return command_bytes(command).decode()
