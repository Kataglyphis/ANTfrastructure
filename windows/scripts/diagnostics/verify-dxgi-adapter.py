#!/usr/bin/env python3
"""Verify the physical vendor of a specific DXGI adapter used by DirectML."""

import argparse
import ctypes
import json
import sys
from ctypes import wintypes


class Guid(ctypes.Structure):
    _fields_ = [
        ("a", wintypes.DWORD),
        ("b", wintypes.WORD),
        ("c", wintypes.WORD),
        ("d", ctypes.c_ubyte * 8),
    ]


class Luid(ctypes.Structure):
    _fields_ = [("low", wintypes.DWORD), ("high", wintypes.LONG)]


class AdapterDescription(ctypes.Structure):
    _fields_ = [
        ("description", wintypes.WCHAR * 128),
        ("vendor", wintypes.UINT),
        ("device", wintypes.UINT),
        ("subsystem", wintypes.UINT),
        ("revision", wintypes.UINT),
        ("vram", ctypes.c_size_t),
        ("system_memory", ctypes.c_size_t),
        ("shared_memory", ctypes.c_size_t),
        ("luid", Luid),
        ("flags", wintypes.UINT),
    ]


def _method(
    obj: ctypes.c_void_p, index: int, restype: object, *types: object
) -> object:
    if sys.platform != "win32":
        raise RuntimeError("DXGI adapter verification requires Windows")
    from ctypes import WINFUNCTYPE

    table = ctypes.cast(obj, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    return WINFUNCTYPE(restype, ctypes.c_void_p, *types)(table[index])


def describe_adapter(index: int) -> AdapterDescription:
    """Use the same EnumAdapters1 index as ORT's explicit DirectML device ID."""
    if sys.platform != "win32":
        raise RuntimeError("DXGI adapter verification requires Windows")
    iid = Guid(
        0x770AAE78,
        0xF26F,
        0x4DBA,
        (ctypes.c_ubyte * 8)(0xA8, 0x29, 0x25, 0x3C, 0x83, 0xD1, 0xB3, 0x87),
    )
    factory = ctypes.c_void_p()
    create = ctypes.WinDLL("dxgi").CreateDXGIFactory1
    create.argtypes = [ctypes.POINTER(Guid), ctypes.POINTER(ctypes.c_void_p)]
    create.restype = ctypes.c_long
    status = create(ctypes.byref(iid), ctypes.byref(factory))
    if status:
        raise OSError(f"CreateDXGIFactory1 failed: {status:#x}")
    try:
        adapter = ctypes.c_void_p()
        enum = _method(
            factory, 12, ctypes.c_long, wintypes.UINT, ctypes.POINTER(ctypes.c_void_p)
        )
        status = enum(factory, index, ctypes.byref(adapter))
        if status:
            raise OSError(f"DXGI adapter {index} is unavailable: {status:#x}")
        try:
            desc = AdapterDescription()
            status = _method(
                adapter, 10, ctypes.c_long, ctypes.POINTER(AdapterDescription)
            )(adapter, ctypes.byref(desc))
            if status:
                raise OSError(f"GetDesc1 failed: {status:#x}")
            return desc
        finally:
            _method(adapter, 2, wintypes.ULONG)(adapter)
    finally:
        _method(factory, 2, wintypes.ULONG)(factory)


def require_vendor(desc: AdapterDescription, vendor: str) -> None:
    expected = {"amd": 0x1002, "nvidia": 0x10DE}
    if desc.flags & 2 or desc.vendor != expected[vendor]:
        raise ValueError(
            f"DXGI adapter is software or not {vendor}: vendor={desc.vendor:#06x}, flags={desc.flags:#x}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", choices=("amd", "nvidia"), required=True)
    parser.add_argument("--index", type=int, required=True)
    args = parser.parse_args()
    if not 0 <= args.index <= 0x7FFFFFFF:
        parser.error("--index must be a non-negative 32-bit integer")
    try:
        desc = describe_adapter(args.index)
        require_vendor(desc, args.vendor)
    except (OSError, RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "index": args.index,
                "vendor": args.vendor,
                "description": desc.description,
                "vendor_id": desc.vendor,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
