"""Webcam object detection on the GPU, streamed to a browser as MJPEG.

A capture thread keeps the newest camera frame; the inference loop runs
torchvision's SSDLite-MobileNetV3 (COCO) with the network in one CUDA graph and
a vectorized postprocess, and serves annotated frames on http://<host>:<port>/.
Why the fast path exists and what it measured: README.md.
"""

import argparse
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import torch
import torchvision
from torchvision.models.detection import SSDLite320_MobileNet_V3_Large_Weights
from torchvision.ops import batched_nms

PAGE = b"""<!doctype html><title>Jetson webcam</title>
<body style="margin:0;background:#111"><img src="/stream" style="width:100%"></body>"""
SIZE = 320  # SSDLite320's fixed input side


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--camera", default="/dev/video0")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--threshold", type=float, default=0.5)
    p.add_argument("--no-cuda-graph", action="store_true", help="launch the network op by op")
    return p.parse_args()


class Latest:
    """The newest item, handed from one producer to any number of waiting consumers."""

    def __init__(self):
        self.cond = threading.Condition()
        self.item, self.seq = None, 0

    def put(self, item):
        with self.cond:
            self.item, self.seq = item, self.seq + 1
            self.cond.notify_all()

    def wait_newer(self, seen):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != seen, timeout=2)
            return self.item, self.seq


class FastSSD:
    """SSDLite's backbone+head replayed from a CUDA graph, then one batched NMS.

    torchvision's own postprocess loops over 90 classes in Python and spent
    80 % of each frame launching tiny kernels; this returns the same boxes.
    """

    def __init__(self, model, dev, cuda_graph=True):
        self.m = model
        self.static_in = torch.zeros(1, 3, SIZE, SIZE, device=dev)
        with torch.inference_mode():
            imgs, _ = model.transform([torch.zeros(3, SIZE, SIZE, device=dev)])
            feats = list(model.backbone(imgs.tensors).values())
            self.anchors = model.anchor_generator(imgs, feats)[0]
        self.graph = None
        if cuda_graph:
            side = torch.cuda.Stream()
            side.wait_stream(torch.cuda.current_stream())
            with torch.cuda.stream(side), torch.inference_mode():
                for _ in range(3):  # warm up allocations before capture
                    self._net()
            torch.cuda.current_stream().wait_stream(side)
            self.graph = torch.cuda.CUDAGraph()
            with torch.cuda.graph(self.graph), torch.inference_mode():
                self.static_out = self._net()

    def _net(self):
        head = self.m.head(list(self.m.backbone(self.static_in).values()))
        return head["bbox_regression"][0], head["cls_logits"][0]

    @torch.inference_mode()
    def __call__(self, rgb_u8, threshold, iou=0.55, top=100):
        h, w = rgb_u8.shape[:2]
        x = rgb_u8.permute(2, 0, 1).unsqueeze(0).float().div_(255)
        x = torch.nn.functional.interpolate(x, size=(SIZE, SIZE), mode="bilinear", align_corners=False)
        self.static_in.copy_((x - 0.5) / 0.5)  # SSDLite's own mean/std
        if self.graph is not None:
            self.graph.replay()
            reg, logits = self.static_out
        else:
            reg, logits = self._net()
        boxes = self.m.box_coder.decode_single(reg, self.anchors).clamp_(0, SIZE)
        scores = torch.softmax(logits, -1)[:, 1:]  # drop background
        anchor, cls = (scores > threshold).nonzero(as_tuple=True)
        boxes, scores, labels = boxes[anchor], scores[anchor, cls], cls + 1
        keep = batched_nms(boxes, scores, labels, iou)[:top]
        scale = torch.tensor([w / SIZE, h / SIZE, w / SIZE, h / SIZE], device=boxes.device)
        return (boxes[keep] * scale).tolist(), labels[keep].tolist(), scores[keep].tolist()


def capture_loop(camera, frames):
    cap = cv2.VideoCapture(camera, cv2.CAP_V4L2)
    if not cap.isOpened():
        raise SystemExit(f"cannot open {camera}")
    # No CAP_PROP_BUFFERSIZE=1: one V4L2 buffer halved the camera to 15 fps.
    # Freshness comes from this thread handing on only the newest frame.
    cap.set(cv2.CAP_PROP_FPS, 30)
    while True:
        ok, frame = cap.read()
        if ok:
            frames.put(frame)
        else:
            time.sleep(0.05)


def inference_loop(args, frames, jpegs):
    if not torch.cuda.is_available():
        raise SystemExit("CUDA not available -- start the container with the GPU (see README.md)")
    dev = torch.device("cuda")
    weights = SSDLite320_MobileNet_V3_Large_Weights.DEFAULT
    model = torchvision.models.detection.ssdlite320_mobilenet_v3_large(weights=weights).eval().to(dev)
    detect = FastSSD(model, dev, cuda_graph=not args.no_cuda_graph)
    labels, gpu = weights.meta["categories"], torch.cuda.get_device_name(0)
    print(f"model on {gpu}, cuda graph {'off' if args.no_cuda_graph else 'on'}", flush=True)

    fps, last, seen = 0.0, time.perf_counter(), 0
    while True:
        frame, seen = frames.wait_newer(seen)
        if frame is None:
            continue
        rgb = torch.from_numpy(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)).to(dev, non_blocking=True)
        t0 = time.perf_counter()
        boxes, classes, scores = detect(rgb, args.threshold)  # .tolist() syncs the GPU
        infer_ms = (time.perf_counter() - t0) * 1000

        for (x1, y1, x2, y2), c, s in zip(boxes, classes, scores):
            cv2.rectangle(frame, (int(x1), int(y1)), (int(x2), int(y2)), (0, 220, 0), 2)
            cv2.putText(frame, f"{labels[c]} {s:.2f}", (int(x1), max(int(y1) - 6, 12)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 220, 0), 1)
        now = time.perf_counter()
        fps = 0.9 * fps + 0.1 / max(now - last, 1e-6)
        last = now
        cv2.putText(frame, f"{gpu} CUDA | {fps:4.1f} fps | infer {infer_ms:4.1f} ms",
                    (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
        jpegs.put(cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])[1].tobytes())


def make_handler(jpegs):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/stream":
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(PAGE)
                return
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.end_headers()
            seen = 0
            try:
                while True:
                    jpeg, seen = jpegs.wait_newer(seen)
                    if jpeg is not None:
                        self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + jpeg + b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_):
            pass

    return Handler


def run_or_die(target, *args):
    # A dead worker thread must stop the server, not leave it streaming nothing.
    try:
        target(*args)
    except BaseException as exc:  # noqa: BLE001 -- report whatever killed it, then exit
        print(f"{target.__name__} stopped: {exc}", flush=True)
        os._exit(1)


def main():
    args = parse_args()
    frames, jpegs = Latest(), Latest()
    threading.Thread(target=run_or_die, args=(capture_loop, args.camera, frames), daemon=True).start()
    threading.Thread(target=run_or_die, args=(inference_loop, args, frames, jpegs), daemon=True).start()
    print(f"open http://<this-host>:{args.port}/", flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(jpegs)).serve_forever()


if __name__ == "__main__":
    main()
