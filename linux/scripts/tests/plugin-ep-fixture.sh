#!/usr/bin/env bash
# The plugin EP suites' shared preamble (EP_SCRIPT=<script> source it; leaves TESTS_DIR, EP, ENVF, _T, VERIFY): the harness, the sourced script with its CLI inert, versions.env and a private work tree.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
EP="${TESTS_DIR}/../03-media/build/onnxruntime/build/${EP_SCRIPT:?EP_SCRIPT names the plugin build script}"
ENVF="${TESTS_DIR}/../01-core/versions.env"
_T="$(mktemp -d)"
trap 'rm -rf "${_T}"' EXIT
# shellcheck source=/dev/null
source "${EP}"
# The build scripts turn errexit on when sourced; the harness counts failures itself.
set +e
# shellcheck source=linux/scripts/01-core/load-versions-env.sh
source "${TESTS_DIR}/../01-core/load-versions-env.sh"
load_versions_env "${ENVF}"
VERIFY="${TESTS_DIR}/../03-media/runtime/verify-media-artifacts.sh"
# _verify <stage> <prefix>: the media verify stage over a fixture tree, its output in _out and its status in _rc.
_out=""; _rc=0
_verify() { _out="$(bash "${VERIFY}" "$@" 2>&1)"; _rc=$?; }
