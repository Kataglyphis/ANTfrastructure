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
COPY ./webserver/dist/ /var/www/html/
RUN chown -R nginx:nginx /var/www/html && chmod -R 755 /var/www/html

# Copy SSL certificates (these will be generated separately)
# Create a placeholder script to generate self-signed cert if none exists
RUN echo '#!/bin/bash\n\
if [ ! -f /etc/nginx/ssl/cert.pem ] || [ ! -f /etc/nginx/ssl/key.pem ]; then\n\
  echo "Generating self-signed SSL certificate..."\n\
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\\n\
    -keyout /etc/nginx/ssl/key.pem \\\n\
    -out /etc/nginx/ssl/cert.pem \\\n\
    -subj "/C=DE/ST=Baden-Wurttemberg/L=Stuttgart/O=Development/CN=localhost"\n\
  chmod 600 /etc/nginx/ssl/key.pem\n\
  chmod 644 /etc/nginx/ssl/cert.pem\n\
  echo "SSL certificate generated successfully"\n\
fi\n\
exec nginx -g "daemon off;"' > /docker-entrypoint.sh \
 && chmod +x /docker-entrypoint.sh

# Send logs to stdout/stderr for Docker friendliness
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

EXPOSE 80 443

ENTRYPOINT ["/docker-entrypoint.sh"]
