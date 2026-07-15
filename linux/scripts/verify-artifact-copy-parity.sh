#!/usr/bin/env bash
set -euo pipefail
# verify-artifact-copy-parity.sh
# Verifies the artifact COPY lane in Dockerfile.package:
#   1. the `artifact-source` stage exists (so `COPY --from=artifact-source`
#      references resolve), and
#   2. every `COPY [--flags...] --from=artifact-source SRC DST` in the
#      package-image stage copies SRC to the SAME path — artifacts are staged
#      in the artifact image at their canonical runtime locations, so a src/dst
#      drift silently relocates an artifact. Documented intentional relocations
#      are allowlisted below.
# Run from repo root.
#
# NOTE: This uses regex-based COPY extraction which is best-effort.
# It will NOT handle multi-line COPY or heredoc syntax. For complex
# Dockerfiles, consider a proper parser.

usage() {
  cat <<'EOF'
Usage: verify-artifact-copy-parity.sh [DOCKERFILE] [options]

Verify that the artifact-source stage exists and that artifact COPY
source/destination paths are consistent in the package-image stage.

Arguments:
  DOCKERFILE                 Path to Dockerfile (default: linux/Dockerfile.package)

Options:
  -h, --help                 Show this help text
EOF
}

DOCKERFILE="${1:-linux/Dockerfile.package}"
case "${DOCKERFILE}" in
  -h|--help) usage; exit 0 ;;
esac

# Documented intentional src != dst relocations, one "SRC DST" pair per entry.
ALLOWED_RELOCATIONS=(
  # Per-arch native clang is staged at /opt/llvm-target and deliberately
  # shipped at /usr/local/llvm-target in the runtime image.
  "/opt/llvm-target /usr/local/llvm-target"
)

# Print "SRC DST" for every single-line `COPY [--flags...] --from=artifact-source`
# inside the package-image stage. Flags (tokens starting with --) may appear in
# any position between COPY and the paths.
extract_artifact_copy_pairs() {
  awk '
    /^[[:space:]]*FROM[[:space:]]/ {
      in_stage = ($0 ~ /[[:space:]]AS[[:space:]]+package-image([[:space:]]|$)/)
      next
    }
    in_stage && $1 == "COPY" && $0 ~ /[[:space:]]--from=artifact-source([[:space:]]|$)/ {
      n = 0
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^--/) continue
        tok[++n] = $i
      }
      if (n >= 2) print tok[n-1], tok[n]
    }
  ' "${DOCKERFILE}"
}

main() {
  if [ ! -f "${DOCKERFILE}" ]; then
    echo "ERROR: Dockerfile not found: ${DOCKERFILE}"
    exit 1
  fi

  if ! grep -qE '^[[:space:]]*FROM[[:space:]].*[[:space:]]AS[[:space:]]+artifact-source([[:space:]]|$)' "${DOCKERFILE}"; then
    echo "ERROR: no 'AS artifact-source' stage in ${DOCKERFILE}; COPY --from=artifact-source cannot resolve."
    echo "       If the stage was renamed, update this check AND the COPY lines together."
    exit 1
  fi

  local pairs
  pairs="$(extract_artifact_copy_pairs)"
  if [ -z "${pairs}" ]; then
    echo "ERROR: no 'COPY ... --from=artifact-source' lines found in the package-image stage of ${DOCKERFILE}."
    echo "       Check the stage names still exist (artifact-source / package-image)."
    exit 1
  fi

  echo "artifact COPY pairs (src dst) in package-image stage:"
  printf '%s\n' "${pairs}" | sed 's/^/  /'
  echo

  local failures=0 src dst pair allowed a
  while read -r src dst; do
    [ -n "${src}" ] || continue
    if [ "${src}" = "${dst}" ]; then
      continue
    fi
    pair="${src} ${dst}"
    allowed=0
    for a in "${ALLOWED_RELOCATIONS[@]}"; do
      if [ "${pair}" = "${a}" ]; then
        allowed=1
        break
      fi
    done
    if [ "${allowed}" -eq 1 ]; then
      echo "OK (documented relocation): ${src} -> ${dst}"
    else
      echo "MISMATCH: ${src} -> ${dst}"
      echo "  Artifact COPY relocates a canonical path. If intentional, add the"
      echo "  pair to ALLOWED_RELOCATIONS in this script."
      failures=$((failures + 1))
    fi
  done <<< "${pairs}"

  if [ "${failures}" -gt 0 ]; then
    echo
    echo "FAIL: ${failures} undocumented artifact COPY relocation(s)."
    exit 1
  fi
  echo "OK: artifact COPY source/destination paths are consistent"
}
main "$@"
