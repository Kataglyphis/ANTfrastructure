#!/usr/bin/env bash
# NO -e: this script's own contract is "ADVISORY ONLY — never fails" and
# preflight.sh runs it as a gate; with errexit, any zero-match grep in the
# collection pipelines below aborted it and failed the gate against contract
# (same deliberate choice as preflight.sh and the lint-*.sh siblings).
set -uo pipefail
# Pin C collation so `sort` and `comm` below agree on byte order. Without this,
# UTF-8 locales sort '-' (0x2d) and '/' (0x2f) differently from `comm`'s byte
# order, so sibling paths like /opt/tvm-wheels vs /opt/tvm/lib make comm abort
# with "file N is not in sorted order" and fail the whole check spuriously.
export LC_ALL=C
# verify-runtime-paths.sh - Compare PATH/LD_LIBRARY_PATH/PKG_CONFIG_PATH
# components in Dockerfiles against the canonical runtime-paths.env reference.
#
# ADVISORY ONLY — this script NEVER fails (always exits 0). Its extraction is
# heuristic (awk over ENV blocks + token grep), which produces WARN lines even
# on a healthy tree: paths composed from build ARGs are invisible to the
# scrape, ${GCC_VERSION}-style refs may not expand outside the build, and
# Dockerfile.package vs Dockerfile.media legitimately diverge in their /opt
# inventories. Treat the output as a diff-review aid when touching ENV blocks,
# not as a gate. (It previously carried an errors counter and an `exit 1`
# branch that could never trigger — that pretend-gate has been removed.)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PATHS_ENV="${REPO_ROOT}/linux/scripts/04-runtime/runtime-paths.env"
VERSIONS_ENV="${REPO_ROOT}/linux/scripts/01-core/versions.env"

echo "=== Runtime paths consistency check (ADVISORY — never fails) ==="

# Load version defaults from the single source of truth so variable references
# (${GCC_VERSION}, ${OPENCV_OUTPUT_DIR}, etc.) can be expanded dynamically.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/load-versions-env.sh"
load_versions_env "${VERSIONS_ENV}"

# Load canonical paths (may reference $GCC_VERSION etc.)
source "${PATHS_ENV}" 2>/dev/null || true

# Extract the explicit paths (values that look like absolute paths)
# Use envsubst to expand any remaining ${VAR} references with actual values.
canonical_paths="$(
  grep -E '^[A-Z_]+=' "${PATHS_ENV}" \
    | grep -vE '^(GCC_PREFIX|OPENCV_PREFIX|GSTREAMER_PREFIX|FFMPEG_PREFIX|LIBCAMERA_PREFIX|VULKAN_SDK)=' \
    | cut -d= -f2- \
    | grep '^/' \
    | while IFS= read -r line; do envsubst <<<"$line"; done \
    | sort -u
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
  df_env_values="$(echo "$df_env_expanded" | grep -oP '/[A-Za-z0-9/._-]+' | sort -u)"

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
    | sort -u
)"
MEDIA_ENV_PATHS="$(
  awk '/^ENV /,/^RUN/{print}' "${REPO_ROOT}/linux/Dockerfile.media" \
    | grep -oP '/opt/[A-Za-z0-9/._-]+' \
    | sort -u
)"

# Compare shared /opt paths
shared_opt="$(
  comm -12 <(echo "$PKG_ENV_PATHS" | sort -u) <(echo "$MEDIA_ENV_PATHS" | sort -u)
)"
pkg_only_opt="$(
  comm -23 <(echo "$PKG_ENV_PATHS" | sort -u) <(echo "$MEDIA_ENV_PATHS" | sort -u)
)"
media_only_opt="$(
  comm -13 <(echo "$PKG_ENV_PATHS" | sort -u) <(echo "$MEDIA_ENV_PATHS" | sort -u)
)"

if [ -n "$pkg_only_opt" ]; then
  echo "  paths only in Dockerfile.package: $(echo "$pkg_only_opt" | tr '\n' ' ')"
fi
if [ -n "$media_only_opt" ]; then
  echo "  paths only in Dockerfile.media: $(echo "$media_only_opt" | tr '\n' ' ')"
fi

echo "ADVISORY: runtime paths comparison done (informational only — WARN lines above never gate)"
