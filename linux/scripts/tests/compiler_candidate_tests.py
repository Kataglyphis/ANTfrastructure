"""Mocked compiler queries preserve candidate publication and fallback policy, not actual compiler availability or ABI."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from functools import lru_cache
from itertools import product
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SUBJECT = Path(sys.argv.pop(1)).resolve()


@lru_cache
def extract(file, name):
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1/linux/scripts/tests/test-harness.sh"; t_fn_src "$2" "$3"',
            "_",
            str(ROOT),
            str(file),
            name,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def functions():
    source = ""
    if "_resolve_build_gcc_candidates() {" in SUBJECT.read_text():
        source = extract(SUBJECT, "_resolve_build_gcc_candidates")
    return source + extract(SUBJECT, "resolve_host_compiler_for_lang")


DRIVER = r"""set -uo pipefail
shopt -s expand_aliases
record() { builtin printf '%s\n' "$@" >> "$TRACE"; }
lookup() {
 record lookup "$@"
 case "$1:$2" in
  -v:resolve_build_gcc_tool) return "$HAVE_RESOLVER" ;;
  -v:build_deb_multiarch_triplet) return "$HAVE_TRIPLET" ;;
  -v:gcc|-v:g++) builtin printf '%s' /path/primary; return "$PATH_PRIMARY_STATUS" ;;
  -v:cc|-v:c++) builtin printf '%s' /path/alternate; return 0 ;;
  *) builtin command "$@" ;;
 esac
}
bound_test() {
 record test "$@"
 case "$1" in
  -x) builtin [ "$2" = "$FILE_CHOICE" ] ;;
  -n) if builtin [ "$NONEMPTY_STATUS" != auto ]; then return "$NONEMPTY_STATUS"; fi; builtin [ "$@" ;;
  *) builtin [ "$@" ;;
 esac
}
bound_printf() {
 record printf "$@"
 builtin printf "$@"
 if builtin [ "$1" = '%s' ]; then return "$PRINT_STATUS"; fi
}
producer() {
 record producer "$@" "scope:${resolved-unset}:${compiler-unset}:${alternate-unset}"
 builtin printf 'hidden producer\n' >&2
 case "$2" in gcc|g++) builtin printf '%s' "$PRIMARY"; return "$PRIMARY_STATUS" ;; *) builtin printf '%s' "$ALTERNATE"; return "$ALTERNATE_STATUS" ;; esac
}
resolve_early() { producer early "$@"; }
resolve_late() { producer late "$@"; }
wrong_binding() { builtin printf WRONG_BINDING; return 17; }
build_deb_multiarch_triplet() { record triplet; builtin printf '%s' triplet-value; return "$TRIPLET_STATUS"; }
alias command=lookup
alias [=bound_test
alias printf=bound_printf
alias resolve_build_gcc_tool=resolve_early
source "$FUNCTIONS"
"""


def run(
    lang,
    primary,
    alternate,
    context,
    strict,
    print_status=0,
    primary_status=0,
    alternate_status=0,
    have_resolver=0,
    have_triplet=0,
    triplet_status=0,
    file_choice="/none",
    path_status=127,
    late_alias=True,
    late_bindings=False,
    preserve_globals=False,
    nonempty_status="auto",
):
    with tempfile.TemporaryDirectory(prefix="ant-compiler-resolver-") as directory:
        work = Path(directory)
        (work / "functions").write_text(functions())
        env = dict(
            os.environ,
            FUNCTIONS=str(work / "functions"),
            TRACE=str(work / "trace"),
            PRIMARY=primary,
            ALTERNATE=alternate,
            PRINT_STATUS=str(print_status),
            PRIMARY_STATUS=str(primary_status),
            ALTERNATE_STATUS=str(alternate_status),
            NONEMPTY_STATUS=str(nonempty_status),
            HAVE_RESOLVER=str(have_resolver),
            HAVE_TRIPLET=str(have_triplet),
            TRIPLET_STATUS=str(triplet_status),
            FILE_CHOICE=file_choice,
            PATH_PRIMARY_STATUS=str(path_status),
        )
        code = DRIVER + (
            "alias resolve_build_gcc_tool=resolve_late\n" if late_alias else ""
        )
        if late_bindings:
            code += "alias command=wrong_binding\nalias [=wrong_binding\nalias printf=wrong_binding\n"
        if preserve_globals:
            code += "resolved=caller-resolved compiler=caller-compiler alternate=caller-alternate\n"
        code += "set -e\n" if strict else "set +e\n"
        code += (
            'if resolve_host_compiler_for_lang "$1"; then builtin printf ":STATUS:0"; else builtin printf ":STATUS:%s" "$?"; fi'
            if context == "conditional"
            else 'resolve_host_compiler_for_lang "$1"'
        )
        if preserve_globals:
            code += '\nbuiltin printf "GLOBAL:%s:%s:%s\\n" "$resolved" "$compiler" "$alternate"\n'
        p = subprocess.run(
            ["bash", "-c", code, "_", lang],
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        return {
            "rc": p.returncode,
            "out": p.stdout,
            "err": p.stderr,
            "trace": (work / "trace").read_text() if (work / "trace").exists() else "",
        }


PROFILES = [
    ("primary", "/primary", "/alternate", 0, 0),
    ("alternate", "", "/alternate", 0, 0),
    ("empty", "", "", 0, 0),
    ("primary-partial", "/partial\n", "/unused", 23, 0),
    ("alternate-partial", "", "/partial-alt\n", 0, 37),
    ("whitespace", " \n", "/unused", 0, 0),
    ("newline", "\n\n", "/alternate", 0, 0),
    ("embedded", "path\nsecond\n", "/unused", 0, 0),
]
FALLBACKS = [
    (1, 1, 0, "/none", 127),
    (0, 0, 31, "/none", 127),
    (0, 0, 0, "/usr/bin/triplet-value-gcc", 127),
    (0, 0, 0, "/usr/bin/clang", 127),
    (0, 0, 0, "/usr/bin/gcc", 127),
    (0, 0, 0, "/usr/bin/cc", 127),
    (0, 0, 0, "/none", 0),
    (0, 0, 0, "/none", 23),
]


def capture():
    results = {}
    for lang, profile, context, strict, fault in product(
        ["c", "cxx", "rust"],
        PROFILES,
        ["direct", "conditional"],
        [False, True],
        [0, 41],
    ):
        label, p, a, ps, als = profile
        results[str((lang, label, context, strict, fault))] = run(
            lang, p, a, context, strict, fault, ps, als
        )
    for fallback, context, strict in product(
        FALLBACKS, ["direct", "conditional"], [False, True]
    ):
        have_resolver, have_triplet, tr_status, choice, path_status = fallback
        key = str(
            (
                "fallback",
                have_resolver,
                have_triplet,
                tr_status,
                choice,
                path_status,
                context,
                strict,
            )
        )
        results[key] = run(
            "c",
            "",
            "",
            context,
            strict,
            have_resolver=have_resolver,
            have_triplet=have_triplet,
            triplet_status=tr_status,
            file_choice=choice,
            path_status=path_status,
        )
    return results


class CompilerCandidatePublication(unittest.TestCase):
    def test_original_whole_resolver_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("compiler-candidate-receipts.json").read_text()
        )
        self.assertEqual(224, len(expected))
        self.assertEqual(expected, capture())

    def test_independent_candidate_and_publication_policy(self):
        first = run("c", "/first\n", "/unused", "direct", True, primary_status=23)
        self.assertEqual(0, first["rc"])
        self.assertEqual("/first", first["out"])
        self.assertEqual(1, first["trace"].count("producer\n"))
        alternate = run("cxx", "", "/alternate\n", "direct", True, alternate_status=37)
        self.assertEqual("/alternate", alternate["out"])
        self.assertIn("late\ng++\n", alternate["trace"])
        self.assertIn("late\nc++\n", alternate["trace"])
        fault = run("c", "/printed", "unused", "direct", True, print_status=41)
        self.assertEqual(41, fault["rc"])
        self.assertEqual("/printed", fault["out"])
        conditional = run(
            "c", "/printed", "unused", "conditional", True, print_status=41
        )
        self.assertEqual(0, conditional["rc"])
        self.assertEqual("/printed:STATUS:0", conditional["out"])

    def test_binding_and_caller_locals(self):
        for lang in ["c", "cxx"]:
            ordinary = run(
                lang, "", "/alternate", "conditional", True, preserve_globals=True
            )
            late = run(
                lang,
                "",
                "/alternate",
                "conditional",
                True,
                preserve_globals=True,
                late_bindings=True,
            )
            self.assertEqual(ordinary, late)
            self.assertIn(
                "GLOBAL:caller-resolved:caller-compiler:caller-alternate\n", late["out"]
            )
            self.assertNotIn("WRONG_BINDING", late["out"])
            self.assertEqual(2, late["trace"].count("producer\n"))
            self.assertIn("scope::", late["trace"])
        forced = run("c", "/first", "/second", "conditional", True, nonempty_status=17)
        self.assertIn("scope:/first:gcc:cc", forced["trace"])
        self.assertEqual(2, forced["trace"].count("producer\n"))


if __name__ == "__main__":
    unittest.main()
