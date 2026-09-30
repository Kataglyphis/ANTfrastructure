#!/usr/bin/env bash
# verify_script_copy_coverage.py on throwaway roots, since it scans from its own path; see docs/code-quality-tooling.md#script-copy-coverage-copy-coverage
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _tree [<name>]: a repo root holding the gate, with an empty linux/Dockerfile.<name>.
_tree() {
  local d; d="$(t_gate_tree verify_script_copy_coverage.py)"
  mkdir -p "${d}/linux/scripts/01-core" "${d}/linux/scripts/03-media/core"
  : > "${d}/linux/Dockerfile.${1:-base}"
  printf '%s' "${d}"
}

_gate() { "${PY}" "$1/linux/scripts/verify_script_copy_coverage.py" "${@:2}"; }
_df() { printf '%s\n' "${@:2}" >> "$1"; }

t_case "a RUN whose script was COPY'd passes"
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'echo hi\n' > "${fix}/linux/scripts/01-core/entry.sh"
_df "${df}" 'COPY linux/scripts/01-core/entry.sh /opt/scripts/core/entry.sh' \
            'RUN bash /opt/scripts/core/entry.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the gate must be able to be green, or the reds below prove nothing"
t_assert_contains "$(t_out _gate "${fix}")" "all referenced /opt/scripts paths are provided"

t_case "a RUN referencing a script that was never COPY'd FAILS, and names it"
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
_df "${df}" 'RUN bash /opt/scripts/core/never-copied.sh'
t_assert_eq "1" "$(t_rc _gate "${fix}")" "exit 127 deep inside a multi-hour build is what this replaces"
t_assert_contains "$(t_out _gate "${fix}")" "/opt/scripts/core/never-copied.sh"

t_case "a TRANSITIVE reference is followed: the sourced script must be provided too"
# The COPY'd script sources a path the image never had.
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'source /opt/scripts/03-media/core/common.sh\n' > "${fix}/linux/scripts/01-core/install-deps.sh"
_df "${df}" 'COPY linux/scripts/01-core/install-deps.sh /opt/scripts/core/install-deps.sh' \
            'RUN bash /opt/scripts/core/install-deps.sh'
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a direct-references-only check would call this image complete"
t_assert_contains "${_out}" "/opt/scripts/03-media/core/common.sh"

t_case "and it passes once that transitive dependency is COPY'd"
printf 'true\n' > "${fix}/linux/scripts/03-media/core/common.sh"
_df "${df}" 'COPY linux/scripts/03-media/core/ /opt/scripts/03-media/core/'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "a directory COPY provides every *.sh beneath it"

t_case "a bare string literal counts as a reference, not only a bash invocation"
# A `for f in "/opt/scripts/..."; do source "$f"; done` loop never spells out a command.
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'for f in "/opt/scripts/core/helper.sh"; do source "$f"; done\n' \
  > "${fix}/linux/scripts/01-core/loop.sh"
_df "${df}" 'COPY linux/scripts/01-core/loop.sh /opt/scripts/core/loop.sh' \
            'RUN bash /opt/scripts/core/loop.sh'
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "/opt/scripts/core/helper.sh"

t_case "a per-RUN bind mount provides the script for that RUN"
# Counting only COPY would fail a healthy tree.
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'true\n' > "${fix}/linux/scripts/01-core/mounted.sh"
_df "${df}" 'RUN --mount=type=bind,source=linux/scripts/01-core,target=/opt/scripts/core,ro bash /opt/scripts/core/mounted.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}")"

t_case "a COPY split across line continuations still counts"
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'true\n' > "${fix}/linux/scripts/01-core/wrapped.sh"
_df "${df}" 'COPY --chmod=755 \' \
            '  linux/scripts/01-core/wrapped.sh \' \
            '  /opt/scripts/core/wrapped.sh' \
            'RUN bash /opt/scripts/core/wrapped.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "a logical line that is not joined provides nothing and fails a healthy tree"

t_case "an inherited path listed in KNOWN_BASE_PROVIDED is allowed, and only for its Dockerfile"
# Keyed by Dockerfile, so an entry cannot silence the check for every image.
fix="$(_tree media)"
_df "${fix}/linux/Dockerfile.media" 'RUN bash /opt/scripts/toolchain/vulkan.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "vulkan.sh comes from the sdk FROM base"
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.base" 'RUN bash /opt/scripts/toolchain/vulkan.sh'
t_assert_eq "1" "$(t_rc _gate "${fix}")" "the same path is not inherited by Dockerfile.base"

t_case "a tree with no Dockerfiles fails instead of reporting a clean sweep"
fix="$(t_gate_tree verify_script_copy_coverage.py)"
mkdir -p "${fix}/linux"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "zero subjects is a broken checkout, not a pass"
t_assert_contains "$(t_out _gate "${fix}")" "no Dockerfiles found"

t_case "one missing reference in one Dockerfile fails the whole run"
fix="$(_tree)"; _tree_second="${fix}/linux/Dockerfile.media"
printf 'true\n' > "${fix}/linux/scripts/01-core/ok.sh"
_df "${fix}/linux/Dockerfile.base" 'COPY linux/scripts/01-core/ok.sh /opt/scripts/core/ok.sh' \
                                   'RUN bash /opt/scripts/core/ok.sh'
_df "${_tree_second}" 'RUN bash /opt/scripts/core/absent.sh'
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a green Dockerfile must not carry a red one through"
t_assert_contains "${_out}" "missing script reference(s)"

t_case "--report-core-usage is read-only and never fails"
# The report's figure is only a lower bound, so no verdict may hang on it.
fix="$(_tree)"
printf 'true\n' > "${fix}/linux/scripts/01-core/used.sh"
_df "${fix}/linux/Dockerfile.base" 'RUN --mount=type=bind,source=linux/scripts/01-core,target=/opt/scripts/core bash /opt/scripts/core/absent-from-mount.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}" --report-core-usage)" "the report must not inherit the gate's verdict"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "while the gate itself still fails on the same tree"

t_case "the REAL tree is covered today"
t_assert_eq "0" "$(t_rc "${PY}" "${TESTS_DIR}/../verify_script_copy_coverage.py")"

t_summary
