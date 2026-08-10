# Build

```bash
sudo nerdctl build -t kataglyphis-webserver:latest -f linux/webserver/Dockerfile linux
```

The build context must be `linux` (not the repo root): the Dockerfile `COPY`s
context-relative `./webserver/...` paths, which only resolve under `linux/`.

`linux/webserver/Dockerfile` does not currently expose the fast Ubuntu mirror build flag used by the main Linux image chain.

# dist/ provenance

`linux/webserver/dist/` is ~82 MB of **committed, pre-built Flutter web
artifacts** (the site served by this image). They are deliberately checked in:
they are built in the sibling app repository (not from any source in this
repo), and committing the output lets this image build standalone without a
Flutter toolchain. Do not hand-edit files under `dist/` — regenerate them in
the app repo and copy the fresh build output over.

# Run mit Volume-Mount für dist UND nginx.conf
```bash
sudo nerdctl run -d --name kataglyphis-webserver \
  -p 8080:80 \
  -p 8443:443 \
  -v "$(pwd)/linux/webserver/dist:/var/www/html" \
  -v "$(pwd)/linux/webserver/nginx.conf:/etc/nginx/nginx.conf:ro" \
  kataglyphis-webserver:latest
```

```bash
docker exec kataglyphis-webserver nginx -t
docker exec kataglyphis-webserver nginx -s reload
```

Reload browser with cache: F5 !!

---

# Reusable Flutter web helpers

The following shared helpers are intended for Flutter web projects that need local hosting or smoke testing outside this repository:

- `linux/webserver/templates/flutter-nginx-local.conf`: minimal nginx config for local SPA + WASM serving on port `8080`
- `linux/webserver/templates/flutter-web.htaccess`: Apache template with WASM MIME type and basic headers
- `linux/webserver/scripts/flutter_integration_smoke_test.sh`: HTTP-level smoke test for a built Flutter web app
- `linux/webserver/scripts/flutter_capture_console_errors.py`: Playwright-based browser smoke test for a built Flutter web app

Example:

```bash
bash linux/webserver/scripts/flutter_integration_smoke_test.sh http://localhost:8080
python3 linux/webserver/scripts/flutter_capture_console_errors.py --build-dir /path/to/build/web
```

---

# Troubleshooting

## Container not reachable from other devices on the network

**Symptom:** Nginx is running and reachable locally (localhost), but other devices on the same network cannot access it.

**Cause:** UFW (Uncomplicated Firewall) has `DEFAULT_FORWARD_POLICY="DROP"` which blocks forwarded traffic to containers.

**Diagnosis:**
```bash
# Check if packets are being dropped in FORWARD chain
sudo iptables -L FORWARD -n -v | head -5
# Look for "policy DROP" and non-zero packet count

# Check current UFW forward policy
grep "DEFAULT_FORWARD_POLICY" /etc/default/ufw
```

**Fix:**
```bash
# Change forward policy to ACCEPT and reload UFW
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw reload
```

After this, the container should be accessible from other devices using the host's IP address (e.g., `http://192.168.x.x`).
