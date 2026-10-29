#!/usr/bin/env bash
# sccache's shared S3 level in a BuildKit RUN, sourced by common.sh and compiler-cache.sh, `drain` its last command: docs/build-cache-tiers.md#the-shared-s3-level

# Only these names reach the server; anything else in the secret is ignored.
_SCCACHE_S3_NAMES="SCCACHE_BUCKET SCCACHE_ENDPOINT SCCACHE_REGION SCCACHE_S3_USE_SSL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"

_sccache_s3_log() {
  printf '[CACHE] %s\n' "$*" >&2
}

# <url>: 0 when its host:port takes a TCP connection within 2 s on one of SCCACHE_S3_PROBE_TRIES tries (a WireGuard re-handshake dropped a whole stage's level on 2026-10-28).
sccache_s3_endpoint_reachable() {
  local rest="${1#*://}" host port try
  rest="${rest%%/*}"
  host="${rest%:*}"
  port="${rest##*:}"
  [ "${host}" != "${rest}" ] || port=80
  [ -n "${host}" ] && [ -n "${port}" ] || return 1
  for try in $(seq 1 "${SCCACHE_S3_PROBE_TRIES:-3}"); do
    # shellcheck disable=SC2016 # expanded by the inner bash, from its arguments
    timeout 2 bash -c ': >"/dev/tcp/$1/$2"' _ "${host}" "${port}" 2>/dev/null && return 0
    [ "${try}" -ge "${SCCACHE_S3_PROBE_TRIES:-3}" ] || sleep 1
  done
  return 1
}

# <array-name>: fills it with NAME=value pairs for the server, or leaves it empty and says why.
sccache_s3_env() {
  local -n _s3_out="$1"
  _s3_out=()
  local file="${SCCACHE_S3_SECRET_FILE:-/run/secrets/sccache_s3}" line name value
  [ -e "${file}" ] || return 0
  if [ ! -r "${file}" ]; then
    _sccache_s3_log "sccache: ${file} is not readable by uid $(id -u) -- no S3 level in this RUN"
    return 0
  fi
  local -A _s3_kv=()
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|'#'*) continue ;; esac
    name="${line%%=*}"; value="${line#*=}"
    case " ${_SCCACHE_S3_NAMES} " in *" ${name} "*) _s3_kv["${name}"]="${value}" ;; esac
  done < "${file}"
  for name in SCCACHE_BUCKET SCCACHE_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [ -z "${_s3_kv[${name}]:-}" ]; then
      _sccache_s3_log "sccache: the S3 secret has no ${name} -- no S3 level in this RUN"
      return 0
    fi
  done
  if ! sccache_s3_endpoint_reachable "${_s3_kv[SCCACHE_ENDPOINT]}"; then
    _sccache_s3_log "sccache: the S3 level (${_s3_kv[SCCACHE_ENDPOINT]}) takes no TCP connection within 2 s on ${SCCACHE_S3_PROBE_TRIES:-3} tries -- this RUN caches on disk alone"
    return 0
  fi
  for name in "${!_s3_kv[@]}"; do _s3_out+=("${name}=${_s3_kv[${name}]}"); done
  _s3_out+=("SCCACHE_MULTILEVEL_CHAIN=disk,s3")
}

# 0 when this sccache can chain levels: the chain was checked against 0.18's multilevel.rs only.
_sccache_s3_version_ok() {
  local v
  v="$(sccache --version 2>/dev/null | awk '{print $2}')"
  [ -n "${v}" ] || return 1
  [ "$(printf '%s\n' 0.18.0 "${v}" | sort -V | head -n 1)" = 0.18.0 ] && return 0
  return 1
}

# Starts the server, with the S3 level when the RUN has its secret; the key stays out of the build's own environment.
sccache_start_server() {
  local -a s3=()
  # Without a socket a running server cannot be told apart, and a second start must not replace it.
  if [ -z "${SCCACHE_SERVER_UDS:-}" ] || ! _sccache_s3_version_ok; then
    sccache --start-server >/dev/null 2>&1 || true
    return 0
  fi
  if [ -S "${SCCACHE_SERVER_UDS}" ] && sccache --show-stats >/dev/null 2>&1; then
    return 0
  fi
  sccache_s3_env s3
  if [ "${#s3[@]}" -gt 0 ]; then
    local out
    # The client can exit 0 after giving up on a server that is still checking its levels.
    if out="$(env "${s3[@]}" sccache --start-server 2>&1)" && ! grep -qE 'Timed out waiting for server startup|Server startup failed' <<<"${out}"; then
      _sccache_s3_log "sccache levels: disk ${SCCACHE_DIR:-} -> s3 $(printf '%s\n' "${s3[@]}" | sed -n 's/^SCCACHE_ENDPOINT=//p')"
      return 0
    fi
    # One level that fails its startup check stops the whole server, so a refused key would leave every compile uncached.
    _sccache_s3_log "sccache: the server did not start with the S3 level ($(printf '%s\n' "${out}" | grep -m1 -E 'error|Timed out' || echo 'no reason given')) -- starting it on disk alone"
    sccache --stop-server >/dev/null 2>&1 || true
  fi
  sccache --start-server >/dev/null 2>&1 || true
}

# <python>: runs it on the server's JSON stats, with `s` bound to their "stats" object.
_sccache_stats_json() {
  sccache --show-stats --stats-format json 2>/dev/null \
    | python3 -c $'import json, sys\ns = json.load(sys.stdin).get("stats") or {}\n'"$1" 2>/dev/null
}

# Echoes the uploads still pending (the most any slower level lags level 0), the failed ones, and a tally; nothing without a chain.
_sccache_s3_pending() {
  _sccache_stats_json '
levels = s.get("multi_level") or []
if len(levels) >= 2:
    l0 = levels[0]["writes"]
    print(max(l0 - l["writes"] - l["write_failures"] for l in levels[1:]),
          sum(l["write_failures"] for l in levels[1:]),
          "; ".join("%s: %d written, %d failed" % (l["name"], l["writes"], l["write_failures"]) for l in levels[1:]),
          "of", l0)
'
}

# One line of the server's compile totals, so every sccache RUN's log measures whether its compiles reached the cache.
_sccache_stats_line() {
  _sccache_stats_json '
def n(key):
    v = s.get(key) or 0
    return sum((v.get("counts") or {}).values()) if isinstance(v, dict) else int(v)
print("sccache-stats| %d requests, %d hits, %d misses, %d errors, %d not cacheable"
      % (n("compile_requests"), n("cache_hits"), n("cache_misses"), n("cache_errors"),
         n("requests_not_cacheable") + n("non_cacheable_compilations")))
' >&2 || true
}

# The server log's last level or S3 lines, since the drain's tally only counts failed writes.
_sccache_s3_failure_reason() {
  local log="${SCCACHE_ERROR_LOG:-/tmp/sccache.log}" lines
  lines="$(grep -iE -e 's3|level|upload|write' "${log}" 2>/dev/null | tail -n 5 || true)"
  printf 'sccache-drain| failed writes; %s says:\n%s\n' "${log}" "${lines:-nothing about levels or S3}" >&2
}

# <PUT|GET> <s3 path> <file> <NAME=value>...: one SigV4 request with the standard library (the images carry no S3 client); 0 on 2xx, 2 on 404.
_sccache_s3_request() {
  env "${@:4}" python3 - "$1" "$2" "$3" <<'PY'
import datetime, hashlib, hmac, os, sys, urllib.request, urllib.error
env = os.environ
method, path, name = sys.argv[1], sys.argv[2], sys.argv[3]
endpoint = env["SCCACHE_ENDPOINT"].rstrip("/")
if "://" not in endpoint:
    endpoint = ("https://" if env.get("SCCACHE_S3_USE_SSL", "true").lower() == "true" else "http://") + endpoint
host = endpoint.split("://", 1)[1]
region, bucket = env.get("SCCACHE_REGION") or "us-east-1", env["SCCACHE_BUCKET"]
body = open(name, "rb").read() if method == "PUT" else b""
now = datetime.datetime.now(datetime.timezone.utc)
amz, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
digest = hashlib.sha256(body).hexdigest()
canonical = "\n".join([method, "/%s/%s" % (bucket, path), "", "host:%s" % host, "x-amz-content-sha256:%s" % digest, "x-amz-date:%s" % amz, "", "host;x-amz-content-sha256;x-amz-date", digest])
scope = "%s/%s/s3/aws4_request" % (day, region)
to_sign = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(canonical.encode()).hexdigest()])
key = ("AWS4" + env["AWS_SECRET_ACCESS_KEY"]).encode()
for part in (day, region, "s3", "aws4_request"):
    key = hmac.new(key, part.encode(), hashlib.sha256).digest()
auth = "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=%s" % (
    env["AWS_ACCESS_KEY_ID"], scope, hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest())
req = urllib.request.Request("%s/%s/%s" % (endpoint, bucket, path), data=body if method == "PUT" else None, method=method,
                             headers={"x-amz-content-sha256": digest, "x-amz-date": amz, "Authorization": auth})
try:
    with urllib.request.urlopen(req, timeout=600) as r:
        if method == "GET":
            with open(name, "wb") as out:
                while chunk := r.read(1 << 20):
                    out.write(chunk)
        sys.exit(0 if 200 <= r.status < 300 else 1)
except urllib.error.HTTPError as e:
    print("%s: HTTP %s" % (path, e.code), file=sys.stderr)
    sys.exit(2 if e.code == 404 else 1)
except Exception as e:  # noqa: BLE001 -- the caller prints the path; one line of cause is enough
    print("%s: %s" % (path, e), file=sys.stderr)
    sys.exit(1)
PY
}

# <s3 path> <file> <NAME=value>...: the PUT half, kept for its callers.
_sccache_s3_put() {
  _sccache_s3_request PUT "$@"
}

# <GET|PUT> <s3 path> <file>: one object of the shared level, with the RUN's secret; 1 without a level, 2 when a GET finds nothing.
_sccache_s3_transfer() {
  local -a env=()
  sccache_s3_env env
  [ "${#env[@]}" -gt 0 ] || return 1
  _sccache_s3_request "$1" "$2" "$3" "${env[@]}"
}

# <s3 path> <file>: GET into <file>.
sccache_s3_fetch() {
  _sccache_s3_transfer GET "$@"
}

# <s3 path> <file>: PUT <file>.
sccache_s3_store() {
  _sccache_s3_transfer PUT "$@"
}

# A failed S3 write leaves the object on the disk level only (sccache does not retry); re-put each one the server log names, so every miss reaches the shared level.
_sccache_s3_reupload_failed() {
  local log="${SCCACHE_ERROR_LOG:-/tmp/sccache.log}" disk="${SCCACHE_DIR:-/var/cache/sccache}" path key file n=0 ok=0
  local -a env=()
  sccache_s3_env env
  [ "${#env[@]}" -gt 0 ] || { _sccache_s3_log "sccache: no S3 level in this RUN, so nothing to re-upload"; return 0; }
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    n=$((n + 1))
    key="${path##*/}"
    # The disk level files a key as k[0]/k[1]/key, the S3 level as k[0]/k[1]/k[2]/key (sccache disk.rs, opendal).
    file="${disk}/${key:0:1}/${key:1:1}/${key}"
    if [ ! -f "${file}" ]; then
      printf 'sccache-drain| re-upload: %s is not on the disk level (%s)\n' "${key:0:12}" "${file}" >&2
      continue
    fi
    if _sccache_s3_put "${path}" "${file}" "${env[@]}"; then ok=$((ok + 1)); fi
  done < <(grep -oE 'service=s3 name=[^ ]+ path=[0-9a-f/]+' "${log}" 2>/dev/null | sed 's/.*path=//' | sort -u)
  printf 'sccache-drain| re-uploaded %d of %d failed write(s) from the disk level\n' "${ok}" "${n}" >&2
  return 0
}

# [timeout-s]: the RUN's end kills the server and drops its background uploads, so wait for them first.
sccache_s3_drain() {
  local limit="${1:-${SCCACHE_S3_DRAIN_TIMEOUT:-600}}" start now report=-30 pending failed tally
  : "${SCCACHE_SERVER_UDS:=/tmp/sccache-$(id -u).sock}"
  export SCCACHE_SERVER_UDS
  # Asking a server that is not there would start one.
  [ -S "${SCCACHE_SERVER_UDS}" ] && command -v sccache >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
  _sccache_stats_line
  start="$(date +%s)"
  while :; do
    read -r pending failed tally < <(_sccache_s3_pending) || true
    [ -n "${pending:-}" ] || return 0
    now=$(( $(date +%s) - start ))
    if [ "${pending}" -le 0 ]; then
      printf 'sccache-drain| every upload done after %d s (%s)\n' "${now}" "${tally}" >&2
      if [ "${failed:-0}" -ne 0 ]; then
        _sccache_s3_failure_reason
        _sccache_s3_reupload_failed
      fi
      return 0
    fi
    if [ "${now}" -ge "${limit}" ]; then
      _sccache_s3_log "sccache: ${pending} upload(s) still pending after ${limit} s (${tally}); the RUN's end drops them, and a later build uploads them again"
      return 0
    fi
    if [ $(( now - report )) -ge 30 ]; then
      printf 'sccache-drain| %d upload(s) pending after %d s (%s)\n' "${pending}" "${now}" "${tally}" >&2
      report="${now}"
    fi
    sleep 2
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    drain) sccache_s3_drain "${2:-}"; exit 0 ;;
    *) printf 'usage: %s drain [timeout-s]\n' "${0##*/}" >&2; exit 2 ;;
  esac
fi
