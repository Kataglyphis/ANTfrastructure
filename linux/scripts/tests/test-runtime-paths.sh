#!/usr/bin/env bash
# Tests for verify-runtime-paths.sh. LOG31: this gate once NEVER failed -- an
# inner warning swallowed by an outer green. Its contract since is deliberately
# split, and BOTH halves need proving: a missing tracked file FAILS hard, while
# every path-mismatch WARN stays advisory because the extraction is heuristic.
# A suite that only pinned the WARN text would leave the toothless half toothless.
# docs/code-quality-tooling.md#runtime-path-consistency-runtime-paths
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
CORE="${TESTS_DIR}/../01-core"
GATE="${TESTS_DIR}/../04-runtime/verify-runtime-paths.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _tree: a throwaway repo root with the gate at its real depth and the four files
# it declares as infrastructure. The loader is the real one -- the fixture proves
# the gate's own logic, not a reimplementation of versions.env parsing.
_tree() {
  local d; d="$(gate_tree_here "${_work}" "${GATE}" linux/scripts/04-runtime/verify-runtime-paths.sh)"
  install -D -m 0644 "${CORE}/load-versions-env.sh" "${d}/linux/scripts/01-core/load-versions-env.sh"
  printf 'GCC_VERSION=16.2.0\nOPENCV_OUTPUT_DIR=/opt/opencv5\n' \
    > "${d}/linux/scripts/01-core/versions.env"
  printf 'GCC_PREFIX=/opt/gcc-${GCC_VERSION}\nPATH_OPENCV=/opt/opencv5/bin\nPATH_FFMPEG=/opt/ffmpeg/bin\n' \
    > "${d}/linux/scripts/04-runtime/runtime-paths.env"
  _dockerfile "${d}" package /opt/opencv5/bin /opt/ffmpeg/bin
  _dockerfile "${d}" media /opt/opencv5/bin /opt/ffmpeg/bin
  printf '%s' "${d}"
}

# _dockerfile <tree> <package|media> <path>... — one ENV block carrying the paths.
_dockerfile() {
  local d="$1" name="$2" p n=0
  shift 2
  : > "${d}/linux/Dockerfile.${name}"
  for p in "$@"; do
    n=$((n + 1))
    printf 'ENV SOME_PATH_%d=%s\n' "${n}" "${p}" >> "${d}/linux/Dockerfile.${name}"
  done
  printf 'RUN true\n' >> "${d}/linux/Dockerfile.${name}"
}

_gate() { bash "$1/linux/scripts/04-runtime/verify-runtime-paths.sh"; }

t_case "a consistent tree passes"
fix="$(_tree)"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the gate must be able to be green, or the reds below prove nothing"
t_assert_contains "$(t_out _gate "${fix}")" "Done: path-mismatch WARN lines above are advisory"

t_case "each tracked file the gate declares as infrastructure FAILS hard when it is gone"
# A rename that silently drops half the comparison is the LOG31 shape: the check
# still printed a green summary while checking nothing.
for _missing in linux/scripts/04-runtime/runtime-paths.env \
                linux/scripts/01-core/versions.env \
                linux/Dockerfile.package \
                linux/Dockerfile.media; do
  fix="$(_tree)"
  rm -f "${fix}/${_missing}"
  t_assert_eq "1" "$(t_rc _gate "${fix}")" "a missing ${_missing} must not be a warning"
  t_assert_contains "$(t_out _gate "${fix}")" "required file missing"
done

t_case "the infra check reports ALL missing files, not just the first"
fix="$(_tree)"
rm -f "${fix}/linux/Dockerfile.package" "${fix}/linux/Dockerfile.media"
_out="$(t_out _gate "${fix}")"
t_assert_contains "${_out}" "Dockerfile.package"
t_assert_contains "${_out}" "Dockerfile.media" "an early exit sends the reader back for a second run"
t_assert_contains "${_out}" "(LOG31)"

t_case "a path mismatch is ADVISORY: it WARNs and the gate still exits 0"
# The extraction is a heuristic over ENV blocks and produces false positives on a
# healthy tree (ARG-composed paths, unexpanded refs). Promoting these to failures
# is the tempting tightening that would make the gate unusable, not stronger.
fix="$(_tree)"
_dockerfile "${fix}" media /opt/opencv5/bin
_out="$(t_out _gate "${fix}")"
t_assert_contains "${_out}" "WARN: linux/Dockerfile.media missing canonical path: /opt/ffmpeg/bin"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the advisory half must never become an exit code"

t_case "a canonical path outside /opt and /usr/local does not even WARN"
fix="$(_tree)"
printf 'PATH_ELSEWHERE=/srv/nowhere/bin\n' >> "${fix}/linux/scripts/04-runtime/runtime-paths.env"
t_assert_eq "0" "$(t_rc _gate "${fix}")"
t_assert_eq "0" "$(t_out _gate "${fix}" | grep -c -e '/srv/nowhere')" \
  "the WARN case list is narrow on purpose; widening it floods a healthy tree"

t_case "a canonical path is expanded from versions.env before it is compared"
# A version embedded MID-path is where the expansion is load-bearing: the
# ${...}-stripping alone turns /opt/${GCC_VERSION}-tools into /opt/-tools, which
# is still an /opt path, still absent, and therefore a WARN about a path the
# Dockerfile does carry.
fix="$(_tree)"
printf 'PATH_GCC_TOOLS=/opt/${GCC_VERSION}-tools\n' >> "${fix}/linux/scripts/04-runtime/runtime-paths.env"
_dockerfile "${fix}" package /opt/opencv5/bin /opt/ffmpeg/bin /opt/16.2.0-tools
_dockerfile "${fix}" media /opt/opencv5/bin /opt/ffmpeg/bin /opt/16.2.0-tools
t_assert_eq "0" "$(t_out _gate "${fix}" | grep -c -e 'missing canonical path: /opt/')" \
  "an unexpanded canonical path WARNs about something that is right there"

t_case "the two Dockerfiles' /opt divergence is reported, and is not a failure"
fix="$(_tree)"
_dockerfile "${fix}" package /opt/opencv5/bin /opt/ffmpeg/bin /opt/package-only
_out="$(t_out _gate "${fix}")"
t_assert_contains "${_out}" "paths only in Dockerfile.package: /opt/package-only"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "Dockerfile.package vs .media /opt divergence is legitimate"

t_case "the REAL tree passes the infrastructure half today"
t_assert_eq "0" "$(t_rc bash "${GATE}")"

t_summary
