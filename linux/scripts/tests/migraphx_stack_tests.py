"""Real hashing and explicit download/build doubles prove source-stack transport, not vendor binaries or GPU/image acceptance."""

import hashlib
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"
SPECS = [
    ("migraphx", "MIGRAPHX_WINDOWS_COMMIT", "MIGRAPHX_WINDOWS_SOURCE_SHA256", "https://github.com/ROCm/AMDMIGraphX/archive/r-migraphx.tar.gz"),
    ("rocm-cmake", "MIGRAPHX_ROCM_CMAKE_COMMIT", "MIGRAPHX_ROCM_CMAKE_SOURCE_SHA256", "https://github.com/ROCm/rocm-cmake/archive/r-rocm-cmake.tar.gz"),
    ("msgpack", "MIGRAPHX_WINDOWS_MSGPACK_VERSION", "MIGRAPHX_WINDOWS_MSGPACK_SHA256", "https://github.com/msgpack/msgpack-c/releases/download/cpp-r-msgpack/msgpack-r-msgpack.tar.gz"),
    ("abseil", "MIGRAPHX_WINDOWS_ABSEIL_VERSION", "MIGRAPHX_WINDOWS_ABSEIL_SHA256", "https://github.com/abseil/abseil-cpp/archive/refs/tags/r-abseil.tar.gz"),
    ("protobuf", "MIGRAPHX_WINDOWS_PROTOBUF_VERSION", "MIGRAPHX_WINDOWS_PROTOBUF_SHA256", "https://github.com/protocolbuffers/protobuf/releases/download/vr-protobuf/protobuf-r-protobuf.tar.gz"),
    ("ck", "MIGRAPHX_CK_COMMIT", "MIGRAPHX_CK_SOURCE_SHA256", "https://codeload.github.com/ROCm/composable_kernel/tar.gz/r-ck"),
    ("rocmlir", "MIGRAPHX_ROCMLIR_COMMIT", "MIGRAPHX_ROCMLIR_SOURCE_SHA256", "https://codeload.github.com/ROCm/rocmlirTriton/tar.gz/r-rocmlir"),
]
TRANSPORT = r"""
source "$DOWNLOADS"
download_verified_file() {
  printf 'fetch:%s\n' "$1" >> "$EVENT_LOG"
  [[ "$FAIL_PHASE" != fetch ]] || return 47
  cp "$POOL/${2}.tar.gz" "$3"
  [[ "$FAIL_PHASE" != corrupt-fetch ]] || printf 'wrong bytes' >> "$3"
}
"""
ENTRY = TRANSPORT + r"""
source "$SOURCE_COMMON"
python3() {
  [[ "$#" == 4 && "$1" == "$SCRIPT_DIR/stage-backend-install.py" && "$2" == check-prefix && "$3" == --prefix ]] || return 98
  printf 'prefix:%s\n' "$4" >> "$EVENT_LOG"
  [[ "$FAIL_PHASE" != prefix ]] || return 29
}
"""
CHILD = r"""#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf 'child:%s\n' "$name" >> "$EVENT_LOG"
printf '%s\0' "$@" > "$ARGV_DIR/$name.nul"
printf '%s' "${MIGRAPHX_DEPS_PREFIX:-}" > "$ARGV_DIR/$name.prefix"
[[ "$FAIL_PHASE" != "$name" ]] || exit 43
"""


class MigraphxStackTests(unittest.TestCase):
    """The complete stack retains exact archives, required children, fresh work and raw failures."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="MIGraphX complete stack ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache = self.root / "source cache"
        self.cache.mkdir()
        self.pool = self.root / "remote archive double"
        self.pool.mkdir()
        self.events = self.root / "events"
        self.argv_dir = self.root / "argv"
        self.argv_dir.mkdir()
        self.table = self.root / "archive table"
        shutil.copy2(LIB / "source-archives.txt", self.table)
        self.env = dict(os.environ, LC_ALL="C", FAIL_PHASE="", EVENT_LOG=str(self.events),
                        POOL=str(self.pool), ARGV_DIR=str(self.argv_dir),
                        DOWNLOADS=str(ROOT / "linux/scripts/01-core/downloads.sh"),
                        SOURCE_COMMON=str(LIB / "source-common.sh"), CACHE=str(self.cache), TABLE=str(self.table),
                        MIGRAPHX_SOURCE_PREFIX=str(self.root / "installed source prefix"),
                        MIGRAPHX_DEPS_PREFIX="/unrelated inherited deps")
        self.expected = {}
        for name, revision_key, digest_key, url in SPECS:
            data = ("explicit archive transport double: " + name).encode()
            digest = hashlib.sha256(data).hexdigest()
            (self.pool / (digest + ".tar.gz")).write_bytes(data)
            self.env[revision_key] = "r-" + name
            self.env[digest_key] = digest
            self.expected[name] = (url, digest, self.cache / (digest + ".tar.gz"))
        self.scripts = self.root / "linux/scripts/03-media/build/migraphx"
        self.scripts.mkdir(parents=True)
        for name in ["build-source-stack.sh", "source-stack.sh", "cli-common.sh", "source-archives.txt"]:
            shutil.copy2(LIB / name, self.scripts)
        common = self.scripts.parents[2] / "lib"
        common.mkdir()
        for name in ["cli-value-options.sh", "log-bootstrap.sh"]:
            shutil.copy2(ROOT / "linux/scripts/lib" / name, common)
        (self.scripts / "entry-common.sh").write_text(ENTRY)
        self.children = ["build-source-deps.sh", "build-source-ck.sh", "verify-source-ck.sh",
                         "build-source-rocmlir.sh", "check-source-sdk.sh", "build-source-backend.sh"]
        for name in self.children:
            (self.scripts / name).write_text(CHILD)
        self.number = 0

    def shell(self, body: str) -> subprocess.CompletedProcess[str]:
        prelude = "set -euo pipefail\n" + TRANSPORT + "\nsource " + shlex.quote(str(LIB / "source-stack.sh")) + "\n"
        return subprocess.run(["bash", "-c", prelude + body], capture_output=True, text=True,
                              check=False, timeout=15, env=self.env)

    def helper(self, fetch: bool = False) -> subprocess.CompletedProcess[str]:
        body = 'declare -a selected=()\nmigraphx_stack_plan selected "$CACHE" "$TABLE"\n'
        if fetch:
            body += 'declare -A files=()\nmigraphx_stack_fetch selected files\n'
        return self.shell(body + 'printf "%s\\0" "${selected[@]}"')

    def run_stack(self, phase: str = "", argv: list[str] | None = None) -> tuple[subprocess.CompletedProcess[str], Path]:
        self.number += 1
        work = self.root / ("work " + str(self.number))
        env = dict(self.env, FAIL_PHASE=phase)
        command = ["bash", str(self.scripts / "build-source-stack.sh"),
                   *(argv if argv is not None else [str(work), str(self.cache), "/ROCm SDK with spaces"])]
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=15, env=env)
        return result, work

    def lines(self) -> list[str]:
        return self.events.read_text().splitlines() if self.events.exists() else []

    def child_args(self, name: str) -> list[str]:
        return [part.decode() for part in (self.argv_dir / (name + ".nul")).read_bytes().split(b"\0") if part]

    def test_seven_exact_URLs_hash_names_and_order_are_planned_before_network(self) -> None:
        result = self.helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected = [name + "|" + url + "|" + digest + "|" + str(file) for name, (url, digest, file) in self.expected.items()]
        self.assertEqual(result.stdout.split("\0")[:-1], expected)
        self.assertFalse(self.events.exists())

    def test_every_pin_and_key_is_required_before_fetch(self) -> None:
        for _name, version, digest, _url in SPECS:
            for key in [version, digest]:
                original = self.env[key]
                for value in ["", "../wrong", "bad value"]:
                    self.env[key] = value
                    result = self.helper(True)
                    self.assertNotEqual(result.returncode, 0, (key, value, result.stdout, result.stderr))
                    self.assertFalse(self.events.exists())
                self.env[key] = original
        self.table.write_text(self.table.read_text().replace("MIGRAPHX_ROCMLIR_COMMIT", "invalid-key"))
        result = self.helper(True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(self.events.exists())

    def test_empty_duplicate_unknown_or_missing_required_table_entry_refuses(self) -> None:
        original = self.table.read_text()
        rows = original.splitlines()
        for value in ["", "\n".join(rows[:-1]) + "\n", original + rows[0] + "\n",
                      original.replace("rocmlir|", "foreign|"), original + rows[-1].replace("rocmlir|", "foreign|") + "\n",
                      original.replace("rocmlir|", "../escape|"), original.replace("{0}", "unpinned"),
                      original.replace("https://codeload.github.com", "http://codeload.github.com")]:
            self.table.write_text(value)
            result = self.helper(True)
            self.assertNotEqual(result.returncode, 0, (value, result.stdout, result.stderr))
            self.assertFalse(self.events.exists())

    def test_cold_fetch_and_exact_warm_cache_preserve_bytes_without_network(self) -> None:
        first = self.helper(True)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(self.lines(), ["fetch:" + url for url, _digest, _path in self.expected.values()])
        original = {str(file): file.read_bytes() for _url, _digest, file in self.expected.values()}
        self.env["FAIL_PHASE"] = "fetch"
        second = self.helper(True)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(len(self.lines()), 7)
        self.assertEqual(original, {str(file): file.read_bytes() for _url, _digest, file in self.expected.values()})
        self.assertEqual(second.stderr.count("MIGRAPHX SOURCE CACHE HIT:"), 7)

    def test_bad_cache_refetches_and_failed_or_wrong_fetch_never_passes(self) -> None:
        _url, digest, cache = self.expected["migraphx"]
        for phase, expected in [("", 0), ("fetch", 47), ("corrupt-fetch", 1)]:
            cache.write_bytes(b"wrong cache bytes")
            self.env["FAIL_PHASE"] = phase
            result = self.helper(True)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            if not phase:
                self.assertEqual(cache.read_bytes(), (self.pool / (digest + ".tar.gz")).read_bytes())
        self.assertFalse(cache.exists())

    def test_symlinked_cache_cannot_supply_an_archive_even_with_matching_bytes(self) -> None:
        _url, digest, cache = self.expected["migraphx"]
        cache.symlink_to(self.pool / (digest + ".tar.gz"))
        result = self.helper(True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Refusing symlinked", result.stderr)
        self.assertFalse(self.events.exists())

    def test_complete_stack_keeps_required_order_exact_arguments_and_owned_prefixes(self) -> None:
        result, work = self.run_stack()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.lines(), ["prefix:" + self.env["MIGRAPHX_SOURCE_PREFIX"]]
                         + ["fetch:" + url for url, _digest, _file in self.expected.values()]
                         + ["child:" + name for name in self.children])
        files = {name: str(value[2]) for name, value in self.expected.items()}
        expected = {
            "build-source-deps.sh": [str(work / "parsers"), files["abseil"], files["protobuf"]],
            "build-source-ck.sh": [str(work / "ck"), files["ck"], files["rocm-cmake"]],
            "verify-source-ck.sh": [str(work / "ck-api"), str(work / "ck/host-deps"), str(work / "ck/ck-source/include/ck/utility/type.hpp")],
            "build-source-rocmlir.sh": [str(work / "rocmlir"), files["rocmlir"], files["rocm-cmake"], "/ROCm SDK with spaces"],
            "check-source-sdk.sh": [str(work / "sdk-check"), "/ROCm SDK with spaces"],
            "build-source-backend.sh": [str(work / "backend"), files["migraphx"], files["rocm-cmake"], files["msgpack"], "/ROCm SDK with spaces"],
        }
        for name, argv in expected.items():
            self.assertEqual(self.child_args(name), argv)
        prefix = ";".join(str(work / name / "host-deps") for name in ["parsers", "ck", "rocmlir"])
        for name in ["check-source-sdk.sh", "build-source-backend.sh"]:
            self.assertEqual((self.argv_dir / (name + ".prefix")).read_text(), prefix)
        self.assertEqual(len((work / "source-archive-plan.txt").read_text().splitlines()), 7)

    def test_default_source_prefix_is_fresh_dedicated_and_explicit_value_survives(self) -> None:
        self.env.pop("MIGRAPHX_SOURCE_PREFIX")
        result, _work = self.run_stack()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.lines()[0], "prefix:/opt/rocm/migraphx")

    def test_every_child_failure_is_raw_and_stops_all_later_children(self) -> None:
        for name in self.children:
            if self.events.exists():
                self.events.unlink()
            result, _work = self.run_stack(name)
            self.assertEqual(result.returncode, 43, (name, result.stdout, result.stderr))
            children = [line.removeprefix("child:") for line in self.lines() if line.startswith("child:")]
            self.assertEqual(children, self.children[:self.children.index(name) + 1])
            self.assertNotIn("COMPLETE SOURCE STACK BUILT", result.stdout)

    def test_prefix_refusal_happens_before_cache_work_download_or_build(self) -> None:
        result, work = self.run_stack("prefix")
        self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
        self.assertEqual(self.lines(), ["prefix:" + self.env["MIGRAPHX_SOURCE_PREFIX"]])
        self.assertFalse(work.exists())
        self.assertFalse(any(self.cache.iterdir()))

    def test_pin_download_and_cache_failures_cannot_start_a_child(self) -> None:
        for phase, expected in [("fetch", 47), ("corrupt-fetch", 1)]:
            if self.events.exists():
                self.events.unlink()
            result, _work = self.run_stack(phase)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertFalse(any(line.startswith("child:") for line in self.lines()))
        self.env["MIGRAPHX_ROCMLIR_SOURCE_SHA256"] = ""
        self.events.unlink()
        result, _work = self.run_stack()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(any(line.startswith(("fetch:", "child:")) for line in self.lines()))

    def test_reused_work_invalid_cache_and_invalid_arity_refuse_before_children(self) -> None:
        occupied = self.root / "occupied work"
        occupied.mkdir()
        result, _work = self.run_stack(argv=[str(occupied), str(self.cache), "/sdk"])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        cache_file = self.root / "cache is file"
        cache_file.write_text("preserve cache file")
        result, _work = self.run_stack(argv=[str(self.root / "new work"), str(cache_file), "/sdk"])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        for argv in [[], [""], ["", str(self.cache), "/sdk"], ["one", "two", "three", "four"]]:
            result, _work = self.run_stack(argv=argv)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(any(line.startswith(("fetch:", "child:")) for line in self.lines()))
        self.assertEqual(cache_file.read_text(), "preserve cache file")


if __name__ == "__main__":
    unittest.main()
