#!/usr/bin/env bash
# The stub refuses stale streams before it publishes a synthetic wrapper state.
: > "${CARGO_RELEASE_TEST_WRAPPER_MARK}"
if [[ -n "${CARGO_RELEASE_WORKSPACE_MESSAGES:-}" ]]; then
  [[ ! -s "${CARGO_RELEASE_WORKSPACE_MESSAGES}" && ! -s "${CARGO_RELEASE_CLI_MESSAGES}" ]] || return 53
fi
export CARGO_RELEASE_TEST_WRAPPER=loaded
info() { printf 'INFO %s\n' "$*"; }
if [[ "${CARGO_RELEASE_TEST_CARGO_FUNCTION}" != 0 ]]; then
  messages=caller-binding
  cargo_release_test_command() {
    [[ "${messages}" == caller-binding ]] || return 93
    printf 'call\n' >> "${CARGO_RELEASE_TEST_CALLBACK_MARK}"
    command cargo "$@"
  }
  cargo_release_test_first() {
    printf 'first\n' >> "${CARGO_RELEASE_TEST_PHASE_MARK}"
    cargo_release_test_command "$@" || return
    alias cargo=cargo_release_test_second
  }
  cargo_release_test_second() {
    printf 'second\n' >> "${CARGO_RELEASE_TEST_PHASE_MARK}"
    cargo_release_test_command "$@"
  }
  case "${CARGO_RELEASE_TEST_CARGO_FUNCTION}" in
    1) cargo() { cargo_release_test_command "$@"; } ;;
    alias) shopt -s expand_aliases; alias cargo=cargo_release_test_command ;;
    rotate) shopt -s expand_aliases; alias cargo=cargo_release_test_first ;;
    *) return 54 ;;
  esac
fi
return "${CARGO_RELEASE_TEST_WRAPPER_STATUS}"
