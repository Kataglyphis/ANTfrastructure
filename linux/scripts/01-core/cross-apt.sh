# shellcheck shell=bash
# Cross-compilation apt helpers, sourced by cross-env.sh.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

[ -z "${_CROSS_APT_LOADED:-}" ] || return 0
_CROSS_APT_LOADED=1


# <file> <caller> <awk-args...>: docs/cross-build-verification.md#rewriting-a-deb822-sources-file-in-place
_apt_sources_rewrite() {
  local sources_file="$1" caller="$2" tmp=""
  shift 2

  tmp="$(mktemp "${sources_file}.XXXXXX")" || {
    printf '%s: mktemp failed beside %s\n' "${caller}" "${sources_file}" >&2
    return 1
  }
  if ! awk "$@" "${sources_file}" > "${tmp}"; then
    rm -f "${tmp}"
    printf '%s: awk rewrite of %s failed; file left unchanged\n' \
      "${caller}" "${sources_file}" >&2
    return 1
  fi
  chmod 0644 "${tmp}"
  mv "${tmp}" "${sources_file}"
}

# Every stanza's Architectures: line; android-sdk.sh also sources this file standalone for it.
apt_sources_set_architectures() {
  local sources_file="$1" arch_string="$2"

  [ -f "${sources_file}" ] || return 0

  _apt_sources_rewrite "${sources_file}" apt_sources_set_architectures \
    -v archs="${arch_string}" '
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
  '
}

# ubuntu-mirror.sh's table, not an inline list, so a new arch cannot silently take the archive branch.
cross_target_uses_ubuntu_ports() {
  ubuntu_arch_uses_ports "$(cross_target_arch)"
}

# The arch passes through unnormalized: apt wants dpkg's spelling (i386). docs/cross-build-verification.md#host-and-target-apt-sources-must-expose-the-same-pockets
cross_apt_sources_file_for_arch() {
  local arch
  arch="${1:-$(cross_target_arch)}" || return 1

  if ubuntu_arch_uses_ports "${arch}"; then
    printf '%s' "${_CROSS_APT_SOURCES_DIR}/ubuntu-ports-${arch}.sources"
  else
    printf '%s' "${_CROSS_APT_SOURCES_DIR}/ubuntu-archive-${arch}.sources"
  fi
}

# Ports mirror for ports arches, archive mirror for amd64/i386, which otherwise got no source at all.
cross_apt_mirror_url_for_arch() {
  local arch
  arch="${1:-$(cross_target_arch)}" || return 1

  if ubuntu_arch_uses_ports "${arch}"; then
    if command -v cross_foreign_arch_ports_mirror_url >/dev/null 2>&1; then
      cross_foreign_arch_ports_mirror_url
    else
      ubuntu_effective_ports_mirror_url
    fi
    return 0
  fi
  ubuntu_mirror_normalize_url "${FAST_UBUNTU_MIRROR_URL:-$(ubuntu_default_archive_mirror_url)}"
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

# True when <sources-file> lists <arch> on its Architectures: line.
apt_source_declares_arch() {
  local sources_file="$1" arch="$2" line

  [ -f "${sources_file}" ] || return 1
  while IFS= read -r line; do
    case "${line}" in Architectures:*) ;; *) continue ;; esac
    case " ${line#Architectures:} " in *" ${arch} "*) return 0 ;; esac
  done < "${sources_file}"
  return 1
}

# Not an env knob: only tests point it at a fixture dir.
_CROSS_APT_SOURCES_DIR=/etc/apt/sources.list.d

# Never prunes the build host's own arch: without it an arm64 host resolved binutils to :amd64.
cross_prune_foreign_arch_apt_sources() {
  local keep_source="${1:-}"
  local existing_arch_source host_arch

  host_arch="$(cross_build_arch 2>/dev/null || printf 'amd64')"

  shopt -s nullglob
  for existing_arch_source in \
    "${_CROSS_APT_SOURCES_DIR}"/ubuntu-ports*.sources \
    "${_CROSS_APT_SOURCES_DIR}"/ubuntu-archive*.sources; do
    [ -n "${keep_source}" ] && [ "${existing_arch_source}" = "${keep_source}" ] && continue
    if apt_source_declares_arch "${existing_arch_source}" "${host_arch}"; then
      continue
    fi
    rm -f "${existing_arch_source}"
  done
  shopt -u nullglob
}

cross_prepare_apt_sources_for_target() {
  local target_arch target_sources

  cross_mode_requested || return 0

  target_arch="${TARGET_ARCH:-${TARGETARCH:-}}"
  [ -n "${target_arch}" ] || return 0
  # Canonical, so the keep-source matches what cross_configure_foreign_arch_apt_sources writes.
  target_arch="$(cross_target_arch)"

  if cross_build_enabled; then
    target_sources="$(cross_apt_sources_file_for_arch "${target_arch}")"
    cross_prune_foreign_arch_apt_sources "${target_sources}"
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

# docs/cross-build-verification.md#host-and-target-apt-sources-must-expose-the-same-pockets
cross_align_host_apt_pockets() {
  local host_sources="$1" codename="$2"

  [ -f "${host_sources}" ] || return 0
  if grep -q -e "^Suites:.*${codename}-security" "${host_sources}"; then
    return 0
  fi

  _apt_sources_rewrite "${host_sources}" cross_align_host_apt_pockets \
    -v sec="${codename}-security" \
    '/^Suites:/ && !added { print $0 " " sec; added = 1; next } { print }' || return 1
  _CROSS_ENV_APT_UPDATED=0
}

# No early return for archive arches: amd64/i386 targets need a source too.
cross_configure_foreign_arch_apt_sources() {
  local target_arch build_arch distro target_url target_sources host_sources

  cross_build_enabled || return 0

  target_arch="$(cross_target_arch)"
  build_arch="$(cross_build_arch)"
  distro="$(cross_detect_distro_codename)"
  target_sources="$(cross_apt_sources_file_for_arch "${target_arch}")"
  target_url="$(cross_apt_mirror_url_for_arch "${target_arch}")"
  host_sources="${_CROSS_APT_SOURCES_DIR}/ubuntu.sources"

  case "${target_url}" in
    */) ;;
    *) target_url="${target_url}/" ;;
  esac

  apt_sources_set_architectures "${host_sources}" "${build_arch}"
  cross_align_host_apt_pockets "${host_sources}" "${distro}"

  cross_prune_foreign_arch_apt_sources "${target_sources}"

  ubuntu_write_deb822_source "${target_sources}" "${target_url}" "${distro}" "${target_arch}" 1
}

# Every installed foreign arch keeps a source: docs/failure-modes.md#apt-libc6i386-install-is-unsatisfiable-after-an-archiveports-drift
cross_ensure_installed_foreign_arch_sources() {
  local build_arch arch file url distro

  command -v ubuntu_write_deb822_source >/dev/null 2>&1 || return 0
  command -v ubuntu_arch_uses_ports >/dev/null 2>&1 || return 0

  build_arch="$(cross_build_arch 2>/dev/null || build_arch_oci 2>/dev/null || printf 'amd64')"
  distro="$(cross_detect_distro_codename 2>/dev/null || true)"
  [ -n "${distro}" ] || return 0

  while IFS= read -r arch; do
    [ -n "${arch}" ] || continue
    if [ "${arch}" = "${build_arch}" ]; then
      continue
    fi
    # amd64/i386 come from the archive, so no ports-only filter here.
    file="$(cross_apt_sources_file_for_arch "${arch}")"
    if [ -f "${file}" ]; then
      continue
    fi
    url="$(cross_apt_mirror_url_for_arch "${arch}")"
    ubuntu_write_deb822_source "${file}" "${url}" "${distro}" "${arch}" 1
  done < <(dpkg --print-foreign-architectures 2>/dev/null || true)
  return 0
}

# A phased-back host libc6 makes every foreign-arch install unsatisfiable.
_CROSS_APT_PHASED_CONF=/etc/apt/apt.conf.d/99cross-phased-updates

cross_allow_phased_updates() {
  [ -d /etc/apt/apt.conf.d ] || return 0
  [ -f "${_CROSS_APT_PHASED_CONF}" ] && return 0
  printf 'APT::Get::Always-Include-Phased-Updates "true";\n' \
    > "${_CROSS_APT_PHASED_CONF}" 2>/dev/null || return 0
}

cross_prepare_foreign_arch() {
  local target_arch
  cross_build_enabled || return 0
  target_arch="$(cross_target_arch)"
  if ! dpkg --print-foreign-architectures | grep -qx "${target_arch}"; then
    dpkg --add-architecture "${target_arch}"
    _CROSS_ENV_APT_UPDATED=0
  fi
  cross_allow_phased_updates
  cross_prepare_apt_sources_for_target
}

cross_package_has_install_candidate() {
  local pkg="${1:-}"
  local candidate=""

  [ -n "${pkg}" ] || return 1

  # Not `apt-cache show`: it returns metadata for packages apt cannot install here.
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

# A retry must never buy a package by removing the toolchain, e.g. gfortran:amd64 replacing gcc:arm64.
_apt_install_would_remove() {
  apt-get install -s -y --no-install-recommends "$1" 2>/dev/null \
    | grep -q '^Remv '
}

install_host_packages() {
  [ "$#" -gt 0 ] || return 0
  if apt-get install -y --no-install-recommends "$@"; then
    return 0
  fi
  # One renamed package fails the whole transaction, and callers `|| true` it, so retry per package.
  echo "WARN: batch host-package install failed; retrying per-package to isolate unavailable names" >&2
  local pkg
  local -a _skipped=() _destructive=()
  for pkg in "$@"; do
    if _apt_install_would_remove "${pkg}"; then
      _destructive+=("${pkg}")
      continue
    fi
    apt-get install -y --no-install-recommends "${pkg}" >/dev/null 2>&1 || _skipped+=("${pkg}")
  done
  [ "${#_skipped[@]}" -eq 0 ] || echo "WARN: skipped unavailable host packages: ${_skipped[*]}" >&2
  [ "${#_destructive[@]}" -eq 0 ] || \
    echo "WARN: skipped host packages whose only solution removes installed ones: ${_destructive[*]}" >&2
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

# dpkg status, not files: a foreign package whose postinst could not run is still unpacked and usable.
cross_package_status_present() {
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
    # `:-0` for a standalone source under set -u, before cross-env.sh sets the default.
    if [ "${_CROSS_ENV_APT_UPDATED:-0}" != "1" ]; then
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
    # A subshell keeps pipefail off the caller's options.
    (
      set -o pipefail
      apt-get install -y --no-install-recommends "${pkgs[@]}" 2>&1 \
        | cross_filter_known_foreign_postinst_noise
    ) || apt_rc=$?

    [ "${apt_rc}" -eq 0 ] && return 0

    # Postinst noise or one renamed package that sank the whole transaction: retry per package.
    echo "install_target_packages: batch apt-get exited ${apt_rc}; retrying per-package to isolate unavailable names" >&2
    local _pkg_rc
    for pkg in "${pkgs[@]}"; do
      _pkg_rc=0
      (
        set -o pipefail
        apt-get install -y --no-install-recommends "${pkg}" 2>&1 \
          | cross_filter_known_foreign_postinst_noise
      ) || _pkg_rc=$?
      # Often benign postinst noise; the status sweep below decides, this only attributes it.
      [ "${_pkg_rc}" -ne 0 ] && \
        echo "install_target_packages: '${pkg}' apt-get exited ${_pkg_rc} (per-package retry; status sweep decides)" >&2
    done

    # Absent packages otherwise surface much later as baffling feature skips.
    for pkg in "${pkgs[@]}"; do
      cross_package_status_present "${pkg}" || missing+=("${pkg}")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
      echo "install_target_packages: apt-get exited ${apt_rc} but all requested packages are present (postinst noise or resolved via per-package retry); continuing." >&2
      return 0
    fi
    echo "install_target_packages: FAILED (caller decides if fatal) — missing after apt-get (rc=${apt_rc}): ${missing[*]}" >&2
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

  # Host-arch dirs too, for host tools built during a cross build.
  local _build_multiarch=""
  if [ -n "${DEB_BUILD_MULTIARCH:-}" ]; then
    _build_multiarch="${DEB_BUILD_MULTIARCH}"
  else
    _build_multiarch="$(dpkg-architecture -qDEB_BUILD_MULTIARCH 2>/dev/null || true)"
  fi
  if [ -z "${_build_multiarch}" ]; then
    if ! command -v arch_deb_multiarch_triplet_for >/dev/null 2>&1; then
      printf 'cross_pkg_config_libdir: WARNING: arch_deb_multiarch_triplet_for is not defined — 01-core/platform.sh was never sourced here. Dropping the host-arch pkgconfig dir; host-arch tools may fail to configure. Source/mount platform.sh alongside cross-apt.sh.\n' >&2
    else
      _build_multiarch="$(arch_deb_multiarch_triplet_for "$(uname -m)" 2>/dev/null || true)"
    fi
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

