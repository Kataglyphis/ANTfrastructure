# sccache's shared S3 level: Garage on a VPS, reached over WireGuard

The server half of [`windows-build-resources.md` § Two cache levels](../../docs/windows-build-resources.md#two-cache-levels).
Every Windows build host keeps its own dufs as level 0, and a Linux chain host its disk cache
mount. This bucket is level 1, shared by all of them, so one host's compiles are hits on the next.

## As built (2026-10-15, endpoint re-resolution 2026-10-16, disk limits 2026-11-05)

| | |
|---|---|
| Host | Ubuntu 26.04 VPS, 4 cores, 7.7 GiB RAM; the disk is shared with Nextcloud and its Borg backups (91 GB free after the setup) |
| Network | WireGuard split tunnel into the FritzBox: the VPS is `<s3-server-lan-ip>` (and `<ula-prefix>::216`) in the home LAN and routes only the home LAN through it, ~20 ms RTT |
| Endpoint | The FritzBox's MyFritz name. `wg-reresolve-dns@wg0.timer` resolves it again every 30 s while the handshake is stale |
| Store | Garage v2.5.0 as the system user `garage`, one node in zone `vps`, data and LMDB metadata in `/srv/garage`, metadata snapshot every 6 h, compression off, `MemoryMax=1G` |
| S3 | `http://<s3-server-lan-ip>:3900`, region `garage`; RPC on `127.0.0.1:3901`, admin API on `127.0.0.1:3903` |
| Bucket | `sccache`, no key prefix, path-style addressing; 754,214 objects (48.9 GiB) after the seed on 2026-10-16 |
| Keys | `sccache-client` (read and write on `sccache` only, for the clients) in `/root/sccache-s3-key.txt`; `sccache-evict` (the size cap's own) in `/etc/garage/evict-key.txt`; both 600 |
| Firewall | ufw allows `3900/tcp` only on `wg0` from `<home-lan-cidr>`; the public IP has no listener on 3900 |
| Size cap | every 10 minutes: over 60 GiB, delete oldest `LastModified` first down to 90 % (54 GiB); under 25 GiB free on the disk, shrink further, down to 10 GiB. Lowered from 100 GiB on 2026-11-05, when the disk had 19 GB free. Hard bucket quotas: `sccache` 70 GiB, `release-assets` 20 GiB |
| Disk reserve | 5 GiB of ext4 reserved blocks (`tune2fs -r 1310720`), so a non-root writer such as Garage stops before root runs out |
| Removed | the dufs/WebDAV service that ran there first (its unit, the port 5000 rule, its data dir) |

> **Addresses.** `<s3-server-lan-ip>`, `<webdav-lan-ip>`, `<router-lan-ip>` and `<home-lan-cidr>`
> stand for the home network's real addresses, which live in the repository root's
> `site.local.env` (gitignored; `site.local.env.example` lists the names).

> **Provenance.** The files here are the live server's, sent by the server session on
> 2026-10-16, with every secret replaced by `REPLACE_ME`. The FritzBox's MyFritz name, its port
> and its IPv6 prefix are placeholders too (`<name>`, `<port>`, `<ula-prefix>`): they point at
> the home connection. `sccache-s3-evict` differs from the live copy in three places only: it
> exports the key in its own statement (shellcheck SC2155), its header is one comment line, and it
> reads the S3 address from `garage.toml`'s `[s3_api]` instead of naming it.
> `garage.service` carries one comment line more, on its `WantedBy`.

## Files

| File | Goes to | Owner, mode |
|---|---|---|
| `wg0.conf.example` | `/etc/wireguard/wg0.conf` | root, 600 |
| `wg-quick@wg0.retry.conf` | `/etc/systemd/system/wg-quick@wg0.service.d/retry.conf` | root, 644 |
| `wg-reresolve-dns@.service`, `wg-reresolve-dns@.timer` | `/etc/systemd/system/` | root, 644 |
| `garage.toml.example` | `/etc/garage/garage.toml` | root:garage, 640 |
| `garage.service` | `/etc/systemd/system/garage.service` | root, 644 |
| `sccache-s3-evict` | `/usr/local/sbin/sccache-s3-evict` | root, 700 |
| `sccache-evict.service`, `sccache-evict.timer` | `/etc/systemd/system/` | root, 644 |

## 1. WireGuard into the home LAN

1. FritzBox: *Internet → Freigaben → VPN (WireGuard) → Verbindung hinzufügen → Einzelnes
   Gerät verbinden*. Name it after the VPS and download the configuration file it offers.
   The FritzBox gives the device an address in the home LAN (here `<s3-server-lan-ip>`).
2. On the VPS, write that file to `/etc/wireguard/wg0.conf` and make two edits
   (`wg0.conf.example` shows the result):
   - `AllowedIPs` names only the home LAN (`<home-lan-cidr>` and the ULA `/64`). The
     export routes everything (`0.0.0.0/0`) through the FritzBox; the split tunnel keeps
     the VPS's own traffic on its own uplink.
   - Comment the `DNS =` lines out, so the VPS keeps its own resolver.
3. Bring the tunnel up, at boot too, with the endpoint re-resolution:

```bash
sudo apt-get install -y wireguard
sudo chmod 600 /etc/wireguard/wg0.conf
sudo install -D -m 644 wg-quick@wg0.retry.conf /etc/systemd/system/wg-quick@wg0.service.d/retry.conf
sudo install -m 755 /usr/share/doc/wireguard-tools/examples/reresolve-dns/reresolve-dns.sh /usr/local/sbin/wg-reresolve-dns
sudo install -m 644 wg-reresolve-dns@.service wg-reresolve-dns@.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wg-quick@wg0 wg-reresolve-dns@wg0.timer
wg show                              # a recent handshake
ping -c 3 <router-lan-ip>              # the FritzBox, through the tunnel
```

**Why the re-resolution (outage of 2026-10-16).** `wg` resolves an `Endpoint` name once, when
the tunnel comes up. The FritzBox's IPv6 prefix changed overnight, the VPS kept sending to the
old address, and the bucket was unreachable for about 8 hours (about 22:00 to 06:00 UTC). The
script is wireguard-tools' own example (GPL-2.0, Jason A. Donenfeld), installed from the
package rather than copied here. For each peer whose last handshake is older than 135 s it runs
`wg set <if> peer <key> endpoint <name>`, which resolves the name again. Recovery measured at
about 20 s.

**And the boot.** `wg-quick@wg0` resolves the name when it starts; if DNS is not up yet it
fails once, and without the drop-in the tunnel stays down until someone starts it. The drop-in
retries every 30 s with no start limit.

## 2. Garage

```bash
# Garage publishes no checksum file for this binary; this digest matched two downloads on 2026-10-15.
curl -fL -o /tmp/garage https://garagehq.deuxfleurs.fr/_releases/v2.4.1/x86_64-unknown-linux-musl/garage
echo "ae49f8de4aaee6b5ca305f7cbdccc8cd8a29b2804aac074649f18bfb83d0a2b6  /tmp/garage" | sha256sum -c
sudo install -m 755 /tmp/garage /usr/local/bin/garage

sudo useradd --system --home /srv/garage --shell /usr/sbin/nologin garage
sudo mkdir -p /srv/garage/meta /srv/garage/data
sudo chown -R garage:garage /srv/garage
sudo install -d -m 750 -o root -g garage /etc/garage
sudo install -m 640 -o root -g garage garage.toml.example /etc/garage/garage.toml
sudo sed -i "s|^rpc_secret = .*|rpc_secret = \"$(openssl rand -hex 32)\"|" /etc/garage/garage.toml
sudo sed -i "s|^admin_token = .*|admin_token = \"$(openssl rand -base64 32)\"|" /etc/garage/garage.toml
sudo install -m 644 garage.service /etc/systemd/system/garage.service
sudo systemctl daemon-reload
sudo systemctl enable --now garage
```

`garage.service` binds to `wg-quick@wg0`: without the tunnel the S3 address does not exist,
and Garage would fail to bind it. `BindsTo` stops Garage when the tunnel stops. Its
`WantedBy=… wg-quick@wg0.service` starts it again when the tunnel comes back; tested on
2026-10-16 by restarting `wg0`. After editing the `[Install]` section of an installed unit, run
`sudo systemctl daemon-reload && sudo systemctl reenable garage`.

Then the layout, the bucket and the two keys. Check each command against
`garage <command> --help` of the installed version:

```bash
garage status                                         # note the node id
garage layout assign -z vps -c 120G <node-id>         # a weight on one node; kept above the size cap
garage layout apply --version 1
garage bucket create sccache
(umask 077; garage key create sccache-client > /root/sccache-s3-key.txt)
garage bucket allow --read --write sccache --key sccache-client
(umask 077; garage key create sccache-evict > /etc/garage/evict-key.txt)
garage bucket allow --read --write sccache --key sccache-evict
```

The client secret stays in `/root/sccache-s3-key.txt`. That is where the user copies it from
into `Set-SccacheS3Level.ps1` on each client. It never goes into a repository.

**Rotating the client key** (after it leaked into a chat or a log, or on a schedule). The
objects stay valid, because the cache keys do not depend on the access key:

```bash
garage key create sccache-client-2                    # new id and secret, shown once
garage bucket allow --read --write sccache --key sccache-client-2
garage key info sccache-client-2 --show-secret | install -m 600 /dev/stdin /root/sccache-s3-key.txt
garage key delete --yes sccache-client                # the old key stops working at once
```

Then, on each Windows client, run `Set-SccacheS3Level.ps1` with the new key id. Copy the
command first and the secret last, so the clipboard holds the secret at the prompt.

## 3. Firewall

```bash
sudo ufw allow in on wg0 from <home-lan-cidr> to <s3-server-lan-ip> port 3900 proto tcp comment 'sccache S3 over WireGuard'
sudo ufw status verbose
```

Garage binds only `<s3-server-lan-ip>`, so the public address has no listener on 3900. Check
it from outside, e.g. a phone off the WLAN: `curl -m 5 http://<public-ip>:3900` must time out.

## 4. The size cap

sccache never deletes an object, and a hit does not refresh `LastModified`. The cap is
therefore oldest-written first, not least-recently-used. The script asks Garage's admin API
for the bucket size first and lists the bucket only when it is over the cap.
A run frees the disk only after Garage's GC has caught up, well after the bucket size has dropped
(2026-11-05: 230,000 objects, 21 minutes for the deletes alone).

```bash
# s5cmd 2.3.0, checksum from the release's s5cmd_checksums.txt
curl -fL -o /tmp/s5cmd.tgz https://github.com/peak/s5cmd/releases/download/v2.3.0/s5cmd_2.3.0_Linux-64bit.tar.gz
echo "de0fdbfa3aceae55e069ba81a0fc17b2026567637603734a387b2fca06c299b4  /tmp/s5cmd.tgz" | sha256sum -c
sudo tar -xzf /tmp/s5cmd.tgz -C /usr/local/bin s5cmd

sudo install -m 700 sccache-s3-evict /usr/local/sbin/sccache-s3-evict
sudo install -m 644 sccache-evict.service sccache-evict.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sccache-evict.timer
sudo systemctl start sccache-evict.service && journalctl -t sccache-evict -n 5
```

Four things keep the shared disk from filling, none of them a guarantee against Nextcloud or its
backups, which nothing here limits:

| Layer | Set by | Stops |
|---|---|---|
| `CAP_GB` (60) | `sccache-evict.service` | the bucket's normal growth, checked every 10 minutes |
| `MIN_FREE_GB` (25), `FLOOR_GB` (10) | `sccache-evict.service` | other writers: under 25 GiB free the bucket gives up the shortfall plus 5 GiB, but not while a resync backlog over 1000 is still freeing earlier deletes |
| Bucket quota | `garage bucket set-quotas sccache --max-size 70GiB` | an upload burst faster than eviction: Garage refuses the writes |
| Reserved blocks | `sudo tune2fs -r 1310720 <device>` | non-root writers, Garage included, at the last 5 GiB, so root can still log in and clean up |

Set the quota only once the bucket is under it, or uploads fail until eviction catches up.

Change the cap with `CAP_GB` in `sccache-evict.service` (`systemctl edit sccache-evict.service`);
the target is 90 % of it. Keep the layout's capacity above it (`garage layout assign … -c`, then
`garage layout apply --version <next>`), and read `df` first: the disk is shared with Nextcloud. A seed from a client gives every object the seed time, so the first
evictions go roughly in seed order until real traffic replaces them.

### Decisions on the disk limits

Taken 2026-11-05 at 19 GB free, when the bucket was over its old cap and eviction had been failing:

| Decision | Why |
|---|---|
| Cap 60 GiB instead of 100 GiB | At most about 10 GiB arrived per day after the seed, and 48.9 of the 104 GiB were the seed of 2026-10-15. The cap costs misses, never data |
| Check every 10 minutes | The script asks the admin API first and lists the bucket only when it has to act, so a quiet check costs almost nothing |
| Free-space rule at 25 GiB, floor 10 GiB | Only the cache can give way for Nextcloud. The floor stops it being emptied for a shortfall it cannot solve |
| Quota 70 GiB above the cap | Eviction runs late under a burst, and the quota holds without it. Between 60 and 70 GiB nothing is refused |
| Reserve 5 GiB for root | The server stays reachable and can be cleaned up when everything else is out of space |
| `release-assets` quota 20 GiB | Nothing evicts that bucket, so nothing else bounds it |
| Oldest upload first, unchanged | A hit does not refresh `LastModified`, so a still-used old object can go. It costs one miss and comes back on the next upload |

Not proven live: the free-space rule has only run against stubs, and what a sccache client does when
the quota refuses an upload was not tried.

**Still open, for the owner:**

- Turn off Garage's metadata snapshots (5.7 GB, `metadata_auto_snapshot_interval`). The cache could
  be rebuilt without them. It needs a Garage restart, so not during a build.
- Move the Borg backups off this disk (38 GB). They would not survive losing it, and nothing here limits them.
- Alert on low free space. The server tells nobody today, and Nextcloud can still fill the disk.

## 5. Check it

On the VPS, with the client key exported as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
and `AWS_REGION=garage`:

```bash
s5cmd --endpoint-url http://<s3-server-lan-ip>:3900 cp /etc/hostname s3://sccache/probe/a/b/c
s5cmd --endpoint-url http://<s3-server-lan-ip>:3900 ls 's3://sccache/probe/*'
s5cmd --endpoint-url http://<s3-server-lan-ip>:3900 cat s3://sccache/probe/a/b/c
s5cmd --endpoint-url http://<s3-server-lan-ip>:3900 rm 's3://sccache/probe/*'
AWS_SECRET_ACCESS_KEY=wrong s5cmd --endpoint-url http://<s3-server-lan-ip>:3900 ls 's3://sccache/*'   # 403, invalid signature
garage bucket info sccache                                    # size, object count and quota
garage stats | grep 'resync queue'                            # deleted space still to come back
df -h /srv/garage
journalctl -t sccache-evict -n 5                              # what the last evictions removed
systemctl list-timers 'wg-reresolve-dns@*' sccache-evict.timer
```

On each Windows client: `Test-HostSetup.ps1` reports `sccache S3 level reachable`. The next
`Build-Buildkit.ps1` run prints `sccache levels: webdav -> s3`, and each sccache RUN
ends with a `sccache-drain|` line.

## The client side

The page linked at the top covers it: `Set-SccacheS3Level.ps1`, `Copy-SccacheCacheToS3.ps1`
(the seed), what the driver passes, and how a build behaves when this server is down.

A Linux chain host stores the same key with `linux/host-config/set-sccache-s3-level.sh`
([`linux-host-setup.md` § B9](../../docs/linux-host-setup.md#b9-the-shared-s3-level-for-sccache)), and
its chain hands it to every sccache RUN as one BuildKit secret
([`build-cache-tiers.md` § The shared S3 level](../../docs/build-cache-tiers.md#the-shared-s3-level)).

## The asset mirror

The same Garage holds a second bucket, `release-assets`: the pinned release assets the chain
downloads, so a GitHub outage cannot fail an arch
([`linux-cross-builds.md` § The asset mirror](../../docs/linux-cross-builds.md#the-asset-mirror)).
Objects are content-addressed, `<sha256>/<file name>`, and every reader checks the pinned
sha256 again. It is a bucket of its own because `sccache-s3-evict` deletes the `sccache`
bucket's oldest objects, and a pinned asset is old by design.

**Setup, from each Linux chain host.** One command per host, from the hub checkout:

```bash
bash linux/host-config/set-asset-mirror.sh --from root@<s3-server-lan-ip> --url http://<s3-server-lan-ip>:3900/release-assets
bash linux/host-config/set-asset-mirror.sh --check
```

`--url` ships `setup-asset-mirror.sh`, with the files it sources, into a temp directory on the VPS
and runs it there: it creates the bucket and its two keys and writes their env files into `/root`,
mode 600. Then the script copies both files into place, mode 600, deletes the VPS copies and the
temp directory, and proves the rights each key needs; `--check` repeats only the proof. The setup
keeps an existing bucket or key, so every host gets the same keys. `setup-asset-mirror.sh` reads
`/etc/garage/garage.toml` (`GARAGE_CONFIG_FILE` overrides it) and stops when the
`garage key info --show-secret` output no longer has a `Key ID:` and a `Secret key:` line.
Nothing evicts the bucket: an old pin's objects stay until they are deleted by hand. Its quota of
20 GiB makes a fill fail loudly when it is reached (783 MiB, 33 objects on 2026-11-05).

| File | Key | Read by |
|---|---|---|
| `~/.config/kataglyphis/asset-mirror.env` | `asset-mirror-read` | every chain build, as the BuildKit secret `asset_mirror` |
| `~/.config/kataglyphis/asset-mirror-fill.env` | `asset-mirror-fill` | `fill-asset-mirror.sh` only |

Both hold `ASSET_MIRROR_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_REGION=garage`,
and never belong in a repository. The check fails unless the read key lists and reads but cannot
write, and the fill key writes and deletes.

The firewall rule of § 3 already admits the build hosts. The key reaches curl on stdin and is
SigV4-signed (`--aws-sigv4`, curl 7.75 or newer), so it shows in no process listing.

**Filling it.** Each upstream fetch logs `asset-mirror| miss <sha256> <url> <mode>`, and the
fill script turns those lines into objects. After a chain, from the hub checkout:

```bash
linux/host-config/fill-asset-mirror.sh                         # dry run over logs/build-logs
linux/host-config/fill-asset-mirror.sh --apply                 # download, verify, upload, read back
linux/host-config/fill-asset-mirror.sh --apply --url <url> --sha <sha256> [--stream]   # one asset by hand
```

It mirrors only a digest that `versions.env` or `tool-pins.env` pins, skips an object that is
already present, verifies every download against the pin and every upload by reading it back,
and exits 1 when any asset failed. The first chain after the setup fills the log; the second
one is served from the mirror (`asset-mirror| hit` lines).
