#!/usr/bin/env bash
# gate-tree.sh — throwaway trees for gate tests, since a gate finds its root from its own path. See docs/code-quality-tooling.md#trailing-conditional-returns-trailing-conditional
[ -n "${_GATE_TREE_SH_LOADED:-}" ] && return 0
_GATE_TREE_SH_LOADED=1

# gate_tree <module.py>... -> a plain tree with the modules beside the gate (no --root, so no git needed).
gate_tree() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/linux/scripts"
  cp "$@" "${dir}/linux/scripts/"
  printf '%s' "${dir}"
}

# gate_tree_subject <allow-name> <subject> <allow> <module.py>... -> tree with subject.sh, plus the allow file if non-empty.
gate_tree_subject() {
  local allow_name="$1" subject="$2" allow="$3" dir
  shift 3
  dir="$(gate_tree "$@")"
  printf '%s\n' "${subject}" > "${dir}/linux/scripts/subject.sh"
  [ -z "${allow}" ] || printf '%s\n' "${allow}" > "${dir}/linux/scripts/${allow_name}"
  printf '%s' "${dir}"
}

# gate_tree_here <parent> <gate> <rel dest> -> tree with a .sh gate installed at the depth it finds its root from.
gate_tree_here() {
  local dir; dir="$(mktemp -d "$1/tree.XXXXXX")"
  install -D -m 0755 "$2" "${dir}/$3"
  printf '%s' "${dir}"
}

# gate_tree_git <subject> [rel] [allow-name] [allow] -> committed checkout for --root; scripts/, never linux/scripts/.
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

# gate_root_arm <py> <gate> <subject> [<allow-name> <row> <needle>]: --root grades that tree and its freeze file. See docs/code-quality-tooling.md#the-scan-root-contract
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

# gate_root_pair_arm <py> <gate> <content> <rel-a> <rel-b> <allow-name>: a --root pair, frozen at its measured budget.
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

# gate_stub_recorder <path>: a gate stub logging argv to $HOOK_TEST_ARGV, exiting $HOOK_TEST_GATE_RC or _STALE_RC.
gate_stub_recorder() {
  cat > "$1" <<'STUB'
import os
import sys

with open(os.environ["HOOK_TEST_ARGV"], "a", encoding="utf-8", newline="\n") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ["HOOK_TEST_STALE_RC" if "--stale-check" in sys.argv
                        else "HOOK_TEST_GATE_RC"]))
STUB
}
