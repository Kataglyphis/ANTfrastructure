"""Offline file fixtures cover SDK completeness and staged artifacts, not downloads or actual media compilation."""

import json
import subprocess
import sys
import tempfile
import unittest
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MEDIA = Path(sys.argv.pop(1)).resolve()


@lru_cache
def body(file, domain):
    if domain == "tf":
        return (
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1/linux/scripts/tests/test-harness.sh"; t_fn_src "$2" ensure_tensorflow_c_sdk',
                    "_",
                    str(ROOT),
                    str(file),
                ],
                capture_output=True,
                text=True,
                check=True,
            ).stdout
            + "\nensure_tensorflow_c_sdk\n"
        )
    s = file.read_text()
    a = s.index("    # Best-effort must not mean silent:")
    b = s.index("\n    fi", a) + len("\n    fi")
    return s[a:b] + "\n"


@lru_cache
def helper_source():
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1/linux/scripts/tests/test-harness.sh"; t_fn_src "$2" media_regular_files_present',
            "_",
            str(ROOT),
            str(MEDIA / "core/common.sh"),
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def receipt(file, domain, mask, kind, conditional):
    with tempfile.TemporaryDirectory(prefix="ant-media-regular-files-") as directory:
        w = Path(directory)
        root = w / "space [*]"
        trip = "fixture-triplet"
        tf = root / "tensorflow-c"
        version = "1 [*]"
        paths = (
            [
                tf / (".complete-" + version),
                tf / "lib/libtensorflow.so",
                tf / "include/tensorflow/c/c_api.h",
            ]
            if domain == "tf"
            else [
                root / "usr" / trip / "lib/libharfbuzz.a",
                root / "usr" / trip / "include/harfbuzz/hb-ft.h",
                root / "usr" / trip / "lib/pkgconfig/harfbuzz.pc",
            ]
        )
        for i, p in enumerate(paths):
            p.parent.mkdir(parents=True, exist_ok=True)
            if not mask & (1 << i):
                continue
            if kind == "regular":
                p.write_text("bytes")
            elif kind == "directory":
                p.mkdir()
            elif kind == "symlink":
                p.symlink_to(w / "real")
            else:
                p.symlink_to(w / "missing")
        (w / "real").write_text("bytes")
        helper = helper_source()
        code = (
            r"""set -euo pipefail
function [ { if builtin [ "${1:-}" = -f ]; then printf '%s\n' "$2" >> "$TRACE"; fi; builtin [ "$@"; }
uname() { printf aarch64; }
is_truthy() { [[ "$1" = 1 ]]; }
mkdir() { printf 'mkdir\n' >> "$TRACE"; }
"""
            + helper
            + "\nFFMPEG_ENABLE_TF=1\n"
            + f"FFMPEG_SDK_CACHE={str(root)!r}\nTENSORFLOW_C_VERSION={version!r}\n_hb_triplet={trip!r}\n_hb_ver=2\n"
        )
        segment = body(file, domain).replace('"/usr/', '"' + str(root) + "/usr/")
        code += "run_case() {\n" + segment + "\n}\n"
        code += (
            "if run_case; then echo STATUS:0; else echo STATUS:$?; fi"
            if conditional
            else "run_case"
        )
        p = subprocess.run(
            ["bash", "-c", code],
            env={"PATH": "/usr/bin:/bin", "TRACE": str(w / "trace")},
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        return {
            "rc": p.returncode,
            "out": p.stdout.replace(directory, "WORK"),
            "err": p.stderr.replace(directory, "WORK"),
            "trace": (w / "trace").read_text().replace(directory, "WORK")
            if (w / "trace").exists()
            else "",
        }


def capture():
    results = {}
    for domain, rel in [
        ("tf", "build/ffmpeg/ffmpeg-dnn-backends.sh"),
        ("hb", "build/opencv/install-deps.sh"),
    ]:
        for mask in range(8):
            for kind in ["regular", "directory", "symlink", "dangling"]:
                for conditional in [False, True]:
                    results[str((domain, mask, kind, conditional))] = receipt(
                        MEDIA / rel, domain, mask, kind, conditional
                    )
    return results


def missing_api(domain, selected, conditional):
    if domain == "tf":
        segment = body(MEDIA / "build/ffmpeg/ffmpeg-dnn-backends.sh", "tf")
        setup = (
            "FFMPEG_ENABLE_TF="
            + ("1" if selected else "0")
            + '\nis_truthy() { [[ "$1" = 1 ]]; }\n'
        )
    else:
        text = (MEDIA / "build/opencv/install-deps.sh").read_text()
        a = text.index("# See docs/failure-modes.md § RV1-FREETYPE:")
        b = text.index("# riscv64 OpenCV's vendored libpng", a)
        segment = text[a:b]
        setup = (
            "is_cross() { return 0; }\ncross_target_arch() { printf riscv64; }\ncross_target_triplet() { printf %s "
            + ("fixture" if selected else "''")
            + "; }\n"
        )
    code = (
        "set -euo pipefail\n"
        + setup
        + r"""
function [ { if builtin [ "${1:-}" = -f ]; then printf UNEXPECTED_FILE_PROBE; fi; builtin [ "$@"; }
mkdir() { printf UNEXPECTED_MKDIR; }
cross_compile_cmake_lib_from_source() { printf UNEXPECTED_BUILD; }
"""
    )
    code += "run_case() {\n" + segment + "\n}\n"
    code += (
        "if run_case; then echo STATUS:0; else echo STATUS:$?; fi"
        if conditional
        else "run_case"
    )
    return subprocess.run(
        ["bash", "-c", code],
        env={"PATH": "/usr/bin:/bin"},
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
    )


class MediaFileSets(unittest.TestCase):
    def test_original_domain_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("media-file-set-receipts.json").read_text()
        )
        self.assertEqual(128, len(expected))
        self.assertEqual(expected, capture())

    def test_file_sets_have_independent_expected_verdicts(self):
        got = capture()
        for domain in ["tf", "hb"]:
            for kind in ["regular", "directory", "symlink", "dangling"]:
                key = str((domain, 7, kind, True))
                passed = kind in ["regular", "symlink"]
                if domain == "tf":
                    self.assertEqual(passed, "already cached" in got[key]["out"])
                else:
                    self.assertEqual(
                        passed, "static target harfbuzz 2 staged" in got[key]["out"]
                    )
        partial = got[str(("tf", 6, "regular", True))]
        self.assertNotIn("already cached", partial["out"])
        self.assertEqual(
            1,
            len(
                [
                    line
                    for line in partial["trace"].splitlines()
                    if line.startswith("WORK")
                ]
            ),
        )

    def test_raw_failure_status_and_order(self):
        command = (
            r"""set -uo pipefail
function [ { printf '%s\n' "$2"; return 23; }
"""
            + helper_source()
            + r"""
if media_regular_files_present 'first [*]' 'second file'; then exit 0; else exit "$?"; fi
"""
        )
        result = subprocess.run(
            ["bash", "-c", command],
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        self.assertEqual(23, result.returncode)
        self.assertEqual("first [*]\n", result.stdout)
        self.assertEqual("", result.stderr)

    def test_missing_api_fails_closed_only_when_selected(self):
        for domain in ["tf", "hb"]:
            for conditional in [False, True]:
                with self.subTest(domain=domain, conditional=conditional):
                    selected = missing_api(domain, True, conditional)
                    self.assertEqual(1, selected.returncode)
                    self.assertIn(
                        "requires media_regular_files_present from media core/common.sh",
                        selected.stderr,
                    )
                    self.assertEqual("", selected.stdout)
                    skipped = missing_api(domain, False, conditional)
                    self.assertEqual("", skipped.stderr)
                    self.assertNotIn(
                        "requires media_regular_files_present", skipped.stderr
                    )
                    self.assertNotIn("UNEXPECTED", skipped.stdout)
                    if domain == "hb":
                        self.assertEqual(0, skipped.returncode)


if __name__ == "__main__":
    unittest.main()
