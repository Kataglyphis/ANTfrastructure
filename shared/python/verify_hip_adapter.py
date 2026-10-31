#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Check that exactly one HIP-visible adapter has the expected PCI address."""

from __future__ import annotations

import argparse
import ctypes
import re
import sys

PCI = re.compile(r"0000:([0-9a-f]{2}):([0-1][0-9a-f])\.([0-7])\Z")
EXPECTED = re.compile(r"([0-9a-f]{2}):([0-1][0-9a-f])\.([0-7])\Z")


def verify(hip: ctypes.CDLL, expected: str) -> tuple[str, str]:
    """Compare the sole visible HIP device to a separately established address."""
    if not EXPECTED.fullmatch(expected):
        raise ValueError("expected PCI address must have form bb:dd.f")
    count = ctypes.c_int()
    if hip.hipGetDeviceCount(ctypes.byref(count)) != 0 or count.value != 1:
        raise ValueError("HIP must expose exactly one device")
    name = ctypes.create_string_buffer(256)
    address = ctypes.create_string_buffer(32)
    if hip.hipDeviceGetName(name, len(name), 0) != 0 or not name.value:
        raise ValueError("HIP could not identify the visible device")
    if hip.hipDeviceGetPCIBusId(address, len(address), 0) != 0:
        raise ValueError("HIP could not read its PCI address")
    try:
        pci = address.value.decode("ascii").lower()
        device_name = name.value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("HIP returned an invalid device identity") from error
    match = PCI.fullmatch(pci)
    if not match or ":".join(match.group(1, 2)) + "." + match.group(3) != expected:
        raise ValueError(f"HIP PCI address {pci!r} does not match {expected!r}")
    return device_name, pci


def main() -> int:
    """Compare a sole HIP device with an independently obtained PCI address."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--pci-address", required=True, help="expected bb:dd.f, lowercase"
    )
    args = parser.parse_args()
    try:
        hip = ctypes.CDLL("libamdhip64.so.7")
        hip.hipGetDeviceCount.argtypes = [ctypes.POINTER(ctypes.c_int)]
        for func in (hip.hipDeviceGetName, hip.hipDeviceGetPCIBusId):
            func.argtypes = [ctypes.POINTER(ctypes.c_char), ctypes.c_int, ctypes.c_int]
            func.restype = ctypes.c_int
        hip.hipGetDeviceCount.restype = ctypes.c_int
        name, address = verify(hip, args.pci_address)
    except (OSError, AttributeError, ValueError) as error:
        print(f"HIP adapter verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Sole HIP-visible adapter: {name}; PCI {address}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
