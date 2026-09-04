#!/usr/bin/env bash
# Characterisation tests for the extractor in verify_package_names.py: what counts as
# a package request, and which of them are guarded. Every case reads its rows back
# through the real `--list` CLI, so none depends on parser internals or the network.
# docs/cross-build-verification.md
set -u
source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
GATE=verify_package_names.py

# _tree <subject-relpath>: the gate + versions.env + subject .sh read from stdin.
_tree() {
  local root; root="$(t_gate_tree "${GATE}")"
  install -D -m 0644 /dev/stdin "${root}/linux/scripts/$1"
  printf 'UBUNTU_CODENAME=fixture\n' | install -D -m 0644 /dev/stdin \
    "${root}/linux/scripts/01-core/versions.env"
  printf '%s' "${root}"
}

# _list <subject-relpath> <subject-text>: the extracted rows, one per line.
_list() {
  local root out
  root="$(printf '%s\n' "$2" | _tree "$1")"
  out="$("${PY}" "${root}/linux/scripts/${GATE}" --list 2>&1)"
  rm -rf "${root}"
  printf '%s\n' "${out}" | grep -F "linux/scripts/$1:" || true
}

# _row <rows> <name>: the single row for one package name, or the empty string.
_row() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$2 == n'; }

t_case "a one-per-line array handed to an installer is extracted"
rows="$(_list 03-media/install-deps.sh 'PACKAGES=(
  libopenexr-dev
  dbus-x11 libsoxr-dev  # trailing comment
)
install_target_packages "${PACKAGES[@]}"')"
t_assert_contains "$(_row "${rows}" libopenexr-dev)" "array" "one name per line"
t_assert_contains "$(_row "${rows}" dbus-x11)" "array" "several names on one row"
t_assert_contains "$(_row "${rows}" libsoxr-dev)" "array" "a trailing comment ends the row, not the array"
t_assert_contains "$(_row "${rows}" libopenexr-dev)" "target" "the scope is the consuming installer's"

t_case "an array no installer is handed is not a request"
rows="$(_list 02-toolchain/android-sdk.sh 'sdk_packages=(
  platform-tools
)
echo "${sdk_packages[0]}"')"
t_assert_eq "" "$(_row "${rows}" platform-tools)" "sdkmanager components are not apt names"

t_case "a for-loop over the array is an installer hand-off"
rows="$(_list 01-core/loop.sh 'HOST_PACKAGES=(ccache)
for p in "${HOST_PACKAGES[@]}"; do
  apt_install "${p}"
done')"
t_assert_contains "$(_row "${rows}" ccache)" "array" "the loop installs it one name at a time"

t_case "a backslash-continued call site is one logical line"
rows="$(_list 03-media/deps.sh 'install_target_packages \
  libsndfile1-dev \
  libvvdec-dev')"
t_assert_contains "$(_row "${rows}" libsndfile1-dev)" "UNGUARDED"
t_assert_contains "$(_row "${rows}" libvvdec-dev)" "UNGUARDED" "the continuation is not a new statement"

t_case "the four ways a call site is guarded each name themselves"
t_assert_contains "$(_row "$(_list a/g1.sh 'install_target_packages libfoo-dev || true')" libfoo-dev)" \
  "|| fallback"
t_assert_contains "$(_row "$(_list a/g2.sh 'install_optional_target_packages libfoo-dev')" libfoo-dev)" \
  "self-filtering helper"
t_assert_contains "$(_row "$(_list a/g3.sh 'if apt_package_exists libfoo-dev; then
  install_target_packages libfoo-dev
fi')" libfoo-dev)" "apt probe in enclosing if"
t_assert_contains "$(_row "$(_list a/g4.sh 'if install_target_packages libfoo-dev; then :; fi')" libfoo-dev)" \
  "in a condition"

t_case "an unguarded request is the one that fails the gate"
t_assert_contains "$(_row "$(_list a/u.sh 'install_target_packages libfoo-dev')" libfoo-dev)" \
  "UNGUARDED" "this is the four-hours-in stage kill"

t_case "the append helpers' first argument is a destination array, not a package"
rows="$(_list 01-core/package-lists.sh 'append_unique_packages hostpkgs flatpak')"
t_assert_eq "" "$(_row "${rows}" hostpkgs)" "the array name is not requested"
t_assert_contains "$(_row "${rows}" flatpak)" "host" "the rest of the line is"

t_case "a command name inside a string is not a call site"
t_assert_eq "" "$(_list a/echo.sh 'echo "install_target_packages exited"')" \
  "a quoted installer name requests nothing"

t_case "the CPython dev-package table is a request shape of its own"
rows="$(_list 01-core/cpython-dev-packages.sh '_rows=(
  "libsqlite3-dev required _sqlite3"
  "libgdbm-dev optional _gdbm"
)')"
t_assert_contains "$(_row "${rows}" libsqlite3-dev)" "cpython dev table"
t_assert_contains "$(_row "${rows}" libgdbm-dev)" "cpython dev table" "optional rows count too"
t_assert_eq "" "$(_row "${rows}" required)" "the column is not a package"

t_case "a bare apt-get install is a host request"
t_assert_contains "$(_row "$(_list 01-core/repo.sh 'apt-get install -y ca-certificates')" ca-certificates)" \
  "host"

t_summary
