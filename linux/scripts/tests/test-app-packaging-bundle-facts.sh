#!/usr/bin/env bash
# Shared bundle facts and verdicts use local fixtures; no external packager, installer or image tool runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/platform.sh"
LIB="${TESTS_DIR}/../lib/app-packaging.sh"
for fn in _app_packaging_arch_for_format app_packaging_map_arch_to_deb app_packaging_map_arch_to_appimage \
  app_packaging_map_arch_to_flatpak app_packaging_resolve_bundle_facts app_packaging_sanitize_package_name \
  _app_packaging_package_bundle app_packaging_package_linux_bundle_deb app_packaging_package_linux_bundle_appimage \
  app_packaging_package_linux_bundle_flatpak _app_packaging_stage_desktop_icon app_packaging_create_desktop_file \
  app_packaging_assert_artifact _app_packaging_copy_bundle; do
  eval "$(t_fn_src "$LIB" "$fn")"
done
_work=$(mktemp -d)
trap 'rm -rf "$_work"' EXIT
export APP_PACKAGING_VERSION=1.2.3 APP_PACKAGING_OUT_DIR="$_work/out" APP_PACKAGING_ICON_FILE="$_work/icon.png"
export APP_PACKAGING_DESKTOP_FILE='' APP_PACKAGING_APP_ID=org.example.fixture
printf icon > "$APP_PACKAGING_ICON_FILE"
app_packaging_detect_bundle_dir() { printf 'bundle/%s' "$1"; }
app_packaging_detect_bundle_binary() { printf 'runner'; }
_capture_bundle() {
  printf '%s|%s|%s|%s|%s|%s|%s' "$format" "$matrix_arch" "$app_name" "$bundle_dir" "$version" "$package_name" "$icon_name" > "$_work/facts"
  artifact="$out_dir/$format.bundle"
  if [[ "$_mode" != empty ]]; then printf bundle > "$artifact"; fi
  bundle_dir=changed
  return "$_callback_rc"
}
_app_packaging_bundle_deb() { _capture_bundle; }
_app_packaging_bundle_appimage() { _capture_bundle; }
_app_packaging_bundle_flatpak() { _capture_bundle; }

_run_bundle() {
  local format="$1" _callback_rc="$2" _mode="$3"
  _rc=0
  "app_packaging_package_linux_bundle_$format" arm64 'Demo App' > "$_work/output" 2>&1 || _rc=$?
  _out=$(cat "$_work/output")
}

matrix_arch=parent app_name=parent version=parent package_name=parent icon_name=parent out_dir=parent bundle_dir=parent artifact=parent
for format in deb appimage flatpak; do
  t_case "$format receives shared facts without leaking them to its caller"
  _run_bundle "$format" 0 full
  t_assert_eq 0 "$_rc" "$_out"
  t_assert_eq "$format|arm64|Demo App|bundle/arm64|1.2.3|demo-app|demo-app" "$(cat "$_work/facts")"
  t_assert_eq 'parent|parent|parent|parent|parent|parent|parent|parent' "$matrix_arch|$app_name|$version|$package_name|$icon_name|$out_dir|$bundle_dir|$artifact"
  t_assert_contains "$_out" "Created: $APP_PACKAGING_OUT_DIR/$format.bundle"

  t_case "$format cannot succeed with an empty artifact"
  : > "$APP_PACKAGING_OUT_DIR/$format.bundle"
  _run_bundle "$format" 0 empty
  t_assert_eq 1 "$_rc"

  t_case "$format propagates a renderer failure despite a stale artifact"
  _run_bundle "$format" 7 full
  t_assert_eq 7 "$_rc" "$_out"
  t_assert_eq '' "$_out" 'failed renderers never report Created'
done

for format in deb appimage flatpak; do
  t_case "$format retains architecture aliases and refusal diagnostics"
  case "$format" in deb) amd=amd64; arm=arm64; label=.deb ;; *) amd=x86_64; arm=aarch64; label=AppImage ;; esac
  [[ "$format" != flatpak ]] || label=Flatpak
  for alias in amd64 x86_64 x64; do t_assert_eq "$amd" "$("app_packaging_map_arch_to_$format" "$alias")"; done
  for alias in arm64 aarch64; do t_assert_eq "$arm" "$("app_packaging_map_arch_to_$format" "$alias")"; done
  _out=$("app_packaging_map_arch_to_$format" riscv64 2>&1); _rc=$?
  t_assert_eq 1 "$_rc"
  t_assert_eq "Error: unsupported architecture for $label: riscv64" "$_out"
done

t_case 'desktop and icon staging keeps the entry fields and optional icon behavior'
_app_packaging_stage_desktop_icon "$_work/app.desktop" org.example.fixture 'Demo App' AppRun demo "$APP_PACKAGING_ICON_FILE" "$_work/copied.png"
t_assert_contains "$(cat "$_work/app.desktop")" 'Exec=AppRun'
t_assert_contains "$(cat "$_work/app.desktop")" 'Icon=demo'
t_assert_eq icon "$(cat "$_work/copied.png")"
_app_packaging_stage_desktop_icon "$_work/no-icon.desktop" org.example.fixture 'Demo App' runner demo '' "$_work/absent.png"
t_assert_fails test -e "$_work/absent.png"
t_assert_ok test -s "$_work/no-icon.desktop"

t_case 'bundle staging preserves hidden files, executable bits and symlinks'
mkdir -p "$_work/payload"
printf '#!/bin/sh\nexit 0\n' > "$_work/payload/runner"
chmod +x "$_work/payload/runner"
printf hidden > "$_work/payload/.hidden"
ln -s runner "$_work/payload/link"
_app_packaging_copy_bundle "$_work/payload" "$_work/staged/payload"
t_assert_eq hidden "$(cat "$_work/staged/payload/.hidden")"
t_assert_ok test -x "$_work/staged/payload/runner"
t_assert_eq runner "$(readlink "$_work/staged/payload/link")"
t_assert_eq 1 "$(t_rc _app_packaging_copy_bundle "$_work/missing" "$_work/staged/missing")"

t_case 'an unconditional packaging call retains errexit inside its renderer'
mkdir -p "$_work/bundle"
printf '#!/bin/sh\nexit 0\n' > "$_work/bundle/runner"
chmod +x "$_work/bundle/runner"
export APP_PACKAGING_BUNDLE_DIR="$_work/bundle" KATAGLYPHIS_PACKAGING_WORKDIR="$_work/staging"
_rc=0
bash -c 'set -e
source "$1"
app_packaging_resolve_appimagetool() { printf true; }
cp() { return 17; }
app_packaging_package_linux_bundle_appimage arm64 "Demo App"
printf survived
' _ "$LIB" > "$_work/errexit-output" 2>&1 || _rc=$?
t_assert_eq 17 "$_rc" "$(cat "$_work/errexit-output")"
t_assert_eq '' "$(cat "$_work/errexit-output")" 'an early staging failure must stop before any verdict'

t_summary
