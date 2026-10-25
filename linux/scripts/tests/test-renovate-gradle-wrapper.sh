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

_wrapper_refuses() {
  local repo
  repo="$(_wrapper_repo "$1")"
  _parser_refuses "${repo}" "${REPORT}" gradle-wrapper "$2" "$3" "$4"
  t_assert_ok git -C "${repo}" diff --quiet HEAD
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
_wrapper_refuses gradle-wrapper-duplicate \
  "multiple declarations or report rows are ambiguous" "duplicate URLs refuse" \
  "the refusal names ambiguity" <<'PROPS'
distributionUrl=https\://services.gradle.org/distributions/gradle-9.8.1-all.zip
distributionUrl=https\://mirror.example.invalid/gradle-9.8.1-bin.zip
PROPS

t_case "an unreadable distributionUrl cannot be guessed from nearby versions"
_wrapper_refuses gradle-wrapper-malformed \
  "no gradle-wrapper declaration of 'gradle'" "malformed URL refuses" \
  "the refusal names the missing declaration" <<'PROPS'
# The old version in a comment is not a declaration.
distributionUrl=https\://services.gradle.org/distributions/gradle-9.8.1-all.zip#unexpected
PROPS

t_case "a checksum pin cannot be left behind when the archive URL moves"
_wrapper_refuses gradle-wrapper-checksum \
  "distributionSha256Sum pins the current Gradle archive" "checksum-coupled URL refuses" \
  "the refusal names the coupled checksum" <<'PROPS'
distributionUrl=https\://services.gradle.org/distributions/gradle-9.8.1-all.zip
distributionSha256Sum=0000000000000000000000000000000000000000000000000000000000000000
PROPS

t_summary
