import importlib.util
import pathlib
import sys
import zipfile
from typing import IO, Protocol, Self, cast
from unittest import mock


class WheelVerifier(Protocol):
    MAX_LIBRARY_BYTES: int
    CHUNK_BYTES: int

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
