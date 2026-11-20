"""Real shell dependency transport with command doubles; no vendor C++ or GPU build is executed."""

import hashlib
import io
import os
import shlex
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"


class MigraphxSourceDepsTests(unittest.TestCase):
    """Independent flags, raw failures and exact original notices constrain dependency staging."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="mgx deps ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env = dict(os.environ, LC_ALL="C", USE_CCACHE="0", USE_SCCACHE="0", USE_LLD="0")
        self.cache = (
            'BUILD_SHARED_LIBS:BOOL=OFF\n'
            'CMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON\n'
            'FETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON\n'
            'CMAKE_C_COMPILER:FILEPATH=/pinned clang/bin/clang\n'
            'CMAKE_CXX_COMPILER:FILEPATH=/pinned clang/bin/clang++\n'
            'CMAKE_CXX_STANDARD:STRING=17\n'
            'CMAKE_C_COMPILER_LAUNCHER:STRING=/fixture-cache\n'
            'CMAKE_CXX_COMPILER_LAUNCHER:STRING=/fixture-cache\n'
        )
        self.calls = 0

    def shell(self, body: str) -> subprocess.CompletedProcess[str]:
        prelude = "\n".join([
            "set -euo pipefail",
            f"source {shlex.quote(str(ROOT / 'linux/scripts/01-core/downloads.sh'))}",
            f"source {shlex.quote(str(ROOT / 'linux/scripts/01-core/cmake-cache-linker.sh'))}",
            f"source {shlex.quote(str(LIB / 'source-common.sh'))}",
            f"source {shlex.quote(str(LIB / 'source-deps.sh'))}",
        ]) + "\n"
        return subprocess.run(["bash", "-c", prelude + body], env=self.env, capture_output=True,
                              text=True, check=False, timeout=15)

    def make_archive(self, dep: str, omit: str = "") -> tuple[Path, str]:
        archive = self.root / (dep + str(self.calls) + ".tar.gz")
        files = {"LICENSE": b"Original license\r\nunchanged bytes\n"}
        if dep == "rocm-cmake":
            files["CMakeLists.txt"] = b"rocm_setup_version(VERSION 0.14.0)\n"
        if dep == "protobuf":
            files["third_party/utf8_range/LICENSE"] = b"Original MIT utf8_range notice\n"
        with tarfile.open(archive, "w:gz") as stream:
            for name, raw in files.items():
                if name != omit:
                    member = tarfile.TarInfo("upstream/" + name)
                    member.size = len(raw)
                    stream.addfile(member, io.BytesIO(raw))
        return archive, hashlib.sha256(archive.read_bytes()).hexdigest()

    def build(self, dep: str = "protobuf", phase: str = "", cache: str | None = None,
              omit: str = "") -> tuple[subprocess.CompletedProcess[str], Path]:
        self.calls += 1
        work = self.root / ("work " + str(self.calls))
        work.mkdir()
        archive, digest = self.make_archive(dep, omit)
        selected_cache = self.cache.replace("CMAKE_CXX_STANDARD:STRING=17", "CMAKE_CXX_STANDARD:STRING=20") if dep == "ck" else self.cache
        self.env.update(FAKE_CACHE=selected_cache if cache is None else cache, FAIL_PHASE=phase)
        self.env["EVENT_LOG"] = str(work / "events")
        callbacks = r"""
append_cmake_cache_linker_args() {
  [[ "$FAIL_PHASE" != resolver ]] || return 31
  if [[ "$FAIL_PHASE" != no-pin ]]; then CMAKE_COMPILER_CACHE_PIN=/fixture-cache; fi
}
cmake() {
  local phase=configure build= args=()
  args=("$@")
  if [[ "$1" == --build || "$1" == --install ]]; then
    phase="${1#--}"
  else
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == -B ]]; then build="$2"; break; fi
      shift
    done
    mkdir -p "$build"
    printf '%s' "$FAKE_CACHE" > "$build/CMakeCache.txt"
    printf '%s\0' "${args[@]}" > "$build/actual-argv.nul"
  fi
  printf '%s\n' "$phase" >> "$EVENT_LOG"
  [[ "$FAIL_PHASE" != "$phase" ]] || return 37
}
"""
        body = callbacks + shlex.join([
            "migraphx_build_static_dep", dep, str(archive), digest, str(work),
            "/pinned clang", "/gcc with spaces",
        ])
        return self.shell(body), work

    def test_real_transport_and_original_notices(self) -> None:
        for dep in ["abseil", "protobuf", "ck"]:
            result, work = self.build(dep)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((work / "events").read_text().splitlines(),
                             ["configure", "build", "install"])
            notices = work / "host-deps/share/licenses"
            self.assertEqual((notices / dep / "LICENSE").read_bytes(),
                             b"Original license\r\nunchanged bytes\n")
            if dep == "protobuf":
                self.assertEqual((notices / "utf8_range/LICENSE").read_bytes(),
                                 b"Original MIT utf8_range notice\n")
            self.assertTrue((work / (dep + "-source.tar.gz")).is_file())

    def test_independent_static_pic_offline_and_compiler_arguments(self) -> None:
        for dep in ["abseil", "protobuf", "ck"]:
            result, work = self.build(dep)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = (work / (dep + "-build/actual-argv.nul")).read_bytes().split(b"\0")
            expected = [
                "-DBUILD_SHARED_LIBS:BOOL=OFF", "-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON",
                "-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON",
                "-DCMAKE_CXX_COMPILER=/pinned clang/bin/clang++",
                "-DCMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN=/gcc with spaces",
                f"-DCMAKE_PREFIX_PATH={work}/host-deps" + (f";{work}/host-tools" if dep == "ck" else ""),
                "-DCMAKE_CXX_STANDARD=" + ("20" if dep == "ck" else "17"),
            ]
            expected += (["-DABSL_ENABLE_INSTALL:BOOL=ON", "-DABSL_PROPAGATE_CXX_STD:BOOL=ON"]
                         if dep == "abseil" else (["-DEMBED_USE:STRING=CArrays", "-DBUILD_TESTING:BOOL=OFF"] if dep == "ck" else [
                             "-Dprotobuf_LOCAL_DEPENDENCIES_ONLY:BOOL=ON",
                             "-Dprotobuf_FORCE_FETCH_DEPENDENCIES:BOOL=OFF",
                             "-Dprotobuf_BUILD_PROTOC_BINARIES:BOOL=ON",
                             "-Dprotobuf_BUILD_SHARED_LIBS:BOOL=OFF",
                         ]))
            if dep == "ck":
                expected += ["-S", str(work / "ck-source/codegen")]
            for value in expected:
                self.assertIn(value.encode(), args)

    def test_child_failures_preserve_status_and_stop_later_phases(self) -> None:
        for phase, status, expected in [
            ("resolver", 31, []), ("no-pin", 1, []),
            ("configure", 37, ["configure"]),
            ("build", 37, ["configure", "build"]),
            ("install", 37, ["configure", "build", "install"]),
        ]:
            with self.subTest(phase=phase):
                result, work = self.build(phase=phase)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                events = work / "events"
                self.assertEqual(events.read_text().splitlines() if events.exists() else [], expected)
                self.assertFalse((work / "host-deps/share/licenses/protobuf/LICENSE").exists())

    def test_cache_override_missing_feature_and_compiler_drift_refuse(self) -> None:
        cases = [
            self.cache.replace("/fixture-cache", "/wrong-cache"),
            self.cache.replace("BUILD_SHARED_LIBS:BOOL=OFF", "BUILD_SHARED_LIBS:BOOL=ON"),
            self.cache.replace("CMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON", "CMAKE_POSITION_INDEPENDENT_CODE:BOOL=OFF"),
            self.cache.replace("FETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON", "FETCHCONTENT_FULLY_DISCONNECTED:BOOL=OFF"),
            self.cache.replace("CMAKE_CXX_COMPILER:FILEPATH=/pinned clang/bin/clang++",
                               "CMAKE_CXX_COMPILER:FILEPATH=/distro/clang++"),
            self.cache.replace("CMAKE_CXX_STANDARD:STRING=17", "CMAKE_CXX_STANDARD:STRING=11"),
        ]
        for cache in cases:
            result, work = self.build(cache=cache)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual((work / "events").read_text().splitlines(), ["configure"])

    def test_missing_original_notices_remain_fatal(self) -> None:
        for dep, missing in [("ck", "LICENSE"), ("abseil", "LICENSE"), ("protobuf", "LICENSE"),
                             ("protobuf", "third_party/utf8_range/LICENSE")]:
            with self.subTest(dep=dep, missing=missing):
                result, _work = self.build(dep, omit=missing)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_unknown_dependency_refuses_before_archive_copy(self) -> None:
        result, work = self.build("unrecognized")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(list(work.iterdir()))

    def test_entrypoints_import_shared_companions_and_keep_order(self) -> None:
        source = (LIB / "build-source-deps.sh").read_text()
        self.assertIn('source "${SCRIPT_DIR}/entry-common.sh"', source)
        self.assertIn('source "${SCRIPT_DIR}/source-deps.sh"', source)
        self.assertLess(source.index("migraphx_build_static_dep abseil"),
                        source.index("migraphx_build_static_dep protobuf"))
        self.assertIn('"${MIGRAPHX_WINDOWS_ABSEIL_SHA256}"', source)
        self.assertIn('"${MIGRAPHX_WINDOWS_PROTOBUF_SHA256}"', source)
        self.assertIn('migraphx_prepare_native_work "${work}" work clang_root gcc_root', source)


    def test_ck_rejects_cxx17_and_keeps_child_failures_raw(self) -> None:
        result, work = self.build("ck", cache=self.cache)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((work / "events").read_text().splitlines(), ["configure"])
        for phase in ["configure", "build", "install"]:
            with self.subTest(phase=phase):
                result, _work = self.build("ck", phase=phase)
                self.assertEqual(result.returncode, 37, result.stdout + result.stderr)

    def test_rocm_tools_keep_version_original_license_and_raw_failures(self) -> None:
        archive, digest = self.make_archive("rocm-cmake")
        for phase in ["", "configure", "install"]:
            with self.subTest(phase=phase):
                self.calls += 1
                work = self.root / ("tools " + str(self.calls))
                work.mkdir()
                self.env.update(MIGRAPHX_ROCM_CMAKE_SOURCE_SHA256=digest,
                                MIGRAPHX_ROCM_CMAKE_VERSION="0.14.0", FAIL_PHASE=phase)
                body = r"""
cmake() {
  local phase=configure
  if [[ "$1" == --install ]]; then phase=install; fi
  [[ "$FAIL_PHASE" != "$phase" ]] || return 37
}
""" + shlex.join(["migraphx_prepare_rocm_cmake", str(work), str(archive)])
                result = self.shell(body)
                self.assertEqual(result.returncode, 37 if phase else 0, result.stdout + result.stderr)
                notice = work / "host-tools/share/licenses/rocm-cmake/LICENSE"
                if phase:
                    self.assertFalse(notice.exists())
                else:
                    self.assertEqual(notice.read_bytes(), b"Original license\r\nunchanged bytes\n")
        work = self.root / "wrong tool version"
        work.mkdir()
        self.env["MIGRAPHX_ROCM_CMAKE_VERSION"] = "0.0.0"
        result = self.shell("cmake() { return 99; }\n" + shlex.join([
            "migraphx_prepare_rocm_cmake", str(work), str(archive)]))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_ck_entrypoint_uses_recorded_archive_and_shared_tools(self) -> None:
        entry = (LIB / "build-source-ck.sh").read_text()
        self.assertIn("'NEW_WORK CK_ARCHIVE ROCM_CMAKE_ARCHIVE' 3", entry)
        self.assertIn('migraphx_prepare_rocm_cmake "${work}" "${rocm_cmake_archive}"', entry)
        self.assertIn('"${MIGRAPHX_CK_SOURCE_SHA256}"', entry)
        self.assertLess(entry.index("migraphx_prepare_rocm_cmake"), entry.index("migraphx_build_static_dep ck"))
        prepare = (LIB / "prepare-source-build.sh").read_text()
        self.assertIn('migraphx_prepare_rocm_cmake "${work}" "${rocm_cmake_archive}"', prepare)


if __name__ == "__main__":
    unittest.main()
