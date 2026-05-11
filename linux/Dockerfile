# syntax=docker/dockerfile:1.19

ARG BASE_IMAGE=local/kataglyphis:android
FROM ${BASE_IMAGE}

ARG BUILD_TYPE=Release
ARG ENABLE_NVIDIA=false
ARG ENABLE_AMD=false
ARG BUILD_MODE=native
ARG TARGET_ARCH
ARG TARGETARCH
ARG USE_FAST_UBUNTU_MIRROR=false
ARG FAST_UBUNTU_MIRROR_URL=https://archive.ubuntu.com/ubuntu/

SHELL ["bash", "-lc"]

RUN --mount=type=bind,source=linux/scripts/01-core/use-fast-ubuntu-mirror.sh,target=/tmp/use-fast-ubuntu-mirror.sh,ro \
    USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR}" \
    FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL}" \
    bash /tmp/use-fast-ubuntu-mirror.sh && \
    if [ "${BUILD_MODE}" = "cross" ]; then exit 0; fi && \
    sudo apt update && sudo apt install -y libtbb-dev

# ==============================================================================
# Runtime scripts (most volatile - changes frequently)
# Copy LAST to maximize cache hits
# ==============================================================================
COPY --chmod=755 linux/scripts/04-runtime/*.sh /usr/local/bin/

# ------------------------------------------------------------------------------
# Workspace & EntryPoint
# ------------------------------------------------------------------------------
ARG WORKDIR=/workspace
WORKDIR ${WORKDIR}
VOLUME ["${WORKDIR}"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["/bin/bash"]

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
