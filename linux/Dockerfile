# syntax=docker/dockerfile:1.4
FROM ubuntu:24.04 AS base

# --------- Build args & env ---------
ARG BUILD_TYPE=Debug
ARG VULKAN_VERSION=1.4.328.1
ARG TARGETARCH

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all

ENV DEBIAN_FRONTEND=noninteractive \
    APT_LISTCHANGES_FRONTEND=none \
    BUILD_TYPE=${BUILD_TYPE} \
    VULKAN_VERSION=${VULKAN_VERSION} \
    WORKDIR=/workspace

RUN apt-get update && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

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

# --------- Common prerequisites ---------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      pkg-config \
      gnupg \
      lsb-release \
      wget \
      xz-utils \
      software-properties-common \
      sudo \
      git \
      libssl-dev \
      build-essential ninja-build make \
      clang            \
      clang-format     \
      clang-tidy       \
      lld              \
      lldb             \
      llvm             \
      llvm-dev         \
      libclang-dev \
      libclang-rt-dev && \
    rm -rf /var/lib/apt/lists/*

# --------- Install Rust via rustup (official method) ---------
# Download and install rustup (the Rust installer) non‑interactively
# The `-s -- -y` flags tell rustup.sh to skip prompts and accept defaults
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y

# Make sure the Cargo bin directory is on PATH
ENV PATH="/root/.cargo/bin:${PATH}"

# (Optional) Verify installation
RUN rustc --version && cargo --version

# --------- Install Kitware CMake ---------
RUN mkdir -p /usr/share/keyrings && \
    wget -qO- https://apt.kitware.com/keys/kitware-archive-latest.asc \
      | gpg --dearmor \
      | tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null && \
    echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu noble main" \
      | tee /etc/apt/sources.list.d/kitware.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends cmake && \
    rm -rf /var/lib/apt/lists/*

# --------- Add LunarG key & repo for Vulkan SDK ---------
RUN wget -qO- https://packages.lunarg.com/lunarg-signing-key-pub.asc | apt-key add - && \
    wget -qO /etc/apt/sources.list.d/lunarg-vulkan-${VULKAN_VERSION}-noble.list https://packages.lunarg.com/vulkan/${VULKAN_VERSION}/lunarg-vulkan-${VULKAN_VERSION}-noble.list

# --------- Install Vulkan SDK per-architecture ---------
# copy script into image
COPY ./scripts/setup-dependencies.sh /tmp/setup-dependencies.sh

# make it executable, run it in one RUN (so apt update/install cache is kept together)
RUN chmod +x /tmp/setup-dependencies.sh \
 && /tmp/setup-dependencies.sh \
 && rm -f /tmp/setup-dependencies.sh

# --------- Install compiler, test & graphics deps ---------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ninja-build sccache ccache \
      python3 python3-pip \
      doxygen graphviz gcovr libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
      libglu1-mesa-dev freeglut3-dev mesa-common-dev mesa-utils wayland-protocols \
      libwayland-dev libxkbcommon-dev libglx-mesa0 libosmesa6-dev && \
    rm -rf /var/lib/apt/lists/*

# --------- Workspace ---------
WORKDIR ${WORKDIR}
VOLUME ["${WORKDIR}"]

ENTRYPOINT ["/bin/bash"]
