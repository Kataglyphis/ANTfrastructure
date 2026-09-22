# Jetson webcam object detection (PoC)

A USB camera, object detection on the Jetson's GPU, and the annotated video in
your browser. It runs in the arm64 GPU wrapper image — the same SBSA CUDA image
a server GPU uses — with nothing installed into the image.

```bash
bash linux/jetson-webcam/run.sh          # then open http://<jetson>:8080/
```

What it does: OpenCV reads the camera (V4L2), torchvision's SSDLite-MobileNetV3
(COCO, 80 classes) detects on the GPU, and the frames are served as MJPEG with
boxes, labels, FPS and inference time drawn in. The weights (13 MB) download
once into `~/.cache/jetson-webcam`.

| Setting | Default |
|---|---|
| `JETSON_WEBCAM_CAMERA` | `/dev/video0` |
| `JETSON_WEBCAM_PORT` | `8080` |
| `JETSON_WEBCAM_IMAGE` | `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-hostarm64-arm64` |
| extra arguments | passed to `app.py`: `--threshold 0.5`, `--device cpu` |

Stop it with Ctrl-C, or `nerdctl stop jetson-webcam` when it runs detached.

## Prerequisites

`nvidia-container-toolkit`, and `crun` >= 1.2x in `~/.local/bin`. Why the run
needs three extra flags on a Jetson, and what fails without each:
[`docs/linux-host-setup.md` § B2b](../../docs/linux-host-setup.md#b2b-a-gpu-container-on-a-jetson-with-rootless-nerdctl).
`run.sh` stops with a message when a prerequisite is missing.

## Measured

Jetson AGX Orin, 640x480, `MODE_50W`, 2026-09-22: a person detected at 0.93,
about 9 fps, 100 ms per inference. The loop is CPU-bound: one core at 87 %, the
GPU at 20-35 %. `sudo jetson_clocks` raises the clocks this runs at.

The official PyTorch `cu130` wheels warn that they do not target compute
capability 8.7 (Orin). This model ran correctly anyway; another model may hit a
kernel that has no Orin code.
