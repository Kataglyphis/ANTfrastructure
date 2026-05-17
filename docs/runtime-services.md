# Runtime Services and Streaming

## Webserver (Linux)

```bash
docker build -t kataglyphis-webserver:latest -f linux/webserver/Dockerfile .
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
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
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
docker-compose up -d beschleuniger
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