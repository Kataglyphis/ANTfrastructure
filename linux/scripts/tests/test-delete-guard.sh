#!/usr/bin/env bash
# Tests for .claude/hooks/guard-destructive-deletes.py — the Linux port of the
# PreToolUse guard. The PowerShell original needs pwsh, which this build host
# does not have, so the guard was INERT here. docs/failure-modes.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GUARD="${TESTS_DIR}/../../../.claude/hooks/guard-destructive-deletes.py"
PY="${PREFLIGHT_PYTHON:-python3}"

_decide() {
  printf '{"tool_input":{"command":%s}}' \
    "$("${PY}" -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
    | "${PY}" "${GUARD}" 2>/dev/null \
    | "${PY}" -c 'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])
except Exception: print("allow")'
}

t_case "the guard exists and is wired ahead of the PowerShell one"
t_assert_ok test -f "${GUARD}"
t_assert_contains "$(cat "${TESTS_DIR}/../../../.claude/settings.json")" \
  "guard-destructive-deletes.py" "pwsh is absent on this host, so .py must be first"

t_case "host-destroying commands are denied"
for _c in "rm -rf /" "rm -rf /usr/lib" "rm -rf \$HOME/*" "rm -rf ~/.ssh" \
          "rm -rf ~/.local/share/containerd" "dd if=/dev/zero of=/dev/sda" \
          "sudo apt-get purge nvidia-driver-560"; do
  t_assert_eq "deny" "$(_decide "${_c}")" "${_c}"
done

t_case "prose that MENTIONS a forbidden command is not a delete"
# A verb-only rule for the cache-prune commands was tried and removed: with no
# path to anchor on it denied its own commit message.
t_assert_eq "allow" "$(_decide "git commit -m documented that the cache prune is forbidden")"

t_case "legitimate cleanup still passes"
# Blanking the reclaimable path must also eat a trailing /*, or this reads as a
# bare `/*` and trips the filesystem-root rule.
for _c in "rm -rf ~/.cache/kata-buildcache/*" "rm -f /tmp/foo.bak" \
          "nerdctl rmi ghcr.io/kataglyphis/x:tag" "git rm --cached file" \
          "bash linux/host-config/prune-safe.sh"; do
  t_assert_eq "allow" "$(_decide "${_c}")" "${_c}"
done

t_case "the path check is scoped to the segment that deletes"
# Verb and path were matched across the WHOLE command, so deleting a scratch dir
# was denied whenever the command merely MENTIONED a system path. A preceding
# `cd` still counts, so a relative delete cannot escape its directory.
for _c in "rm -rf scratch && cc -o x /opt/gcc/bin/gcc" \
          "nerdctl run --rm -v /opt/x:/src img sh -c 'cp -r /src w'" \
          "rm -rf out/logs; grep -rn foo /usr/include"; do
  t_assert_eq "allow" "$(_decide "${_c}")" "${_c}"
done
for _c in "cd /usr && rm -rf *" "cd /opt/libcamera && rm -rf lib"; do
  t_assert_eq "deny" "$(_decide "${_c}")" "${_c}"
done

t_case "a quoted span is not cut into segments"
# The splitter used a regex, so `|` and newlines inside a quoted string ended a
# segment and the quote-stripping below had nothing to strip. A status line that
# merely SAID "rm" landed in the same segment as a bare / from `df -h /`, and a
# legitimate container removal was denied. docs/failure-modes.md#the-delete-guard-denies-its-own-legitimate-work
_MIX="nerdctl rm abc123 | sed 's/x/y/'
echo \"  after rm+rmi: \$(df -h / | tail -1)\""
t_assert_eq "allow" "$(_decide "${_MIX}")" "prose naming rm beside df -h / must not deny"
t_assert_eq "allow" "$(_decide "echo \"tidy up: rm -rf / would be bad\"")" \
  "a quoted sentence about rm -rf / is prose, not a delete"
# and the guard must still bite through the same shapes
for _c in "echo start | rm -rf /" "cd /opt && rm -rf * | tee log"; do
  t_assert_eq "deny" "$(_decide "${_c}")" "${_c}"
done

t_summary
