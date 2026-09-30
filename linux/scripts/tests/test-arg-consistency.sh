#!/usr/bin/env bash
# Exit codes too, so advisory and hard sections cannot swap. See docs/code-quality-tooling.md#version-arg-consistency-arg-consistency
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _tree: the gate, what it sources, and inputs enough to clear its own vacuity floor.
_tree() {
  local d; d="$(mktemp -d "${_work}/tree.XXXXXX")"
  mkdir -p "${d}/linux/scripts/01-core" "${d}/linux/scripts/02-toolchain" \
           "${d}/linux/scripts/tests" "${d}/linux/scripts/03-media/build"
  install -m 0755 "${CORE}/verify-arg-consistency.sh" "${d}/linux/scripts/01-core/"
  install -m 0644 "${CORE}/version-forwarding.sh" "${CORE}/build-helpers.sh" \
    "${d}/linux/scripts/01-core/"
  printf 'GCC_VERSION=16.2.0\nLLVM_RELEASE=22.1.8\nFOO_VERSION=1.2.3\n# noforward\nHOST_ONLY=7\n' \
    > "${d}/linux/scripts/01-core/versions.env"
  printf 'llvm_release_version() { case "$1" in 22) echo 22.1.8 ;; esac; }\n' \
    > "${d}/linux/scripts/01-core/common.sh"
  printf 'gcc_default() {\n  case "$1" in\n      16) default_full_version="16.2.0" ;;\n  esac\n}\n' \
    > "${d}/linux/scripts/02-toolchain/gcc.sh"
  _gcc_sites "${d}" 12 16.2.0
  printf 'ARG GCC_VERSION=16.2.0\nARG FOO_VERSION=1.2.3\n' > "${d}/linux/Dockerfile.base"
  printf 'ARG GCC_VERSION=16.2.0\n' > "${d}/linux/Dockerfile.media"
  printf '%s' "${d}"
}

# _gcc_sites <tree> <count> <literal>: assembled from parts, as a literal under linux/ would be scanned as real.
_gcc_sites() {
  local d="$1" n="$2" lit="$3" i
  : > "${d}/linux/scripts/01-core/toolchain-paths.sh"
  for ((i = 0; i < n; i++)); do
    printf 'P%d="/opt/gcc-${%s:-%s}/bin"\n' "${i}" GCC_VERSION "${lit}" \
      >> "${d}/linux/scripts/01-core/toolchain-paths.sh"
  done
}

_gate() { bash "$1/linux/scripts/01-core/verify-arg-consistency.sh"; }

t_case "a consistent tree passes every section"
fix="$(_tree)"
_out="$(t_out _gate "${fix}")"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the gate must be able to be green, or the reds below prove nothing"
t_assert_contains "${_out}" "All ARG defaults match versions.env"
t_assert_contains "${_out}" "DONE: version ARG consistency check"

t_case "an ARG default that drifts from versions.env is FATAL"
fix="$(_tree)"
printf 'ARG FOO_VERSION=9.9.9\n' > "${fix}/linux/Dockerfile.media"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a stale ARG default wins silently on a plain docker build"
t_assert_contains "${_out}" "DRIFT: linux/Dockerfile.media ARG FOO_VERSION=9.9.9"
# The generator stays unnamed: the gate registry credits any suite that mentions a gate's script.
t_assert_contains "${_out}" "Run: python3 docs/scripts/sync" "the message has to name the fix"

t_case "an ARG derived from another ARG is skipped, not reported as drift"
fix="$(_tree)"
printf 'ARG GCC_VERSION=16.2.0\nARG FOO_VERSION=${GCC_VERSION}\n' > "${fix}/linux/Dockerfile.media"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "there is no literal to compare, and flagging it would be a permanent false red"

t_case "a default-LESS ARG naming a versions.env variable is FATAL"
# A plain `docker build` would get an empty value.
fix="$(_tree)"
printf 'ARG GCC_VERSION=16.2.0\nARG FOO_VERSION\n' > "${fix}/linux/Dockerfile.media"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" "declares ARG FOO_VERSION with no default anywhere in the file"

t_case "a stage-level re-declaration is covered by the file's own global default"
fix="$(_tree)"
printf 'ARG FOO_VERSION=1.2.3\nFROM base AS x\nARG FOO_VERSION\nARG GCC_VERSION=16.2.0\n' \
  > "${fix}/linux/Dockerfile.media"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the pre-FROM default is what the re-declaration inherits"

t_case "the two advisory sections WARN and do not fail"
# Advisory: # noforward is an orchestrator hint, and a standalone script default may pin a branch.
_advisory() {  # <what the fixture plants> <expected phrase>
  fix="$(_tree)"
  case "$1" in
    noforward) printf 'ARG GCC_VERSION=16.2.0\nARG HOST_ONLY=7\n' > "${fix}/linux/Dockerfile.media" ;;
    # Assembled by printf: a literal fallback under linux/scripts is a real knob to the env-knobs gate.
    script)    printf 'V="${%s:-0.0.1}"\n' FOO_VERSION > "${fix}/linux/scripts/01-core/standalone.sh" ;;
  esac
  t_assert_contains "$(t_out _gate "${fix}")" "$2"
  t_assert_eq "0" "$(t_rc _gate "${fix}")" "the $1 scan must stay out of the exit code"
}
_advisory noforward "ARG 'HOST_ONLY' consumes a versions.env value that is not forwarded"
_advisory script "WARN drift:"

t_case "the gcc.sh case mapping is pinned to versions.env"
fix="$(_tree)"
sed -i 's/16.2.0/16.1.0/' "${fix}/linux/scripts/02-toolchain/gcc.sh"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a case arm that overrides the real version drifts where no ARG check can see it"
t_assert_contains "${_out}" "gcc.sh case default for major 16 does not map to 16.2.0"

t_case "the common.sh llvm mapping is pinned too"
fix="$(_tree)"
printf 'llvm_release_version() { case "$1" in 22) echo 22.0.0 ;; esac; }\n' \
  > "${fix}/linux/scripts/01-core/common.sh"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "common.sh llvm_release_version mapping does not contain 22.1.8"

t_case "an inline GCC fallback that drifts is FATAL, not advisory"
# These all name one /opt/gcc-<ver> toolchain, so no divergence is legitimate.
fix="$(_tree)"
_gcc_sites "${fix}" 12 16.1.0
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" "expected GCC_VERSION default 16.2.0"

t_case "a scan that stops matching the tree FAILS instead of reporting a clean pass"
# The anti-vacuity floor: literals rewritten past the pattern must not print OK.
fix="$(_tree)"
_gcc_sites "${fix}" 3 16.2.0
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "zero findings from a broken pattern must never read as zero problems"
t_assert_contains "${_out}" "scanned only 3 site(s)"
t_assert_contains "${_out}" "fix the pattern rather than trusting this pass"

t_case "the scanned-site count is reported even when the gate passes"
fix="$(_tree)"
t_assert_contains "$(t_out _gate "${fix}")" "Scanned 12 inline GCC version default(s)"

t_case "a hand-forward of an auto-forwarded variable is FATAL"
# XC7: append_version_build_args already forwards it; a second channel diverges.
fix="$(_tree)"
printf 'nerdctl build --build-arg FOO_VERSION="${FOO_VERSION}" .\n' \
  > "${fix}/linux/scripts/01-core/build-it.sh"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" "hand-forward duplicates auto-forwarding"

t_case "tests/ is excluded from the hand-forward scan"
# A suite quotes the pattern as assertion text.
fix="$(_tree)"
printf 'assert "--build-arg FOO_VERSION=x"\n' > "${fix}/linux/scripts/tests/test-thing.sh"
t_assert_eq "0" "$(t_rc _gate "${fix}")"

t_case "the REAL tree is consistent today"
t_assert_eq "0" "$(t_rc bash "${CORE}/verify-arg-consistency.sh")"

t_summary
