# syntax=docker/dockerfile:1.24.0
# Digest-pinned like linux/Dockerfile.base: this image builds standalone (via
# linux/docker-compose.yml, no orchestrator forwarding), so the ARG defaults are
# load-bearing and are kept synced to versions.env by sync_versions.py.
ARG UBUNTU_VERSION=26.04
ARG UBUNTU_DIGEST=sha256:b7f48194d4d8b763a478a621cdc81c27be222ba2206ca3ca6bc42b49685f3d9e
FROM ubuntu:${UBUNTU_VERSION}@${UBUNTU_DIGEST}
ENV DEBIAN_FRONTEND=noninteractive

# Install nginx and openssl (minimal) utilizing BuildKit cache mounts
# We use an architecture-specific ID to prevent cache corruption between amd64/arm64/riscv64
ARG TARGETARCH
RUN --mount=type=cache,id=apt-cache-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib-${TARGETARCH},target=/var/lib/apt,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends nginx ca-certificates openssl

# Create nginx user/group and ensure directories exist
RUN groupadd -r nginx || true \
 && useradd -r -g nginx -s /sbin/nologin -d /var/cache/nginx nginx || true \
 && mkdir -p /var/www/html /var/cache/nginx /run /etc/nginx/ssl \
 && chown -R nginx:nginx /var/www/html /var/cache/nginx \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

# Put your full config into the real global path
COPY ./webserver/nginx.conf /etc/nginx/nginx.conf

# Copy entrypoint script to generate self-signed cert if none exists
COPY --chmod=755 ./webserver/entrypoint.sh /docker-entrypoint.sh

# Copy website files and license assets
COPY --chown=nginx:nginx --chmod=755 ./webserver/dist/ /var/www/html/
COPY --chown=nginx:nginx --chmod=755 ./webserver/license-assets/ /var/www/html/assets/

EXPOSE 80 443

ENTRYPOINT ["/docker-entrypoint.sh"]
