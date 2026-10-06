#!/usr/bin/env bash
# _cargo_wrapper.sh's safe.directory guard against a real git in a throwaway HOME, and that every cargo_*.sh driver sources it.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RUST_DIR="$(cd "${TESTS_DIR}/../02-toolchain/rust" && pwd)"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# _safe_dirs [VAR=value...]: sources the wrapper twice in a fresh HOME and prints the safe.directory entries git holds.
_safe_dirs() {
  local home; home="$(mktemp -d "${_WORK}/home.XXXXXX")"
  # MSYS_NO_PATHCONV: Git Bash would rewrite /workspace into a Windows path on its way to git.exe.
  env HOME="${home}" XDG_CONFIG_HOME="${home}/xdg" GIT_CONFIG_NOSYSTEM=1 CARGO_HOME="${home}/cargo-home" MSYS_NO_PATHCONV=1 "$@" bash -c '
    source "$1/_cargo_wrapper.sh" >/dev/null 2>&1
    source "$1/_cargo_wrapper.sh" >/dev/null 2>&1
    git config --global --get-all safe.directory | tr "\n" " "
  ' _ "${RUST_DIR}" 2>/dev/null
}

t_case "the default is /workspace, the bind mount the family images use"
t_assert_eq "/workspace " "$(_safe_dirs)"

t_case "CARGO_SAFE_DIRECTORY names another checkout"
t_assert_eq "/src/oxidant " "$(_safe_dirs CARGO_SAFE_DIRECTORY=/src/oxidant)"

t_case "an empty value opts out, as CMAKE_BUILD_SAFE_DIRECTORY does"
t_assert_eq "" "$(_safe_dirs CARGO_SAFE_DIRECTORY=)"

t_case "sourcing it again adds nothing: every driver run would otherwise grow the global gitconfig"
t_assert_eq "1" "$(_safe_dirs | wc -w | tr -d ' ')"

# _install_pinned <have-version>: a fake tool reporting that version, a fake cargo logging its argv; prints the installs.
_install_pinned() {
  local home bin; home="$(mktemp -d "${_WORK}/pin.XXXXXX")"; bin="${home}/bin"
  mkdir -p "${bin}"
  [ -n "$1" ] && printf '#!/usr/bin/env bash\necho "cargo-deny %s"\n' "$1" > "${bin}/cargo-deny"
  printf '#!/usr/bin/env bash\necho "cargo $*" >> "%s/cargo.log"\n' "${home}" > "${bin}/cargo"
  chmod +x "${bin}"/*
  touch "${home}/cargo.log"
  # The fakes go first again after sourcing: in the image the toolchain guard hoists /usr/local/cargo/bin.
  env HOME="${home}" XDG_CONFIG_HOME="${home}/xdg" GIT_CONFIG_NOSYSTEM=1 CARGO_HOME="${home}/cargo-home" CARGO_SAFE_DIRECTORY= \
    PATH="${bin}:${PATH}" bash -c 'source "$1/_cargo_wrapper.sh" >/dev/null 2>&1; PATH="$2:${PATH}"
      cargo_install_pinned cargo-deny 0.20.2 >/dev/null 2>&1' _ "${RUST_DIR}" "${bin}"
  # The wrapper's toolchain guard asks cargo for its version while sourcing.
  grep '^cargo install' "${home}/cargo.log" || true
}

t_case "the image's pinned tool is used as it is: no cargo install"
t_assert_eq "" "$(_install_pinned 0.20.2)"

t_case "another version, or none, is built at the pin with --locked"
t_assert_eq "cargo install --locked --version 0.20.2 cargo-deny" "$(_install_pinned 0.19.0)"
t_assert_eq "cargo install --locked --version 0.20.2 cargo-deny" "$(_install_pinned '')"

t_case "every cargo_*.sh driver goes through the wrapper"
for driver in "${RUST_DIR}"/cargo_*.sh; do
  t_assert_eq "1" "$(grep -c '_cargo_wrapper\.sh"' "${driver}")" "$(basename "${driver}") must source _cargo_wrapper.sh, or it skips the guards"
done

t_summary
