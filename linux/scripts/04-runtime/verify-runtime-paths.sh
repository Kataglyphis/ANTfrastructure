#!/usr/bin/env bash
# NO -e: the path-mismatch checks below are heuristic (awk over ENV blocks +
# token grep) and must stay advisory — they produce WARN lines even on a healthy
# tree (ARG-composed paths, unexpanded ${GCC_VERSION}-style refs, legitimate
# Dockerfile.package vs .media /opt divergence). INFRASTRUCTURE errors (missing
# reference file / Dockerfiles) are NOT heuristic — those fail loudly (LOG31).
set -uo pipefail
# Pin C collation so `sort` and `comm` below agree on byte order. Without this,
# UTF-8 locales sort '-' (0x2d) and '/' (0x2f) differently from `comm`'s byte
# order, so sibling paths like /opt/tvm-wheels vs /opt/tvm/lib make comm abort
# with "file N is not in sorted order" and fail the whole check spuriously.
export LC_ALL=C
# verify-runtime-paths.sh - Compare PATH/LD_LIBRARY_PATH/PKG_CONFIG_PATH
# components in Dockerfiles against the canonical runtime-paths.env reference.
#
# Contract: FAILS on infrastructure errors (missing runtime-paths.env,
# versions.env, or a tracked Dockerfile — a broken tree/rename, not a heuristic
# mismatch). The path-mismatch WARN lines stay advisory: extraction is
# heuristic and produces false positives on a healthy tree. (LOG31: this script
# previously NEVER failed — an inner warning swallowed by an outer green.)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PATHS_ENV="${REPO_ROOT}/linux/scripts/04-runtime/runtime-paths.env"
VERSIONS_ENV="${REPO_ROOT}/linux/scripts/01-core/versions.env"

echo "=== Runtime paths consistency check (advisory path-mismatch; hard infra) ==="

# Infrastructure: these are tracked repo files. A missing one is a broken
# tree/rename, not a heuristic mismatch — fail loudly (LOG31).
_infra_fail=0
for _req in "${PATHS_ENV}" "${VERSIONS_ENV}" "${REPO_ROOT}/linux/Dockerfile.package" "${REPO_ROOT}/linux/Dockerfile.media"; do
  if [ ! -f "${_req}" ]; then
    echo "FAIL: required file missing: ${_req}" >&2
    _infra_fail=1
  fi
done
if [ "${_infra_fail}" -ne 0 ]; then
  echo "FAIL: infrastructure file(s) missing — fix the tree (LOG31)" >&2
  exit 1
fi

# Load version defaults from the single source of truth so variable references
# (${GCC_VERSION}, ${OPENCV_OUTPUT_DIR}, etc.) can be expanded dynamically.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/load-versions-env.sh"
load_versions_env "${VERSIONS_ENV}"

# Load canonical paths (may reference $GCC_VERSION etc.)
source "${PATHS_ENV}"

# Extract the explicit paths (values that look like absolute paths)
# Use envsubst to expand any remaining ${VAR} references with actual values.
canonical_paths="$(
  grep -E '^[A-Z_]+=' "${PATHS_ENV}" \
    | grep -vE '^(GCC_PREFIX|OPENCV_PREFIX|GSTREAMER_PREFIX|FFMPEG_PREFIX|LIBCAMERA_PREFIX|VULKAN_SDK)=' \
    | cut -d= -f2- \
    | grep '^/' \
    | while IFS= read -r line; do envsubst <<<"$line"; done \
    | LC_ALL=C sort -u
)"

echo "  canonical paths from runtime-paths.env: $(echo "$canonical_paths" | wc -l)"

# Check each Dockerfile's ENV blocks for these paths
DOCKERFILES=(
  linux/Dockerfile.package
  linux/Dockerfile.media
)

for df in "${DOCKERFILES[@]}"; do
  df_path="${REPO_ROOT}/${df}"
  echo "  checking ${df}..."

  # Extract ENV values (multi-line ENV blocks), expanding known variables
  df_env_text="$(
    awk '/^ENV /{flag=1} flag{print; if(!/\\$/){flag=0}}' "$df_path" | tr -d '\\'
  )"
  # Expand variable refs to their literal values via envsubst (reads the
  # versions.env vars sourced above, no hardcoded sed substitutions needed).
  df_env_expanded="$(envsubst <<<"$df_env_text")"
  df_env_values="$(echo "$df_env_expanded" | grep -oP '/[A-Za-z0-9/._-]+' | LC_ALL=C sort -u)"

  for path in $canonical_paths; do
    # Remove variable substitutions for matching
    clean_path="$(echo "$path" | sed 's/\${[^}]*}//g' | sed 's/\/$//')"
    [ -n "$clean_path" ] || continue
    if ! echo "$df_env_values" | grep -qF "$clean_path"; then
      case "$clean_path" in
        /opt/*|/usr/local/*)
          echo "WARN: ${df} missing canonical path: ${clean_path}" >&2
          ;;
      esac
    fi
  done
done

# Check that Dockerfile.package and Dockerfile.media agree on the critical paths
echo "  checking cross-Dockerfile consistency..."
PKG_ENV_PATHS="$(
  awk '/^ENV /,/^RUN/{print}' "${REPO_ROOT}/linux/Dockerfile.package" \
    | grep -oP '/opt/[A-Za-z0-9/._-]+' \
    | LC_ALL=C sort -u
)"
MEDIA_ENV_PATHS="$(
  awk '/^ENV /,/^RUN/{print}' "${REPO_ROOT}/linux/Dockerfile.media" \
    | grep -oP '/opt/[A-Za-z0-9/._-]+' \
    | LC_ALL=C sort -u
)"

# Compare shared /opt paths. LC_ALL=C: sort collates by locale, comm compares
# bytes — mixing them silently corrupts the set difference.
pkg_only_opt="$(
  comm -23 <(echo "$PKG_ENV_PATHS" | LC_ALL=C sort -u) <(echo "$MEDIA_ENV_PATHS" | LC_ALL=C sort -u)
)"
media_only_opt="$(
  comm -13 <(echo "$PKG_ENV_PATHS" | LC_ALL=C sort -u) <(echo "$MEDIA_ENV_PATHS" | LC_ALL=C sort -u)
)"

if [ -n "$pkg_only_opt" ]; then
  echo "  paths only in Dockerfile.package: $(echo "$pkg_only_opt" | tr '\n' ' ')"
fi
if [ -n "$media_only_opt" ]; then
  echo "  paths only in Dockerfile.media: $(echo "$media_only_opt" | tr '\n' ' ')"
fi

echo "Done: path-mismatch WARN lines above are advisory; infrastructure errors fail hard (LOG31)."
exit 0
