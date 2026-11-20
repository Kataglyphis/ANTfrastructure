"""Ninja metadata and shell lifecycle doubles; no rocMLIR library is compiled or accepted by these fixtures."""

import argparse
import hashlib
import json
import os
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"
REQUIRED = (
    "lib/librockCompiler.a", "lib/cmake/rocmlir/rocmlir-config.cmake",
    "lib/cmake/rocmlir/rocmlir-config-version.cmake", "lib/cmake/rocmlir/rocmlir-targets.cmake",
    "include/rocmlir/mlir-c/RegisterRocMLIR.h", "include/rocmlir/mlir-c/Dialect/MIGraphX.h",
    "include/rocmlir/external/include/mlir-c/IR.h",
)


class RocmlirBuildPlanTests(unittest.TestCase):
    """Every planned C/C++ action has an independent cache/compiler/toolchain expectation."""

    def setUp(self) -> None:
        self.api = runpy.run_path(str(LIB / "inspect-rocmlir-build.py"))
        self.rows = []
        for suffix, compiler in [("cpp", "clang++"), ("c", "clang"), ("S", "clang")]:
            args = ["/source clang/bin/" + compiler, "--gcc-toolchain=/source GCC", "-c", "/source/file." + suffix]
            if suffix != "S":
                args.insert(0, "/cache launcher")
            self.rows.append({"file": "/source/file." + suffix, "command": shlex.join(args), "output": suffix + ".o"})
        self.rows.append({"file": "/build/libOne.a", "output": "package/rockCompiler.mri",
                          "command": "for archive in /build/libOne.a /build/libTwo.a ; do echo addlib $archive ; done"})

    def inspect(self, rows: object) -> dict[str, object]:
        return self.api["inspect_rows"](rows, "/source clang", "/source GCC", "/cache launcher")

    def test_plan_counts_cache_and_assembly_scope_and_fat_members(self) -> None:
        proof = self.inspect(self.rows)
        self.assertEqual(proof["planned_commands"], 4)
        self.assertEqual(proof["planned_compiles"], {"cxx": 1, "c": 1, "assembly": 1})
        self.assertEqual(proof["assembly_sources"], ["/source/file.S"])
        self.assertEqual(proof["fat_archive_members"], ["/build/libOne.a", "/build/libTwo.a"])

    def test_each_c_or_cxx_cache_compiler_and_toolchain_drift_refuses(self) -> None:
        for index in [0, 1]:
            for before, after in [("/cache launcher", "/foreign cache"),
                                  ("/source clang", "/distro compiler"),
                                  ("--gcc-toolchain=/source GCC", "--gcc-toolchain=/foreign GCC")]:
                rows = [dict(row) for row in self.rows]
                rows[index]["command"] = rows[index]["command"].replace(before, after)
                with self.assertRaises(ValueError):
                    self.inspect(rows)

    def test_empty_incomplete_unknown_or_uncompiled_object_records_refuse(self) -> None:
        cases = [[], {}, self.rows[1:], self.rows + [{}]]
        for field, value in [("file", ""), ("file", "/source/unknown.xyz"), ("command", "without-compile"),
                             ("output", ""), ("output", "module.pcm")]:
            rows = [dict(row) for row in self.rows]
            rows[0][field] = value
            rows.append(dict(self.rows[0], output="healthy-extra.o"))
            cases.append(rows)
        rows = [dict(row) for row in self.rows]
        rows[2]["command"] = rows[2]["command"].replace("/source clang", "/foreign clang")
        cases.append(rows)
        rows = [dict(row) for row in self.rows]
        rows[0]["command"] = rows[0]["command"].replace(" -c ", " ")
        cases.append(rows)
        rows = [dict(row) for row in self.rows]
        rows[-1]["file"] = ""
        cases.append(rows)
        for rows in cases:
            with self.subTest(rows=rows), self.assertRaises((ValueError, TypeError)):
                self.inspect(rows)

    def test_missing_duplicate_empty_or_malformed_fat_archive_loop_refuses(self) -> None:
        for command in ["not a loop", "for archive in ; do echo empty ; done",
                        "for archive in /build/libOne.a /build/libOne.a ; do echo duplicate ; done",
                        "for archive in /build/not-static.so ; do echo shared ; done",
                        "for archive in /build/libOne.a ; do echo first ; done ; for archive in /build/libTwo.a ; do echo second ; done"]:
            rows = [dict(row) for row in self.rows]
            rows[-1]["command"] = command
            with self.assertRaises(ValueError):
                self.inspect(rows)
        for rows in [self.rows[:-1], self.rows + [self.rows[-1]]]:
            with self.assertRaises(ValueError):
                self.inspect(rows)

    def test_metadata_transport_raw_status_fresh_output_and_input_preservation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rocmlir Ninja protocol ") as temporary:
            root = Path(temporary)
            build = root / "configured build"
            (build / "CMakeFiles").mkdir(parents=True)
            for name in ["CMakeCache.txt", "build.ninja", "CMakeFiles/rules.ninja"]:
                (build / name).write_text("original\n")
            tool = root / "ninja double"
            tool.write_text("#!" + sys.executable + "\nimport json,os,sys\n"
                            "from pathlib import Path\n"
                            "tool=sys.argv[sys.argv.index('-t')+1]\n"
                            "if sys.argv[-1]!='librockCompiler': sys.exit(99)\n"
                            "if os.environ.get('FAIL_TOOL')==tool: sys.exit(37)\n"
                            "if os.environ.get('MUTATE_INPUT'): Path(sys.argv[2],'build.ninja').write_text('changed')\n"
                            "print(os.environ['ROWS'] if tool=='compdb-targets' else 'metadata only')\n")
            tool.chmod(0o755)
            args = argparse.Namespace(build=build, output=root / "proof", ninja=str(tool),
                                      clang_prefix="/source clang", gcc_prefix="/source GCC", cache_launcher="/cache launcher")
            with mock.patch.dict(os.environ, ROWS=json.dumps(self.rows)):
                self.assertEqual(self.api["run"](args), 0)
                self.assertTrue((args.output / "proof.json").is_file())
                with self.assertRaises(FileExistsError):
                    self.api["run"](args)
                args.output = root / "prior receipt only"
                args.output.mkdir()
                (args.output / "proof.json").write_text("original receipt")
                with self.assertRaises(FileExistsError):
                    self.api["run"](args)
                self.assertEqual((args.output / "proof.json").read_text(), "original receipt")
                for name in ["compdb-targets", "inputs", "commands"]:
                    args.output = root / name
                    with mock.patch.dict(os.environ, FAIL_TOOL=name):
                        self.assertEqual(self.api["run"](args), 37)
                    self.assertFalse((args.output / "proof.json").exists())
                args.output = root / "changed inputs"
                with mock.patch.dict(os.environ, MUTATE_INPUT="1"), self.assertRaisesRegex(ValueError, "changed"):
                    self.api["run"](args)


PREPARATION = r"""
printf 'prepare\n' >> "$EVENT_LOG"
printf '%s\0' "$@" > "$PREPARE_ARGV"
[[ "$FAIL_PHASE" != prepare ]] || return 23
work="$1"
mkdir "$work"
cp -a "$FIXTURE_SOURCE" "$work/source"
SCRIPT_DIR="$FIXTURE_SCRIPTS"
clang_root="$FIXTURE_CLANG" gcc_root='/source GCC'
CMAKE_COMPILER_CACHE_PIN='/cache launcher'
[[ "$FAIL_PHASE" != no-cache ]] || CMAKE_COMPILER_CACHE_PIN=''
HOST_PYTHON_BIN=fixture_python JOBS="${FIXTURE_JOBS-7}"
source "$DOWNLOADS_LIBRARY"
source "$ROCMLIR_LIBRARY"
compute_cpp_heavy_jobs() {
  printf 'jobs\n' >> "$EVENT_LOG"
  printf '%s\n' "$1" > "$JOBS_LOG"
  [[ "$FAIL_PHASE" != jobs ]] || return 31
  printf '2\n'
}
fixture_python() {
  printf 'plan\n' >> "$EVENT_LOG"
  printf '%s\0' "$@" > "$PLAN_ARGV"
  [[ "$FAIL_PHASE" != plan ]] || return 37
}
cmake() {
  local phase="${1#--}" file
  printf '%s\n' "$phase" >> "$EVENT_LOG"
  printf '%s\0' "$@" > "$CMAKE_ARGV.$phase"
  [[ "$FAIL_PHASE" != "$phase" ]] || return 37
  if [[ "$phase" == install ]]; then
    for file in REQUIRED_FIXTURE_FILES; do
      [[ "$OMIT_FILE" != "$file" ]] || continue
      mkdir -p "$work/host-deps/$(dirname "$file")"
      if [[ "$OMIT_FILE" == "empty:$file" ]]; then
        : > "$work/host-deps/$file"
      else
        printf 'fixture installed payload\n' > "$work/host-deps/$file"
      fi
    done
  fi
}
bash() {
  [[ "${1##*/}" == verify-source-rocmlir.sh ]] || return 99
  [[ -f "$work/host-deps/share/licenses/rocmlir/SOURCE-NOTICE-SHA256SUMS" ]] || return 38
  printf 'api\n' >> "$EVENT_LOG"
  printf '%s\0' "$@" > "$API_ARGV"
  [[ "$FAIL_PHASE" != api ]] || return 37
}

"""


class RocmlirBuildLifecycleTests(unittest.TestCase):
    """The real shell entry retains imports, exact target/install scope, original notices and raw failures."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="rocmlir lifecycle ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.scripts = self.root / "script directory"
        self.scripts.mkdir()
        shutil.copy2(LIB / "build-source-rocmlir.sh", self.scripts)
        body = PREPARATION.replace("REQUIRED_FIXTURE_FILES", shlex.join(REQUIRED))
        (self.scripts / "prepare-source-rocmlir.sh").write_text(body)
        self.tree = self.root / "original source"
        self.tree.mkdir()
        lines = []
        for name in ["LICENSE", "external/llvm-project/LICENSE.TXT", "external/triton/LICENSE"]:
            path = self.tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"unchanged upstream\r\nnotice bytes\n")
            lines.append(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + name)
        (self.scripts / "rocmlir-source-notices.sha256").write_text("\n".join(lines) + "\n")
        self.clang = self.root / "source clang"
        (self.clang / "bin").mkdir(parents=True)
        ar = self.clang / "bin/llvm-ar"
        ar.write_text('#!/usr/bin/env bash\nprintf "ar\\n" >> "$EVENT_LOG"\n'
                      '[[ "$FAIL_PHASE" != ar ]] || exit 37\n'
                      '[[ "$FAIL_PHASE" != empty-ar ]] || exit 0\nprintf "actual-test-double-member.o\\n"\n')
        ar.chmod(0o755)
        self.calls = 0
        self.requested_jobs = "7"

    def build(self, phase: str = "", omit: str = "") -> tuple[subprocess.CompletedProcess[str], Path, Path]:
        self.calls += 1
        work = self.root / ("work " + str(self.calls))
        events = self.root / ("events " + str(self.calls))
        env = dict(os.environ, LC_ALL="C", FAIL_PHASE=phase, OMIT_FILE=omit,
                   EVENT_LOG=str(events), FIXTURE_SOURCE=str(self.tree), FIXTURE_SCRIPTS=str(self.scripts),
                   FIXTURE_CLANG=str(self.clang), DOWNLOADS_LIBRARY=str(ROOT / "linux/scripts/01-core/downloads.sh"),
                   ROCMLIR_LIBRARY=str(LIB / "source-rocmlir.sh"), JOBS_LOG=str(self.root / "jobs"),
                   FIXTURE_JOBS=self.requested_jobs, PLAN_ARGV=str(self.root / "plan.nul"), CMAKE_ARGV=str(self.root / "cmake.nul"),
                   PREPARE_ARGV=str(self.root / "prepare.nul"), API_ARGV=str(self.root / "api.nul"))
        result = subprocess.run(["bash", str(self.scripts / "build-source-rocmlir.sh"),
                                 str(work), "source archive", "rocm-cmake archive", "/ROCm with spaces"],
                                check=False, capture_output=True, text=True, timeout=15, env=env)
        return result, work, events

    def test_exact_build_target_leaf_install_and_memory_capped_jobs(self) -> None:
        result, work, events = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(events.read_text().splitlines(), ["prepare", "jobs", "plan", "build", "install", "ar", "api"])
        self.assertEqual((self.root / "jobs").read_text(), "7\n")
        self.assertEqual((self.root / "prepare.nul").read_bytes().split(b"\0")[:-1],
                         [str(work).encode(), b"source archive", b"rocm-cmake archive", b"/ROCm with spaces"])
        self.assertEqual((self.root / "cmake.nul.build").read_bytes().split(b"\0")[:-1], [
            b"--build", str(work / "build").encode(), b"--target", b"librockCompiler", b"--parallel", b"2",
        ])
        self.assertEqual((self.root / "cmake.nul.install").read_bytes().split(b"\0")[:-1],
                         [b"--install", str(work / "build/mlir/tools/rocmlir-lib").encode()])
        plan = (self.root / "plan.nul").read_bytes().split(b"\0")
        for value in ["/cache launcher", str(self.clang), "/source GCC", str(work / "build-plan")]:
            self.assertIn(value.encode(), plan)
        self.assertIn(b"--cache-launcher", plan)
        self.assertEqual((self.root / "api.nul").read_bytes().split(b"\0")[:-1],
                         [str(self.scripts / "verify-source-rocmlir.sh").encode(),
                          str(work / "api-check").encode(), str(work / "host-deps").encode(), str(work / "source").encode()])

    def test_unset_or_explicit_jobs_request_always_uses_the_heavy_cap(self) -> None:
        for requested in ("", "3"):
            self.requested_jobs = requested
            result, work, _events = self.build()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.root / "jobs").read_text(), requested + "\n")
            self.assertEqual((self.root / "cmake.nul.build").read_bytes().split(b"\0")[-2], b"2")
            self.assertTrue((work / "installed-archive-members.txt").is_file())

    def test_original_installed_notices_and_archive_receipt(self) -> None:
        result, work, _events = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ["LICENSE", "external/llvm-project/LICENSE.TXT", "external/triton/LICENSE"]:
            self.assertEqual((work / "host-deps/share/licenses/rocmlir" / name).read_bytes(), (self.tree / name).read_bytes())
        self.assertEqual((work / "installed-archive-members.txt").read_text(), "actual-test-double-member.o\n")

    def test_prepare_jobs_plan_build_install_and_archive_failures_remain_raw(self) -> None:
        for phase, status, tail in [
            ("prepare", 23, "prepare"), ("no-cache", 1, "prepare"), ("jobs", 31, "jobs"),
            ("plan", 37, "plan"), ("build", 37, "build"), ("install", 37, "install"),
            ("ar", 37, "ar"), ("empty-ar", 1, "ar"),
        ]:
            with self.subTest(phase=phase):
                result, work, events = self.build(phase)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual(events.read_text().splitlines()[-1], tail)
                self.assertFalse((work / "host-deps/share/licenses/rocmlir").exists())
                self.assertNotIn("ROCMLIR LIBRARY BUILT:", result.stdout)

    def test_each_required_installed_payload_is_mandatory(self) -> None:
        for missing in REQUIRED:
            result, _work, events = self.build(omit=missing)
            self.assertEqual(result.returncode, 1, (missing, result.stdout, result.stderr))
            self.assertEqual(events.read_text().splitlines()[-1], "install")

    def test_each_required_installed_payload_must_be_nonempty(self) -> None:
        for name in REQUIRED:
            result, _work, _events = self.build(omit="empty:" + name)
            self.assertEqual(result.returncode, 1, (name, result.stdout, result.stderr))

    def test_missing_original_notice_fails_after_install_without_success(self) -> None:
        (self.tree / "external/triton/LICENSE").unlink()
        result, _work, _events = self.build()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("ROCMLIR LIBRARY BUILT:", result.stdout)

    def test_prefix_raw_archive_failure_and_reused_receipt_under_conditional_calls(self) -> None:
        result, work, events = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        command = "source " + shlex.quote(str(LIB / "source-rocmlir.sh")) + "\nstatus=0\n"
        call = ["migraphx_rocmlir_prefix_contract", str(work / "host-deps"), str(self.clang / "bin/llvm-ar")]
        for name, record, phase, expected in [
            ("raw", work / "fresh archive receipt", "ar", 37),
            ("reuse", work / "installed-archive-members.txt", "", 2),
        ]:
            body = command + shlex.join([*call, str(record)]) + ' || status=$?\nexit "$status"\n'
            child = subprocess.run(["bash", "-euo", "pipefail", "-c", body], capture_output=True, text=True,
                                   check=False, timeout=10, env=dict(os.environ, LC_ALL="C", FAIL_PHASE=phase, EVENT_LOG=str(events)))
            self.assertEqual(child.returncode, expected, (name, child.stdout, child.stderr))
        self.assertEqual((work / "installed-archive-members.txt").read_text(), "actual-test-double-member.o\n")
        for stub, expected in [("migraphx_rocmlir_payload_files() { return 31; }\n", 31),
                               ('migraphx_rocmlir_payload_files() { local -n output="$1"; output=(); }\n', 1)]:
            body = command + stub + shlex.join([*call, str(work / "unused receipt")]) + ' || status=$?\nexit "$status"\n'
            child = subprocess.run(["bash", "-euo", "pipefail", "-c", body], capture_output=True, text=True,
                                   check=False, timeout=10, env=dict(os.environ, LC_ALL="C", FAIL_PHASE="", EVENT_LOG=str(events)))
            self.assertEqual(child.returncode, expected, child.stdout + child.stderr)

    def test_real_builder_bad_arity_refuses_before_preparation(self) -> None:
        for args in [[], ["work"], ["work", "source", "tools"], ["work", "source", "tools", "rocm", "extra"]]:
            result = subprocess.run(["bash", str(LIB / "build-source-rocmlir.sh"), *args], capture_output=True,
                                    text=True, check=False, timeout=10, env=dict(os.environ, LC_ALL="C"))
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)



    def test_required_external_api_check_preserves_failure_after_notices(self) -> None:
        result, work, events = self.build("api")
        self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
        self.assertEqual(events.read_text().splitlines()[-1], "api")
        self.assertTrue((work / "host-deps/share/licenses/rocmlir/LICENSE").is_file())
        self.assertNotIn("ROCMLIR LIBRARY BUILT:", result.stdout)


if __name__ == "__main__":
    unittest.main()
