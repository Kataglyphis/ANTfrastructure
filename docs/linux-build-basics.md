# Linux Build Basics

## Build

```bash
sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
# on Windows you must expose ports one by one
sudo nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

## Optional Ubuntu Apt Mirror Workaround

- Add both `--build-arg USE_FAST_UBUNTU_MIRROR=true` and `--build-arg FAST_UBUNTU_MIRROR_URL=...` when the default Ubuntu archive mirror is slow.
- Example German mirror override: `--build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/`.
- The helper rewrites archive mirror entries only by default; `security.ubuntu.com` stays untouched unless you explicitly opt into rewriting it.
- Helper scripts expose the same behavior via `--fast-ubuntu-mirror` and `--fast-ubuntu-mirror-url`.

Generic usage:

```bash
sudo nerdctl build \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  -f <dockerfile> \
  .
```

Supported Dockerfiles:

- `linux/Dockerfile.base`
- `linux/Dockerfile.toolchain`
- `linux/Dockerfile.sdk`
- `linux/Dockerfile.media`
- `linux/Dockerfile.android`
- `linux/Dockerfile`
- `linux/Dockerfile.nvidia`
- `linux/Dockerfile.amd`
- `linux/Dockerfile.torch`

Not supported / not needed:

- `linux/webserver/Dockerfile` is not wired for this flag.
- `linux/Dockerfile.runtime-artifact` is copy-only and does not run apt.
- `windows/Dockerfile` does not use apt.

## Multi-Arch Build

### RICV64 example

```bash
nerdctl build --platform linux/riscv64 --build-arg GSTREAMER_VERSION=1.28.1 --no-cache \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:riscv -f linux/Dockerfile.media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  .
```

### Setup essentials

Always build with `--platform`:

```bash
docker buildx imagetools create --tag ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest_multiarch ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd64
```

```bash
cat > /tmp/buildkitd.toml <<'TOML'
# limit BuildKit worker parallelism to 2 (set to 1 on very small machines)
[worker.oci]
  max-parallelism = 2
TOML
```

```bash
sudo nerdctl login ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest -u Kataglyphis

sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all

sudo nerdctl build \
  --platform=linux/arm64,linux/amd64,linux/arm64,linux/riscv64 \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true' \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_BY="local" \
  -f linux/Dockerfile . 2>&1 | tee -a output.log
```

### Build & push (docker buildx)

```bash
docker buildx create --name wsl-limited --use --driver docker-container --driver-opt memory=12g --driver-opt cpu-period=100000 --driver-opt cpu-quota=800000
```

```bash
--builder wsl-limited
```

```bash
sudo docker buildx build \
  -f linux/Dockerfile \
  --platform linux/amd64,linux/arm64,linux/riscv64 \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:$(git rev-parse --short HEAD) \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_BY="local" \
  --push \
  . 2>&1 | tee -a output.log
```

### Reset builder

```bash
docker buildx ls
docker buildx rm mybuilder 2>/dev/null || true
docker buildx create --name mybuilder --driver docker-container --buildkitd-config /tmp/buildkitd.toml --use --
```

### Sequential build (nerdctl)

If apt stalls on the default Ubuntu archive mirror, add `--build-arg USE_FAST_UBUNTU_MIRROR=true` and `--build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/` to the Ubuntu-based build commands in this sequence.

```bash
sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base,push=true' \
  -f linux/Dockerfile.base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-base,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-base \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-compiler,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-compiler \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk,push=true' \
  -f linux/Dockerfile.sdk \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-sdk,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-sdk \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:media \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media,push=true' \
  -f linux/Dockerfile.media \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android,push=true' \
  -f linux/Dockerfile.android \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true' \
  -f linux/Dockerfile \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-latest,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-latest \
  . 2>&1 | tee -a output.log
```