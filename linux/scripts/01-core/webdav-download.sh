#!/usr/bin/env bash
# webdav-download.sh - pull a WebDAV tree into a local directory.
#
# The bash half of download-webdav-files.py, for the Linux lanes. Its PowerShell
# twin is WindowsWebDav.Common.psm1's Invoke-EarlyWebDavDownload; both run the
# same script and both install the same PINNED client, so "which WebDavClient
# did this run use" has one answer (WEBDAVCLIENT_REF, 01-core/versions.env)
# instead of "whatever the default branch was that day".
#
# Credentials come from the environment and are never arguments:
#   WEBDAV_HOSTNAME, WEBDAV_USERNAME, WEBDAV_PASSWORD
# A password on a command line is in every `ps` listing and in every CI log line
# that echoes the command.
#
# docs/shared-script-libraries.md#01-corewebdav-downloadsh
#
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.

[ -n "${_WEBDAV_DOWNLOAD_SH_LOADED:-}" ] && return 0
_WEBDAV_DOWNLOAD_SH_LOADED=1

_webdav_core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./logging.sh
source "${_webdav_core_dir}/logging.sh"
# shellcheck source=./load-versions-env.sh
source "${_webdav_core_dir}/load-versions-env.sh"

# webdav_download_tree <remote> <local> [extension|all] -> 0, or 1 by name.
#
# The venv resolution is the one from the consumer copies, kept because it is
# load-bearing: --python forces the WRITABLE local environment. The image bakes
# a root-owned /opt/venv and exports UV_PYTHON at it, so a plain `uv pip
# install` inside an activated .venv still targets /opt/venv and dies with
# "Permission denied (os error 13)" for the uid 1001 build user.
webdav_download_tree() {
  local remote="${1:?remote base path required}"
  local local_dir="${2:?local base path required}"
  local extension="${3:-all}"
  local venv_root="${KATAGLYPHIS_REPO_ROOT:-}"
  [ -n "${venv_root}" ] || venv_root="$(pwd)"
  local venv="${WEBDAV_VENV_DIR:-${venv_root}/.venv}"
  local script="${_webdav_core_dir}/download-webdav-files.py"
  local venv_python

  : "${WEBDAV_HOSTNAME:?WEBDAV_HOSTNAME is not set}"
  : "${WEBDAV_USERNAME:?WEBDAV_USERNAME is not set}"
  : "${WEBDAV_PASSWORD:?WEBDAV_PASSWORD is not set}"

  [ -f "${script}" ] || { err "download-webdav-files.py is missing at ${script}"; return 1; }

  load_versions_env "${_webdav_core_dir}/versions.env"
  : "${WEBDAVCLIENT_REF:?WEBDAVCLIENT_REF is not set in 01-core/versions.env}"

  # bin/python is the POSIX venv layout; a Git Bash venv carries
  # Scripts/python.exe. Missing both is a broken venv and fails HERE by name,
  # not as a confusing resolver error two commands later.
  venv_python="${venv}/bin/python"
  [ -x "${venv_python}" ] || venv_python="${venv}/Scripts/python.exe"
  if [ ! -x "${venv_python}" ]; then
    err "no interpreter in ${venv} (neither bin/python nor Scripts/python.exe); create it with uv_venv_create first"
    return 1
  fi

  # The commit's source archive, not git+https: the same form as
  # Get-WebDavClientRequirement in WindowsWebDav.Common.psm1, whose comment says
  # why (the pinned commit's submodule chain overflows Git for Windows).
  info "installing kataglyphis_webdavclient @ ${WEBDAVCLIENT_REF}"
  uv pip install --python "${venv_python}" \
    "kataglyphis_webdavclient @ https://github.com/Kataglyphis/WebDavClient/archive/${WEBDAVCLIENT_REF}.tar.gz" || return 1

  info "webdav: ${remote} -> ${local_dir} (extension: ${extension})"
  "${venv_python}" "${script}" \
    "${WEBDAV_HOSTNAME}" "${WEBDAV_USERNAME}" "${WEBDAV_PASSWORD}" \
    "${remote}" "${local_dir}" --extension "${extension}"
}
