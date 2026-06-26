# Nextcloud AIO — nerdctl compose

Manual-install variant without the mastercontainer (no docker socket needed).

## Quick Start

```bash
cp .env.example .env
# edit .env — at minimum set NC_DOMAIN and generate passwords

nerdctl compose -f linux/nextcloud-aio/compose.yaml --env-file linux/nextcloud-aio/.env up -d
```

With optional services:

```bash
nerdctl compose -f linux/nextcloud-aio/compose.yaml --env-file linux/nextcloud-aio/.env \
  --profile collabora --profile talk --profile talk-recording \
  --profile clamav --profile imaginary --profile fulltextsearch --profile whiteboard up -d
```

## Updating

```bash
# 1. Stop containers
nerdctl compose -f linux/nextcloud-aio/compose.yaml down

# 2. Compare with upstream reference and update compose.yaml
diff linux/nextcloud-aio/compose.yaml linux/nextcloud-aio/latest.yml

# 3. Pull new images
nerdctl compose -f linux/nextcloud-aio/compose.yaml pull

# 4. Start again
nerdctl compose -f linux/nextcloud-aio/compose.yaml --env-file linux/nextcloud-aio/.env up -d
```

## Notes

- Access Nextcloud at `http://<NC_DOMAIN>:8080`
- Admin user: `admin` (password set in `.env`)
- The `custom-bin/caddy` wrapper strips TLS from the Caddyfile (local HTTP setup)
- The `custom-bin/dig` wrapper resolves `nextcloud-aio-apache` from `/etc/hosts`
