#!/usr/bin/env python3
"""Cold-import one selected tiny binding; this does not run MIGraphX, a finished consumer or GPU inference."""

import argparse
import hashlib
import importlib.util
import json
import platform
import sys
import sysconfig
from pathlib import Path


def run(build: Path, version: str) -> dict[str, object]:
    if platform.python_version() != version:
        raise ValueError("The runtime interpreter differs from the requested pin")
    module_path = Path((build / "module-file.txt").read_text().strip()).resolve(strict=True)
    if (not module_path.is_file() or not module_path.is_relative_to(build.resolve())
            or module_path.name != "migraphx_python_probe" + sysconfig.get_config_var("EXT_SUFFIX")):
        raise ValueError("The built module is outside the selected build or has a foreign Python ABI")
    before = hashlib.sha256(module_path.read_bytes()).hexdigest()
    gil_before = sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else True
    spec = importlib.util.spec_from_file_location("migraphx_python_probe", module_path)
    if spec is None or spec.loader is None:
        raise ValueError("Cannot load the compiled Python probe")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    gil_after = sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else True
    origin = module.__file__
    if (module.constant_value() != 42 or not isinstance(origin, str) or Path(origin).resolve() != module_path
            or before != hashlib.sha256(module_path.read_bytes()).hexdigest()
            or (not gil_before and gil_after)):
        raise ValueError("Compiled binding value, origin, bytes or GIL state changed")
    return {"status": "passed-tiny-native-Python-binding-only", "python_version": platform.python_version(),
            "interpreter": sys.executable, "module": str(module_path), "module_sha256": before,
            "extension_suffix": sysconfig.get_config_var("EXT_SUFFIX"),
            "gil_enabled_before": gil_before, "gil_enabled_after": gil_after, "scope": __doc__}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.build, args.version), indent=2))
    except (OSError, ValueError, ImportError, RuntimeError) as error:
        print("Python binding probe failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
