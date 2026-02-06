# syntax=docker/dockerfile:1.19

ARG BASE_IMAGE=local/kataglyphis:android
FROM ${BASE_IMAGE}

ARG BUILD_TYPE=Release

SHELL ["bash", "-lc"]

# ==============================================================================
# Runtime scripts (most volatile - changes frequently)
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
