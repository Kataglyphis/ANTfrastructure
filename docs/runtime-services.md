# Runtime Services and Streaming

## Webserver (Linux)

The webserver serves the **Kataglyphis web frontend** — a Flutter app with pages
for AI chat, blog posts, personal data, and an
open source license overview at `/openSourceLicenses`.

```bash
nerdctl build -t kataglyphis-webserver:latest -f linux/webserver/Dockerfile .
docker run -d --name kataglyphis-webserver \
  -p 8080:80 \
  -v "$(pwd)/linux/webserver/dist:/var/www/html" \
  -v "$(pwd)/linux/webserver/nginx.conf:/etc/nginx/nginx.conf:ro" \
  kataglyphis-webserver:latest
```

`linux/webserver/Dockerfile` does not currently expose the fast Ubuntu mirror build flag.

## Run with frontend display support

```bash
nerdctl run --rm -it \
  -e DISPLAY=$DISPLAY \
  -e WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
  -e XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
  -e PULSE_SERVER=$PULSE_SERVER \
  -v /mnt/wslg:/mnt/wslg \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v $XDG_RUNTIME_DIR:$XDG_RUNTIME_DIR \
  -v "$(pwd)":/workspace \
  --workdir /workspace \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
```

## Raspberry Pi Camera

[rpi-cam sources](https://www.raspberrypi.com/documentation/computers/camera_software.html#rpicam-apps)

```bash
# list if camera is available
v4l2-ctl --list-devices
```

## WebRTC Streaming

The container includes a WebRTC signalling server (`gst-webrtc-signalling-server`) for real-time video streaming.

### Firewall Configuration

Allow port 8443 for the WebRTC signalling server:

```bash
sudo ufw allow 8443/tcp
```

### Running the Signalling Server

The `beschleuniger` container starts the signalling server automatically on port 8443:

```bash
nerdctl compose -f linux/docker-compose.yml up -d beschleuniger
```

### Streaming from KataglyphisCppInference

The cppInference project includes WebRTC streaming support via GStreamer's `webrtcsink`:

```bash
# Build the project (inside container or on host with GStreamer)
cd /KataglyphisCppInference
cmake --preset=linux-release-clang
cmake --build build-release

# Stream with test pattern
./build-release/bin/KataglyphisCppInference --webrtc --source test --server ws://localhost:8443

# Stream from libcamera (Raspberry Pi camera)
./build-release/bin/KataglyphisCppInference --webrtc --source libcamera --server ws://localhost:8443

# Stream from V4L2 USB camera
./build-release/bin/KataglyphisCppInference --webrtc --source v4l2 --device /dev/video0 --server ws://localhost:8443
```

### CLI Options

```text
--webrtc                Start WebRTC streaming
--server <uri>          Signalling server URI (default: ws://127.0.0.1:8443)
--source <type>         Video source: libcamera, v4l2, test (default: libcamera)
--device <path>         V4L2 device path (default: /dev/video0)
--width <pixels>        Video width (default: 1280)
--height <pixels>       Video height (default: 720)
--fps <rate>            Framerate (default: 30)
--encoder <type>        Encoder: h264-hw, h264-sw, vp8, vp9 (default: h264-hw)
--bitrate <kbps>        Bitrate in kbps (default: 2000)
```

### Viewing the Stream

Open the webserver in your browser and use the GstWebRTC API to connect to the stream:

```text
http://localhost/javascript/webrtc/index.html
```

## Raw `gst-launch-1.0` pipelines (debugging below the app)

When `--webrtc` above fails, the useful next step is to reproduce the same
pipeline by hand. `gst-launch-1.0` bisects the problem: if the raw pipeline
works, the fault is in the application wiring; if it does not, the fault is in
the plugins, the encoder, or the camera.

First establish the environment is sane at all:

```bash
gst-launch-1.0 --version
gst-inspect-1.0                       # every plugin the runtime can see
gst-inspect-1.0 | grep -i h264        # ...or just the encoders
gst-launch-1.0 videotestsrc ! autovideosink
```

Prefix any pipeline with `GST_DEBUG=3` (or `4`) for negotiation failures — the
usual cause is a caps mismatch that the error message alone does not explain.

### Raspberry Pi camera → WebRTC

```bash
gst-launch-1.0 libcamerasrc ! \
  video/x-raw,width=640,height=360,format=NV12,interlace-mode=progressive ! \
  x264enc speed-preset=1 threads=1 byte-stream=true ! \
  h264parse ! \
  webrtcsink signaller::uri="ws://0.0.0.0:8444" name=ws meta="meta,name=gst-stream"
```

On a Pi 3 the USB/V4L2 path is the one that works:

```bash
gst-launch-1.0 v4l2src device=/dev/video0 ! \
  video/x-raw,width=1280,height=720,framerate=15/1 ! \
  webrtcsink signaller::uri="ws://0.0.0.0:8443" name=ws meta="meta,name=gst-stream"
```

### Recording to a file instead of streaming

Useful to prove the capture side independently of the network side:

```bash
gst-launch-1.0 v4l2src device=/dev/video50 ! \
  video/x-raw,width=640,height=480,framerate=30/1 ! \
  videoconvert ! \
  openh264enc ! h264parse ! \
  mp4mux ! filesink location=output.mp4
```

### MJPEG source → WebRTC

Cameras that only offer `image/jpeg` at the resolution you want need an explicit
decode step:

```bash
GST_DEBUG=3 gst-launch-1.0 -e \
  v4l2src device=/dev/video20 ! \
  image/jpeg,width=1280,height=720,framerate=5/1 ! \
  jpegdec ! videoconvert ! \
  video/x-raw,format=I420 ! \
  openh264enc ! \
  webrtcsink congestion-control=disabled \
    signaller::uri="ws://0.0.0.0:8443" name=ws meta="meta,name=webfrontend-stream"
```

### Hardware encoders that under-declare their caps

Some vendor encoders (`kyh264enc` on Rockchip-class boards among them) negotiate
successfully but emit caps too vague for `webrtcsink` to build an SDP from. The
fix is an explicit `capsfilter` after the encoder — spelling out the stream
format, profile and level the downstream element needs:

```bash
GST_DEBUG=4 gst-launch-1.0 -v -e \
  v4l2src device=/dev/video20 ! \
  video/x-raw,format=YUY2,width=1280,height=720,framerate=5/1 ! \
  videoconvert ! video/x-raw,format=NV12,width=1280,height=720,framerate=5/1 ! \
  kyh264enc ! h264parse config-interval=1 ! \
  capsfilter caps="video/x-h264,stream-format=(string)byte-stream,alignment=(string)au,profile=(string)main,level=(string)3.1,chroma-format=(string)4:2:0,bit-depth-luma=(uint)8,bit-depth-chroma=(uint)8,parsed=(boolean)true" ! \
  queue ! \
  webrtcsink congestion-control=disabled \
    signaller::uri="ws://0.0.0.0:8443" name=ws meta="meta,name=webfrontend-stream"
```

Bisect this one with `... ! kyh264enc ! fakesink` first — if that fails, the
encoder is the problem, not the sink.

### Basler industrial camera (Pylon)

```bash
gst-launch-1.0 -e \
  pylonsrc ! \
  video/x-raw,format=RGB,width=1920,height=1080,framerate=30/1 ! \
  videoconvert ! videoscale ! \
  video/x-raw,format=I420,width=1920,height=1080,framerate=30/1 ! \
  queue ! \
  vp8enc target-bitrate=6000000 deadline=1 cpu-used=6 threads=4 error-resilient=1 ! \
  webrtcsink signaller::uri="ws://0.0.0.0:8443" name=ws meta="meta,name=webfrontend-stream"
```

## Building GStreamer from source on a device

The images build GStreamer through
`linux/scripts/03-media/build/gstreamer/common/build-gstreamer-monorepo.sh`.
This section is for the case that script does not cover: building on a target
board to get a plugin the packaged runtime lacks.

```bash
git clone -b 1.24.10 https://gitlab.freedesktop.org/gstreamer/gstreamer.git
cd gstreamer
```

Install the build dependencies:

```bash
sudo apt install -y build-essential meson ninja-build git pkg-config \
  libglib2.0-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libdrm-dev libx11-dev libxv-dev libxext-dev \
  libasound2-dev libpulse-dev libv4l-dev libudev-dev libssl-dev \
  libx264-dev libx265-dev \
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
  libogg-dev libvorbis-dev libopus-dev libtheora-dev \
  libspeex-dev libmp3lame-dev libfaad-dev \
  libjack-jackd2-dev liba52-0.7.4-dev yasm
```

**Fetch the subprojects before configuring.** This step is easy to miss and the
resulting failure — a plugin silently absent from the build — does not point
back at it:

```bash
meson subprojects download
meson subprojects update
```

Then:

```bash
meson setup build \
  --prefix=/usr \
  -Dtests=disabled \
  -Dexamples=disabled \
  -Drs=enabled \
  -Dgpl=enabled \
  -Dbuildtype=release

meson compile -C build
sudo meson install -C build
sudo ldconfig
```

The Rust plugins (`-Drs=enabled`, which is where `webrtcsink` lives) land in the
cargo target directory rather than the system plugin path, so point GStreamer at
both:

```bash
export GST_PLUGIN_PATH="$HOME/gst-plugins-rs/target/release:/usr/lib/$(gcc -dumpmachine)/gstreamer-1.0${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}"
```

On a cross-built or multiarch rootfs the loader also needs the arch triplet
directory — `/usr/lib/aarch64-linux-gnu` on ARM64, `/usr/lib/riscv64-linux-gnu`
on RISC-V:

```bash
export LIBRARY_PATH="/usr/lib/$(gcc -dumpmachine):$LIBRARY_PATH"
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:$PKG_CONFIG_PATH
```

Confirm the plugin is actually visible before debugging a pipeline that uses it:

```bash
gst-inspect-1.0 webrtcsink
```

### Removing a previous source install

`meson install` scatters files across the prefix, and `ninja uninstall` is often
unavailable by the time you need it. On a cross rootfs the stale copies are also
arch-specific, so they sit in the triplet directory rather than `/usr/local/lib`:

```bash
# preview first — the -print before -delete is deliberate
sudo find /usr/local/lib/riscv64-linux-gnu -type f -name 'libgst*.so*' -print
sudo find /usr/local/lib/riscv64-linux-gnu -type f -name 'libgst*.so*' -print -delete
sudo ldconfig
```

Swap the triplet for the target you built (`aarch64-linux-gnu`,
`x86_64-linux-gnu`). Leaving stale `libgst*.so*` behind is a common cause of a
pipeline that loads the wrong plugin version and fails with a caps error that
makes no sense against the source you are reading.

### Prebuilt Android GStreamer

The Android lane consumes the upstream universal tarball rather than building
it. Unpack it where `Dockerfile.android` expects to find it:

```bash
sudo mkdir -p /opt/android/gstreamer
sudo tar -xf gstreamer-1.0-android-universal-1.26.7.tar.xz -C /opt/android/gstreamer
```

Keep the version aligned with the pin in `linux/scripts/01-core/versions.env` —
a mismatch here surfaces much later as a link error in the Android stage.
