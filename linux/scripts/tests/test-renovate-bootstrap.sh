#!/usr/bin/env bash
# renovate-local.sh --print-bin installs Renovate with npm ci from the committed lock, over a stand-in node and npm.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
LOCK="${SCRIPTS}/renovate-npm/package-lock.json"

w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
mkdir -p "${w}/bin" "${w}/repo"
git -C "${w}/repo" init -q
# node reports the pinned major, so the script takes it from PATH and downloads nothing.
printf '#!/bin/sh\n[ "$1" = --version ] && echo v24.21.0\nexit 0\n' > "${w}/bin/node"
printf '#!/bin/sh\necho "$*" >> "%s/npm.log"\n[ "$1" = ci ] && [ -f package.json ] && [ -f package-lock.json ] || exit 3\nmkdir -p node_modules/renovate/dist && : > node_modules/renovate/dist/renovate.js\necho "added 620 packages"\n' \
  "${w}" > "${w}/bin/npm"
chmod +x "${w}/bin/node" "${w}/bin/npm"
want="$(sed -n 's/^RENOVATE_VERSION=//p' "${SCRIPTS}/01-core/tool-pins.env")"

# print_bin [VAR=value...]: --print-bin from the throwaway repo; stdout in ${w}/out, stderr in ${w}/err.
print_bin() {
  (cd "${w}/repo" && env -u RENOVATE_VERSION PATH="${w}/bin:${PATH}" RENOVATE_LOCAL_CACHE="${w}/cache" "$@" \
    bash "${SCRIPTS}/renovate-local.sh" --print-bin > "${w}/out" 2> "${w}/err")
}

t_case "the lock installs the Renovate tool-pins.env pins"
t_assert_eq "${want}" "$(tr -d '\r' < "${LOCK}" | sed -n '/"node_modules\/renovate": {/{n;s/.*"version": "\([^"]*\)".*/\1/p;}')"

t_case "--print-bin installs with npm ci from the lock, and stdout is the path alone"
t_assert_ok print_bin
prefix="${w}/cache/renovate-${want}-$(sha256sum "${LOCK}" | cut -c1-12)"
t_assert_eq "${prefix}/node_modules/renovate/dist/renovate.js" "$(cat "${w}/out")"
t_assert_eq "ci --no-fund --no-audit --no-update-notifier --loglevel=error" "$(cat "${w}/npm.log")" "never a fresh resolve"
t_assert_eq "" "$(cmp "${LOCK}" "${prefix}/package-lock.json" 2>&1)" "the committed lock, byte for byte"

t_case "a second run takes the installed prefix"
t_assert_ok print_bin
t_assert_eq 1 "$(wc -l < "${w}/npm.log" | tr -d ' ')"

t_case "a pin the lock does not install is refused before npm runs"
t_assert_fails print_bin RENOVATE_VERSION=0.0.1
t_assert_contains "$(cat "${w}/err")" "installs renovate ${want}, tool-pins.env pins 0.0.1"
t_assert_eq 1 "$(wc -l < "${w}/npm.log" | tr -d ' ')"

t_summary
