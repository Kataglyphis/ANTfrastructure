#!/usr/bin/env bash
# verify_knob_order.py against planted shapes and the two GStreamer incidents; not covered: sourced definitions, cross-file callers; arguments select sections (-k shapes).
set -u
source "${BASH_SOURCE[0]%/*}/test-harness.sh"
source "${BASH_SOURCE[0]%/*}/gate-tree.sh"
SCRIPTS_DIR="${_T_SCRIPTS}"
GATE="${SCRIPTS_DIR}/verify_knob_order.py"
GST="${SCRIPTS_DIR}/03-media/build/gstreamer/common/setup-gstreamer.sh"
PY="${PREFLIGHT_PYTHON:-python3}"

_verdict() {
  local want="$1" why="$2" subject="$3" fix
  fix="$(gate_tree_subject knob-order.unused "${subject}" "" "${GATE}" "${SCRIPTS_DIR}/verify_code_size.py" \
    "${SCRIPTS_DIR}/quality_allow.py" "${SCRIPTS_DIR}/gate_scope.py")"
  t_assert_eq "${want}" "$(t_rc "${PY}" "${fix}/linux/scripts/verify_knob_order.py")" "${why}"
  rm -rf "${fix}"
}


_section_tree() {
  t_case "the tree has no read ahead of its default"
  t_assert_ok "${PY}" "${GATE}"
}

_section_shapes() {
  t_case "a top-level read ahead of a default in a function fails"
  _verdict 1 "the function has not run" $'f() {\n  : "${X:=1}"\n}\necho "${X}"\nf'
  t_case "the same read after the call passes"
  _verdict 0 "the call ran the default" $'f() {\n  : "${X:=1}"\n}\nf\necho "${X}"'
  t_case "a read in a function called before the default fails"
  _verdict 1 "call order, not file order" $'g() {\n  echo "$X"\n}\nf() {\n  : "${X:=1}"\n}\ng\nf'
  t_case "a read in a function called after the default passes"
  _verdict 0 "call order, not file order" $'g() {\n  echo "$X"\n}\nf() {\n  : "${X:=1}"\n}\nf\ng'
  t_case "a top-level default above every reader passes"
  _verdict 0 "defined at source time" $': "${X:=1}"\ng() {\n  echo "${X}"\n}\ng'
  t_case "a default behind && does not hold on every path"
  _verdict 1 "the false arm skips it" $'[ -n "${A:-}" ] && : "${X:=1}"\necho "${X}"'
  t_case "a default in an if without else does not hold after it"
  _verdict 1 "the skipped arm defines nothing" $'if [ -n "${A:-}" ]; then\n  : "${X:=1}"\nfi\necho "${X}"'
  t_case "a default in both arms holds after them"
  _verdict 0 "every arm defines it" $'if [ -n "${A:-}" ]; then\n  : "${X:=1}"\nelse\n  : "${X:=2}"\nfi\necho "${X}"'
  t_case "an arm that exits constrains nothing"
  _verdict 0 "that path never reads" $'if [ -n "${A:-}" ]; then\n  : "${X:=1}"\nelse\n  exit 1\nfi\necho "${X}"'
  t_case "a case without a star arm does not hold after it"
  _verdict 1 "no arm may match" $'case "${A:-}" in\n  a) : "${X:=1}" ;;\nesac\necho "${X}"'
  t_case "a case with a star arm defining it holds"
  _verdict 0 "every arm defines it" $'case "${A:-}" in\n  a) : "${X:=1}" ;;\n  *) : "${X:=2}" ;;\nesac\necho "${X}"'
  t_case "a default after an early return does not leave the function"
  _verdict 1 "return 0 skips it" $'f() {\n  [ -n "${A:-}" ] && return 0\n  : "${X:=1}"\n}\nf\necho "${X}"'
  t_case "a default in a command substitution stays in the child"
  _verdict 1 "the subshell's assignment is gone" $'f() {\n  : "${X:=1}"\n}\nv="$(f)"\necho "${X}${v}"'
  t_case "a default inside a loop does not hold after it"
  _verdict 1 "the loop may not run" $'for i in ${LIST:-}; do\n  : "${X:=1}"\ndone\necho "${X}"'
  t_case "an operator inside a default's substitution is not a guard"
  _verdict 0 "the separators belong to the child shell" $': "${X:=$(a && b || c)}"\necho "${X}"'
  t_case "a read through a callback runs at its mention"
  _verdict 1 "retry runs g before f" $'g() {\n  echo "${X}"\n}\nf() {\n  : "${X:=1}"\n}\nretry 3 1 d g\nf'
  t_case "a helper is walked under its caller, not on its own"
  _verdict 0 "the only caller defaulted first" $'helper() {\n  echo "${X}"\n}\nentry() {\n  : "${X:=1}"\n  helper\n}'
  t_case "two library entries have no order"
  _verdict 1 "nothing orders them" $'reader() {\n  echo "${X}"\n}\nsetter() {\n  : "${X:=1}"\n}'
  t_case "guarded forms are not reads"
  _verdict 0 ":- cannot abort" $'echo "${X:-}${X+y}${X:+z}"\nf() {\n  : "${X:=1}"\n}\nf'
  t_case "a read after an emptiness test passes"
  _verdict 0 "the author handled unset" $'g() {\n  [ -n "${X:-}" ] || return 0\n  echo "${X}"\n}\nf() {\n  : "${X:=1}"\n}\ng\nf'
  t_case "a local shadows the knob"
  _verdict 0 "this name is the function's own" $'g() {\n  local X=2\n  echo "${X}"\n}\nf() {\n  : "${X:=1}"\n}\ng\nf'
  t_case "export without a value defines nothing"
  _verdict 1 "export X leaves it unset" $'export X\necho "${X}"\nf() {\n  : "${X:=1}"\n}\nf'
  t_case "a comment, a single quote and a heredoc do not read"
  _verdict 0 "none of these expand" $'# ${X}\necho \'${X}\'\ncat <<\'E\'\n${X}\nE\nf() {\n  : "${X:=1}"\n}\nf'
}

# <knob> <anchor regex>: the real script with that knob's top-level default moved under the anchor.
_gst_moved() {
  local knob="$1" anchor="$2" fix
  fix="$(gate_tree_subject knob-order.unused "" "" "${GATE}" "${SCRIPTS_DIR}/verify_code_size.py" \
    "${SCRIPTS_DIR}/quality_allow.py" "${SCRIPTS_DIR}/gate_scope.py")"
  sed -E -e "/^: \"\\\$\{${knob}:=/d" "${GST}" \
    | sed -e "/${anchor}/a\\  : \"\${${knob}:=x}\"" > "${fix}/linux/scripts/subject.sh"
  t_assert_eq "1" "$(t_rc "${PY}" "${fix}/linux/scripts/verify_knob_order.py")" "${knob} moved under ${anchor}"
  t_assert_contains "$("${PY}" "${fix}/linux/scripts/verify_knob_order.py" 2>&1)" "${knob} read" "the row names the knob"
  rm -rf "${fix}"
}

_section_gstreamer() {
  t_case "GSTREAMER_DEBUG_LOGS defaulted inside save_logs is caught"
  _gst_moved GSTREAMER_DEBUG_LOGS '^save_logs() {$'
  t_case "GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR defaulted inside one wrapper is caught"
  _gst_moved GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR '^prepare_cargo_host_linker_wrapper() {$'
}

_section_root() {
  t_case "--root grades the tree it is handed"
  gate_root_arm "${PY}" "${GATE}" $'f() {\n  : "${X:=1}"\n}\necho "${X}"\nf'
}

t_sections _section_tree _section_shapes _section_gstreamer _section_root -- "$@"

t_summary
