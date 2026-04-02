#!/usr/bin/env bash
set -eux

# Ensure OpenCV shared libraries are visible to the system linker during
# the GStreamer build. Some build steps ignore -L ordering, so copy all
# libopencv*.so* into /usr/lib and multiarch /usr/lib/<triplet> before
# building GStreamer.
OPENCV_OUTPUT_DIR="${1:-/opt/opencv4}"

triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
for libdir in "${OPENCV_OUTPUT_DIR}/lib" "${OPENCV_OUTPUT_DIR}/lib64"; do
    if [ -d "$libdir" ]; then
        cd "$libdir"
        # First fix symlinks inside OpenCV lib dir directly
        candidate=$(ls -1 libopencv_tracking.so* 2>/dev/null | head -n1 || true)
        if [ -n "$candidate" ]; then
            if [ ! -e libopencv_tracking.so ]; then
                echo "Creating symlink $libdir/libopencv_tracking.so -> $candidate"
                ln -sf "$candidate" libopencv_tracking.so || true
            fi
            if [ -n "$triplet" ] && [ -d "/usr/lib/$triplet" ]; then
                ln -sf "$libdir/$candidate" "/usr/lib/$triplet/libopencv_tracking.so" || true
            fi
            ln -sf "$libdir/$candidate" "/usr/lib/libopencv_tracking.so" || true
        fi

        # Also copy actual files to multiarch lib dir for some legacy build tools
        for f in libopencv_*.so*; do
            [ -e "$f" ] || continue
            src="$libdir/$f"
            if [ -n "$triplet" ] && [ -d "/usr/lib/$triplet" ]; then
                install -m 0644 -D "$src" "/usr/lib/$triplet/$(basename "$f" | sed 's/\..*$/.so/')" || true
            fi
            install -m 0644 -D "$src" "/usr/lib/$(basename "$f" | sed 's/\..*$/.so/')" || true
        done
    fi
done
ldconfig || true

# Create a linker script in /usr/lib so `-lopencv_tracking` always resolves
# to the versioned library in /opt/opencv4/lib even if the build system
# doesn't respect -L ordering.
tracking_candidate="$(ls -1 ${OPENCV_OUTPUT_DIR}/lib/libopencv_tracking.so* 2>/dev/null | head -n1 || true)"
if [ -n "$tracking_candidate" ]; then
    echo "Found tracking lib: $tracking_candidate"
    script=/usr/lib/libopencv_tracking.so
    echo "INPUT($tracking_candidate)" > "$script" || true
    if [ -n "$triplet" ] && [ -d "/usr/lib/$triplet" ]; then
        mkdir -p "/usr/lib/$triplet" || true
        echo "INPUT($tracking_candidate)" > "/usr/lib/$triplet/libopencv_tracking.so" || true
    fi
fi
ldconfig || true
