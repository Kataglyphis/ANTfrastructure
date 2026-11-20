"""Normal AMD entry, mounts and shell failure controls do not prove vendor builds, loader ABI, licences or GPU/image acceptance."""

import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from dockerfile_runs import dockerfile_runs

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"
ENTRY_DOUBLE = r"""
image_event() {
  printf '%s\n' "$1" >> "$EVENTS"
  if [[ "$FAIL_PHASE" == "$1" ]]; then return 43; fi
  return 0
}
setup_host_python_environment() {
  image_event python || return
  HOST_PYTHON_BIN="$SELECTED_PYTHON"
}
uv() {
  image_event uv || return
  printf '%s\0' "$@" > "$UV_ARGS"
}
ldconfig() { image_event ldconfig; }
PY_PYBIND11_VERSION="${TEST_PYBIND_PIN-3.1.0}"
"""
STACK_DOUBLE = r"""#!/usr/bin/env bash
set -euo pipefail
printf 'stack\n' >> "$EVENTS"
printf '%s\0' "$@" > "$STACK_ARGS"
printf '%s' "${MIGRAPHX_SOURCE_PREFIX:-}" > "$PREFIX_RECORD"
if [[ "$FAIL_PHASE" == stack ]]; then exit 45; fi
"""
PUBLICATION_DOUBLE = r"""
publish_rocm_ld_path() {
  printf 'publish\n' >> "$EVENTS"
  if [[ "$FAIL_PHASE" == publish ]]; then return 47; fi
  return 0
}
"""
CORE_FILES = [
    'modules.sh', 'module-bootstrap.sh', 'path-helpers.sh', 'common.sh', 'compiler-cache-utils.sh',
    'load-versions-env.sh', 'versions.env', 'logging.sh', 'platform.sh', 'arch-mapping.sh',
    'ubuntu-mirror.sh', 'downloads.sh', 'download-loader.sh', 'parallelism.sh', 'guard-helpers.sh',
    'cross-env.sh', 'cross-gcc.sh', 'cross-python.sh', 'cross-apt.sh', 'cross-meson.sh',
    'cross-active-fallback.sh', 'compiler-cache.sh', 'compiler-resolution.sh', 'cmake-cache-linker.sh',
    'python-host.sh', 'abseil-headers.sh', 'qnn-sdk.sh', 'build-helpers.sh', 'image-ref-args.sh',
    'elf-strip.sh', 'sccache-server-address.sh', 'sccache-s3-level.sh', 'sccache-launcher.sh',
    'apply-patch.sh', 'sudo-policy.sh', 'install-deps-preamble.sh'
]
BUILD_FILES = [
    'build-image.sh', 'build-source-stack.sh', 'source-stack.sh', 'source-archives.txt',
    'cli-common.sh', 'entry-common.sh', 'native-check-common.sh', 'source-common.sh', 'build-source-deps.sh', 'source-deps.sh',
    'build-source-ck.sh', 'verify-source-ck.sh', 'ck-host-consumer/CMakeLists.txt',
    'ck-host-consumer/main.cpp', 'build-source-rocmlir.sh', 'prepare-source-rocmlir.sh',
    'source-rocmlir.sh', 'rocmlir-source-notices.sha256', 'inspect-rocmlir-build.py',
    'verify-source-rocmlir.sh', 'rocmlir-host-consumer/CMakeLists.txt',
    'rocmlir-host-consumer/main.cpp', 'check-hip-compiler.sh', 'hip-compiler-probe.hip',
    'check-source-sdk.sh', 'sdk-closure/CMakeLists.txt',
    'sdk-closure/SdkPackages.cmake', 'build-source-backend.sh', 'prepare-source-build.sh',
    'stage-backend-install.py', 'backend-source-notices.sha256'
]


def bundle_provisions() -> dict[str, tuple[str, str]]:
    """Inspect real staged bytes and modes against the independently declared image contract."""
    with tempfile.TemporaryDirectory(prefix="Actual script bundle ") as temporary:
        output = Path(temporary) / "bundle"
        command = ["python3", str(ROOT / "linux/scripts/stage-script-closure.py"), "migraphx-image", "--output", str(output)]
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=15)
        if result.returncode:
            raise AssertionError(result.stderr)
        records = json.loads((output / "SCRIPT-CLOSURE.json").read_text())["files"]
        actual = {path.relative_to(output).as_posix() for path in output.rglob("*") if path.is_file()}
        if actual != {*records, "SCRIPT-CLOSURE.json"}:
            raise AssertionError("The staged tree differs from its selected manifest")
        provided = {}
        for target, record in records.items():
            path = output / target
            source = "linux/scripts/" + record["source"]
            if path.read_bytes() != (ROOT / source).read_bytes():
                raise AssertionError("The staged source bytes differ")
            provided["/opt/scripts/" + target] = (source, format(path.stat().st_mode & 0o777, "o"))
        return provided


def normal_run() -> str:
    """Select the real producer invocation rather than a comment or an unrelated apt RUN."""
    matches = [text for _, text in dockerfile_runs(str(ROOT / "linux/Dockerfile.amd"))
               if re.search(r"\bbash /opt/scripts/03-media/build/migraphx/build-image\.sh ", text)]
    if len(matches) != 1:
        raise AssertionError("Expected exactly one normal AMD source producer RUN")
    return matches[0]


class ImageEntryTests(unittest.TestCase):
    """Explicit child doubles test invocation boundaries and raw failures without modifying a host SDK."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="MIGraphX image entry ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.scripts = self.root / "linux/scripts/03-media/build/migraphx"
        self.scripts.mkdir(parents=True)
        for name in ("build-image.sh", "cli-common.sh"):
            shutil.copy2(LIB / name, self.scripts)
        companions = self.scripts.parents[2] / "lib"
        companions.mkdir()
        for name in ("cli-value-options.sh", "log-bootstrap.sh"):
            shutil.copy2(ROOT / "linux/scripts/lib" / name, companions)
        (self.scripts / "entry-common.sh").write_text(ENTRY_DOUBLE)
        (self.scripts / "build-source-stack.sh").write_text(STACK_DOUBLE)
        packaging = self.scripts.parents[2] / "06-packaging"
        packaging.mkdir()
        (packaging / "media-payloads.sh").write_text(PUBLICATION_DOUBLE)
        selected_python = self.root / "selected Python/python"
        selected_python.parent.mkdir()
        selected_python.write_text('''#!/usr/bin/env bash\nset -euo pipefail\nprintf 'loads\\n' >> "$EVENTS"\nprintf '%s\\0' "$@" > "$LOAD_ARGS"\nif [[ "$FAIL_PHASE" == loads ]]; then exit 49; fi\n''')
        selected_python.chmod(0o755)
        self.events = self.root / "events"
        self.env = dict(os.environ, LC_ALL="C", FAIL_PHASE="", EVENTS=str(self.events),
                        SELECTED_PYTHON=str(selected_python), UV_ARGS=str(self.root / "uv.nul"), LOAD_ARGS=str(self.root / "loads.nul"),
                        STACK_ARGS=str(self.root / "stack.nul"), PREFIX_RECORD=str(self.root / "prefix"))
        self.env.pop("MIGRAPHX_SOURCE_PREFIX", None)
        self.args = [str(self.root / "new work"), str(self.root / "source cache"), "/opt/rocm"]

    def run_entry(self, args: list[str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(self.scripts / "build-image.sh"), *(self.args if args is None else args)],
                              env=self.env, capture_output=True, text=True, check=False, timeout=15)

    def recorded_events(self) -> list[str]:
        return self.events.read_text().splitlines() if self.events.exists() else []

    def test_normal_order_retains_exact_python_pin_and_complete_stack_argv(self) -> None:
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded_events(), ["python", "uv", "stack", "publish", "ldconfig", "loads"])
        self.assertEqual((self.root / "loads.nul").read_bytes().split(b"\0")[:-1],
                         [os.fsencode(self.scripts / "stage-backend-install.py"), b"verify-loads", b"--prefix", b"/opt/rocm/migraphx"])
        self.assertEqual((self.root / "uv.nul").read_bytes().split(b"\0")[:-1],
                         [b"pip", b"install", b"--python", os.fsencode(self.env["SELECTED_PYTHON"]), b"--no-deps", b"pybind11==3.1.0"])
        self.assertEqual((self.root / "stack.nul").read_bytes().split(b"\0")[:-1],
                         [arg.encode() for arg in self.args])
        self.assertEqual((self.root / "prefix").read_text(), "/opt/rocm/migraphx")

    def test_selected_pin_changes_the_exact_install_not_a_default(self) -> None:
        self.env["TEST_PYBIND_PIN"] = "9.8.7"
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"pybind11==9.8.7\0", (self.root / "uv.nul").read_bytes())

    def test_missing_pin_refuses_before_install_or_build(self) -> None:
        self.env["TEST_PYBIND_PIN"] = ""
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing selected pybind11 pin", result.stderr)
        self.assertEqual(self.recorded_events(), ["python"])

    def test_each_required_failure_stops_later_phases_and_keeps_raw_status(self) -> None:
        cases = [("python", 43), ("uv", 43), ("stack", 45), ("publish", 47), ("ldconfig", 43), ("loads", 49)]
        order = ["python", "uv", "stack", "publish", "ldconfig", "loads"]
        for phase, expected in cases:
            with self.subTest(phase=phase):
                self.events.unlink(missing_ok=True)
                self.env["FAIL_PHASE"] = phase
                result = self.run_entry()
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(self.recorded_events(), order[:order.index(phase) + 1])

    def test_foreign_image_prefix_refuses_before_any_operation(self) -> None:
        self.env["MIGRAPHX_SOURCE_PREFIX"] = "/different source prefix"
        result = self.run_entry()
        self.assertEqual(result.returncode, 2)
        self.assertIn("canonical MIGraphX source prefix", result.stderr)
        self.assertEqual(self.recorded_events(), [])

    def test_explicit_canonical_prefix_remains_supported(self) -> None:
        self.env["MIGRAPHX_SOURCE_PREFIX"] = "/opt/rocm/migraphx"
        self.assertEqual(self.run_entry().returncode, 0)

    def test_wrong_argument_counts_fail_before_import_or_install(self) -> None:
        for args in ([], self.args[:2], [*self.args, "unexpected"]):
            with self.subTest(args=args):
                self.assertNotEqual(self.run_entry(args).returncode, 0)
                self.assertEqual(self.recorded_events(), [])


class ImageWiringTests(unittest.TestCase):
    """Concrete source files and actual RUN shell controls grade integration policy rather than installed binaries."""

    def test_required_build_core_and_shared_companions_are_fresh_named_files(self) -> None:
        expected = {f"/opt/scripts/core/{name}": f"linux/scripts/01-core/{name}" for name in CORE_FILES}
        expected.update({f"/opt/scripts/03-media/build/migraphx/{name}":
                         f"linux/scripts/03-media/build/migraphx/{name}" for name in BUILD_FILES})
        for name in ("03-media/core/common.sh", "03-media/core/arch-flags-amd64.env",
                     "lib/cli-value-options.sh", "lib/log-bootstrap.sh",
                     "patches/migraphx/001-preserve-zero-pad-maxpool.patch",
                     "patches/migraphx/002-select-pinned-python.patch",
                     "06-packaging/ort_census_probe.py", "06-packaging/smoke-common.sh", "06-packaging/media-payloads.sh"):
            expected["/opt/scripts/" + name] = "linux/scripts/" + name
        for name in ("vulkan.sh", "bootstrap-import.sh", "bootstrap.sh", "vulkan-install.sh"):
            expected["/opt/scripts/toolchain/" + name] = "linux/scripts/02-toolchain/" + name
        expected_modes = {target: (source, "755" if target.endswith(".sh") else "644")
                          for target, source in expected.items()}
        self.assertEqual(bundle_provisions(), expected_modes)

    def test_exact_bundle_is_mounted_readonly_once_in_the_compile_run(self) -> None:
        run = normal_run()
        binds = re.findall(r"--mount=type=bind,[^\s]+", run)
        self.assertEqual(binds, ["--mount=type=bind,from=hub-scripts,source=/${HUB_SCRIPTS_KEY}/files,target=/opt/scripts,ro"])
        text = (ROOT / "linux/Dockerfile.amd").read_text()
        self.assertEqual(text.count("LABEL org.kataglyphis.build-script-closure=migraphx-image"), 1)
        self.assertNotIn("source=linux/scripts,target=", text)

    def test_both_compile_caches_source_uv_and_secrets_are_preserved(self) -> None:
        run = normal_run()
        for target, identifier in (("/var/cache/ccache", "ccache-${TARGETARCH}"),
                                   ("/var/cache/sccache", "sccache-${TARGETARCH}"),
                                   ("/var/cache/migraphx-source", "migraphx-source-${TARGETARCH}"),
                                   ("/root/.cache/uv", "uv-cache-${TARGETARCH}")):
            self.assertIn(f"--mount=type=cache,target={target},id={identifier},sharing=locked", run)
        for name in ("asset_mirror", "sccache_s3"):
            self.assertIn(f"--mount=type=secret,id={name},required=false", run)
        self.assertNotIn("--mount=type=tmpfs", run)

    def test_normal_stage_keeps_apt_sdk_then_builds_full_stack_before_environment(self) -> None:
        text = (ROOT / "linux/Dockerfile.amd").read_text()
        self.assertLess(text.index("bash /tmp/core-scripts/setup-rocm-repo.sh"), text.index("LABEL kataglyphis.step=migraphx-source"))
        self.assertLess(text.index(normal_run()), text.index('ENV PATH="/opt/rocm/migraphx/bin:'))
        self.assertIn("build-image.sh /tmp/migraphx-source-stack /var/cache/migraphx-source /opt/rocm", normal_run())
        self.assertNotRegex(normal_run(), r"(?:purge|remove).*(?:amdrocm|migraphx)")

    def test_gpu_environment_prioritizes_source_for_each_search_mechanism(self) -> None:
        text = (ROOT / "linux/Dockerfile.amd").read_text()
        for expected in ('MIGRAPHX_HOME="/opt/rocm/migraphx"', 'PATH="/opt/rocm/migraphx/bin:',
                         'PKG_CONFIG_PATH="/opt/rocm/migraphx/lib/pkgconfig:/opt/rocm/migraphx/lib64/pkgconfig:',
                         'PYTHONPATH="/opt/rocm/migraphx/lib:', 'CMAKE_PREFIX_PATH="/opt/rocm/migraphx:',
                         'LD_LIBRARY_PATH="/opt/rocm/migraphx/lib:/opt/rocm/migraphx/lib/migraphx/lib:/opt/rocm/migraphx/lib64:'):
            self.assertIn(expected, text)

    def test_gpu_path_keeps_inherited_compilers_before_distro_and_rocm_tools(self) -> None:
        text = (ROOT / "linux/Dockerfile.amd").read_text()
        matches = re.findall(r'^ENV PATH="([^"]+)"', text, re.MULTILINE)
        self.assertEqual(len(matches), 1)
        expression = matches[0]
        for original, variable in (("/opt/rocm/migraphx/bin", "${TEST_MGX_BIN}"),
                                   ("/usr/lib/llvm-${LLVM_RELEASE%%.*}/bin", "${TEST_DISTRO_BIN}"),
                                   ("/opt/rocm/bin", "${TEST_ROCM_BIN}")):
            expression = expression.replace(original, variable)
        with tempfile.TemporaryDirectory(prefix="AMD inherited PATH ") as temporary:
            root = Path(temporary)
            paths = {name: root / name for name in ("native GNU", "native LLVM", "base", "source MIGraphX", "distro LLVM", "ROCm")}
            tools = {"native GNU": ["gcc", "g++", "cc", "c++"], "native LLVM": ["clang", "clang++", "llvm-config"],
                     "base": ["migraphx-driver"], "source MIGraphX": ["migraphx-driver"],
                     "distro LLVM": ["clang", "clang++", "llvm-config"], "ROCm": ["clang", "clang++", "llvm-config", "hipcc"]}
            for name, binaries in tools.items():
                paths[name].mkdir()
                for binary in binaries:
                    path = paths[name] / binary
                    path.write_text("#!/bin/sh\nexit 0\n")
                    path.chmod(0o755)
            initial = ":".join(str(paths[name]) for name in ("native GNU", "native LLVM", "base"))
            selected = [*(paths["native GNU"] / name for name in tools["native GNU"]),
                        *(paths["native LLVM"] / name for name in tools["native LLVM"]),
                        paths["source MIGraphX"] / "migraphx-driver", paths["ROCm"] / "hipcc"]
            script = 'PATH="$1"\nPATH="' + expression + '"\nprintf "%s\\n" "$PATH"\n'
            script += 'for tool in gcc g++ cc c++ clang clang++ llvm-config migraphx-driver hipcc; do command -v "$tool"; done\n'
            environment = dict(os.environ, LLVM_RELEASE="23.1.5", TEST_MGX_BIN=str(paths["source MIGraphX"]),
                               TEST_DISTRO_BIN=str(paths["distro LLVM"]), TEST_ROCM_BIN=str(paths["ROCm"]))
            result = subprocess.run(["bash", "-c", script, "_", initial], env=environment,
                                    capture_output=True, text=True, check=False, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(initial, result.stdout.splitlines()[0])
            self.assertEqual(result.stdout.splitlines()[1:], [str(path) for path in selected])

    def test_shipped_runtime_environment_is_conditional_and_keeps_existing_search_paths(self) -> None:
        text = (ROOT / "linux/Dockerfile.package").read_text()
        expected = {
            "MIGRAPHX_HOME": "${ROCM_ON:+/opt/rocm/migraphx}",
            "PATH": "${ROCM_ON:+/opt/rocm/migraphx/bin:}${PATH}${ROCM_ON:+:/opt/rocm/bin}",
            "PKG_CONFIG_PATH": "${ROCM_ON:+/opt/rocm/migraphx/lib/pkgconfig:/opt/rocm/migraphx/lib64/pkgconfig:}${PKG_CONFIG_PATH}",
            "PYTHONPATH": "${ROCM_ON:+/opt/rocm/migraphx/lib:}${PYTHONPATH:-}",
            "CMAKE_PREFIX_PATH": "${ROCM_ON:+/opt/rocm/migraphx:}${CMAKE_PREFIX_PATH:-}",
            "LD_LIBRARY_PATH": "${ROCM_ON:+/opt/rocm/migraphx/lib:/opt/rocm/migraphx/lib/migraphx/lib:/opt/rocm/migraphx/lib64:}${LD_LIBRARY_PATH:-}",
        }
        for name, value in expected.items():
            self.assertRegex(text, re.escape(name) + r'="?' + re.escape(value) + r'(?:"|\s)')
        for enabled in ("", "true"):
            code = 'ROCM_ON="$1"\nPATH=/original/bin\nPKG_CONFIG_PATH=/original/pkg\nPYTHONPATH=/original/py\n'
            code += 'CMAKE_PREFIX_PATH=/original/cmake\nLD_LIBRARY_PATH=/original/lib\n'
            for name, value in expected.items():
                code += f'{name}="{value}"\nprintf "%s\\n" "${name}"\n'
            result = subprocess.run(["bash", "-c", code, "_", enabled], capture_output=True, text=True, check=False, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            values = result.stdout.splitlines()
            self.assertEqual(values[0], "/opt/rocm/migraphx" if enabled else "")
            for value, original in zip(values[1:], ("/original/bin", "/original/pkg", "/original/py", "/original/cmake", "/original/lib"), strict=True):
                self.assertIn(original, value)
                self.assertEqual(value.startswith("/opt/rocm/migraphx"), bool(enabled))

    def test_publisher_is_shared_without_reintroducing_a_private_copy(self) -> None:
        shared = (ROOT / "linux/scripts/06-packaging/media-payloads.sh").read_text()
        copy = (ROOT / "linux/scripts/06-packaging/copy-media-payloads.sh").read_text()
        self.assertEqual(shared.count("publish_rocm_ld_path() {"), 1)
        self.assertNotIn("publish_rocm_ld_path() {", copy)
        self.assertIn("  publish_rocm_ld_path\n", copy)
        self.assertIn('source "${SCRIPT_DIR}/../../../06-packaging/media-payloads.sh"', (LIB / "build-image.sh").read_text())

    def test_actual_run_shell_preserves_build_failure_and_drains_without_cleanup(self) -> None:
        self.run_shell(37)

    def test_actual_run_shell_cleans_successful_work_and_drains(self) -> None:
        self.run_shell(0)

    def run_shell(self, build_status: int) -> None:
        with tempfile.TemporaryDirectory(prefix="AMD RUN shell ") as temporary:
            root = Path(temporary)
            events = root / "events"
            build = root / "build.sh"
            drain = root / "drain.sh"
            work = root / "source work"
            build.write_text('printf "build\\n" >> "$EVENTS"\nmkdir "$1"\nexit "$BUILD_STATUS"\n')
            drain.write_text('printf "drain\\n" >> "$EVENTS"\nexit "$DRAIN_STATUS"\n')
            run = normal_run()
            body = run[run.index("    set -euo pipefail;"):].replace("\\\n", "")
            body = body.replace("/opt/scripts/03-media/build/migraphx/build-image.sh", shlex.quote(str(build)))
            body = body.replace("/opt/scripts/core/sccache-s3-level.sh", '"${DRAIN_DRIVER}"')
            body = body.replace("/tmp/migraphx-source-stack", shlex.quote(str(work)))
            for drain_status in (0, 41):
                events.unlink(missing_ok=True)
                if work.exists():
                    work.rmdir()
                env = dict(os.environ, EVENTS=str(events), BUILD_STATUS=str(build_status), DRAIN_STATUS=str(drain_status), DRAIN_DRIVER=str(drain))
                result = subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True, check=False, timeout=10)
                expected = build_status or drain_status
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(events.read_text().splitlines(), ["build", "drain"] if expected != 41 else ["build", "drain", "drain"])
                self.assertEqual(work.exists(), bool(build_status))


if __name__ == "__main__":
    unittest.main()
