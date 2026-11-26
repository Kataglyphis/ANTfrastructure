# shellcheck shell=bash
# Runtime image pushes: the zstd conversion, the registry check and the retries; artifact-common.sh sources it before runtime-build-fns.sh.

# One push attempt, output tee'd so the caller can classify the failure.
_runtime_push_attempt() {
  local tag="$1" log_file="${2:-/dev/null}" started rc
  local -a quiet=(--quiet)
  # The progress redraw was 98% of a 3.6M-line chain log (2026-10-21); the error text survives --quiet.
  [ "${RUNTIME_PUSH_PROGRESS:-0}" = "1" ] && quiet=()
  started="${SECONDS}"
  # retry policy lives in runtime_push_tag; this only reports the push rc
  run "${NERDCTL_BIN:-nerdctl}" push "${tag}" "${quiet[@]}" 2>&1 | tee "${log_file}"
  rc="${PIPESTATUS[0]}"
  log "[push] ${tag}: rc=${rc} after $(( SECONDS - started ))s"
  return "${rc}"
}

# The manifest digest the local image would publish (CON158).
_runtime_local_digest() {
  "${NERDCTL_BIN:-nerdctl}" image inspect --mode=native "$1" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print((d.get("ManifestDesc") or {}).get("digest",""))' 2>/dev/null
}

# The manifest digest ghcr.io holds for a tag, anonymously (CON158); empty for other registries or any failure.
_runtime_registry_digest() {
  local ref="$1" repo tag tok
  case "${ref}" in ghcr.io/*) ;; *) return 0 ;; esac
  repo="${ref#ghcr.io/}"; tag="${repo##*:}"; repo="${repo%:*}"
  tok="$(curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" || return 0
  [ -n "${tok}" ] || return 0
  curl -fsSI -H "Authorization: Bearer ${tok}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${repo}/manifests/${tag}" 2>/dev/null | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p' | head -n 1
}

# nerdctl 2.4's in-place convert loses the source manifest when no other image holds it, so convert to a second tag: docs/failure-modes.md
_runtime_zstd_convert() {
  local tag="$1" staged="$1-zstd" nerdctl="${NERDCTL_BIN:-nerdctl}"
  run "${nerdctl}" image convert --zstd --oci "${tag}" "${staged}" || return 1
  run "${nerdctl}" tag "${staged}" "${tag}" || return 1
  run "${nerdctl}" rmi "${staged}" >/dev/null || warn "[push] ${staged} stays behind; remove it with nerdctl rmi"
  return 0
}

# Transient push failures retry (PUSH_MAX_ATTEMPTS, PUSH_RETRY_BASE_SECS), permanent ones do not. docs/cross-build-verification.md
runtime_push_tag() {
  local tag="$1"
  local max_attempts="${PUSH_MAX_ATTEMPTS:-4}" base_secs="${PUSH_RETRY_BASE_SECS:-15}"
  local attempt=1 rc=0 log_file="" local_digest remote_digest delay
  # The published layers leave as zstd, as the cross stages push theirs (owner decision 2026-11-21, CON99); idempotent.
  [ "${CROSS_LAYER_COMPRESSION:-zstd}" != zstd ] || _runtime_zstd_convert "${tag}" || return 1
  # A restart re-pushes what the registry already holds: same manifest digest, nothing to upload (CON158).
  local_digest="$(_runtime_local_digest "${tag}")"
  remote_digest="$(_runtime_registry_digest "${tag}")"
  if [ -n "${local_digest}" ] && [ "${local_digest}" = "${remote_digest}" ]; then
    log "[push] ${tag}: already in the registry (${local_digest}), no upload"
    return 0
  fi
  log_file="$(mktemp "${TMPDIR:-/tmp}/runtime-push-XXXXXX" 2>/dev/null || true)"

  while :; do
    rc=0
    _runtime_push_attempt "${tag}" "${log_file:-/dev/null}" || rc=$?
    [ "${rc}" -eq 0 ] && break
    if ! delay="$(push_retry_delay "${attempt}" "${max_attempts}" "${base_secs}" "${log_file}")"; then
      if [ "${attempt}" -lt "${max_attempts}" ]; then
        warn "[push] ${tag} failed with a PERMANENT error (not a registry/network flake) — not retrying"
      else
        warn "[push] ${tag} failed after ${attempt} attempts"
      fi
      break
    fi
    warn "[push] ${tag} attempt ${attempt}/${max_attempts} hit a transient registry/network error; retrying in ${delay}s"
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
  done

  [ -z "${log_file}" ] || rm -f "${log_file}"
  return "${rc}"
}
