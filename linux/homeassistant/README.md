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
# fill in the WoL MAC and the shutdown SSH command
```

The `rechenkiste` switch's turn-off runs `ssh` inside the container, which has
no key of its own: put the private key and a `known_hosts` under
`config/.ssh/` and reference both explicitly (see the example). As of
2026-09-30 only `id_rsa.pub` is there, so turn-off fails until the key is
restored; wake-up (magic packet) works regardless.

`!secret` only works as a whole YAML node, so each `shell_command` is stored
whole in `secrets.yaml` — it cannot be assembled from parts in the tracked YAML.

## Updating

```bash
nerdctl compose -f linux/homeassistant/compose.yaml pull
nerdctl compose -f linux/homeassistant/compose.yaml up -d --force-recreate
```

`--force-recreate` is required: unlike docker compose, `nerdctl compose up`
keeps a running container on its old image after a pull. When you name one
service, the other is reported as "orphaned" — ignore it; `--remove-orphans`
would delete it.

## Notes

- Bluetooth is unavailable: a rootless container cannot authenticate to the
  host D-Bus (EXTERNAL auth is rejected), so the stack runs without
  `privileged` and without the `/run/dbus` mount — which also removes the
  recurring BlueZ error spam. The remaining startup errors from
  `habluetooth.manager` and `aiodhcpwatcher` are silenced in `logger:`; drop
  those two lines when moving to a rootful runtime.
- `stop_grace_period: 60s` gives the recorder time to close the SQLite DB
  cleanly; a 10s stop leaves an "unfinished session" warning behind.
- The 455 MB `core` dump from 2025-03-19 was deleted during the move; the
  `.gitignore` `core` pattern keeps any future dump out of git.

## Recorder and energy dashboard

`recorder.exclude` in `configuration.yaml` drops the chatty Tasmota plug
telemetry (apparent/reactive power, current, voltage, power factor) — measured
2026-09-13: ~320k of 552k state rows over 10 days. `power` and the kWh
`total`/`today` counters stay, because the energy dashboard consumes them.
Since 2026-09-30 it also drops the TP-Link P110 voltage/current and their
day/month counters (derivable from `total_consumption`) plus two chatty phone
sensors — together ~49% of the state rows written in the preceding week.

### Grid meter glitch guard

The bitshake E320 reader occasionally reports garbage (e.g. `-1.4e13 kWh`). A
`total_increasing` sensor books that as a meter reset, and the rebound adds
trillions of kWh to the long-term `sum` — this happened on 2026-09-29/30.
`configuration.yaml` defines `sensor.netzbezug` / `sensor.netzeinspeisung`,
which copy the raw counters but hold their last value unless the new reading is
positive, non-decreasing and less than 1000 kWh above it. The energy
dashboard's grid source uses these, not the raw
`sensor.bitshake_smartmeterreader_e320_e_in/_out` (whose own statistics can
still pick up future glitches — ignore them). On 2026-09-30 the corrupted
history was recomputed from the hourly meter readings and copied onto the two
filtered sensors, so the dashboard kept its history back to 2026-09-02. A genuinely replaced meter
(counter restarting low) would freeze them — reset by removing and re-adding
the entities.

The dashboard carries grid (Tasmota P1 meter), solar (Growatt), both
Forecast.Solar planes (10 kWp + 2.5 kWp, currently at the 25°/180° defaults —
retune tilt/azimuth in the integration's Configure dialog if the roofs differ),
and six individual devices: four NOUS A1T (Wohnzimmer links, Büro links, Silas,
Waschmaschine) and two P110 (Anrichte, Wohnzimmer rechts). The "Stromzähler von
Jones" P110 exposes no lifetime counter, so it is not listed.

## Backups

Automatic backups run daily into `config/backups/`, retention 3 copies. The
password was set 2026-09-13, so backups created from 2026-09-14 on are
**encrypted**; the older unencrypted archives were deleted 2026-09-30. Keep the password (stored in
`.storage/backup`) in your password manager — new archives cannot be restored
without it. They are local-only: add the NAS as network storage, then register
it as a backup location (Settings → System → Backups → Locations) to get them
off the Pi.
