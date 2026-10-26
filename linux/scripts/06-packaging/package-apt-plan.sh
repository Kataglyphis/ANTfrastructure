#!/usr/bin/env bash
# The package stage's strict apt set, simulated against its parent's sources: docs/linux-cross-builds.md#the-runtime-lane-input-preflight
set -euo pipefail

# Lines of an apt-get --simulate failure that name the conflict.
apt_plan_conflict_lines() {
    grep -E -e '^E:' -e ': (Pre)?Depends:' -e ': (Conflicts|Breaks):' || true
}

# <package...>: 0 when apt resolves the install, else 1 with apt's own lines on stderr.
apt_plan_simulate() {
    local out rc=0 lines
    out="$(DEBIAN_FRONTEND=noninteractive apt-get install --simulate --no-install-recommends "$@" 2>&1)" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        printf 'OK: apt plan: %s package(s) resolve: %s\n' "$#" "$*"
        return 0
    fi
    lines="$(printf '%s\n' "${out}" | apt_plan_conflict_lines)"
    [ -n "${lines}" ] || lines="$(printf '%s\n' "${out}" | tail -n 20)"
    printf 'ERROR: apt-get install --simulate failed (rc=%s):\n%s\n' "${rc}" "${lines}" >&2
    return 1
}

apt_plan_main() {
    local python_mm="${PYTHON_MAJOR_MINOR:?PYTHON_MAJOR_MINOR is required}"
    local gcc_major="${GCC_VERSION%%.*}"
    local -a packages=()
    [ -n "${gcc_major}" ] || { echo "ERROR: GCC_VERSION is required" >&2; return 1; }

    # Dockerfile.package switches mirrors before setup-package-image.sh, so apt here reads what it reads.
    if [ "${USE_FAST_UBUNTU_MIRROR:-false}" = "true" ]; then
        bash /opt/scripts/core/use-fast-ubuntu-mirror.sh
    fi
    apt-get update
    # The stage installs the staged CPython first, so select_dev_packages skips python-dev there too.
    [ -e "/usr/local/bin/python${python_mm}" ] || install -m 0755 /dev/null "/usr/local/bin/python${python_mm}"
    select_dev_packages packages "${python_mm}" "${gcc_major}"
    apt_plan_simulate "${packages[@]}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # shellcheck source=linux/scripts/06-packaging/setup-package-image.sh
    source /opt/scripts/packaging/setup-package-image.sh
    apt_plan_main "$@"
fi
