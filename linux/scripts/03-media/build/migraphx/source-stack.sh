#!/usr/bin/env bash
# Stack transport verifies pinned archives and invokes required children; it does not prove their binaries or image acceptance.
migraphx_stack_plan() {
  local -n stack_plan="$1"
  local cache="$2" table="$3" name revision_key digest_key url revision digest required
  local -A seen=()
  stack_plan=()
  while IFS='|' read -r name revision_key digest_key url; do
    [[ "${revision_key}" =~ ^[A-Z][A-Z0-9_]*$ && "${digest_key}" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
      printf 'Invalid MIGraphX archive pin key\n' >&2; return 2;
    }
    revision="${!revision_key:-}" digest="${!digest_key:-}"
    [[ "${revision}" =~ ^[A-Za-z0-9._+-]+$ && "${digest}" =~ ^[0-9a-f]{64}$ ]] || {
      printf 'Missing or invalid MIGraphX archive pin: %s/%s\n' "${revision_key}" "${digest_key}" >&2; return 1;
    }
    [[ "${name}" =~ ^[a-z][a-z0-9-]*$ && -z "${seen[${name}]:-}" && "${url}" == https://*'{0}'* ]] || {
      printf 'Repeated or invalid MIGraphX archive entry\n' >&2; return 2;
    }
    seen["${name}"]=1
    url="${url//\{0\}/${revision}}"
    stack_plan+=("${name}|${url}|${digest}|${cache}/${digest}.tar.gz")
  done < "${table}"
  [[ "${#seen[@]}" -eq 7 ]] || { printf 'MIGraphX stack requires exactly seven archive entries\n' >&2; return 1; }
  for required in migraphx rocm-cmake msgpack abseil protobuf ck rocmlir; do
    [[ "${seen[${required}]:-}" == 1 ]] || { printf 'Missing MIGraphX stack archive: %s\n' "${required}" >&2; return 1; }
  done
}

migraphx_stack_fetch() {
  local -n stack_records="$1" stack_files="$2"
  local record name url digest archive
  for record in "${stack_records[@]}"; do
    IFS='|' read -r name url digest archive <<< "${record}"
    [[ ! -L "${archive}" ]] || { printf 'Refusing symlinked MIGraphX source-cache archive\n' >&2; return 1; }
    if [[ -f "${archive}" ]] && download_verify_sha256 "${digest}" "${archive}"; then
      printf 'MIGRAPHX SOURCE CACHE HIT: %s\n' "${name}" >&2
    else
      download_verified_file "${url}" "${digest}" "${archive}" || return
      download_verify_sha256 "${digest}" "${archive}" || return
    fi
    stack_files+=(["${name}"]="${archive}")
  done
}
