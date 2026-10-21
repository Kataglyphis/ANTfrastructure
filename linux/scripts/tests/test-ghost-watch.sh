#!/usr/bin/env bash
# ghost-watch.sh over a fake ps listing of the 2026-10-21 build host: which orphans it reports, and which it leaves alone.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GW="${TESTS_DIR}/../../host-config/ghost-watch.sh"
_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# pid ppid etimes pcpu rss(kB) args; 2348 plays the user's systemd.
cat > "${_WORK}/ps" <<'EOF'
2701278 1 237600 94.9 3500 bash ./t.sh
4127676 1 4000 3.1 235484 /opt/google/chrome/chrome --headless=new --no-sandbox --user-data-dir=/tmp/docs-sidebars-x
4127700 1 300 2.0 235484 /opt/google/chrome/chrome --headless=new --user-data-dir=/tmp/docs-sidebars-y
1887506 2348 230000 1.3 1900000 /usr/bin/gnome-shell --mode=ubuntu
4207 1 350000 1.9 11052 /usr/local/bin/ollama serve
1213870 1 6000 0.0 4564 bash linux/scripts/build-cross-chain.sh --target-arches amd64
500 2348 90000 60.0 20000 python3 /home/u/runaway.py
600 4242 90000 99.0 20000 cc1plus -O2 big.cpp
700 1 90000 0.5 2000000 node /home/u/leaky-server.js
800 1 90000 0.1 3000 sleep 3600
EOF
_gw() { GHOST_WATCH_PS_FILE="${_WORK}/ps" GHOST_WATCH_MANAGER_PID=2348 GHOST_WATCH_ALLOW="${_WORK}/allow" bash "${GW}" "$@" 2>&1; }

t_case "the spinning fixture, an old headless Chrome and orphans heavy on CPU or memory are reported"
out="$(_gw)"; rc=$?
t_assert_eq "1" "${rc}" "ghosts must exit 1"
t_assert_contains "${out}" "4 orphaned process(es) older than 60 min"
t_assert_contains "${out}" $'2701278\t66h00m'
t_assert_contains "${out}" "4127676"
t_assert_contains "${out}" "500"$'\t'
t_assert_contains "${out}" "leaky-server.js"

t_case "a young orphan, a process with a live parent, the desktop and the allowlisted services are not"
t_assert_fails grep -q '^4127700' <<<"${out}"
t_assert_fails grep -q '^600' <<<"${out}"
t_assert_fails grep -qE 'gnome-shell|ollama|build-cross-chain|sleep 3600' <<<"${out}"

t_case "the host's allow file and --min-age-min narrow the report"
printf '# a comment\nleaky-server\\.js\n\n' > "${_WORK}/allow"
t_assert_contains "$(_gw)" "3 orphaned process(es)"
rm -f "${_WORK}/allow"
t_assert_contains "$(_gw --min-age-min=1)" "5 orphaned process(es) older than 1 min"

t_case "nothing to report exits 0 and prints nothing; bad arguments exit 2"
printf '4207 1 350000 1.9 11052 /usr/local/bin/ollama serve\n' > "${_WORK}/ps"
out="$(_gw)"; rc=$?
t_assert_eq "0|" "${rc}|${out}"
t_rc_is() { local want="$1"; shift; "$@" >/dev/null 2>&1; t_assert_eq "${want}" "$?"; }
t_rc_is 2 _gw --min-age-min=abc
t_rc_is 2 _gw --frobnicate

t_summary
