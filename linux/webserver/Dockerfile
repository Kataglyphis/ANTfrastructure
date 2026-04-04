FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Enable apt caching (Ubuntu docker images clean this up by default)
RUN rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

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
 && chown -R nginx:nginx /var/www/html /var/cache/nginx

# Send logs to stdout/stderr for Docker friendliness
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

# Put your full config into the real global path
COPY ./webserver/nginx.conf /etc/nginx/nginx.conf

# Copy entrypoint script to generate self-signed cert if none exists
COPY --chmod=755 ./webserver/entrypoint.sh /docker-entrypoint.sh

# Copy website files
COPY --chown=nginx:nginx --chmod=755 ./webserver/dist/ /var/www/html/

EXPOSE 80 443

ENTRYPOINT ["/docker-entrypoint.sh"]
