"""Append an exact memory suffix with backups; this is no atomic transaction against crashes or uncooperative writers."""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import stat
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from typing import Any, BinaryIO, cast

from operational_memory_guard import controller_absence
from source_ci.common import fingerprint, require, save, timestamp


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def single_regular(info: os.stat_result) -> None:
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, 'Input must be regular with exactly one link')


@contextmanager
def opened(path: Path, flags: int) -> Generator[BinaryIO, None, None]:
    descriptor = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    mode = 'r+b' if flags & os.O_RDWR else 'rb'
    with os.fdopen(descriptor, mode, buffering=0) as stream:
        single_regular(os.fstat(stream.fileno()))
        yield cast(BinaryIO, stream)


def read_regular(path: Path) -> bytes:
    with opened(path, os.O_RDONLY) as stream:
        return stream.read()


def same_file(path: Path, descriptor: int) -> None:
    current, original = path.lstat(), os.fstat(descriptor)
    single_regular(current)
    require((current.st_dev, current.st_ino) == (original.st_dev, original.st_ino), 'Memory file identity changed')


def persist(path: Path, data: bytes) -> None:
    with path.open('xb') as stream:
        require(stream.write(data) == len(data), 'Incomplete backup write')
        stream.flush()
        os.fsync(stream.fileno())


def sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_append(descriptor: int, data: bytes) -> None:
    position = 0
    while position < len(data):
        written = os.write(descriptor, data[position:])
        require(0 < written <= len(data) - position, 'Append made no valid progress')
        position += written
    os.fsync(descriptor)


def verify_snapshots(directory: Path, before: bytes, addition: bytes) -> None:
    for name, expected in [('prefix-before.bin', before), ('append.bin', addition)]:
        require(digest(read_regular(directory / name)) == digest(expected), 'Backup bytes changed')


def source_inputs() -> dict[str, str]:
    here = Path(__file__).resolve().parent
    names = ('append-operational-memory.py', 'operational_memory.py', 'operational_memory_guard.py',
             'host_commands.py', 'source_ci/common.py')
    return {str(here / name): fingerprint(here / name) for name in names}


def append_memory(memory: Path, expected_bytes: int, expected_sha256: str,
                  append_file: Path, directory: Path) -> dict[str, Any]:
    require(type(expected_bytes) is int and expected_bytes >= 0, 'Expected byte count must be nonnegative')
    require(re.fullmatch(r'[0-9a-f]{64}', expected_sha256), 'Expected SHA256 must be lowercase hexadecimal')
    memory, append_file, directory = memory.absolute(), append_file.absolute(), directory.absolute()
    require(memory != append_file, 'Memory cannot also be its append input')
    addition = read_regular(append_file)
    require(addition, 'Append input must not be empty')
    addition.decode('utf-8')
    with opened(memory, os.O_RDWR | os.O_APPEND) as stream:
        descriptor = stream.fileno()
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = stream.read()
        require(len(before) == expected_bytes and digest(before) == expected_sha256, 'Memory prefix differs')
        observation = controller_absence()
        directory.mkdir(mode=0o700)
        save(directory / 'invocation.json', {'memory': str(memory), 'expected_bytes': expected_bytes,
             'expected_sha256': expected_sha256, 'append_file': str(append_file), 'append_sha256': digest(addition),
             'sources_sha256': source_inputs(), 'scope': __doc__})
        save(directory / 'controller-observation.json', observation)
        persist(directory / 'prefix-before.bin', before)
        persist(directory / 'append.bin', addition)
        sync_directory(directory)
        sync_directory(directory.parent)
        verify_snapshots(directory, before, addition)
        same_file(memory, descriptor)
        stream.seek(0)
        require(stream.read() == before, 'Memory changed before the append')
        write_append(descriptor, addition)
        same_file(memory, descriptor)
        stream.seek(0)
        after = stream.read()
        require(after == before + addition, 'Memory changed during the append')
        verify_snapshots(directory, before, addition)
        proof = {'status': 'passed-prefix-preserving-append-only', 'observed_at': timestamp(),
                 'memory': str(memory), 'before_bytes': len(before), 'before_sha256': digest(before),
                 'after_bytes': len(after), 'after_sha256': digest(after),
                 'prefix_backup': str(directory / 'prefix-before.bin'),
                 'prefix_backup_sha256': fingerprint(directory / 'prefix-before.bin'),
                 'append_snapshot': str(directory / 'append.bin'),
                 'append_sha256': digest(addition), 'controller_absence': observation,
                 'scope': __doc__, 'runtime_GPU_image_quality_or_goal_acceptance': False}
        save(directory / 'proof.json', proof)
        return proof
