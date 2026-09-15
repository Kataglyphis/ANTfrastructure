#!/usr/bin/env bash
# app-packaging.sh - generic "package a built Linux desktop app" core.
#
# A wrapper sets the APP_PACKAGING_* variables, sources this file and calls the
# step functions. Sets no -e/-u/-o pipefail: sourcing must not change the
# caller's shell options.
#
# Caller variables (all optional):
#   APP_PACKAGING_APP_ID_PREFIX   reverse-DNS prefix for the app id  (org.example)
#   APP_PACKAGING_COMMENT         .desktop Comment=                  (the app name)
#   APP_PACKAGING_MAINTAINER      deb Maintainer:                    (Unknown <dev@localhost>)
#   APP_PACKAGING_DESCRIPTION     deb long description               (<app> desktop application.)
#   APP_PACKAGING_ICON_FALLBACKS  probed after web/icons/Icon-512.png
#   APP_PACKAGING_WORKDIR         staging root, container-native     (/tmp/packaging-work)
#   KATAGLYPHIS_FLATPAK_WORKDIR   flatpak staging root               (/tmp/flatpak-work)
#
# Three things here were learned the hard way and must not be "simplified":
#
#   1. Every staging tree is container-native, never inside the mounted
#      workspace. A bind-mounted host drive cannot chmod/fchmod for the
#      container uid: dpkg-deb then refuses a DEBIAN directory it left at 777,
#      appimagetool fails on its AppDir, and flatpak-builder cannot create its
#      OSTree repo. Only finished artifacts are copied into out/.
#   2. The flatpak step does NOT gate on flatpak-builder's exit code. The export
#      can be complete while a later stage fails, so it asks
#      `ostree --repo=<repo> refs` whether the app is committed. The exit code
#      is reported, never used as the verdict.
#   3. Nothing prints "Created: …" without app_packaging_assert_artifact. All
#      four formats used to announce success unconditionally, so a dpkg-deb or
#      appimagetool that had already failed still looked green with no file on
#      disk — and that lies on every filesystem, not just a mounted one.

[ -n "${_APP_PACKAGING_SH_LOADED:-}" ] && return 0
_APP_PACKAGING_SH_LOADED=1

_APP_PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log-bootstrap.sh
source "${_APP_PACKAGING_DIR}/log-bootstrap.sh"
# shellcheck source=../01-core/platform.sh
source "${_APP_PACKAGING_DIR}/../01-core/platform.sh"   # arch_normalize, arch_uname_name_for
# shellcheck source=../01-core/common.sh
source "${_APP_PACKAGING_DIR}/../01-core/common.sh"     # run_priv (+ versions.env)

: "${FLATPAK_RUNTIME_VERSION:=24.08}"

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

# "Created: …" used to be printed unconditionally, so a dpkg-deb or appimagetool
# that had already failed still reported success and the lane looked green with
# no artifact on disk. Every packaging function ends here now — AGENTS.md § 4.
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

app_packaging_setup_dependencies_for_container() {
  local matrix_arch="${1:?matrix_arch required}"

  # The CI image already ships these: ANTfrastructure's Dockerfile.base runs
  # linux/scripts/02-toolchain/packaging-deps.sh, whose
  # packaging_prerequisite_packages list is exactly dpkg / flatpak /
  # flatpak-builder / elfutils / libfuse2(t64) / dbus-user-session / wget.
  # Installing them again was not merely wasteful, it was impossible: the image
  # runs as an unprivileged user with no working sudo, so this
  # apt-get took the whole native-linux lane down on both arches.
  #
  # Probe instead of assume — if a future image drops one of them, apt-get is
  # still attempted and the failure names what is missing.
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

  dbus-run-session -- flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  dbus-run-session -- flatpak --user install -y --arch="$flatpak_arch" flathub \
    "org.freedesktop.Platform//${FLATPAK_RUNTIME_VERSION}" \
    "org.freedesktop.Sdk//${FLATPAK_RUNTIME_VERSION}"
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
  echo "build/linux/${matrix_arch}/release/bundle"
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

# Both flatpak packagers need the same two binaries and give the same advice.
app_packaging_require_flatpak_tools() {
  local _t
  for _t in flatpak flatpak-builder; do
    if ! command -v "$_t" >/dev/null 2>&1; then
      echo "Error: ${_t} not found. Install '${_t}' to build Flatpak bundles." >&2
      return 1
    fi
  done
}

# THE VERDICT for both flatpak packagers, and it is not flatpak-builder's exit
# code: the export can be complete while a later stage fails with `fchmod:
# Operation not permitted` on a bind-mounted host drive, and a zero exit can
# leave an empty repo. What decides is whether the app is committed.
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

# Prints the first icon that exists, or nothing. The Flutter default wins:
# web/icons/Icon-512.png is a real 512x512 PNG, which is what flatpak-builder
# demands ("… is not a valid icon" otherwise). APP_PACKAGING_ICON_FALLBACKS is
# probed only after it, for projects that do not ship the Flutter web icons.
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

app_packaging_create_desktop_file() {
  local file_path="${1:?desktop file path required}"
  local app_id="${2:?app id required}"
  local app_name="${3:?app name required}"
  local exec_name="${4:?exec name required}"
  local icon_name="${5:?icon name required}"

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

# The six facts all three bundle packagers derive identically. Sets the CALLER's
# locals by dynamic scope; each caller still declares them and adds only what is
# its own -- deb and appimage an `arch` spelling, flatpak its manifest paths.
app_packaging_resolve_bundle_facts() {
  local matrix_arch="${1:?matrix_arch is required}" app_name="${2:?app_name is required}"

  bundle_dir="$(app_packaging_detect_bundle_dir "$matrix_arch")"
  version="$(app_packaging_get_pubspec_version)"
  package_name="$(app_packaging_sanitize_package_name "$app_name")"
  app_id="${APP_PACKAGING_APP_ID_PREFIX:-org.example}.${package_name}"
  binary_name="$(app_packaging_detect_bundle_binary "$bundle_dir")"
  icon_file="$(app_packaging_detect_icon_file)"
}

app_packaging_package_linux_bundle_deb() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  local app_name="${2:?app_name is required}"

  local bundle_dir version package_name arch deb_root binary_name app_id icon_file icon_name output_name
  app_packaging_resolve_bundle_facts "$matrix_arch" "$app_name"
  arch="$(app_packaging_map_arch_to_deb "$matrix_arch")"
  icon_name="$package_name"
  output_name="${package_name}_${version}_${arch}.deb"

  if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "Error: dpkg-deb not found. Install package 'dpkg' to build .deb files." >&2
    return 1
  fi

  # Staged container-native: dpkg-deb refuses a DEBIAN dir it cannot chmod to
  # 0755, and a bind-mounted host drive silently leaves it 777 — AGENTS.md § 4.
  deb_root="${KATAGLYPHIS_PACKAGING_WORKDIR:-/tmp/packaging-work}/deb"
  rm -rf "$deb_root"
  mkdir -p "$deb_root/DEBIAN"
  mkdir -p "$deb_root/opt/$package_name"
  mkdir -p "$deb_root/usr/bin"
  mkdir -p "$deb_root/usr/share/applications"
  mkdir -p "$deb_root/usr/share/icons/hicolor/512x512/apps"

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
    cp "$icon_file" "$deb_root/usr/share/icons/hicolor/512x512/apps/${package_name}.png"
  fi

  cat > "$deb_root/DEBIAN/control" <<EOF
Package: ${package_name}
Version: ${version}
Section: utils
Priority: optional
Architecture: ${arch}
Maintainer: ${APP_PACKAGING_MAINTAINER:-Unknown <dev@localhost>}
Depends: libc6, libstdc++6, libgtk-3-0
Description: ${app_name}
 ${APP_PACKAGING_DESCRIPTION:-${app_name} desktop application.}
EOF

  chmod 0755 "$deb_root/DEBIAN"
  if ! dpkg-deb --build "$deb_root" "out/${output_name}"; then
    echo "Error: dpkg-deb failed for out/${output_name}" >&2
    return 1
  fi
  app_packaging_assert_artifact "out/${output_name}"
}

app_packaging_package_linux_bundle_appimage() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  local app_name="${2:?app_name is required}"

  local bundle_dir version package_name arch binary_name app_id icon_file icon_name appdir output_name appimagetool_cmd
  app_packaging_resolve_bundle_facts "$matrix_arch" "$app_name"
  arch="$(app_packaging_map_arch_to_appimage "$matrix_arch")"
  icon_name="$package_name"
  # Container-native for the same reason as the deb root: appimagetool chmods
  # its AppDir, which a bind-mounted host drive refuses — AGENTS.md § 4.
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
      "$appimagetool_cmd" "$appdir" "out/${output_name}"; then
    echo "Error: appimagetool failed for out/${output_name}" >&2
    return 1
  fi
  app_packaging_assert_artifact "out/${output_name}"
}

app_packaging_package_linux_bundle_flatpak() {
  local matrix_arch="${1:?matrix_arch is required (x64|arm64)}"
  local app_name="${2:?app_name is required}"

  local bundle_dir version package_name app_id binary_name icon_file manifest_dir manifest_file repo_dir build_dir output_name flatpak_arch
  app_packaging_resolve_bundle_facts "$matrix_arch" "$app_name"
  # Everything flatpak touches needs fchmod, which a bind-mounted host drive
  # refuses — manifest and files/ are staging, the repo and build tree are
  # intermediates. Only the finished bundle belongs in out/. See AGENTS.md § 4.
  local flatpak_work="${KATAGLYPHIS_FLATPAK_WORKDIR:-/tmp/flatpak-work}"
  manifest_dir="${flatpak_work}/manifest"
  manifest_file="${manifest_dir}/${app_id}.yml"
  repo_dir="${flatpak_work}/repo"
  build_dir="${flatpak_work}/build-dir"
  mkdir -p "$flatpak_work"
  output_name="out/${package_name}-${version}.flatpak"
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
  - --share=network
  - --socket=wayland
  - --socket=fallback-x11
  - --device=dri
modules:
  - name: ${package_name}
    buildsystem: simple
    build-commands:
      - mkdir -p /app/bin /app/lib /app/data
      - install -Dm755 ${binary_name} /app/bin/${package_name}
      - cp -a lib/. /app/lib/
      - cp -a data/. /app/data/
      - install -Dm644 ${app_id}.desktop /app/share/applications/${app_id}.desktop
      - install -Dm644 ${app_id}.png /app/share/icons/hicolor/512x512/apps/${app_id}.png
    sources:
      - type: dir
        path: files
EOF

  # KATAGLYPHIS_FLATPAK_VERBOSE=1 adds -v; the packaging failure on a Windows
  # host is not yet understood and the default output does not name the path.
  local -a fb_flags=()
  [ -n "${KATAGLYPHIS_FLATPAK_VERBOSE:-}" ] && fb_flags+=(-v)
  # The exit code is deliberately not the gate. flatpak-builder can export the
  # app completely and still fail afterwards in `Pruning cache` with
  # `fchmod: Operation not permitted` on a bind-mounted host drive. What decides
  # is whether the app is committed — see AGENTS.md § 4.
  local fb_rc=0
  flatpak-builder "${fb_flags[@]}" --force-clean --disable-rofiles-fuse --arch="$flatpak_arch" \
    --state-dir="${flatpak_work}/state" "$build_dir" "$manifest_file" --repo="$repo_dir" || fb_rc=$?

  app_packaging_assert_flatpak_committed "$repo_dir" "$app_id" "$fb_rc" || return 1

  # build-bundle chmods the file it writes, which a bind-mounted host drive
  # refuses — the failure reads as `error: fchmod: Operation not permitted` and
  # looks like it came from the `Pruning cache` line above it. Write it
  # container-native, then copy the finished bundle out.
  local staged_bundle
  staged_bundle="${flatpak_work}/$(basename "$output_name")"
  if ! flatpak build-bundle "$repo_dir" "$staged_bundle" "$app_id"; then
    return 1
  fi
  mkdir -p "$(dirname "$output_name")"
  cp -f "$staged_bundle" "$output_name"

  app_packaging_assert_artifact "${output_name}"
}

# Resolve the flatpak architecture the same way for the runtime install and the
# build: an explicit spelling wins, then flatpak's own default, then this file's
# app_packaging_map_arch_to_flatpak over the OCI arch. Prints it; stdout stays
# clean because nothing else here writes to fd 1.
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

# app_packaging_ensure_flatpak_runtime [arch] [runtime] [sdk] [runtime_version]
#
# flathub plus the runtime+SDK pair, for a packaging run that is NOT inside the
# family CI image. Deliberately not app_packaging_setup_dependencies_for_container
# (apt, privilege helper, unconditional install); why the two must not be merged,
# and why every step is user-first with a system fallback:
# docs/shared-script-libraries.md#app-packagingsh--the-two-flatpak-entry-points
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

  local runtime_ref="${runtime}/${flatpak_arch}/${runtime_version}"
  local sdk_ref="${sdk}/${flatpak_arch}/${runtime_version}"

  if ! flatpak remote-info --user flathub >/dev/null 2>&1 \
     && ! flatpak remote-info --system flathub >/dev/null 2>&1; then
    if ! flatpak --user remote-add --if-not-exists flathub \
           https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1; then
      flatpak --system remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo || return 1
    fi
  fi

  local _ref
  for _ref in "$runtime_ref" "$sdk_ref"; do
    if flatpak info --user "$_ref" >/dev/null 2>&1 || flatpak info --system "$_ref" >/dev/null 2>&1; then
      echo "[Info] flatpak ref already installed: ${_ref}"
      continue
    fi
    echo "[Info] Installing flatpak ref: ${_ref}"
    flatpak --user install -y --noninteractive flathub "$_ref" \
      || flatpak --system install -y --noninteractive flathub "$_ref" \
      || return 1
  done
}

# CMake install rules name their files after the PROJECT; flatpak wants them
# named after the APP ID. Renames in place when the project-named file is there,
# and tolerates a tree that already carries the app-id name (a second run).
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

# The manifest for a cmake-install payload: one `simple` module that copies the
# staged prefix to /app. Its own function so the packager stays under the
# function-size limit; the here-document is most of its length.
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

# app_packaging_package_cmake_install_flatpak <build_dir> <out_dir> <app_id>
#   <project_name> <version_suffix> [runtime] [sdk] [runtime_version] [branch] [arch]
#
# The CMAKE-INSTALL twin of app_packaging_package_linux_bundle_flatpak, which
# packages a Flutter *bundle* tree this project does not have. It obeys the three
# conventions in this file's header: container-native staging (so <out_dir> may be
# the build directory on a mounted workspace), ostree and not the exit code as the
# verdict, and no success line without app_packaging_assert_artifact. Detail:
# docs/shared-script-libraries.md#app-packagingsh--the-two-flatpak-entry-points
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

  # The install can "succeed" with nothing in bin/ (a component filter, a target
  # that was never built). flatpak-builder would then commit an app whose
  # `command` names a file that is not there, and it would fail on a user
  # machine instead. Fail here, naming the path that is missing.
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

  # build-bundle chmods the file it writes, which a bind-mounted host drive
  # refuses - write it container-native, then copy the finished bundle out.
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
