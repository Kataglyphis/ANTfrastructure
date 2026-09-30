# syntax=docker/dockerfile:1.27.0
# Builds standalone, so these defaults are load-bearing; sync_versions.py keeps them equal to versions.env.
ARG UBUNTU_VERSION=26.04
ARG UBUNTU_DIGEST=sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78
FROM ubuntu:${UBUNTU_VERSION}@${UBUNTU_DIGEST} AS base

# No version ARG: scripts/download-ollama.sh fetches the tarball outside the build and owns the version.

# curl is required by the HEALTHCHECK below and by entrypoint.sh's readiness poll.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    zstd \
    && rm -rf /var/lib/apt/lists/*

COPY ollama-binary.tar.zst /tmp/ollama.tar.zst

RUN tar --zstd -xf /tmp/ollama.tar.zst -C /usr/local && \
    rm /tmp/ollama.tar.zst

ENV OLLAMA_HOST=0.0.0.0:8080 \
    OLLAMA_KEEP_ALIVE=24h \
    OLLAMA_NUM_PARALLEL=1 \
    OLLAMA_MAX_LOADED_MODELS=2

EXPOSE 8080
VOLUME /root/.ollama

COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -fs http://localhost:8080/api/tags || exit 1

ENTRYPOINT ["/entrypoint.sh"]
