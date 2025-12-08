# syntax=docker/dockerfile:1.19
FROM ubuntu:24.04 AS base

# ------------------------------------------------------------------------------
# Build-Argumente
# ------------------------------------------------------------------------------
ARG BUILD_TYPE=Release
ARG VULKAN_VERSION=1.4.328.1
ARG LLVM_WANTED=21
ARG CLANG_WANTED=21
ARG GCC_WANTED=14
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
    RUSTC_WRAPPER=/usr/bin/sccache \
    SCCACHE_DIR=/var/cache/sccache

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
        clang libc++-18-dev libc++abi-18-dev clang-format clang-tidy lld llvm llvm-dev libclang-dev libclang-rt-dev \
        pkg-config lsb-release software-properties-common \
        meson python3 python3-venv python3-dev python3-pip \
        $([ "$ARCH" != "riscv64" ] && echo "lldb"); \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Install Graphics/Docs Deps --no-install-recommends
# ------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update -y && \
    apt-get install -y  \ 
      doxygen iwyu graphviz gcovr libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
      libglu1-mesa-dev freeglut3-dev mesa-common-dev mesa-utils wayland-protocols \
      libwayland-dev libxkbcommon-dev libglx-mesa0 libosmesa6-dev

# ------------------------------------------------------------------------------
# Adding for perforance analysis tools (perf)
# ------------------------------------------------------------------------------        
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update -y && \
    apt-get install -y linux-tools-common linux-tools-generic

# ------------------------------------------------------------------------------
# Vulkan ICD/Layer-JSONs
# ------------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /etc/vulkan/icd.d; \
    cat > /etc/vulkan/icd.d/nvidia_icd.json <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version" : "${VULKAN_VERSION}"
    }
}
EOF
RUN set -eux; \
    mkdir -p /usr/share/glvnd/egl_vendor.d; \
    cat > /usr/share/glvnd/egl_vendor.d/10_nvidia.json <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
EOF
RUN set -eux; \
    mkdir -p /etc/vulkan/implicit_layer.d/; \
    cat > /etc/vulkan/implicit_layer.d/nvidia_layers.json <<EOF
{
    "file_format_version" : "1.0.0",
    "layer": {
        "name": "VK_LAYER_NV_optimus",
        "type": "INSTANCE",
        "library_path": "libGLX_nvidia.so.0",
        "api_version" : "${VULKAN_VERSION}",
        "implementation_version" : "1",
        "description" : "NVIDIA Optimus layer",
        "functions": {
            "vkGetInstanceProcAddr": "vk_optimusGetInstanceProcAddr",
            "vkGetDeviceProcAddr": "vk_optimusGetDeviceProcAddr"
        },
        "enable_environment": {
            "__NV_PRIME_RENDER_OFFLOAD": "1"
        },
        "disable_environment": {
            "DISABLE_LAYER_NV_OPTIMUS_1": ""
        }
    }
}
EOF

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
# Abhängigkeiten & Toolchains (Skripte per Bind-Mount aus dem Build-Kontext)
# ------------------------------------------------------------------------------

ARG LLVM_WANTED CLANG_WANTED GCC_WANTED VULKAN_VERSION TARGETARCH
RUN --mount=type=bind,src=linux/scripts,dst=/opt/setup-scripts,ro \
    --mount=type=bind,src=linux/scripts/setup-dependencies.sh,dst=/opt/setup-scripts/setup-dependencies.sh,ro \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    set -eux; \
    bash /opt/setup-scripts/setup-dependencies.sh base; \
    bash /opt/setup-scripts/setup-dependencies.sh cmake; \
    bash /opt/setup-scripts/setup-dependencies.sh extras; \
    bash /opt/setup-scripts/setup-dependencies.sh --gcc "${GCC_WANTED}" gcc; \
    if [ "${TARGETARCH:-$(uname -m)}" != "riscv64" ]; then \
      bash /opt/setup-scripts/setup-dependencies.sh --llvm "${LLVM_WANTED}" --clang "${CLANG_WANTED}" llvm; \
    fi; \
    bash /opt/setup-scripts/setup-dependencies.sh --vulkan-version "${VULKAN_VERSION}" vulkan; \
    bash /opt/setup-scripts/setup-dependencies.sh verify

# ------------------------------------------------------------------------------
# GStreamer-Build: ENV + Setup
# ------------------------------------------------------------------------------
ARG GSTREAMER_VERSION=1.26.7
ENV GSTREAMER_VERSION=${GSTREAMER_VERSION} \
    GSTREAMER_PREFIX=/opt/gstreamer \
    GST_PLUGIN_PATH="" \
    GI_TYPELIB_PATH=""

# Multiarch-Libdir-Symlink (stabiler Pfad)
RUN set -eux; \
    triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH)"; \
    mkdir -p "/opt/gstreamer/lib/${triplet}"; \
    ln -snf "/opt/gstreamer/lib/${triplet}" "/opt/gstreamer/lib/multiarch" || true

# GStreamer-ENV für Build-Schritt
ENV PKG_CONFIG_PATH="" \
    LD_LIBRARY_PATH=""
ENV PATH="${GSTREAMER_PREFIX}/bin:${PATH}"
ENV PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/multiarch/pkgconfig:${PKG_CONFIG_PATH}"
ENV LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib/multiarch:${LD_LIBRARY_PATH}"
ENV GST_PLUGIN_PATH="${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0:${GST_PLUGIN_PATH}"
ENV GI_TYPELIB_PATH="${GSTREAMER_PREFIX}/lib/multiarch/girepository-1.0:${GI_TYPELIB_PATH}"

# GStreamer aus Skript (Bind-Mount), mit Caches
RUN --mount=type=bind,src=linux,dst=/opt/linux,ro \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/root/.cache/pip \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/var/cache/ccache \
    --mount=type=cache,target=/var/cache/sccache \
    set -eux; \
    export USER=root; \
    cd /opt && \
    bash /opt/linux/scripts/setup-gstreamer.sh "$GSTREAMER_VERSION" "$GSTREAMER_PREFIX" "$BUILD_TYPE"

# GStreamer aus Skript (Bind-Mount), mit Caches
RUN --mount=type=bind,src=linux,dst=/opt/linux,ro \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/root/.cache/pip \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/var/cache/ccache \
    --mount=type=cache,target=/var/cache/sccache \
    set -eux; \
    cd /opt && \
    bash /opt/linux/scripts/build-libcamera.sh

# GStreamer-Pakete, die evtl. via apt reinkamen, entfernen
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get purge -y 'gstreamer*' 'gstreamer1.0*' 'libgstreamer*' || true; \
    apt-get autoremove --purge -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    ldconfig

# GStreamer systemweit für pkg-config sichtbar machen
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

# Zusätzliche GUI-/Utility-/Python packaging-Deps (optional)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    arch="$(dpkg --print-architecture)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential clang ninja-build pkg-config \
      libgtk-3-dev libglib2.0-dev libgdk-pixbuf2.0-dev libatk1.0-dev \
      libpango1.0-dev libx11-dev libx11-xcb-dev libxkbcommon-dev \
      libasound2-dev libpulse-dev libdbus-1-dev \
      file dpkg-dev fakeroot binutils $( [ "$arch" != "riscv64" ] && echo valgrind || true ); \
    echo "Detected arch: $arch"; \
    echo "PATH (this step): $PATH"; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------------------------
# Android SDK & NDK (only for x86_64)
# ------------------------------------------------------------------------------
ARG ANDROID_SDK_VERSION=13114758
# https://github.com/android/ndk/releases/tag/r29
ARG ANDROID_NDK_VERSION=29.0.14206865
ARG ANDROID_COMPILE_SDK=36
ARG ANDROID_BUILD_TOOLS=35.0.0
ARG ANDROID_CMAKE_VERSION=4.2.0

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_NDK_HOME=/opt/android-sdk/ndk/${ANDROID_NDK_VERSION} \
    ANDROID_NDK_ROOT=/opt/android-sdk/ndk/${ANDROID_NDK_VERSION}

# Add Android tools to PATH
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS}:${ANDROID_NDK_HOME}:${PATH}"

RUN set -eux; \
    if [ "${TARGETARCH:-$(uname -m)}" = "amd64" ] || [ "$(uname -m)" = "x86_64" ]; then \
      dpkg --add-architecture i386; \
      # Install Java (required for Android SDK)
      apt-get update; \
      # https://developer.android.com/studio/install?hl=de#64bit-libs
      apt-get install -y --no-install-recommends \ 
        libc6:i386 libncurses6:i386 libstdc++6:i386 \
        lib32z1 libbz2-1.0:i386; \
      apt-get install -y --no-install-recommends \
      # Java 25 is actually not yet officially supported by any stable Gradle version
      openjdk-21-jdk \
      unzip; \
      \
      # Download and install Android command line tools
      mkdir -p "${ANDROID_HOME}/cmdline-tools"; \
      cd /tmp; \
      wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip"; \
      unzip -q commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip; \
      mv cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest"; \
      rm commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip; \
      \
      # Accept licenses
      yes | ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager --licenses || true; \
      \
      # Install Android SDK components
      ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager \
        "platform-tools" \
        "platforms;android-${ANDROID_COMPILE_SDK}" \
        "build-tools;${ANDROID_BUILD_TOOLS}" \
        "ndk;${ANDROID_NDK_VERSION}" \
        "extras;android;m2repository" \
        "extras;google;m2repository"; \
      \
      # Clean up
      apt-get clean; \
      rm -rf /var/lib/apt/lists/* /tmp/*; \
    else \
      echo "Skipping Android SDK/NDK installation on non-x86_64 architecture"; \
    fi

# Create NDK standalone toolchains symlinks for easier access
RUN set -eux; \
    if [ "${TARGETARCH:-$(uname -m)}" = "amd64" ] || [ "$(uname -m)" = "x86_64" ]; then \
      if [ -d "${ANDROID_NDK_HOME}" ]; then \
        # Create convenient symlinks
        ln -sf "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64" "${ANDROID_NDK_HOME}/toolchain"; \
      fi; \
    fi

# https://gstreamer.freedesktop.org/documentation/installing/for-android-development.html?gi-language=c
ENV GSTREAMER_ROOT_ANDROID=${GSTREAMER_PREFIX}

# ------------------------------------------------------------------------------
# Laufzeit-ENV für GStreamer (ENTRYPOINT)
# ------------------------------------------------------------------------------
COPY linux/scripts/gstreamer-env.sh /usr/local/bin/gstreamer-env.sh
RUN chmod +x /usr/local/bin/gstreamer-env.sh
COPY linux/scripts/libcamera-env.sh /usr/local/bin/libcamera-env.sh
RUN chmod +x /usr/local/bin/libcamera-env.sh
COPY linux/scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
# ------------------------------------------------------------------------------
# OCI-Labels (dynamisch) – am Ende, damit Cache stabil bleibt
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
