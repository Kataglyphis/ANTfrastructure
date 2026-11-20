#!/usr/bin/env bash
# Stub Cargo/wrapper controls prove stream, argument and failure transport, not real builds, helpers or packages.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare ROOT work out rc
t_fixture_workspace_init work ROOT || exit 1
mkdir -p "${work}/bin" "${work}/driver" "${work}/streams with spaces" || exit
cp "${ROOT}/linux/scripts/02-toolchain/rust/cargo_release.sh" "${work}/driver/" || exit
cp "${TESTS_DIR}/fixtures/cargo-release-wrapper.sh" "${work}/driver/_cargo_wrapper.sh" || exit
cp "${TESTS_DIR}/fixtures/cargo-release-command.py" "${work}/bin/cargo" || exit
chmod +x "${work}/bin/cargo" || exit
declare workspace_messages="${work}/streams with spaces/workspace.jsonl" cli_messages="${work}/streams with spaces/cli.jsonl"

_release_run() {
  : > "${work}/args.jsonl"
  rm -f "${work}/wrapper-marker"
  rm -f "${work}/callback-marker"
  rm -f "${work}/phase-marker"
  t_capture_command out rc env PATH="${work}/bin:${PATH}" \
    CARGO_RELEASE_WORKSPACE_MESSAGES="$1" CARGO_RELEASE_CLI_MESSAGES="$2" \
    CARGO_RELEASE_TEST_WORKSPACE_STATUS="${3:-0}" CARGO_RELEASE_TEST_CLI_STATUS="${4:-0}" \
    CARGO_RELEASE_TEST_WRAPPER_STATUS="${5:-0}" CARGO_RELEASE_TEST_WRAPPER_MARK="${work}/wrapper-marker" \
    CARGO_RELEASE_TEST_CARGO_FUNCTION="${7:-0}" \
    CARGO_RELEASE_TEST_CALLBACK_MARK="${work}/callback-marker" \
    CARGO_RELEASE_TEST_PHASE_MARK="${work}/phase-marker" \
    CARGO_RELEASE_TEST_ARGS="${work}/args.jsonl" \
    timeout --kill-after=1s "${6:-10s}" bash "${work}/driver/cargo_release.sh" --locked --target 'two words' ''
}

_release_args() {
  local format='' count="$2"
  [[ "$1" != json ]] || format='"--message-format=json-render-diagnostics", '
  t_assert_eq "${count}" "$(wc -l < "${work}/args.jsonl" | tr -d ' ')"
  t_assert_eq '["build", '"${format}"'"--release", "--workspace", "--locked", "--target", "two words", ""]' "$(sed -n '1p' "${work}/args.jsonl")"
  if [[ "${count}" == 2 ]]; then
    t_assert_eq '["build", '"${format}"'"--release", "-p", "kataglyphis_cli", "--locked", "--target", "two words", ""]' "$(sed -n '2p' "${work}/args.jsonl")"
  fi
  return 0
}

_release_stream() {
  t_assert_eq 2 "$(wc -l < "$1" | tr -d ' ')"
  t_assert_eq '{"reason": "compiler-artifact", "role": "'"$2"'"}' "$(sed -n '1p' "$1")"
  t_assert_eq '{"reason": "build-finished", "success": '"$3"'}' "$(sed -n '2p' "$1")"
}

t_case 'declared JSON API and unchanged default workspace followed by CLI'
t_assert_eq '# ANT_CARGO_RELEASE_JSON_API=1' "$(sed -n '2p' "${work}/driver/cargo_release.sh")"
_release_run '' ''
t_assert_eq 0 "${rc}"
_release_args normal 2

t_case 'separate successful JSON invocations retain spaces, empty arguments and stderr'
printf stale > "${workspace_messages}"
printf stale > "${cli_messages}"
_release_run "${workspace_messages}" "${cli_messages}"
t_assert_eq 0 "${rc}"
_release_args json 2
_release_stream "${workspace_messages}" workspace true
_release_stream "${cli_messages}" cli true
t_assert_contains "${out}" 'Cargo diagnostic workspace'
t_assert_contains "${out}" 'Cargo diagnostic cli'

t_case 'supplied Cargo shell functions retain caller bindings and full argv'
_release_run "${workspace_messages}" "${cli_messages}" 0 0 0 10s 1
t_assert_eq 0 "${rc}"
_release_args json 2
_release_stream "${workspace_messages}" workspace true
_release_stream "${cli_messages}" cli true

t_case 'wrapper-selected aliases bind after wrapper initialization in both phases'
for capture in console json; do
  if [[ "${capture}" == json ]]; then
    _release_run "${workspace_messages}" "${cli_messages}" 0 0 0 10s alias
    _release_stream "${workspace_messages}" workspace true
    _release_stream "${cli_messages}" cli true
  else
    _release_run '' '' 0 0 0 10s alias
  fi
  t_assert_eq 0 "${rc}"
  _release_args "${capture}" 2
  t_assert_eq 2 "$(wc -l < "${work}/callback-marker" 2>/dev/null || printf 0)"
done

t_case 'the CLI retains an alias changed by the workspace callback'
_release_run "${workspace_messages}" "${cli_messages}" 0 0 0 10s rotate
t_assert_eq 0 "${rc}"
_release_args json 2
_release_stream "${workspace_messages}" workspace true
_release_stream "${cli_messages}" cli true
t_assert_eq $'first\nsecond' "$(cat "${work}/phase-marker")"

t_case 'workspace failure keeps raw status and cannot run the CLI phase'
_release_run "${workspace_messages}" "${cli_messages}" 43
t_assert_eq 43 "${rc}"
_release_args json 1
_release_stream "${workspace_messages}" workspace false
t_assert_ok test ! -s "${cli_messages}"

t_case 'CLI failure keeps raw status and a failed second stream'
_release_run "${workspace_messages}" "${cli_messages}" 0 47
t_assert_eq 47 "${rc}"
_release_args json 2
_release_stream "${workspace_messages}" workspace true
_release_stream "${cli_messages}" cli false

t_case 'wrapper failure sees both previous streams invalidated before Cargo'
_release_run "${workspace_messages}" "${cli_messages}" 0 0 51
t_assert_eq 51 "${rc}"
t_assert_ok test ! -s "${workspace_messages}"
t_assert_ok test ! -s "${cli_messages}"
t_assert_ok test ! -s "${work}/args.jsonl"

t_case 'a single output or aliased outputs refuse before wrapper setup'
for cli in '' "${workspace_messages}" "${work}/unused/../streams with spaces/workspace.jsonl"; do
  _release_run "${workspace_messages}" "${cli}"
  t_assert_eq 2 "${rc}"
  t_assert_ok test ! -e "${work}/wrapper-marker"
  t_assert_ok test ! -s "${work}/args.jsonl"
done
_release_run '' "${cli_messages}"
t_assert_eq 2 "${rc}"

t_case 'hardlinked outputs cannot overwrite one another'
ln "${workspace_messages}" "${work}/hardlink.jsonl" || exit
_release_run "${workspace_messages}" "${work}/hardlink.jsonl"
t_assert_eq 2 "${rc}"
t_assert_ok test ! -e "${work}/wrapper-marker"

t_case 'directories and FIFOs refuse before any output is opened'
mkdir "${work}/not-file" || exit
mkfifo "${work}/pipe" || exit
for invalid in "${work}/not-file" "${work}/pipe"; do
  _release_run "${workspace_messages}" "${invalid}" 0 0 0 2s
  t_assert_eq 2 "${rc}"
  t_assert_ok test ! -e "${work}/wrapper-marker"
done

t_case 'failed parent allocation stops before wrapper or Cargo'
printf file > "${work}/parent-is-file"
_release_run "${workspace_messages}" "${work}/parent-is-file/output.jsonl"
t_assert_eq 1 "${rc}"
t_assert_ok test ! -e "${work}/wrapper-marker"
t_assert_ok test ! -s "${work}/args.jsonl"
t_summary
