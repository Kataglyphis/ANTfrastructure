#!/usr/bin/env bash
# run-in-ci-image.sh - run a command inside the family CI image, from anywhere.
#
# Every consumer README, every local-repro section and half the agent prompts in
# this family carried the same hand-typed `docker run` line, and they had all
# drifted: a different image tag, a forgotten MSYS_NO_PATHCONV, a bind mount at
# a different path, a missing safe.directory. This is that line, once. CI itself
# uses the run-in-linux-container composite action; this is for everything that
# is not a workflow step -- a local repro, a sweep script, an agent.
#
# Usage:
#   run-in-ci-image.sh <repo-root> [options] -- <command...>
#
#   --engine docker|nerdctl   container engine (default: nerdctl if present,
#                             else docker -- the local box runs Rancher Desktop,
#                             CI runs docker, and neither should have to say so)
#   --platform <p>            e.g. linux/arm64 (needs binfmt; see
#                             docs/rancher-desktop-linux-containers.md)
#   --mount-hub-scripts       also mount THIS hub checkout at
#                             /opt/kataglyphis-scripts, read-only, for a
#                             consumer whose own third_party/ANTfrastructure is
#                             not initialised yet
#   --workdir <dir>           working directory inside the container
#                             (default: /workspace)
#   --name <n>, --keep        name the container / do not --rm it
#   --                        everything after this is the command
#
# The repo root is mounted at /workspace and registered as a git
# safe.directory before the command runs: the bind mount belongs to another uid
# than the container user, and without it every git call inside fails as
# "dubious ownership" -- which is what breaks a format gate's `git ls-files`
# long before anything builds.
#
# docs/shared-script-libraries.md#run-in-ci-imagesh--run-a-command-in-the-ci-image
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'run-in-ci-image.sh: %s\n' "$*" >&2; exit 2; }

REPO_ROOT=""
ENGINE=""
PLATFORM=""
WORKDIR="/workspace"
NAME=""
KEEP=0
MOUNT_HUB=0
CMD=()

[ "$#" -ge 1 ] || die "the repo root is required (got no arguments)"
REPO_ROOT="$(cd "$1" 2>/dev/null && pwd)" || die "repo root not found: $1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engine)   ENGINE="${2:?--engine needs a value}"; shift 2 ;;
    --platform) PLATFORM="${2:?--platform needs a value}"; shift 2 ;;
    --workdir)  WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --name)     NAME="${2:?--name needs a value}"; shift 2 ;;
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

IMAGE="$(bash "${_SCRIPT_DIR}/ci-image-ref.sh")" || die "could not resolve the CI image reference"

ARGS=(run --rm)
[ "${KEEP}" -eq 0 ] || ARGS=(run)
[ -z "${NAME}" ] || ARGS+=(--name "${NAME}")
[ -z "${PLATFORM}" ] || ARGS+=(--platform "${PLATFORM}")
ARGS+=(-v "${REPO_ROOT}:/workspace" -w "${WORKDIR}")
if [ "${MOUNT_HUB}" -eq 1 ]; then
  ARGS+=(-v "$(cd "${_SCRIPT_DIR}/../.." && pwd):/opt/kataglyphis-scripts:ro")
fi
ARGS+=("${IMAGE}" bash -lc "git config --global --add safe.directory /workspace >/dev/null 2>&1 || true; $(printf '%q ' "${CMD[@]}")")

# MSYS_NO_PATHCONV/MSYS2_ARG_CONV_EXCL: from Git Bash, MSYS rewrites anything
# that looks like a POSIX path into a Windows one, which destroys every -v and
# -w argument and fails with "expected an absolute path". Exported rather than
# documented, because a note nobody reads is how this keeps being rediscovered.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' exec "${ENGINE}" "${ARGS[@]}"
