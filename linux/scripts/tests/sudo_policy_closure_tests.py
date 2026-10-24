"""Check fresh recipe bindings and copied fallback APIs, not image execution or real sudo."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "linux/scripts"
sys.path.insert(0, str(SCRIPTS))
from verify_dockerfile_env_order import instructions


def runs(name, source):
    return [
        text
        for _, text in instructions(ROOT / "linux" / name)
        if text.startswith("RUN ") and "source=" + source + "," in text
    ]


WORKER = r'''
set -euo pipefail
PATH=/nonexistent-ant-sudo-fixture-bin
export PATH
GUARD_LOG="$2"
command_not_found_handle() { printf 'FORBIDDEN:%s\n' "$*" >> "$GUARD_LOG"; exit 97; }
check_guard() {
 local _spc_status="$1" _spc_line
 while IFS= read -r _spc_line; do
  case "$_spc_line" in FORBIDDEN:*) exit 97;; esac
 done < "$GUARD_LOG"
 exit "$_spc_status"
}
trap 'check_guard "$?"' EXIT
dirname() {
 local _spc_dir="${1%/*}"
 [ "$_spc_dir" != "$1" ] || _spc_dir=.
 printf '%s\n' "${_spc_dir:-/}"
}
LLVM_WANTED=1 CLANG_WANTED=1 GCC_WANTED=1 PYTHON_MAJOR_MINOR=3.14
source "$1/common.sh"
unset -f _ensure_sudo_wrapper
sudo() { :; }
SUDO_WRAP=seed-wrap
if require_sudo; then
 printf 'READY:<%s>:<%s>\n' "$SUDO" "$SUDO_WRAP"
else
 exit "$?"
fi
'''


class SudoPolicyClosureTests(unittest.TestCase):
    def test_base_readonly_bindings(self):
        selected = runs("Dockerfile.base", "linux/scripts/01-core/common.sh")
        self.assertEqual(6, len(selected))
        for recipe in selected:
            self.assertIn(
                "source=linux/scripts/01-core/sudo-policy.sh,target=/tmp/scripts/01-core/sudo-policy.sh,ro ",
                recipe,
            )

    def test_toolchain_readonly_bindings(self):
        selected = runs("Dockerfile.toolchain", "linux/scripts/01-core/common.sh")
        self.assertEqual(2, len(selected))
        for recipe in selected:
            self.assertIn(
                "source=linux/scripts/01-core/sudo-policy.sh,target=/opt/scripts/core/sudo-policy.sh,ro ",
                recipe,
            )

    def test_sdk_copies_the_current_companion(self):
        selected = [
            text
            for _, text in instructions(ROOT / "linux/Dockerfile.sdk")
            if text.startswith("COPY ")
            and "linux/scripts/01-core/common.sh" in text.split()
        ]
        self.assertEqual(1, len(selected))
        self.assertIn("linux/scripts/01-core/sudo-policy.sh", selected[0].split())
        self.assertEqual("/opt/scripts/core/", selected[0].split()[-1])

    def test_whole_core_copies_keep_the_existing_route(self):
        for name in ["Dockerfile.package", "Dockerfile.torch", "Dockerfile.toolchain"]:
            with self.subTest(dockerfile=name):
                self.assertTrue(
                    any(
                        text.startswith("COPY ")
                        and "linux/scripts/01-core/" in text.split()
                        and text.split()[-1] == "/opt/scripts/core/"
                        for _, text in instructions(ROOT / "linux" / name)
                    )
                )

    def test_copied_common_uses_the_companion_and_refuses_its_absence(self):
        for missing in [False, True]:
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as folder:
                work = Path(folder)
                for name in [
                    "common.sh", "compiler-cache-utils.sh", "load-versions-env.sh",
                    "versions.env", "platform.sh", "cross-active-fallback.sh",
                    "sudo-policy.sh",
                ]:
                    shutil.copyfile(SCRIPTS / "01-core" / name, work / name)
                if missing:
                    (work / "sudo-policy.sh").unlink()
                guard = work / "guard.log"
                guard.write_text("")
                env = {key: value for key, value in os.environ.items() if not key.startswith(("_", "BASH_FUNC_"))}
                for key in ("BASH_ENV", "BASHOPTS", "SHELLOPTS"):
                    env.pop(key, None)
                result = subprocess.run(
                    ["/bin/bash", "-c", WORKER, "_", str(work), str(guard)],
                    env=env, capture_output=True, text=True, timeout=5, check=False,
                )
                self.assertEqual("", guard.read_text())
                if missing:
                    self.assertEqual(1, result.returncode)
                    self.assertEqual("", result.stdout)
                    self.assertIn("sudo-policy.sh", result.stderr)
                else:
                    prefix = "" if os.geteuid() == 0 else "sudo"
                    self.assertEqual(
                        (0, f"READY:<{prefix}>:<{prefix}>\n", ""),
                        (result.returncode, result.stdout, result.stderr),
                    )


if __name__ == "__main__":
    unittest.main()
