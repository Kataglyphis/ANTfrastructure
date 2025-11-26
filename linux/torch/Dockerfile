
# syntax=docker/dockerfile:1.19

FROM ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
SHELL ["bash", "-lc"]

ENV VENV=/opt/venv
RUN --mount=type=cache,target=/root/.cache/uv uv venv --system-site-packages "${VENV}"
ENV VIRTUAL_ENV=${VENV}
ENV PATH=${VENV}/bin:${PATH}

# PyGObject via apt (visible in venv due to --system-site-packages)

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      python3-gi gir1.2-glib-2.0 gir1.2-gtk-3.0 \
    && rm -rf /var/lib/apt/lists/*

# Python packages (no pygobject from pip)

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/root/.cache/pip \
    set -eux; \
    uv pip install --upgrade pip setuptools wheel; \
    uv pip install numpy opencv-python tqdm; \
    uv pip install --index-url https://download.pytorch.org/whl/rocm6.4 \
      torch==2.9.0 torchvision==0.24.0 torchaudio==2.9.0; \
    python -c "import gi, cv2, torch; \
      import gi.repository as r; \
      print('gi OK'); print('cv2', cv2.__version__); \
      print('Gst typelibs path ok'); \
      print('torch', torch.__version__, 'cuda:', torch.cuda.is_available())"