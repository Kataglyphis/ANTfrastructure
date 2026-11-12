"""Real CMake resolution over isolated config doubles; no SDK ABI, compiler or GPU claim."""

import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SDK = ROOT / "linux/scripts/03-media/build/migraphx/sdk-closure"
PACKAGES = (
    "hip", "hsa-runtime64", "miopen", "rocblas", "hipblaslt", "hipblas",
    "hiprtc", "SQLite3", "pybind11", "composable_kernel_host", "rocMLIR",
)
VERSIONED = ("composable_kernel_host", "rocMLIR")


class MigraphxSDKClosureTests(unittest.TestCase):
    """Every independently expected package must resolve; absent or incompatible metadata stays red."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="mgx SDK metadata ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.prefix = self.root / "prefix with spaces"
        for name in PACKAGES:
            directory = self.prefix / "lib/cmake" / name
            directory.mkdir(parents=True)
            (directory / (name.lower() + "-config.cmake")).write_text(
                f"set({name}_FOUND TRUE)\n"
            )
            (directory / (name.lower() + "-config-version.cmake")).write_text(
                "set(PACKAGE_VERSION 1.0.0)\nset(PACKAGE_VERSION_COMPATIBLE TRUE)\n"
            )

    def resolve(self) -> subprocess.CompletedProcess[str]:
        command = ["cmake", f"-DCMAKE_PREFIX_PATH={self.prefix}"]
        for scope in ["CMAKE_SYSTEM_PATH", "SYSTEM_ENVIRONMENT_PATH", "CMAKE_ENVIRONMENT_PATH",
                      "PACKAGE_ROOT_PATH", "PACKAGE_REGISTRY", "SYSTEM_PACKAGE_REGISTRY"]:
            command.append(f"-DCMAKE_FIND_USE_{scope}=FALSE")
        command += ["-P", str(SDK / "SdkPackages.cmake")]
        return subprocess.run(command, capture_output=True, text=True, check=False,
                              env=dict(os.environ, LC_ALL="C"), timeout=20)

    def test_all_independently_expected_packages_are_resolved(self) -> None:
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        found = re.findall(r"^-- MIGRAPHX SDK found ([\w-]+):", result.stdout, re.MULTILINE)
        self.assertCountEqual(found, PACKAGES)
        self.assertEqual(len(found), len(PACKAGES))
        self.assertNotIn("MIGRAPHX SDK missing", result.stdout)

    def test_each_absent_package_refuses_with_its_identity(self) -> None:
        for name in PACKAGES:
            with self.subTest(package=name):
                config = self.prefix / "lib/cmake" / name / (name.lower() + "-config.cmake")
                original = config.read_text()
                config.unlink()
                try:
                    result = self.resolve()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn(f"MIGRAPHX SDK missing {name}", result.stdout)
                    self.assertIn("SDK development packages missing", result.stderr)
                finally:
                    config.write_text(original)

    def test_required_package_versions_are_enforced(self) -> None:
        for name in VERSIONED:
            with self.subTest(package=name):
                config = self.prefix / "lib/cmake" / name / (name.lower() + "-config-version.cmake")
                original = config.read_text()
                config.write_text("set(PACKAGE_VERSION 0.5.0)\nset(PACKAGE_VERSION_COMPATIBLE FALSE)\n")
                try:
                    result = self.resolve()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn(f"MIGRAPHX SDK missing {name}@1.0.0", result.stdout)
                finally:
                    config.write_text(original)

    def test_existing_package_that_reports_not_found_refuses(self) -> None:
        config = self.prefix / "lib/cmake/hip/hip-config.cmake"
        config.write_text("set(hip_FOUND FALSE)\n")
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("MIGRAPHX SDK missing hip", result.stdout)

    def test_provider_variables_cannot_erase_an_earlier_missing_fact(self) -> None:
        (self.prefix / "lib/cmake/hip/hip-config.cmake").unlink()
        provider = self.prefix / "lib/cmake/pybind11/pybind11-config.cmake"
        provider.write_text(provider.read_text() + 'set(missing "")\n')
        result = self.resolve()
        self.assertNotIn("Parse error", result.stderr)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("SDK development packages missing", result.stderr)
        self.assertIn("MIGRAPHX SDK missing hip", result.stdout)

    def test_bounded_transport_modes_and_raw_status(self) -> None:
        worker = SDK.parent / "configure-proof.sh"
        text = worker.read_text()
        body = text[text.index('case "${1:-configure}"'):]
        body = body.replace("/proof/configure.log", shlex.quote(str(self.root / "dispatch.log")))
        argv = self.root / "argv"
        jobs = self.root / "worker-jobs"
        stub = ("bash() { printf '%s\\0' \"$@\" > " + shlex.quote(str(argv))
                + "; printf '%s\\0' \"${JOBS:-}\" \"${BUILD_JOBS:-}\" \"${MAX_JOBS:-}\" > "
                + shlex.quote(str(jobs)) + "; return \"$FAKE_STATUS\"; }\n")
        for mode, fake, expected, target in [
            ("", 0, 0, "prepare-source-build.sh"), ("sdk", 0, 0, "check-source-sdk.sh"),
            ("sdk", 37, 37, "check-source-sdk.sh"),
            ("parsers", 0, 0, "build-source-deps.sh"), ("parsers", 37, 37, "build-source-deps.sh"),
            ("ck", 0, 0, "build-source-ck.sh"), ("ck", 37, 37, "build-source-ck.sh"),
            ("python-consumer", 0, 0, "verify-source-python.sh"), ("python-consumer", 37, 37, "verify-source-python.sh"),
            ("rocmlir-consumer", 0, 0, "verify-source-rocmlir.sh"), ("rocmlir-consumer", 37, 37, "verify-source-rocmlir.sh"),
            ("rocmlir", 0, 0, "prepare-source-rocmlir.sh"), ("rocmlir", 37, 37, "prepare-source-rocmlir.sh"),
            ("rocmlir-build", 0, 0, "build-source-rocmlir.sh"), ("rocmlir-build", 37, 37, "build-source-rocmlir.sh"),
            ("ck-consumer", 0, 0, "verify-source-ck.sh"), ("ck-consumer", 37, 37, "verify-source-ck.sh"), ("unrecognized", 0, 2, ""),
        ]:
            with self.subTest(mode=mode, status=fake):
                argv.unlink(missing_ok=True)
                result = subprocess.run(
                    ["bash", "-c", "set -euo pipefail\n" + stub + body, "dispatch", mode],
                    capture_output=True, text=True, check=False, timeout=10,
                    env=dict(os.environ, LC_ALL="C", FAKE_STATUS=str(fake)),
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if mode == "rocmlir-build":
                    self.assertEqual(jobs.read_bytes().split(b"\0")[:-1], [b"4", b"4", b"4"])
                if target:
                    expected_args = {
                        "prepare-source-build.sh": ["/proof/work", "/source.tar.gz", "/rocm-cmake.tar.gz", "/msgpack.tar.gz", "/opt/rocm"],
                        "check-source-sdk.sh": ["/proof/work", "/opt/rocm"],
                        "build-source-deps.sh": ["/proof/work", "/abseil.tar.gz", "/protobuf.tar.gz"],
                        "build-source-ck.sh": ["/proof/work", "/source.tar.gz", "/rocm-cmake.tar.gz"],
                        "verify-source-python.sh": ["/proof/work", "/migraphx-original-source"],
                        "verify-source-rocmlir.sh": ["/proof/work", "/deps-prefix", "/rocmlir-original-source"],
                        "prepare-source-rocmlir.sh": ["/proof/work", "/source.tar.gz", "/rocm-cmake.tar.gz", "/opt/rocm"],
                        "build-source-rocmlir.sh": ["/proof/work", "/source.tar.gz", "/rocm-cmake.tar.gz", "/opt/rocm"],
                        "verify-source-ck.sh": ["/proof/work", "/deps-prefix", "/ck-original-header.hpp"],
                    }[target]
                    expected_args.insert(0, "/hub/linux/scripts/03-media/build/migraphx/" + target)
                    self.assertEqual(argv.read_bytes().split(b"\0")[:-1], [value.encode() for value in expected_args])
                else:
                    self.assertFalse(argv.exists())


    def test_supplied_development_prefix_precedes_image_sdk_paths(self) -> None:
        text = (SDK.parent / "check-source-sdk.sh").read_text()
        start = text.index('prefix_path=')
        end = text.index('if [[ "${pybind_status}"', start)
        body = ("source " + shlex.quote(str(SDK.parent / "source-common.sh")) + "\n"
                + text[start:end] + "\nprintf '%s\\0' \"${cmake_args[@]}\"\n")
        for prefix in ["", "/supplied development prefix"]:
            env = dict(os.environ, LC_ALL="C", MIGRAPHX_DEPS_PREFIX=prefix,
                       rocm="/ROCm with spaces", ROCM_VERSION="10.1", SCRIPT_DIR="/source scripts", work="/new work")
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", body], capture_output=True,
                                    check=False, timeout=10, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = result.stdout.split(b"\0")
            expected = "/ROCm with spaces;/ROCm with spaces/core;/ROCm with spaces/core/lib/rocm_sysdeps;/ROCm with spaces/extras-10/lib/migraphx"
            if prefix:
                expected = prefix + ";" + expected
            self.assertIn(("-DCMAKE_PREFIX_PATH=" + expected).encode(), args)

    def test_shared_cli_resolves_its_root_before_validation(self) -> None:
        body = (
            "set -euo pipefail\nsource " + shlex.quote(str(SDK.parent / "cli-common.sh"))
            + ' value 1 "$@"\nprintf "%s\\n" "$SCRIPT_DIR" "$work" "$1"\n'
        )
        for args, status in [(["value with spaces"], 0), ([], 2), ([""], 2)]:
            result = subprocess.run(["bash", "-c", body, "cli", *args], capture_output=True,
                                    text=True, check=False, env=dict(os.environ, LC_ALL="C"), timeout=10)
            self.assertEqual(result.returncode, status, result.stdout + result.stderr)
            if status == 0:
                self.assertEqual(result.stdout.splitlines(), [str(SDK.parent), args[0], args[0]])
            else:
                self.assertEqual(result.stdout, "")

    def test_shared_entry_keeps_source_scope_and_selected_failures(self) -> None:
        entry = SDK.parent / "entry-common.sh"
        for name, init, module, export, companion, expected in [
            ("valid", 0, 0, True, True, 0), ("init", 23, 0, True, True, 23),
            ("module", 0, 17, True, True, 17), ("api", 0, 0, False, True, 1),
            ("companion", 0, 0, True, False, 1), ("core", 0, 0, True, True, 1),
        ]:
            with self.subTest(name=name):
                base = self.root / name
                scripts = base / "build/migraphx"
                scripts.mkdir(parents=True)
                (base / "core").mkdir()
                if name != "core":
                    (base / "core/common.sh").write_text(
                        'declare SDK_SCOPE_SENTINEL=visible\n'
                        + f"media_common_init() {{ return {init}; }}\n"
                        + f"source_module() {{ return {module}; }}\n"
                    )
                if companion:
                    (scripts / "source-common.sh").write_bytes((SDK.parent / "source-common.sh").read_bytes())
                body = "set -euo pipefail\nunset -f gcc_toolchain_resolve_prefix\nunset SDK_SCOPE_SENTINEL\nSCRIPT_DIR=" + shlex.quote(str(scripts)) + "\n"
                if export:
                    body += "gcc_toolchain_resolve_prefix() { printf '/fixture gcc'; }\n"
                body += "source " + shlex.quote(str(entry))
                body += '\nprintf "%s\\n" "${SDK_SCOPE_SENTINEL:-missing}"\n'
                result = subprocess.run(["bash", "-c", body], capture_output=True, text=True,
                                        check=False, env=dict(os.environ, LC_ALL="C"), timeout=10)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if expected == 0:
                    self.assertEqual(result.stdout.strip(), "visible")

    def test_entrypoint_and_project_keep_shared_transport(self) -> None:
        source = (SDK.parent / "check-source-sdk.sh").read_text()
        self.assertIn('source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh"', source)
        self.assertIn('source "${SCRIPT_DIR}/entry-common.sh"', source)
        self.assertIn('source "${SCRIPT_DIR}/source-common.sh"',
                      (SDK.parent / "entry-common.sh").read_text())
        self.assertIn('migraphx_prepare_native_work "${work}" work clang_root gcc_root', source)
        self.assertIn('migraphx_prepare_cmake_plan cmake_args "${clang_root}" "${gcc_root}"', source)
        self.assertIn('migraphx_native_cmake_args "$1" "$2" "$3" || return',
                      (SDK.parent / "source-common.sh").read_text())
        self.assertIn('cmake_assert_compiler_cache_pin "${work}/build"', source)
        self.assertIn('include("${CMAKE_CURRENT_LIST_DIR}/SdkPackages.cmake")',
                      (SDK / "CMakeLists.txt").read_text())


if __name__ == "__main__":
    unittest.main()
