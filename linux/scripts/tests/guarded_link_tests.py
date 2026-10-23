#!/usr/bin/env python3
"""Private filesystem receipts cover link guards and caller policies, not system sysroots, SDK builds or privileged installation."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
SCRIPTS = Path(sys.argv.pop(1)).resolve()
DRIVER = r"""set -euo pipefail
source "$HELPERS"
source "$FUNCTION"
log() { printf 'LOG:%s\n' "$*"; }
record() { printf '%s\n' "$@" >> "$TRACE"; }
mkdir() { record mkdir "$@"; command mkdir "$@"; }
ln() {
  record ln "$@"
  [ "$LN_STATUS" = 0 ] || return "$LN_STATUS"
  command ln "$@"
}
rm() { record rm "$@"; command rm "$@"; }
basename() {
  record basename "$@"
  if [ "$SCENARIO" = vanished-source ]; then command rm -rf "$1"; fi
  command basename "$@"
}
uname() { record uname "$@"; printf fixture-host; }
fake_sudo() {
  record sudo "$@"
  [ "$PREFIX_STATUS" = 0 ] || return "$PREFIX_STATUS"
  shift 2
  "$@"
}
case "$SCENARIO" in
  unset-sudo) unset SUDO ;;
  prefix|prefix-failure) SUDO='fake_sudo --scope fixture' ;;
  *) SUDO='' ;;
esac
if [ "$API" = gcc ]; then
  invocation=(stage_cross_gcc_sysroot_libs "$WORK/prefix" fixture-target)
else
  invocation=(_vulkan_setup_sdk_includes requested fixture-target "$WORK/sdk")
fi
trap 'for name in SDK_ARCHDIR CMAKE_PREFIX_PATH CMAKE_INCLUDE_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH entry; do printf "%s=%s\n" "$name" "${!name-<unset>}"; done > "$WORK/state"' EXIT
if [ "$CONTEXT" = conditional ]; then
  if "${invocation[@]}"; then exit 0; else exit "$?"; fi
fi
"${invocation[@]}"
"""
SCENARIOS = {
    "gcc": (
        "fresh",
        "existing",
        "dangling-dest",
        "missing-source",
        "prefix",
        "prefix-failure",
        "ln-failure",
        "unset-sudo",
        "vanished-source",
    ),
    "vulkan": (
        "fresh",
        "existing",
        "dangling-dest",
        "missing-source",
        "prefix",
        "prefix-failure",
        "ln-failure",
        "unset-sudo",
        "vanished-source",
        "fallback-arch",
        "missing-sdk",
        "no-include",
    ),
}


def function_source(scripts, api):
    module, function = (
        ("gcc.sh", "stage_cross_gcc_sysroot_libs")
        if api == "gcc"
        else ("vulkan.sh", "_vulkan_setup_sdk_includes")
    )
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1/test-harness.sh"; t_fn_src "$2" "$3"',
            "_",
            str(TESTS),
            str(scripts / "02-toolchain" / module),
            function,
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    )
    return result.stdout


def plant_sources(work, api, scenario):
    source = work / ("usr/fixture-target/lib" if api == "gcc" else "usr/include")
    if scenario == "missing-source":
        return source
    source.mkdir(parents=True)
    directory, file, spaced, link = (
        ("directory", "file.so", "space lib.so", "link.so")
        if api == "gcc"
        else ("X11", "wayland-client.h", "xf86drm spaced.h", "wayland-link.h")
    )
    (source / directory).mkdir()
    (source / file).write_text("payload")
    (source / spaced).write_text("spaced")
    (source / link).symlink_to(source / file)
    (source / ("broken.so" if api == "gcc" else "wayland-broken.h")).symlink_to(
        source / "absent"
    )
    return source


def plant_destinations(work, api, scenario, source):
    destination = work / (
        "prefix/fixture-target/lib" if api == "gcc" else "usr/fixture-target/include"
    )
    if scenario not in ("existing", "dangling-dest"):
        return
    destination.mkdir(parents=True)
    for path in source.iterdir():
        if not path.exists():
            continue
        target = destination / path.name
        if scenario == "dangling-dest":
            target.symlink_to(work / "absent-target")
        else:
            target.write_text("keep")


def snapshot(work):
    result = []
    for root in (work / "usr", work / "prefix"):
        for path in sorted(root.rglob("*")):
            relative = str(path.relative_to(work))
            if path.is_symlink():
                result.append(
                    f"link:{relative}->{os.readlink(path).replace(str(work), 'WORK')}"
                )
            elif path.is_file():
                result.append(f"file:{relative}:{path.read_text()}")
    return result


def capture_case(scripts, api, scenario, context, function):
    with tempfile.TemporaryDirectory(prefix="ant-guarded-links-") as temporary:
        work = Path(temporary)
        source = plant_sources(work, api, scenario)
        plant_destinations(work, api, scenario, source)
        if api == "vulkan" and scenario != "missing-sdk":
            sdk = (
                work
                / "sdk"
                / ("fixture-host" if scenario == "fallback-arch" else "requested")
            )
            sdk.mkdir(parents=True)
            if scenario != "no-include":
                (sdk / "include/vulkan").mkdir(parents=True)
                (sdk / "include/vk_video").mkdir()
        function_file = work / "function.sh"
        function_file.write_text(function.replace("/usr", str(work / "usr")))
        env = dict(
            os.environ,
            WORK=str(work),
            HELPERS=str(scripts / "01-core/path-helpers.sh"),
            FUNCTION=str(function_file),
            TRACE=str(work / "trace"),
            SCENARIO=scenario,
            API=api,
            CONTEXT=context,
            LN_STATUS="41" if scenario == "ln-failure" else "0",
            PREFIX_STATUS="43" if scenario == "prefix-failure" else "0",
            CMAKE_PREFIX_PATH="prior cmake",
            CMAKE_INCLUDE_PATH="prior includes",
            CPATH="prior cpath",
            C_INCLUDE_PATH="prior c",
            CPLUS_INCLUDE_PATH="prior c++",
        )
        env.pop("_PATH_HELPERS_SH_LOADED", None)
        result = subprocess.run(
            ["bash", "-c", DRIVER],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        return {
            "status": result.returncode,
            "stdout": result.stdout.replace(str(work), "WORK"),
            "stderr": result.stderr.replace(str(work), "WORK"),
            "trace": (work / "trace").read_text().replace(str(work), "WORK")
            if (work / "trace").exists()
            else "",
            "state": (work / "state").read_text().replace(str(work), "WORK"),
            "files": snapshot(work),
        }


def capture(scripts):
    result = {}
    for api, scenarios in SCENARIOS.items():
        function = function_source(scripts, api)
        for scenario in scenarios:
            for context in ("strict", "conditional"):
                result[f"{api}:{scenario}:{context}"] = capture_case(
                    scripts, api, scenario, context, function
                )
    return result


def plant_module_bundle(root, scripts, layout, module):
    base = root / ("linux/scripts" if layout == "repo" else "installed")
    toolchain = base / ("02-toolchain" if layout == "repo" else "toolchain")
    core = base / ("01-core" if layout == "repo" else "core")
    toolchain.mkdir(parents=True)
    core.mkdir()
    for name in (module, "vulkan-install.sh", "bootstrap-import.sh"):
        shutil.copy2(scripts / "02-toolchain" / name, toolchain / name)
    bootstrap = (
        (scripts / "02-toolchain/bootstrap.sh")
        .read_text()
        .replace("/opt/scripts/core", str(core))
    )
    (toolchain / "bootstrap.sh").write_text(bootstrap)
    for name in ("load-versions-env.sh", "path-helpers.sh"):
        shutil.copy2(scripts / "01-core" / name, core / name)
    (toolchain / "path-helpers.sh").write_text("echo POISON; exit 79\n")
    return toolchain / module, core


def import_bundle(path, context, env=None):
    command = "unset -f source_toolchain_required; download_file() { :; }; "
    command += (
        'source "$1"; echo imported'
        if context == "direct"
        else 'if source "$1"; then echo imported; else exit "$?"; fi'
    )
    return subprocess.run(
        ["bash", "-euc", command, "_", str(path)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )


def broken_bundle_imports(path, core):
    original = (core / "path-helpers.sh").read_bytes()
    for defect in ("missing-file", "missing-export", "stale-guard"):
        (core / "path-helpers.sh").write_bytes(original)
        env = dict(os.environ)
        env.pop("_PATH_HELPERS_SH_LOADED", None)
        if defect == "missing-file":
            (core / "path-helpers.sh").unlink()
        elif defect == "missing-export":
            (core / "path-helpers.sh").write_text(":\n")
        else:
            env["_PATH_HELPERS_SH_LOADED"] = "1"
        for context in ("direct", "conditional"):
            yield defect, context, import_bundle(path, context, env)


class GuardedLinks(unittest.TestCase):
    def test_original_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("guarded-link-receipts.json").read_text()
        )
        actual = capture(SCRIPTS)
        for name, receipt in expected.items():
            with self.subTest(name=name):
                self.assertEqual(receipt, actual[name])

    def test_lazy_sudo_and_destination_guard(self):
        command = r"""set -u
source "$1"
ln() { printf 'LN:%s:%s:%s' "$1" "$2" "$3"; }
unset SUDO
path_symlink_missing '/missing source' "$2/existing" -sfn required
path_symlink_missing '/missing source' "$2/absent" -s optional
"""
        with tempfile.TemporaryDirectory(prefix="ant-link-policy-") as temporary:
            root = Path(temporary)
            (root / "existing").write_text("keep")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    command,
                    "_",
                    str(SCRIPTS / "01-core/path-helpers.sh"),
                    str(root),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(0, result.returncode)
            self.assertEqual(f"LN:-s:/missing source:{root}/absent", result.stdout)
            command = r"""set -eu; source "$1"; unset SUDO; path_symlink_missing source "$2/absent" -sfn required"""
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    command,
                    "_",
                    str(SCRIPTS / "01-core/path-helpers.sh"),
                    str(root),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(1, result.returncode)
            self.assertIn("SUDO: unbound variable", result.stderr)

    def test_copied_required_companions(self):
        for layout in ("repo", "installed"):
            for module in ("gcc.sh", "vulkan.sh"):
                with (
                    self.subTest(layout=layout, module=module),
                    tempfile.TemporaryDirectory(prefix="ant-link-bundle-") as temporary,
                ):
                    path, core = plant_module_bundle(
                        Path(temporary), SCRIPTS, layout, module
                    )
                    complete = import_bundle(path, "direct")
                    self.assertEqual(0, complete.returncode, complete.stderr)
                    self.assertEqual("imported\n", complete.stdout)
                    for defect, context, failed in broken_bundle_imports(path, core):
                        self.assertEqual(
                            1,
                            failed.returncode,
                            (
                                layout,
                                module,
                                defect,
                                context,
                                failed.stdout,
                                failed.stderr,
                            ),
                        )
                        self.assertIn(
                            "requires path-helpers.sh"
                            if defect == "missing-file"
                            else "requires path_symlink_missing from path-helpers.sh",
                            failed.stderr,
                        )
                        self.assertNotIn("POISON", failed.stdout)
                        self.assertNotIn("imported", failed.stdout)

    def test_old_bootstrap_dispatcher(self):
        diagnostic = "ERROR: bootstrap.sh does not provide source_toolchain_required\n"
        for layout in ("repo", "installed"):
            for module in ("gcc.sh", "vulkan.sh"):
                with (
                    self.subTest(layout=layout, module=module),
                    tempfile.TemporaryDirectory(
                        prefix="ant-old-bootstrap-"
                    ) as temporary,
                ):
                    path, _ = plant_module_bundle(
                        Path(temporary), SCRIPTS, layout, module
                    )
                    (path.parent / "bootstrap.sh").write_text(
                        "source_toolchain_downloads() { :; }\n"
                    )
                    for context in ("conditional", "direct"):
                        failed = import_bundle(path, context)
                        self.assertEqual(
                            1, failed.returncode, (layout, module, context)
                        )
                        self.assertEqual(diagnostic, failed.stderr)
                        self.assertEqual("", failed.stdout)

    def test_fresh_docker_closures(self):
        docker = SCRIPTS.parent
        toolchain = (docker / "Dockerfile.toolchain").read_text()
        runs = toolchain.split("\nRUN ")
        gcc_runs = [
            run for run in runs if "source=linux/scripts/02-toolchain/gcc.sh," in run
        ]
        self.assertEqual(2, len(gcc_runs))
        for run in gcc_runs:
            self.assertIn(
                "source=linux/scripts/01-core/path-helpers.sh,target=/opt/scripts/core/path-helpers.sh,ro",
                run,
            )
            self.assertIn(
                "source=linux/scripts/02-toolchain/bootstrap-import.sh,target=/opt/scripts/toolchain/bootstrap-import.sh,ro",
                run,
            )
        sdk = (docker / "Dockerfile.sdk").read_text()
        self.assertIn("    linux/scripts/01-core/path-helpers.sh ", sdk)
        self.assertIn("    linux/scripts/02-toolchain/bootstrap-import.sh ", sdk)
        torch = (
            (docker / "Dockerfile.torch").read_text().split("FROM torch AS final", 1)[1]
        )
        bundle = next(
            line
            for line in torch.splitlines()
            if line.startswith("COPY ") and "vulkan.sh" in line
        )
        self.assertIn("linux/scripts/02-toolchain/bootstrap-import.sh", bundle)
        fresh = "COPY --chmod=755 linux/scripts/01-core/ /opt/scripts/core/"
        self.assertIn(fresh, torch)
        self.assertLess(torch.index(fresh), torch.index("\nRUN "))

    def test_independent_link_policies(self):
        actual = capture(SCRIPTS)
        self.assertIn("ln\n-sfn\n", actual["gcc:fresh:strict"]["trace"])
        self.assertIn("ln\n-s\n", actual["vulkan:fresh:strict"]["trace"])
        self.assertEqual(0, actual["gcc:dangling-dest:strict"]["status"])
        self.assertEqual(1, actual["vulkan:dangling-dest:strict"]["status"])
        self.assertEqual(41, actual["gcc:ln-failure:strict"]["status"])
        self.assertEqual(0, actual["gcc:ln-failure:conditional"]["status"])
        self.assertEqual(43, actual["vulkan:prefix-failure:strict"]["status"])
        self.assertEqual(0, actual["vulkan:unset-sudo:strict"]["status"])
        self.assertIn(
            "link:prefix/fixture-target/lib/file.so->WORK/usr/fixture-target/lib/file.so",
            actual["gcc:vanished-source:strict"]["files"],
        )
        self.assertNotIn("ln\n", actual["gcc:existing:strict"]["trace"])


if __name__ == "__main__":
    unittest.main()
