"""Check query transport using independent literal verdicts and argument receipts."""
import itertools
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def extract(text, name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", text, re.MULTILINE | re.DOTALL)
    if match is None:
        raise AssertionError(f"missing function: {name}")
    return match.group() + "\n"


WORKER = r'''
set -uo pipefail
[ "$STRICT" = 0 ] || set -e
shopt -s expand_aliases
fixture_find() {
 printf 'quiet producer diagnostic\n' >&2
 printf 'FIND:%s:' "$PHASE" >> "$WORK/trace"
 printf '<%s>' "$@" >> "$WORK/trace"
 printf '\n' >> "$WORK/trace"
 case "$*" in
  *'*.wasm'*) printf '%s/fixture.wasm\n' "$WORK"; return 0 ;;
 esac
 [ "$OUTPUT" = 0 ] || printf '/fixture/present library\n'
 return "$FIND_RC"
}
fixture_grep() {
 local bytes
 bytes="$(cat)"
 printf 'GREP:%s:<%s>:<%s>\n' "$PHASE" "$*" "$bytes" >> "$WORK/trace"
 [ "$GREP_RC" = 0 ] || { printf 'consumer failed\n' >&2; return "$GREP_RC"; }
 [ -n "$bytes" ]
}
early_find() { PHASE=early fixture_find "$@"; }
late_find() { PHASE=late fixture_find "$@"; }
early_grep() { PHASE=early fixture_grep "$@"; }
late_grep() { PHASE=late fixture_grep "$@"; }
alias find=early_find
alias grep=early_grep
source "$WORK/python.sh"
if [ "$ALIASES" = late ]; then
 alias find=late_find
 alias grep=late_grep
fi
source "$WORK/web.sh"
cross_build_is_active() { [ "$MODE" = cross ]; }
command() {
 if [ "$*" = '-v python3' ] && [ "$MODE" = missing_python ]; then return 1; fi
 builtin command "$@"
}
python3() { [ "$MODE" = native_import ]; }
imported() { printf 'IMPORTED\n'; }
presence() { printf 'PRESENCE'; printf '<%s>' "$@"; printf '\n'; }
pass() { printf 'PASS:<%s>\n' "$*"; }
run() {
 _smoke_media_python_library fixture 'libfixture.so*' imported presence '/fixture/path with spaces'
 _check_web_runtime Fixture "$WORK" 1
}
if [ "$CONTEXT" = conditional ]; then
 if run; then printf 'STATUS:0\n'; else printf 'STATUS:%s\n' "$?"; fi
else
 run
 printf 'STATUS:%s\n' "$?"
fi
'''


def expected_output(mode, present, work):
    prefix = ""
    if mode == "native_import":
        prefix = "IMPORTED\n"
    elif mode != "missing_python":
        verdict = "present" if present else "missing"
        build = "cross" if mode == "cross" else "native"
        prefix = f"PRESENCE<{build}><{verdict}></fixture/path with spaces>\n"
    if not present:
        prefix += "  INFO: Fixture has .wasm but no JS loader alongside\n"
    return prefix + f"PASS:<Fixture web runtime valid (1 verified .wasm in {work})>\nSTATUS:0\n"


def check_case(work, case):
    strict, context, aliases, output, producer_rc, consumer_rc, mode = case
    env = dict(os.environ, WORK=str(work), STRICT=str(strict), CONTEXT=context,
               ALIASES=aliases, OUTPUT=str(output), FIND_RC=str(producer_rc),
               GREP_RC=str(consumer_rc), MODE=mode)
    (work / "trace").write_text("")
    result = subprocess.run(["bash", "-c", WORKER], env=env, capture_output=True,
                            text=True, timeout=10, check=False)
    present = output == 1 and producer_rc == consumer_rc == 0
    assert result.returncode == 0, (case, result)
    assert result.stdout == expected_output(mode, present, work), (case, result)
    queries = 2 if mode in {"cross", "native_fallback"} else 1
    assert result.stderr == "consumer failed\n" * (queries if consumer_rc else 0), (case, result)
    trace = (work / "trace").read_text()
    web_phase = "late" if aliases == "late" else "early"
    assert f"FIND:{web_phase}:<{work}><(><-name><*.js><-o><-name><*.mjs><)><-print><-quit>\n" in trace, (case, trace)
    assert f"GREP:{web_phase}:<-q .>:" in trace, (case, trace)
    if queries == 2:
        assert "FIND:early:</fixture/path with spaces><-name><libfixture.so*><-type><f>\n" in trace, (case, trace)
        assert "GREP:early:<-q .>:" in trace, (case, trace)


def check_dynamic_scope(work):
    code = r'''
set -euo pipefail
source "$1/python.sh"
producer=outer-producer consumer=outer-consumer
cross_build_is_active() { return 0; }
find() { printf '%s/%s\n' "$producer" "$consumer"; }
grep() { printf 'QUERY:%s:' "$*"; cat; }
presence() { printf 'PRESENCE:%s\n' "$2"; }
_smoke_media_python_library fixture pattern ignored presence /fixture
caller() {
 local producer=caller-producer consumer=caller-consumer
 _smoke_media_python_library fixture pattern ignored presence /fixture
}
caller
printf 'GLOBALS:%s/%s\n' "$producer" "$consumer"
'''
    result = subprocess.run(["bash", "-c", code, "_", str(work)], capture_output=True,
                            text=True, timeout=10, check=False)
    expected = ("QUERY:-q .:outer-producer/outer-consumer\nPRESENCE:present\n"
                "QUERY:-q .:caller-producer/caller-consumer\nPRESENCE:present\n"
                "GLOBALS:outer-producer/outer-consumer\n")
    assert (result.returncode, result.stdout, result.stderr) == (0, expected, ""), result


PREFIX_WORKER = r'''
set -uo pipefail
[ "$STRICT" = 0 ] || set -e
shopt -s expand_aliases
provided_find() {
 printf 'FIND:' >> "$WORK/find-prefix"
 printf '<%s>' "$@" >> "$WORK/find-prefix"
 printf '\n' >> "$WORK/find-prefix"
 printf '%s/fixture.wasm\n' "$WORK"
}
provided_grep() {
 local bytes
 bytes="$(cat)"
 printf 'GREP:' >> "$WORK/grep-prefix"
 printf '<%s>' "$@" >> "$WORK/grep-prefix"
 printf 'STDIN:<%s>\n' "$bytes" >> "$WORK/grep-prefix"
 [ "$#" = "${#expected[@]}" ] || return 23
 local index
 local -a actual=("$@")
 for index in "${!expected[@]}"; do
  [ "${expected[index]}" = "${actual[index]}" ] || return 23
 done
 [ "$bytes" = "$WORK/fixture.wasm" ]
}
alias find='provided_find "$@"'
alias grep='provided_grep "$@"'
source "$WORK/python.sh"
if [ "$ALIASES" = late ]; then
 alias find='provided_find late "$@"'
 alias grep='provided_grep late "$@"'
fi
source "$WORK/web.sh"
cross_build_is_active() { return 0; }
presence() { printf 'VERDICT:%s\n' "$2"; }
pass() { printf 'VALID\n'; }
run_prefix() {
 if [ "$SUBJECT" = python ]; then
  expected=('/original path' '' -q .)
  _smoke_media_python_library fixture '*.so' ignored presence '/original path' ''
 else
  expected=(Fixture "$WORK" 1 -q .)
  [ "$ALIASES" = early ] || expected=(late "${expected[@]}")
  _check_web_runtime Fixture "$WORK" 1
 fi
}
if [ "$CONTEXT" = conditional ]; then
 if run_prefix; then printf 'STATUS:0\n'; else printf 'STATUS:%s\n' "$?"; fi
else
 run_prefix
 printf 'STATUS:%s\n' "$?"
fi
'''


def check_prefix_case(work, case):
    strict, context, aliases, subject = case
    for leaf in ("find-prefix", "grep-prefix"):
        (work / leaf).write_text("")
    env = dict(os.environ, WORK=str(work), STRICT=str(strict), CONTEXT=context,
               ALIASES=aliases, SUBJECT=subject)
    result = subprocess.run(["bash", "-c", PREFIX_WORKER], env=env,
                            capture_output=True, text=True, timeout=10, check=False)
    verdict = "VERDICT:present\n" if subject == "python" else "VALID\n"
    assert (result.returncode, result.stdout, result.stderr) == (0, verdict + "STATUS:0\n", ""), (case, result)
    prefix = "</original path><>" if subject == "python" else f"<Fixture><{work}><1>"
    if subject == "web" and aliases == "late":
        prefix = "<late>" + prefix
    expected_grep = f"GREP:{prefix}<-q><.>STDIN:<{work}/fixture.wasm>\n"
    assert (work / "grep-prefix").read_text() == expected_grep, case
    find = (work / "find-prefix").read_text()
    expected_find = (f"FIND:{prefix}</original path><><-name><*.so><-type><f>\n"
                     if subject == "python" else
                     f"FIND:{prefix}<{work}><(><-name><*.js><-o><-name><*.mjs><)><-print><-quit>\n")
    assert expected_find in find, (case, find)


def check_prefix_aliases(work):
    cases = itertools.product((0, 1), ("direct", "conditional"),
                              ("early", "late"), ("python", "web"))
    for case in cases:
        check_prefix_case(work, case)


def main():
    text = Path(sys.argv[1]).read_text()
    with tempfile.TemporaryDirectory(prefix="smoke-query-") as directory:
        work = Path(directory)
        (work / "fixture.wasm").write_bytes(b"\x00asm")
        python_names = ("_smoke_query_matches", "_smoke_python_files", "_smoke_python_match", "_smoke_media_python_library")
        web_names = ("_smoke_web_loaders", "_smoke_web_match", "_check_web_runtime")
        (work / "python.sh").write_text("".join(extract(text, name) for name in python_names))
        (work / "web.sh").write_text("".join(extract(text, name) for name in web_names))
        cases = itertools.product((0, 1), ("direct", "conditional"), ("early", "late"),
                                  (0, 1), (0, 7, 141), (0, 1, 2),
                                  ("cross", "native_import", "native_fallback", "missing_python"))
        count = 0
        for case in cases:
            check_case(work, case)
            count += 1
        check_dynamic_scope(work)
        check_prefix_aliases(work)
        print(f"{count} smoke query cases,16 prefix-alias controls and dynamic-scope contract passed")


if __name__ == "__main__":
    main()
