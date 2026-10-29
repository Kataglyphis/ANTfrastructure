#!/usr/bin/env bash
# sccache-s3-level.sh: the secret becomes the server's S3 level, never the build's env; a dead level falls back; the drain waits.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

LIB="${TESTS_DIR}/../01-core/sccache-s3-level.sh"
LINUX_DIR="${TESTS_DIR}/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# _fake_sccache <start: ok|fail-with-s3> <json>: records each start with whether it carried a key.
_fake_sccache() {
  mkdir -p "${WORK}/bin"
  cat > "${WORK}/bin/sccache" <<EOF
#!/bin/bash
case "\$1" in
  --version) echo "sccache 0.18.0" ;;
  --start-server)
    echo "start key=\${AWS_ACCESS_KEY_ID:-none} chain=\${SCCACHE_MULTILEVEL_CHAIN:-none}" >> "${WORK}/calls"
    if [ "$1" = fail-with-s3 ] && [ -n "\${AWS_ACCESS_KEY_ID:-}" ]; then
      echo "sccache: error: Server startup failed: AccessDenied" >&2; exit 2
    fi ;;
  --stop-server) echo stop >> "${WORK}/calls" ;;
  --show-stats) [ "\${2:-}" = --stats-format ] && cat "${WORK}/stats.json" ;;
esac
EOF
  chmod +x "${WORK}/bin/sccache"
  printf '%s' "$2" > "${WORK}/stats.json"
  : > "${WORK}/calls"
}

_secret() {
  printf '%s\n' "$@" > "${WORK}/secret"
}

FULL=(SCCACHE_BUCKET=sccache SCCACHE_ENDPOINT=http://127.0.0.1:1 SCCACHE_REGION=garage
  AWS_ACCESS_KEY_ID=GKtest AWS_SECRET_ACCESS_KEY=s3cret)

# _env_of <reachable: 0|1>: the NAME=value list sccache_s3_env builds, one per line, sorted.
_env_of() {
  bash -c 'source "$1"; _rc="$2"; sccache_s3_endpoint_reachable() { return "${_rc}"; }; a=(); sccache_s3_env a; printf "%s\n" "${a[@]}" | sort' _ "${LIB}" "$1" 2>&1
}

t_case "a complete secret becomes the S3 level, chained behind disk, and only whitelisted names pass"
_secret "${FULL[@]}" 'PATH=/evil' '# a comment' '' 'LD_PRELOAD=/x.so'
out="$(SCCACHE_S3_SECRET_FILE="${WORK}/secret" _env_of 0)"
t_assert_contains "${out}" "SCCACHE_MULTILEVEL_CHAIN=disk,s3"
t_assert_contains "${out}" "AWS_SECRET_ACCESS_KEY=s3cret"
t_assert_eq "" "$(printf '%s\n' "${out}" | grep -E '^(PATH|LD_PRELOAD)=' || true)" "a name off the whitelist reached the server"

t_case "no secret, a partial one, or a dead endpoint means no S3 level, each with its reason"
t_assert_eq "" "$(SCCACHE_S3_SECRET_FILE="${WORK}/absent" _env_of 0)" "a RUN without the secret must stay silent"
_secret SCCACHE_BUCKET=sccache SCCACHE_ENDPOINT=http://127.0.0.1:1
t_assert_contains "$(SCCACHE_S3_SECRET_FILE="${WORK}/secret" _env_of 0)" "has no AWS_ACCESS_KEY_ID -- no S3 level"
_secret "${FULL[@]}"
out="$(SCCACHE_S3_SECRET_FILE="${WORK}/secret" _env_of 1)"
t_assert_contains "${out}" "takes no TCP connection within 2 s"
t_assert_eq "" "$(printf '%s\n' "${out}" | grep '=' || true)" "an unreachable level still produced variables"

t_case "the TCP probe retries before a stage loses its S3 level"
t_assert_contains "$(t_fn_src "${LIB}" sccache_s3_endpoint_reachable)" 'for try in $(seq 1 "${SCCACHE_S3_PROBE_TRIES:-3}")' \
  "one 2 s connect lost a stage's level during a WireGuard re-handshake (2026-10-28)"

t_case "the TCP probe tells a listening port from a closed one"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(4); time.sleep(20)' "${port}" &
listener=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do bash -c ': >"/dev/tcp/127.0.0.1/$1"' _ "${port}" 2>/dev/null && break; sleep 0.2; done
t_assert_ok bash -c 'source "$1"; sccache_s3_endpoint_reachable "http://127.0.0.1:$2/"' _ "${LIB}" "${port}"
kill "${listener}" 2>/dev/null; wait "${listener}" 2>/dev/null
t_assert_fails bash -c 'source "$1"; sccache_s3_endpoint_reachable "http://127.0.0.1:$2"' _ "${LIB}" "${port}"

# _start <fake mode>: runs sccache_start_server with a reachable level; prints the log, then the build shell's key.
_start() {
  _fake_sccache "$1" '{}'
  _secret "${FULL[@]}"
  PATH="${WORK}/bin:${PATH}" SCCACHE_S3_SECRET_FILE="${WORK}/secret" SCCACHE_SERVER_UDS="${WORK}/no.sock" bash -c \
    'source "$1"; sccache_s3_endpoint_reachable() { return 0; }; sccache_start_server; echo "shell key=${AWS_ACCESS_KEY_ID:-none}"' _ "${LIB}" 2>&1
}

t_case "the server gets the key; the build shell never does"
out="$(_start ok)"
t_assert_contains "${out}" "sccache levels: disk"
t_assert_contains "${out}" "shell key=none"
t_assert_eq "start key=GKtest chain=disk,s3" "$(cat "${WORK}/calls")"

t_case "a server that will not start with the S3 level is restarted on disk alone"
out="$(_start fail-with-s3)"
t_assert_contains "${out}" "did not start with the S3 level (sccache: error: Server startup failed: AccessDenied) -- starting it on disk alone"
t_assert_eq "start key=GKtest chain=disk,s3|stop|start key=none chain=none" "$(paste -sd'|' "${WORK}/calls")"

t_case "without a socket (sccache < 0.14's TCP mode) the S3 level is never tried"
_fake_sccache ok '{}'
PATH="${WORK}/bin:${PATH}" SCCACHE_S3_SECRET_FILE="${WORK}/secret" bash -c 'unset SCCACHE_SERVER_UDS; source "$1"; sccache_start_server' _ "${LIB}"
t_assert_eq "start key=none chain=none" "$(cat "${WORK}/calls")"

# _drain <json> [timeout]: the drain's stderr against a fake server whose socket exists.
_drain() {
  _fake_sccache ok "$1"
  # Python startup crossing a wall-clock second must not change the drain fixture's verdict.
  printf '#!/usr/bin/env bash\nprintf "0\\n"\n' > "${WORK}/bin/date"
  chmod +x "${WORK}/bin/date"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${WORK}/s.sock" 2>/dev/null || true
  PATH="${WORK}/bin:${PATH}" SCCACHE_SERVER_UDS="${WORK}/s.sock" bash "${LIB}" drain "${2:-}" 2>&1
}
level() { printf '{"name":"%s","writes":%d,"write_failures":%d}' "$1" "$2" "$3"; }

t_case "the drain reports a finished chain, waits out its limit on a stuck one, and skips a single level"
t_assert_contains "$(_drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 20 0),$(level 'L1 (s3)' 18 2)]}}")" \
  "every upload done after 0 s (L1 (s3): 18 written, 2 failed of 20)"
t_assert_contains "$(_drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 20 0),$(level 'L1 (s3)' 5 0)]}}" 0)" \
  "15 upload(s) still pending after 0 s"
t_assert_eq "sccache-stats| 0 requests, 0 hits, 0 misses, 0 errors, 0 not cacheable" "$(_drain '{"stats":{"multi_level":null}}')" \
  "a server without a chain has nothing to drain, but still reports its totals"

t_case "the drain reports the RUN's compile totals and names why a write failed"
_stats='"compile_requests":414,"cache_hits":{"counts":{"C/C++":365}},"cache_misses":{"counts":{"C/C++":12}},"cache_errors":{"counts":{"C/C++":36}},"requests_not_cacheable":1,"non_cacheable_compilations":0'
t_assert_contains "$(_drain "{\"stats\":{${_stats},\"multi_level\":null}}")" \
  "sccache-stats| 414 requests, 365 hits, 12 misses, 36 errors, 1 not cacheable"
printf 'noise\nWARN level L1 (s3): PutObject failed: SlowDown\n' > "${WORK}/sccache.log"
_out="$(SCCACHE_ERROR_LOG="${WORK}/sccache.log" _drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 12 0),$(level 'L1 (s3)' 3 9)]}}")"
t_assert_contains "${_out}" "L1 (s3): 3 written, 9 failed of 12"
t_assert_contains "${_out}" "PutObject failed: SlowDown"
t_assert_contains "$(SCCACHE_ERROR_LOG="${WORK}/none.log" _drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 2 0),$(level 'L1 (s3)' 1 1)]}}")" \
  "says:
nothing about levels or S3"
t_assert_eq 0 "$(SCCACHE_ERROR_LOG="${WORK}/sccache.log" _drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 2 0),$(level 'L1 (s3)' 2 0)]}}" | grep -c 'failed writes')" \
  "a clean drain reads no log"
t_case "a failed S3 write is re-put from the disk level (sccache does not retry; 3 of 232 GStreamer objects stayed local on 2026-10-29)"
_key=a338e2ed182c58687268cd88c3630ca7b4f22b8771afd27e85872cd3bb624e7f
mkdir -p "${WORK}/disk/a/3" "${WORK}/disk/preprocessor/b/4/b" "${WORK}/s3"
printf 'object bytes' > "${WORK}/disk/a/3/${_key}"
printf 'preprocessor entry' > "${WORK}/disk/preprocessor/b/4/b/b4${_key:2}"
python3 - "${WORK}/s3" > "${WORK}/s3/port" 2>/dev/null <<'PY' &
import http.server, sys, threading
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(root + "/put", "w") as f:
            f.write("%s %s %s\n" % (self.path, self.headers.get("Authorization", ""), body.decode()))
        self.send_response(200); self.end_headers()
    def do_GET(self):
        if not self.path.endswith("/have.tgz"):
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", "9"); self.end_headers(); self.wfile.write(b"archive-9")
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
_s3pid=$!
until [ -s "${WORK}/s3/port" ]; do sleep 0.1; done
_port="$(cat "${WORK}/s3/port")"
printf 'SCCACHE_BUCKET=sccache\nSCCACHE_ENDPOINT=http://127.0.0.1:%s\nSCCACHE_REGION=garage\nAWS_ACCESS_KEY_ID=GKtest\nAWS_SECRET_ACCESS_KEY=secret\n' "${_port}" > "${WORK}/secret-s3"
printf '[ERROR opendal::services] service=s3 name=sccache path=a/3/3/%s written=12: write close failed Unexpected (temporary) at write => send http request\n' "${_key}" > "${WORK}/sccache.log"
_out="$(SCCACHE_S3_SECRET_FILE="${WORK}/secret-s3" SCCACHE_DIR="${WORK}/disk" SCCACHE_ERROR_LOG="${WORK}/sccache.log" _drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 2 0),$(level 'L1 (s3)' 1 1)]}}")"
t_assert_contains "${_out}" "re-uploaded 1 of 1 failed write(s) from the disk level" "the drain re-puts it: ${_out}"
t_assert_contains "$(cat "${WORK}/s3/put" 2>/dev/null)" "/sccache/a/3/3/${_key} AWS4-HMAC-SHA256 Credential=GKtest/" "a SigV4 PUT of the S3 path, under the bucket"
t_assert_contains "$(cat "${WORK}/s3/put" 2>/dev/null)" "/garage/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=" "signed for the secret's region"
t_assert_contains "$(cat "${WORK}/s3/put" 2>/dev/null)" " object bytes" "with the disk level's bytes"
printf '[ERROR opendal::services] service=s3 name=sccache path=preprocessor/b/4/b/%s written=1: write close failed\n' "b4${_key:2}" >> "${WORK}/sccache.log"
printf '[ERROR opendal::services] service=s3 name=sccache path=f/f/f/%s written=1: write close failed\n' "ffff${_key:4}" >> "${WORK}/sccache.log"
_out="$(SCCACHE_S3_SECRET_FILE="${WORK}/secret-s3" SCCACHE_DIR="${WORK}/disk" SCCACHE_ERROR_LOG="${WORK}/sccache.log" _drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 4 0),$(level 'L1 (s3)' 1 3)]}}")"
t_assert_contains "${_out}" "re-upload: ffff${_key:4:8} is not on the disk level" "a key the disk level evicted is named, not invented"
t_assert_contains "${_out}" "re-uploaded 2 of 3 failed write(s)" "a compile object (k0/k1/key on disk, k0/k1/k2/key in S3) and a preprocessor entry (its full path on both) are both found"
t_assert_contains "$(cat "${WORK}/s3/put" 2>/dev/null)" "/sccache/preprocessor/b/4/b/b4${_key:2} " "the preprocessor entry went up under its S3 path"
t_case "sccache_s3_fetch and sccache_s3_store move one object of the shared level with the RUN's secret"
_fetch() { SCCACHE_S3_SECRET_FILE="${WORK}/secret-s3" bash -c 'source "$1"; sccache_s3_fetch "$2" "$3"' _ "${LIB}" "$@" 2>&1; echo "rc=$?"; }
t_assert_contains "$(_fetch ccache/have.tgz "${WORK}/got.tgz")" "rc=0" "a present object is fetched"
t_assert_eq "archive-9" "$(cat "${WORK}/got.tgz" 2>/dev/null)" "byte for byte"
t_assert_contains "$(_fetch ccache/missing.tgz "${WORK}/none.tgz")" "rc=2" "an absent one says 2 (HTTP 404), the caller's cue to fill it"
t_assert_contains "$(SCCACHE_S3_SECRET_FILE="${WORK}/none" bash -c 'source "$1"; sccache_s3_store x "$2"' _ "${LIB}" "${WORK}/got.tgz" 2>&1; echo "rc=$?")" "rc=1" "no secret, no level: 1, nothing sent"
kill "${_s3pid}" 2>/dev/null || true
_out="$(SCCACHE_S3_SECRET_FILE="${WORK}/none" SCCACHE_DIR="${WORK}/disk" SCCACHE_ERROR_LOG="${WORK}/sccache.log" _drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 2 0),$(level 'L1 (s3)' 1 1)]}}")"
t_assert_contains "${_out}" "no S3 level in this RUN, so nothing to re-upload" "without the secret the drain only reports"

rm -f "${WORK}/s.sock"
t_assert_eq "" "$(PATH="${WORK}/bin:${PATH}" SCCACHE_SERVER_UDS="${WORK}/s.sock" bash "${LIB}" drain 2>&1)" "no socket, no server to ask"

# One pass over every Dockerfile RUN: "drain:" for a sccache RUN short of its secret, library or drain, "mounts:" for a compiling one without both caches.
bad="$(PYTHONPATH="${TESTS_DIR}" python3 - "${LINUX_DIR}" <<'EOF'
import glob, os, re, sys
from dockerfile_runs import dockerfile_runs
for f in sorted(glob.glob(os.path.join(sys.argv[1], "Dockerfile.*"))):
    for s, b in dockerfile_runs(f):
        where = "%s:%d" % (os.path.basename(f), s)
        # Dockerfile.base only initialises the caches; nothing there compiles.
        if "target=/var/cache/sccache" in b and not f.endswith("Dockerfile.base"):
            lib = "source=linux/scripts/01-core," in b or "source=linux/scripts/01-core/sccache-s3-level.sh," in b
            if not (lib and "type=secret,id=sccache_s3,required=false" in b and b.rstrip().endswith("sccache-s3-level.sh drain")):
                print("drain:" + where)
        if re.search(r"setup-dependencies\.sh\b[^;&|]*\b(vulkan|dockerfile-gcc|dockerfile-llvm|target-clang)\b", b):
            if not ("target=/var/cache/sccache" in b and "target=/var/cache/ccache" in b):
                print("mounts:" + where)
EOF
)"

t_case "every Dockerfile RUN on the sccache mount carries the secret, the library, and ends in the drain"
t_assert_eq "" "$(grep '^drain:' <<<"${bad}" || true)" "RUNs missing the secret mount, the library or the closing drain"

t_case "every RUN whose setup-dependencies.sh command compiles mounts both compiler caches"
t_assert_eq "" "$(grep '^mounts:' <<<"${bad}" || true)" "compiling RUNs without the compiler-cache mounts"

t_case "the runtime lane's wrapper build hands the secret over, since Dockerfile.torch mounts it"
# Lost 2026-10-21: two runs compiled HailoRT with 0 hits, 32 min a run on arm64 under QEMU.
wrap="$(t_fn_src "${TESTS_DIR}/../01-core/runtime-build-fns.sh" _runtime_build_wrapper)" || wrap=""
t_assert_contains "${wrap}" "_cross_build_append_sccache_s3_secret _wrapper_build_args_out"

t_case "the chain hands the host file over as one secret only when it is private, complete and reachable"
_drv() {
  local fn
  fn="$(t_fn_src "${TESTS_DIR}/../01-core/cross-stage-build.sh" _cross_build_append_sccache_s3_secret)" || return 1
  fn+=$'\n'"$(t_fn_src "${TESTS_DIR}/../01-core/build-helpers.sh" host_secret_file_ready)" || return 1
  KATAGLYPHIS_SCCACHE_S3_FILE="${WORK}/host.env" bash -c 'eval "$1"; _rc="$2"
    warn() { echo "WARN $*"; }; info() { echo "INFO $*"; }
    sccache_s3_endpoint_reachable() { return "${_rc}"; }
    cmd=(build); _cross_build_append_sccache_s3_secret cmd; echo "argv=${cmd[*]}"' _ "${fn}" "$1" 2>&1
}
printf '%s\n' "${FULL[@]}" > "${WORK}/host.env"; chmod 600 "${WORK}/host.env"
t_assert_contains "$(_drv 0)" "argv=build --secret id=sccache_s3,src=${WORK}/host.env"
t_assert_contains "$(_drv 1)" "argv=build"
t_assert_contains "$(_drv 1)" "takes no TCP connection from this host"
t_assert_contains "$(KATAGLYPHIS_SCCACHE_S3=off _drv 0)" "argv=build"
t_assert_eq "" "$(KATAGLYPHIS_SCCACHE_S3=off _drv 0 | grep -e '--secret' || true)" "KATAGLYPHIS_SCCACHE_S3=off still passed the secret"
chmod 644 "${WORK}/host.env"
t_assert_contains "$(_drv 0)" "is readable by others (chmod 600 it)"
printf '%s\n' SCCACHE_BUCKET=sccache SCCACHE_ENDPOINT=http://x:1 > "${WORK}/host.env"; chmod 600 "${WORK}/host.env"
t_assert_contains "$(_drv 0)" "has no AWS_ACCESS_KEY_ID"

t_summary
