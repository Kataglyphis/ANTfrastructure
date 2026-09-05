#!/usr/bin/env bash
# Tests for verify-android-stage-parity.sh. The five android library stages are
# copy-paste on purpose, so the gate's job is to make the copy mechanical: it must
# go RED on a real divergence and on a stage it can no longer find, and stay green
# on the two differences that are deliberate (the ANDROID_LIB value, and comments).
# docs/code-quality-tooling.md#android-library-stage-parity-android-parity
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
GATE="${TESTS_DIR}/../01-core/verify-android-stage-parity.sh"
STAGES="android-gstreamer android-onnx android-litert android-opencv android-iree"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _tree: a throwaway repo root holding the real gate at its real depth, since it
# derives the Dockerfile path from its own location.
_tree() { gate_tree_here "${_work}" "${GATE}" linux/scripts/01-core/verify-android-stage-parity.sh; }

# _dockerfile <tree> [<stage>=<extra body line>]... — five stages, each with the
# copy-paste body, plus whatever extra line the caller pins on a named stage.
_dockerfile() {
  local d="$1" stage extra pair
  shift
  : > "${d}/linux/Dockerfile.android"
  for stage in ${STAGES}; do
    extra=""
    for pair in "$@"; do
      case "${pair}" in "${stage}="*) extra="${pair#*=}" ;; esac
    done
    {
      printf 'FROM android-sdk AS %s\n\n' "${stage}"
      printf 'ARG TARGET_ARCH\n'
      printf 'ARG ANDROID_LIB=%s\n' "${stage#android-}"
      printf 'COPY linux/scripts/03-media/build/${ANDROID_LIB}/android/ /opt/scripts/\n'
      [ -z "${extra}" ] || printf '%s\n' "${extra}"
      printf '\n'
    } >> "${d}/linux/Dockerfile.android"
  done
}

_gate() { bash "$1/linux/scripts/01-core/verify-android-stage-parity.sh"; }

t_case "five copy-paste stages differing only in ANDROID_LIB pass"
# The gate must be able to be GREEN, or every red below proves only that it is broken.
fix="$(_tree)"; _dockerfile "${fix}"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the deliberate difference is the ANDROID_LIB value itself"
t_assert_contains "$(t_out _gate "${fix}")" "All 5 android library stages are identical"

t_case "a real divergence in ONE stage fails, and names it"
fix="$(_tree)"; _dockerfile "${fix}" "android-onnx=RUN echo drifted"
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "printing a diff and exiting 0 is the failure mode this gate is for"
t_assert_contains "${_out}" "stage 'android-onnx' diverges"
t_assert_contains "${_out}" "android library stages have drifted apart"

t_case "a divergence in the LAST stage fails too"
# The first stage becomes the reference; a loop that stopped comparing after the
# first match would let the tail of the list drift untouched.
fix="$(_tree)"; _dockerfile "${fix}" "android-iree=RUN echo drifted"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "stage 'android-iree' diverges"

t_case "two stages drifting the SAME way still fail: parity is against the reference"
fix="$(_tree)"; _dockerfile "${fix}" "android-onnx=RUN echo drifted" "android-litert=RUN echo drifted"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
_out="$(t_out _gate "${fix}")"
t_assert_contains "${_out}" "android-onnx"
t_assert_contains "${_out}" "android-litert" "a majority is not the reference; the first stage is"

t_case "a renamed or deleted stage FAILS, it does not quietly check four"
# The gate's own STAGES list is the contract. A stage it cannot find is a check
# that silently stopped covering a fifth of the Dockerfile -- and the FIRST stage
# going missing must not simply promote the second to reference.
for _gone in android-opencv android-gstreamer; do
  fix="$(_tree)"; _dockerfile "${fix}"
  sed -i "s/^FROM android-sdk AS ${_gone}\$/FROM android-sdk AS ${_gone}-renamed/" \
    "${fix}/linux/Dockerfile.android"
  t_assert_eq "1" "$(t_rc _gate "${fix}")" "a missing ${_gone} must not be skipped"
  t_assert_contains "$(t_out _gate "${fix}")" "stage '${_gone}' not found"
done

t_case "comments and blank lines are normalized away, and are not drift"
fix="$(_tree)"; _dockerfile "${fix}" "android-litert=# a note about litert only"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "a per-stage comment is the point of keeping them separate stages"

t_case "a stage block ends at the next FROM: the next stage's body is not borrowed"
# Without that boundary the reference would swallow every later stage and the
# comparison would be a stage against itself -- green whatever drifted.
fix="$(_tree)"; _dockerfile "${fix}"
printf 'FROM scratch AS unrelated\nRUN echo not-a-library-stage\n' >> "${fix}/linux/Dockerfile.android"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "an unrelated trailing stage must not attach to android-iree"
sed -i 's/^RUN echo not-a-library-stage$/RUN echo changed/' "${fix}/linux/Dockerfile.android"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "and editing it must not move the verdict"

t_case "the REAL Dockerfile.android is in parity today"
t_assert_eq "0" "$(t_rc bash "${GATE}")"

t_summary
