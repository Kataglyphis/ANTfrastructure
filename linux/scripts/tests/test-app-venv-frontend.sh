#!/usr/bin/env bash
# The app venv carries OrchestrANT's frontend extra (CON106) and both venv gates hold it per arch; recorded inputs only.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ASSEMBLE="${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh"
STV="${TESTS_DIR}/../06-packaging/smoke-torch-venv.sh"

_SB="$(t_rt_sandbox)"; _WORK="$(mktemp -d)"; trap 'rm -rf "${_SB}" "${_WORK}"' EXIT
_rt() { t_rt_call "${_SB}" "$1"; }

t_case "build_uv_sync_args asks uv for ml-ai, docs and frontend"
_bua="$(t_fn_src "${ASSEMBLE}" build_uv_sync_args)" || exit 1
_args="$(bash -c "uv() { :; }"$'\n'"${_bua//\/opt\/wheels/${_WORK}}"$'\n''declare -a a=() s=(); PYTORCH_EXTRA=none build_uv_sync_args a s; printf "%s\n" "${a[@]}"' 2>&1)"
for _e in ml-ai docs frontend; do
  t_assert_contains "${_args}" $'--extra\n'"${_e}" "extra ${_e}"
done

t_case "VENV-SET's contract holds frontend on amd64 and arm64, and leaves it out on riscv64"
t_assert_eq "ml-ai docs frontend" "$(_rt '_venv_contract_extras amd64')" "amd64"
t_assert_eq "ml-ai docs frontend" "$(_rt '_venv_contract_extras arm64')" "arm64"
t_assert_eq "ml-ai docs" "$(_rt '_venv_contract_extras riscv64')" "riscv64"

# _venvset <arch> <REQ lines> <installed packages>: the verdict lines for a recorded probe.
_venvset() {
  REQS="$2" PKGS="$3" _rt "p=\"\$(printf 'ADV PYTORCH_EXTRA none\n%s\n' \"\${REQS}\"; printf 'PKG %s\n' \${PKGS})\"; _venv_set_verdicts $1 \"\${p}\""
}
_REQS=$'REQ ml-ai pandas\nREQ docs sphinx\nREQ frontend flet\nREQ frontend flet-web'

t_case "VENV-SET: a declared frontend package missing from an amd64 venv is a MISS"
_out="$(_venvset amd64 "${_REQS}" 'pandas sphinx flet')"
t_assert_contains "${_out}" "MISS frontend flet-web" "flet-web absent"
t_assert_contains "$(_venvset amd64 "${_REQS}" 'pandas sphinx flet flet-web')" "ASSERTED 4" "all present"

t_case "VENV-SET: an amd64 app with no frontend edge at all fails as NOREQ, not as a pass"
t_assert_contains "$(_venvset amd64 $'REQ ml-ai pandas\nREQ docs sphinx' 'pandas sphinx')" "NOREQ frontend" "extra renamed or truncated"

t_case "VENV-SET: riscv64, where the markers drop every frontend edge, raises no NOREQ"
_out="$(_venvset riscv64 $'REQ ml-ai pandas\nREQ docs sphinx' 'sphinx')"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e '^NOREQ' || true)" "no NOREQ on riscv64"

# _parity <arch> <dist...>: APP-PARITY's probe over fake dist-info trees for the given names.
_PROBE="${_WORK}/parity.py"
awk '/^_stv_probe_app_venv_parity\(\) \{$/ {f=1; next} f && /^PYEOF$/ {exit} f == 2 {print} f && /<<.PYEOF.$/ {f=2}' "${STV}" > "${_PROBE}"
t_case "the APP-PARITY probe was extracted"
t_assert_contains "$(cat "${_PROBE}")" 'print("APP-PARITY: PASS")' "probe body"
_parity() {
  local arch="$1" d; shift
  d="$(mktemp -d "${_WORK}/site.XXXXXX")"
  for _n in "$@"; do
    mkdir -p "${d}/${_n//-/_}-1.0.dist-info"
    printf 'Metadata-Version: 2.1\nName: %s\nVersion: 1.0\n' "${_n}" > "${d}/${_n//-/_}-1.0.dist-info/METADATA"
  done
  STV_ARCH="${arch}" PYTHONPATH="${d}" python3 -S "${_PROBE}" 2>&1; printf 'rc=%s\n' "$?"
}
_COMMON=(pandas scipy scikit-learn optuna mlflow boto3 iree-base-compiler sphinx sphinx-book-theme sphinx-design myst-parser)
_FRONT=(flet flet-desktop flet-web fastapi)

t_case "APP-PARITY: amd64 needs every frontend package"
t_assert_contains "$(_parity amd64 "${_COMMON[@]}" "${_FRONT[@]}")" "APP-PARITY: PASS" "all present"
_out="$(_parity amd64 "${_COMMON[@]}" flet flet-web fastapi)"
t_assert_contains "${_out}" "flet-desktop         MISSING" "flet-desktop absent"
t_assert_contains "${_out}" "rc=1" "and the gate fails"

t_case "APP-PARITY: riscv64 records the frontend absences, and a present one is stale"
_out="$(_parity riscv64 optuna sphinx sphinx-book-theme sphinx-design myst-parser)"
t_assert_contains "${_out}" "APP-PARITY: PASS" "documented exemptions"
t_assert_contains "${_out}" "flet-web             absent on riscv64 BY DECISION" "flet-web exempt"
t_assert_contains "$(_parity riscv64 optuna sphinx sphinx-book-theme sphinx-design myst-parser flet)" \
  "flet                 1.0 is INSTALLED but listed EXEMPT on riscv64" "stale exemption"

t_summary
