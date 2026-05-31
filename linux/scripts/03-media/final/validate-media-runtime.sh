#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

ARTIFACTS=(
  "${GSTREAMER_PREFIX:-/opt/gstreamer}/bin/gst-launch-1.0"
  "${LIBCAMERA_PREFIX:-/opt/libcamera}/bin/cam"
  "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg"
)

LIB_DIRS=(
  "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib"
  "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib/multiarch"
  "${LIBCAMERA_PREFIX:-/opt/libcamera}/lib"
  "${LIBCAMERA_PREFIX:-/opt/libcamera}/lib64"
  "${FFMPEG_PREFIX:-/opt/ffmpeg}/lib"
  "/opt/opencv4/lib"
  "/usr/local/lib"
  "/usr/local/lib/onnxruntime-cpu/lib"
)

declare -A KNOWN_SO_PACKAGES=(
  ["libxml2.so.2"]="libxml2"
  ["libevent_core-2.1.so.7"]="libevent-core-2.1-7t64"
  ["libevent_pthreads-2.1.so.7"]="libevent-pthreads-2.1-7t64"
  ["libevent_extra-2.1.so.7"]="libevent-extra-2.1-7t64"
  ["libevent_openssl-2.1.so.7"]="libevent-openssl-2.1-7t64"
  ["liblzma.so.5"]="liblzma5"
  ["libbz2.so.1.0"]="libbz2-1.0"
  ["libzstd.so.1"]="libzstd1"
  ["libreadline.so.8"]="libreadline8t64"
  ["libncursesw.so.6"]="libncursesw6"
  ["libtinfo.so.6"]="libtinfo6"
  ["libpanelw.so.6"]="libpanelw6"
  ["libgdbm.so.6"]="libgdbm6t64"
  ["libgdbm_compat.so.4"]="libgdbm-compat4t64"
  ["libexpat.so.1"]="libexpat1"
  ["libffi.so.8"]="libffi8"
  ["libsqlite3.so.0"]="libsqlite3-0"
  ["libssl.so.3"]="libssl3t64"
  ["libcrypto.so.3"]="libssl3t64"
  ["libgmp.so.10"]="libgmp10"
  ["libhogweed.so.6"]="libhogweed6t64"
  ["libnettle.so.8"]="libnettle8t64"
  ["libgnutls.so.30"]="libgnutls30t64"
  ["libp11-kit.so.0"]="libp11-kit0"
  ["libidn2.so.0"]="libidn2-0"
  ["libunistring.so.5"]="libunistring5"
  ["libtasn1.so.6"]="libtasn1-6"
  ["libjpeg.so.8"]="libjpeg-turbo8"
  ["libpng16.so.16"]="libpng16-16t64"
  ["libtiff.so.6"]="libtiff6"
  ["libwebp.so.7"]="libwebp7"
  ["libvpx.so.9"]="libvpx9"
  ["libx264.so.164"]="libx264-164"
  ["libx265.so.209"]="libx265-209"
  ["libaom.so.3"]="libaom3"
  ["libdav1d.so.7"]="libdav1d7"
  ["libopenjp2.so.7"]="libopenjp2-7"
  ["libdeflate.so.0"]="libdeflate0"
  ["libjbig.so.0"]="libjbig0"
  ["libLerc.so.4"]="liblerc4"
  ["libtheora.so.0"]="libtheora0"
  ["libtheoradec.so.1"]="libtheora0"
  ["libtheoraenc.so.1"]="libtheora0"
  ["libogg.so.0"]="libogg0"
  ["libvorbis.so.0"]="libvorbis0a"
  ["libvorbisenc.so.2"]="libvorbisenc2"
  ["libFLAC.so.14"]="libflac14"
  ["libFLAC++.so.10"]="libflac++10"
  ["libmp3lame.so.0"]="libmp3lame0"
  ["libmpg123.so.0"]="libmpg123-0t64"
  ["libopus.so.0"]="libopus0"
  ["libspeex.so.1"]="libspeex1"
  ["libspeexdsp.so.1"]="libspeexdsp1"
  ["libwavpack.so.1"]="libwavpack1"
  ["libgsm.so.1"]="libgsm1"
  ["libtwolame.so.0"]="libtwolame0"
  ["libopenh264.so.7"]="libopenh264-7"
  ["libsrtp2.so.1"]="libsrtp2-1"
  ["libsoup-3.0.so.0"]="libsoup-3.0-0"
  ["libsoup-2.4.so.1"]="libsoup-2.4-1"
  ["libcurl.so.4"]="libcurl4t64"
  ["libcurl-gnutls.so.4"]="libcurl3t64-gnutls"
  ["libnghttp2.so.14"]="libnghttp2-14"
  ["librtmp.so.1"]="librtmp1"
  ["libssh2.so.1"]="libssh2-1t64"
  ["libpsl.so.5"]="libpsl5t64"
  ["libbrotlidec.so.1"]="libbrotli1"
  ["libbrotlienc.so.1"]="libbrotli1"
  ["libbrotlicommon.so.1"]="libbrotli1"
  ["libasound.so.2"]="libasound2t64"
  ["libpulse.so.0"]="libpulse0"
  ["libpipewire-0.3.so.0"]="libpipewire-0.3-0t64"
  ["libjack.so.0"]="libjack0"
  ["libsndfile.so.1"]="libsndfile1"
  ["libsamplerate.so.0"]="libsamplerate0"
  ["libv4l2.so.0"]="libv4l-0"
  ["libudev.so.1"]="libudev1"
  ["libusb-1.0.so.0"]="libusb-1.0-0"
  ["libboost_program_options.so.1.83.0"]="libboost-program-options1.83.0"
  ["libboost_program_options.so.1.74.0"]="libboost-program-options1.74.0"
  ["libyaml-0.so.2"]="libyaml-0-2"
  ["libdw.so.1"]="libdw1t64"
  ["libunwind.so.8"]="libunwind8"
  ["libunwind-x86_64.so.8"]="libunwind8"
  ["libunwind-aarch64.so.8"]="libunwind8"
  ["libunwind-riscv.so.8"]="libunwind8"
  ["libva.so.2"]="libva2"
  ["libva-drm.so.2"]="libva-drm2"
  ["libva-x11.so.2"]="libva-x11-2"
  ["libdrm.so.2"]="libdrm2"
  ["libgbm.so.1"]="libgbm1"
  ["libepoxy.so.0"]="libepoxy0"
  ["libGL.so.1"]="libgl1"
  ["libEGL.so.1"]="libegl1"
  ["libGLESv2.so.2"]="libgles2"
  ["libwayland-client.so.0"]="libwayland-client0"
  ["libwayland-egl.so.1"]="libwayland-egl1"
  ["libwayland-server.so.0"]="libwayland-server0"
  ["libwayland-cursor.so.0"]="libwayland-cursor0"
  ["libxkbcommon.so.0"]="libxkbcommon0"
  ["libxkbcommon-x11.so.0"]="libxkbcommon-x11-0"
  ["libX11.so.6"]="libx11-6"
  ["libXext.so.6"]="libxext6"
  ["libXfixes.so.3"]="libxfixes3"
  ["libXdamage.so.1"]="libxdamage1"
  ["libXrandr.so.2"]="libxrandr2"
  ["libXrender.so.1"]="libxrender1"
  ["libXau.so.6"]="libxau6"
  ["libXdmcp.so.6"]="libxdmcp6"
  ["libxcb.so.1"]="libxcb1"
  ["libxcb-shm.so.0"]="libxcb1"
  ["libxcb-render.so.0"]="libxcb1"
  ["libxcb-xfixes.so.0"]="libxcb1"
  ["libXi.so.6"]="libxi6"
  ["libXcursor.so.1"]="libxcursor1"
  ["libXinerama.so.1"]="libxinerama1"
  ["libXv.so.1"]="libxv1"
  ["libfontconfig.so.1"]="libfontconfig1"
  ["libfreetype.so.6"]="libfreetype6"
  ["libfribidi.so.0"]="libfribidi0"
  ["libpixman-1.so.0"]="libpixman-1-0"
  ["libharfbuzz.so.0"]="libharfbuzz0b"
  ["libgraphite2.so.3"]="libgraphite2-3"
  ["libcairo.so.2"]="libcairo2"
  ["libpango-1.0.so.0"]="libpango-1.0-0"
  ["libpangocairo-1.0.so.0"]="libpangocairo-1.0-0"
  ["libpangoft2-1.0.so.0"]="libpangoft2-1.0-0"
  ["libpangoxft-1.0.so.0"]="libpangoxft-1.0-0"
  ["libgdk_pixbuf-2.0.so.0"]="libgdk-pixbuf-2.0-0"
  ["libgio-2.0.so.0"]="libglib2.0-0t64"
  ["libglib-2.0.so.0"]="libglib2.0-0t64"
  ["libgobject-2.0.so.0"]="libglib2.0-0t64"
  ["libgmodule-2.0.so.0"]="libglib2.0-0t64"
  ["libgthread-2.0.so.0"]="libglib2.0-0t64"
  ["libjson-glib-1.0.so.0"]="libjson-glib-1.0-0"
  ["libgtk-4.so.1"]="libgtk-4-1"
  ["libgtk-3.so.0"]="libgtk-3-0t64"
  ["libstdc++.so.6"]="libstdc++6"
  ["libgcc_s.so.1"]="libgcc-s1"
  ["libatomic.so.1"]="libatomic1"
  ["libmvec.so.1"]="libmvec1"
  ["libcsound64.so.6.0"]="libcsound64-6.0"
  ["libopenexr-3_2.so.31"]="libopenexr-3-2-31"
  ["libImath-3_2.so.29"]="libimath-3-2-29t64"
  ["libIex-3_2.so.31"]="libopenexr-3-2-31"
  ["libcdio.so.19"]="libcdio19t64"
  ["libcdio_paranoia.so.2"]="libcdio-paranoia2t64"
  ["libcdio_cdda.so.2"]="libcdio-cdda2t64"
  ["libdc1394.so.26"]="libdc1394-26"
  ["libraw1394.so.11"]="libraw1394-11t64"
  ["libswresample.so.5"]="libswresample5"
  ["libswscale.so.8"]="libswscale8"
  ["libavcodec.so.62"]="libavcodec62"
  ["libavformat.so.62"]="libavformat62"
  ["libavutil.so.60"]="libavutil60"
  ["libavfilter.so.11"]="libavfilter11"
  ["libavdevice.so.62"]="libavdevice62"
  ["libpostproc.so.58"]="libpostproc58"
)

find_missing_needed() {
  local binary="$1"
  local missing=()

  [ -f "${binary}" ] || [ -L "${binary}" ] || { echo "WARNING: ${binary} not found, skipping" >&2; return 0; }

  echo "Checking: ${binary}" >&2

  local so_name
  for so_name in $(objdump -p "${binary}" 2>/dev/null | awk '/NEEDED/ {print $2}'); do
    local found=false

    for dir in "${LIB_DIRS[@]}" /usr/lib /lib /usr/lib/*-linux-gnu* /usr/local/lib/*-linux-gnu*; do
      [ -d "${dir}" ] || continue
      if [ -f "${dir}/${so_name}" ]; then
        found=true
        break
      fi
    done

    if [ "${found}" = "false" ]; then
      if ldconfig -p 2>/dev/null | grep -qF " ${so_name} "; then
        found=true
      fi
    fi

    if [ "${found}" = "false" ]; then
      echo "  MISSING: ${so_name}" >&2
      missing+=("${so_name}")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
  fi
}

resolve_package_for_so() {
  local so_name="$1"
  local pkg=""

  pkg="${KNOWN_SO_PACKAGES[${so_name}]:-}"

  if [ -n "${pkg}" ]; then
    echo "${pkg}"
    return 0
  fi

  pkg="$(dpkg-query -S "${so_name}" 2>/dev/null | head -1 | cut -d: -f1 || true)"

  if [ -n "${pkg}" ]; then
    echo "${pkg}"
    return 0
  fi

  local base_lib="${so_name%%.so*}"
  if apt-cache search "^${base_lib}[0-9]" 2>/dev/null | head -1 | grep -q .; then
    pkg="$(apt-cache search "^${base_lib}[0-9]" 2>/dev/null | head -1 | awk '{print $1}')"
    if [ -n "${pkg}" ]; then
      echo "${pkg}"
      return 0
    fi
  fi

  return 1
}

scan_plugin_directory() {
  local plugin_dir="$1"

  [ -d "${plugin_dir}" ] || return 0

  echo "Scanning plugins in: ${plugin_dir}" >&2

  local missing_all=()

  local p
  for p in "${plugin_dir}"/*.so; do
    [ -f "${p}" ] || continue

    local so_name
    for so_name in $(objdump -p "${p}" 2>/dev/null | awk '/NEEDED/ {print $2}'); do
      local found=false

      for dir in "${LIB_DIRS[@]}" /usr/lib /lib /usr/lib/*-linux-gnu* /usr/local/lib/*-linux-gnu*; do
        [ -d "${dir}" ] || continue
        if [ -f "${dir}/${so_name}" ]; then
          found=true
          break
        fi
      done

      if [ "${found}" = "false" ]; then
        if ldconfig -p 2>/dev/null | grep -qF " ${so_name} "; then
          found=true
        fi
      fi

      if [ "${found}" = "false" ]; then
        missing_all+=("${so_name}")
        break
      fi
    done
  done

  if [ ${#missing_all[@]} -gt 0 ]; then
    printf '%s\n' "Some plugins have missing deps:" "${missing_all[@]}" >&2
  fi

  if [ ${#missing_all[@]} -gt 0 ]; then
    printf '%s\n' "${missing_all[@]}"
  fi
}

uniq_nonempty_lines() {
  grep -v '^$' | sort -u || true
}

echo "=== Media Runtime Validation ==="

ALL_MISSING=()

for artifact in "${ARTIFACTS[@]}"; do
  mapfile -t missing_list < <(find_missing_needed "${artifact}")
  ALL_MISSING+=("${missing_list[@]}")
done

gst_plugin_dir="${GSTREAMER_PREFIX:-/opt/gstreamer}/lib/multiarch/gstreamer-1.0"
if [ -d "${gst_plugin_dir}" ]; then
  mapfile -t plugin_missing < <(scan_plugin_directory "${gst_plugin_dir}")
  ALL_MISSING+=("${plugin_missing[@]}")
fi

mapfile -t UNIQ_MISSING < <(printf '%s\n' "${ALL_MISSING[@]}" | uniq_nonempty_lines)

if [ ${#UNIQ_MISSING[@]} -eq 0 ]; then
  echo "All artifacts have their runtime dependencies satisfied."
  exit 0
fi

echo ""
echo "=== Resolving ${#UNIQ_MISSING[@]} missing dependencies ==="

PACKAGES_TO_INSTALL=()
STILL_MISSING=()

for so_name in "${UNIQ_MISSING[@]}"; do
  pkg="$(resolve_package_for_so "${so_name}" || true)"
  if [ -n "${pkg}" ]; then
    echo "  ${so_name} -> ${pkg}"
    PACKAGES_TO_INSTALL+=("${pkg}")
  else
    echo "  ${so_name} -> UNKNOWN (no apt package mapping found)"
    STILL_MISSING+=("${so_name}")
  fi
done

mapfile -t UNIQ_PKGS < <(printf '%s\n' "${PACKAGES_TO_INSTALL[@]}" | uniq_nonempty_lines)

if [ ${#UNIQ_PKGS[@]} -gt 0 ]; then
  echo ""
  echo "Installing ${#UNIQ_PKGS[@]} runtime packages..."

  if command -v cross_apt_update >/dev/null 2>&1; then
    cross_apt_update
  else
    apt-get update
  fi

  if command -v install_target_packages >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive install_target_packages "${UNIQ_PKGS[@]}" || true
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${UNIQ_PKGS[@]}" || true
  fi

  ldconfig

  echo ""
  echo "=== Re-checking after package install ==="
  REMAINING=()
  for artifact in "${ARTIFACTS[@]}"; do
    mapfile -t still_missing < <(find_missing_needed "${artifact}")
    REMAINING+=("${still_missing[@]}")
  done

  mapfile -t UNIQ_REMAINING < <(printf '%s\n' "${REMAINING[@]}" | uniq_nonempty_lines)

  if [ ${#UNIQ_REMAINING[@]} -gt 0 ]; then
    echo ""
    echo "=== WARNING: ${#UNIQ_REMAINING[@]} dependencies still unresolved ==="
    printf '  %s\n' "${UNIQ_REMAINING[@]}"
    echo ""
    echo "These libraries could not be found in any apt package. The artifacts"
    echo "that depend on them (and the plugins that load them) will fail at"
    echo "runtime. Review the build configuration or add package mappings"
    echo "to KNOWN_SO_PACKAGES in validate-media-runtime.sh."
  else
    echo "All dependencies resolved after package install."
  fi
fi

if [ ${#STILL_MISSING[@]} -gt 0 ]; then
  echo ""
  echo "=== WARNING: ${#STILL_MISSING[@]} dependencies have no known apt package ==="
  printf '  %s\n' "${STILL_MISSING[@]}"
  echo "Add entries to KNOWN_SO_PACKAGES in validate-media-runtime.sh."
fi

echo ""
echo "=== Validation complete ==="
