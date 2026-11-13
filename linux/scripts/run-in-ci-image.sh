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
PRIVILEGED=0
VOLUMES=()
ENVS=()
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
    --privileged) PRIVILEGED=1; shift ;;
    --volume)
      # No comma or second colon: both would end the name or the path inside --mount.
      [[ "${2-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*:/[^,:]*$ ]] || die "--volume needs name:/absolute/path, got \"${2-}\""
      VOLUMES+=("$2"); shift 2 ;;
    --env)
      [[ "${2-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "--env needs NAME=value, got \"${2-}\""
      ENVS+=("$2"); shift 2 ;;
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

# engine_says <args...>: the first line of an engine query; empty when the engine cannot answer.
engine_says() { "${ENGINE}" "$@" 2>/dev/null | head -n 1 || true; }

# A rootless engine on Linux maps the host user to the container's root; any other user cannot write the checkout.
if [ -z "${USER_SPEC}" ] && [ "$(uname -s)" = Linux ] \
  && [[ "$(engine_says info --format '{{.SecurityOptions}}')" == *rootless* ]]; then
  USER_SPEC=0:0
  # As root GNU tar restores an archive's owners, and one beyond the subuid range fails the extraction.
  [[ " ${ENVS[*]%%=*} " == *" TAR_OPTIONS "* ]] || ENVS+=(TAR_OPTIONS=--no-same-owner)
fi

# A month-old local copy reads as broken code, so every run says how old the image is.
CREATED="$(engine_says image inspect --format '{{.Created}}' "${IMAGE}")"
if [ -n "${CREATED}" ]; then AGE="local copy created ${CREATED}"; else AGE="no local copy; the engine pulls it"; fi
printf 'run-in-ci-image.sh: image %s, %s\n' "${IMAGE}" "${AGE}" >&2

ON_PLATFORM=()
[ -z "${PLATFORM}" ] || ON_PLATFORM=(--platform "${PLATFORM}")
COMMON=("${ON_PLATFORM[@]}")
if [ "${ENGINE##*/}" = nerdctl ]; then COMMON+=(--security-opt apparmor=unconfined); fi

# hand_volumes_to <user>: a new named volume is root's, so a run under another user could not write its cache.
hand_volumes_to() {
  local volume
  for volume in "${VOLUMES[@]}"; do
    "${ENGINE}" run --rm "${COMMON[@]}" --user 0:0 --mount "type=volume,source=${volume%%:*},target=${volume#*:}" \
      "${IMAGE}" chown "$1" "${volume#*:}" >&2 || die "could not hand volume ${volume%%:*} to user $1"
  done
}
RUN_USER="${USER_SPEC}"
if [ "${#VOLUMES[@]}" -gt 0 ] && [ -z "${RUN_USER}" ]; then
  # The image's own user is known only from a local copy.
  [ -n "${CREATED}" ] || "${ENGINE}" pull "${ON_PLATFORM[@]}" "${IMAGE}" >&2 || die "could not pull ${IMAGE}"
  RUN_USER="$(engine_says image inspect --format '{{.Config.User}}' "${IMAGE}")"
fi
case "${RUN_USER}" in
  ''|0|0:*|root|root:*) ;;
  *) hand_volumes_to "${RUN_USER}" ;;
esac

ARGS=(run --rm)
[ "${KEEP}" -eq 0 ] || ARGS=(run)
ARGS+=("${COMMON[@]}")
[ -z "${NAME}" ] || ARGS+=(--name "${NAME}")
[ -z "${USER_SPEC}" ] || ARGS+=(--user "${USER_SPEC}")
[ "${PRIVILEGED}" -eq 0 ] || ARGS+=(--privileged)
for volume in "${VOLUMES[@]}"; do ARGS+=(--mount "type=volume,source=${volume%%:*},target=${volume#*:}"); done
for pair in "${ENVS[@]}"; do ARGS+=(-e "${pair}"); done
ARGS+=(-v "${REPO_ROOT}:/workspace" -w "${WORKDIR}")
if [ "${MOUNT_HUB}" -eq 1 ]; then
  ARGS+=(-v "$(cd "${_SCRIPT_DIR}/../.." && pwd):/opt/kataglyphis-scripts:ro")
fi
ARGS+=("${IMAGE}" bash -lc "git config --global --add safe.directory /workspace >/dev/null 2>&1 || true; $(printf '%q ' "${CMD[@]}")")

# From Git Bash, MSYS would rewrite every -v/-w path into a Windows one.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' exec "${ENGINE}" "${ARGS[@]}"
