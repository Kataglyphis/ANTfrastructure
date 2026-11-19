#!/usr/bin/env bash
# dev-doctor.sh <repo-root>: what is stale in a dev checkout, read-only, one line each. See docs/shared-script-libraries.md#dev-doctorsh--what-is-stale-in-a-dev-checkout
set -uo pipefail

_DOCTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR_FINDINGS=0
DOCTOR_IMAGE_MAX_DAYS="${DOCTOR_IMAGE_MAX_DAYS:-7}"

_finding() { printf 'STALE  %s\n' "$*"; DOCTOR_FINDINGS=$((DOCTOR_FINDINGS + 1)); }
_ok() { printf 'ok     %s\n' "$*"; }
# Not a finding: this host cannot answer, or the value does not decide anything a gate runs.
_note() { printf 'note   %s\n' "$*"; }

# <url>: the public https form of a GitHub remote, so ls-remote needs no loaded key.
_https_url() {
  case "$1" in
    git@github.com:*) printf 'https://github.com/%s\n' "${1#git@github.com:}" ;;
    ssh://git@github.com/*) printf 'https://github.com/%s\n' "${1#ssh://git@github.com/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# <root>: commits the checkout lacks from origin's develop, read with ls-remote; nothing is fetched or written.
_doctor_behind() {
  local root="$1" url tip behind
  url="$(git -C "${root}" config --get remote.origin.url)" || { _note "no origin remote, so nothing to be behind"; return 0; }
  tip="$(git -C "${root}" ls-remote "$(_https_url "${url}")" refs/heads/develop 2>/dev/null | cut -f1)"
  if [ -z "${tip}" ]; then _note "origin's develop could not be read (offline, or no develop branch)"; return 0; fi
  if ! git -C "${root}" cat-file -e "${tip}^{commit}" 2>/dev/null; then
    _finding "origin's develop is at ${tip:0:10}, a commit this clone does not have: fetch, then fast-forward"
    return 0
  fi
  behind="$(git -C "${root}" rev-list --count "HEAD..${tip}")"
  if [ "${behind}" -gt 0 ]; then _finding "HEAD is ${behind} commit(s) behind origin's develop (${tip:0:10})"
  else _ok "HEAD has origin's develop (${tip:0:10})"; fi
}

# <root>: every submodule at the commit its gitlink records, and the hub's hooks wired by an absolute path.
_doctor_checkout() {
  local root="$1" line hooks
  while IFS= read -r line; do
    case "${line:0:1}" in
      -) _finding "submodule ${line#* } is not checked out: git submodule update --init -- ${line#* }" ;;
      +) _finding "submodule $(printf '%s' "${line:1}" | cut -d' ' -f2) is not at its recorded commit: git submodule update" ;;
      U) _finding "submodule $(printf '%s' "${line:1}" | cut -d' ' -f2) has a merge conflict" ;;
    esac
  done < <(git -C "${root}" submodule status 2>/dev/null)
  hooks="$(git -C "${root}" config --get core.hooksPath)"
  case "${hooks}" in
    '') _finding "core.hooksPath is unset, so no hook runs the gates (docs/adopting-in-a-new-project.md#the-git-hooks-by-reference)" ;;
    /*) _ok "core.hooksPath is ${hooks}" ;;
    *) _finding "core.hooksPath ${hooks} is relative, so a linked worktree without the hub runs no hook: set it absolute" ;;
  esac
}

# The local copy of the family CI image, which a month-old pull turns into a hunt for a fixed bug.
_doctor_image() {
  local engine image created age_days
  engine="${DOCTOR_ENGINE:-}"
  if [ -z "${engine}" ]; then
    if command -v nerdctl >/dev/null 2>&1; then engine=nerdctl; elif command -v docker >/dev/null 2>&1; then engine=docker; fi
  fi
  [ -n "${engine}" ] || { _note "no container engine on PATH, so the CI image was not checked"; return 0; }
  image="$(bash "${_DOCTOR_DIR}/ci-image-ref.sh")" || { _note "the CI image reference could not be resolved"; return 0; }
  created="$("${engine}" image inspect --format '{{.Created}}' "${image}" 2>/dev/null | head -n 1)"
  if [ -z "${created}" ]; then _finding "no local copy of ${image}: ${engine} pull ${image}"; return 0; fi
  age_days=$(( ($(date +%s) - $(date -d "${created}" +%s 2>/dev/null || date +%s)) / 86400 ))
  if [ "${age_days}" -gt "${DOCTOR_IMAGE_MAX_DAYS}" ]; then
    _finding "the local ${image} is ${age_days} days old (over ${DOCTOR_IMAGE_MAX_DAYS}): ${engine} pull ${image}"
  else _ok "the local ${image} is ${age_days} day(s) old"; fi
}

# <name> <pinned>: the version a tool on PATH reports, against its pin.
_tool_version() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }

# uv decides what a lock means, so it is a finding; the gates fetch their own pinned linters, so those are notes.
_doctor_tools() {
  local pins="${_DOCTOR_DIR}/01-core" uv_pin have tool pin
  uv_pin="$(sed -n 's/^UV_VERSION=//p' "${pins}/versions.env")"
  have="$(_tool_version uv)"
  if [ -z "${have}" ]; then _note "no uv on PATH; the image carries ${uv_pin}"
  elif [ "${have}" != "${uv_pin}" ]; then _finding "uv on PATH is ${have}, the pin is ${uv_pin}: a lock it cannot read fails as a broken lock"
  else _ok "uv ${have}"; fi
  for tool in shellcheck actionlint gitleaks ruff; do
    pin="$(sed -n "s/^$(printf '%s' "${tool}" | tr '[:lower:]' '[:upper:]')_VERSION=v\{0,1\}//p" "${pins}/tool-pins.env")"
    have="$(_tool_version "${tool}")"
    [ -z "${have}" ] || [ "${have}" = "${pin}" ] \
      || _note "${tool} on PATH is ${have}, the pin is ${pin}; the gates run the pinned one, a run by hand does not"
  done
}

main() {
  [ "$#" -eq 1 ] || { printf 'usage: dev-doctor.sh <repo-root>\n' >&2; exit 2; }
  local root
  root="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'dev-doctor.sh: %s is not a git checkout\n' "$1" >&2; exit 2; }
  printf 'dev-doctor: %s\n' "${root}"
  _doctor_behind "${root}"
  _doctor_checkout "${root}"
  _doctor_image
  _doctor_tools
  if [ "${DOCTOR_FINDINGS}" -gt 0 ]; then
    printf 'dev-doctor: %d stale item(s); nothing was changed\n' "${DOCTOR_FINDINGS}"
    exit 1
  fi
  printf 'dev-doctor: nothing stale\n'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
