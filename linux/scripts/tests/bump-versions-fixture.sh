#!/usr/bin/env bash
# The bump suites' workspace and offline bump_versions.py snippets; source it from the suite's TESTS_DIR.
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh" || return 1
declare _WORK REPO
t_fixture_workspace_init _WORK REPO || return 1

# _bv_offline [args...] runs a snippet with the real module imported as bv; dependencies remain fixture-owned.
_bv_offline() {
  { printf 'import os, sys\nsys.path.insert(0, os.path.join(sys.argv[1], "docs/scripts"))\nimport bump_versions as bv\n'; cat; } \
    | python3 - "${REPO}" "$@"
}

# _bv_tags_offline <python list> [args...] -- the same, with ls_remote_tags answering that list.
_bv_tags_offline() {
  local tags="$1"
  shift
  { printf 'bv.ls_remote_tags = lambda repo: %s\n' "$tags"; cat; } | _bv_offline "$@"
}

# _audit_expr <python expression> [<pin file> <line>]... -- prints rc and its output on a copy of the real pin files, lines appended.
_audit_expr() {
  local expr="$1" dir
  dir="$(mktemp -d "${_WORK}/pins.XXXXXX")"
  shift
  cp "${REPO}/linux/scripts/01-core/versions.env" "${REPO}/linux/scripts/01-core/tool-pins.env" "${dir}/"
  while (( $# >= 2 )); do printf '%s\n' "$2" >> "${dir}/$1"; shift 2; done
  _bv_offline <<PY
from pathlib import Path
import bump_coverage
bv.VERSIONS_ENV = Path("${dir}/versions.env")
print("rc", ${expr})
PY
}

# _audit_pins <audit> [<pin file> <line>]... -- one bump_versions.py audit on that copy.
_audit_pins() {
  local audit="$1"
  shift
  _audit_expr "bv.${audit}()" "$@"
}
