# syntax=docker/dockerfile:1.4
FROM ubuntu:24.04 AS base

# ------------------------------------------------------------------------------
# Build args & env
# ------------------------------------------------------------------------------
ARG BUILD_TYPE=Release
ARG VULKAN_VERSION=1.4.328.1
ARG GSTREAMER_VERSION=1.26.7

# Toolchain versions (override at build time)
ARG LLVM_WANTED=21
ARG CLANG_WANTED=21
ARG GCC_WANTED=14

# Docker/BuildKit-provided arch arg; export to ENV for scripts
ARG TARGETARCH

# Use bash for RUN (arrays, pipefail-friendly)
SHELL ["bash", "-lc"]

# allow nvidia GPUs to work
ENV NVIDIA_DRIVER_CAPABILITIES=all \
    NVIDIA_VISIBLE_DEVICES=all

ENV DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true \
    APT_LISTCHANGES_FRONTEND=none \
    BUILD_TYPE=${BUILD_TYPE} \
    VULKAN_VERSION=${VULKAN_VERSION} \
    GSTREAMER_VERSION=${GSTREAMER_VERSION} \
    WORKDIR=/workspace \ 
    PKG_CONFIG_PATH="" \
    LD_LIBRARY_PATH="" \
    GST_PLUGIN_PATH="" \ 
    GI_TYPELIB_PATH="" \
    GSTREAMER_PREFIX=/opt/gstreamer \
    TARGETARCH=${TARGETARCH} \
    LLVM_WANTED=${LLVM_WANTED} \
    CLANG_WANTED=${CLANG_WANTED} \
    GCC_WANTED=${GCC_WANTED}

# ------------------------------------------------------------------------------
# Update package registry and upgrade existing packages
# ------------------------------------------------------------------------------

RUN apt-get update && apt-get upgrade -y

# ------------------------------------------------------------------------------
# Common prerequisites
# ------------------------------------------------------------------------------

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        nano tmux vim \
        sudo curl ca-certificates gnupg wget xz-utils libssl-dev git \
        build-essential ninja-build make sccache ccache \
        clang clang-format clang-tidy lld lldb llvm llvm-dev libclang-dev libclang-rt-dev \
        pkg-config lsb-release software-properties-common \
        meson python3 python3-venv python3-dev python3-pip

# ------------------------------------------------------------------------------
# Install Graphics/Docs Deps --no-install-recommends
# ------------------------------------------------------------------------------
RUN apt-get install -y  \ 
      doxygen iwyu graphviz gcovr libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
      libglu1-mesa-dev freeglut3-dev mesa-common-dev mesa-utils wayland-protocols \
      libwayland-dev libxkbcommon-dev libglx-mesa0 libosmesa6-dev

# ------------------------------------------------------------------------------
# Vulkan specific configs (Vulkan ICD configs)
# ------------------------------------------------------------------------------

RUN mkdir -p /etc/vulkan/icd.d && \
    cat > /etc/vulkan/icd.d/nvidia_icd.json <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version" : "${VULKAN_VERSION}"
    }
}
EOF
RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    cat > /usr/share/glvnd/egl_vendor.d/10_nvidia.json <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
EOF
RUN mkdir -p /etc/vulkan/implicit_layer.d/ && \
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
# Install Rust via rustup (official method) and setup uv package manager
# ------------------------------------------------------------------------------
ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    # RUSTC_WRAPPER=/usr/bin/sccache \
    PATH=/usr/local/cargo/bin:/root/.local/bin:$PATH

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    curl -sSf https://sh.rustup.rs | sh -s -- -y && \
    rustc --version && \
    cargo --version && \
    cargo install --locked cargo-c

# uv (persist PATH via ENV above)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# ------------------------------------------------------------------------------
# Install Vulkan SDK and Deps per-architecture
# ------------------------------------------------------------------------------
# Copy main and helpers into the paths setup-dependencies.sh expects
COPY --chmod=0755 linux/scripts/setup-dependencies.sh /opt/setup-scripts/setup-dependencies.sh
COPY --chmod=0755 linux/scripts /opt/setup-scripts/scripts/

# Run individual steps with CLI args; keep apt cache mounts for speed.
# Order: install base/cmake/extras, then set toolchains (gcc/llvm), then Vulkan.
# --mount=type=cache,target=/var/cache/apt \
#     --mount=type=cache,target=/var/lib/apt \
RUN /opt/setup-scripts/setup-dependencies.sh base && \
    /opt/setup-scripts/setup-dependencies.sh cmake && \
    /opt/setup-scripts/setup-dependencies.sh extras && \
    /opt/setup-scripts/setup-dependencies.sh --gcc "${GCC_WANTED}" gcc && \
    /opt/setup-scripts/setup-dependencies.sh --llvm "${LLVM_WANTED}" --clang "${CLANG_WANTED}" llvm && \
    /opt/setup-scripts/setup-dependencies.sh --vulkan-version "${VULKAN_VERSION}" vulkan && \
    /opt/setup-scripts/setup-dependencies.sh verify

# ------------------------------------------------------------------------------
# Build and install gstreamer from source
# ------------------------------------------------------------------------------
RUN set -eux; \
    triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH)"; \
    ln -s "/opt/gstreamer/lib/${triplet}" "/opt/gstreamer/lib/multiarch" || true

# GStreamer-ENV vars; without nothing works ....
# I set them before running the setup script so that the script can use them too
# So gst-plugins-rs can be built correctly
ENV PATH="${GSTREAMER_PREFIX}/bin:${PATH}"
ENV PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/multiarch/pkgconfig:${PKG_CONFIG_PATH}"
ENV LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib/multiarch:${LD_LIBRARY_PATH}"
ENV GST_PLUGIN_PATH="${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0:${GST_PLUGIN_PATH}"
ENV GI_TYPELIB_PATH="${GSTREAMER_PREFIX}/lib/multiarch/girepository-1.0:${GI_TYPELIB_PATH}"

COPY --chmod=0755 linux/scripts/setup-gstreamer.sh /usr/local/bin/setup-gstreamer.sh
RUN /usr/local/bin/setup-gstreamer.sh "$GSTREAMER_VERSION" "$GSTREAMER_PREFIX" "$BUILD_TYPE"
# Multiarch-Libdir ermitteln und auf einen stabilen Symlink zeigen lassen

# after building & installing GStreamer into /opt/gstreamer
# This writes an ld.so conf file and runs ldconfig so the runtime linker will 
# find your GStreamer libs without requiring LD_LIBRARY_PATH at runtime.
RUN printf "%s\n" "/opt/gstreamer/lib/x86_64-linux-gnu" "/opt/gstreamer/lib/multiarch" \
    > /etc/ld.so.conf.d/gstreamer.conf && ldconfig

# --------- Workspace ---------
WORKDIR ${WORKDIR}
VOLUME ["${WORKDIR}"]

ENTRYPOINT ["/bin/bash"]
