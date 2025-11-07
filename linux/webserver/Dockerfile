# Dockerfile.ubuntu.static
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install nginx (minimal)
RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# create nginx user/group and ensure directories exist
RUN groupadd -r nginx || true \
 && useradd -r -g nginx -s /sbin/nologin -d /var/cache/nginx nginx || true \
 && mkdir -p /var/www/html /var/cache/nginx /run \
 && chown -R nginx:nginx /var/www/html /var/cache/nginx

# Put your full config into the real global path
COPY ./linux/webserver/nginx.conf /etc/nginx/nginx.conf

# Copy static site
COPY ./linux/webserver/dist /var/www/html

# Send logs to stdout/stderr for Docker friendliness
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
