#!/usr/bin/env bash
# lane-prologue.sh - make a container usable as a Flutter build environment.
#
# The Flutter twin of lib/cmake-build.sh's cmake_build_prepare_env, and written
# for the same reason: two consumers had each grown their own prologue, they had
# drifted, and the differences were all wrong in the same direction -- carrying
# work the IMAGE already does. This file carries only what the image does NOT.
#
# What it deliberately does NOT do, and must never gain:
#   * a git safe.directory for the SDK. setup-package-image.sh:556 registers
#     /opt/flutter at --system level, so a per-run --global copy is a no-op that
#     reads like a requirement.
#   * ~/.bashrc sourcing to find flutter. Dockerfile.package:268 puts
#     /opt/flutter/bin on PATH for every shell; sourcing a stock non-interactive
#     .bashrc returns early with a meaningless status and hides a broken rc file.
#   * installing a Flutter SDK. The image owns it. A lane that installs one is
#     testing a different toolchain from the one it ships.
#
# docs/shared-script-libraries.md#05-frameworksflutterlane-prologuesh
#
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.

[ -n "${_FLUTTER_LANE_PROLOGUE_SH_LOADED:-}" ] && return 0
_FLUTTER_LANE_PROLOGUE_SH_LOADED=1

# shellcheck source=../../01-core/logging.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../01-core" && pwd)/logging.sh"

# flutter_lane_prepare_env [flutter_dir] -> 0, or 1 naming what is wrong.
#
# FLUTTER_DIR (or the argument) defaults to /opt/flutter. The repo root is
# KATAGLYPHIS_REPO_ROOT, else the current directory.
flutter_lane_prepare_env() {
  local flutter_dir="${1:-${FLUTTER_DIR:-/opt/flutter}}"
  local repo_root="${KATAGLYPHIS_REPO_ROOT:-}"
  [ -n "${repo_root}" ] || repo_root="$(pwd)"

  if [ ! -x "${flutter_dir}/bin/flutter" ]; then
    printf 'no Flutter SDK at %s.\n' "${flutter_dir}" >&2
    printf 'The container image bakes one in; check FLUTTER_DIR and the image tag.\n' >&2
    printf '(Outside the container, point FLUTTER_DIR at your own SDK.)\n' >&2
    return 1
  fi
  export FLUTTER_DIR="${flutter_dir}"
  case ":${PATH}:" in
    *":${flutter_dir}/bin:"*) : ;;
    *) export PATH="${flutter_dir}/bin:${PATH}" ;;
  esac

  # The bind-mounted workspace belongs to a different uid than the container
  # user, and without safe.directory git refuses it as "dubious ownership" --
  # which kills the format gate's `git ls-files` and flutter itself. The REPO
  # ROOT only: see the header for why the SDK is not listed here.
  if ! git config --global --add safe.directory "${repo_root}"; then
    printf 'could not record %s as a git safe.directory (HOME=%s).\n' \
      "${repo_root}" "${HOME:-<unset>}" >&2
    printf 'Every later git call against that tree would fail as "dubious ownership".\n' >&2
    return 1
  fi

  # Inside the repo, so a cached package survives between phases of one run and
  # nothing is written to a root-owned $HOME.
  export PUB_CACHE="${PUB_CACHE:-${repo_root}/.pub-cache}"

  # The image tag is unpinned (:latest-cross), so the version is a measurement,
  # not a constant: print the one THIS run got.
  flutter --version || return 1
}

# flutter_build_web [--wasm] [--no-tree-shake-icons] [extra flutter args...]
#
# The two flags every consumer passes, named rather than spelled at each call
# site. Everything else is forwarded untouched.
flutter_build_web() {
  local -a args=(build web --release)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wasm) args+=(--wasm) ;;
      --no-tree-shake-icons) args+=(--no-tree-shake-icons) ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  info "flutter ${args[*]}"
  flutter "${args[@]}"
}
