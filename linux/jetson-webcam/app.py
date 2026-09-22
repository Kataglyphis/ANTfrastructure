"""Webcam object detection on the GPU, streamed to a browser as MJPEG.

Capture with OpenCV (V4L2), detect with torchvision's SSDLite-MobileNetV3 (COCO),
serve the annotated frames on http://<host>:<port>/. See README.md.
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

PAGE = b"""<!doctype html><title>Jetson webcam</title>
<body style="margin:0;background:#111"><img src="/stream" style="width:100%"></body>"""


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--camera", default="/dev/video0")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--threshold", type=float, default=0.5)
    p.add_argument("--device", default="cuda", help="cuda or cpu")
    return p.parse_args()


class Latest:
    """The newest annotated JPEG, handed from the inference loop to every client."""

    def __init__(self):
        self.cond = threading.Condition()
        self.jpeg = None

    def put(self, jpeg):
        with self.cond:
            self.jpeg = jpeg
            self.cond.notify_all()

    def wait(self):
        with self.cond:
            self.cond.wait(timeout=2)
            return self.jpeg


def inference_loop(args, latest):
    if args.device == "cuda" and not torch.cuda.is_available():
        raise SystemExit("CUDA not available -- start the container with the GPU (see README.md)")
    dev = torch.device(args.device)
    weights = SSDLite320_MobileNet_V3_Large_Weights.DEFAULT
    model = torchvision.models.detection.ssdlite320_mobilenet_v3_large(weights=weights).eval().to(dev)
    labels = weights.meta["categories"]
    name = torch.cuda.get_device_name(0) if dev.type == "cuda" else "CPU"
    print(f"model on {name}", flush=True)

    cap = cv2.VideoCapture(args.camera, cv2.CAP_V4L2)
    if not cap.isOpened():
        raise SystemExit(f"cannot open {args.camera}")

    fps, last = 0.0, time.perf_counter()
    with torch.inference_mode():
        while True:
            ok, frame = cap.read()
            if not ok:
                time.sleep(0.05)
                continue
            rgb = torch.from_numpy(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)).to(dev)
            t0 = time.perf_counter()
            out = model([rgb.permute(2, 0, 1).float() / 255])[0]
            if dev.type == "cuda":
                torch.cuda.synchronize()
            infer_ms = (time.perf_counter() - t0) * 1000

            keep = out["scores"] >= args.threshold
            for box, label, score in zip(out["boxes"][keep].tolist(),
                                         out["labels"][keep].tolist(),
                                         out["scores"][keep].tolist()):
                x1, y1, x2, y2 = map(int, box)
                cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 220, 0), 2)
                cv2.putText(frame, f"{labels[label]} {score:.2f}", (x1, max(y1 - 6, 12)),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 220, 0), 1)

            now = time.perf_counter()
            fps = 0.9 * fps + 0.1 / max(now - last, 1e-6)
            last = now
            cv2.putText(frame, f"{name} | {fps:4.1f} fps | infer {infer_ms:5.1f} ms",
                        (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
            latest.put(cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])[1].tobytes())


def make_handler(latest):
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
            try:
                while True:
                    jpeg = latest.wait()
                    if jpeg is None:
                        continue
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + jpeg + b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_):
            pass

    return Handler


def run_or_die(args, latest):
    # A dead inference thread must stop the server, not leave it streaming nothing.
    try:
        inference_loop(args, latest)
    except BaseException as exc:  # noqa: BLE001 -- report whatever killed it, then exit
        print(f"inference stopped: {exc}", flush=True)
        os._exit(1)


def main():
    args = parse_args()
    latest = Latest()
    threading.Thread(target=run_or_die, args=(args, latest), daemon=True).start()
    print(f"open http://<this-host>:{args.port}/", flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(latest)).serve_forever()


if __name__ == "__main__":
    main()
