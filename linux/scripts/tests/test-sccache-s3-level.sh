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
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${WORK}/s.sock" 2>/dev/null || true
  PATH="${WORK}/bin:${PATH}" SCCACHE_SERVER_UDS="${WORK}/s.sock" bash "${LIB}" drain "${2:-}" 2>&1
}
level() { printf '{"name":"%s","writes":%d,"write_failures":%d}' "$1" "$2" "$3"; }

t_case "the drain reports a finished chain, waits out its limit on a stuck one, and skips a single level"
t_assert_contains "$(_drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 20 0),$(level 'L1 (s3)' 18 2)]}}")" \
  "every upload done after 0 s (L1 (s3): 18 written, 2 failed of 20)"
t_assert_contains "$(_drain "{\"stats\":{\"multi_level\":[$(level 'L0 (disk)' 20 0),$(level 'L1 (s3)' 5 0)]}}" 0)" \
  "15 upload(s) still pending after 0 s"
t_assert_eq "" "$(_drain '{"stats":{"multi_level":null}}')" "a server without a chain has nothing to drain"
rm -f "${WORK}/s.sock"
t_assert_eq "" "$(PATH="${WORK}/bin:${PATH}" SCCACHE_SERVER_UDS="${WORK}/s.sock" bash "${LIB}" drain 2>&1)" "no socket, no server to ask"

t_case "every Dockerfile RUN on the sccache mount carries the secret, the library, and ends in the drain"
bad="$(python3 - "${LINUX_DIR}" <<'EOF'
import glob, os, sys
for f in sorted(glob.glob(os.path.join(sys.argv[1], "Dockerfile.*"))):
    if f.endswith("Dockerfile.base"):  # base only initialises the caches; nothing there compiles
        continue
    lines = open(f).read().split("\n")
    i = 0
    while i < len(lines):
        if lines[i].startswith("RUN"):
            s = i
            while lines[i].rstrip().endswith("\\") or lines[i].lstrip().startswith("#"):
                i += 1
            b = "\n".join(lines[s:i + 1])
            if "target=/var/cache/sccache" in b:
                lib = "source=linux/scripts/01-core," in b or "source=linux/scripts/01-core/sccache-s3-level.sh," in b
                if not (lib and "type=secret,id=sccache_s3,required=false" in b and b.rstrip().endswith("sccache-s3-level.sh drain")):
                    print("%s:%d" % (os.path.basename(f), s + 1))
        i += 1
EOF
)"
t_assert_eq "" "${bad}" "RUNs missing the secret mount, the library or the closing drain"

t_case "the chain hands the host file over as one secret only when it is private, complete and reachable"
_drv() {
  local fn
  fn="$(t_fn_src "${TESTS_DIR}/../01-core/cross-stage-build.sh" _cross_build_append_sccache_s3_secret)" || return 1
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
