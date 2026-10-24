#!/usr/bin/env python3
"""Private profiles cover environment expansion and companion wiring, not GCC execution or installed profile permissions."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
SCRIPTS = Path(sys.argv.pop(1)).resolve()
VARIABLES = ("CPATH", "CPPFLAGS", "CFLAGS", "CXXFLAGS", "LIBRARY_PATH")
DRIVER = r"""set -euo pipefail
source "$TESTS/test-harness.sh"
if [ "$KIND" = torch ]; then
  compgen() { case "$*" in *include*) printf '%s\n' "$INCLUDE" ;; *) printf '%s\n' "$LIBRARY" ;; esac; }
  source "$WORK/torch.sh"
else
  eval "$(t_fn_src "$SCRIPTS/06-packaging/swap-native-gcc.sh" _write_native_gcc_profile_d | sed "s|/etc/profile.d|$WORK/profile|g")"
  _write_native_gcc_profile_d "$TRIPLET"
  if [ "$SEED" = late ]; then
    CPATH=late-include; CPPFLAGS=late-cpp; CFLAGS=late-c; CXXFLAGS=late-cxx; LIBRARY_PATH=late-lib
  fi
  sed "s|/opt/scripts/core/native-gcc-system-paths.sh|$SCRIPTS/01-core/native-gcc-system-paths.sh|g" "$WORK/profile/50-native-gcc-paths.sh" > "$WORK/profile.sh"
  source "$WORK/profile.sh"
  if [ "$SEED" = twice ]; then source "$WORK/profile.sh"; fi
fi
for name in CPATH CPPFLAGS CFLAGS CXXFLAGS LIBRARY_PATH _idaf _mi _ml; do printf '%s=%s\n' "$name" "${!name-<unset>}"; done
"""


def capture_case(scripts, kind, seed, directories):
    with tempfile.TemporaryDirectory(prefix="ant-native-env-") as temporary:
        work = Path(temporary)
        text = (scripts / "06-packaging/setup-torch-venv.sh").read_text()
        snippet = text[text.index('_mi="') : text.index("# Hard-require platform.sh")]
        snippet = snippet.replace(
            "/opt/scripts/core/native-gcc-system-paths.sh",
            str(scripts / "01-core/native-gcc-system-paths.sh"),
        )
        (work / "torch.sh").write_text(snippet)
        env = dict(
            os.environ,
            TESTS=str(TESTS),
            SCRIPTS=str(scripts),
            KIND=kind,
            SEED=seed,
            WORK=str(work),
            INCLUDE="/usr/include/fixture-linux-gnu"
            if directories in ("both", "include-only")
            else "",
            LIBRARY="/usr/lib/fixture-linux-gnu"
            if directories in ("both", "library-only")
            else "",
            TRIPLET="fixture-linux-gnu",
        )
        for name in VARIABLES:
            env.pop(name, None)
            if seed != "unset":
                env[name] = "" if seed == "empty" else f"prior {name}"
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
        }


def capture(scripts):
    receipts = {}
    for kind in ("torch", "profile"):
        for seed in ("unset", "empty", "preset", "late", "twice"):
            directories = (
                ("both",)
                if kind == "profile"
                else ("both", "none", "include-only", "library-only")
            )
            for paths in directories:
                receipts[f"{kind}:{seed}:{paths}"] = capture_case(
                    scripts, kind, seed, paths
                )
    return receipts


class NativeEnvironment(unittest.TestCase):
    def test_original_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("native-gcc-env-receipts.json").read_text()
        )
        actual = capture(SCRIPTS)
        for case, receipt in expected.items():
            with self.subTest(case=case):
                self.assertEqual(receipt, actual[case])

    def test_required_companion_and_posix_profile(self):
        with tempfile.TemporaryDirectory(prefix="ant-native-profile-") as temporary:
            work = Path(temporary)
            source = (SCRIPTS / "06-packaging/swap-native-gcc.sh").read_text()
            start = source.index(
                "  cat > /etc/profile.d/50-native-gcc-paths.sh <<EOF\n"
            )
            profile = source[start:].split("<<EOF\n", 1)[1].split("\nEOF", 1)[0]
            profile = profile.replace("${triplet}", "fixture-linux-gnu")
            leaf = work / "native-gcc-system-paths.sh"
            profile = profile.replace(
                "/opt/scripts/core/native-gcc-system-paths.sh", str(leaf)
            )
            path = work / "profile.sh"
            path.write_text(profile + "\n")
            for shell in ("bash", "sh"):
                failed = subprocess.run(
                    [
                        shell,
                        "-uc",
                        '. "$1"; status=$?; [ "$status" -eq 0 ] || exit "$status"; echo completed',
                        "_",
                        str(path),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=10,
                )
                self.assertEqual(1 if shell == "bash" else 2, failed.returncode)
                self.assertNotIn("completed", failed.stdout)
            leaf.write_bytes(
                (SCRIPTS / "01-core/native-gcc-system-paths.sh").read_bytes()
            )
            env = dict(os.environ, CXXFLAGS="consumer C++ flags")
            for shell in ("bash", "sh"):
                loaded = subprocess.run(
                    [shell, "-uc", '. "$1"; printf "%s" "$CXXFLAGS"', "_", str(path)],
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=10,
                )
                self.assertEqual(0, loaded.returncode)
                self.assertEqual(
                    "consumer C++ flags -idirafter /usr/include/fixture-linux-gnu -idirafter /usr/include",
                    loaded.stdout,
                )
            torch = (SCRIPTS / "06-packaging/setup-torch-venv.sh").read_text()
            snippet = torch[
                torch.index('_mi="') : torch.index("# Hard-require platform.sh")
            ]
            snippet = snippet.replace(
                "/opt/scripts/core/native-gcc-system-paths.sh", str(work / "missing.sh")
            )
            failed = subprocess.run(
                ["bash", "-euc", snippet],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(1, failed.returncode)
            self.assertIn("missing.sh", failed.stderr)

    def test_docker_closures(self):
        line = "COPY --chmod=755 linux/scripts/01-core/native-gcc-system-paths.sh /opt/scripts/core/native-gcc-system-paths.sh"
        for stage, executable in (
            ("android", "swap-native-gcc.sh"),
            ("torch", "setup-torch-venv.sh"),
        ):
            text = (SCRIPTS.parent / f"Dockerfile.{stage}").read_text()
            self.assertEqual(1, text.count(line))
            self.assertLess(
                text.index(line),
                text.index(f"bash /opt/scripts/packaging/{executable}"),
            )
        package = (SCRIPTS.parent / "Dockerfile.package").read_text()
        self.assertIn("COPY linux/scripts/01-core/ /opt/scripts/core/", package)

    def test_explicit_system_paths(self):
        actual = capture(SCRIPTS)
        line = actual["torch:preset:both"]["stdout"]
        self.assertIn(
            "CPATH=prior CPATH:/usr/include/fixture-linux-gnu:/usr/include\n", line
        )
        self.assertIn(
            "LIBRARY_PATH=prior LIBRARY_PATH:/usr/lib/fixture-linux-gnu:/usr/lib\n",
            line,
        )
        for name in ("CPPFLAGS", "CFLAGS", "CXXFLAGS"):
            self.assertIn(
                f"{name}=prior {name} -idirafter /usr/include/fixture-linux-gnu -idirafter /usr/include\n",
                line,
            )
        self.assertIn(
            "CXXFLAGS=late-cxx -idirafter /usr/include/fixture-linux-gnu -idirafter /usr/include\n",
            actual["profile:late:both"]["stdout"],
        )


if __name__ == "__main__":
    unittest.main()
