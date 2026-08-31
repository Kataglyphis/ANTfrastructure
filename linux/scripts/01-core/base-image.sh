#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FOUND_MODULES=0
# shellcheck disable=SC1091
for _bs_path in "/opt/scripts/core/modules.sh" "${SCRIPT_DIR}/modules.sh"; do
  if [ -f "${_bs_path}" ]; then
    source "${_bs_path}"
    source_modules_framework "${SCRIPT_DIR}"
    _FOUND_MODULES=1
    break
  fi
done
[ "${_FOUND_MODULES}" -eq 1 ] || { echo "Error: modules.sh not found" >&2; exit 1; }
unset _bs_path _FOUND_MODULES

source_module common.sh
source_module package-lists.sh
source_module cmake.sh

BASE_IMAGE_CMAKE_VERSION="${CMAKE_VERSION:-4.4.2}"
# versions.env (loaded via common.sh above) is authoritative for these; no
# fallback literals — a stale third channel here silently unpins, and a
# half-loaded env must fail loud instead.
BASE_IMAGE_NODE_VERSION="${NODE_VERSION:?NODE_VERSION not set - versions.env half-loaded?}"
BASE_IMAGE_UV_VERSION="${UV_VERSION:?UV_VERSION not set - versions.env half-loaded?}"
BASE_IMAGE_VULKAN_VERSION="${VULKAN_VERSION}"
BASE_IMAGE_CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-30G}"

toolchain_script() {
  local script_name="$1"
  local candidate

  for candidate in \
    "${SCRIPT_DIR}/../02-toolchain/${script_name}" \
    "/opt/scripts/toolchain/${script_name}"; do
    if [ -f "${candidate}" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  die "Required toolchain script not found: ${script_name}"
}

usage() {
  cat <<'EOF'
Usage: base-image.sh <command> [options]

Commands:
  bootstrap-ca
  restore-mirror-scheme
  configure-fast-mirror [--archive-url URL] [--ports-url URL] [--rewrite-security true|false]
  install-os-packages
  install-shared-build-tooling [--cmake-version VERSION]
  install-node [--version VERSION]
  install-vulkan-runtime-files [--version VERSION] [VULKAN_DIR]
  install-uv [--version VERSION]
  init-compiler-caches [--max-size SIZE]
EOF
}

require_single_value() {
  local flag="$1"
  local value="${2:-}"

  [ -n "${value}" ] || die "Missing value for ${flag}"
}

parse_bool_flag() {
  local flag_name="$1"
  local value="$2"

  case "${value}" in
    1|true|TRUE|yes|YES|0|false|FALSE|no|NO)
      printf '%s' "${value}"
      ;;
    *)
      die "Invalid boolean for ${flag_name}: ${value}"
      ;;
  esac
}

# parse_options table: "<cmd> <flag>" -> "<target-var>|<value-mode>|<side-effect>".
# Modes, and the deliberate --ports-url/--archive-url empty-value asymmetry:
# docs/refactoring-backlog-archive-2026-08-31.md
declare -A BASE_IMAGE_OPTION_SPECS=(
  ["configure-fast-mirror --archive-url"]="FAST_UBUNTU_MIRROR_URL|required|use-fast-mirror"
  ["configure-fast-mirror --ports-url"]="FAST_UBUNTU_PORTS_MIRROR_URL|optional|use-fast-mirror"
  ["configure-fast-mirror --rewrite-security"]="FAST_UBUNTU_REWRITE_SECURITY|bool|"
  ["install-shared-build-tooling --cmake-version"]="BASE_IMAGE_CMAKE_VERSION|required|"
  ["install-node --version"]="BASE_IMAGE_NODE_VERSION|required|"
  ["install-vulkan-runtime-files --version"]="BASE_IMAGE_VULKAN_VERSION|required|"
  ["install-uv --version"]="BASE_IMAGE_UV_VERSION|required|"
  ["init-compiler-caches --max-size"]="BASE_IMAGE_CCACHE_MAXSIZE|required|"
)

# Apply one <flag> <value> pair for <cmd>, or die. <value> is the caller's
# "${2-}", so an absent value collapses to empty; every mode handles that.
base_image_apply_option() {
  local cmd="$1"
  local flag="$2"
  local value="$3"
  local spec target mode side

  spec="${BASE_IMAGE_OPTION_SPECS["${cmd} ${flag}"]:-}"
  [ -n "${spec}" ] || die "Unknown argument for ${cmd}: ${flag}"

  target="${spec%%|*}"
  spec="${spec#*|}"
  mode="${spec%%|*}"
  side="${spec#*|}"

  local -n target_ref="${target}"
  case "${mode}" in
    required)
      require_single_value "${flag}" "${value}"
      target_ref="${value}"
      ;;
    bool)
      require_single_value "${flag}" "${value}"
      # Assign THROUGH the nameref: parse_bool_flag's die must still end the
      # process here. docs/refactoring-backlog-archive-2026-08-31.md
      target_ref="$(parse_bool_flag "${flag}" "${value}")"
      ;;
    optional)
      # shellcheck disable=SC2034  # nameref: the write lands in the caller's var
      target_ref="${value}"
      ;;
  esac

  # The one side effect: naming a mirror URL opts INTO the fast mirror.
  case "${side}" in
    use-fast-mirror)
      USE_FAST_UBUNTU_MIRROR=true
      ;;
  esac
}

parse_options() {
  local cmd="$1"
  shift

  case "${cmd}" in
    configure-fast-mirror|install-shared-build-tooling|install-node|install-uv|init-compiler-caches)
      while [ "$#" -gt 0 ]; do
        base_image_apply_option "${cmd}" "$1" "${2-}"
        shift 2
      done
      ;;
    install-vulkan-runtime-files)
      # The ONLY command taking positionals: stops at the first non-flag (or
      # `--`) and passes the rest on via REMAINING_ARGS, which nothing else sets.
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --)
            shift
            break
            ;;
          -*)
            base_image_apply_option "${cmd}" "$1" "${2-}"
            shift 2
            ;;
          *)
            break
            ;;
        esac
      done
      REMAINING_ARGS=("$@")
      ;;
    bootstrap-ca|restore-mirror-scheme|install-os-packages)
      [ "$#" -eq 0 ] || die "${cmd} does not accept extra arguments"
      ;;
    *)
      [ "$#" -eq 0 ] || die "Unknown command or arguments: ${cmd} $*"
      ;;
  esac
}

base_image_arch() {
  dpkg --print-architecture
}

bootstrap_ca() {
  local use_fast_mirror archive_mirror_url bootstrap_archive_mirror_url rewrite_security

  log "Bootstrapping CA certificates"

  use_fast_mirror="${USE_FAST_UBUNTU_MIRROR:-false}"
  archive_mirror_url="${FAST_UBUNTU_MIRROR_URL:-$(ubuntu_default_archive_mirror_url)}"
  rewrite_security="${FAST_UBUNTU_REWRITE_SECURITY:-false}"

  if ubuntu_mirror_is_truthy "${use_fast_mirror}"; then
    bootstrap_archive_mirror_url="$(ubuntu_mirror_normalize_url "${archive_mirror_url}")"

    # Fresh Ubuntu base images do not ship a trusted CA bundle yet, so bootstrap
    # the archive over HTTP first when a fast mirror was requested.
    case "${bootstrap_archive_mirror_url}" in
      https://*)
        bootstrap_archive_mirror_url="http://${bootstrap_archive_mirror_url#https://}"
        ;;
    esac

    USE_FAST_UBUNTU_MIRROR=true \
    FAST_UBUNTU_MIRROR_URL="${bootstrap_archive_mirror_url}" \
    FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}" \
    FAST_UBUNTU_REWRITE_SECURITY="${rewrite_security}" \
    bash "${SCRIPT_DIR}/use-fast-ubuntu-mirror.sh"
  fi

  # Make EVERY apt-get in EVERY subsequent build layer retry transient network
  # failures. QEMU-emulated arm64/riscv64 networks are flaky, and this is the
  # first RUN in the base image, so dropping the config here covers the whole
  # chain (install_os_packages, packaging-deps, media/android stages, ...) with
  # one line -- not just this bootstrap function's own retry loop below.
  mkdir -p /etc/apt/apt.conf.d
  printf 'Acquire::Retries "3";\n' > /etc/apt/apt.conf.d/80-retries

  # Retry apt-get under QEMU emulation (network can be flaky). After the last
  # attempt, FAIL — the old `break` discarded the terminal rc, and a base image
  # whose apt/mirror is broken only surfaces hours later as an opaque TLS or
  # 404 failure deep in the chain. Failing fast here names the real culprit.
  local _retry=0 _max=3
  until apt-get update -qq; do
    _retry=$((_retry + 1))
    if [ "${_retry}" -ge "${_max}" ]; then
      log "ERROR: apt-get update failed ${_max} times (mirror/network broken) — aborting bootstrap instead of building a base image with a broken apt"
      return 1
    fi
    log "apt-get update failed (attempt ${_retry}/${_max}), retrying..."
    sleep 5
  done
  # ca-certificates: tolerate a failed (re)install ONLY if the package is
  # already present — a base without a CA store breaks every later download.
  apt-get install -y --no-install-recommends ca-certificates || {
    if dpkg -s ca-certificates >/dev/null 2>&1; then
      log "WARNING: ca-certificates reinstall failed but package already present (non-fatal)"
    else
      log "ERROR: ca-certificates install failed and package is absent — every TLS download downstream would fail"
      return 1
    fi
  }
  update-ca-certificates || \
    log "WARNING: update-ca-certificates failed (non-fatal during emulated build)"

  # THE restore point for the deliberate http downgrade above (APT-HTTP): the
  # CA store now exists, so put the mirror entries back on the https scheme
  # the user actually configured. The standalone use-fast-ubuntu-mirror.sh RUN
  # in Dockerfile.base can NOT do this for a custom mirror — its regexes only
  # match upstream archive/security/ports hosts, and by this point the sources
  # name the MIRROR, so it returns without writing (latent since the bootstrap
  # downgrade was introduced; caught 2026-08-24).
  restore_mirror_https_scheme
}

# Undo the CA-bootstrap http downgrade: bootstrap_ca() rewrites the fast-mirror
# URL to http:// so apt can fetch ca-certificates before a CA store exists, and
# nothing downstream restores https for a custom (non-upstream-host) mirror.
# This function is the restore. It is TARGETED — a fixed-string rewrite of the
# exact downgraded URL the bootstrap wrote (plus the ports URL derived from
# it), never a regex over upstream hosts — and safe to call any time:
#   - no-op when USE_FAST_UBUNTU_MIRROR is off (no downgrade ever happened);
#   - no-op when the configured mirror is already http:// (the user's explicit
#     scheme choice is respected, not "fixed");
#   - idempotent (once restored, the downgraded string no longer matches);
#   - loud: echoes the resulting URI/deb lines of every sources file — the
#     PKGCFG-MIRROR verdict discipline: echo the RESULT, never the intent.
# Security entries need no separate pair: when FAST_UBUNTU_REWRITE_SECURITY
# was on, the bootstrap pointed them at the SAME downgraded archive URL, so the
# archive pair restores them too. An explicit FAST_UBUNTU_PORTS_MIRROR_URL was
# passed through the bootstrap unchanged, so it needs no restore either.
# Exposed as the `restore-mirror-scheme` subcommand (honoring
# UBUNTU_SOURCES_ROOT like use-fast-ubuntu-mirror.sh) so host-side gates and
# tests can assert the scheme OUTCOME on a fixture instead of trusting wiring.
restore_mirror_https_scheme() {
  local use_fast_mirror archive_url downgraded_url sources_root
  local ports_wanted ports_downgraded
  local sources_file content new_content i changed=0 line
  local -a rewrite_from=() rewrite_to=() source_files=()

  use_fast_mirror="${USE_FAST_UBUNTU_MIRROR:-false}"
  sources_root="${UBUNTU_SOURCES_ROOT:-/}"

  if ! ubuntu_mirror_is_truthy "${use_fast_mirror}"; then
    log "restore-mirror-scheme: USE_FAST_UBUNTU_MIRROR is off — bootstrap never downgraded anything, no-op"
    return 0
  fi

  archive_url="$(ubuntu_mirror_normalize_url "${FAST_UBUNTU_MIRROR_URL:-$(ubuntu_default_archive_mirror_url)}")"

  case "${archive_url}" in
    https://*) ;;
    *)
      log "restore-mirror-scheme: configured mirror ${archive_url} is not https — respecting the user's explicit scheme, no-op"
      return 0
      ;;
  esac

  # Pair 1: the exact URL bootstrap_ca wrote -> the URL the user configured.
  downgraded_url="http://${archive_url#https://}"
  rewrite_from+=("${downgraded_url}")
  rewrite_to+=("${archive_url}")

  # Pair 2: the ports URL DERIVED from the downgraded archive URL (only when no
  # explicit ports URL was given — an explicit one was never downgraded). For
  # the official archive both derivations collapse to the upstream ports
  # default and no pair is added.
  if [ -z "${FAST_UBUNTU_PORTS_MIRROR_URL:-}" ]; then
    ports_wanted="$(ubuntu_effective_ports_mirror_url "${archive_url}" "")"
    ports_downgraded="$(ubuntu_effective_ports_mirror_url "${downgraded_url}" "")"
    case "${ports_wanted}" in
      https://*)
        if [ "${ports_downgraded}" != "${ports_wanted}" ]; then
          rewrite_from+=("${ports_downgraded}")
          rewrite_to+=("${ports_wanted}")
        fi
        ;;
    esac
  fi

  shopt -s nullglob
  source_files=(
    "${sources_root%/}/etc/apt/sources.list"
    "${sources_root%/}/etc/apt/sources.list.d/"*.list
    "${sources_root%/}/etc/apt/sources.list.d/"*.sources
  )
  shopt -u nullglob

  for sources_file in "${source_files[@]}"; do
    [ -f "${sources_file}" ] || continue
    content="$(cat "${sources_file}")"
    new_content="${content}"
    for i in "${!rewrite_from[@]}"; do
      new_content="${new_content//"${rewrite_from[$i]}"/"${rewrite_to[$i]}"}"
    done
    if [ "${new_content}" != "${content}" ]; then
      printf '%s\n' "${new_content}" > "${sources_file}"
      changed=1
    fi
    # PKGCFG-MIRROR verdict: the lines apt will actually read, post-restore.
    while IFS= read -r line; do
      log "PKGCFG-MIRROR verdict ${sources_file}: ${line}"
    done < <(grep -hE '^(URIs:|deb )' "${sources_file}" || true)
  done

  if [ "${changed}" -eq 1 ]; then
    log "restore-mirror-scheme: restored https scheme (${rewrite_from[*]} -> ${rewrite_to[*]})"
  else
    log "restore-mirror-scheme: no downgraded mirror entries present (already restored or never rewritten) — no-op"
  fi
}

configure_fast_mirror() {
  log "Rewriting Ubuntu apt mirrors when requested"
  USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}" \
  FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-}" \
  FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}" \
  FAST_UBUNTU_REWRITE_SECURITY="${FAST_UBUNTU_REWRITE_SECURITY:-false}" \
  bash "${SCRIPT_DIR}/use-fast-ubuntu-mirror.sh"
}

install_os_packages() {
  local arch tool
  local -a packages=()

  arch="$(base_image_arch)"
  log "Installing base OS packages for ${arch}"
  apt-get update -qq
  base_image_os_packages "${arch}" packages
  apt-get install -y --no-install-recommends "${packages[@]}"

  # Postcondition: the must-have core of this ~90-package root layer actually
  # landed (append_available_packages silently filters optional packages, so
  # the install line alone proves nothing about what was requested). Failing
  # here names the culprit instead of surfacing layers later as a missing tool.
  for tool in git ninja ccache python3 pkg-config; do
    command -v "${tool}" >/dev/null 2>&1 || \
      die "install_os_packages postcondition failed: required tool '${tool}' missing after base package install"
  done
}

install_shared_build_tooling() {
  local packaging_deps_script

  log "Installing shared build tooling"
  packaging_deps_script="$(toolchain_script packaging-deps.sh)"

  require_sudo
  detect_system
  CMAKE_VERSION="${BASE_IMAGE_CMAKE_VERSION}" install_cmake
  bash "${packaging_deps_script}" all
}

install_nodejs() {
  local arch node_asset node_sha256 node_url tmpdir node_dir tool
  local installed_node installed_major pinned_major

  arch="$(base_image_arch)"
  case "${arch}" in
    amd64|x86_64)
      node_asset="node-v${BASE_IMAGE_NODE_VERSION}-linux-x64.tar.xz"
      # No SHA fallback literals: versions.env is authoritative, and a
      # half-loaded env must fail HERE, not as a tamper-shaped checksum error.
      node_sha256="${NODE_AMD64_SHA256:?NODE_AMD64_SHA256 not set - versions.env half-loaded?}"
      ;;
    arm64|aarch64)
      node_asset="node-v${BASE_IMAGE_NODE_VERSION}-linux-arm64.tar.xz"
      node_sha256="${NODE_ARM64_SHA256:?NODE_ARM64_SHA256 not set - versions.env half-loaded?}"
      ;;
    riscv64)
      # RISC-V: no official Node.js tarball. Pin to a known version from distro packages.
      log "Installing pinned Node.js distro packages on riscv64"
      apt-get update -qq
      if ! apt_install "nodejs=${BASE_IMAGE_NODE_VERSION}-1~ubuntu26.04.1"; then
        warn "Exact Node.js pin nodejs=${BASE_IMAGE_NODE_VERSION}-1~ubuntu26.04.1 unavailable on riscv64; falling back to the distro default version"
        apt_install nodejs
        warn "Installed Node.js $(node --version) instead of pinned ${BASE_IMAGE_NODE_VERSION}"
      fi
      # npm is REQUIRED here: `npm --version` below asserts it under set -e,
      # so swallowing a failed install (the old `|| true`) only deferred and
      # obscured the error. Fail at the install step, which names the culprit.
      apt_install npm
      # A fallback install may have unpinned entirely — surface the installed
      # major vs the pin LOUDLY so a drift is never silent (BS5). It is NOT
      # fatal on riscv64: there is no official Node tarball for this arch (see
      # above), so we are at the mercy of ubuntu-ports, which lags the pinned
      # major and drops the exact `-1~ubuntu26.04.1` build as ports advances.
      # Node on riscv64 only backs optional JS/web tooling (litert-web /
      # onnx-web) the Python/native runtime never imports, so a major lag must
      # not abort the whole build. Set NODE_RISCV64_MAJOR_REQUIRED=1 to restore
      # a hard failure.
      installed_node="$(node --version)"
      installed_major="${installed_node#v}"
      installed_major="${installed_major%%.*}"
      pinned_major="${BASE_IMAGE_NODE_VERSION%%.*}"
      if [ "${installed_major}" != "${pinned_major}" ]; then
        if [ "${NODE_RISCV64_MAJOR_REQUIRED:-0}" = "1" ]; then
          die "riscv64 Node.js major mismatch: installed ${installed_node}, but pin ${BASE_IMAGE_NODE_VERSION} expects major ${pinned_major}"
        fi
        warn "riscv64 Node.js major LAGS the pin: installed ${installed_node}, pin ${BASE_IMAGE_NODE_VERSION} (major ${pinned_major}) — ubuntu-ports has no ${pinned_major}.x; shipping the ports default (optional JS/web tooling only)"
      fi
      node --version
      npm --version
      return 0
      ;;
    *)
      die "Unsupported Node.js architecture: ${arch}"
      ;;
  esac

  node_url="https://nodejs.org/dist/v${BASE_IMAGE_NODE_VERSION}/${node_asset}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' EXIT

  log "Installing pinned Node.js ${BASE_IMAGE_NODE_VERSION} for ${arch}"
  download_verified_file "${node_url}" "${node_sha256}" "${tmpdir}/${node_asset}"
  tar -xJf "${tmpdir}/${node_asset}" -C "${tmpdir}"

  node_dir="${tmpdir}/${node_asset%.tar.xz}"
  install -d /usr/local/lib/nodejs
  rm -rf "/usr/local/lib/nodejs/node-v${BASE_IMAGE_NODE_VERSION}"
  mv "${node_dir}" "/usr/local/lib/nodejs/node-v${BASE_IMAGE_NODE_VERSION}"

  for tool in node npm npx corepack; do
    if [ -e "/usr/local/lib/nodejs/node-v${BASE_IMAGE_NODE_VERSION}/bin/${tool}" ]; then
      ln -sf "/usr/local/lib/nodejs/node-v${BASE_IMAGE_NODE_VERSION}/bin/${tool}" "/usr/local/bin/${tool}"
    fi
  done

  rm -rf "${tmpdir}"
  trap - EXIT
  node --version
  npm --version
}

install_vulkan_runtime_files() {
  local vulkan_dir="${1:-${SCRIPT_DIR}/../../vulkan}"

  [ -d "${vulkan_dir}" ] || die "Vulkan manifest directory not found: ${vulkan_dir}"
  log "Installing Vulkan runtime manifests from ${vulkan_dir}"

  install -d /etc/vulkan/icd.d /usr/share/glvnd/egl_vendor.d /etc/vulkan/implicit_layer.d
  cp "${vulkan_dir}/10_nvidia.json" /usr/share/glvnd/egl_vendor.d/10_nvidia.json
  sed "s|@@VULKAN_VERSION@@|${BASE_IMAGE_VULKAN_VERSION}|g" \
    "${vulkan_dir}/nvidia_icd.json.in" > /etc/vulkan/icd.d/nvidia_icd.json
  sed "s|@@VULKAN_VERSION@@|${BASE_IMAGE_VULKAN_VERSION}|g" \
    "${vulkan_dir}/nvidia_layers.json.in" > /etc/vulkan/implicit_layer.d/nvidia_layers.json
}

install_uv() {
  local arch uv_asset uv_sha256 uv_url tmpdir uv_dir

  arch="$(base_image_arch)"
  case "${arch}" in
    amd64|x86_64)
      uv_asset="uv-x86_64-unknown-linux-gnu.tar.gz"
      # No SHA fallback literals: versions.env is authoritative, and a
      # half-loaded env must fail HERE, not as a tamper-shaped checksum error.
      uv_sha256="${UV_AMD64_SHA256:?UV_AMD64_SHA256 not set - versions.env half-loaded?}"
      ;;
    arm64|aarch64)
      uv_asset="uv-aarch64-unknown-linux-gnu.tar.gz"
      uv_sha256="${UV_ARM64_SHA256:?UV_ARM64_SHA256 not set - versions.env half-loaded?}"
      ;;
    riscv64)
      uv_asset="uv-riscv64gc-unknown-linux-gnu.tar.gz"
      uv_sha256="${UV_RISCV64_SHA256:?UV_RISCV64_SHA256 not set - versions.env half-loaded?}"
      ;;
    *)
      die "Unsupported uv architecture: ${arch}"
      ;;
  esac

  uv_url="https://github.com/astral-sh/uv/releases/download/${BASE_IMAGE_UV_VERSION}/${uv_asset}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' EXIT

  log "Installing pinned uv ${BASE_IMAGE_UV_VERSION} for ${arch}"
  download_verified_file "${uv_url}" "${uv_sha256}" "${tmpdir}/${uv_asset}"
  tar -xzf "${tmpdir}/${uv_asset}" -C "${tmpdir}"

  uv_dir="${tmpdir}/${uv_asset%.tar.gz}"
  install -m 0755 "${uv_dir}/uv" /usr/local/bin/uv
  install -m 0755 "${uv_dir}/uvx" /usr/local/bin/uvx

  rm -rf "${tmpdir}"
  trap - EXIT
  uv --version
}

# Install the PINNED sccache over whatever apt provided (2026-08-26, the
# ccache->sccache switch).
#
# Why not just use the apt package: Ubuntu 26.04 ships sccache 0.13.0, which has
# no SCCACHE_BASEDIRS. The GCC lane relies on CCACHE_BASEDIR="${BUILD_DIR}" so
# the three arch lanes -- whose build dirs differ only by triplet -- can share
# entries for identical translation units. Without basedir relativization they
# never share, and sccache additionally hashes the working directory. That
# failure is SILENT: the build stays green and simply stops hitting cache.
# SCCACHE_BASEDIRS first shipped in v0.14.0, so the distro build is on the
# wrong side of it. versions.env pins 0.17.0, the release the Windows lane
# already uses.
#
# Non-fatal by design: upstream publishes no riscv64 asset, and a missing
# sccache must degrade to "no compiler cache", never fail the base image.
install_sccache_pinned() {
  local ver="${SCCACHE_LINUX_VERSION:-}"
  if [ -z "${ver}" ]; then
    warn "SCCACHE_LINUX_VERSION unset -- keeping the apt sccache"
    return 0
  fi

  local machine target sha
  machine="$(uname -m)"
  case "${machine}" in
    x86_64)  target="x86_64-unknown-linux-musl";  sha="${SCCACHE_LINUX_X86_64_SHA256:-}" ;;
    aarch64) target="aarch64-unknown-linux-musl"; sha="${SCCACHE_LINUX_AARCH64_SHA256:-}" ;;
    *) log "No pinned sccache asset for ${machine} -- keeping the apt sccache"; return 0 ;;
  esac
  if [ -z "${sha}" ]; then
    warn "no SHA256 pinned for sccache/${target} -- refusing to install unverified bytes"
    return 0
  fi

  local url="https://github.com/mozilla/sccache/releases/download/v${ver}/sccache-v${ver}-${target}.tar.gz"
  local tmp="/tmp/sccache-${ver}.tar.gz"
  local dir="/tmp/sccache-${ver}"
  if ! download_verified_file "${url}" "${sha}" "${tmp}"; then
    warn "pinned sccache ${ver} could not be fetched/verified -- keeping the apt sccache"
    return 0
  fi
  mkdir -p "${dir}"
  if tar -xf "${tmp}" -C "${dir}" --strip-components=1 \
     && install -m 0755 "${dir}/sccache" /usr/local/bin/sccache; then
    log "sccache pinned: $(/usr/local/bin/sccache --version 2>/dev/null || echo unknown)"
  else
    warn "pinned sccache ${ver} failed to unpack -- keeping the apt sccache"
  fi
  rm -rf "${tmp}" "${dir}"
}

init_compiler_caches() {
  log "Initializing compiler cache settings"
  # ccache stays installed through the transition: it is the fallback for any
  # invocation sccache refuses. sccache HARD-FAILS on a compiler it cannot
  # identify, where ccache would simply run it.
  ccache -M "${BASE_IMAGE_CCACHE_MAXSIZE}" || true
  install_sccache_pinned
  # sccache takes its cap from SCCACHE_CACHE_SIZE plus the config file baked in
  # Dockerfile.base; there is no `ccache -M` equivalent to call here.
  log "sccache dir=${SCCACHE_DIR:-unset} cap=${SCCACHE_CACHE_SIZE:-unset} conf=${SCCACHE_CONF:-unset}"
}

main() {
  local cmd="${1:-}"

  REMAINING_ARGS=()

  case "${cmd}" in
    -h|--help)
      usage
      return 0
      ;;
  esac

  shift || true
  parse_options "${cmd}" "$@"

  case "${cmd}" in
    bootstrap-ca)
      bootstrap_ca
      ;;
    restore-mirror-scheme)
      restore_mirror_https_scheme
      ;;
    configure-fast-mirror)
      configure_fast_mirror
      ;;
    install-os-packages)
      install_os_packages
      ;;
    install-shared-build-tooling)
      install_shared_build_tooling
      ;;
    install-node)
      install_nodejs
      ;;
    install-vulkan-runtime-files)
      install_vulkan_runtime_files "${REMAINING_ARGS[@]}"
      ;;
    install-uv)
      install_uv
      ;;
    init-compiler-caches)
      init_compiler_caches
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
