#!/usr/bin/env bash
# clean-host-package-check.sh on a planted tarball: the ldd scan, its scan-elves switch, the command, and the one-match glob.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

CHECK="${TESTS_DIR}/../../../.github/actions/clean-host-package-check/clean-host-package-check.sh"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# An ELF whose NEEDED library is gone, as a bundle built in the image looks on a bare host.
mkdir -p "${_work}/build" "${_work}/app/bin" "${_work}/app/lib" "${_work}/artifact/packages"
printf 'int gone(void) { return 1; }\n' > "${_work}/build/gone.c"
printf 'int gone(void);\nint uses(void) { return gone(); }\n' > "${_work}/build/uses.c"
cc -shared -fPIC -o "${_work}/build/libgone.so" "${_work}/build/gone.c"
cc -shared -fPIC -o "${_work}/app/lib/libuses.so" "${_work}/build/uses.c" -L"${_work}/build" -lgone
printf '#!/bin/sh\nexit 0\n' > "${_work}/app/bin/ok"
chmod +x "${_work}/app/bin/ok"
tar -czf "${_work}/artifact/packages/app-linux.tar.gz" -C "${_work}" app
_check() { env PACKAGES_DIR="${_work}/artifact/packages" TARBALL_GLOB='*.tar.gz' TARBALL_COMMAND=./bin/ok "$@" bash "${CHECK}"; }

t_case "a missing library fails the ldd scan, and is named"
t_assert_fails _check
t_assert_contains "$(_check 2>&1)" "libgone.so => not found" "the missing library is printed"

t_case "scan-elves false leaves the proof to the command"
t_assert_ok _check SCAN_ELVES=false
t_assert_fails _check SCAN_ELVES=false TARBALL_COMMAND='exit 3'

t_case "a glob matching two packages fails instead of testing one"
cp "${_work}/artifact/packages/app-linux.tar.gz" "${_work}/artifact/packages/app-linux-2.tar.gz"
t_assert_fails _check SCAN_ELVES=false
t_assert_contains "$(_check SCAN_ELVES=false 2>&1)" "matches 2 files" "the count is named"

t_summary
