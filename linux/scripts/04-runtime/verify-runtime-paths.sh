#!/usr/bin/env bash
# No -e: path-mismatch checks are heuristic and warn; missing tracked files fail hard.
set -uo pipefail
# C collation, or `comm` aborts on paths that sort differently under UTF-8 ('-' vs '/').
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PATHS_ENV="${REPO_ROOT}/linux/scripts/04-runtime/runtime-paths.env"
VERSIONS_ENV="${REPO_ROOT}/linux/scripts/01-core/versions.env"

echo "=== Runtime paths consistency check (advisory path-mismatch; hard infra) ==="

# Tracked files: a missing one is a broken tree, not a heuristic mismatch.
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

# _envsubst <text>: envsubst's ${NAME}/$NAME from the exported env, in bash; with no envsubst (the image) the gate compared nothing.
_envsubst() {
  local s="$1" out="" name
  while [[ "${s}" =~ \$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*)) ]]; do
    name="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
    out+="${s%%"${BASH_REMATCH[0]}"*}$(printenv "${name}" || true)"
    s="${s#*"${BASH_REMATCH[0]}"}"
  done
  printf '%s\n' "${out}${s}"
}

# versions.env values let _envsubst expand the ${VAR} references below.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/load-versions-env.sh"
load_versions_env "${VERSIONS_ENV}"

# Load canonical paths (may reference $GCC_VERSION etc.)
source "${PATHS_ENV}"

canonical_paths="$(
  grep -E '^[A-Z_]+=' "${PATHS_ENV}" \
    | grep -vE '^(GCC_PREFIX|OPENCV_PREFIX|GSTREAMER_PREFIX|FFMPEG_PREFIX|LIBCAMERA_PREFIX|VULKAN_SDK)=' \
    | cut -d= -f2- \
    | grep '^/' \
    | while IFS= read -r line; do _envsubst "$line"; done \
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
  # _envsubst reads the versions.env values sourced above.
  df_env_expanded="$(_envsubst "$df_env_text")"
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

# LC_ALL=C: a locale-collated sort would corrupt comm's byte-wise set difference.
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
