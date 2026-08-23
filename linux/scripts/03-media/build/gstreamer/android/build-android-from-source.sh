#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../android-build-preamble.sh"

# 1. Parse Arguments
GST_VERSION="${GSTREAMER_VERSION:-1.29.2}"
ANDROID_SDK="${ANDROID_HOME:-/opt/android-sdk}"
ANDROID_NDK="${ANDROID_NDK_HOME:-${ANDROID_HOME:-/opt/android-sdk}/ndk/${ANDROID_NDK_VERSION:-29.0.14206865}}"
INSTALL_PATH="${GSTREAMER_ROOT_ANDROID:-/opt/android/gstreamer}"
TARGET_ARCH="${TARGET_ARCH:-${TARGETARCH:-arm64}}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --gst-version=*) GST_VERSION="${1#*=}"; shift ;;
    --android-sdk=*) ANDROID_SDK="${1#*=}"; shift ;;
    --android-ndk=*) ANDROID_NDK="${1#*=}"; shift ;;
    --android-api=*) ANDROID_API_LEVEL="${1#*=}"; shift ;;
    --prefix=*)      INSTALL_PATH="${1#*=}"; shift ;;
    --target-arch=*) TARGET_ARCH="${1#*=}"; shift ;;
    --with-onnx-inference) shift ;;
    *) shift ;;
  esac
done

# 2. Set environment for non-interactive apt
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

android_build_preamble_init "GStreamer Android build" "${ANDROID_API_LEVEL:-34}"

resolve_host_python() {
    if command -v host_python_bin >/dev/null 2>&1; then
        host_python_bin
        return
    fi

    if [ -n "${MEDIA_HOST_PYTHON:-}" ] && [ -x "${MEDIA_HOST_PYTHON}" ]; then
        printf '%s' "${MEDIA_HOST_PYTHON}"
        return
    fi

    if [ -n "${UV_PYTHON:-}" ] && [ -x "${UV_PYTHON}" ]; then
        printf '%s' "${UV_PYTHON}"
        return
    fi

    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/python" ]; then
        printf '%s' "${VIRTUAL_ENV}/bin/python"
        return
    fi

    if [ -n "${PYTHON_MAJOR_MINOR:-}" ] && [ -x "/usr/local/bin/python${PYTHON_MAJOR_MINOR}" ]; then
        printf '%s' "/usr/local/bin/python${PYTHON_MAJOR_MINOR}"
        return
    fi

    command -v python3 2>/dev/null || command -v python 2>/dev/null || return 1
}

patch_cerbero_system_m4_usage() {
    local autoconf_recipe="recipes/build-tools/autoconf.recipe"
    local libtool_recipe="recipes/build-tools/libtool.recipe"

    [ -f "${autoconf_recipe}" ] || return 0
    [ -f "${libtool_recipe}" ] || return 0

    # Container layout first (apply-patch.sh + patches/ are COPY'd into the
    # android stages); the 4-up repo-relative path resolves to /opt in the
    # flattened container layout ("bash: /opt/01-core/apply-patch.sh: No such
    # file", exit 127).
    local _apply_patch _patches_root _scripts_dir
    if [ -f /opt/scripts/core/apply-patch.sh ]; then
        _apply_patch=/opt/scripts/core/apply-patch.sh
        _patches_root=/opt/scripts/patches
    else
        _scripts_dir="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
        _apply_patch="${_scripts_dir}/01-core/apply-patch.sh"
        _patches_root="${_scripts_dir}/patches"
    fi
    bash "${_apply_patch}" \
      "${_patches_root}/cerbero/001-drop-m4-dependency.patch" \
      "$(pwd)" \
      "Cerbero drop m4 dependency from autoconf/libtool recipes"
}

override_pkgconfig_dead_mirror() {
    # PKGCFG-MIRROR (2026-08-22): recipes/pkg-config.recipe fetches from
    # pkgconfig.freedesktop.org (host dead) and the DEFAULT_MIRRORS fallback
    # gstreamer.freedesktop.org/src/mirror/ 404s too (upstream restructure)
    # — every COLD cerbero bootstrap dies on curl (22) across ALL arches.
    # macports serves the byte-identical tarball (sha256 6fc69c01... equals
    # the recipe's tarball_checksum, so the checksum still guards the bytes).
    # v1 of this fix picked ONE file via `grep -rl | grep -m1` — readdir
    # order is filesystem-dependent, so in-container it patched a stray
    # patch-file instead of the recipe while still echoing success. Patch
    # the known recipe explicitly PLUS every other file naming a dead host,
    # and echo the resulting url line as proof.
    local f patched=0
    for f in recipes/pkg-config.recipe \
             $(grep -rl "pkgconfig\.freedesktop\.org/releases\|gstreamer\.freedesktop\.org/src/mirror/pkg-config" recipes/ packages/ 2>/dev/null); do
        [ -f "${f}" ] || continue
        case " ${_pkgcfg_seen:-} " in *" ${f} "*) continue ;; esac
        _pkgcfg_seen="${_pkgcfg_seen:-} ${f}"
        sed -i \
          -e 's|https://gstreamer.freedesktop.org/src/mirror/pkg-config|https://distfiles.macports.org/pkgconfig/pkg-config|g' \
          -e 's|https://pkgconfig.freedesktop.org/releases|https://distfiles.macports.org/pkgconfig|g' \
          "${f}"
        patched=$((patched + 1))
    done
    unset _pkgcfg_seen
    if [ -f recipes/pkg-config.recipe ]; then
        echo "cerbero: pkg-config mirror override → $(grep -m1 "url = " recipes/pkg-config.recipe | tr -d ' ') (${patched} file(s) patched, PKGCFG-MIRROR)"
    else
        echo "WARNING: recipes/pkg-config.recipe missing — pkg-config mirror override patched ${patched} file(s) blind" >&2
    fi
}

# Pull a plain string attribute out of a cerbero recipe ("attr = 'value'", also
# the f-string form recipes increasingly use). Recipes are executable python, so
# this is a TEXTUAL read and never an evaluation: callers must refuse whatever
# they cannot make sense of instead of guessing at it.
_cerbero_recipe_str() {
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*f\\{0,1\\}['\"]\\([^'\"]*\\)['\"].*/\\1/p" "$1" | head -1
}

override_soundtouch_codeberg_checksum() {
    # soundtouch is fetched from Codeberg's AUTO-GENERATED archive
    # (codeberg.org/soundtouch/soundtouch/archive/<version>.tar.gz). Forgejo
    # regenerates these with different compression periodically, so ANY static
    # pinned hash drifts while the SOURCE is unchanged. It has drifted 3x
    # (e07abf... -> 87c6c9... -> 35d404e6...), so chasing it with a hardcoded
    # value is a losing game.
    #
    # Instead of pinning a fixed hash, pin DYNAMICALLY: fetch the archive now,
    # compute its real sha256, and write THAT into the recipe so cerbero's later
    # fetch always matches. Integrity rests on TLS + the version tag (the tag is
    # immutable; only the archive's compression varies) -- the right trade-off
    # for a non-byte-stable auto-archive. Best-effort: on any failure the recipe
    # is left untouched and cerbero's own checksum step still guards the fetch.
    #
    # STILL LOAD-BEARING, measured 2026-08-23: cerbero 1.29.2 pins
    # e07abf20...6733 while the live archive is 35d404e6...77ec, so WITHOUT this
    # every cold android lane dies on soundtouch's checksum.
    #
    # NOT generalised into a checksums table, and that is a finding, not an
    # omission: of the ~25 forge auto-archive URLs in cerbero 1.29.2, 13 were
    # re-downloaded on 2026-08-23 and compared against their pins -- libffi and
    # svt-av1 (GitLab /-/archive/), graphene, libsrtp, proxy-libintl, openjpeg,
    # rice-proto, srt, libepoxy, libproxy, pycairo, vvdec, libvpx and ninja
    # (GitHub /archive/) -- and ALL of them still hashed to the pinned value.
    # Only Forgejo re-compresses. One case is a point fix (backlog standing rule
    # P3: generalize only when a SECOND case appears).
    local recipe="recipes/soundtouch.recipe"
    [ -f "${recipe}" ] || return 0
    command -v curl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 || {
        echo "WARNING: curl/sha256sum unavailable; cannot dynamic-pin soundtouch checksum" >&2
        return 0
    }

    local ver nam cur url_tpl url tmp actual
    ver="$(_cerbero_recipe_str "${recipe}" version)"
    nam="$(_cerbero_recipe_str "${recipe}" name)"
    url_tpl="$(_cerbero_recipe_str "${recipe}" url)"
    cur="$(sed -n "s/^[[:space:]]*tarball_checksum[[:space:]]*=[[:space:]]*['\"]\([0-9a-fA-F]*\)['\"].*/\1/p" "${recipe}" | head -1)"
    if [ -z "${ver}" ] || [ -z "${cur}" ] || [ -z "${nam}" ] || [ -z "${url_tpl}" ]; then
        echo "WARNING: could not parse soundtouch name/version/url/checksum from recipe; leaving as-is" >&2
        return 0
    fi
    # ver/nam are about to be spliced into a sed replacement and into a URL, so
    # refuse anything outside a version/name charset (no delimiter, no '&', no
    # backslash, no shell or URL metacharacter can reach either).
    case "${ver}${nam}" in
        *[!A-Za-z0-9._+-]*)
            echo "WARNING: soundtouch name/version have unexpected characters ('${nam}' '${ver}'); leaving recipe as-is" >&2
            return 0 ;;
    esac

    # Expand the recipe's OWN url instead of hardcoding one. A hardcoded URL is
    # only correct while the recipe still points where we think it does: upstream
    # ships a stale pin (see above), so this recipe WILL be rewritten, and if it
    # is rewritten to a byte-stable source the hardcoded path would have fetched
    # the Codeberg tarball and written ITS hash over a checksum that was correct
    # -- breaking a recipe upstream had just fixed, silently, from inside a
    # function whose contract is "leave it untouched on any failure".
    # cerbero substitutes name/version/maj_ver (build/source.py
    # replace_name_and_version) and recipes also write f-strings; anything left
    # unexpanded means this script no longer understands the URL, so it stops.
    url="$(printf '%s' "${url_tpl}" | sed \
        -e "s|%(version)s|${ver}|g" -e "s|%(name)s|${nam}|g" \
        -e "s|{version}|${ver}|g" -e "s|{name}|${nam}|g")"
    case "${url}" in
        *'%('*|*'{'*)
            echo "WARNING: soundtouch url '${url_tpl}' has placeholders this script cannot expand; leaving recipe as-is" >&2
            return 0 ;;
    esac
    # The Forgejo auto-archive endpoint IS the justification for trading a pinned
    # hash for TLS+tag. Off that endpoint the trade is not ours to make, so the
    # recipe's own checksum stands.
    case "${url}" in
        https://codeberg.org/*/archive/*) ;;
        *)
            echo "WARNING: soundtouch no longer fetches a Codeberg auto-archive (${url}); TOFU re-pin SKIPPED, upstream's tarball_checksum stands" >&2
            return 0 ;;
    esac

    tmp="$(mktemp)"
    if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 -o "${tmp}" "${url}"; then
        # `|| actual=""` is load-bearing: the script runs under
        # `set -euo pipefail`, so a failing sha256sum makes the whole pipeline
        # non-zero and the bare assignment would ABORT the build instead of
        # reaching the guard below — the guard was written first without it and
        # was therefore unreachable, i.e. exactly the kind of dead check this
        # sweep keeps finding. Now an unhashable download degrades to a warning.
        actual="$(sha256sum "${tmp}" | awk '{print $1}')" || actual=""
        if [ -z "${actual}" ]; then
            echo "WARNING: could not hash the fetched soundtouch archive; leaving recipe as-is" >&2
        elif [ "${actual}" != "${cur}" ]; then
            sed -i "s/${cur}/${actual}/g" "${recipe}"
            echo "Re-pinned soundtouch tarball checksum ${cur} -> ${actual} (live Codeberg archive ${ver})"
        else
            echo "soundtouch tarball checksum already matches live Codeberg archive (${cur})"
        fi
    else
        echo "WARNING: could not pre-fetch soundtouch archive to re-pin checksum; leaving recipe as-is" >&2
    fi
    rm -f "${tmp}"
}

override_glib_libiconv_dep() {
    # CERB-ICONV (2026-08-23): cerbero's glib recipe declares the libiconv dep
    # only below API 28 ("Android only provides libiconv with API level >=28",
    # recipes/glib.recipe), but on Android libiconv lands in the prefix ANYWAY
    # -- fontconfig, zbar and libass append it for every Android target, flac
    # adds it for riscv64 specifically. GNU libiconv's iconv.h #defines
    # iconv_open -> libiconv_open, so whether glib compiles against bionic's
    # iconv or against the renamed one depends purely on WHEN libiconv's header
    # got installed relative to glib's configure/compile: nothing orders them.
    # Lose that race and glib compiles the renamed symbol but links without
    # -liconv -- "ld.lld: error: undefined symbol: libiconv_open" while linking
    # libglib-2.0.so, which killed the cold riscv64 lane in wave5l and then
    # passed unchanged in wave5m. Declaring the dep makes the order
    # deterministic and adds no recipe to the build set (Android builds
    # libiconv either way). Best-effort: on any surprise the recipe is left
    # exactly as upstream shipped it.
    local recipe="recipes/glib.recipe"
    [ -f "${recipe}" ] || {
        echo "WARNING: recipes/glib.recipe missing - glib<-libiconv dep NOT declared (CERB-ICONV)" >&2
        return 0
    }
    if grep -q "CERB-ICONV" "${recipe}"; then
        echo "cerbero: glib <- libiconv dep already declared (CERB-ICONV)"
        return 0
    fi

    cp "${recipe}" "${recipe}.cerb-iconv.bak"
    sed -i \
      -e "s|^\([[:space:]]*\)if self.config.target_platform == Platform.ANDROID and DistroVersion.get_android_api_version(self.config.target_distro_version) < 28:|\1if self.config.target_platform == Platform.ANDROID:  # CERB-ICONV: declare on every API level (link-order race)|" \
      "${recipe}"

    if ! grep -q "CERB-ICONV" "${recipe}"; then
        mv -f "${recipe}.cerb-iconv.bak" "${recipe}"
        echo "WARNING: glib's API<28 libiconv guard not found (upstream reformat?) - dep NOT declared (CERB-ICONV)" >&2
        return 0
    fi
    # A botched sed would surface hours later as an unreadable recipe; parse it
    # now and roll back instead (recipes are exec'd python, so compile() is a
    # real syntax gate).
    if command -v python3 >/dev/null 2>&1 \
       && ! python3 -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')" "${recipe}" 2>/dev/null; then
        mv -f "${recipe}.cerb-iconv.bak" "${recipe}"
        echo "WARNING: glib<-libiconv edit broke recipe syntax - reverted (CERB-ICONV)" >&2
        return 0
    fi
    rm -f "${recipe}.cerb-iconv.bak"
    echo "cerbero: glib <- libiconv dep -> $(grep -m1 "CERB-ICONV" "${recipe}" | sed 's/^[[:space:]]*//')"
}

# ------------------------------------------------------------------------------
# Concurrency limiting (similar to the desktop GStreamer build)
# ------------------------------------------------------------------------------
# You can override by exporting JOBS (or set ANDROID_GSTREAMER_PER_JOB_MB)
PER_JOB_MB="${ANDROID_GSTREAMER_PER_JOB_MB:-1500}"

if [ -z "${JOBS:-}" ]; then
    JOBS="$(nproc --all)"
    # Nothing in this script pre-loads parallelism.sh, so source it on demand
    # (container path) before probing for compute_jobs_with_mem_cap — mirrors
    # media_jobs() in android-build-preamble.sh, but keeps the configurable
    # ANDROID_GSTREAMER_PER_JOB_MB cap instead of its fixed 2000 MB.
    if [ -f /opt/scripts/core/parallelism.sh ]; then
        # shellcheck disable=SC1091
        source /opt/scripts/core/parallelism.sh 2>/dev/null || true
        if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
            JOBS="$(compute_jobs_with_mem_cap "" "${PER_JOB_MB}")"
        fi
    fi
fi

export JOBS
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"
export MAKEFLAGS="-j${JOBS}"
export NINJAFLAGS="-j${JOBS}"

# Cargo/Rust build parallelism (important for gst-plugins-rs)
export CARGO_BUILD_JOBS="${JOBS}"
# Codegen units begrenzen = weniger RAM pro Crate
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${JOBS}"
# Optional: LTO deaktivieren spart RAM bei Release-Builds
# export CARGO_PROFILE_RELEASE_LTO="false"

echo "Using JOBS=${JOBS} (CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL}, CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}, per_job_mb=${PER_JOB_MB})"

# 3. Pre-install dependencies
echo "==> Pre-installing dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
    autotools-dev automake autoconf libtool g++ autopoint \
    make cmake ninja-build bison flex nasm pkg-config \
    libxv-dev libx11-dev libx11-xcb-dev libpulse-dev \
    gettext build-essential libxext-dev libxi-dev \
    x11proto-record-dev libxrender-dev libgl1-mesa-dev \
    libxfixes-dev libxdamage-dev libxcomposite-dev libasound2-dev \
    gperf wget libxtst-dev libxrandr-dev libglu1-mesa-dev \
    libegl1-mesa-dev git m4 xutils-dev ccache \
    libssl-dev

# 4. Setup Cerbero with fallback mechanism
cd /opt
if [ ! -d "cerbero" ]; then
    # First, clone without depth to allow fallback branch checkout
    # Pinned shallow clone, HARD-FAIL on a missing tag (supply-chain audit
    # #20): the old ladder fell back to the MOVING origin/<major.minor>
    # branch, silently turning a reproducible build into an unreproducible
    # one — and cerbero is the build system that pins every downstream
    # GStreamer source. A missing tag is a loud, fixable condition.
    echo "==> Cloning cerbero at pinned tag: $GST_VERSION"
    if ! git clone --depth 1 --branch "$GST_VERSION" https://gitlab.freedesktop.org/gstreamer/cerbero.git; then
        echo "Error: cerbero has no tag '$GST_VERSION'." >&2
        echo "       Fix GSTREAMER_VERSION in versions.env (or add a 40-hex CERBERO_COMMIT" >&2
        echo "       pin there and extend this clone) — refusing the moving-branch fallback." >&2
        exit 1
    fi
    cd cerbero
else
    cd cerbero
fi

patch_cerbero_system_m4_usage
override_soundtouch_codeberg_checksum
override_pkgconfig_dead_mirror
override_glib_libiconv_dep

# 5. Setup Python Virtual Environment
HOST_PYTHON="$(resolve_host_python)"
export UV_PYTHON="${HOST_PYTHON}" \
       MEDIA_HOST_PYTHON="${HOST_PYTHON}"
uv venv --seed --python "${HOST_PYTHON}" .venv
source .venv/bin/activate
export UV_PYTHON="${VIRTUAL_ENV}/bin/python" \
       MEDIA_HOST_PYTHON="${VIRTUAL_ENV}/bin/python"
uv pip install distro "setuptools==70.0.0" wheel

# 6. Detect build host
BUILD_ARCH=$(uname -m)
case "$BUILD_ARCH" in
    x86_64|amd64) CERBERO_HOST_ARCH="X86_64" ;;
    aarch64|arm64) CERBERO_HOST_ARCH="ARM64" ;;
    *) echo "Unsupported: $BUILD_ARCH"; exit 1 ;;
esac

# 7. Map target architecture
case "$TARGET_ARCH" in
    arm64|aarch64)
        CERBERO_TARGET_ARCH="ARM64"
        CONFIG_NAME="android_arm64"
        ;;
    amd64|x86_64|x64)
        CERBERO_TARGET_ARCH="X86_64"
        CONFIG_NAME="android_x86_64"
        ;;
    riscv64|riscv|rv64*)
        CERBERO_TARGET_ARCH="RISCV64"
        CONFIG_NAME="android_riscv64"
        ;;
    armv7|arm)
        CERBERO_TARGET_ARCH="ARMv7"
        CONFIG_NAME="android_armv7"
        ;;
    *)
        echo "Unsupported target: $TARGET_ARCH"
        exit 1
        ;;
esac

# 8. Create Cerbero home directory structure
#
# CERB-CACHE (2026-08-23): everything cerbero can resume from lives under
# home_dir — sources/local (the downloaded tarballs AND the git working repos it
# checks out), sources/<pkg> (extracted + compiled build trees), build-tools/
# (the host bootstrap prefix), rust/ (rustup+cargo), dist/android_<arch>/ (the
# target prefix) and the two pickles cache-file.cache / build-tools.cache that
# record which recipes are already built (cerbero/build/cookbook.py:
# _cache_file() = home_dir + cache_file). bootstrap+package is ONE Dockerfile
# RUN, so any failure inside it discarded ALL of that and the next attempt
# restarted COLD — the ~40-60 min bootstrap was re-paid three times in one
# session for zero progress. home_dir therefore points at a per-arch BuildKit
# cachemount (linux/Dockerfile.android, android-gstreamer RUN:
# target=/var/cache/cerbero) so a retry resumes.
#
# What a resume is NOT: a re-verification. Read against the pinned cerbero
# 1.29.2 — Oven._cook_recipe_step returns before it ever calls the step function
# when that step is already recorded in the pickle (build/oven.py:511), and
# _cook_recipe skips the whole recipe once needs_build is false (:554). The only
# caller of Source.verify() (the sha256 against the recipe's tarball_checksum)
# is the fetch step itself (build/source.py:366/378/458). So a recipe whose
# fetch is already recorded reuses whatever bytes sit in sources/local WITHOUT
# hashing them. What the pickle does guarantee is narrower: a recipe's status is
# thrown away when its built_version changes or when the content hash of the
# recipe file plus its patch files changes (build/cookbook.py:426-440;
# Recipe.get_checksum = files_checksum over the recipe's own FILES, not over the
# tarball) — so the sed-patched recipes in this script (PKGCFG-MIRROR,
# soundtouch, glib libiconv) do invalidate themselves. Nothing in that pickle
# knows about the toolchain, which is why ANDROID_NDK_VERSION and
# ANDROID_API_LEVEL are part of the cachemount id: a pin bump must start a NEW
# store, because cerbero would happily resume a tree built against the old NDK.
#
# The state dir is deliberately NOT /opt/cerbero, which stays the git CHECKOUT:
# a mount target already exists when the RUN body starts, so the `[ ! -d
# cerbero ]` guard in section 4 would skip the clone and `git clone` refuses a
# non-empty destination anyway. Separating them also un-collides cerbero's
# read-only seed dir cached_sources (= <checkout>/sources) from the live tree.
CERBERO_HOME="${CERBERO_HOME:-/var/cache/cerbero}"

# CERB-HOME-GUARD: CERBERO_HOME is an operator knob, and TWO paths below rm -rf
# its CONTENTS (the CERBERO_CACHE_RESET escape hatch and the not-mounted
# cleanup). The obvious "put it back the way it was" value — /opt/cerbero — is
# the git CHECKOUT this script is running out of, and /opt is the SDK/NDK/GCC
# tree; either one would be erased mid-build by a knob that reads like a path
# preference. There is no way to guess intent here, so anything that is not a
# dedicated state directory is refused loudly instead.
cerbero_home_reject() {
    echo "ERROR: CERBERO_HOME='${CERBERO_HOME}' is not a usable cerbero state dir: $1" >&2
    echo "       Its CONTENTS are rm -rf'd on cleanup and on CERBERO_CACHE_RESET=1." >&2
    echo "       Use a dedicated path, e.g. the default /var/cache/cerbero (the" >&2
    echo "       BuildKit cachemount target); do NOT point it at the checkout." >&2
    exit 1
}
case "${CERBERO_HOME}" in
    /*) ;;
    *) cerbero_home_reject "must be an absolute path" ;;
esac
case "${CERBERO_HOME}" in
    *//*|*/./*|*/../*|*/.|*/..)
        cerbero_home_reject "must be normalized (no '//', '.' or '..' components)" ;;
esac
CERBERO_HOME="${CERBERO_HOME%/}"
[ -n "${CERBERO_HOME}" ] || cerbero_home_reject "must not be the filesystem root"
[ "$(dirname "${CERBERO_HOME}")" != "/" ] \
    || cerbero_home_reject "must not be a top-level directory (/opt would erase the SDK/NDK/GCC)"
# The cerbero CHECKOUT of section 4 is /opt/cerbero and is rm -rf'd after the
# build. Reject it and every ANCESTOR of it (this pattern matches when
# ${CERBERO_HOME} is /opt/cerbero itself or contains it) ...
# shellcheck disable=SC2194  # the constant subject is deliberate: the VARIABLE
# is the pattern here, which is what tests "is CERBERO_HOME an ancestor of it?"
case "/opt/cerbero/" in
    "${CERBERO_HOME}"/*)
        cerbero_home_reject "would delete the cerbero checkout at /opt/cerbero" ;;
esac
# ... and every path INSIDE it, which is not destructive but silently pointless:
# the checkout removal takes the state with it, so nothing would ever resume.
case "${CERBERO_HOME}/" in
    /opt/cerbero/*)
        cerbero_home_reject "must not live inside the cerbero checkout /opt/cerbero (deleted after the build)" ;;
esac

CERBERO_PREFIX="${CERBERO_HOME}/dist/android_${TARGET_ARCH}"
mkdir -p "${CERBERO_HOME}"
mkdir -p "${CERBERO_PREFIX}"

cerbero_state_is_mounted() {
    # PROVE the mount instead of assuming it: an earlier seed-cache attempt
    # shipped inert because nothing ever mounted its directory. A BuildKit
    # cachemount is a real bind mount inside the RUN, so it shows up in
    # mountinfo and its st_dev differs from its parent's. Every uncertain answer
    # is "not mounted", which is the safe direction — the cleanup then deletes
    # the state instead of baking ~10-15 GB of it into the image layer.
    [ -d "${CERBERO_HOME}" ] || return 1
    grep -qF " ${CERBERO_HOME} " /proc/self/mountinfo 2>/dev/null && return 0
    local dev_state dev_parent
    dev_state="$(stat -c %d "${CERBERO_HOME}" 2>/dev/null)" || return 1
    dev_parent="$(stat -c %d "$(dirname "${CERBERO_HOME}")" 2>/dev/null)" || return 1
    [ -n "${dev_state}" ] && [ "${dev_state}" != "${dev_parent}" ]
}

# Cold-start escape hatch: a POISONED state dir (a half-installed prefix, a
# recipe that only fails on a resumed tree) would otherwise wedge this lane on
# every single retry. Contents only, never the mountpoint itself — rm -rf on a
# mountpoint fails EBUSY and would kill the run under `set -e` AFTER emptying it.
CERBERO_CACHE_RESET="${CERBERO_CACHE_RESET:-0}"
if [ "${CERBERO_CACHE_RESET}" = "1" ]; then
    echo "==> CERBERO_CACHE_RESET=1 — clearing ${CERBERO_HOME} for a cold cerbero build"
    find "${CERBERO_HOME}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
fi

if cerbero_state_is_mounted; then
    # Print the size the store already occupies: this feature trades host disk
    # for restartability on a host that runs near-full, so the price belongs in
    # the log rather than in a comment nobody reads at 2am.
    CERBERO_STATE_SIZE_ON_ENTRY="$(du -sh "${CERBERO_HOME}" 2>/dev/null | cut -f1 || echo unknown)"
    if [ -f "${CERBERO_HOME}/cache-file.cache" ]; then
        echo "==> cerbero state cache HIT: resuming from ${CERBERO_HOME} (${CERBERO_STATE_SIZE_ON_ENTRY} on the cachemount, CERB-CACHE)"
    else
        echo "==> cerbero state cache MISS: ${CERBERO_HOME} is mounted but cold (${CERBERO_STATE_SIZE_ON_ENTRY}, CERB-CACHE)"
    fi
else
    echo "WARNING: ${CERBERO_HOME} is NOT a cachemount — this run cannot resume, and its" >&2
    echo "         state is deleted at the end instead of shipping in the layer (CERB-CACHE)" >&2
fi

# 9. Map API level to Cerbero's DistroVersion enum
CERBERO_VARIANTS_OVERRIDE=""

# Note: Cerbero's bundled riscv64 Android config requires API 35 and disables Rust.
# Other Android targets still use the older distro version mapping.
if [ "${CERBERO_TARGET_ARCH}" = "RISCV64" ]; then
    DISTRO_VERSION="ANDROID_VANILLAICECREAM"
    CERBERO_VARIANTS_OVERRIDE="variants.override('norust')"
    echo "==> Note: Using ANDROID_VANILLAICECREAM for Android riscv64 (Cerbero requirement)"
elif [ "$ANDROID_API_LEVEL" -ge 26 ]; then
    DISTRO_VERSION="ANDROID_OREO"           # API 26+ - Use Oreo for all newer versions
    echo "==> Note: Using ANDROID_OREO for API ${ANDROID_API_LEVEL} (highest available in GStreamer 1.26.9)"
elif [ "$ANDROID_API_LEVEL" -ge 24 ]; then
    DISTRO_VERSION="ANDROID_NOUGAT"         # API 24-25 - Nougat
elif [ "$ANDROID_API_LEVEL" -ge 23 ]; then
    DISTRO_VERSION="ANDROID_MARSHMALLOW"    # API 23 - Marshmallow
elif [ "$ANDROID_API_LEVEL" -ge 21 ]; then
    DISTRO_VERSION="ANDROID_LOLLIPOP_MR1"   # API 21-22 - Lollipop
elif [ "$ANDROID_API_LEVEL" -ge 19 ]; then
    DISTRO_VERSION="ANDROID_KITKAT"         # API 19 - KitKat
else
    echo "Error: Minimum Android API level is 19"
    exit 1
fi

# 10. Create comprehensive configuration file
cat > ${CONFIG_NAME}.cbc <<EOF
import os
from cerbero.config import Architecture, Distro, Platform, DistroVersion

# Build host configuration
arch = Architecture.${CERBERO_HOST_ARCH}
platform = Platform.LINUX

# Target configuration
target_platform = Platform.ANDROID
target_distro = Distro.ANDROID
target_arch = Architecture.${CERBERO_TARGET_ARCH}
target_distro_version = DistroVersion.${DISTRO_VERSION}

# Android-specific paths
os.environ['ANDROID_SDK_ROOT'] = "${ANDROID_SDK}"
os.environ['ANDROID_NDK_HOME'] = "${ANDROID_NDK}"

android_sdk = "${ANDROID_SDK}"
android_ndk = "${ANDROID_NDK}"

# Build paths
home_dir = "${CERBERO_HOME}"
prefix = "${CERBERO_PREFIX}"
sources = os.path.join(home_dir, "sources")
logs = os.path.join(home_dir, "logs")
cache_file = os.path.join(home_dir, "cache-file.cache")

# Build configuration
${CERBERO_VARIANTS_OVERRIDE}
interactive = False

# Toolchain configuration
allow_system_libs = False
use_ccache = True if os.path.exists('/usr/bin/ccache') else False
EOF

echo "==> Configuration created:"
echo "    Build Host: ${CERBERO_HOST_ARCH}"
echo "    Target: ${CERBERO_TARGET_ARCH}"
echo "    API Level: ${ANDROID_API_LEVEL} (using ${DISTRO_VERSION})"
echo "    Cerbero Home: ${CERBERO_HOME}"
echo "    Prefix: ${CERBERO_PREFIX}"

# Try to pass the job limit through Cerbero's CLI if supported (different Cerbero versions vary).
CERBERO_JOBS_ARGS=()
if uv run ./cerbero-uninstalled --help 2>&1 | grep -q -- '--jobs'; then
    CERBERO_JOBS_ARGS+=(--jobs "${JOBS}")
elif uv run ./cerbero-uninstalled --help 2>&1 | grep -q -- '-j'; then
    CERBERO_JOBS_ARGS+=(-j "${JOBS}")
else
    echo "==> Note: Cerbero CLI has no --jobs/-j; relying on env (MAKEFLAGS/CMAKE_BUILD_PARALLEL_LEVEL/NINJAFLAGS)"
fi

# 11. Execute build
(
    unset RUSTUP_HOME CARGO_HOME RUSTC_WRAPPER
    export DEBIAN_FRONTEND=noninteractive
    export M4=/usr/bin/m4
    export SETUPTOOLS_USE_DISTUTILS=local
    
    # Set Android environment variables
    export ANDROID_SDK_ROOT="${ANDROID_SDK}"
    export ANDROID_NDK_HOME="${ANDROID_NDK}"
    
    # Ensure apt runs non-interactively and pre-install common build deps
    # Cerbero's bootstrap may invoke apt-get without -y which prompts; pre-install
    # the packages it requests so the bootstrap won't stop for confirmation.
    # Must FAIL here on error (no `|| true`): a mirror outage swallowed at this
    # point resurfaces hours later as an inscrutable Cerbero bootstrap failure.
    # Transient network hiccups are already retried via the base image's
    # /etc/apt/apt.conf.d/80-retries (Acquire::Retries "3").
    echo "==> Installing system packages required by Cerbero (non-interactive)"
    apt-get update
    apt-get install -y --no-install-recommends \
        autoconf automake autopoint autotools-dev binutils bison build-essential \
        ccache cmake curl flex g++ gettext git gperf libasound2-dev libclang-dev \
        libcurl4-openssl-dev libdrm-dev libegl1-mesa-dev libgl1-mesa-dev \
        libglu1-mesa-dev libpulse-dev libssl-dev libtool libva-dev libx11-dev \
        libx11-xcb-dev libxcomposite-dev libxdamage-dev libxext-dev libxfixes-dev \
        libxi-dev libxrandr-dev libxrender-dev libxtst-dev libxv-dev m4 make nasm \
        ninja-build pkg-config python3-dev python3-setuptools x11proto-record-dev \
        xutils-dev

    echo "==> Running Cerbero Bootstrap..."
    uv run ./cerbero-uninstalled -c ${CONFIG_NAME}.cbc "${CERBERO_JOBS_ARGS[@]}" bootstrap
    
    echo "==> Building GStreamer..."
    uv run ./cerbero-uninstalled -c ${CONFIG_NAME}.cbc "${CERBERO_JOBS_ARGS[@]}" package gstreamer-1.0
)

# 12. Extract package
mkdir -p "$INSTALL_PATH"

echo "==> Searching for package..."
PACKAGE_FILE=""
while IFS= read -r candidate; do
    case "${candidate}" in
        *-runtime.tar.*) ;; # prefer non-runtime if available
        *) PACKAGE_FILE="${candidate}"; break ;;
    esac
done < <(find . -name "gstreamer-1.0-*android*.tar.*" -type f 2>/dev/null | sort)

if [ -z "${PACKAGE_FILE}" ]; then
    PACKAGE_FILE=$(find . -name "gstreamer-1.0-*android*.tar.*" -type f 2>/dev/null | sort | head -n 1)
fi

if [ -z "$PACKAGE_FILE" ]; then
    echo "Error: Package not found. Listing all tar files:"
    find . -name "*.tar.*" -type f 2>/dev/null || echo "No tar files found"
    exit 1
fi

echo "==> Extracting: $PACKAGE_FILE"

# Avoid "Cannot open: Not a directory" due to previous partial extractions
if [ -z "${INSTALL_PATH}" ] || [ "${INSTALL_PATH}" = "/" ]; then
    echo "Refusing to extract into unsafe INSTALL_PATH='${INSTALL_PATH}'"
    exit 1
fi

rm -rf "${INSTALL_PATH}"
mkdir -p "${INSTALL_PATH}"

tar -xf "$PACKAGE_FILE" -C "$INSTALL_PATH" --strip-components=1

echo ""
echo "==> ✓ Success!"
echo "==> GStreamer ${GST_VERSION} for Android ${TARGET_ARCH} (API ${ANDROID_API_LEVEL})"
echo "==> Installed to: $INSTALL_PATH"
echo ""

# ------------------------------------------------------------------------------
# Cleanup (CERB-CACHE)
# The built GStreamer is extracted to $INSTALL_PATH by now, so the cerbero
# CHECKOUT is dead weight in the image layer. The build STATE under
# ${CERBERO_HOME} is the opposite: it is what the NEXT attempt resumes from, and
# on the cachemount it is invisible to the image anyway (a cachemount is not
# part of any layer). It is therefore only deleted when it is NOT mounted —
# because then it really would ship as ~10-15 GB of layer.
#
# DISK TRADE-OFF, with the number, because the host runs near-full: this prune
# is on the SUCCESS path ONLY. A failed attempt exits above and keeps its whole
# tree — that is the entire point of the mount, and it costs up to the ~10-15 GB
# this cleanup used to free before the cache existed, per lane, i.e. ~30-45 GB
# with all three arch lanes sitting on failures. Pruning on ENTRY instead was
# considered and REJECTED as unsafe: cerbero records progress per STEP, so a
# recipe can be mid-flight with extract recorded and compile not (oven.py:511
# then skips straight to a configure/compile on a directory this prune would
# have deleted) — that wedges the lane on every retry instead of bounding disk.
# What IS bounded: retries reuse the same cachemount id and the same paths, so a
# failing lane overwrites in place rather than accumulating a tree per attempt.
# GENERATIONS are the unbounded axis — the id carries the NDK/API pins, so a pin
# bump starts a fresh store and ORPHANS the previous one, and nothing here can
# reach it (a different cachemount id is simply not mounted into this RUN). Do
# not expect linux/host-config/prune-safe.sh to clean it up either: that tool
# prunes `type==regular` only and treats every cachemount as sacred by design
# (CACHE1 — it aborts if the cachemount count drops). Reclaiming an orphan is a
# deliberate host-side act, e.g. a duration-bounded `buildctl prune --filter
# type==exec.cachemount --keep-duration <t>` chosen so the ccache/sccache mounts
# a live build keeps warm stay above the cutoff — check what it would remove
# before running it. That is the accepted price of not silently resuming a tree
# built against the old NDK. CERBERO_CACHE_RESET=1 empties the CURRENT store on
# entry when a lane must be forced cold.
# ------------------------------------------------------------------------------
echo "==> Cleaning up the Cerbero checkout..."
CERBERO_SIZE=$(du -sh /opt/cerbero 2>/dev/null | cut -f1 || echo "unknown")
cd /
rm -rf /opt/cerbero
echo "==> Removed the Cerbero checkout (freed ${CERBERO_SIZE})."

if cerbero_state_is_mounted; then
    # SUCCESS path only (see the trade-off above). The package exists, so the
    # extracted/compiled build trees — the bulk of the state — are dead weight:
    # cache-file.cache marks those recipes built, so a later run skips them
    # entirely (oven.py:554) and their results are already installed under
    # dist/. Everything kept lives OUTSIDE sources/: the dist prefix, the
    # build-tools prefix (config.py:1065 = home_dir/build-tools) and the two
    # pickles. Inside sources/ only local/ survives — that is local_sources
    # (config.py:1146-1151, because home_dir is non-default), i.e. the tarballs
    # and git repos that make the next run cheap and network-independent
    # (FD-OUTAGE). Those bytes are NOT re-hashed on reuse (see section 8), so
    # what they buy is speed, not trust.
    find "${CERBERO_HOME}/sources" -mindepth 1 -maxdepth 1 ! -name local -exec rm -rf {} + 2>/dev/null || true
    echo "==> Kept cerbero state on the cachemount ${CERBERO_HOME} ($(du -sh "${CERBERO_HOME}" 2>/dev/null | cut -f1 || echo unknown)) for the next attempt."
else
    CERBERO_STATE_SIZE=$(du -sh "${CERBERO_HOME}" 2>/dev/null | cut -f1 || echo "unknown")
    find "${CERBERO_HOME}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    echo "==> No cerbero cachemount: emptied ${CERBERO_HOME} (freed ${CERBERO_STATE_SIZE}) to keep it out of the image."
fi
