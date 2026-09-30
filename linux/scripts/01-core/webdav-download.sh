#!/usr/bin/env bash
# Credentials only via WEBDAV_* env, never argv. docs/shared-script-libraries.md#01-corewebdav-downloadsh

[ -n "${_WEBDAV_DOWNLOAD_SH_LOADED:-}" ] && return 0
_WEBDAV_DOWNLOAD_SH_LOADED=1

_webdav_core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./logging.sh
source "${_webdav_core_dir}/logging.sh"
# shellcheck source=./load-versions-env.sh
source "${_webdav_core_dir}/load-versions-env.sh"

# webdav_download_tree <remote> <local> [extension|all]; --python beats the image's UV_PYTHON=/opt/venv.
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

  # Git Bash venvs carry Scripts/python.exe; a broken venv fails here by name, not later in the resolver.
  venv_python="${venv}/bin/python"
  [ -x "${venv_python}" ] || venv_python="${venv}/Scripts/python.exe"
  if [ ! -x "${venv_python}" ]; then
    err "no interpreter in ${venv} (neither bin/python nor Scripts/python.exe); create it with uv_venv_create first"
    return 1
  fi

  # The source archive, not git+https: the pinned commit's submodule chain overflows Git for Windows.
  info "installing kataglyphis_webdavclient @ ${WEBDAVCLIENT_REF}"
  uv pip install --python "${venv_python}" \
    "kataglyphis_webdavclient @ https://github.com/Kataglyphis/WebDavClient/archive/${WEBDAVCLIENT_REF}.tar.gz" || return 1

  info "webdav: ${remote} -> ${local_dir} (extension: ${extension})"
  "${venv_python}" "${script}" \
    "${WEBDAV_HOSTNAME}" "${WEBDAV_USERNAME}" "${WEBDAV_PASSWORD}" \
    "${remote}" "${local_dir}" --extension "${extension}"
}
