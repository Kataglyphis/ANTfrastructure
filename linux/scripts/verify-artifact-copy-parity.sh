#!/usr/bin/env bash
set -euo pipefail
# verify-artifact-copy-parity.sh
# Verifies that the artifact COPY source paths in Dockerfile.package's
# artifact-source-local and package-image stages are consistent.
# Run from repo root.
#
# NOTE: This uses regex-based COPY extraction which is best-effort.
# It will NOT handle multi-line COPY, heredoc syntax, or --from= without ${}
# variable references. For complex Dockerfiles, consider a proper parser.
DOCKERFILE="${1:-linux/Dockerfile.package}"

extract_copy_sources() {
  local section_pattern="$1" in_section=0 line src
  while IFS= read -r line; do
    if echo "${line}" | grep -qE "^FROM .* AS ${section_pattern}"; then
      in_section=1; continue
    fi
    [ "${in_section}" -eq 1 ] || continue
    if echo "${line}" | grep -qE '^FROM '; then break; fi
    if echo "${line}" | grep -qE '^\s*COPY --from=.*\$'; then
      src="$(echo "${line}" | awk '{for(i=1;i<=NF;i++) if($i~/\$\{/){s=$i;gsub(/^\$\{?|:.*|-.*\}/,"",s); print s; exit}}')"
      [ -n "${src}" ] && printf '%s\n' "${src}"
      continue
    fi
    if echo "${line}" | grep -qE '^\s*COPY --from=.* /opt/'; then
      src="$(echo "${line}" | awk '{for(i=1;i<=NF;i++) if($i~/^\/opt\//){print $i; exit}}')"
      [ -n "${src}" ] && printf '%s\n' "${src}"
    fi
  done < "${DOCKERFILE}"
}

main() {
  local local_src image_src
  local_src="$(extract_copy_sources 'artifact-source-local' | sort)"
  image_src="$(extract_copy_sources 'package-image' | sort)"

  echo "artifact-source-local sources:"
  echo "${local_src}"
  echo
  echo "package-image sources:"
  echo "${image_src}"
  echo

  if [ -z "${local_src}" ] && [ -z "${image_src}" ]; then
    echo "ERROR: No COPY sources found in either section. Check stage names exist in Dockerfile."
    exit 1
  fi

  if [ "${local_src}" = "${image_src}" ]; then
    echo "OK: artifact COPY source paths match"
    return 0
  fi

  echo "MISMATCH.  If intentional (e.g. llvm-target), update this check."
  diff <(echo "${local_src}") <(echo "${image_src}") || true
  exit 1
}
main
