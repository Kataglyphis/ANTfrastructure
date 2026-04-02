#!/bin/bash
set -e

if [ ! -f /etc/nginx/ssl/cert.pem ] || [ ! -f /etc/nginx/ssl/key.pem ]; then
  echo "Generating self-signed SSL certificate..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/key.pem \
    -out /etc/nginx/ssl/cert.pem \
    -subj "/C=DE/ST=Baden-Wurttemberg/L=Stuttgart/O=Development/CN=localhost"
  chmod 600 /etc/nginx/ssl/key.pem
  chmod 644 /etc/nginx/ssl/cert.pem
  echo "SSL certificate generated successfully"
fi

exec nginx -g "daemon off;"
