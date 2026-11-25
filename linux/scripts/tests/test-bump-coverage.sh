#!/usr/bin/env bash
# bump_coverage.py: who moves each pin, drift and stale table rows; it does not look up upstream versions. See docs/dependency-updates.md#what-one-call-does-not-move
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/bump-versions-fixture.sh
source "${TESTS_DIR}/bump-versions-fixture.sh" || exit 1

t_case "--audit-coverage on the REAL pin files: who updates each pin, the drift pins and the pins outside them"
t_needs "a POSIX Python that can read the fixture paths" t_posix_python
_real="$(_audit_expr "bump_coverage.audit_coverage()")"
t_assert_contains "${_real}" "rc 0" "every committed pin has a class and no table row is stale"
t_assert_contains "${_real}" "LLVM_COMMIT" "a hand-moved commit whose owner Renovate moves is named as drift"
t_assert_contains "${_real}" "with LLVM_RELEASE (renovate)" "with its owner and the owner's updater"
t_assert_contains "${_real}" "source-pins.txt: onnxruntime v" "a version kept outside the pin files is listed"
t_assert_eq "0" "$(printf '%s\n' "${_real}" | grep -c -e 'OPENCV_COMMIT .*(renovate)' || true)" "an empty commit pin follows its tag and is no drift"

t_case "a new commit or asset pin no longer hides behind the non-version filter"
t_needs "a POSIX Python that can read the fixture paths" t_posix_python
_mut="$(_audit_pins audit_unclassified versions.env NEWLIB_COMMIT=0123456789abcdef0123456789abcdef01234567 versions.env NEWLIB_ASSET=newlib.zip)"
t_assert_contains "${_mut}" "rc 1" "--audit-unclassified fails on a commit or asset pin with no owner"
t_assert_contains "${_mut}" "NEWLIB_COMMIT" "the commit pin is named"
t_assert_contains "${_mut}" "NEWLIB_ASSET" "the asset pin is named"
_cov="$(_audit_expr "bump_coverage.audit_coverage(brief=True)" versions.env NEWLIB_COMMIT=0123456789abcdef0123456789abcdef01234567)"
t_assert_contains "${_cov}" "rc 1" "--audit-coverage fails on the same pin, so the Renovate run refuses"
t_assert_contains "${_cov}" "  NEWLIB_COMMIT" "and names it"

t_case "a stale FOLLOWS row fails, and drift needs a set pin and a one-call owner (offline)"
_out="$(_bv_offline <<'PY'
import bump_coverage as cov
cov.FOLLOWS.update(NOPE_COMMIT="LLVM_RELEASE", FLUTTER_COMMIT="FLUTTER_VERSION")
print("rc", cov.audit_coverage())
classes = dict(A_COMMIT=("hand", "with A_VERSION"), A_VERSION=("renovate", ""),
               B_COMMIT=("hand", "with B_VERSION"), B_VERSION=("hand", "MANUAL"))
cov.FOLLOWS = dict(A_COMMIT="A_VERSION", B_COMMIT="B_VERSION")
print("drift", cov.drift(dict(A_COMMIT="abc", B_COMMIT="def", A_VERSION="1", B_VERSION="2"), classes))
print("empty", cov.drift(dict(A_COMMIT="", A_VERSION="1"), classes))
PY
)"
t_assert_contains "${_out}" "rc 1" "a stale row fails the audit"
t_assert_contains "${_out}" "FOLLOWS NOPE_COMMIT -> LLVM_RELEASE: no such pin" "a row naming no pin is reported"
t_assert_contains "${_out}" "FOLLOWS FLUTTER_COMMIT: already bump extra, delete the row" "a row another class covers is reported"
t_assert_contains "${_out}" "drift [('A_COMMIT', 'A_VERSION', 'renovate')]" "only a set pin whose owner one call moves is drift"
t_assert_contains "${_out}" "empty []" "an empty pin follows its tag"

t_summary
