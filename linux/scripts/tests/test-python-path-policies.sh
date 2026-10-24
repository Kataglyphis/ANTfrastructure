#!/usr/bin/env bash
# Path policies use executable fixtures and recorded callers, not Python package installs or WebDAV services.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare WORK
t_fixture_workspace_init WORK || exit 1
CORE="${1:-${TESTS_DIR}/../01-core}"
CI="${2:-${TESTS_DIR}/../02-toolchain/python/ci-common.sh}"
# shellcheck source=linux/scripts/01-core/python-probe.sh
source "$CORE/python-probe.sh"
venv="$WORK/venv with spaces"
mkdir -p "$venv/bin" "$venv/Scripts"
printf '#!/bin/sh\nexit 0\n' > "$venv/bin/python"
cp "$venv/bin/python" "$venv/Scripts/python.exe"
chmod +x "$venv/bin/python" "$venv/Scripts/python.exe"
t_case "bin/python wins when both interpreter layouts exist"
t_assert_eq "$venv/bin/python" "$(python_venv_executable "$venv")"
t_case "raw trailing slashes are retained"
t_assert_eq "$venv//bin/python" "$(python_venv_executable "$venv/")"
chmod -x "$venv/bin/python"
t_case "a nonexecutable POSIX interpreter falls through to Scripts/python.exe"
t_assert_eq "$venv/Scripts/python.exe" "$(python_venv_executable "$venv")"
chmod -x "$venv/Scripts/python.exe"
t_case "a broken venv fails without returning a broken path"
t_assert_rc 1 python_venv_executable "$venv"
t_assert_eq '' "$(python_venv_executable "$venv")"
chmod +x "$venv/bin/python" "$venv/Scripts/python.exe"

_run_uv() { bash -c 'source "$1/python_uv.sh"; eval "$2"' _ "$CORE" "$1"; }
t_case "UV names the venv failure before inspecting requirements"
output="$(_run_uv 'uv_pip_install_requirements /missing/venv /missing/requirements' 2>&1)"
t_assert_contains "$output" 'No usable venv at /missing/venv'
t_assert_rc 1 _run_uv 'uv_pip_install_requirements /missing/venv /missing/requirements'
t_case "UV names missing requirements after selecting an executable venv"
# The selected path is supplied as an environment value, so shell spaces stay observable.
output="$(FIXTURE_VENV="$venv" _run_uv 'uv_pip_install_requirements "$FIXTURE_VENV" /missing/requirements' 2>&1)"
t_assert_contains "$output" 'Requirements file not found: /missing/requirements'
: > "$WORK/requirements.txt"
t_case "UV forwards its selected interpreter and requirements as individual arguments"
output="$(FIXTURE_VENV="$venv" FIXTURE_REQ="$WORK/requirements.txt" _run_uv '
  uv() { printf "ARG:%s\n" "$@"; }
  uv_pip_install_requirements "$FIXTURE_VENV" "$FIXTURE_REQ"
')"
t_assert_contains "$output" "ARG:$venv/bin/python"
t_assert_contains "$output" "ARG:$WORK/requirements.txt"
t_assert_contains "$output" 'ARG:--python'

t_source_functions "$CORE/python_uv.sh" python_workspace_prefer_mount detect_workspace
mount="$WORK/bind mount"
mkdir -p "$mount"
WORKSPACE_ROOT=original
t_case "a directory without pyproject never replaces the caller workspace"
python_workspace_prefer_mount "$mount"
t_assert_eq original "$WORKSPACE_ROOT"
: > "$mount/pyproject.toml"
t_case "a real pyproject bind mount wins without canonicalizing its raw path"
python_workspace_prefer_mount "$mount/"
t_assert_eq "$mount/" "$WORKSPACE_ROOT"
rm "$mount/pyproject.toml"; mkdir "$mount/pyproject.toml"
WORKSPACE_ROOT=original
python_workspace_prefer_mount "$mount"
t_assert_eq original "$WORKSPACE_ROOT"
rmdir "$mount/pyproject.toml"; : > "$mount/pyproject.toml"

t_case "detect_workspace applies the mount after caller fallback and exports its result"
output="$(FIXTURE_MOUNT="$mount" _run_uv '
  info() { :; }
  python_workspace_prefer_mount() { printf "before:%s\n" "$WORKSPACE_ROOT"; WORKSPACE_ROOT="$FIXTURE_MOUNT"; }
  WORKSPACE_ROOT=caller-default
  detect_workspace
  bash -c '\''printf "export:%s" "$WORKSPACE_ROOT"'\''
')"
t_assert_contains "$output" 'before:caller-default'
t_assert_contains "$output" "export:$mount"
mkdir -p "$mount/flutter/bin"
t_case "CI selects the mount before cd, Flutter PATH and best-effort git setup"
output="$(bash -c '
  source "$1"
  fixture_mount="$2"
  python_workspace_prefer_mount() { WORKSPACE_ROOT="$fixture_mount"; }
  git() { printf "git:%s|cwd:%s\n" "$*" "$PWD"; return 1; }
  prepare_ci_workspace --cd
  printf "path:%s" "${PATH%%:*}"
' _ "$CI" "$mount")"
t_assert_contains "$output" "git:config --global --add safe.directory $mount|cwd:$mount"
t_assert_contains "$output" "path:$mount/flutter/bin"

_run_webdav() { bash -c 'source "$1/webdav-download.sh"; eval "$2"' _ "$CORE" "$1"; }
t_case "WebDAV requires credentials before checking for a venv"
output="$(_run_webdav '
  unset WEBDAV_HOSTNAME WEBDAV_USERNAME WEBDAV_PASSWORD
  webdav_download_tree remote local
' 2>&1)"
t_assert_contains "$output" 'WEBDAV_HOSTNAME is not set'
t_case "WebDAV retains its own missing-interpreter diagnostic"
output="$(WEBDAV_HOSTNAME=fixture WEBDAV_USERNAME=fixture WEBDAV_PASSWORD=fixture WEBDAV_VENV_DIR=/missing/venv _run_webdav '
  load_versions_env() { WEBDAVCLIENT_REF=fixture; }
  webdav_download_tree remote local
' 2>&1)"
t_assert_contains "$output" 'no interpreter in /missing/venv'
printf '#!/bin/sh\nprintf "DOWNLOADER_EXECUTED\\n"\n' > "$venv/bin/python"
t_case "a failed WebDAV client install stays fatal and does not execute the downloader"
output="$(WEBDAV_HOSTNAME=fixture WEBDAV_USERNAME=fixture WEBDAV_PASSWORD=fixture WEBDAV_VENV_DIR="$venv" _run_webdav '
  load_versions_env() { WEBDAVCLIENT_REF=fixture; }
  uv() { return 17; }
  webdav_download_tree remote local
' 2>&1)"
status=$?
t_assert_eq 1 "$status"
t_assert_rc 1 grep -Fq DOWNLOADER_EXECUTED <<< "$output"

t_case "Python CI fixture construction carries the required probe companion"
t_assert_ok bash -c '
  source "$1/test-harness.sh"
  source "$1/python-ci-fixture.sh"
  python_ci_fixture "$2/ci closure" "$3" || exit
  test -f "$TREE/01-core/python-probe.sh" || exit
  source "$TREE/01-core/python_uv.sh"
  declare -F python_venv_executable >/dev/null
' _ "$TESTS_DIR" "$WORK" "$CORE/.."

for module in python_uv.sh webdav-download.sh; do
  bundle="$WORK/$module bundle"
  mkdir -p "$bundle"
  cp "$CORE/$module" "$CORE/logging.sh" "$CORE/load-versions-env.sh" "$CORE/verified-script-install.sh" "$bundle/"
  t_case "$module refuses a copied closure missing python-probe.sh"
  t_assert_rc 73 bash -c 'if source "$1"; then exit 0; else exit 73; fi' _ "$bundle/$module"
  cp "$CORE/python-probe.sh" "$bundle/"
  t_case "$module loads when its shared companion is carried"
  t_assert_ok bash -c 'source "$1"; declare -F python_venv_executable >/dev/null' _ "$bundle/$module"
done
bundle="$WORK/ci import"
mkdir -p "$bundle/01-core" "$bundle/02-toolchain/python"
cp "$CORE/python_uv.sh" "$CORE/logging.sh" "$CORE/verified-script-install.sh" "$bundle/01-core/"
cp "$CI" "$bundle/02-toolchain/python/ci-common.sh"
t_case "conditional CI imports propagate a missing uv companion"
t_assert_rc 73 bash -c 'if source "$1"; then exit 0; else exit 73; fi' _ "$bundle/02-toolchain/python/ci-common.sh"
cp "$CORE/python-probe.sh" "$bundle/01-core/"
t_case "complete CI import closures load without running workspace preparation"
t_assert_ok bash -c 'source "$1"; declare -F prepare_ci_workspace >/dev/null' _ "$bundle/02-toolchain/python/ci-common.sh"

t_summary
