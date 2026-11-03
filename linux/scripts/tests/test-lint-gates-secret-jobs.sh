#!/usr/bin/env bash
# _lint_gates_secret_scan_all with a stub lint-secrets.sh; not covered: gitleaks itself, which the gate's self-test holds.
set -u
source "${BASH_SOURCE[0]%/*}/test-harness.sh"
# shellcheck source=../run-lint-gates.sh
source "${_T_SCRIPTS}/run-lint-gates.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
_LINT_GATES_DIR="${_work}/stub"
_LINT_GATES_ROOT="${_work}/root"
mkdir -p "${_LINT_GATES_DIR}" "${_LINT_GATES_ROOT}"
{
  printf '#!/usr/bin/env bash\nname="${1##*/}"\n'
  sed -n '/^meet_peers() {$/,/^}$/p' "${_T_SCRIPTS}/tests/meet.sh"
  cat <<'STUB'
printf 'scan %s config=%s\n' "${name}" "${2:-none}"
case "${name}" in
  meet*) [ "$(meet_peers "${MEET_DIR}" "${name}" 2 "${MEET_SECS:-20}")" = met ] || { echo "ran alone"; exit 5; } ;;
  leak) echo "found a secret"; exit 1 ;;
  vanish) kill -9 "$PPID" ;;
esac
exit 0
STUB
} > "${_LINT_GATES_DIR}/lint-secrets.sh"

_scan() {
  local rc=0
  LAST="$(_lint_gates_secret_scan_all "$@" 2>&1)" || rc=$?
  return "${rc}"
}

t_case "two scans overlap by default, and report in scope order"
export MEET_DIR="${_work}/meet-a"
mkdir -p "${MEET_DIR}"
t_assert_ok _scan "" meet-b meet-a
t_assert_eq "scan meet-b config=none
scan meet-a config=none" "${LAST}" "the first scope entry reports first, whichever finished first"

t_case "one job runs them in turn"
export MEET_DIR="${_work}/meet-b" MEET_SECS=1
mkdir -p "${MEET_DIR}"
LINT_GATES_SECRET_JOBS=1 t_assert_fails _scan "" meet-a meet-b
t_assert_contains "${LAST}" "ran alone"

t_case "a finding beside clean scans fails the gate and keeps its output"
t_assert_fails _scan "" clean leak other
t_assert_contains "${LAST}" "found a secret"
t_assert_contains "${LAST}" "scan other"

t_case "a scan that died before it wrote a status fails the gate"
t_assert_fails _scan "" clean vanish

t_case "the config reaches every scan"
t_assert_ok _scan cfg.toml one two
t_assert_contains "${LAST}" "scan two config=cfg.toml"

t_case "a bad job count stops the gate"
LINT_GATES_SECRET_JOBS=many _scan "" one
t_assert_eq 2 "$?" "not a positive integer"

t_case "the gate takes this path"
t_assert_contains "$(declare -f _lint_gates_secrets)" '_lint_gates_secret_scan_all "${config}" "${scope[@]}"'

t_summary
