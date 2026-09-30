# syntax=docker/dockerfile:1.27.0
# Built standalone with no orchestrator forwarding, so these defaults are load-bearing (sync_versions.py keeps them).
ARG UBUNTU_VERSION=26.04
ARG UBUNTU_DIGEST=sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78
FROM ubuntu:${UBUNTU_VERSION}@${UBUNTU_DIGEST}
ENV DEBIAN_FRONTEND=noninteractive

# Per-arch cache ids, or the arches corrupt each other's apt cache.
ARG TARGETARCH
RUN --mount=type=cache,id=apt-cache-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib-${TARGETARCH},target=/var/lib/apt,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends nginx ca-certificates openssl curl

# Create nginx user/group and ensure directories exist
RUN groupadd -r nginx || true \
 && useradd -r -g nginx -s /sbin/nologin -d /var/cache/nginx nginx || true \
 && mkdir -p /var/www/html /var/cache/nginx /run /etc/nginx/ssl \
 && chown -R nginx:nginx /var/www/html /var/cache/nginx \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

# Put your full config into the real global path
COPY ./webserver/nginx.conf /etc/nginx/nginx.conf
# Re-included by every add_header location, since nginx add_header inheritance is all-or-nothing.
COPY ./webserver/security-headers.conf /etc/nginx/security-headers.conf

# Copy entrypoint script to generate self-signed cert if none exists
COPY --chmod=755 ./webserver/entrypoint.sh /docker-entrypoint.sh

# The site is a named build context; see docs/runtime-services.md § Webserver (Linux). DL3022 cannot model contexts.
# hadolint ignore=DL3022
COPY --from=site --chown=nginx:nginx --chmod=755 / /var/www/html/
# assets/assets/ is not a typo: Flutter web serves declared assets under its own assets/ root.
COPY --chown=nginx:nginx --chmod=755 ./webserver/license-assets/ /var/www/html/assets/assets/

EXPOSE 80 443

# -k: the entrypoint's certificate is self-signed.
HEALTHCHECK --interval=30s --timeout=10s \
    CMD curl -fsk https://localhost:443/health || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
