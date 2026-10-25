#!/usr/bin/env bash
# Mutated Gradle wrapper properties prove the exact edit and refusals; no network or wrapper JAR runs here.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

PROPERTIES=android/gradle/wrapper/gradle-wrapper.properties

_wrapper_repo() {
  local repo
  repo="$(_repo "$1")"
  mkdir -p "${repo}/android/gradle/wrapper"
  cat > "${repo}/${PROPERTIES}"
  _commit "${repo}"
  printf '%s' "${repo}"
}

REPORT="${WORK}/gradle-wrapper.json"
_report "${REPORT}" gradle-wrapper "${PROPERTIES}" gradle 9.8.1 9.8.2

t_case "the exact Gradle version moves while the mirror URL, distribution type and suffix stay"
GOOD="$(_wrapper_repo gradle-wrapper-good <<'PROPS'
# Keep this mirror and its query when only the version moves.
distributionBase=GRADLE_USER_HOME
distributionUrl=https\://mirror.example.invalid/gradle/gradle-9.8.1-bin.zip?source=ci
zipStoreBase=GRADLE_USER_HOME
PROPS
)"
_run_apply_verdict "${GOOD}" "${REPORT}" gradle-wrapper 0 "one versioned URL applies"
t_assert_eq "$(cat <<'PROPS'
# Keep this mirror and its query when only the version moves.
distributionBase=GRADLE_USER_HOME
distributionUrl=https\://mirror.example.invalid/gradle/gradle-9.8.2-bin.zip?source=ci
zipStoreBase=GRADLE_USER_HOME
PROPS
)" "$(cat "${GOOD}/${PROPERTIES}")" "only the version span changed"

t_case "two distributionUrl lines are ambiguous and leave the checkout untouched"
DUP="$(_wrapper_repo gradle-wrapper-duplicate <<'PROPS'
distributionUrl=https\://services.gradle.org/distributions/gradle-9.8.1-all.zip
distributionUrl=https\://mirror.example.invalid/gradle-9.8.1-bin.zip
PROPS
)"
_run_apply_verdict "${DUP}" "${REPORT}" gradle-wrapper 2 "duplicate URLs refuse"
t_assert_contains "${OUT}" "multiple declarations or report rows are ambiguous" "the refusal names ambiguity"
t_assert_ok git -C "${DUP}" diff --quiet HEAD

t_case "an unreadable distributionUrl cannot be guessed from nearby versions"
BAD="$(_wrapper_repo gradle-wrapper-malformed <<'PROPS'
# The old version in a comment is not a declaration.
distributionUrl=https\://services.gradle.org/distributions/gradle-9.8.1-all.zip#unexpected
PROPS
)"
_run_apply_verdict "${BAD}" "${REPORT}" gradle-wrapper 2 "malformed URL refuses"
t_assert_contains "${OUT}" "no gradle-wrapper declaration of 'gradle'" "the refusal names the missing declaration"
t_assert_ok git -C "${BAD}" diff --quiet HEAD

t_case "a checksum pin cannot be left behind when the archive URL moves"
SHA="$(_wrapper_repo gradle-wrapper-checksum <<'PROPS'
distributionUrl=https\://services.gradle.org/distributions/gradle-9.8.1-all.zip
distributionSha256Sum=0000000000000000000000000000000000000000000000000000000000000000
PROPS
)"
_run_apply_verdict "${SHA}" "${REPORT}" gradle-wrapper 2 "checksum-coupled URL refuses"
t_assert_contains "${OUT}" "distributionSha256Sum pins the current Gradle archive" "the refusal names the coupled checksum"
t_assert_ok git -C "${SHA}" diff --quiet HEAD

t_summary
