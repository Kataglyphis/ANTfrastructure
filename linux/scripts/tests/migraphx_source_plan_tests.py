"""Extracted shell plans test archive, compiler and configuration gates, not a real backend build."""

import hashlib
import io
import os
import re
import shlex
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORKER = ROOT / "linux/scripts/03-media/build/migraphx/prepare-source-build.sh"
COMMON = WORKER.with_name("source-common.sh")
FEATURES = (
    "MIGRAPHX_ENABLE_GPU", "MIGRAPHX_ENABLE_MLIR", "MIGRAPHX_USE_COMPOSABLEKERNEL",
    "MIGRAPHX_USE_ROCBLAS", "MIGRAPHX_USE_HIPBLASLT", "MIGRAPHX_USE_MIOPEN",
    "MIGRAPHX_USE_HIPRTC", "MIGRAPHX_ENABLE_PYTHON", "MIGRAPHX_ENABLE_ONNX",
    "MIGRAPHX_ENABLE_TENSORFLOW",
)


class MigraphxSourcePlanTests(unittest.TestCase):
    """Independent expected flags and negative caches must reject omitted source gates."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="mgx source plan ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.work = self.root / "work with spaces"
        (self.work / "build").mkdir(parents=True)
        self.clang = self.root / "pinned compiler"
        self.gcc = self.root / "gcc with spaces"
        self.source = WORKER.read_text()
        self.env = dict(os.environ, USE_CCACHE="0", USE_SCCACHE="0", USE_LLD="0",
                        LLVM_RELEASE="23.1.5", MIGRAPHX_CLANG_PREFIX=str(self.clang),
                        MIGRAPHX_SOURCE_PREFIX=str(self.root / "install prefix"))
        cache = [f"{feature}:BOOL=ON" for feature in FEATURES]
        cache += [
            f"CMAKE_C_COMPILER:FILEPATH={self.clang}/bin/clang",
            f"CMAKE_CXX_COMPILER:FILEPATH={self.clang}/bin/clang++",
            "CMAKE_C_COMPILER_LAUNCHER:STRING=/fixture-cache",
            "CMAKE_CXX_COMPILER_LAUNCHER:STRING=/fixture-cache",
            "HAS_HIP:INTERNAL=1",
            "MIGRAPHX_SELECTED_PYTHON_EXECUTABLE:INTERNAL=/pinned python",
        ]
        self.cache = "\n".join(cache) + "\n"

    def shell(self, body: str, name: str = "probe") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\n" + body, name], env=self.env,
            capture_output=True, text=True, check=False, timeout=15,
        )

    def configured(self, cache: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        (self.work / "build/CMakeCache.txt").write_text(cache)
        start = self.source.index("\ncmake_args=(\n")
        end = self.source.index("sha256sum ", start)
        verify = self.source.index('cmake_assert_compiler_cache_pin "${work}/build"')
        tail = self.source[verify:]
        prelude = (
            f"source {shlex.quote(str(ROOT / 'linux/scripts/01-core/cmake-cache-linker.sh'))}\n"
            f"source {shlex.quote(str(COMMON))}\n"
            f"work={shlex.quote(str(self.work))}\nclang_root={shlex.quote(str(self.clang))}\n"
            f"gcc_root={shlex.quote(str(self.gcc))}\nrocm='/rocm sdk'\n"
            "HOST_PYTHON_BIN='/pinned python'\npybind_dir='/selected pybind'\nPY_PYBIND11_VERSION=3.1.0\nPYTHON_VERSION=3.15.2\nROCM_VERSION=10.1\ndeps_prefix='/selected deps'\ncmake_args=(obsolete flags)\n"
        )
        result = self.shell(
            prelude + self.source[start:end]
            + "CMAKE_COMPILER_CACHE_PIN=/fixture-cache\n" + tail
        )
        values = (self.work / "cmake-argv.nul").read_bytes().split(b"\0")
        return result, [value.decode() for value in values if value]

    def test_full_feature_and_argument_contract(self) -> None:
        self.assertIn('source "${SCRIPT_DIR}/entry-common.sh"', self.source)
        self.assertIn('source "${SCRIPT_DIR}/source-common.sh"', WORKER.with_name("entry-common.sh").read_text())
        self.assertIn("migraphx_compiler_setup clang_root gcc_root", self.source)
        result, args = self.configured(self.cache)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("obsolete", args)
        for feature in FEATURES:
            self.assertIn(f"-D{feature}:BOOL=ON", args)
        self.assertIn(f"-DCMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN={self.gcc}", args)
        self.assertIn(f"-DCMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN={self.gcc}", args)
        self.assertTrue(any(value.startswith("-DCMAKE_PREFIX_PATH=/selected deps;") for value in args))
        self.assertIn("-DPython_EXECUTABLE=/pinned python", args)
        self.assertIn("-DMIGRAPHX_REQUIRED_PYTHON_VERSION=3.15.2", args)
        self.assertIn("-DMIGRAPHX_REQUIRED_PYBIND11_VERSION=3.1.0", args)
        self.assertIn("-Dpybind11_DIR=/selected pybind", args)
        self.assertIn(f"-DCMAKE_CXX_COMPILER={self.clang}/bin/clang++", args)

    def test_source_input_hashes_bind_both_patches_and_selected_Python_module(self) -> None:
        relatives = ["source.tar.gz", "rocm-cmake-source.tar.gz", "msgpack-source.tar.gz",
                     "source/src/eliminate_pad.cpp", "source/test/eliminate_pad_test.cpp",
                     "source/cmake/PythonModules.cmake", "padding.patch", "Python selection.patch"]
        expected = {}
        for relative in relatives:
            file = self.work / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(("independent source input: " + relative).encode())
            expected[str(file)] = hashlib.sha256(file.read_bytes()).hexdigest()
        start = self.source.index('sha256sum "${work}/source.tar.gz"')
        end = self.source.index('\ncmake "${cmake_args[@]}"', start)
        result = self.shell(
            "work=" + shlex.quote(str(self.work)) + "\npatch_file=" + shlex.quote(str(self.work / "padding.patch"))
            + "\npython_patch_file=" + shlex.quote(str(self.work / "Python selection.patch")) + "\n" + self.source[start:end])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = (self.work / "source-inputs.sha256").read_text()
        self.assertEqual({line[66:]: line[:64] for line in manifest.splitlines()}, expected)
        (self.work / "source/cmake/PythonModules.cmake").write_text("changed selected Python source")
        changed = self.shell("sha256sum --check " + shlex.quote(str(self.work / "source-inputs.sha256")))
        self.assertNotEqual(changed.returncode, 0)
        self.assertRegex(changed.stdout, r"PythonModules\.cmake\x27?: FAILED")

    def test_each_disabled_feature_refuses(self) -> None:
        for feature in FEATURES:
            with self.subTest(feature=feature):
                result, _args = self.configured(self.cache.replace(f"{feature}:BOOL=ON",
                                                                  f"{feature}:BOOL=OFF"))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_missing_duplicate_compiler_cache_and_hip_facts_refuse(self) -> None:
        bad = [
            self.cache.replace("MIGRAPHX_ENABLE_GPU:BOOL=ON\n", ""),
            self.cache + "MIGRAPHX_ENABLE_GPU:BOOL=OFF\n",
            self.cache.replace(f"{self.clang}/bin/clang++", "/distro/clang++"),
            self.cache.replace("CMAKE_CXX_COMPILER_LAUNCHER:STRING=/fixture-cache",
                               "CMAKE_CXX_COMPILER_LAUNCHER:STRING=/wrong-cache"),
            self.cache.replace("HAS_HIP:INTERNAL=1\n", ""),
            self.cache.replace("MIGRAPHX_SELECTED_PYTHON_EXECUTABLE:INTERNAL=/pinned python",
                               "MIGRAPHX_SELECTED_PYTHON_EXECUTABLE:INTERNAL=/foreign python"),
        ]
        for number, cache in enumerate(bad):
            with self.subTest(case=number):
                result, _args = self.configured(cache)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_llvm_version_gate_rejects_distro_drift(self) -> None:
        (self.clang / "bin").mkdir(parents=True)
        compiler = self.clang / "bin/clang++"
        for version, expected in (("clang version 23.1.5 (fixture)", 0),
                                  ("Ubuntu clang version 23.1.6 (fixture)", 1)):
            with self.subTest(version=version):
                compiler.write_text("#!/bin/sh\nprintf '%s\\\n' " + shlex.quote(version) + "\n")
                compiler.chmod(0o755)
                result = self.shell(
                    f"source {shlex.quote(str(COMMON))}\n"
                    + "gcc_toolchain_resolve_prefix() { printf '/fixture gcc'; }\n"
                    + shlex.join(["migraphx_compiler_setup", "selected_clang", "selected_gcc",
                                  str(self.work / "compiler.txt")])
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_compiler_setup_publishes_slots_and_preserves_failures(self) -> None:
        (self.clang / "bin").mkdir(parents=True)
        compiler = self.clang / "bin/clang++"
        compiler.write_text("#!/bin/sh\nprintf '%s\\n' 'clang version 23.1.5 (fixture)'\n")
        compiler.chmod(0o755)
        prelude = f"source {shlex.quote(str(COMMON))}\n"
        call = shlex.join(["migraphx_compiler_setup", "clang_root", "gcc_root",
                           str(self.work / "compiler.txt")])
        result = self.shell(prelude + "gcc_toolchain_resolve_prefix() { printf '/fixture gcc'; }\n"
                            + call + '\nprintf "%s\\n" "$clang_root" "$gcc_root"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(self.clang), "/fixture gcc"])
        failed_gcc = self.shell(prelude + "gcc_toolchain_resolve_prefix() { return 29; }\n" + call)
        self.assertEqual(failed_gcc.returncode, 29, failed_gcc.stderr)
        compiler.write_text("#!/bin/sh\nexit 17\n")
        failed_compiler = self.shell(prelude + call)
        self.assertEqual(failed_compiler.returncode, 17, failed_compiler.stderr)

    def test_owned_defaults_preserve_explicit_prefixes(self) -> None:
        start = self.source.index(': "${MIGRAPHX_SOURCE_PREFIX:=')
        end = self.source.index("\ncmake_args=(\n", start)
        defaults = self.source[start:end]
        for source, deps, expected in [
            ("", "", ["/opt/rocm/migraphx", str(self.work / "host-deps")]),
            ("/explicit install", "/explicit deps", ["/explicit install", "/explicit deps"]),
        ]:
            with self.subTest(source=source, deps=deps):
                result = self.shell(
                    f"work={shlex.quote(str(self.work))}\n"
                    + f"MIGRAPHX_SOURCE_PREFIX={shlex.quote(source)}\n"
                    + f"MIGRAPHX_DEPS_PREFIX={shlex.quote(deps)}\n"
                    + defaults + '\nprintf "%s\\n" "$MIGRAPHX_SOURCE_PREFIX" "$deps_prefix"\n'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_shared_work_keeps_scope_refuses_reuse_and_retains_raw_status(self) -> None:
        destination = self.root / "new native work"
        prelude = f"source {shlex.quote(str(COMMON))}\nwork=untouched\n"
        call = shlex.join(["migraphx_new_work", str(destination), "work"])
        result = self.shell(prelude + call + '\nprintf "%s\\n" "$work"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(destination.resolve()))
        reused = self.shell(prelude + call)
        self.assertEqual(reused.returncode, 1, reused.stderr)
        failed = self.root / "failed cd"
        command = shlex.join(["migraphx_new_work", str(failed), "work"])
        result = self.shell(
            prelude + "cd() { return 27; }\nstatus=0\n" + command
            + ' || status=$?\nprintf "%s\\n" "$work"\nexit "$status"\n'
        )
        self.assertEqual(result.returncode, 27, result.stderr)
        self.assertEqual(result.stdout.strip(), "untouched")

    def test_native_work_keeps_compiler_slots_and_selected_failures(self) -> None:
        prelude = (
            f"source {shlex.quote(str(COMMON))}\n"
            + 'work=untouched\nclang_root=unset\ngcc_root=unset\n'
            + 'migraphx_compiler_setup() { printf -v "$1" /clang; printf -v "$2" /gcc; return "$compiler_status"; }\n'
        )
        for name, compiler_status in [("success", 0), ("compiler failure", 37)]:
            path = self.root / name
            call = shlex.join(["migraphx_prepare_native_work", str(path), "work", "clang_root", "gcc_root"])
            result = self.shell(prelude + f"compiler_status={compiler_status}\nstatus=0\n" + call
                                + ' || status=$?\nprintf "%s\\n" "$work" "$clang_root" "$gcc_root"\nexit "$status"\n')
            self.assertEqual(result.returncode, compiler_status, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [str(path), "/clang", "/gcc"])
            reused = self.shell(prelude + "compiler_status=0\n" + call)
            self.assertEqual(reused.returncode, 1, reused.stderr)

    def test_source_pin_shapes_refuse_missing_or_nonhex_values(self) -> None:
        start = self.source.index('[[ "${MIGRAPHX_WINDOWS_COMMIT:-}"')
        end = self.source.index('migraphx_new_work "${work}" work', start)
        cases = [
            ("a" * 40, "b" * 64, 0), ("z" * 40, "b" * 64, 1),
            ("a" * 39, "b" * 64, 1), ("a" * 40, "g" * 64, 1),
            ("a" * 40, "", 1),
        ]
        for commit, digest, expected in cases:
            with self.subTest(commit=commit, digest=digest):
                result = self.shell(
                    "MIGRAPHX_WINDOWS_COMMIT=" + shlex.quote(commit) + "\n"
                    + "MIGRAPHX_WINDOWS_SOURCE_SHA256=" + shlex.quote(digest) + "\n"
                    + self.source[start:end]
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def archive_function(self) -> str:
        match = re.search(r"migraphx_prepare_source_tree\(\) \{.*?\n}\n", COMMON.read_text(), re.DOTALL)
        assert match is not None
        return match[0]

    def test_verified_archive_and_stale_copy_failure(self) -> None:
        archive = self.root / "input archive.tar.gz"
        with tarfile.open(archive, "w:gz") as stream:
            member = tarfile.TarInfo("upstream/value.txt")
            member.size = 4
            stream.addfile(member, io.BytesIO(b"data"))
        raw = archive.read_bytes()
        sha = hashlib.sha256(raw).hexdigest()
        destination = self.root / "extracted"
        prelude = f"source {shlex.quote(str(ROOT / 'linux/scripts/01-core/downloads.sh'))}\n"
        command = prelude + self.archive_function() + "\n"
        def run(path: Path, expected_sha: str, tree: Path) -> subprocess.CompletedProcess[str]:
            return self.shell(command + shlex.join([
                "migraphx_prepare_source_tree", str(path), expected_sha, str(tree)
            ]))
        result = run(archive, sha, destination)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((destination / "value.txt").read_bytes(), b"data")
        mismatch = self.root / "mismatch"
        self.assertEqual(run(archive, "0" * 64, mismatch).returncode, 1)
        self.assertFalse(mismatch.exists())
        stale = self.root / "stale"
        Path(str(stale) + ".tar.gz").write_bytes(raw)
        self.assertEqual(run(self.root / "missing archive", sha, stale).returncode, 1)
        self.assertFalse(stale.exists())
        self.assertEqual(archive.read_bytes(), raw)
        self.assertEqual(run(archive, sha, destination).returncode, 1)

    def test_bad_archive_retains_raw_extraction_failure(self) -> None:
        archive = self.root / "invalid archive"
        archive.write_bytes(b"not a gzip archive")
        command = (
            f"source {shlex.quote(str(ROOT / 'linux/scripts/01-core/downloads.sh'))}\n"
            + self.archive_function() + "\n" + shlex.join([
                "migraphx_prepare_source_tree", str(archive),
                hashlib.sha256(archive.read_bytes()).hexdigest(), str(self.root / "bad"),
            ])
        )
        self.assertEqual(self.shell(command).returncode, 2)


    def test_shared_cmake_plan_preserves_argument_bytes_and_cache_publication(self) -> None:
        path = self.root / "planned argv.nul"
        body = r"""
declare -a selected=('original value with spaces' '')
append_cmake_cache_linker_args() {
  local -n selected_cache_args="$1"
  selected_cache_args+=('-DFIXTURE_CACHE=launcher with spaces')
  CMAKE_COMPILER_CACHE_PIN='/selected launcher'
}
migraphx_prepare_cmake_plan selected '/clang with spaces' '/gcc with spaces' """ + shlex.quote(str(path)) + r""" '/source with spaces' '/build with spaces'
[[ "$CMAKE_COMPILER_CACHE_PIN" == '/selected launcher' ]]
"""
        result = self.shell("source " + shlex.quote(str(COMMON)) + "\n" + body)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(path.read_bytes().split(b"\0")[:-1], [
            b"-S", b"/source with spaces", b"-B", b"/build with spaces", b"-G", b"Ninja",
            b"original value with spaces", b"",
            b"-DCMAKE_C_COMPILER=/clang with spaces/bin/clang",
            b"-DCMAKE_CXX_COMPILER=/clang with spaces/bin/clang++",
            b"-DCMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN=/gcc with spaces",
            b"-DCMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN=/gcc with spaces",
            b"-DFIXTURE_CACHE=launcher with spaces"])

    def test_shared_cmake_plan_retains_raw_selection_failures(self) -> None:
        path = self.root / "must not be written.nul"
        for phase, status in [("native", 23), ("cache", 37)]:
            body = r"""
declare -a selected=(original)
migraphx_native_cmake_args() { [[ "$FAIL_PHASE" != native ]] || return 23; }
append_cmake_cache_linker_args() { [[ "$FAIL_PHASE" != cache ]] || return 37; }
migraphx_prepare_cmake_plan selected '/clang' '/gcc' """ + shlex.quote(str(path)) + " '/source' '/build'"
            self.env["FAIL_PHASE"] = phase
            result = self.shell("source " + shlex.quote(str(COMMON)) + "\n" + body)
            self.assertEqual(result.returncode, status, result.stdout + result.stderr)
            self.assertFalse(path.exists())



    def test_shared_cmake_directories_preserve_option_arguments(self) -> None:
        for initial, tail in [("unset selected", []),
                              ("declare -a selected=('existing option with spaces' '')",
                               [b"existing option with spaces", b""])]:
            body = ("source " + shlex.quote(str(COMMON)) + "\n" + initial + "\n"
                    + "migraphx_cmake_directories selected '/source with spaces' '/build with spaces'\n"
                    + '[[ "$(declare -p selected)" == "declare -a "* ]]\n'
                    + "printf '%s\\0' \"${selected[@]}\"\n")
            result = self.shell(body)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.encode().split(b"\0")[:-1],
                             [b"-S", b"/source with spaces", b"-B", b"/build with spaces", b"-G", b"Ninja", *tail])


    def test_shared_consumer_configuration_keeps_options_scope_and_expected_entries(self) -> None:
        output = self.root / "consumer actual.nul"
        entries = self.root / "consumer entries.nul"
        body = r"""
declare -a chosen=('original option with spaces' '')
append_cmake_cache_linker_args() { CMAKE_COMPILER_CACHE_PIN='/selected cache'; }
cmake() { printf '%s\0' "$@" > "$ACTUAL"; }
cmake_assert_compiler_cache_pin() { [[ "$1" == "$CONSUMER_WORK/build" && "$2" == '/selected cache' ]]; }
cmake_assert_configured_entries() { printf '%s\0' "$@" > "$ENTRIES"; }
migraphx_configure_native_consumer chosen "$CONSUMER_WORK" '/source project' '/source clang' '/source GCC' 17 'CUSTOM=value with spaces' 'EMPTY='
"""
        self.env.update(ACTUAL=str(output), ENTRIES=str(entries), CONSUMER_WORK=str(self.root))
        result = self.shell("source " + shlex.quote(str(COMMON)) + "\n" + body)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected = [b"-S", b"/source project", b"-B", str(self.root / "build").encode(), b"-G", b"Ninja",
                    b"-DCMAKE_BUILD_TYPE=Release", b"-DCMAKE_CXX_STANDARD=17",
                    b"original option with spaces", b"", b"-DCMAKE_C_COMPILER=/source clang/bin/clang",
                    b"-DCMAKE_CXX_COMPILER=/source clang/bin/clang++",
                    b"-DCMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN=/source GCC",
                    b"-DCMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN=/source GCC"]
        self.assertEqual(output.read_bytes().split(b"\0")[:-1], expected)
        self.assertEqual((self.root / "cmake-argv.nul").read_bytes(), output.read_bytes())
        self.assertEqual(entries.read_bytes().split(b"\0")[:-1],
                         [str(self.root / "build").encode(), b"first", b"CMAKE_CXX_COMPILER=/source clang/bin/clang++",
                          b"CMAKE_CXX_STANDARD=17", b"CUSTOM=value with spaces", b"EMPTY="])

    def test_shared_consumer_configuration_keeps_raw_phase_failures(self) -> None:
        body = r"""
declare -a chosen=(original)
migraphx_prepare_cmake_plan() { [[ "$FAIL_PHASE" != plan ]] || return 23; }
cmake() { [[ "$FAIL_PHASE" != configure ]] || return 37; }
cmake_assert_compiler_cache_pin() { [[ "$FAIL_PHASE" != cache ]] || return 39; }
cmake_assert_configured_entries() { [[ "$FAIL_PHASE" != verdict ]] || return 41; }
status=0
migraphx_configure_native_consumer chosen '/new work' '/project' '/clang' '/gcc' 17 'CUSTOM=value' || status=$?
exit "$status"
"""
        for phase, status in [("plan", 23), ("configure", 37), ("cache", 39), ("verdict", 41)]:
            self.env["FAIL_PHASE"] = phase
            result = self.shell("source " + shlex.quote(str(COMMON)) + "\n" + body)
            self.assertEqual(result.returncode, status, (phase, result.stdout, result.stderr))


    def test_shared_native_consumer_build_preserves_selection_publication_and_raw_status(self) -> None:
        library = self.root / "actual archive.a"
        library.write_bytes(b"fixture bytes")
        build = self.root / "build"
        build.mkdir()
        (build / "imported-library.txt").write_text(str(library) + "\n")
        body = r"""
published=unset
cmake() {
  [[ "$published" == "$EXPECTED" ]] || return 43
  printf '%s\0' "$@" > "$BUILD_ARGS"
  return "$BUILD_STATUS"
}
status=0
migraphx_build_native_consumer "$CONSUMER_WORK" "$EXPECTED" 2 published || status=$?
printf '%s\n' "$published"
exit "$status"
"""
        for status in [0, 37]:
            args = self.root / ("build args " + str(status))
            self.env.update(CONSUMER_WORK=str(self.root), EXPECTED=str(library),
                            BUILD_ARGS=str(args), BUILD_STATUS=str(status))
            result = self.shell("source " + shlex.quote(str(COMMON)) + "\n" + body)
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertEqual(result.stdout.strip(), str(library))
            self.assertEqual(args.read_bytes().split(b"\0")[:-1], [b"--build", str(build).encode(), b"--parallel", b"2"])
        read_failure = "source " + shlex.quote(str(COMMON)) + "\ncat() { return 29; }\n" + body
        self.assertEqual(self.shell(read_failure).returncode, 29)
        (build / "imported-library.txt").write_text(str(self.root / "foreign archive.a") + "\n")
        self.assertEqual(self.shell("source " + shlex.quote(str(COMMON)) + "\n" + body).returncode, 1)


if __name__ == "__main__":
    unittest.main()
