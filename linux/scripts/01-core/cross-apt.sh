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

  # Temp file NEXT TO the target, not in $TMPDIR: several RUNs mount /tmp as a
  # tmpfs (Dockerfile.sdk, Dockerfile.toolchain), which turns the final `mv`
  # into a cross-device copy instead of an atomic rename. The random suffix
  # keeps it out of apt's own *.sources/*.list globs — and out of
  # cross_prune_foreign_arch_apt_sources' ubuntu-ports*.sources glob — for the
  # moments it exists.
  tmp="$(mktemp "${sources_file}.XXXXXX")" || {
    printf 'apt_sources_set_architectures: mktemp failed beside %s\n' "${sources_file}" >&2
    return 1
  }
  if ! awk -v archs="${arch_string}" '
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
  ' "${sources_file}" > "${tmp}"; then
    # Cleanup is EXPLICIT at every exit, never a trap: this file is SOURCED, and
    # a trap armed inside a sourced function stays armed and re-fires on the
    # CALLER's return (the parallel-loop.sh RETURN-trap incident, which turned a
    # fully green chain into exit 1).
    #
    # Bailing out here is the load-bearing half. The old code ran `mv`
    # unconditionally, so a failing awk (ENOSPC on the temp, a shadowed/broken
    # awk) REPLACED the host sources file with awk's truncated output and still
    # returned 0 — every later apt-get in that RUN then died with "Unable to
    # locate package" and no trace of the real cause.
    rm -f "${tmp}"
    printf 'apt_sources_set_architectures: awk rewrite of %s failed; file left unchanged\n' \
      "${sources_file}" >&2
    return 1
  fi
  # mktemp creates 0600 and `mv` carries that mode onto the target; apt sources
  # are 0644 root:root everywhere else in /etc/apt/sources.list.d.
  chmod 0644 "${tmp}"
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
# T1a: named for what it ACTUALLY does — queries the dpkg install STATUS, not the
# filesystem (the old name `cross_package_files_present` implied a file probe and
# misled every caller/comment). A foreign-arch package counts as present when its
# status is installed OR merely unpacked/half-configured (its headers+libs are on
# disk for cross-compiling even when the postinst couldn't run on the build host).
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
    # T1b: `:-0` so cross-apt.sh sourced standalone under `set -u` (before
    # cross-env.sh's default at :7 is in scope) reads a value instead of crashing.
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
    # Run in a subshell so pipefail applies to the pipeline without leaking
    # into (or depending on) the caller's shell options.
    (
      set -o pipefail
      apt-get install -y --no-install-recommends "${pkgs[@]}" 2>&1 \
        | cross_filter_known_foreign_postinst_noise
    ) || apt_rc=$?

    # Trust a clean atomic install: apt-get succeeded, every package is unpacked.
    # Do NOT run the cross_package_status_present sweep on this path — it is a
    # dpkg-status probe (installed/unpacked/half-configured all count as present),
    # used ONLY below as a disambiguator AFTER apt has already errored, never to
    # second-guess a clean atomic install.
    [ "${apt_rc}" -eq 0 ] && return 0

    # The atomic transaction failed. That can be harmless foreign-arch postinst
    # noise (every package still unpacked), but it can ALSO be a single
    # unresolvable/renamed name (e.g. a SONAME rename across an Ubuntu release)
    # that aborts the WHOLE transaction and takes every other requested package
    # down with it — apt installs nothing. Because callers routinely `|| true`
    # this (gstreamer graphics/HLS/X11 batches), that silently strips ~20 libs
    # at once. Retry each package on its own so one bad name can't drop the rest.
    echo "install_target_packages: batch apt-get exited ${apt_rc}; retrying per-package to isolate unavailable names" >&2
    local _pkg_rc
    for pkg in "${pkgs[@]}"; do
      _pkg_rc=0
      (
        set -o pipefail
        apt-get install -y --no-install-recommends "${pkg}" 2>&1 \
          | cross_filter_known_foreign_postinst_noise
      ) || _pkg_rc=$?
      # T1c: surface the per-package rc (diagnosability). Non-zero here is often
      # benign foreign-arch postinst noise — the dpkg-status sweep below is the
      # real arbiter of what landed — but seeing WHICH package and WHAT rc turns
      # a silent `|| true` into an attributable signal when a name genuinely fails.
      [ "${_pkg_rc}" -ne 0 ] && \
        echo "install_target_packages: '${pkg}' apt-get exited ${_pkg_rc} (per-package retry; status sweep decides)" >&2
    done

    # Now disambiguate: which packages genuinely did not land? The dpkg-status
    # check tolerates foreign-arch postinst noise (apt errored but the package is
    # unpacked) while still catching genuinely-absent packages (dependency
    # conflicts, ports outages) that would otherwise surface much later as
    # baffling feature-skips.
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

  # Include host-arch pkgconfig dirs so host libraries (e.g. xcb)
  # are resolvable when building host-arch tools during cross builds.
  local _build_multiarch=""
  if [ -n "${DEB_BUILD_MULTIARCH:-}" ]; then
    _build_multiarch="${DEB_BUILD_MULTIARCH}"
  else
    _build_multiarch="$(dpkg-architecture -qDEB_BUILD_MULTIARCH 2>/dev/null || true)"
  fi
  if [ -z "${_build_multiarch}" ]; then
    # DUP1: was a hand-rolled uname->triplet case here. platform.sh's
    # arch_deb_multiarch_triplet_for is the SSOT. Mount/bake map independently
    # RE-AUDITED 2026-08-24 (grep of every RUN/COPY block referencing this
    # file — do not re-litigate without re-running that grep): platform.sh is
    # co-mounted in ALL 5 Dockerfile.toolchain RUNs that mount this file
    # (blocks at 70/124/187/245/266) and in both Dockerfile.media litert RUNs
    # (per-file mounts @414, whole-01-core mount @432). Dockerfile.sdk is the
    # ONLY image that bakes this file (COPY block @91) and bakes platform.sh
    # beside it (:60). Dockerfile.android and Dockerfile.torch do NOT ship
    # cross-apt.sh at all (an earlier note listed them; that was vacuous —
    # torch bakes cross-env.sh WITHOUT this file, so sourcing cross-env.sh
    # there dies loudly at its `source cross-apt.sh`, never reaching this
    # fallback silently). Plus cross-env.sh:10 and 01-core/common.sh:22 both
    # source platform.sh before this file, and the missing-helper branch below
    # still warns loudly if a future RUN forgets the co-mount.
    # (Only apt_sources_set_architectures is contracted to work when cross-apt.sh
    # is sourced STANDALONE — see 02-toolchain/android-sdk.sh:8 — and it stays
    # dependency-free.)
    #
    # The two ways this lookup can come back empty are NOT the same failure and
    # must not degrade the same way. A single `... 2>/dev/null || true` collapsed
    # both into silence:
    #   * helper MISSING (rc 127, command not found) = a WIRING bug — platform.sh
    #     was not co-mounted/sourced. Every host-arch pkgconfig dir silently
    #     vanishes from PKG_CONFIG_LIBDIR and host tools (xcb & friends) start
    #     failing to configure with no hint as to why. Say so, loudly.
    #   * helper present, arch UNRECOGNISED (rc 1) = expected degradation. The
    #     candidate is skipped and we stay quiet, exactly as before.
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

