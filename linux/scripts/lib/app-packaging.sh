#!/usr/bin/env bash
# Sourced core, so it sets no shell options; knobs APP_PACKAGING_*. docs/shared-script-libraries.md#app-packagingsh--the-two-flatpak-entry-points

[ -n "${_APP_PACKAGING_SH_LOADED:-}" ] && return 0
_APP_PACKAGING_SH_LOADED=1

_APP_PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log-bootstrap.sh
source "${_APP_PACKAGING_DIR}/log-bootstrap.sh"
# shellcheck source=../01-core/platform.sh
source "${_APP_PACKAGING_DIR}/../01-core/platform.sh"   # arch_normalize, arch_uname_name_for
# shellcheck source=../01-core/common.sh
source "${_APP_PACKAGING_DIR}/../01-core/common.sh"     # run_priv (+ versions.env)

: "${FLATPAK_RUNTIME_VERSION:=26.08}"

# run_priv, plus a `sudo -n true` probe the runtime image needs.
app_packaging_run_privileged_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    run_priv "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    SUDO="sudo" run_priv "$@"
  else
    echo "Error: need root privileges for command: $*" >&2
    echo "       Running as uid $(id -u) and sudo cannot elevate here." >&2
    echo "       In the CI container this means a prerequisite is missing from" >&2
    echo "       the image - it cannot be installed at run time." >&2
    return 1
  fi
}

# Every packager ends here, so a failed dpkg-deb or appimagetool never prints "Created:" over no file.
app_packaging_assert_artifact() {
  local artifact="${1:?artifact path required}"
  if [ ! -s "$artifact" ]; then
    echo "Error: packaging reported success but ${artifact} is missing or empty" >&2
    return 1
  fi
  echo "Created: ${artifact} ($(du -h "$artifact" 2>/dev/null | cut -f1))"
}

# appimagetool comes from ANTfrastructure (pinned version + SHA256) — AGENTS.md § 2.
app_packaging_ensure_appimagetool_via_antfrastructure() {
  if command -v appimagetool >/dev/null 2>&1; then return 0; fi
  bash "${_APP_PACKAGING_DIR}/../02-toolchain/packaging-deps.sh" appimagetool || return 1
  # The provisioner's own PATH export dies with the child process.
  if ! command -v appimagetool >/dev/null 2>&1; then export PATH="${HOME:-}/.local/bin:$PATH"; fi
  command -v appimagetool >/dev/null 2>&1
}

# Adds a remote or ref only when neither scope has it: a system copy must not pull a ~1.9 GB user one.
app_packaging_flatpak_ensure_refs() {
  local mode="${1:?mode required (container|runtime)}" arch="${2:-}"
  shift 2
  local -a refs=("$@")
  local -a wrap=()
  local _ref

  [ "${mode}" = "container" ] && wrap=(dbus-run-session --)

  if ! flatpak remote-info --user flathub >/dev/null 2>&1 \
     && ! flatpak remote-info --system flathub >/dev/null 2>&1; then
    if [ "${mode}" = "runtime" ]; then
      flatpak --user remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 \
        || flatpak --system remote-add --if-not-exists flathub \
          https://flathub.org/repo/flathub.flatpakrepo || return 1
    else
      "${wrap[@]}" flatpak --user remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo
    fi
  fi

  for _ref in "${refs[@]}"; do
    if flatpak info --user "$_ref" >/dev/null 2>&1 \
       || flatpak info --system "$_ref" >/dev/null 2>&1; then
      echo "[Info] flatpak ref already installed: ${_ref}"
      continue
    fi
    echo "[Info] Installing flatpak ref: ${_ref}"
    if [ "${mode}" = "runtime" ]; then
      flatpak --user install -y --noninteractive flathub "$_ref" \
        || flatpak --system install -y --noninteractive flathub "$_ref" \
        || return 1
    else
      "${wrap[@]}" flatpak --user install -y --arch="${arch}" flathub "$_ref" \
        || return 1
    fi
  done
}

app_packaging_setup_dependencies_for_container() {
  local matrix_arch="${1:?matrix_arch required}"

  # The CI image ships these and has no working sudo, so apt-get runs only for what is missing.
  local -a required_cmds=(dpkg flatpak flatpak-builder dbus-run-session wget)
  local -a missing_cmds=()
  local _cmd
  for _cmd in "${required_cmds[@]}"; do
    command -v "$_cmd" >/dev/null 2>&1 || missing_cmds+=("$_cmd")
  done

  if [[ ${#missing_cmds[@]} -eq 0 ]]; then
    echo "[Info] Packaging prerequisites already present in the image; skipping apt-get."
  else
    echo "[Info] Missing packaging prerequisites: ${missing_cmds[*]} — installing via apt-get."
    app_packaging_run_privileged_cmd apt-get update
    app_packaging_run_privileged_cmd apt-get install -y dpkg flatpak flatpak-builder elfutils libfuse2 dbus-user-session wget
  fi

  app_packaging_ensure_appimagetool_via_antfrastructure

  XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
  export XDG_RUNTIME_DIR
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"

  # Map matrix_arch to Flatpak architecture format
  local flatpak_arch
  case "$matrix_arch" in
    x64|amd64|x86_64) flatpak_arch="x86_64" ;;
    arm64|aarch64) flatpak_arch="aarch64" ;;
    *)
      echo "Error: unsupported architecture for Flatpak runtime: $matrix_arch" >&2
      return 1
      ;;
  esac

  # Probe both scopes: the image installs the pair system-wide, and uid 1001 would pull a user copy.
  app_packaging_flatpak_ensure_refs container "$flatpak_arch" \
    "org.freedesktop.Platform/${flatpak_arch}/${FLATPAK_RUNTIME_VERSION}" \
    "org.freedesktop.Sdk/${flatpak_arch}/${FLATPAK_RUNTIME_VERSION}"
}

app_packaging_formats_include_flatpak() {
  local formats_csv="${1:-}"
  IFS=',' read -r -a _formats <<< "$formats_csv"
  for _raw in "${_formats[@]}"; do
    local _fmt
    _fmt="$(echo "$_raw" | xargs | tr '[:upper:]' '[:lower:]')"
    if [[ "$_fmt" == "flatpak" ]]; then
      return 0
    fi
  done

  return 1
}

app_packaging_run_command_with_runtime() {
  local formats_csv="${1:-}"
  shift

  if app_packaging_formats_include_flatpak "$formats_csv"; then
    dbus-run-session -- "$@"
  else
    "$@"
  fi
}

app_packaging_prepare_workspace() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  rm -rf "build/linux/${matrix_arch}/release/obj" || true
  rm -rf ~/.pub-cache/hosted || true
}

app_packaging_package_bundle_outputs_tar() {
  local bundle_source_dir="${1:?bundle_source_dir is required}"
  local app_name="${2:?app_name is required}"
  local matrix_arch="${3:?matrix_arch is required (x64|arm64)}"

  if [[ ! -d "$bundle_source_dir" ]]; then
    echo "Error: bundle source directory not found: $bundle_source_dir" >&2
    return 1
  fi

  mkdir -p out
  local tar_name
  tar_name="${app_name}-linux-${matrix_arch}.tar.gz"
  rm -rf "out/${app_name}-bundle" || true

  cp -r "$bundle_source_dir" "out/${app_name}-bundle"
  if ! tar -C out -czf "out/${tar_name}" "${app_name}-bundle"; then
    echo "Error: tar failed for out/${tar_name}" >&2
    return 1
  fi
  app_packaging_assert_artifact "out/${tar_name}"
  cp -f "out/${tar_name}" "${tar_name}"
}

app_packaging_package_linux_bundle_tar() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  local app_name="${2:?app_name is required}"

  app_packaging_prepare_workspace "$matrix_arch"
  app_packaging_package_bundle_outputs_tar "build/linux/${matrix_arch}/release/bundle" "$app_name" "$matrix_arch"
}

app_packaging_sanitize_package_name() {
  local input="${1:?package name required}"
  echo "$input" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sed 's/[^a-z0-9.+-]/-/g'
}

app_packaging_detect_bundle_dir() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  # A non-Flutter app hands its staged tree in here (06-packaging/package_archive.sh does).
  echo "${APP_PACKAGING_BUNDLE_DIR:-build/linux/${matrix_arch}/release/bundle}"
}

app_packaging_detect_bundle_binary() {
  local bundle_dir="${1:?bundle_dir required}"
  if [[ ! -d "$bundle_dir" ]]; then
    echo "Error: bundle directory not found: $bundle_dir" >&2
    return 1
  fi

  local binary=""
  while IFS= read -r candidate; do
    local base
    base="$(basename "$candidate")"
    if [[ "$base" == *.so || "$base" == *.sh ]]; then
      continue
    fi
    binary="$base"
    break
  done < <(find "$bundle_dir" -mindepth 1 -maxdepth 1 -type f -executable | sort)

  if [[ -z "$binary" ]]; then
    echo "Error: could not detect executable in $bundle_dir" >&2
    return 1
  fi

  echo "$binary"
}

app_packaging_get_pubspec_version() {
  local pubspec_file="${1:-pubspec.yaml}"
  if [[ ! -f "$pubspec_file" ]]; then
    echo "0.0.0"
    return 0
  fi

  local version
  version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$pubspec_file" | head -n1)"
  version="${version%%+*}"

  if [[ -z "$version" ]]; then
    version="0.0.0"
  fi

  echo "$version"
}

app_packaging_map_arch_to_deb() {
  local a="${1:?arch required}"
  case "$(arch_normalize "$a")" in
    amd64|arm64) arch_normalize "$a" ;;
    *)
      echo "Error: unsupported architecture for .deb: $1" >&2
      return 1
      ;;
  esac
}

app_packaging_map_arch_to_appimage() {
  local a="${1:?arch required}"
  case "$(arch_normalize "$a")" in
    amd64|arm64) arch_uname_name_for "$a" ;;
    *)
      echo "Error: unsupported architecture for AppImage: $1" >&2
      return 1
      ;;
  esac
}

# ostree too: Debian's flatpak depends on libostree, not the CLI the verdict runs.
app_packaging_require_flatpak_tools() {
  local _t _why _missing=0
  # Report every missing tool at once: one apt-get installs all three.
  for _t in flatpak flatpak-builder ostree; do
    if command -v "$_t" >/dev/null 2>&1; then
      continue
    fi
    case "$_t" in
      flatpak) _why="'flatpak build-bundle' writes the bundle" ;;
      flatpak-builder) _why="'flatpak-builder' builds the app and exports it to the repo" ;;
      ostree) _why="'ostree refs' is the verdict that the export committed the app, and the flatpak package depends on libostree rather than on this CLI" ;;
    esac
    echo "Error: ${_t} not found. Install '${_t}' to build Flatpak bundles: ${_why}." >&2
    _missing=1
  done
  return "${_missing}"
}

# The verdict is the committed ref: flatpak-builder's exit code lies in both directions.
app_packaging_assert_flatpak_committed() {
  local repo_dir="${1:?repo dir required}" app_id="${2:?app id required}" fb_rc="${3:-0}"
  if ! ostree --repo="$repo_dir" refs 2>/dev/null | grep -q "^app/${app_id}/"; then
    echo "Error: flatpak-builder exited ${fb_rc} and ${app_id} is not in ${repo_dir}" >&2
    return 1
  fi
  if [ "$fb_rc" -ne 0 ]; then
    echo "[Warn] flatpak-builder exited ${fb_rc}, but ${app_id} is committed; continuing to build-bundle." >&2
  fi
}

app_packaging_map_arch_to_flatpak() {
  local a="${1:?arch required}"
  case "$(arch_normalize "$a")" in
    amd64|arm64) arch_uname_name_for "$a" ;;
    *)
      echo "Error: unsupported architecture for Flatpak: $1" >&2
      return 1
      ;;
  esac
}

# Prints the command name; stdout stays clean because the provisioner logs to stderr.
app_packaging_resolve_appimagetool() {
  app_packaging_ensure_appimagetool_via_antfrastructure >&2 || return 1
  echo "appimagetool"
}

# <png>: "WxH" from the IHDR header, the hicolor dir an icon belongs in; 512x512 when it is no PNG.
app_packaging_icon_size() {
  local png="${1:-}" w h
  if [[ -f "$png" ]] && [[ "$(head -c 8 "$png" | od -An -tx1 | tr -d ' \n')" == "89504e470d0a1a0a" ]]; then
    read -r w h < <(od -An -tu4 --endian=big -j16 -N8 "$png")
    printf '%sx%s' "$w" "$h"
    return 0
  fi
  printf '512x512'
}

# Flutter's Icon-512.png wins: flatpak-builder demands a real 512x512 icon.
app_packaging_detect_icon_file() {
  local candidate
  for candidate in \
    "web/icons/Icon-512.png" \
    ${APP_PACKAGING_ICON_FALLBACKS[@]+"${APP_PACKAGING_ICON_FALLBACKS[@]}"} \
    "assets/images/logo.png"
  do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo ""
}

# <src> <dest> <exec> <icon>: the project's .desktop with Exec and Icon set for one package format.
app_packaging_adapt_desktop_file() {
  local src="${1:?desktop source required}" dest="${2:?desktop path required}"
  local exec_name="${3:?exec name required}" icon_name="${4:?icon name required}"
  [[ -f "$src" ]] || { echo "Error: desktop file not found: $src" >&2; return 1; }
  awk -v exec_name="$exec_name" -v icon_name="$icon_name" '
    /^Exec=/ || /^Icon=/ { next }
    { print }
    /^\[Desktop Entry\]/ { print "Exec=" exec_name; print "Icon=" icon_name }
  ' "$src" > "$dest"
}

app_packaging_create_desktop_file() {
  local file_path="${1:?desktop file path required}"
  local app_id="${2:?app id required}"
  local app_name="${3:?app name required}"
  local exec_name="${4:?exec name required}"
  local icon_name="${5:?icon name required}"

  if [[ -n "${APP_PACKAGING_DESKTOP_FILE:-}" ]]; then
    app_packaging_adapt_desktop_file "$APP_PACKAGING_DESKTOP_FILE" "$file_path" "$exec_name" "$icon_name"
    return
  fi
  cat > "$file_path" <<EOF
[Desktop Entry]
Type=Application
Name=${app_name}
Comment=${APP_PACKAGING_COMMENT:-${app_name}}
Exec=${exec_name}
Icon=${icon_name}
Terminal=false
Categories=Utility;Development;
StartupNotify=true
StartupWMClass=${exec_name}
X-GNOME-UsesNotifications=true
EOF
}

# Sets the caller's locals by dynamic scope, so each caller must declare them.
app_packaging_resolve_bundle_facts() {
  local matrix_arch="${1:?matrix_arch is required}" app_name="${2:?app_name is required}"

  bundle_dir="$(app_packaging_detect_bundle_dir "$matrix_arch")"
  version="${APP_PACKAGING_VERSION:-$(app_packaging_get_pubspec_version)}"
  package_name="$(app_packaging_sanitize_package_name "$app_name")"
  app_id="${APP_PACKAGING_APP_ID:-${APP_PACKAGING_APP_ID_PREFIX:-org.example}.${package_name}}"
  binary_name="$(app_packaging_detect_bundle_binary "$bundle_dir")"
  icon_file="${APP_PACKAGING_ICON_FILE:-$(app_packaging_detect_icon_file)}"
  out_dir="${APP_PACKAGING_OUT_DIR:-out}"
  mkdir -p "$out_dir"
}

app_packaging_package_linux_bundle_deb() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  local app_name="${2:?app_name is required}"

  local bundle_dir version package_name arch deb_root binary_name app_id icon_file icon_name output_name out_dir
  app_packaging_resolve_bundle_facts "$matrix_arch" "$app_name"
  arch="$(app_packaging_map_arch_to_deb "$matrix_arch")"
  icon_name="$package_name"
  output_name="${package_name}_${version}_${arch}.deb"

  if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "Error: dpkg-deb not found. Install package 'dpkg' to build .deb files." >&2
    return 1
  fi

  # Container-native: dpkg-deb refuses the DEBIAN dir a bind-mounted drive leaves at 777.
  deb_root="${KATAGLYPHIS_PACKAGING_WORKDIR:-/tmp/packaging-work}/deb"
  rm -rf "$deb_root"
  mkdir -p "$deb_root/DEBIAN"
  mkdir -p "$deb_root/opt/$package_name"
  mkdir -p "$deb_root/usr/bin"
  mkdir -p "$deb_root/usr/share/applications"
  mkdir -p "$deb_root/usr/share/icons/hicolor/$(app_packaging_icon_size "$icon_file")/apps"

  cp -a "$bundle_dir/." "$deb_root/opt/$package_name/"

  cat > "$deb_root/usr/bin/$package_name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec /opt/${package_name}/${binary_name} "\$@"
EOF
  chmod 0755 "$deb_root/usr/bin/$package_name"

  app_packaging_create_desktop_file \
    "$deb_root/usr/share/applications/${package_name}.desktop" \
    "$app_id" \
    "$app_name" \
    "$package_name" \
    "$icon_name"

  if [[ -n "$icon_file" ]]; then
    cp "$icon_file" "$deb_root/usr/share/icons/hicolor/$(app_packaging_icon_size "$icon_file")/apps/${package_name}.png"
  fi

  cat > "$deb_root/DEBIAN/control" <<EOF
Package: ${package_name}
Version: ${version}
Section: utils
Priority: optional
Architecture: ${arch}
Maintainer: ${APP_PACKAGING_MAINTAINER:-Unknown <dev@localhost>}
Depends: ${APP_PACKAGING_DEB_DEPENDS:-libc6, libstdc++6, libgtk-3-0}
Description: ${app_name}
 ${APP_PACKAGING_DESCRIPTION:-${app_name} desktop application.}
EOF

  chmod 0755 "$deb_root/DEBIAN"
  if ! dpkg-deb --build "$deb_root" "${out_dir}/${output_name}"; then
    echo "Error: dpkg-deb failed for ${out_dir}/${output_name}" >&2
    return 1
  fi
  app_packaging_assert_artifact "${out_dir}/${output_name}"
}

app_packaging_package_linux_bundle_appimage() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  local app_name="${2:?app_name is required}"

  local bundle_dir version package_name arch binary_name app_id icon_file icon_name appdir output_name appimagetool_cmd out_dir
  app_packaging_resolve_bundle_facts "$matrix_arch" "$app_name"
  arch="$(app_packaging_map_arch_to_appimage "$matrix_arch")"
  icon_name="$package_name"
  # Container-native: appimagetool chmods its AppDir, which a bind-mounted drive refuses.
  appdir="${KATAGLYPHIS_PACKAGING_WORKDIR:-/tmp/packaging-work}/${package_name}.AppDir"
  output_name="${package_name}-${version}-${arch}.AppImage"

  if ! appimagetool_cmd="$(app_packaging_resolve_appimagetool)"; then
    return 1
  fi

  rm -rf "$appdir"
  mkdir -p "$appdir/usr/lib/$package_name"

  cp -a "$bundle_dir/." "$appdir/usr/lib/$package_name/"

  cat > "$appdir/AppRun" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SELF_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec "\$SELF_DIR/usr/lib/${package_name}/${binary_name}" "\$@"
EOF
  chmod 0755 "$appdir/AppRun"

  app_packaging_create_desktop_file \
    "$appdir/${app_id}.desktop" \
    "$app_id" \
    "$app_name" \
    "AppRun" \
    "$icon_name"

  if [[ -n "$icon_file" ]]; then
    cp "$icon_file" "$appdir/${icon_name}.png"
  fi

  if ! APPIMAGE_EXTRACT_AND_RUN=1 NO_APPSTREAM=1 ARCH="$arch" \
      "$appimagetool_cmd" "$appdir" "${out_dir}/${output_name}"; then
    echo "Error: appimagetool failed for ${out_dir}/${output_name}" >&2
    return 1
  fi
  app_packaging_assert_artifact "${out_dir}/${output_name}"
}

# KATAGLYPHIS_FLATPAK_FINISH_ARGS is appended, never replacing the four that keep network/wayland/dri.
app_packaging_flatpak_finish_args_block() {
  local -a finish_args=(
    --share=network
    --socket=wayland
    --socket=fallback-x11
    --device=dri
  )
  local -a extra=()
  if [[ -n "${KATAGLYPHIS_FLATPAK_FINISH_ARGS:-}" ]]; then
    IFS=' ' read -r -a extra <<< "${KATAGLYPHIS_FLATPAK_FINISH_ARGS}"
  fi
  local _arg
  for _arg in "${finish_args[@]}" ${extra[@]+"${extra[@]}"}; do
    printf '  - %s\n' "${_arg}"
  done
}

app_packaging_package_linux_bundle_flatpak() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  local app_name="${2:?app_name is required}"

  local bundle_dir version package_name app_id binary_name icon_file manifest_dir manifest_file repo_dir build_dir output_name flatpak_arch out_dir
  app_packaging_resolve_bundle_facts "$matrix_arch" "$app_name"
  # Everything flatpak touches needs fchmod, so stage container-native; only the bundle goes to out/.
  local flatpak_work="${KATAGLYPHIS_FLATPAK_WORKDIR:-/tmp/flatpak-work}"
  manifest_dir="${flatpak_work}/manifest"
  manifest_file="${manifest_dir}/${app_id}.yml"
  repo_dir="${flatpak_work}/repo"
  build_dir="${flatpak_work}/build-dir"
  mkdir -p "$flatpak_work"
  output_name="${out_dir}/${package_name}-${version}.flatpak"
  flatpak_arch="$(app_packaging_map_arch_to_flatpak "$matrix_arch")"

  app_packaging_require_flatpak_tools || return 1

  mkdir -p "$manifest_dir/files"
  rm -rf "$manifest_dir/files" "$repo_dir" "$build_dir"
  mkdir -p "$manifest_dir/files"

  cp -a "$bundle_dir/." "$manifest_dir/files/"

  app_packaging_create_desktop_file \
    "$manifest_dir/files/${app_id}.desktop" \
    "$app_id" \
    "$app_name" \
    "$package_name" \
    "$app_id"

  if [[ -n "$icon_file" ]]; then
    cp "$icon_file" "$manifest_dir/files/${app_id}.png"
  fi

  cat > "$manifest_file" <<EOF
app-id: ${app_id}
runtime: org.freedesktop.Platform
runtime-version: '${FLATPAK_RUNTIME_VERSION}'
sdk: org.freedesktop.Sdk
command: ${package_name}
finish-args:
$(app_packaging_flatpak_finish_args_block)
modules:
  - name: ${package_name}
    buildsystem: simple
    build-commands:
      - mkdir -p /app/bin /app/lib /app/data
      - install -Dm755 ${binary_name} /app/bin/${package_name}
      - if [ -d lib ]; then cp -a lib/. /app/lib/; fi
      - if [ -d data ]; then cp -a data/. /app/data/; fi
      - install -Dm644 ${app_id}.desktop /app/share/applications/${app_id}.desktop
      - install -Dm644 ${app_id}.png /app/share/icons/hicolor/$(app_packaging_icon_size "$icon_file")/apps/${app_id}.png
    sources:
      - type: dir
        path: files
EOF

  # KATAGLYPHIS_FLATPAK_VERBOSE=1 adds -v: the default output does not name the failing path.
  local -a fb_flags=()
  [ -n "${KATAGLYPHIS_FLATPAK_VERBOSE:-}" ] && fb_flags+=(-v)
  # Not the gate: a complete export can still fail afterwards in Pruning cache on fchmod.
  local fb_rc=0
  flatpak-builder "${fb_flags[@]}" --force-clean --disable-rofiles-fuse --arch="$flatpak_arch" \
    --state-dir="${flatpak_work}/state" "$build_dir" "$manifest_file" --repo="$repo_dir" || fb_rc=$?

  app_packaging_assert_flatpak_committed "$repo_dir" "$app_id" "$fb_rc" || return 1

  # build-bundle chmods its output, which a bind-mounted drive refuses; stage it, then copy out.
  local staged_bundle
  staged_bundle="${flatpak_work}/$(basename "$output_name")"
  if ! flatpak build-bundle "$repo_dir" "$staged_bundle" "$app_id"; then
    return 1
  fi
  mkdir -p "$(dirname "$output_name")"
  cp -f "$staged_bundle" "$output_name"

  app_packaging_assert_artifact "${output_name}"
}

# Shared by install and build: explicit arch, then flatpak's default, then the OCI mapping.
app_packaging_resolve_flatpak_arch() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return 0
  fi
  local from_flatpak=""
  if command -v flatpak >/dev/null 2>&1; then
    from_flatpak="$(flatpak --default-arch 2>/dev/null || true)"
  fi
  if [[ -n "$from_flatpak" ]]; then
    echo "$from_flatpak"
    return 0
  fi
  app_packaging_map_arch_to_flatpak "$(arch_oci)"
}

# [arch] [runtime] [sdk] [runtime_version]; outside the CI image, user-first with a system fallback.
app_packaging_ensure_flatpak_runtime() {
  local flatpak_arch="${1:-}"
  local runtime="${2:-org.freedesktop.Platform}"
  local sdk="${3:-org.freedesktop.Sdk}"
  local runtime_version="${4:-${FLATPAK_RUNTIME_VERSION}}"

  if ! command -v flatpak >/dev/null 2>&1; then
    echo "Error: flatpak not found. Install 'flatpak' before asking for a runtime." >&2
    return 1
  fi

  flatpak_arch="$(app_packaging_resolve_flatpak_arch "$flatpak_arch")" || return 1

  app_packaging_flatpak_ensure_refs runtime "" \
    "${runtime}/${flatpak_arch}/${runtime_version}" \
    "${sdk}/${flatpak_arch}/${runtime_version}"
}

# CMake names files after the project, flatpak after the app id; a second run finds them renamed.
app_packaging_rename_installed_file() {
  local dir="${1:?directory required}" from_name="${2:?source name required}" to_name="${3:?target name required}"
  local source=""
  if [[ -f "${dir}/${from_name}" ]]; then
    source="${dir}/${from_name}"
  elif [[ -f "${dir}/${to_name}" ]]; then
    source="${dir}/${to_name}"
  fi
  if [[ -n "$source" && "$source" != "${dir}/${to_name}" ]]; then
    cp -f "$source" "${dir}/${to_name}"
    rm -f "$source"
  fi
}

# Split out to keep the packager under the function-size limit.
app_packaging_write_cmake_flatpak_manifest() {
  local path="${1:?manifest path required}" app_id="${2:?app id required}"
  local runtime="${3:?runtime required}" runtime_version="${4:?runtime version required}"
  local sdk="${5:?sdk required}" command_name="${6:?command required}"
  local source_app_path="${7:?source path required}"

  cat > "$path" <<MANIFEST
{
  "app-id": "${app_id}",
  "runtime": "${runtime}",
  "runtime-version": "${runtime_version}",
  "sdk": "${sdk}",
  "command": "${command_name}",
  "modules": [
    {
      "name": "${command_name}",
      "buildsystem": "simple",
      "build-commands": [
        "cp -a . /app"
      ],
      "sources": [
        {
          "type": "dir",
          "path": "${source_app_path}"
        }
      ]
    }
  ]
}
MANIFEST
}

# <build_dir> <out_dir> <app_id> <project_name> <version_suffix> [runtime] [sdk] [runtime_version] [branch] [arch]
app_packaging_package_cmake_install_flatpak() {
  local build_dir="${1:?build_dir is required}"
  local out_dir="${2:?out_dir is required}"
  local app_id="${3:?app_id is required}"
  local project_name="${4:?project_name is required}"
  local version_suffix="${5:?version_suffix is required}"
  local runtime="${6:-org.freedesktop.Platform}"
  local sdk="${7:-org.freedesktop.Sdk}"
  local runtime_version="${8:-${FLATPAK_RUNTIME_VERSION}}"
  local branch="${9:-master}"
  local flatpak_arch="${10:-}"

  app_packaging_require_flatpak_tools || return 1

  local flatpak_work="${KATAGLYPHIS_FLATPAK_WORKDIR:-/tmp/flatpak-work}"
  local stage_root="${flatpak_work}/cmake-install"
  local source_dir="${stage_root}/source"
  local build_root="${stage_root}/build"
  local repo_dir="${stage_root}/repo"
  local manifest_path="${stage_root}/${app_id}.json"

  rm -rf "$stage_root"
  mkdir -p "${source_dir}/app" "$build_root" "$repo_dir" "$out_dir"

  if ! cmake --install "$build_dir" --prefix "${source_dir}/app"; then
    echo "Error: cmake --install failed for ${build_dir}" >&2
    return 1
  fi

  app_packaging_rename_installed_file "${source_dir}/app/share/applications" \
    "${project_name}.desktop" "${app_id}.desktop"
  app_packaging_rename_installed_file "${source_dir}/app/share/icons/hicolor/256x256/apps" \
    "${project_name}.png" "${app_id}.png"
  app_packaging_rename_installed_file "${source_dir}/app/share/metainfo" \
    "${project_name}.appdata.xml" "${app_id}.appdata.xml"

  # An install can succeed with nothing in bin/; fail here instead of on a user's machine.
  if [[ ! -x "${source_dir}/app/bin/${project_name}" ]]; then
    echo "Error: Flatpak staging failed: expected an executable at ${source_dir}/app/bin/${project_name}" >&2
    return 1
  fi

  local source_app_path
  source_app_path="$(cd "${source_dir}/app" && pwd)"
  app_packaging_write_cmake_flatpak_manifest "$manifest_path" "$app_id" "$runtime" \
    "$runtime_version" "$sdk" "$project_name" "$source_app_path"

  local -a fb_flags=(--disable-rofiles-fuse --force-clean)
  [ -n "${KATAGLYPHIS_FLATPAK_VERBOSE:-}" ] && fb_flags+=(-v)
  [ -n "$flatpak_arch" ] && fb_flags+=(--arch="$flatpak_arch")
  local fb_rc=0
  flatpak-builder "${fb_flags[@]}" --state-dir="${stage_root}/state" \
    --repo="$repo_dir" "$build_root" "$manifest_path" || fb_rc=$?

  app_packaging_assert_flatpak_committed "$repo_dir" "$app_id" "$fb_rc" || return 1

  # build-bundle chmods its output, which a bind-mounted drive refuses; stage it, then copy out.
  local out_name="${project_name}-${version_suffix}-linux.flatpak"
  local staged_bundle="${stage_root}/${out_name}"
  if ! flatpak build-bundle "$repo_dir" "$staged_bundle" "$app_id" "$branch"; then
    return 1
  fi
  cp -f "$staged_bundle" "${out_dir}/${out_name}"

  app_packaging_assert_artifact "${out_dir}/${out_name}"
}

app_packaging_package_android_apk_outputs_tar() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  local app_name="${2:?app_name is required}"

  app_packaging_prepare_workspace "$matrix_arch"
  app_packaging_package_bundle_outputs_tar "build/app/outputs/flutter-apk" "$app_name" "$matrix_arch"
}
