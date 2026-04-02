FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Install nginx and openssl (minimal)
RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/*

# Create nginx user/group and ensure directories exist
RUN groupadd -r nginx || true \
 && useradd -r -g nginx -s /sbin/nologin -d /var/cache/nginx nginx || true \
 && mkdir -p /var/www/html /var/cache/nginx /run /etc/nginx/ssl \
 && chown -R nginx:nginx /var/www/html /var/cache/nginx

# Put your full config into the real global path
COPY ./webserver/nginx.conf /etc/nginx/nginx.conf

# Copy website files
COPY --chown=nginx:nginx --chmod=755 ./webserver/dist/ /var/www/html/

# Copy entrypoint script to generate self-signed cert if none exists
COPY --chmod=755 ./webserver/entrypoint.sh /docker-entrypoint.sh

# Send logs to stdout/stderr for Docker friendliness
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

EXPOSE 80 443

ENTRYPOINT ["/docker-entrypoint.sh"]
