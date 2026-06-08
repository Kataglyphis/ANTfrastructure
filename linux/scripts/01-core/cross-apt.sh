# Source-only helper -- do not execute directly.
# cross-apt.sh - Cross-compilation APT helpers.
# Sourced by cross-env.sh.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

cross_target_uses_ubuntu_ports() {
  case "$(cross_target_arch)" in
    arm64|armhf|ppc64el|riscv64|s390x) return 0 ;;
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
  for existing_ports_source in /etc/apt/sources.list.d/ubuntu-ports-*.sources; do
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

cross_apt_update() {
  cross_prepare_apt_sources_for_target
  apt-get update "$@"
  _CROSS_ENV_APT_UPDATED=1
}

cross_configure_foreign_arch_apt_sources() {
  local target_arch build_arch distro ports_url host_sources ports_sources tmp existing_ports_source

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

  if [ -f "${host_sources}" ]; then
    tmp="$(mktemp)"
    awk -v arch="${build_arch}" '
      BEGIN { in_stanza=0; has_arch=0 }
      /^[[:space:]]*$/ {
        if (in_stanza && !has_arch) print "Architectures: " arch
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
        print "Architectures: " arch
        has_arch=1
        next
      }
      {
        print
      }
      END {
        if (in_stanza && !has_arch) print "Architectures: " arch
      }
    ' "${host_sources}" > "${tmp}"
    mv "${tmp}" "${host_sources}"
  fi

  cross_prune_foreign_arch_apt_sources "${ports_sources}"

  printf 'Types: deb\nURIs: %s\nSuites: %s %s-updates %s-backports %s-security\nComponents: main universe restricted multiverse\nArchitectures: %s\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
    "${ports_url}" "${distro}" "${distro}" "${distro}" "${distro}" "${target_arch}" > "${ports_sources}"
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
  apt-get install -y --no-install-recommends "$@"
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

install_target_packages() {
  local pkg resolved
  local had_pipefail=0
  local -a pkgs=()

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
    case ":${SHELLOPTS:-}:" in
      *:pipefail:*) had_pipefail=1 ;;
    esac
    set -o pipefail
    apt-get install -y --no-install-recommends "${pkgs[@]}" 2>&1 | cross_filter_known_foreign_postinst_noise
    if [ "${had_pipefail}" -ne 1 ]; then
      set +o pipefail
    fi
    return 0
  fi

  apt-get install -y --no-install-recommends "${pkgs[@]}"
}

install_optional_target_packages() {
    local pkg

    [ "$#" -gt 0 ] || return 0

    for pkg in "$@"; do
        if ! install_target_packages "${pkg}"; then
            echo "Skipping optional target package ${pkg} because apt could not resolve it for $(cross_target_arch 2>/dev/null || echo target)."
        fi
    done
}

is_cross_riscv64() {
  command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
  command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]
}

is_cross_skip_csound() {
  command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
  command -v cross_target_arch >/dev/null 2>&1 || return 1
  case "$(cross_target_arch)" in
    arm64|riscv64) return 0 ;;
    *) return 1 ;;
  esac
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

