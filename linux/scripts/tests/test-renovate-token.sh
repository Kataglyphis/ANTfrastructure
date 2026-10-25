#!/usr/bin/env bash
# A live Renovate run needs an actual GitHub credential; this suite probes precedence and WSL gh.exe transport without using a real token.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "real symlinks for an isolated PATH" t_posix_symlinks
t_source_functions "${TESTS_DIR}/../renovate-cli.sh" renovate_github_cli || exit 1
t_source_functions "${TESTS_DIR}/../renovate-local.sh" resolve_github_token || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
EMPTY="${WORK}/empty"
mkdir -p "${BIN}" "${EMPTY}"
ln -sf "$(command -v bash)" "${BIN}/bash"
ln -sf "$(command -v env)" "${BIN}/env"
ln -sf "$(command -v bash)" "${EMPTY}/bash"
ln -sf "$(command -v env)" "${EMPTY}/env"

cat > "${BIN}/gh.exe" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = token ] || exit 1
printf 'fixture-windows-token\r\n'
GH
chmod +x "${BIN}/gh.exe"

token_probe() (
  local mode="$1" got=""
  unset GITHUB_COM_TOKEN GH_TOKEN
  PATH="${BIN}"
  err() { exit 1; }
  case "${mode}" in
    direct) GITHUB_COM_TOKEN=fixture-direct; export GH_TOKEN=fixture-gh ;;
    env) export GH_TOKEN=fixture-gh ;;
    exe) ;;
    none) PATH="${EMPTY}" ;;
  esac
  resolve_github_token || return 1
  got="${GITHUB_COM_TOKEN}"
  case "${mode}/${got}" in
    direct/fixture-direct|env/fixture-gh|exe/fixture-windows-token) return 0 ;;
  esac
  return 1
)

t_case "a direct token has precedence over GH_TOKEN and gh.exe"
t_assert_ok token_probe direct
t_case "GH_TOKEN is forwarded to Renovate when no direct token exists"
t_assert_ok token_probe env
t_case "WSL gh.exe fallback strips the Windows carriage return"
t_assert_ok token_probe exe
t_case "no credential is a fatal result"
t_assert_fails token_probe none

t_summary
