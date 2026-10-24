#!/usr/bin/env bash
# Disposable sources and Dockerfile inspection cover cache companion closure, not real cache commands or builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CACHE="${1:-${TESTS_DIR}/../01-core/compiler-cache.sh}"
CMAKE="${2:-${TESTS_DIR}/../01-core/cmake-cache-linker.sh}"
GCC="${3:-${TESTS_DIR}/../02-toolchain/build-gcc.sh}"
DOCKER_ROOT="${4:-${TESTS_DIR}/../../..}"
COMMON="${5:-${TESTS_DIR}/../01-core/common.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir "${WORK}/complete" "${WORK}/missing"
for companion in compiler-cache-utils.sh load-versions-env.sh versions.env platform.sh cross-active-fallback.sh; do
  install -m 0644 "${TESTS_DIR}/../01-core/${companion}" "${WORK}/complete/"
done
for module in "${CACHE}" "${CMAKE}" "${COMMON}"; do
  install -m 0644 "${module}" "${WORK}/complete/${module##*/}"
done

t_case 'cache modules initialize with their complete companion closure'
for module in "${CACHE}" "${CMAKE}" "${COMMON}"; do
  rc=0
  result="$(bash -euc 'source "$1"; declare -F compiler_tool_enabled >/dev/null; printf READY' _ "${WORK}/complete/${module##*/}")" || rc=$?
  t_assert_eq 0 "${rc}"
  t_assert_eq READY "${result}"
done

t_case 'cache modules reject a missing companion even when source runs under if'
cp -a "${WORK}/complete/." "${WORK}/missing/"
rm "${WORK}/missing/compiler-cache-utils.sh"
for module in "${CACHE}" "${CMAKE}" "${COMMON}"; do
  result="$(bash -c 'if source "$1" 2>/dev/null; then printf GREEN; else printf REJECTED; fi; if source "$1" 2>/dev/null; then printf GREEN; else printf REJECTED; fi' _ "${WORK}/missing/${module##*/}")"
  t_assert_eq REJECTEDREJECTED "${result}" 'a failed load cannot mark the module successfully loaded'
done

t_case 'the GCC bootstrap refuses a missing cache utility before later initialization'
mkdir "${WORK}/toolchain" "${WORK}/01-core" "${WORK}/mounted"
cp "${TESTS_DIR}/../01-core/load-versions-env.sh" "${WORK}/01-core/"
cp "${TESTS_DIR}/../02-toolchain/bootstrap-import.sh" "${WORK}/toolchain/"
sed "s|/opt/scripts/core|${WORK}/mounted|g" "${TESTS_DIR}/../02-toolchain/bootstrap.sh" > "${WORK}/toolchain/bootstrap.sh"
cat >> "${WORK}/toolchain/bootstrap.sh" <<'BASH'
source_toolchain_common_or_fallback() { :; }
source_toolchain_elf_strip() { :; }
install_err_trap() { printf 'later initialization\n'; }
BASH
awk '/^usage\(\) \{/ { exit } { print }' "${GCC}" > "${WORK}/toolchain/build-gcc.sh"
rc=0
out="$(timeout 5 bash "${WORK}/toolchain/build-gcc.sh" 2> "${WORK}/err")" || rc=$?
t_assert_eq 1 "${rc}"
t_assert_contains "$(cat "${WORK}/err")" 'requires compiler-cache-utils.sh'
t_assert_eq '' "${out}" 'later bootstrap and build work must not run'

t_case 'native builders and the media CMake module carry their required utility'
t_assert_ok python3 - "${DOCKER_ROOT}" "${TESTS_DIR}/.." <<'PYTHON'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[2])
from verify_dockerfile_env_order import instructions
root = Path(sys.argv[1])
base_runs = [line for _, line in instructions(root / 'linux/Dockerfile.base') if line.startswith('RUN ') and 'source=linux/scripts/01-core/common.sh,' in line]
assert len(base_runs) == 6
assert all('source=linux/scripts/01-core/compiler-cache-utils.sh,target=/tmp/scripts/01-core/compiler-cache-utils.sh,ro' in run for run in base_runs)
runs = [line for _, line in instructions(root / 'linux/Dockerfile.toolchain') if line.startswith('RUN ') and 'source=linux/scripts/02-toolchain/build-gcc.sh,' in line]
assert len(runs) == 2
assert all('source=linux/scripts/01-core/compiler-cache-utils.sh,' in run for run in runs)
media = [line for _, line in instructions(root / 'linux/Dockerfile.media')]
assert any(line.startswith('COPY ') and 'linux/scripts/01-core/compiler-cache-utils.sh' in line and '/opt/scripts/core/' in line for line in media)
PYTHON
t_summary
