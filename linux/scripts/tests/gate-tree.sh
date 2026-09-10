#!/usr/bin/env bash
# gate-tree.sh — a throwaway repo root for one gate under test. A gate derives its
# scan root from its own path, so a fixture has to give it a tree of its own or it
# reads the real repo. Source it and plant subjects under <tree>/linux/scripts.
# docs/code-quality-tooling.md#trailing-conditional-returns-trailing-conditional
[ -n "${_GATE_TREE_SH_LOADED:-}" ] && return 0
_GATE_TREE_SH_LOADED=1

# gate_tree <module.py>... -> tree path; every module named is copied in beside the gate.
# A plain directory is enough. It was briefly a git checkout: the ratchet gates
# defaulted --root to their own ROOT, which reached gate_scope.resolve_root's
# git-toplevel check on every bare run and killed a mktemp -d fixture at "not a
# git checkout". The gates now default --root to None, which resolve_root has
# always documented as "the gate's own repo" and exempts from that check, so the
# init here would be dead weight with a comment claiming it was load-bearing.
gate_tree() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/linux/scripts"
  cp "$@" "${dir}/linux/scripts/"
  printf '%s' "${dir}"
}

# gate_tree_subject <allow-name> <subject content> <allow content> <module.py>...
# -> tree path with subject.sh planted, and <allow-name> only when non-empty.
gate_tree_subject() {
  local allow_name="$1" subject="$2" allow="$3" dir
  shift 3
  dir="$(gate_tree "$@")"
  printf '%s\n' "${subject}" > "${dir}/linux/scripts/subject.sh"
  [ -z "${allow}" ] || printf '%s\n' "${allow}" > "${dir}/linux/scripts/${allow_name}"
  printf '%s' "${dir}"
}

# gate_tree_here <parent dir> <gate path> <rel dest> -> tree path; the gate
# installed executable at the depth it resolves its own repo root from. For the
# .sh gates that live outside linux/scripts/ and cannot use gate_tree.
gate_tree_here() {
  local dir; dir="$(mktemp -d "$1/tree.XXXXXX")"
  install -D -m 0755 "$2" "${dir}/$3"
  printf '%s' "${dir}"
}

# gate_stub_recorder <path> — a stand-in for a python gate driven by a git hook:
# appends the argv it was handed, one invocation per line, to $HOOK_TEST_ARGV and
# exits with $HOOK_TEST_GATE_RC, or $HOOK_TEST_STALE_RC when handed --stale-check.
# The recorded argv is the only evidence of what a hook's own notices describe.
gate_stub_recorder() {
  cat > "$1" <<'STUB'
import os
import sys

with open(os.environ["HOOK_TEST_ARGV"], "a", encoding="utf-8") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ["HOOK_TEST_STALE_RC" if "--stale-check" in sys.argv
                        else "HOOK_TEST_GATE_RC"]))
STUB
}
