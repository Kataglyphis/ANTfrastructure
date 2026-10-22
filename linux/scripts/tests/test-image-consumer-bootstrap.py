#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Exercise the default plan's Flutter bootstraps against the actual lane/check drivers."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PLAN = json.loads((ROOT / "shared/config/image-consumers.json").read_text(encoding="utf-8"))


class BootstrapTests(unittest.TestCase):
    def test_cpp_acceptance_uses_the_unprivileged_gcc_lane(self):
        spec = next(row for row in PLAN["consumers"] if row["name"] == "AccelerANTgine")
        self.assertEqual(spec["command"][-2:], ["--compiler", "gcc"])

    def test_flutter_bootstraps_register_git_and_resolve_each_package(self):
        for name in ("ANThology", "OmniAccelerANT", "jotrockenmitlocken"):
            with self.subTest(consumer=name), tempfile.TemporaryDirectory(prefix="acceptance bootstrap ") as directory:
                self.check_flutter(name, Path(directory))

    def check_flutter(self, name, directory):
        work = directory / "checkout"
        tools = directory / "bin"
        work.mkdir()
        tools.mkdir()
        env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                   HOME=str(directory), GIT_CONFIG_GLOBAL=str(directory / "gitconfig"),
                   ANTFRASTRUCTURE_DIR=str(ROOT), BOOTSTRAP_ROOT=str(work),
                   BOOTSTRAP_LOG=str(directory / "calls"), FLUTTER_DIR=str(directory / "sdk"))
        env.pop("PUB_CACHE", None)
        flutter = """#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$PWD" "$*" >> "$BOOTSTRAP_LOG"
case "$*" in
  --version) printf 'Flutter fixture\n' ;;
  'pub get')
    test "$PUB_CACHE" = "$BOOTSTRAP_ROOT/.pub-cache"
    git config --global --get-all safe.directory | grep -qxF "$BOOTSTRAP_ROOT"
    test "$(git ls-files pubspec.yaml)" = pubspec.yaml
    mkdir -p .dart_tool "$PUB_CACHE"
    printf '{}\n' > .dart_tool/package_config.json
    ;;
  test) test -f .dart_tool/package_config.json ;;
  *) exit 1 ;;
esac
"""
        self.write(tools / "flutter", flutter, executable=True)
        self.write(tools / "dart", "#!/usr/bin/env bash\nexit 0\n", executable=True)
        sdk_bin = directory / "sdk/bin"
        sdk_bin.mkdir(parents=True)
        (sdk_bin / "flutter").symlink_to(tools / "flutter")
        (sdk_bin / "dart").symlink_to(tools / "dart")
        self.package(work)
        checks = 'bash "$ANTFRASTRUCTURE_DIR/linux/scripts/05-frameworks/flutter/flutter_checks.sh" --strict true'
        wrapper = f"#!/usr/bin/env bash\nset -euo pipefail\n{checks}\n"
        if name == "jotrockenmitlocken":
            self.package(work / "third_party/ANThology")
            wrapper = wrapper.replace(checks, checks + " --extra-package third_party/ANThology")
            self.write(work / "scripts/lib/antfrastructure.sh",
                       'antfrastructure_source() { source "$ANTFRASTRUCTURE_DIR/$1"; }\n')
        elif name == "OmniAccelerANT":
            self.package(work / "packages/kataglyphis_native_inference")
            helper = 'source "$ANTFRASTRUCTURE_DIR/linux/scripts/05-frameworks/flutter/lane-prologue.sh"\n'
            helper += 'run_flutter_common_checks() {\n test "$1" = 1\n'
            helper += checks + ' --extra-package packages/kataglyphis_native_inference\n'
            helper += ' (cd packages/kataglyphis_native_inference && flutter test)\n}\n'
            self.write(work / "scripts/linux/lib/container-steps.sh", helper)
        self.write(work / "scripts/run-dart-checks.sh", wrapper)
        subprocess.run(["git", "init", "-q", str(work)], check=True)
        subprocess.run(["git", "-C", str(work), "add", "-A"], check=True)
        spec = next(row for row in PLAN["consumers"] if row["name"] == name)
        subprocess.run(spec["command"], cwd=work, env=env, check=True, timeout=30,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertTrue((work / ".dart_tool/package_config.json").is_file())
        if name == "OmniAccelerANT":
            self.assertTrue((work / "packages/kataglyphis_native_inference/.dart_tool/package_config.json").is_file())
        elif name == "jotrockenmitlocken":
            self.assertTrue((work / "third_party/ANThology/.dart_tool/package_config.json").is_file())
        self.assertNotIn("--platform chrome", (directory / "calls").read_text())

    @staticmethod
    def write(path, content, *, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        if executable:
            path.chmod(0o755)

    def package(self, root):
        self.write(root / "pubspec.yaml", "name: acceptance_fixture\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\n")
        self.write(root / "lib/main.dart", "void main() {}\n")


if __name__ == "__main__":
    unittest.main()
