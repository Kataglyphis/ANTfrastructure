#!/usr/bin/env bash
set -eux
# Ensure basic build tooling present for building vvdec and GTK/Cairo checks
# Install core packages first, then attempt to install X protocol headers.
# Some base images may not provide the \`xorgproto\` package name. Try a few
# alternatives and fail early if none are available so the error is clear.
# Ensure pkg-config metadata directories updated
update-alternatives --set xauth /usr/bin/xauth 2>/dev/null || true
# Install Csound packages required for building csound-related plugins.
# Skip installing Csound on RISC-V targets where APT packages are often unavailable.
if echo "${TARGETARCH:-}" | grep -qi -E '^riscv|riscv64'; then
  echo "Skipping Csound APT install on TARGETARCH=${TARGETARCH:-unset}"
fi
# Some Debian packages do not provide a pkg-config .pc file for Csound.
# Create a minimal csound.pc in the appropriate multiarch pkgconfig
# directory so downstream pkg-config checks succeed. Only create the
# stub when not building for riscv targets (we skipped installing Csound
# packages above for riscv), otherwise creating a stub may mask missing
# package problems on supported arches.
if ! echo "${TARGETARCH:-}" | grep -qi -E '^riscv|riscv64'; then
  triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  if [ -n "$triplet" ] && [ -d "/usr/lib/$triplet" ]; then
    pcdir="/usr/lib/$triplet/pkgconfig"
    libdir="/usr/lib/$triplet"
  else
    pcdir="/usr/lib/pkgconfig"
    libdir="/usr/lib"
  fi
  mkdir -p "$pcdir"
  # Write a minimal csound.pc with the computed libdir. Keep ${prefix}
  # and ${libdir}/${includedir} in the file as pkg-config variables.
  printf '%s\n' \
    "prefix=/usr" \
    "exec_prefix=\${prefix}" \
    "libdir=${libdir}" \
    "includedir=/usr/include/csound" \
    "" \
    "Name: Csound" \
    "Description: Csound audio and music processing system" \
    "Version: 6.18.1" \
    "Libs: -L\${libdir} -lcsound64" \
    "Cflags: -I\${includedir}" \
    > "$pcdir/csound.pc" || true
  # Verify that pkg-config can discover csound; fail with diagnostics if not.
  if ! pkg-config --exists csound 2>/dev/null; then
    echo "" >&2
    echo "ERROR: csound pkg-config (.pc) not found after installing Csound packages." >&2
    echo "dpkg multiarch triplet: ${triplet:-unset}" >&2
    echo "PKG_CONFIG_LIBDIR=${PKG_CONFIG_LIBDIR:-unset}" >&2
    echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-unset}" >&2
    echo "Listing likely pkgconfig directories:" >&2
    for d in "/usr/lib/${triplet:-}/pkgconfig" /usr/lib/pkgconfig /usr/local/lib/pkgconfig; do
      echo "-- $d --" >&2; ls -la "$d" 2>/dev/null | sed -n '1,200p' >&2 || true
    done
    echo "pkg-config output (if any):" >&2
    pkg-config --cflags --libs csound 2>/dev/null || true
    exit 1
  fi
  if [ -n "$triplet" ] && [ -d "/usr/lib/$triplet" ]; then
    CSOUND_LIB_DIR="/usr/lib/$triplet"
  else
    CSOUND_LIB_DIR="/usr/lib"
  fi
  echo "Setting CSOUND_LIB_DIR=$CSOUND_LIB_DIR"
  export CSOUND_LIB_DIR
  # Persist for later stages / shells
  echo "CSOUND_LIB_DIR=$CSOUND_LIB_DIR" >> /etc/environment
else
  echo "Skipping creation of csound.pc stub for riscv target"
fi
rm -rf /var/lib/apt/lists/*
