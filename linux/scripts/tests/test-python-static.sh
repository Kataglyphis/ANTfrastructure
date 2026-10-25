#!/usr/bin/env bash
# Stub scanners prove scope and verdict handling; this suite does not verify Ruff's or ty's analysis rules.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/git-fixture-env.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
WORK="$(mktemp -d)" || exit 1
HUB="$(t_gate_tree python-static.sh 01-core/load-versions-env.sh 01-core/lint-root.sh)" || exit 1
trap 'rm -rf -- "$WORK" "$HUB"' EXIT
TARGET="$WORK/caller"
STUBS="$WORK/stubs"
CALLS="$WORK/calls"

new_fixture() {
  mkdir -p "$HUB/quality" "$TARGET/src" "$TARGET/other" "$STUBS" || return 1
  sed -n '/^RUFF_VERSION=/p; /^TY_VERSION=/p' "$SCRIPTS_DIR/01-core/tool-pins.env" \
    > "$HUB/linux/scripts/01-core/tool-pins.env" || return 1
  printf '[project]\nname="fixture"\nversion="0.0.0"\n' > "$HUB/quality/pyproject.toml"
  printf 'version = 1\n' > "$HUB/quality/uv.lock"
  printf 'logs/\n' > "$TARGET/.gitignore"
  printf 'value = 1\n' > "$TARGET/src/one.py"
  printf 'value = 2\n' > "$TARGET/src/two.py"
  printf 'value = 3\n' > "$TARGET/other/three.py"
  git -C "$TARGET" init -q || return 1
  t_git_commit "$TARGET" || return 1
  cat > "$STUBS/uv" <<'UV'
#!/usr/bin/env bash
printf 'uv %s\n' "$*" >> "$STUB_CALLS"
if [[ "${STUB_SETUP_FAIL:-}" == 1 ]]; then echo 'sync failed' >&2; exit 7; fi
[[ "$1" == sync && "$2" == --project && "$4" == --locked && "$5" == --python && "$6" == 3.14 ]] || exit 8
mkdir -p "$UV_PROJECT_ENVIRONMENT/bin" || exit 9
cp "$STUB_SCRIPTS/ruff" "$STUB_SCRIPTS/ty" "$UV_PROJECT_ENVIRONMENT/bin/" || exit 10
chmod +x "$UV_PROJECT_ENVIRONMENT/bin/ruff" "$UV_PROJECT_ENVIRONMENT/bin/ty"
UV
  cat > "$STUBS/ruff" <<'RUFF'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then printf 'ruff %s\n' "${STUB_RUFF_VERSION:-0.17.0}"; exit 0; fi
printf 'ruff %s\n' "$*" >> "$STUB_CALLS"
case "${STUB_RUFF_MODE:-clean}" in
  clean) echo 'All checks passed!'; exit 0 ;;
  finding) printf 'src/one.py:1:1: F401 finding\nFound 1 error.\n'; [[ " $* " == *' --exit-zero '* ]] && exit 0; exit 1 ;;
  error) echo 'Ruff configuration failed' >&2; exit 2 ;;
esac
RUFF
  cat > "$STUBS/ty" <<'TY'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then printf 'ty 0.0.91 (build)\n'; exit 0; fi
printf 'ty %s\n' "$*" >> "$STUB_CALLS"
case "${STUB_TY_MODE:-clean}" in
  clean) echo 'All checks passed!'; exit 0 ;;
  finding) printf 'src/one.py:1:1: invalid-assignment finding\nFound 1 diagnostic\n'; [[ " $* " == *' --exit-zero '* ]] && exit 0; exit 1 ;;
  error) echo 'ty configuration failed' >&2; exit 2 ;;
esac
TY
  chmod +x "$STUBS/uv" "$STUBS/ruff" "$STUBS/ty" || return 1
}

run_static() {
  : > "$CALLS"
  t_capture_command OUT STATUS env PATH="$STUBS:$PATH" STUB_CALLS="$CALLS" STUB_SCRIPTS="$STUBS" \
    STUB_RUFF_MODE="${STUB_RUFF_MODE:-clean}" STUB_TY_MODE="${STUB_TY_MODE:-clean}" \
    STUB_SETUP_FAIL="${STUB_SETUP_FAIL:-}" STUB_RUFF_VERSION="${STUB_RUFF_VERSION:-0.17.0}" \
    bash "$HUB/linux/scripts/python-static.sh" --root "$TARGET" "$@"
}

assert_scanner_result() {
  local scanner="$1" count="$2" status="$3" evidence="$4" label
  label=findings
  [[ "$scanner" == ty ]] && label=diagnostics
  t_assert_contains "$OUT" "$scanner-$label=$count $scanner-exit=$status"
  t_assert_contains "$(cat "$TARGET/logs/code-quality/python-static/$scanner.txt")" "$evidence"
}

new_fixture || exit 1

t_case "report-only keeps Ruff and ty findings visible while passing"
STUB_RUFF_MODE=finding STUB_TY_MODE=finding run_static --path src --report-only
t_assert_eq 0 "$STATUS"
t_assert_contains "$OUT" 'mode=report-only path=src files=2'
assert_scanner_result ruff 1 0 'F401 finding'
assert_scanner_result ty 1 0 'invalid-assignment finding'
t_assert_contains "$(cat "$CALLS")" 'uv sync --project'
t_assert_contains "$(cat "$CALLS")" '--locked --python 3.14'
t_assert_contains "$(cat "$CALLS")" '--exit-zero -- src/one.py src/two.py'
t_assert_eq 0 "$(grep -c 'other/three.py' "$CALLS")"
t_assert_ok git -C "$TARGET" check-ignore -q --no-index -- logs/code-quality/python-static/ruff.txt

t_case "strict mode fails on findings after recording both reports"
STUB_RUFF_MODE=finding STUB_TY_MODE=finding run_static --path src/one.py --strict
t_assert_eq 2 "$STATUS"
t_assert_contains "$OUT" 'mode=strict path=src/one.py files=1'
assert_scanner_result ruff 1 1 'F401 finding'
assert_scanner_result ty 1 1 'invalid-assignment finding'
t_assert_eq 0 "$(grep -c -- '--exit-zero' "$CALLS")"
t_assert_contains "$(cat "$CALLS")" 'src/one.py'
t_assert_eq 0 "$(grep -c 'src/two.py' "$CALLS")"

t_case "scanner failure remains fatal in report-only mode"
STUB_RUFF_MODE=error STUB_TY_MODE=finding run_static --path src --report-only
t_assert_eq 2 "$STATUS"
assert_scanner_result ruff unknown 2 'configuration failed'
assert_scanner_result ty 1 0 'invalid-assignment finding'

t_case "locked setup failure prevents both scanners"
STUB_SETUP_FAIL=1 run_static --path src
t_assert_eq 2 "$STATUS"
t_assert_contains "$OUT" 'locked quality setup failed'
t_assert_eq 0 "$(grep -c '^ruff\|^ty' "$CALLS")"

t_case "version mismatch fails before scanning"
STUB_RUFF_VERSION=0.0.0 run_static --path src
t_assert_eq 2 "$STATUS"
t_assert_contains "$OUT" 'Ruff version differs from tool-pins.env'
t_assert_eq 0 "$(grep -c '^ruff\|^ty' "$CALLS")"

t_case "invalid scope and untracked Python fail before setup"
printf 'value = 4\n' > "$TARGET/src/untracked.py"
run_static --path ../outside
t_assert_eq 2 "$STATUS"
t_assert_contains "$OUT" 'canonical caller-relative path'
t_assert_eq 0 "$(wc -c < "$CALLS")"
run_static --path src/untracked.py
t_assert_eq 2 "$STATUS"
t_assert_contains "$OUT" 'no tracked Python files'
t_assert_eq 0 "$(wc -c < "$CALLS")"

t_case "an unignored report directory is rejected"
printf 'other-output/\n' > "$TARGET/.gitignore"
run_static --path src
t_assert_eq 2 "$STATUS"
t_assert_contains "$OUT" 'must be ignored by the caller'
t_assert_eq 0 "$(wc -c < "$CALLS")"

t_summary
