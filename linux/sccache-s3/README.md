# sccache's shared S3 level: Garage on a VPS, reached over WireGuard

The server half of [`windows-build-resources.md` § Two cache levels](../../docs/windows-build-resources.md#two-cache-levels).
Every Windows build host keeps its own dufs as level 0. This bucket is level 1, shared by
all of them, so one host's compiles are hits on the next.

## As built on 2026-10-15

| | |
|---|---|
| Host | Ubuntu 26.04 VPS, 4 cores, 7.7 GiB RAM; the disk is shared with Nextcloud (91 GB free after the setup) |
| Network | WireGuard split tunnel into the FritzBox: the VPS is `192.168.188.216` in the home LAN and routes only `192.168.188.0/24` through it, ~20 ms RTT |
| Store | Garage v2.4.1, one node, S3 API on `http://192.168.188.216:3900`, region `garage`, compression off |
| Bucket | `sccache`, no key prefix, path-style addressing |
| Keys | `sccache-client`: read and write on `sccache` only; the clients use it. `sccache-evict`: the size cap's own key |
| Firewall | ufw allows `3900/tcp` only on `wg0` from `192.168.188.0/24`; the public IP does not answer; the admin API listens on localhost |
| Size cap | hourly: over 60 GiB, delete oldest `LastModified` first down to 54 GiB |
| Removed | the dufs/WebDAV service that ran there first (its unit, the port 5000 rule, its data dir) |

> **Provenance.** A Claude session set this server up on 2026-10-15 and reported the values
> above; the session ended before it could hand over its files. The files in this directory
> rebuild the same setup from that report and Garage's documented commands. Before you
> rely on them for a rebuild, compare them with the live server:
> `cat /etc/garage.toml`, `systemctl cat garage sccache-evict.service sccache-evict.timer`,
> `cat /usr/local/bin/sccache-evict.sh`, `ufw status verbose`, `wg show`. Then commit any
> difference here.

## Files

| File | Goes to | Mode |
|---|---|---|
| `wg0.conf.example` | `/etc/wireguard/wg0.conf` | root, 600 |
| `garage.toml.example` | `/etc/garage.toml` | root, 600 |
| `garage.service` | `/etc/systemd/system/garage.service` | |
| `sccache-evict.sh` | `/usr/local/bin/sccache-evict.sh` | root, 755 |
| `sccache-evict.env.example` | `/etc/sccache-evict.env` | root, 600 |
| `sccache-evict.service`, `sccache-evict.timer` | `/etc/systemd/system/` | |

Every `REPLACE_ME` is a secret or a site value. Keep the real values on the server.

## 1. WireGuard into the home LAN

1. FritzBox: *Internet → Freigaben → VPN (WireGuard) → Verbindung hinzufügen → Einzelnes
   Gerät verbinden*. Name it after the VPS and download the configuration file it offers.
   The FritzBox gives the device an address in the home LAN (here `192.168.188.216`).
2. On the VPS, write that file to `/etc/wireguard/wg0.conf` and make two edits
   (`wg0.conf.example` shows the result):
   - `AllowedIPs = 192.168.188.0/24`. The export routes everything (`0.0.0.0/0`) through
     the FritzBox; the split tunnel keeps the VPS's own traffic on its own uplink.
   - Delete the `DNS =` line, so the VPS keeps its own resolver.
3. Bring the tunnel up, at boot too:

```bash
sudo apt-get install -y wireguard
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
wg show                              # a recent handshake
ping -c 3 192.168.188.1              # the FritzBox, through the tunnel
```

## 2. Garage

```bash
# Garage publishes no checksum file for this binary; this digest matched two downloads on 2026-10-15.
curl -fL -o /tmp/garage https://garagehq.deuxfleurs.fr/_releases/v2.4.1/x86_64-unknown-linux-musl/garage
echo "ae49f8de4aaee6b5ca305f7cbdccc8cd8a29b2804aac074649f18bfb83d0a2b6  /tmp/garage" | sha256sum -c
sudo install -m 755 /tmp/garage /usr/local/bin/garage

sudo install -m 600 garage.toml.example /etc/garage.toml   # then set rpc_secret and admin_token
sudo sed -i "s/^rpc_secret = .*/rpc_secret = \"$(openssl rand -hex 32)\"/" /etc/garage.toml
sudo sed -i "s/^admin_token = .*/admin_token = \"$(openssl rand -hex 32)\"/" /etc/garage.toml
sudo install -m 644 garage.service /etc/systemd/system/garage.service
sudo systemctl daemon-reload
sudo systemctl enable --now garage
```

Then the layout, the bucket and the two keys. Check each command against
`garage <command> --help` of the installed version:

```bash
garage status                                         # note the node id
garage layout assign -z dc1 -c 80G <node-id>          # capacity: what the disk can give
garage layout apply --version 1
garage bucket create sccache
garage key create sccache-client                      # prints the key id and the secret once
garage bucket allow --read --write sccache --key sccache-client
garage key create sccache-evict
garage bucket allow --read --write sccache --key sccache-evict
```

Keep the client secret root-only: on this server it is in `/root/sccache-s3-key.txt` (600).
That is where the user copies it from into `Set-SccacheS3Level.ps1` on each client.

## 3. Firewall

```bash
sudo ufw allow in on wg0 from 192.168.188.0/24 to any port 3900 proto tcp comment 'sccache S3 over WireGuard'
sudo ufw status verbose
```

Garage binds only `192.168.188.216`, so the public address has no listener on 3900. Check
it from outside, e.g. a phone off the WLAN: `curl -m 5 http://<public-ip>:3900` must time out.

## 4. The size cap

sccache never deletes an object, and a hit does not refresh `LastModified`. The cap is
therefore oldest-written first, not least-recently-used.

```bash
# s5cmd 2.3.0, checksum from the release's s5cmd_checksums.txt
curl -fL -o /tmp/s5cmd.tgz https://github.com/peak/s5cmd/releases/download/v2.3.0/s5cmd_2.3.0_Linux-64bit.tar.gz
echo "de0fdbfa3aceae55e069ba81a0fc17b2026567637603734a387b2fca06c299b4  /tmp/s5cmd.tgz" | sha256sum -c
sudo tar -xzf /tmp/s5cmd.tgz -C /usr/local/bin s5cmd

sudo install -m 755 sccache-evict.sh /usr/local/bin/sccache-evict.sh
sudo install -m 600 sccache-evict.env.example /etc/sccache-evict.env   # then the sccache-evict key
sudo install -m 644 sccache-evict.service sccache-evict.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sccache-evict.timer
sudo systemctl start sccache-evict.service && journalctl -u sccache-evict.service -n 5
```

Change the cap with `CAP_GB` and `TRIM_GB` in `/etc/sccache-evict.env`; the next hourly run
picks it up. A seed from a client gives every object the seed time, so the first evictions
go roughly in seed order until real traffic replaces them.

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
```

On each Windows client: `Test-HostSetup.ps1` reports `sccache S3 level reachable`. The next
`Build-Buildkit.ps1` run prints `sccache levels: webdav … -> s3 …`, and each sccache RUN
ends with a `sccache-drain|` line.

## The client side

The page linked at the top covers it: `Set-SccacheS3Level.ps1`, `Copy-SccacheCacheToS3.ps1`
(the seed), what the driver passes, and how a build behaves when this server is down.
