#!/usr/bin/env bash
# Tests for 01-core/cross-apt.sh — the install_target_packages 3-path state
# machine (clean batch / batch-fail + per-package retry / genuinely missing)
# and the cross_package_status_present contract it uses as a disambiguator.
#
# Headline regression guard: on a CLEAN batch install (apt-get rc 0) the
# files-present sweep must NOT run at all. cross_package_status_present is only
# a heuristic and false-negatives for some packages (e.g. libfreetype6-dev);
# running it after a successful atomic install turned perfectly good installs
# into spurious failures. A clean rc=0 must be trusted as-is.
#
# No sudo, no network, no real apt: fake `apt-get` and `dpkg-query` binaries
# in a mktemp bin dir are prepended to PATH. Each fake appends its argv to a
# per-tool log so the tests can assert exactly which code path ran. The
# cross_* collaborators are stubbed AFTER sourcing cross-apt.sh so only the
# unit under test is real.
#
# Contract note (deliberate): despite its name — and the caller comment about
# "hunting for a representative file" — cross_package_status_present checks the
# dpkg-query '${Status}' field, NOT files on disk. The suite tests that actual
# status contract: installed/unpacked/half-configured/triggers-* are "present",
# "deinstall ok config-files" and unknown packages are not.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/cross-apt.sh"

# --- stubs: everything install_target_packages needs besides apt/dpkg -------
cross_build_enabled() { return 0; }
cross_prepare_foreign_arch() { :; }
cross_resolve_target_package() { printf '%s' "$1"; }
_CROSS_ENV_APT_UPDATED=1   # normally initialized by cross-env.sh

# --- fake tool sandbox ------------------------------------------------------
FAKE_DIR="$(mktemp -d)"
trap 'rm -rf "${FAKE_DIR}"' EXIT
FAKE_BIN="${FAKE_DIR}/bin"
export FAKE_LOG_DIR="${FAKE_DIR}/log"
export FAKE_STATE_DIR="${FAKE_DIR}/state"
mkdir -p "${FAKE_BIN}" "${FAKE_LOG_DIR}" "${FAKE_STATE_DIR}"

# Fake apt-get. Modes (env FAKE_APT_MODE): "ok" = every install succeeds;
# "batch-fail" = any multi-package install exits 100 (atomic transaction
# abort), single-package installs then succeed unless the package is listed in
# FAKE_ABSENT (space-separated), which simulates a genuinely unresolvable
# name. A successful install writes the package's dpkg Status into
# FAKE_STATE_DIR so the fake dpkg-query can see it.
cat > "${FAKE_BIN}/apt-get" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LOG_DIR}/apt-get.log"
cmd="${1:-}"; shift || true
[ "${cmd}" = "update" ] && exit 0
[ "${cmd}" = "install" ] || exit 0
pkgs=()
for a in "$@"; do case "${a}" in -*) ;; *) pkgs+=("${a}") ;; esac; done
if [ "${FAKE_APT_MODE:-ok}" = "batch-fail" ] && [ "${#pkgs[@]}" -gt 1 ]; then
  echo "E: Unable to locate package (simulated batch abort)" >&2
  exit 100
fi
for p in "${pkgs[@]}"; do
  case " ${FAKE_ABSENT:-} " in
    *" ${p} "*) echo "E: Unable to locate package ${p}" >&2; exit 100 ;;
  esac
  printf 'install ok installed' > "${FAKE_STATE_DIR}/${p}"
done
exit 0
FAKE
chmod +x "${FAKE_BIN}/apt-get"

# Fake dpkg-query: last argv element is the package; print its recorded Status
# (no trailing newline, like the real -f='${Status}') or fail like the real
# tool does for unknown packages. Logging every call is what lets the suite
# prove the sweep did NOT run on the clean-batch path.
cat > "${FAKE_BIN}/dpkg-query" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LOG_DIR}/dpkg-query.log"
pkg="${!#}"
if [ -f "${FAKE_STATE_DIR}/${pkg}" ]; then
  cat "${FAKE_STATE_DIR}/${pkg}"
  exit 0
fi
echo "dpkg-query: no packages found matching ${pkg}" >&2
exit 1
FAKE
chmod +x "${FAKE_BIN}/dpkg-query"

export PATH="${FAKE_BIN}:${PATH}"

# _reset_fakes [mode] [absent-list] — wipe logs/state, script the next scenario.
_reset_fakes() {
  : > "${FAKE_LOG_DIR}/apt-get.log"
  : > "${FAKE_LOG_DIR}/dpkg-query.log"
  rm -f "${FAKE_STATE_DIR:?}"/*
  export FAKE_APT_MODE="${1:-ok}"
  export FAKE_ABSENT="${2:-}"
  _CROSS_ENV_APT_UPDATED=1
}

# ---------------------------------------------------------------------------
t_case "no arguments is a no-op success (no apt-get call)"
_reset_fakes ok
t_assert_ok install_target_packages
t_assert_eq "" "$(cat "${FAKE_LOG_DIR}/apt-get.log")" "apt-get must not run for an empty package list"

# ---------------------------------------------------------------------------
# Path 1: clean atomic install. rc=0 must be trusted; the files-present sweep
# must not run (libfreetype6-dev false-negative regression).
t_case "clean batch success returns 0 and skips the files-present sweep"
_reset_fakes ok
out="$(install_target_packages libfoo-dev libbar-dev 2>&1)"; rc=$?
t_assert_eq "0" "${rc}" "clean batch install must return 0"
t_assert_eq "" "$(cat "${FAKE_LOG_DIR}/dpkg-query.log")" \
  "dpkg-query must NOT be invoked after a clean batch (would false-negative e.g. libfreetype6-dev)"
t_assert_eq "1" "$(wc -l < "${FAKE_LOG_DIR}/apt-get.log")" "exactly one apt-get call: the atomic batch"
t_assert_contains "$(cat "${FAKE_LOG_DIR}/apt-get.log")" \
  "install -y --no-install-recommends libfoo-dev libbar-dev" "batch argv carries all packages at once"

# ---------------------------------------------------------------------------
# Path 2: batch aborts (rc 100), per-package retries land everything, sweep
# finds all present -> overall success, and the retries really happened.
t_case "batch rc=100 with successful per-package retries returns 0"
_reset_fakes batch-fail
out="$(install_target_packages libfoo-dev libbar-dev 2>&1)"; rc=$?
t_assert_eq "0" "${rc}" "per-package recovery must yield overall success"
t_assert_contains "${out}" "retrying per-package" "the fallback must announce itself"
t_assert_contains "${out}" "all requested packages are present" "the sweep verdict must be reported"
t_assert_eq "1" "$(grep -cx -- 'install -y --no-install-recommends libfoo-dev' "${FAKE_LOG_DIR}/apt-get.log")" \
  "libfoo-dev must be retried exactly once on its own"
t_assert_eq "1" "$(grep -cx -- 'install -y --no-install-recommends libbar-dev' "${FAKE_LOG_DIR}/apt-get.log")" \
  "libbar-dev must be retried exactly once on its own"
t_assert_eq "2" "$(wc -l < "${FAKE_LOG_DIR}/dpkg-query.log")" \
  "the files-present sweep must check each package exactly once on the failure path"

# ---------------------------------------------------------------------------
# Path 3: batch aborts AND one package is genuinely unresolvable -> return 1
# and name exactly the missing package (not its innocent batch-mates).
t_case "batch fail with one genuinely absent package returns 1 naming it"
_reset_fakes batch-fail "libbogus-dev"
out="$(install_target_packages libfoo-dev libbogus-dev 2>&1)"; rc=$?
t_assert_eq "1" "${rc}" "a genuinely missing package must fail the install"
t_assert_eq "install_target_packages: FAILED — missing after apt-get (rc=100): libbogus-dev" \
  "$(printf '%s\n' "${out}" | grep 'FAILED' || true)" \
  "failure line must name exactly the absent package (and not libfoo-dev)"

# ---------------------------------------------------------------------------
# cross_package_status_present contract: it reads the dpkg '${Status}' field
# (NOT files on disk, despite the name). Unpacked/half-configured — the state
# a foreign-arch package lands in when its postinst hits Exec format error —
# must count as present; a removed package must not.
t_case "cross_package_status_present accepts usable dpkg Status values"
_reset_fakes ok
printf 'install ok installed'        > "${FAKE_STATE_DIR}/pkg-inst"
printf 'install ok unpacked'         > "${FAKE_STATE_DIR}/pkg-unp"
printf 'install ok half-configured'  > "${FAKE_STATE_DIR}/pkg-half"
printf 'install ok triggers-awaited' > "${FAKE_STATE_DIR}/pkg-trig"
t_assert_ok cross_package_status_present pkg-inst
t_assert_ok cross_package_status_present pkg-unp
t_assert_ok cross_package_status_present pkg-half
t_assert_ok cross_package_status_present pkg-trig

t_case "cross_package_status_present rejects removed and unknown packages"
printf 'deinstall ok config-files' > "${FAKE_STATE_DIR}/pkg-gone"
t_assert_fails cross_package_status_present pkg-gone
t_assert_fails cross_package_status_present pkg-never-seen

t_case "a pkg=version spec is stripped to the bare name for the lookup"
t_assert_ok cross_package_status_present "pkg-inst=1.2.3-1"
t_assert_eq "pkg-inst" "$(tail -1 "${FAKE_LOG_DIR}/dpkg-query.log" | awk '{print $NF}')" \
  "dpkg-query must receive the bare package name, not name=version"

t_summary
