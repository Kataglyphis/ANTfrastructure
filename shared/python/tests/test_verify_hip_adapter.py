#!/usr/bin/env python3
"""Exercise HIP adapter matching without requiring GPU hardware."""

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import Mock

SPEC = importlib.util.spec_from_file_location(
    "verify_hip_adapter", Path(__file__).resolve().parents[1] / "verify_hip_adapter.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def hip_fixture(
    count=1, pci=b"0000:18:00.0", status=0, name=b"AMD Radeon(TM) Graphics"
):
    hip = Mock()

    def get_count(pointer):
        pointer._obj.value = count
        return status

    def get_name(buffer, size, index):
        assert size == 256 and index == 0
        buffer.value = name
        return 0

    def get_pci(buffer, size, index):
        assert size == 32 and index == 0
        buffer.value = pci
        return 0

    hip.hipGetDeviceCount.side_effect = get_count
    hip.hipDeviceGetName.side_effect = get_name
    hip.hipDeviceGetPCIBusId.side_effect = get_pci
    return hip


class HipAdapterTests(unittest.TestCase):
    def test_exact_visible_pci_match(self):
        self.assertEqual(
            MODULE.verify(hip_fixture(), "18:00.0"),
            ("AMD Radeon(TM) Graphics", "0000:18:00.0"),
        )

    def test_other_gpu_cannot_satisfy_the_requested_address(self):
        with self.assertRaises(ValueError):
            MODULE.verify(hip_fixture(), "03:00.0")

    def test_zero_multiple_or_failed_enumeration_is_rejected(self):
        for hip in (hip_fixture(count=0), hip_fixture(count=2), hip_fixture(status=1)):
            with self.subTest(hip=hip), self.assertRaises(ValueError):
                MODULE.verify(hip, "18:00.0")

    def test_invalid_and_nonzero_domain_addresses_are_rejected(self):
        for pci in (b"0001:18:00.0", b"0000:18:20.0", b"18:00.0", b"garbage"):
            with self.subTest(pci=pci), self.assertRaises(ValueError):
                MODULE.verify(hip_fixture(pci=pci), "18:00.0")
        for expected in ("18:20.0", "18:00.8", "18:00", "18:00.0\n", "18:0A.0"):
            with self.subTest(expected=expected), self.assertRaises(ValueError):
                MODULE.verify(hip_fixture(), expected)

    def test_missing_name_and_pci_error_are_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.verify(hip_fixture(name=b""), "18:00.0")
        hip = hip_fixture()
        hip.hipDeviceGetPCIBusId.side_effect = None
        hip.hipDeviceGetPCIBusId.return_value = 1
        with self.assertRaises(ValueError):
            MODULE.verify(hip, "18:00.0")


if __name__ == "__main__":
    unittest.main()
