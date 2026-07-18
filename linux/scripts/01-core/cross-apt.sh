# shellcheck shell=bash
# Source-only helper -- do not execute directly.
# cross-apt.sh - Cross-compilation APT helpers.
# Sourced by cross-env.sh.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

[ -z "${_CROSS_APT_LOADED:-}" ] || return 0
_CROSS_APT_LOADED=1


# Set/overwrite the `Architectures:` line in every stanza of a deb822 sources
# file. Self-contained (awk only; no cross_* deps), so it is also sourced by
# 02-toolchain/android-sdk.sh for its "amd64 i386" host case.
apt_sources_set_architectures() {
  local sources_file="$1" arch_string="$2" tmp=""

  [ -f "${sources_file}" ] || return 0

  tmp="$(mktemp)"
  awk -v archs="${arch_string}" '
    BEGIN { in_stanza=0; has_arch=0 }
    /^[[:space:]]*$/ {
      if (in_stanza && !has_arch) print "Architectures: " archs
      print
      in_stanza=0
      has_arch=0
      next
    }
    /^[[:space:]]*#/ {
      print
      next
    }
    {
      in_stanza=1
    }
    /^Architectures:[[:space:]]*/ {
      print "Architectures: " archs
      has_arch=1
      next
    }
    {
      print
    }
    END {
      if (in_stanza && !has_arch) print "Architectures: " archs
    }
  ' "${sources_file}" > "${tmp}"
  mv "${tmp}" "${sources_file}"
}

cross_target_uses_ubuntu_ports() {
  case "$(cross_target_arch)" in
    arm64|riscv64) return 0 ;;
    *) return 1 ;;
  esac
}

cross_detect_distro_codename() {
  local distro=""

  if [ -n "${DISTRO:-}" ]; then
    printf '%s' "${DISTRO}"
    return 0
  fi

  if [ -r /etc/os-release ]; then
    distro="$(
      # shellcheck disable=SC1091
      . /etc/os-release
      printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    )"
    if [ -n "${distro}" ]; then
      printf '%s' "${distro}"
      return 0
    fi
  fi

  if command -v lsb_release >/dev/null 2>&1; then
    distro="$(lsb_release -cs 2>/dev/null || true)"
    if [ -n "${distro}" ]; then
      printf '%s' "${distro}"
      return 0
    fi
  fi

  printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
}

cross_prune_foreign_arch_apt_sources() {
  local keep_source="${1:-}"
  local existing_ports_source

  shopt -s nullglob
  for existing_ports_source in /etc/apt/sources.list.d/ubuntu-ports*.sources; do
    [ -n "${keep_source}" ] && [ "${existing_ports_source}" = "${keep_source}" ] && continue
    rm -f "${existing_ports_source}"
  done
  shopt -u nullglob
}

cross_prepare_apt_sources_for_target() {
  local target_arch ports_sources

  cross_mode_requested || return 0

  target_arch="${TARGET_ARCH:-${TARGETARCH:-}}"
  [ -n "${target_arch}" ] || return 0

  if cross_build_enabled && cross_target_uses_ubuntu_ports; then
    ports_sources="/etc/apt/sources.list.d/ubuntu-ports-${target_arch}.sources"
    cross_prune_foreign_arch_apt_sources "${ports_sources}"
    cross_configure_foreign_arch_apt_sources
  else
    cross_prune_foreign_arch_apt_sources
  fi
}

apt_update_smart() {
  local -a extra_args=()
  if [ "$#" -gt 0 ]; then
    extra_args=("$@")
  else
    extra_args=(-y)
  fi

  if command -v cross_apt_update >/dev/null 2>&1; then
    cross_apt_update "${extra_args[@]}"
  else
    apt-get update "${extra_args[@]}"
  fi
}

cross_apt_update() {
  cross_prepare_apt_sources_for_target
  apt-get update "$@"
  _CROSS_ENV_APT_UPDATED=1
}

cross_configure_foreign_arch_apt_sources() {
  local target_arch build_arch distro ports_url host_sources ports_sources existing_ports_source

  cross_build_enabled || return 0
  cross_target_uses_ubuntu_ports || return 0

  target_arch="$(cross_target_arch)"
  build_arch="$(cross_build_arch)"
  distro="$(cross_detect_distro_codename)"
  ports_url="$(cross_foreign_arch_ports_mirror_url)"
  host_sources="/etc/apt/sources.list.d/ubuntu.sources"
  ports_sources="/etc/apt/sources.list.d/ubuntu-ports-${target_arch}.sources"

  case "${ports_url}" in
    */) ;;
    *) ports_url="${ports_url}/" ;;
  esac

  apt_sources_set_architectures "${host_sources}" "${build_arch}"

  cross_prune_foreign_arch_apt_sources "${ports_sources}"

  ubuntu_write_deb822_source "${ports_sources}" "${ports_url}" "${distro}" "${target_arch}" 1
}

cross_prepare_foreign_arch() {
  local target_arch
  cross_build_enabled || return 0
  target_arch="$(cross_target_arch)"
  if ! dpkg --print-foreign-architectures | grep -qx "${target_arch}"; then
    dpkg --add-architecture "${target_arch}"
    _CROSS_ENV_APT_UPDATED=0
  fi
  cross_prepare_apt_sources_for_target
}

cross_package_has_install_candidate() {
  local pkg="${1:-}"
  local candidate=""

  [ -n "${pkg}" ] || return 1

  # `apt-cache show` can return package metadata even when apt cannot install the
  # package on this release/architecture combination.
  candidate="$(apt-cache policy "${pkg}" 2>/dev/null | awk '/^[[:space:]]*Candidate:/ { print $2; exit }')"
  [ -n "${candidate}" ] && [ "${candidate}" != "(none)" ]
}

cross_resolve_target_package() {
  local pkg="$1"
  local target_arch
  target_arch="$(cross_target_arch)"

  if ! cross_build_enabled; then
    printf '%s' "${pkg}"
    return 0
  fi

  if cross_package_has_install_candidate "${pkg}:${target_arch}"; then
    printf '%s' "${pkg}:${target_arch}"
  else
    printf '%s' "${pkg}"
  fi
}

install_host_packages() {
  [ "$#" -gt 0 ] || return 0
  # Fast path: one atomic transaction.
  if apt-get install -y --no-install-recommends "$@"; then
    return 0
  fi
  # A SINGLE unavailable/renamed package (e.g. a SONAME rename across an Ubuntu
  # release — resolute dropped the `libxml2` runtime name for `libxml2-16`) makes
  # the whole atomic install fail, which silently drops EVERY other requested lib
  # (callers use `|| true`). That is exactly how the final image ended up missing
  # libopenh264/libsrtp2/libwavpack/libcsound64/libv4l/libgudev runtime libs even
  # though those packages are perfectly installable. Fall back to per-package
  # installs so one bad name can't take the rest down, and report what was skipped.
  echo "WARN: batch host-package install failed; retrying per-package to isolate unavailable names" >&2
  local pkg
  local -a _skipped=()
  for pkg in "$@"; do
    apt-get install -y --no-install-recommends "${pkg}" >/dev/null 2>&1 || _skipped+=("${pkg}")
  done
  [ "${#_skipped[@]}" -eq 0 ] || echo "WARN: skipped unavailable host packages: ${_skipped[*]}" >&2
  return 0
}

cross_filter_known_foreign_postinst_noise() {
  local line

  while IFS= read -r line; do
    case "${line}" in
      *"glib-compile-schemas: Exec format error"*|*"gio-querymodules: Exec format error"*|*"gdk-pixbuf-query-loaders: Exec format error"*)
        continue
        ;;
    esac
    printf '%s\n' "${line}"
  done
}

# Is this package present on disk in a usable state? On cross builds a
# foreign-arch package whose postinst failed (Exec format error — target
# binaries can't run on the build host) is still fully unpacked, so its
# headers/libs ARE usable for cross-compiling. Treat unpacked/half-configured
# as present; only "not installed at all" counts as missing.
cross_package_files_present() {
  local pkg="${1%%=*}"
  local status
  status="$(dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null || true)"
  case "${status}" in
    *" installed"|*" unpacked"|*" half-configured"|*" triggers-awaited"|*" triggers-pending")
      return 0 ;;
  esac
  return 1
}

install_target_packages() {
  local pkg resolved
  local apt_rc=0
  local -a pkgs=() missing=()

  [ "$#" -gt 0 ] || return 0
  if cross_build_enabled; then
    cross_prepare_foreign_arch
    if [ "${_CROSS_ENV_APT_UPDATED}" != "1" ]; then
      apt-get update
      _CROSS_ENV_APT_UPDATED=1
    fi
  fi

  for pkg in "$@"; do
    resolved="$(cross_resolve_target_package "${pkg}")"
    [ -n "${resolved}" ] && pkgs+=("${resolved}")
  done

  [ "${#pkgs[@]}" -gt 0 ] || return 0

  if cross_build_enabled; then
    # Run in a subshell so pipefail applies to the pipeline without leaking
    # into (or depending on) the caller's shell options.
    (
      set -o pipefail
      apt-get install -y --no-install-recommends "${pkgs[@]}" 2>&1 \
        | cross_filter_known_foreign_postinst_noise
    ) || apt_rc=$?

    if [ "${apt_rc}" -ne 0 ]; then
      # The atomic transaction failed. That can be harmless foreign-arch postinst
      # noise (every package still unpacked), but it can ALSO be a single
      # unresolvable/renamed name (e.g. a SONAME rename across an Ubuntu release)
      # that aborts the WHOLE transaction and takes every other requested package
      # down with it — apt installs nothing. Because callers routinely `|| true`
      # this (gstreamer graphics/HLS/X11 batches), that silently strips ~20 libs
      # at once. Retry each package on its own so one bad name can't drop the rest;
      # the package-files-present check below stays the source of truth.
      echo "install_target_packages: batch apt-get exited ${apt_rc}; retrying per-package to isolate unavailable names" >&2
      for pkg in "${pkgs[@]}"; do
        (
          set -o pipefail
          apt-get install -y --no-install-recommends "${pkg}" 2>&1 \
            | cross_filter_known_foreign_postinst_noise
        ) || true
      done
    fi

    # Source of truth is which package files actually landed — this tolerates
    # foreign-arch postinst noise (rc!=0 but files present) while still catching
    # genuinely-absent packages (dependency conflicts, ports outages) that would
    # otherwise surface much later as baffling feature-skips (e.g. gst HLS with
    # no crypto).
    for pkg in "${pkgs[@]}"; do
      cross_package_files_present "${pkg}" || missing+=("${pkg}")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
      [ "${apt_rc}" -eq 0 ] || echo "install_target_packages: apt-get exited ${apt_rc} but all requested packages are present (postinst noise or resolved via per-package retry); continuing." >&2
      return 0
    fi
    echo "install_target_packages: FAILED — missing after apt-get (rc=${apt_rc}): ${missing[*]}" >&2
    return 1
  fi

  apt-get install -y --no-install-recommends "${pkgs[@]}"
}

install_optional_target_packages() {
    [ "$#" -gt 0 ] || return 0

    local -a resolved=()
    local pkg

    for pkg in "$@"; do
        [ -n "${pkg}" ] || continue
        if cross_build_enabled; then
            cross_package_has_install_candidate "$(cross_resolve_target_package "${pkg}")" || {
                echo "Skipping optional target package ${pkg} because apt could not resolve it for $(cross_target_arch 2>/dev/null || echo target)."
                continue
            }
        fi
        resolved+=("${pkg}")
    done

    [ "${#resolved[@]}" -gt 0 ] || return 0
    if ! install_target_packages "${resolved[@]}"; then
        echo "Some optional target packages failed to install; continuing" >&2
    fi
}

install_deps_preamble() {
  apt_update_smart
  if [ "$#" -gt 0 ]; then
    install_host_packages "$@"
  else
    install_host_packages build-essential cmake git pkg-config
  fi
}

is_cross_riscv64() {
  cross_build_is_active && \
  command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]
}

cross_pkg_config_libdir() {
  local triplet="${1:-$(cross_target_triplet)}"
  local dir path=""
  local old_ifs
  local -a candidates extra_dirs

  candidates=(
    "/usr/${triplet}/lib/pkgconfig"
    "/usr/lib/${triplet}/pkgconfig"
    "/usr/lib/pkgconfig"
    "/usr/local/lib/pkgconfig"
    "/usr/share/pkgconfig"
  )

  # Include host-arch pkgconfig dirs so host libraries (e.g. xcb)
  # are resolvable when building host-arch tools during cross builds.
  local _build_multiarch=""
  if [ -n "${DEB_BUILD_MULTIARCH:-}" ]; then
    _build_multiarch="${DEB_BUILD_MULTIARCH}"
  else
    _build_multiarch="$(dpkg-architecture -qDEB_BUILD_MULTIARCH 2>/dev/null || true)"
  fi
  if [ -z "${_build_multiarch}" ]; then
    _build_multiarch="$(uname -m)"
    case "${_build_multiarch}" in
      x86_64) _build_multiarch="x86_64-linux-gnu" ;;
      aarch64) _build_multiarch="aarch64-linux-gnu" ;;
      riscv64) _build_multiarch="riscv64-linux-gnu" ;;
    esac
  fi
  [ -n "${_build_multiarch}" ] && candidates+=("/usr/lib/${_build_multiarch}/pkgconfig")

  if [ -n "${PKG_CONFIG_PATH:-}" ]; then
    old_ifs="${IFS}"
    IFS=':' read -r -a extra_dirs <<< "${PKG_CONFIG_PATH}"
    IFS="${old_ifs}"
    candidates+=("${extra_dirs[@]}")
  fi

  for dir in "${candidates[@]}"; do
    [ -n "${dir}" ] || continue
    case ":${path}:" in
      *":${dir}:"*) continue ;;
    esac
    path="${path:+${path}:}${dir}"
  done

  printf '%s' "${path}"
}

