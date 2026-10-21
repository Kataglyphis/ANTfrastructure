# Build

```bash
sudo nerdctl build -t kataglyphis-webserver:latest -f linux/webserver/Dockerfile linux
```

The build context must be `linux` (not the repo root): the Dockerfile `COPY`s
context-relative `./webserver/...` paths, which only resolve under `linux/`.

`linux/webserver/Dockerfile` does not currently expose the fast Ubuntu mirror build flag used by the main Linux image chain.

# The site comes from a build context, not from this repository

The site this image serves is built in **jotrockenmitlocken**, from sources that
do not exist here. It was committed under `linux/webserver/dist/` until
2026-09-15 — 82 MB of minified output — so that the image could build standalone
without a Flutter toolchain. That convenience was paid for by every clone of
this repository, and by every gate that had to learn to skip the directory.

Build it by naming the site as a context instead:

```bash
nerdctl build --build-context site=<path-to-jotrockenmitlocken>/build/web \
  -f linux/webserver/Dockerfile -t kataglyphis-webserver:latest linux
```

`site` can be any directory holding a built web app — a fresh
`flutter build web --release` output, or a CI artifact you downloaded and
unpacked. `linux/docker-compose.yml` declares a default path for it under
`additional_contexts`; adjust it for your checkout. A build that names no `site`
context fails at the `COPY --from=site` line, by name, rather than producing an
image that serves nothing.

`linux/webserver/dist/` is gitignored. Files already there keep working for the
volume-mount recipe below; they are simply not this repository's to carry, and
nothing here can regenerate them.

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
- `linux/webserver/scripts/flutter_integration_smoke_test.sh`: HTTP-level smoke test for a built Flutter web app. With `CHECK_LOADING_SHELL=1` (the default) it also fails when `index.html` lacks the shared shell's markup or one of its files is not served ([`shared/web/README.md`](../../shared/web/README.md)). With `CHECK_LOCAL_ENGINE=1` (the default) it fails a build that loads its engine from Google's CDN: build with `--no-web-resources-cdn`. With `CHECK_FALLBACK_FONTS=1` it fails a build whose `flutter_bootstrap.js` names no `fontFallbackBaseUrl` on the site, or that does not serve every font of the lock under it ([below](#fallback-fonts-from-the-site)). `REQUIRED_CSP_HOSTS` names hosts the CSP must carry; none by default
- `linux/webserver/scripts/flutter-nginx-integration-test.sh <build-dir> [--port N]`: that smoke test against the build behind `flutter-nginx-local.conf` in `nginx:alpine`. `ENGINE` picks docker or nerdctl; from Git Bash it hands the engine `C:/...` paths. It removes the container whatever the result
- `linux/webserver/scripts/flutter_capture_console_errors.py`: Playwright-based browser smoke test for a built Flutter web app. It serves the build with index.html for every extension-less path, as nginx and the `.htaccess` do, so a deep route loads the app instead of a 404 page. `--route PATH`, repeated, names the routes to open. It lists every third-party host the page requested; `--forbid-host SUFFIX`, repeated, fails the run when one matches

Example:

```bash
bash linux/webserver/scripts/flutter_integration_smoke_test.sh http://localhost:8080
python3 linux/webserver/scripts/flutter_capture_console_errors.py --build-dir /path/to/build/web
```

## Fallback fonts from the site

`--no-web-resources-cdn` serves the engine from the site, but not the fonts it falls back to for a
glyph the app's fonts lack (emoji, symbols, CJK): the engine fetches those from
`fonts.gstatic.com/s/<family>/<version>/<file>.woff2`, a CSP that names no Google host blocks the
fetch, and the glyph draws as an empty box.

- **The site serves them instead.** The app's `web/flutter_bootstrap.js` passes
  `config: {fontFallbackBaseUrl: "fallback-fonts/"}` to `_flutter.loader.load`, and the build gets
  `linux/scripts/05-frameworks/flutter/fetch-fallback-fonts.py --dest build/web/fallback-fonts`,
  which places each file of `fallback-fonts.lock` at `<family>/<version>/<file>`, checked by
  SHA-256 through `lib/fetch-data-lock.py` and its cache (`KATAGLYPHIS_FONT_CACHE`).
- **The family image holds them already** (CON147): the SDK stage fills `/opt/flutter-fallback-fonts`
  once and makes it read-only, and `KATAGLYPHIS_FONT_STORE` names it. The fetcher copies from there
  first, so a build downloads nothing; the cache serves only a file the store lacks.
- **The lock holds every chunk of Noto Color Emoji and Noto Sans Symbols 2**, 18 files, 2.3 MiB
  (2026-10-21): the families jonasheinle.de's content asked for. The engine loads a chunk only
  when a glyph needs it. All 144 families are 724 files, 20.7 MiB, most of it CJK.
- **A Flutter bump can move the paths.** The fetcher reads the engine's
  `font_fallback_data.dart` in the image's SDK and fails on a locked file the engine no longer
  requests, or a chunk of a locked family the lock lacks. Re-pin with
  `fetch-fallback-fonts.py --print-lock <family>...`.
- **A family the lock lacks** now 404s on the site instead of being blocked: the live-site check
  ([`docs/ftp-deploys.md`](../../docs/ftp-deploys.md#the-live-site-check)) names its URL.
- The fonts are OFL-1.1; the app lists them on its licences page.

## Prerequisites for the browser smoke test

The Playwright script drives a real headless browser, so it needs one. **flatpak
Chromium**, because it is the option that works on ARM64 as well as x86-64 —
which is why this is not "install chromium with your package manager":

```bash
flatpak install flathub org.chromium.Chromium
python3 -m pip install --break-system-packages playwright
```

`--break-system-packages` is not carelessness: on a Debian/Ubuntu host with an
externally-managed Python, `pip install` refuses outright, and a venv is the
wrong shape here because the script is run by hand next to a build, not by a
lane that owns an environment.

What the script does, so a green run means something: it serves the build
directory over HTTP, launches headless Chromium through Playwright's flatpak
binary, then walks every route, four viewport widths (375 / 768 / 1280 / 1920),
the asset and renderer wiring, page-load timings and the interactive bits
(loading-screen fade, cookie notice and consent, navigation, dark mode). It
reports errors, warnings and info separately and writes a screenshot. **A WebGL
GPU-stall warning in headless mode is expected** and is not a finding.

## Troubleshooting the browser smoke test

Four failures account for nearly all of them, and each looks like something else:

- **`No module named 'playwright'`** — the install above was skipped or landed in
  another interpreter: `python3 -m pip install --break-system-packages playwright`.
- **Chromium not found** — check the flatpak is really there
  (`flatpak list | grep chromium`); a system chromium does not satisfy this.
- **Port 8080 already in use** — a previous run's server survived:
  `kill $(lsof -t -i:8080)`. The symptom is a test that passes against the OLD
  build, which is worse than a failure.
- **Browser launch fails** — inside a container or WSL, Chromium needs
  `--no-sandbox`; without it the launch dies with no useful message.

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
