#!/usr/bin/env bash
# The app self-test both bundle scripts trust; see docs/python-app-bundles.md#the-consumers-side-packagingappjson
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SELFTEST="${TESTS_DIR}/../06-packaging/python-app-selftest.py"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
# Paths the interpreter can open: Git Bash's python3 is a Windows program that cannot read /tmp/...
_n() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
W="$(_n "${_work}")"
printf 'import sys\nsys.stdout.write(open(sys.argv[1], encoding="utf-8").read())\nsys.exit(int(sys.argv[2]))\n' > "${_work}/app.py"
# _run [--root R] <case> <exit code>: the checker over a fake launcher printing <case>.out and exiting with that code.
_run() {
  local root=()
  if [ "$1" = --root ]; then root=(--root "$2"); shift 2; fi
  python3 "${SELFTEST}" "${root[@]}" -- python3 "${W}/app.py" "${W}/$1.out" "$2"
}
_report() { printf '{\n  "ok": %s,\n  "onnxruntime_module": "%s"\n}\n' "$1" "$2"; }

_report true "${W}/runtime/onnxruntime/__init__.py" > "${_work}/good.out"
{ echo 'EP Error {dml} fell back to CPU'; cat "${_work}/good.out"; } > "${_work}/notice.out"
_report false "" > "${_work}/notok.out"
echo 'started, but said nothing structured' > "${_work}/nojson.out"
_report true "/usr/lib/python3/dist-packages/onnxruntime/__init__.py" > "${_work}/foreign.out"

t_case "an ok report passes and comes back on stdout, as bundle.json records it"
t_assert_contains "$(_run --root "${W}" good 0 2>/dev/null)" '"ok": true'

t_case "a notice with braces before the report (ORT's DirectML fallback) is not mistaken for it"
t_assert_ok _run --root "${W}" notice 0

t_case "not ok, no JSON and a failing exit are each refused, and the reason is named"
t_assert_contains "$(t_out _run notok 0)" "did not report ok"
t_assert_contains "$(t_out _run nojson 0)" "printed no JSON report"
t_assert_contains "$(t_out _run good 3)" "exited 3"

t_case "an ONNX Runtime loaded from outside --root fails: a package must not run on the host's copy"
t_assert_contains "$(t_out _run --root "${W}" foreign 0)" "outside ${W}"
t_assert_ok _run foreign 0

t_summary
