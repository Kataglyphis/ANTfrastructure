# syntax=docker/dockerfile:1.24.0
# Digest-pinned like linux/Dockerfile.base: this image builds standalone (no
# orchestrator forwarding), so the ARG defaults are load-bearing and are kept
# synced to versions.env by sync_versions.py.
ARG UBUNTU_VERSION=26.04
ARG UBUNTU_DIGEST=sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03
FROM ubuntu:${UBUNTU_VERSION}@${UBUNTU_DIGEST} AS base

# The Ollama tarball is downloaded OUTSIDE the build by scripts/download-ollama.sh
# (which owns the version default) and COPY'd in below — no version ARG here.

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
