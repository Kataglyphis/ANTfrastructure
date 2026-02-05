# syntax=docker/dockerfile:1.19

# ------------------------------------------------------------------------------
# Global build args (available to all stages)
# ------------------------------------------------------------------------------
ARG BUILD_TYPE=Release
ARG VULKAN_VERSION=1.4.335.0
ARG LLVM_WANTED=21
ARG CLANG_WANTED=21
ARG GCC_WANTED=15
ARG GCC_VERSION=15.2.0
ARG TARGETARCH

# ------------------------------------------------------------------------------
# STAGE 1: OS + stable dependencies (rarely changes)
# This stage intentionally avoids COPY of scripts to keep apt layers cacheable.
# ------------------------------------------------------------------------------
FROM ubuntu:24.04 AS os-deps

ARG BUILD_TYPE
ARG VULKAN_VERSION
ARG TARGETARCH

# ------------------------------------------------------------------------------
# Shell
# ------------------------------------------------------------------------------
SHELL ["bash", "-lc"]

# ------------------------------------------------------------------------------
# GPU-ENV
# ------------------------------------------------------------------------------
ENV NVIDIA_DRIVER_CAPABILITIES=all \
    NVIDIA_VISIBLE_DEVICES=all \
    VULKAN_VERSION=${VULKAN_VERSION}

# ------------------------------------------------------------------------------
# Basis-ENV
# ------------------------------------------------------------------------------
ENV DEBIAN_FRONTEND=noninteractive \
    APT_LISTCHANGES_FRONTEND=none \
    WORKDIR=/workspace \
    PATH=/usr/local/cargo/bin:/root/.local/bin:$PATH \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    CCACHE_DIR=/var/cache/ccache \
    CCACHE_MAXSIZE=30G \
    RUSTC_WRAPPER="" \
    SCCACHE_DIR=/var/cache/sccache

# ==============================================================================
# OS dependencies
# ==============================================================================

# ------------------------------------------------------------------------------
# Basis-Pakete (ein RUN, BuildKit-Caches)
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    set -eux; \
    ARCH="$(dpkg --print-architecture)" && \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nano tmux vim \
        sudo curl ca-certificates gnupg wget xz-utils libssl-dev git \
        build-essential ninja-build make sccache ccache \
        libc++-18-dev libc++abi-18-dev \
        $([ "$ARCH" != "riscv64" ] && echo "clang clang-format clang-tidy lld llvm llvm-dev libclang-dev libclang-rt-dev") \
        pkg-config lsb-release software-properties-common \
        meson python3 python3-venv python3-dev python3-pip \
        patchelf unzip zip \
        $([ "$ARCH" != "riscv64" ] && echo "lldb"); \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Install Graphics/Docs Deps
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
        set -eux; \
        apt-get update -y; \
        apt-get install -y --no-install-recommends \
            doxygen iwyu graphviz gcovr \
            libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
            libglu1-mesa-dev freeglut3-dev mesa-common-dev mesa-utils \
            wayland-protocols libwayland-dev libxkbcommon-dev \
            libglx-mesa0 libosmesa6-dev; \
        apt-get clean; \
        rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Additional dependencies; for frontend dev (with f.e. flutter/dart)
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
        set -eux; \
        arch="$(dpkg --print-architecture)"; \
        apt-get update -y; \
        apt-get install -y --no-install-recommends \
            libgtk-3-dev libglib2.0-dev libgdk-pixbuf2.0-dev libatk1.0-dev \
            libpango1.0-dev libx11-dev libx11-xcb-dev \
            libasound2-dev libpulse-dev libdbus-1-dev \
            file dpkg-dev fakeroot patchelf binutils $( [ "$arch" != "riscv64" ] && echo valgrind || true ); \
        apt-get clean; \
        rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Performance analysis tools (perf)
# ------------------------------------------------------------------------------        
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    set -eux; \
    apt-get update -y; \
    apt-get install -y --no-install-recommends linux-tools-common linux-tools-generic; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Install Node.js (different for RISC-V vs. other architectures)
# ------------------------------------------------------------------------------ 
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    set -eux; \
    ARCH=$(dpkg --print-architecture); \
    if [ "$ARCH" = "riscv64" ]; then \
        echo "RISC-V detected: Installing Node.js from default apt repo"; \
        apt-get update && apt-get install -y --no-install-recommends nodejs npm; \
    else \
        echo "Non-RISC-V architecture: Installing Node.js from NodeSource"; \
        curl -sL https://deb.nodesource.com/setup_24.x | bash - && \
        apt-get update && apt-get install -y --no-install-recommends nodejs; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Vulkan ICD/Layer-JSONs
# ------------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /etc/vulkan/icd.d /usr/share/glvnd/egl_vendor.d /etc/vulkan/implicit_layer.d

COPY linux/vulkan/nvidia_icd.json.in /tmp/nvidia_icd.json.in
COPY linux/vulkan/10_nvidia.json /usr/share/glvnd/egl_vendor.d/10_nvidia.json
COPY linux/vulkan/nvidia_layers.json.in /tmp/nvidia_layers.json.in

RUN set -eux; \
    sed "s|@@VULKAN_VERSION@@|${VULKAN_VERSION}|g" /tmp/nvidia_icd.json.in > /etc/vulkan/icd.d/nvidia_icd.json; \
    sed "s|@@VULKAN_VERSION@@|${VULKAN_VERSION}|g" /tmp/nvidia_layers.json.in > /etc/vulkan/implicit_layer.d/nvidia_layers.json; \
    rm -f /tmp/nvidia_icd.json.in /tmp/nvidia_layers.json.in

# ------------------------------------------------------------------------------
# Rust via rustup + cargo-c
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    set -eux; \
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; \
    rustc --version; \
    cargo --version; \
    cargo install --locked cargo-c

# ------------------------------------------------------------------------------
# uv installieren
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/uv \
    set -eux; \
    curl -LsSf https://astral.sh/uv/install.sh | sh

# ------------------------------------------------------------------------------
# Compiler-Caches initialisieren
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/ccache \
    --mount=type=cache,target=/var/cache/sccache \
    set -eux; \
    ccache -M "${CCACHE_MAXSIZE}" || true

# ------------------------------------------------------------------------------
# STAGE 2: Toolchain setup (changes occasionally)
# Script changes should not invalidate Stage 1.
# ------------------------------------------------------------------------------
FROM os-deps AS toolchain

ARG LLVM_WANTED
ARG CLANG_WANTED
ARG GCC_WANTED
ARG GCC_VERSION
ARG VULKAN_VERSION
ARG TARGETARCH

COPY linux/scripts/01-core/ /opt/scripts/core/
COPY linux/scripts/02-toolchain/ /opt/scripts/toolchain/

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
        --mount=type=cache,target=/var/lib/apt \
        set -eux; \
        # Ensure core modules are available in toolchain dir
        for f in /opt/scripts/core/*.sh; do \
            dst="/opt/scripts/toolchain/$(basename \"$f\")"; \
            [ -f "$dst" ] || ln -s "$f" "$dst"; \
        done; \
        # Run dependency setup
        bash /opt/scripts/toolchain/setup-dependencies.sh cmake; \
        bash /opt/scripts/toolchain/setup-dependencies.sh extras; \
        bash /opt/scripts/toolchain/setup-dependencies.sh --gcc "${GCC_WANTED}" gcc; \
        # IMPORTANT: Source the environment after GCC installation
        if [ -f "/etc/environment" ]; then \
            set -a; \
            . /etc/environment; \
            set +a; \
        fi; \
        if [ "${TARGETARCH:-$(dpkg --print-architecture)}" = "riscv64" ]; then \
                echo "NOTICE: Detected riscv64 architecture." >&2; \
                echo "apt.llvm.org does not provide prebuilt LLVM/Clang packages for riscv64." >&2; \
        else \
                bash /opt/scripts/toolchain/setup-dependencies.sh --llvm "${LLVM_WANTED}" --clang "${CLANG_WANTED}" llvm; \
                bash /opt/scripts/toolchain/setup-dependencies.sh --vulkan-version "${VULKAN_VERSION}" vulkan; \
        fi; \
        bash /opt/scripts/toolchain/setup-dependencies.sh verify

# Set ENV vars for subsequent layers (critical for Docker multi-stage builds)
ENV PATH="/opt/gcc-${GCC_VERSION}/bin:${PATH}" \
    PKG_CONFIG_PATH="/opt/gcc-${GCC_VERSION}/lib64/pkgconfig:/opt/gcc-${GCC_VERSION}/lib/pkgconfig:${PKG_CONFIG_PATH}" \
    LD_LIBRARY_PATH="/opt/gcc-${GCC_VERSION}/lib64:/opt/gcc-${GCC_VERSION}/lib:${LD_LIBRARY_PATH}"

# Fix for GCC 15 missing libgcc_s and libstdc++ symlinks
RUN set -eux; \
    # 1. Fix libgcc_s
    find /usr -name "libgcc_s.so.1" -print -exec ln -sf {} /usr/lib/libgcc_s.so \; ; \
    # 2. Fix libstdc++
    find /usr -name "libstdc++.so.6" -print -exec ln -sf {} /usr/lib/libstdc++.so \; ; \
    # 3. Verify links were created (optional debug step)
    ls -l /usr/lib/libgcc_s.so /usr/lib/libstdc++.so


# ==============================================================================
# LAYER 2.5: Frameworks; TVM (heavy, but stable enough to cache)
# ==============================================================================
COPY linux/scripts/05-frameworks/ /opt/scripts/frameworks/
RUN chmod +x /opt/scripts/frameworks/*.sh || true

ARG TVM_REF=v0.22.0
ARG TVM_BUILD_TYPE=${BUILD_TYPE}
ARG TVM_USE_VULKAN=1
ARG TVM_INSTALL_PYTHON=1

ENV TVM_REF=${TVM_REF} \
    TVM_BUILD_TYPE=${TVM_BUILD_TYPE} \
    TVM_USE_VULKAN=${TVM_USE_VULKAN}

#RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
#        --mount=type=cache,target=/var/lib/apt \
#        --mount=type=cache,target=/var/cache/ccache \
#        --mount=type=cache,target=/var/cache/sccache \
#        --mount=type=cache,target=/root/.cache/uv \
#        --mount=type=cache,target=/root/.cache/pip \
#        set -eux; \
#        arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
#        if [ "${TVM_INSTALL_PYTHON}" = "1" ]; then \
#            py_flag=""; \
#        else \
#            py_flag="--no-python"; \
#        fi; \
#        bash /opt/scripts/frameworks/tvm.sh \
#            --ref "${TVM_REF}" \
#            --build-type "${TVM_BUILD_TYPE}" \
#            ${py_flag}

# ------------------------------------------------------------------------------
# STAGE 3: Media stack (ONNX Runtime, GStreamer, Libcamera)
# ------------------------------------------------------------------------------
FROM toolchain AS media

ARG BUILD_TYPE
ARG TARGETARCH
ARG GSTREAMER_VERSION=1.28.0

# ------------------------------------------------------------------------------
# GStreamer-Build: ENV + Setup
# ------------------------------------------------------------------------------
ENV GSTREAMER_VERSION=${GSTREAMER_VERSION} \
    GSTREAMER_PREFIX=/opt/gstreamer \
    GST_PLUGIN_PATH="" \
    GI_TYPELIB_PATH=""

# Multiarch-Libdir-Symlink
RUN set -eux; \
    triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH)"; \
    mkdir -p "/opt/gstreamer/lib/${triplet}"; \
    ln -snf "/opt/gstreamer/lib/${triplet}" "/opt/gstreamer/lib/multiarch" || true

# GStreamer-ENV
ENV PKG_CONFIG_PATH="" \
    LD_LIBRARY_PATH="" \
    CMAKE_PREFIX_PATH=""
ENV PATH="${GSTREAMER_PREFIX}/bin:${PATH}"
ENV PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${GSTREAMER_PREFIX}/lib/multiarch/pkgconfig:${PKG_CONFIG_PATH}"
ENV CMAKE_PREFIX_PATH="/usr/local:${CMAKE_PREFIX_PATH}"
ENV LD_LIBRARY_PATH="/usr/local/lib:${GSTREAMER_PREFIX}/lib/multiarch:${LD_LIBRARY_PATH}"
ENV GST_PLUGIN_PATH="${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0:${GST_PLUGIN_PATH}"
ENV GI_TYPELIB_PATH="${GSTREAMER_PREFIX}/lib/multiarch/girepository-1.0:${GI_TYPELIB_PATH}"

# ------------------------------------------------------------------------------
# Libcamera-Build: ENV
# ------------------------------------------------------------------------------
ENV LIBCAMERA_PREFIX=/opt/libcamera
ENV PATH="${LIBCAMERA_PREFIX}/bin:${PATH}"
ENV PKG_CONFIG_PATH="${LIBCAMERA_PREFIX}/lib/pkgconfig:${LIBCAMERA_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH}"
ENV LD_LIBRARY_PATH="${LIBCAMERA_PREFIX}/lib:${LIBCAMERA_PREFIX}/lib64:${LD_LIBRARY_PATH}"
ENV GST_PLUGIN_PATH="${LIBCAMERA_PREFIX}/lib/gstreamer-1.0:${GST_PLUGIN_PATH}"

# ==============================================================================
# LAYER 3: Media stack; GStreamer only (changes when updating GStreamer)
# ==============================================================================
# ONNX Runtime build helper
COPY linux/scripts/03-media/onnxruntime/build /opt/scripts/media/onnxruntime/build
RUN chmod +x /opt/scripts/media/onnxruntime/build/*.sh /opt/scripts/media/onnxruntime/build/lib/*.sh || true

# Make gstreamer env helper available early so /opt/scripts/media/gstreamer/setup-gstreamer.sh
# can source it during the ONNX and GStreamer build steps (the runtime scripts are
# copied later in the Dockerfile).
COPY linux/scripts/04-runtime/gstreamer-env.sh /opt/scripts/04-runtime/gstreamer-env.sh
RUN chmod +x /opt/scripts/04-runtime/gstreamer-env.sh || true

# ----------------------------------------------------------------------------
# ONNX Runtime build args
# ----------------------------------------------------------------------------
# v1.23.2
ARG ONNXRUNTIME_VERSION=main
ARG ONNXRUNTIME_NATIVE_BUILD_TYPE=Release
ARG ONNXRUNTIME_WASM_BUILD_TYPE=Release

# ------------------------------------------------------------------------------
# ONNX Runtime build (split into steps for better Docker layer caching)
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
        --mount=type=cache,target=/var/lib/apt \
        set -eux; \
        export USER=root; \
    SKIP_DEP_INSTALL=true bash /opt/scripts/media/onnxruntime/build/10-deps.sh \
            --ort-version "${ONNXRUNTIME_VERSION}" \
            --build-type "${ONNXRUNTIME_NATIVE_BUILD_TYPE}" \
            --wasm-config "${ONNXRUNTIME_WASM_BUILD_TYPE}"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
        --mount=type=cache,target=/var/lib/apt \
        --mount=type=cache,target=/root/.cache/uv \
        --mount=type=cache,target=/root/.cache/pip \
        set -eux; \
        export USER=root; \
        bash /opt/scripts/media/onnxruntime/build/20-fetch.sh \
            --ort-version "${ONNXRUNTIME_VERSION}" \
            --build-type "${ONNXRUNTIME_NATIVE_BUILD_TYPE}" \
            --wasm-config "${ONNXRUNTIME_WASM_BUILD_TYPE}"

RUN --mount=type=cache,target=/var/cache/ccache \
        --mount=type=cache,target=/var/cache/sccache \
        --mount=type=cache,target=/usr/local/cargo/registry \
        --mount=type=cache,target=/usr/local/cargo/git \
        set -eux; \
        export USER=root; \
        bash /opt/scripts/media/onnxruntime/build/30-build-native.sh \
            --ort-version "${ONNXRUNTIME_VERSION}" \
            --build-type "${ONNXRUNTIME_NATIVE_BUILD_TYPE}" \
            --wasm-config "${ONNXRUNTIME_WASM_BUILD_TYPE}"

RUN --mount=type=cache,target=/var/cache/ccache \
        --mount=type=cache,target=/var/cache/sccache \
        set -eux; \
        export USER=root; \
        bash /opt/scripts/media/onnxruntime/build/40-build-wasm.sh \
            --ort-version "${ONNXRUNTIME_VERSION}" \
            --build-type "${ONNXRUNTIME_NATIVE_BUILD_TYPE}" \
            --wasm-config "${ONNXRUNTIME_WASM_BUILD_TYPE}"

RUN set -eux; \
        export USER=root; \
    bash /opt/scripts/media/onnxruntime/build/50-build-js.sh \
            --ort-version "${ONNXRUNTIME_VERSION}" \
            --build-type "${ONNXRUNTIME_NATIVE_BUILD_TYPE}" \
            --wasm-config "${ONNXRUNTIME_WASM_BUILD_TYPE}"

# pkg-config generator is copied AFTER heavy ONNX build steps to improve Docker caching
COPY linux/scripts/03-media/onnxruntime/runtime /opt/scripts/media/onnxruntime/runtime
RUN chmod +x /opt/scripts/media/onnxruntime/runtime/*.sh || true

RUN set -eux; \
    export USER=root; \
    bash /opt/scripts/media/onnxruntime/runtime/31-generate-pkgconfig-native.sh \
        --ort-version "${ONNXRUNTIME_VERSION}" \
        --build-type "${ONNXRUNTIME_NATIVE_BUILD_TYPE}" \
        --wasm-config "${ONNXRUNTIME_WASM_BUILD_TYPE}"

# ------------------------------------------------------------------------------
# GStreamer build
# ------------------------------------------------------------------------------
COPY linux/scripts/03-media/gstreamer/common /opt/scripts/media/gstreamer/common
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    set -eux; \
    export USER=root; \
    export PKG_CONFIG_PATH="/usr/local/lib/onnxruntime-cpu/runtime/lib/pkgconfig:${PKG_CONFIG_PATH}"; \
    cd /opt && \
    bash /opt/scripts/media/gstreamer/common/setup-gstreamer.sh \
        "$GSTREAMER_VERSION" \
        "$GSTREAMER_PREFIX" \
        "$BUILD_TYPE"

# ==============================================================================
# LAYER 3: Media stack; Libcamera only (changes when updating GStreamer)
# ==============================================================================
COPY linux/scripts/03-media/libcamera/ /opt/scripts/media/libcamera/

# ------------------------------------------------------------------------------
# Libcamera build
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/root/.cache/pip \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/var/cache/ccache \
    --mount=type=cache,target=/var/cache/sccache \
    set -eux; \
    cd /opt && \
    bash /opt/scripts/media/libcamera/build-libcamera.sh

# ------------------------------------------------------------------------------
# Cleanup and system configuration
# ------------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get purge -y 'gstreamer*' 'gstreamer1.0*' 'libgstreamer*' || true; \
    apt-get autoremove --purge -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    ldconfig

RUN set -eux; \
    triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH)"; \
    SYS_PKGCONF_DIR="/usr/lib/${triplet}/pkgconfig"; \
    GST_PKGCONF_DIR="/opt/gstreamer/lib/${triplet}/pkgconfig"; \
    mkdir -p "${SYS_PKGCONF_DIR}"; \
    if [ -d "${GST_PKGCONF_DIR}" ]; then \
      for pc in "${GST_PKGCONF_DIR}"/*.pc; do \
        ln -snf "$pc" "${SYS_PKGCONF_DIR}/$(basename "$pc")"; \
      done; \
    fi; \
    printf "%s\n" "/opt/gstreamer/lib/${triplet}" > /etc/ld.so.conf.d/gstreamer.conf; \
    ldconfig

RUN set -eux; \
    printf "%s\n" "/opt/libcamera/lib" > /etc/ld.so.conf.d/libcamera.conf; \
    printf "%s\n" "/opt/libcamera/lib64" >> /etc/ld.so.conf.d/libcamera.conf; \
    ldconfig

# ------------------------------------------------------------------------------
# STAGE 4: Android SDK/NDK (only for x86_64)
# ------------------------------------------------------------------------------
FROM media AS android

ARG ANDROID_SDK_VERSION=13114758
ARG ANDROID_NDK_VERSION=29.0.14206865
ARG ANDROID_COMPILE_SDK=36
ARG ANDROID_BUILD_TOOLS=35.0.0
ARG ANDROID_CMAKE_VERSION=4.1.2

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_NDK_HOME=/opt/android-sdk/ndk/${ANDROID_NDK_VERSION} \
    ANDROID_NDK_ROOT=/opt/android-sdk/ndk/${ANDROID_NDK_VERSION}

ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS}:${ANDROID_NDK_HOME}:${PATH}"

COPY linux/scripts/03-media/gstreamer/android /opt/scripts/media/gstreamer/android
RUN chmod +x /opt/scripts/media/gstreamer/android/build-android-from-source.sh \
    && chmod +x /opt/scripts/media/gstreamer/android/setup-android-sdk-ndk.sh

RUN set -eux; \
        /opt/scripts/media/gstreamer/android/setup-android-sdk-ndk.sh

ENV GSTREAMER_ROOT_ANDROID=/opt/android/gstreamer

# ------------------------------------------------------------------------------
# STAGE 5: Final image (runtime scripts copied last)
# ------------------------------------------------------------------------------
FROM android AS final

# ==============================================================================
# LAYER 4: Runtime scripts (most volatile - changes frequently)
# Copy LAST to maximize cache hits
# ==============================================================================
COPY linux/scripts/04-runtime/gstreamer-env.sh /usr/local/bin/gstreamer-env.sh
RUN chmod +x /usr/local/bin/gstreamer-env.sh

COPY linux/scripts/04-runtime/libcamera-env.sh /usr/local/bin/libcamera-env.sh
RUN chmod +x /usr/local/bin/libcamera-env.sh

COPY linux/scripts/04-runtime/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ------------------------------------------------------------------------------
# OCI-Labels
# ------------------------------------------------------------------------------
ARG BUILD_DATE="" VCS_REF="" BUILD_BY="CI"
LABEL org.opencontainers.image.title="kataglyphis_beschleuniger" \
      org.opencontainers.image.description="My beschleuniger image for 2D AI" \
      org.opencontainers.image.version="${BUILD_TYPE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.authors="Jonas Heinle <jonasheinle@googlemail.com>" \
      org.opencontainers.image.url="https://github.com/Kataglyphis/Kataglyphis-DockerHub" \
      org.opencontainers.image.source="https://github.com/Kataglyphis/Kataglyphis-DockerHub" \
      org.opencontainers.image.licenses="MIT"

# ------------------------------------------------------------------------------
# Workspace & EntryPoint
# ------------------------------------------------------------------------------
WORKDIR ${WORKDIR}
VOLUME ["${WORKDIR}"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["/bin/bash"]
