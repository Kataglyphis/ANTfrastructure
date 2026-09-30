#!/usr/bin/env bash
# A wired restore is not a working one, so wiring and outcome each get a red; see docs/code-quality-tooling.md#ubuntu-mirror-consistency-mirror-consistency
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"
DOCKERFILES="base toolchain sdk media android package torch"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _tree: the whole 01-core, because the gate runs the real mirror scripts, plus the Dockerfiles it checks.
_tree() {
  local d name; d="$(mktemp -d "${_work}/tree.XXXXXX")"
  mkdir -p "${d}/linux/scripts" "${d}/linux"
  cp -r "${CORE}" "${d}/linux/scripts/01-core"
  # base-image.sh's module framework reaches outside 01-core for exactly one file.
  install -D -m 0644 "${CORE}/../02-toolchain/cmake.sh" "${d}/linux/scripts/02-toolchain/cmake.sh"
  for name in ${DOCKERFILES}; do
    {
      printf 'ARG USE_FAST_UBUNTU_MIRROR\n'
      printf 'ARG FAST_UBUNTU_MIRROR_URL\n'
      printf 'ARG FAST_UBUNTU_PORTS_MIRROR_URL\n'
      [ "${name}" = base ] && printf 'RUN bash /opt/scripts/core/use-fast-ubuntu-mirror.sh\n'
    } > "${d}/linux/Dockerfile.${name}"
  done
  printf '%s' "${d}"
}

_gate() { bash "$1/linux/scripts/01-core/verify-ubuntu-mirror-consistency.sh"; }

t_case "a consistent tree passes both halves"
fix="$(_tree)"
_out="$(t_out _gate "${fix}")"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the gate must be able to be green, or the reds below prove nothing"
t_assert_contains "${_out}" "CA-bootstrap downgrade provably restored to https"

t_case "a Dockerfile missing one canonical mirror ARG fails, naming both"
fix="$(_tree)"
sed -i '/^ARG FAST_UBUNTU_PORTS_MIRROR_URL$/d' "${fix}/linux/Dockerfile.media"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" "linux/Dockerfile.media is missing ARG FAST_UBUNTU_PORTS_MIRROR_URL"

t_case "the mirror RUN is required in Dockerfile.base, and only there"
fix="$(_tree)"
sed -i '/use-fast-ubuntu-mirror.sh/d' "${fix}/linux/Dockerfile.base"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "missing use-fast-ubuntu-mirror.sh RUN"
fix="$(_tree)"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "downstream images inherit it; requiring it everywhere would be a false red"

t_case "a Dockerfile the tree does not have is skipped, not reported missing"
fix="$(_tree)"
rm -f "${fix}/linux/Dockerfile.torch"
t_assert_eq "0" "$(t_rc _gate "${fix}")"

# --- the wiring half (1): a working-but-unwired restore is the failure mode ----

t_case "bootstrap_ca that never calls the restore FAILS"
fix="$(_tree)"
sed -i 's/^  restore_mirror_https_scheme$/  true/' "${fix}/linux/scripts/01-core/base-image.sh"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "bootstrap_ca does not call restore_mirror_https_scheme"

t_case "a restore that runs BEFORE the ca-certificates install FAILS"
# https before the CA store exists re-creates the chicken-and-egg the downgrade breaks.
fix="$(_tree)"
python3 - "${fix}/linux/scripts/01-core/base-image.sh" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
body = re.search(r"^bootstrap_ca\(\).*?^\}", text, re.S | re.M).group(0)
moved = body.replace("\n  restore_mirror_https_scheme\n", "\n")
moved = moved.replace("bootstrap_ca() {\n", "bootstrap_ca() {\n  restore_mirror_https_scheme\n", 1)
open(path, "w", encoding="utf-8").write(text.replace(body, moved, 1))
PY
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" "must run AFTER the ca-certificates install"

# --- the outcome half (2): referenced != restored -----------------------------

t_case "a restore that no-ops FAILS on the fixture, however well it is wired"
# A present call site can still leave the sources on http; only running the pipeline shows it.
fix="$(_tree)"
sed -i 's/^restore_mirror_https_scheme() {$/restore_mirror_https_scheme() {\n  return 0/' \
  "${fix}/linux/scripts/01-core/base-image.sh"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a wired call to a function that does nothing is the whole bug"
t_assert_contains "${_out}" "mirror SCHEME not restored"

t_case "a restore that fails outright is reported as a failure, not as a pass"
fix="$(_tree)"
sed -i 's/^restore_mirror_https_scheme() {$/restore_mirror_https_scheme() {\n  return 1/' \
  "${fix}/linux/scripts/01-core/base-image.sh"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "restore-mirror-scheme failed on the fixture"

t_case "a downgrade that stops landing is reported as a broken PRECONDITION"
# Without a landed downgrade the outcome check would pass for the wrong reason.
fix="$(_tree)"
sed -i 's|^  sources_root="${UBUNTU_SOURCES_ROOT:-/}"$|  sources_root="/nonexistent-root"|' \
  "${fix}/linux/scripts/01-core/use-fast-ubuntu-mirror.sh"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" "fixture precondition failed"

t_case "several errors are all reported, and the count reaches the exit code"
fix="$(_tree)"
sed -i '/^ARG FAST_UBUNTU_MIRROR_URL$/d' "${fix}/linux/Dockerfile.sdk"
sed -i '/^ARG USE_FAST_UBUNTU_MIRROR$/d' "${fix}/linux/Dockerfile.package"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" "FAILED: 2 mirror consistency errors" \
  "a per-file loop that reports and exits 0 is the shape this repo keeps finding"

# --- the pocket half (3): each file is valid alone, only the PAIR is wrong ----

# A second writer, so the fixture can carry a DISAGREEMENT and not just a flag.
_second_writer() {
  printf 'ubuntu_write_deb822_source /etc/apt/sources.list.d/ubuntu.sources "https://a/" resolute amd64 %s\n' \
    "$2" > "$1/linux/scripts/01-core/_extra-writer.sh"
}

t_case "two writers that disagree on -security FAIL, naming both sides"
# A -security skew between writers leaves Multi-Arch:same libraries with no common version.
fix="$(_tree)"
_second_writer "${fix}" 0
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" "do not agree on the -security flag"
t_assert_contains "${_out}" "_extra-writer.sh:1"
t_assert_contains "${_out}" "cross-apt.sh"

t_case "two writers that AGREE pass, so the red above is about the skew"
fix="$(_tree)"
_second_writer "${fix}" 1
t_assert_eq "0" "$(t_rc _gate "${fix}")"

t_case "a helper that drops -security for the host arch only FAILS"
fix="$(_tree)"
sed -i 's|  if \[ "${with_security}" = "1" \]; then|  if [ "${with_security}" = "1" ] \&\& [ "${arch}" != "amd64" ]; then|' \
  "${fix}/linux/scripts/01-core/ubuntu-mirror.sh"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "equal flags that yield unequal suite sets is the bug in the helper instead of the caller"
t_assert_contains "${_out}" "asymmetric for equal flags"

t_case "a tree with no writer at all is reported, not silently green"
fix="$(_tree)"
# Every writer goes, or NOSITES never fires; the remaining `command -v` probe must not count as a call.
sed -i 's|^[[:space:]]*ubuntu_write_deb822_source .*|  : # writer removed|' \
  "${fix}/linux/scripts/01-core/cross-apt.sh"
t_assert_ok grep -q 'command -v ubuntu_write_deb822_source' \
  "${fix}/linux/scripts/01-core/cross-apt.sh"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a scan that finds nothing must not read as a pass"
t_assert_contains "${_out}" "NOSITES"

t_case "the REAL tree is consistent today"
t_assert_eq "0" "$(t_rc bash "${CORE}/verify-ubuntu-mirror-consistency.sh")"

t_summary
