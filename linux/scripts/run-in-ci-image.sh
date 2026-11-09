#!/usr/bin/env bash
# run-in-ci-image.sh <repo-root> [options] -- <cmd...> in the CI image. See docs/shared-script-libraries.md#run-in-ci-imagesh--run-a-command-in-the-ci-image
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=linux/scripts/lib/cli-value-options.sh
source "${_SCRIPT_DIR}/lib/cli-value-options.sh"

die() { printf 'run-in-ci-image.sh: %s\n' "$*" >&2; exit 2; }

REPO_ROOT=""
ENGINE=""
IMAGE=""
PLATFORM=""
WORKDIR="/workspace"
NAME=""
USER_SPEC=""
KEEP=0
MOUNT_HUB=0
CMD=()

[ "$#" -ge 1 ] || die "the repo root is required (got no arguments)"
REPO_ROOT="$(cd "$1" 2>/dev/null && pwd)" || die "repo root not found: $1"
shift

declare -A CI_IMAGE_VALUE_OPTIONS=(
  [--image]=IMAGE [--engine]=ENGINE [--platform]=PLATFORM
  [--workdir]=WORKDIR [--name]=NAME [--user]=USER_SPEC
)
while [ "$#" -gt 0 ]; do
  if [ -n "${CI_IMAGE_VALUE_OPTIONS[$1]:-}" ]; then
    [ -n "${2-}" ] || die "$1 needs a nonempty value"
    assign_cli_value_option CI_IMAGE_VALUE_OPTIONS "$1" "${2-}" "$#"
    shift 2
    continue
  fi
  case "$1" in
    --keep|--keep-container) KEEP=1; shift ;;
    --mount-hub-scripts) MOUNT_HUB=1; shift ;;
    --) shift; CMD=("$@"); break ;;
    *) die "unknown argument \"$1\" (did you forget the -- before the command?)" ;;
  esac
done

[ "${#CMD[@]}" -gt 0 ] || die "no command given; everything after -- is the command"

if [ -z "${ENGINE}" ]; then
  if command -v nerdctl >/dev/null 2>&1; then ENGINE=nerdctl; else ENGINE=docker; fi
fi
command -v "${ENGINE}" >/dev/null 2>&1 || die "${ENGINE} is not on PATH"

if [ -z "${IMAGE}" ]; then
  IMAGE="$(bash "${_SCRIPT_DIR}/ci-image-ref.sh")" || die "could not resolve the CI image reference"
fi

ARGS=(run --rm)
[ "${KEEP}" -eq 0 ] || ARGS=(run)
if [ "${ENGINE##*/}" = nerdctl ]; then ARGS+=(--security-opt apparmor=unconfined); fi
[ -z "${NAME}" ] || ARGS+=(--name "${NAME}")
[ -z "${PLATFORM}" ] || ARGS+=(--platform "${PLATFORM}")
[ -z "${USER_SPEC}" ] || ARGS+=(--user "${USER_SPEC}")
ARGS+=(-v "${REPO_ROOT}:/workspace" -w "${WORKDIR}")
if [ "${MOUNT_HUB}" -eq 1 ]; then
  ARGS+=(-v "$(cd "${_SCRIPT_DIR}/../.." && pwd):/opt/kataglyphis-scripts:ro")
fi
ARGS+=("${IMAGE}" bash -lc "git config --global --add safe.directory /workspace >/dev/null 2>&1 || true; $(printf '%q ' "${CMD[@]}")")

# From Git Bash, MSYS would rewrite every -v/-w path into a Windows one.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' exec "${ENGINE}" "${ARGS[@]}"
