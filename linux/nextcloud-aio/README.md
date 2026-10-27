# Nextcloud AIO — nerdctl compose

Manual-install variant without the mastercontainer (no docker socket needed). srv-1 does not
run it: see [srv-1](#srv-1).

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

## srv-1

srv-1 runs AIO's standard mastercontainer under Docker, with no extra environment:

```bash
docker run -d --init --sig-proxy=false --name nextcloud-aio-mastercontainer --restart always \
  -p 80:80 -p 8080:8080 -p 8443:8443 \
  -v nextcloud_aio_mastercontainer:/mnt/docker-aio-config \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  ghcr.io/nextcloud-releases/all-in-one:latest
```

AIO's daily Borg backup goes to `/root/nextcloud_aio/borg`; the weekly copy to the NAS and the
restore are in [Backups to the NAS](../ansible/README.md#backups-to-the-nas).

`nextcloud-ai-worker.service` (here) runs Nextcloud's AI task worker, so Assistant tasks do not
wait for the next cron run: copy it to `/etc/systemd/system/`, then
`systemctl enable --now nextcloud-ai-worker.service`. The Context Chat backend is an ExApp
installed from the app store through HaRP; its index rebuilds itself and is not backed up.
