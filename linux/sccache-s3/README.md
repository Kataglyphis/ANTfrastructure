# sccache's shared S3 level: Garage on a VPS, reached over WireGuard

The server half of [`windows-build-resources.md` § Two cache levels](../../docs/windows-build-resources.md#two-cache-levels).
Every Windows build host keeps its own dufs as level 0. This bucket is level 1, shared by
all of them, so one host's compiles are hits on the next.

## As built (2026-10-15, endpoint re-resolution 2026-10-16)

| | |
|---|---|
| Host | Ubuntu 26.04 VPS, 4 cores, 7.7 GiB RAM; the disk is shared with Nextcloud (91 GB free after the setup) |
| Network | WireGuard split tunnel into the FritzBox: the VPS is `192.168.188.216` (and `<ula-prefix>::216`) in the home LAN and routes only the home LAN through it, ~20 ms RTT |
| Endpoint | The FritzBox's MyFritz name. `wg-reresolve-dns@wg0.timer` resolves it again every 30 s while the handshake is stale |
| Store | Garage v2.4.1 as the system user `garage`, one node in zone `vps`, data and LMDB metadata in `/srv/garage`, metadata snapshot every 6 h, compression off, `MemoryMax=1G` |
| S3 | `http://192.168.188.216:3900`, region `garage`; RPC on `127.0.0.1:3901`, admin API on `127.0.0.1:3903` |
| Bucket | `sccache`, no key prefix, path-style addressing; 754,214 objects (48.9 GiB) after the seed on 2026-10-16 |
| Keys | `sccache-client` (read and write on `sccache` only, for the clients) in `/root/sccache-s3-key.txt`; `sccache-evict` (the size cap's own) in `/etc/garage/evict-key.txt`; both 600 |
| Firewall | ufw allows `3900/tcp` only on `wg0` from `192.168.188.0/24`; the public IP has no listener on 3900 |
| Size cap | hourly: over 60 GiB, delete oldest `LastModified` first down to 90 % (54 GiB) |
| Removed | the dufs/WebDAV service that ran there first (its unit, the port 5000 rule, its data dir) |

> **Provenance.** The files here are the live server's, sent by the server session on
> 2026-10-16, with every secret replaced by `REPLACE_ME`. The FritzBox's MyFritz name, its port
> and its IPv6 prefix are placeholders too (`<name>`, `<port>`, `<ula-prefix>`): they point at
> the home connection. `sccache-s3-evict` differs from the live copy in two places only: it
> exports the key in its own statement (shellcheck SC2155), and its header is one comment line.

## Files

| File | Goes to | Owner, mode |
|---|---|---|
| `wg0.conf.example` | `/etc/wireguard/wg0.conf` | root, 600 |
| `wg-reresolve-dns@.service`, `wg-reresolve-dns@.timer` | `/etc/systemd/system/` | root, 644 |
| `garage.toml.example` | `/etc/garage/garage.toml` | root:garage, 640 |
| `garage.service` | `/etc/systemd/system/garage.service` | root, 644 |
| `sccache-s3-evict` | `/usr/local/sbin/sccache-s3-evict` | root, 700 |
| `sccache-evict.service`, `sccache-evict.timer` | `/etc/systemd/system/` | root, 644 |

## 1. WireGuard into the home LAN

1. FritzBox: *Internet → Freigaben → VPN (WireGuard) → Verbindung hinzufügen → Einzelnes
   Gerät verbinden*. Name it after the VPS and download the configuration file it offers.
   The FritzBox gives the device an address in the home LAN (here `192.168.188.216`).
2. On the VPS, write that file to `/etc/wireguard/wg0.conf` and make two edits
   (`wg0.conf.example` shows the result):
   - `AllowedIPs` names only the home LAN (`192.168.188.0/24` and the ULA `/64`). The
     export routes everything (`0.0.0.0/0`) through the FritzBox; the split tunnel keeps
     the VPS's own traffic on its own uplink.
   - Comment the `DNS =` lines out, so the VPS keeps its own resolver.
3. Bring the tunnel up, at boot too, with the endpoint re-resolution:

```bash
sudo apt-get install -y wireguard
sudo chmod 600 /etc/wireguard/wg0.conf
sudo install -m 755 /usr/share/doc/wireguard-tools/examples/reresolve-dns/reresolve-dns.sh /usr/local/sbin/wg-reresolve-dns
sudo install -m 644 wg-reresolve-dns@.service wg-reresolve-dns@.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wg-quick@wg0 wg-reresolve-dns@wg0.timer
wg show                              # a recent handshake
ping -c 3 192.168.188.1              # the FritzBox, through the tunnel
```

**Why the re-resolution (outage of 2026-10-16).** `wg` resolves an `Endpoint` name once, when
the tunnel comes up. The FritzBox's IPv6 prefix changed overnight, the VPS kept sending to the
old address, and the bucket was unreachable for about 8 hours (about 22:00 to 06:00 UTC). The
script is wireguard-tools' own example (GPL-2.0, Jason A. Donenfeld), installed from the
package rather than copied here. For each peer whose last handshake is older than 135 s it runs
`wg set <if> peer <key> endpoint <name>`, which resolves the name again. Recovery measured at
about 20 s.

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
and Garage would fail to bind it.

Then the layout, the bucket and the two keys. Check each command against
`garage <command> --help` of the installed version:

```bash
garage status                                         # note the node id
garage layout assign -z vps -c 80G <node-id>          # capacity: what the disk can give
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
sudo ufw allow in on wg0 from 192.168.188.0/24 to 192.168.188.216 port 3900 proto tcp comment 'sccache S3 over WireGuard'
sudo ufw status verbose
```

Garage binds only `192.168.188.216`, so the public address has no listener on 3900. Check
it from outside, e.g. a phone off the WLAN: `curl -m 5 http://<public-ip>:3900` must time out.

## 4. The size cap

sccache never deletes an object, and a hit does not refresh `LastModified`. The cap is
therefore oldest-written first, not least-recently-used. The script asks Garage's admin API
for the bucket size first and lists the bucket only when it is over the cap.

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

Change the cap with `CAP_GB` in `sccache-evict.service` (`systemctl edit sccache-evict.service`);
the target is 90 % of it. A seed from a client gives every object the seed time, so the first
evictions go roughly in seed order until real traffic replaces them.

## 5. Check it

On the VPS, with the client key exported as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
and `AWS_REGION=garage`:

```bash
s5cmd --endpoint-url http://192.168.188.216:3900 cp /etc/hostname s3://sccache/probe/a/b/c
s5cmd --endpoint-url http://192.168.188.216:3900 ls 's3://sccache/probe/*'
s5cmd --endpoint-url http://192.168.188.216:3900 cat s3://sccache/probe/a/b/c
s5cmd --endpoint-url http://192.168.188.216:3900 rm 's3://sccache/probe/*'
AWS_SECRET_ACCESS_KEY=wrong s5cmd --endpoint-url http://192.168.188.216:3900 ls 's3://sccache/*'   # 403, invalid signature
garage bucket info sccache                                    # size and object count
systemctl list-timers 'wg-reresolve-dns@*' sccache-evict.timer
```

On each Windows client: `Test-HostSetup.ps1` reports `sccache S3 level reachable`. The next
`Build-Buildkit.ps1` run prints `sccache levels: webdav … -> s3 …`, and each sccache RUN
ends with a `sccache-drain|` line.

## The client side

The page linked at the top covers it: `Set-SccacheS3Level.ps1`, `Copy-SccacheCacheToS3.ps1`
(the seed), what the driver passes, and how a build behaves when this server is down.
