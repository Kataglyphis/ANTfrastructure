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

# gate_tree_git <subject content> [rel] [allow-name] [allow content] -> tree path.
#
# The --root arm needs a fixture the other builders here cannot give it. Rule 1
# of the scan-root contract refuses a --root that is not a git TOPLEVEL, and
# rule 3 reads the scope from `git ls-files` -- so a plain `mktemp -d` tree, the
# shape every fixture above uses, cannot exercise --root at all: the gate exits 2
# before grading anything. This one is a real checkout with the subject
# COMMITTED, and the subject deliberately sits at scripts/, NOT linux/scripts/,
# so a gate that ignored --root and graded its own repo could not accidentally
# find it there either.
gate_tree_git() {
  local content="$1" rel="${2:-scripts/subject.sh}" allow_name="${3-}" allow="${4-}" dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/$(dirname "${rel}")"
  printf '%s\n' "${content}" > "${dir}/${rel}"
  [ -z "${allow_name}" ] || printf '%s\n' "${allow}" > "${dir}/${allow_name}"
  git -C "${dir}" init -q
  t_git_commit "${dir}"
  printf '%s' "${dir}"
}

# gate_root_arm <py> <gate> <subject> [<allow-name> <row> <needle>]
#
# The two assertions every --root case makes, written once: the gate must NAME
# the fixture's subject (which this repo does not have), and a row planted at
# <root>/<allow-name> must come back in the output (which happens only if the
# freeze file followed the root). A gate with no freeze file passes three
# arguments. Every other fixture here plants a tree AROUND the gate, so no other
# case reaches --root -- the one argument a consumer depends on.
# docs/code-quality-tooling.md#the-scan-root-contract
gate_root_arm() {
  local py="$1" gate="$2" subject="$3" allow_name="${4-}" row="${5-}" needle="${6-}" fx
  fx="$(gate_tree_git "${subject}")"
  t_assert_contains "$("${py}" "${gate}" --root "${fx}" 2>&1)" "subject.sh"     "the gate must grade the tree it was handed; this repo has no subject.sh"
  rm -rf "${fx}"
  if [ -n "${allow_name}" ]; then
    fx="$(gate_tree_git "${subject}" scripts/subject.sh "${allow_name}" "${row}")"
    t_assert_contains "$("${py}" "${gate}" --root "${fx}" 2>&1)" "${needle}"       "the freeze file must resolve to <root>/${allow_name}"
    rm -rf "${fx}"
  fi
}

# gate_root_pair_arm <py> <gate> <content> <rel-a> <rel-b> <allow-name>
#
# The --root arm for the two DUPLICATION gates, which need a PAIR rather than one
# subject: plant the same text at two paths in a throwaway checkout, prove the
# gate finds the pair THERE, then freeze it at the measured budget in
# <root>/<allow-name> and prove that silences it. The budget is read back from
# the gate's own report, never written as a round number: both gates fail a
# budget sitting above the measurement, which is the whole point of a ratchet.
gate_root_pair_arm() {
  local py="$1" gate="$2" content="$3" a="$4" b="$5" allow_name="$6" fx n
  fx="$(gate_tree_git "${content}" "${a}")"
  mkdir -p "$(dirname "${fx}/${b}")"
  printf '%s\n' "${content}" > "${fx}/${b}"
  t_git_commit "${fx}"
  t_assert_eq "1" "$(t_rc "${py}" "${gate}" --root "${fx}")" \
    "the fixture pair is a finding; this repo's own twins are all budgeted"
  t_assert_contains "$("${py}" "${gate}" --root "${fx}" 2>&1)" "${b}" \
    "the finding must name the fixture"
  n="$("${py}" "${gate}" --root "${fx}" 2>&1 | sed -n 's/^  \([0-9]*\) shared shingles.*/\1/p' | head -1)"
  printf '%s | %s | %s | fixture budget\n' "${a}" "${b}" "${n}" > "${fx}/${allow_name}"
  t_assert_eq "0" "$(t_rc "${py}" "${gate}" --root "${fx}")" \
    "silenced only if <root>/${allow_name} was the file read"
  rm -rf "${fx}"
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
