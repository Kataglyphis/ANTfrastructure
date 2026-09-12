# Home Assistant — nerdctl compose

Home Assistant Container (no supervisor) plus glances. The hand-written config
is versioned here; the live database, backups and secrets are not.

## Quick Start

```bash
nerdctl compose -f linux/homeassistant/compose.yaml up -d
```

Home Assistant uses host networking — UI at `http://<host>:8123`, glances at
port 61206.

## Tracked vs Live State

Tracked: `compose.yaml`, `configuration.yaml`, `automations.yaml`,
`scripts.yaml`, `scenes.yaml`, `blueprints/`, and `secrets.yaml.example`.

Gitignored (see `.gitignore`): `secrets.yaml`, `.storage/` (auth tokens),
`.ssh/`, `.cloud/`, the recorder DB, logs, `backups/`, and `core`.

## Secrets

```bash
cp config/secrets.yaml.example config/secrets.yaml
# fill in the WoL MAC, the F@H SSH commands and the alert address
```

`!secret` only works as a whole YAML node, so each `shell_command` is stored
whole in `secrets.yaml` — it cannot be assembled from parts in the tracked YAML.

## Updating

```bash
nerdctl compose -f linux/homeassistant/compose.yaml pull
nerdctl compose -f linux/homeassistant/compose.yaml up -d
```

## Notes

- `privileged` and the `/run/dbus` mount are required for Bluetooth/USB
  integrations.
- The 455 MB `core` dump from 2025-03-19 was deleted during the move; the
  `.gitignore` `core` pattern keeps any future dump out of git.
