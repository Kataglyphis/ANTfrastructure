import importlib.util
import io
import pathlib
import shutil
import sys
import zipfile
from contextlib import redirect_stderr
from typing import IO, Protocol, Self, cast
from unittest import mock


class WheelVerifier(Protocol):
    MAX_LIBRARY_BYTES: int
    CHUNK_BYTES: int

    def main(self) -> int: ...

    def wheel_has_library(self, archive: zipfile.ZipFile, library: pathlib.Path, strip: str,
                          scratch: pathlib.Path, require_unstripped: bool = False) -> bool: ...

script, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(script.parent))
spec = importlib.util.spec_from_file_location("stage_ort_exact", script)
assert spec is not None and spec.loader is not None
loaded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loaded)
module = cast(WheelVerifier, loaded)
scratch = root / "unused-exact-scratch"
with zipfile.ZipFile(root / "valid/onnxruntime-1-cp315-linux.whl") as archive:
    assert module.wheel_has_library(archive, root / "build/libonnxruntime.so.1.2.3", "missing-strip", scratch, True)
    assert not module.wheel_has_library(archive, root / "native/libonnxruntime.so.1.2.3", "missing-strip", scratch, True)
assert not scratch.exists()
assert module.MAX_LIBRARY_BYTES > 256 * 1024 * 1024
original_limit = module.MAX_LIBRARY_BYTES
module.CHUNK_BYTES = 32
library = root / "build/libonnxruntime.so.1.2.3"
with zipfile.ZipFile(root / "valid/onnxruntime-1-cp315-linux.whl") as archive:
    original_open = archive.open
    class LimitedRead:
        def __init__(self, stream: IO[bytes]) -> None: self.stream = stream
        def __enter__(self) -> Self: return self
        def __exit__(self, *args: object) -> None: self.stream.close()
        def read(self, size: int = -1) -> bytes:
            assert 0 < size <= module.CHUNK_BYTES
            return self.stream.read(size)
    with mock.patch.object(archive, "open", side_effect=lambda *args, **kwargs: LimitedRead(original_open(*args, **kwargs))):
        assert module.wheel_has_library(archive, library, "strip", root / "build")
        module.MAX_LIBRARY_BYTES = library.stat().st_size - 1
        try:
            module.wheel_has_library(archive, library, "strip", root / "build")
        except ValueError as error:
            assert "invalid wheel entry" in str(error)
        else:
            raise AssertionError("an over-limit archive member was accepted")

module.MAX_LIBRARY_BYTES = original_limit
original_copy = shutil.copyfileobj
for fault in ("copy-error", "short-copy", "replace-error", "changed-input"):
    bundle = root / "bundles" / ("restore-fault-" + fault)
    library = bundle / "lib/libonnxruntime.so.1.2.3"
    library.parent.mkdir(parents=True)
    before = (root / "native/libonnxruntime.so.1.2.3").read_bytes()
    library.write_bytes(before)
    argv = [str(script), "--wheel-dir", str(root / "valid"), "--destination", str(bundle),
            "--strip", "strip", "--restore-unstripped", "--library", str(library)]
    error = io.StringIO()
    if fault == "copy-error":
        patch = mock.patch("shutil.copyfileobj", side_effect=OSError("fixture original copy failure"))
        expected = "fixture original copy failure"
    elif fault == "short-copy":
        patch = mock.patch("shutil.copyfileobj", side_effect=lambda source, target, length: target.write(b"short"))
        expected = "original wheel copy is incomplete"
    elif fault == "replace-error":
        patch = mock.patch("os.replace", side_effect=OSError("fixture original replace failure"))
        expected = "fixture original replace failure"
    else:
        def change_during_copy(source: IO[bytes], target: IO[bytes], length: int, changed: pathlib.Path = library) -> None:
            changed.write_bytes(b"late replacement must survive")
            original_copy(source, target, length)
        patch = mock.patch("shutil.copyfileobj", side_effect=change_during_copy)
        expected = "native library changed before original-byte staging"
    with mock.patch.object(sys, "argv", argv), patch, redirect_stderr(error):
        assert module.main() == 1, error.getvalue()
    assert expected in error.getvalue(), error.getvalue()
    assert library.read_bytes() == (b"late replacement must survive" if fault == "changed-input" else before)
    assert not list(library.parent.glob(".ort-original-*")), "original staging leaked a temporary file"
