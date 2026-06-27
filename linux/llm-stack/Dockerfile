# syntax=docker/dockerfile:1.24.0
ARG UBUNTU_VERSION=26.04
FROM ubuntu:${UBUNTU_VERSION} AS base

ARG TARGETARCH
ARG OLLAMA_VERSION=0.30.10

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
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
