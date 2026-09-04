#!/usr/bin/env bash
# gate-tree.sh — a throwaway repo root for one gate under test. A gate derives its
# scan root from its own path, so a fixture has to give it a tree of its own or it
# reads the real repo. Source it and plant subjects under <tree>/linux/scripts.
# docs/code-quality-tooling.md#trailing-conditional-returns-trailing-conditional
[ -n "${_GATE_TREE_SH_LOADED:-}" ] && return 0
_GATE_TREE_SH_LOADED=1

# gate_tree <module.py>... -> tree path; every module named is copied in beside the gate.
gate_tree() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/linux/scripts"
  cp "$@" "${dir}/linux/scripts/"
  printf '%s' "${dir}"
}
