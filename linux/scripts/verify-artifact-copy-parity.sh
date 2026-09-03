#!/usr/bin/env bash
set -euo pipefail
# verify-artifact-copy-parity.sh — verify artifact COPY src/dst parity in Dockerfile.package.
# NOTE: regex-based — does not handle multi-line COPY or heredoc syntax.

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

_require_file() { [ -f "$1" ] || { echo "ERROR: $2 not found: $1"; exit 1; }; }

main() {
  _require_file "${DOCKERFILE}" "Dockerfile"

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

  check_completeness "${pairs}"
}

# Completeness: every path in runtime-artifacts.manifest must be COPY'd, and every
# COPY'd path must be in the manifest. This is what catches a BUILT-BUT-DROPPED
# artifact (Flutter 2026-09-03, ArmNN/ACL before it) — the consistency check above
# only sees paths that ARE copied. docs/artifact-copy-completeness.md
# $1 = counter nameref; for each line in $2 (needles) absent from $3 (a newline
# set), print the two message templates $4/$5 with every '@P@' -> the path, and
# add the miss count to the counter. One owner for both directions of the check.
_report_absent() {
  local -n _cnt="$1"
  local needles="$2" haystack="$3" head="$4" hint="$5" p
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    if ! printf '%s\n' "${haystack}" | grep -qxF -- "${p}"; then
      echo "${head//@P@/${p}}"
      echo "      ${hint//@P@/${p}}"
      _cnt=$((_cnt + 1))
    fi
  done <<< "${needles}"
}

check_completeness() {
  local pairs="$1"
  local manifest
  manifest="$(dirname "$0")/runtime-artifacts.manifest"
  _require_file "${manifest}" "manifest"

  local copied want fails=0
  copied="$(printf '%s\n' "${pairs}" | awk 'NF{print $1}' | sort -u)"
  want="$(grep -vE '^[[:space:]]*(#|$)' "${manifest}" | sed 's/[[:space:]]*|.*//' | sort -u)"

  _report_absent fails "${want}" "${copied}" \
    "FAIL: @P@ is in runtime-artifacts.manifest but NOT COPY'd from artifact-source" \
    "-> built and expected in the runtime image but dropped; add: COPY --link --from=artifact-source @P@ @P@"
  _report_absent fails "${copied}" "${want}" \
    "FAIL: @P@ is COPY'd from artifact-source but NOT in runtime-artifacts.manifest" \
    "-> add a line '@P@ | <reason>' to the manifest, or remove the COPY"

  if [ "${fails}" -gt 0 ]; then
    echo
    echo "FAIL: ${fails} artifact-copy completeness error(s)."
    exit 1
  fi
  echo "OK: every built runtime artifact is copied, and every copy is declared ($(printf '%s\n' "${want}" | grep -c .) artifacts)"
}
main "$@"
