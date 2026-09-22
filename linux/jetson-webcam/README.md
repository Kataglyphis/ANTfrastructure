# Jetson webcam object detection (PoC)

A USB camera, object detection on the Jetson's GPU, and the annotated video in
your browser. It runs in the arm64 GPU wrapper image — the same SBSA CUDA image
a server GPU uses — with nothing installed into the image.

```bash
bash linux/jetson-webcam/run.sh          # then open http://<jetson>:8080/
```

What it does: a capture thread reads the camera (V4L2, 30 fps) and keeps only
the newest frame; torchvision's SSDLite-MobileNetV3 (COCO, 80 classes) detects
on the GPU; the frames are served as MJPEG with boxes, labels, FPS and inference
time drawn in. The weights (13 MB) download once into `~/.cache/jetson-webcam`.

| Setting | Default |
|---|---|
| `JETSON_WEBCAM_CAMERA` | `/dev/video0` |
| `JETSON_WEBCAM_PORT` | `8080` |
| `JETSON_WEBCAM_IMAGE` | `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-hostarm64-arm64` |
| extra arguments | passed to `app.py`: `--threshold 0.5`, `--no-cuda-graph` |

Stop it with Ctrl-C, or `nerdctl stop jetson-webcam` when it runs detached.

## Prerequisites

`nvidia-container-toolkit`, and `crun` >= 1.2x in `~/.local/bin`. Why the run
needs three extra flags on a Jetson, and what fails without each:
[`docs/linux-host-setup.md` § B2b](../../docs/linux-host-setup.md#b2b-a-gpu-container-on-a-jetson-with-rootless-nerdctl).
`run.sh` stops with a message when a prerequisite is missing.

## Measured

Jetson AGX Orin, 640x480, `MODE_50W`, 2026-09-22:

| | stream | inference |
|---|---|---|
| torchvision's `model(frames)` | 9 fps | 100 ms |
| this app (`FastSSD`) | **30 fps** (the camera's limit) | **13 ms** |

Where the 100 ms went, measured on a still frame: 1 ms preprocessing, 29 ms
network, **182 ms postprocessing** (with the first app running beside it).
torchvision's postprocess loops over 90 classes in Python and launches tiny
kernels on a slow CPU while the GPU waits. `FastSSD` decodes every anchor at
once and runs one `batched_nms` (36 ms per frame), and replays the network from
a CUDA graph (12 ms). On a captured frame it returned the same classes, scores
and pixel boxes as torchvision.

Two things that cost frames and are easy to reintroduce:
`CAP_PROP_BUFFERSIZE=1` halves this camera to 15 fps (one V4L2 buffer cannot
capture while the last frame is dequeued), and MJPG capture reads corrupt JPEG
data from it; YUYV at 30 fps is clean.

The official PyTorch `cu130` wheels warn that they do not target compute
capability 8.7 (Orin). This model ran correctly anyway; another model may hit a
kernel that has no Orin code.
