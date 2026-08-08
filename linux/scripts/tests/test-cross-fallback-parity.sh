#!/usr/bin/env bash
# Parity suite for the three intentionally-bundled cross_build_is_active
# fallback clones (01-core/common.sh, 03-media/core/common.sh,
# gstreamer/common/build-gstreamer-monorepo.sh). Bundling is policy; DRIFT is
# the bug — this file has drifted twice (arch normalization missed 4 of 5
# copies; the cross_build_enabled delegation missed the monorepo copy).
# Assert BEHAVIOR parity of the fallback in three scenarios instead of
# diffing text (comments/locals may differ).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

_probe() {
  # $1 = file, $2 = fn-extraction context, $3... = env; runs the fallback
  # definition in a clean bash with cross_build_is_active undefined.
  local file="$1"; shift
  bash -c "
    arch_normalize() { case \"\$1\" in x86_64) echo amd64;; aarch64) echo arm64;; *) echo \"\$1\";; esac; }
    # extract just the guarded fallback definition block
    src=\$(awk '/if ! command -v cross_build_is_active/,/^  fi\$|^fi\$/' '${file}')
    eval \"\${src}\"
    $* cross_build_is_active && echo ACTIVE || echo INACTIVE
  " 2>/dev/null
}

# 01-core/common.sh delegates at SOURCE time (structurally different,
# semantically equivalent) — awk extraction doesn't fit it; assert its
# structure directly instead of its behavior.
t_case "01-core/common.sh: source-time delegation to cross_build_enabled present"
t_assert_ok grep -q 'cross_build_is_active() { cross_build_enabled; }' "${TESTS_DIR}/../01-core/common.sh"

FILES=(
  "${TESTS_DIR}/../03-media/core/common.sh"
  "${TESTS_DIR}/../03-media/build/gstreamer/common/build-gstreamer-monorepo.sh"
)

for f in "${FILES[@]}"; do
  name="$(basename "$(dirname "${f}")")/$(basename "${f}")"

  t_case "${name}: cross+foreign arch => ACTIVE"
  t_assert_eq "ACTIVE" "$(_probe "${f}" BUILD_MODE=cross TARGET_ARCH=arm64 BUILDARCH=amd64)"

  t_case "${name}: cross+same arch => INACTIVE (OCI vs uname normalization)"
  t_assert_eq "INACTIVE" "$(_probe "${f}" BUILD_MODE=cross TARGET_ARCH=arm64 BUILDARCH=aarch64)"

  t_case "${name}: native => INACTIVE"
  t_assert_eq "INACTIVE" "$(_probe "${f}" BUILD_MODE=native TARGET_ARCH=arm64 BUILDARCH=amd64)"

  t_case "${name}: delegates to cross_build_enabled when defined"
  out="$(bash -c "
    arch_normalize() { echo \"\$1\"; }
    cross_build_enabled() { return 0; }
    src=\$(awk '/if ! command -v cross_build_is_active/,/^  fi\$|^fi\$/' '${f}')
    eval \"\${src}\"
    BUILD_MODE=native cross_build_is_active && echo DELEGATED || echo RAW
  " 2>/dev/null)"
  t_assert_eq "DELEGATED" "${out}" "authoritative predicate must win over the approximation"
done

t_summary
