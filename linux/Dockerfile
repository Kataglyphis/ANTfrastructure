# syntax=docker/dockerfile:1.24.0

ARG BASE_IMAGE=local/kataglyphis:torch
FROM ${BASE_IMAGE}

ARG BUILD_TYPE=Release
ARG ENABLE_NVIDIA=false
ARG ENABLE_AMD=false

# ==============================================================================
# Runtime scripts (most volatile - changes frequently)
# Copy LAST to maximize cache hits
# ==============================================================================
COPY --chmod=755 linux/scripts/02-toolchain/vulkan.sh /usr/local/bin/vulkan.sh
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
ARG BUILD_DATE="" VCS_REF=""
LABEL org.opencontainers.image.title="kataglyphis_beschleuniger" \
      org.opencontainers.image.description="My beschleuniger image for 2D AI" \
      org.opencontainers.image.version="${BUILD_TYPE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.authors="Jonas Heinle <jonasheinle@googlemail.com>" \
      org.opencontainers.image.url="https://github.com/Kataglyphis/Kataglyphis-DockerHub" \
      org.opencontainers.image.source="https://github.com/Kataglyphis/Kataglyphis-DockerHub" \
      org.opencontainers.image.licenses="MIT"
