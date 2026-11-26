#!/usr/bin/env bash
# runtime_push_tag with a stub nerdctl: the push runs quiet unless asked, keeps its error text, and logs its duration.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RBF="${TESTS_DIR}/../01-core/runtime-push.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

_FNS="$(t_fn_src "${RBF}" _runtime_push_attempt)" || exit 1
_FNS+=$'\n'"$(t_fn_src "${RBF}" _runtime_zstd_convert)" || exit 1
_FNS+=$'\n'"$(t_fn_src "${RBF}" runtime_push_tag)" || exit 1

# The stub records its argv and prints what $PUSH_OUT holds; $PUSH_RC is its exit code, $CONVERT_RC the conversion's, $TAG_RC the retag's.
cat > "${WORK}/nerdctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ARGV_LOG}"
# nerdctl 2.4's in-place convert loses the manifest it reads, so a convert onto its own source fails here as it does there.
[ "$1 $2" = "image convert" ] && { [ "$5" != "$6" ] || exit 9; exit "${CONVERT_RC:-0}"; }
[ "$1" = tag ] && exit "${TAG_RC:-0}"
[ "$1" = rmi ] && exit 0
[ -z "${PUSH_OUT:-}" ] || printf '%s\n' "${PUSH_OUT}"
exit "${PUSH_RC:-0}"
EOF
chmod +x "${WORK}/nerdctl"

_push() {
  : > "${WORK}/argv"
  ARGV_LOG="${WORK}/argv" NERDCTL_BIN="${WORK}/nerdctl" PUSH_MAX_ATTEMPTS=1 TMPDIR="${WORK}" \
    bash -c 'eval "$1"
      log() { echo "LOG $*"; }; warn() { echo "WARN $*"; }; run() { "$@"; }
      runtime_push_tag ghcr.io/x/y:latest-amd64' _ "${_FNS}" 2>&1
}

convert='image convert --zstd --oci ghcr.io/x/y:latest-amd64 ghcr.io/x/y:latest-amd64-zstd'$'\n''tag ghcr.io/x/y:latest-amd64-zstd ghcr.io/x/y:latest-amd64'$'\n''rmi ghcr.io/x/y:latest-amd64-zstd'

t_case "the push runs with --quiet by default, and with its progress on RUNTIME_PUSH_PROGRESS=1"
out="$(_push)"
t_assert_eq "${convert}"$'\n'"push ghcr.io/x/y:latest-amd64 --quiet" "$(cat "${WORK}/argv")" "default argv"
t_assert_contains "${out}" "LOG [push] ghcr.io/x/y:latest-amd64: rc=0 after "
RUNTIME_PUSH_PROGRESS=1 _push >/dev/null
t_assert_eq "${convert}"$'\n'"push ghcr.io/x/y:latest-amd64" "$(cat "${WORK}/argv")" "RUNTIME_PUSH_PROGRESS=1 argv"

t_case "the layers become zstd before the push (CON99); CROSS_LAYER_COMPRESSION=gzip pushes them as built"
CROSS_LAYER_COMPRESSION=gzip _push >/dev/null
t_assert_eq "push ghcr.io/x/y:latest-amd64 --quiet" "$(cat "${WORK}/argv")" "gzip argv"
t_case "a failed conversion pushes nothing and fails"
rc=0; CONVERT_RC=1 _push >/dev/null || rc=$?
t_assert_eq "image convert --zstd --oci ghcr.io/x/y:latest-amd64 ghcr.io/x/y:latest-amd64-zstd" "$(cat "${WORK}/argv")" "no retag and no push after a failed conversion"
t_assert_eq 1 "${rc}" "the conversion's failure is the push's"

t_case "a failed retag pushes nothing and fails"
rc=0; TAG_RC=1 _push >/dev/null || rc=$?
t_assert_eq 0 "$(grep -c -e '^push ' "${WORK}/argv")" "no push after a failed retag"
t_assert_eq 1 "${rc}"

t_case "a failed quiet push still shows its error and its rc"
out="$(PUSH_RC=1 PUSH_OUT='level=fatal msg="use of closed network connection"' _push)"
t_assert_contains "${out}" "use of closed network connection"
t_assert_contains "${out}" "rc=1 after "

t_summary
