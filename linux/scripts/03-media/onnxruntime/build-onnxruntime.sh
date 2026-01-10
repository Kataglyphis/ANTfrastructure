#!/usr/bin/env bash
set -euxo pipefail

ORT_VERSION="${ORT_VERSION:-v1.23.2}"
ORT_REPO="${ORT_REPO:-https://github.com/microsoft/onnxruntime.git}"
ORT_SRC_DIR="${ORT_SRC_DIR:-/opt/onnxruntime}"

# ------------------------------------------------------------------------------
# Concurrency limiting (similar to GStreamer build)
# ------------------------------------------------------------------------------
# Memory per compile job in MB — adjust if needed
PER_JOB_MB="${ORT_PER_JOB_MB:-1500}"

if [ -z "${JOBS:-}" ]; then
  CORES="$(nproc --all)"

  # Available RAM in MB (fallback 2048 MB)
  AVAIL_MB="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo)"
  [ -z "${AVAIL_MB}" ] && AVAIL_MB=2048

  MAX_BY_MEM=$(( AVAIL_MB / PER_JOB_MB ))
  [ "${MAX_BY_MEM}" -lt 1 ] && MAX_BY_MEM=1

  # JOBS = min(CORES, MAX_BY_MEM)
  if [ "${CORES}" -lt "${MAX_BY_MEM}" ]; then
    JOBS="${CORES}"
  else
    JOBS="${MAX_BY_MEM}"
  fi

  # Reserve one core for system if possible
  if [ "${JOBS}" -gt 1 ]; then
    JOBS=$((JOBS - 1))
  fi

  [ "${JOBS}" -lt 1 ] && JOBS=1
fi

export JOBS
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"
export MAKEFLAGS="-j${JOBS}"
echo "Using JOBS=${JOBS} (CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL}, per_job_mb=${PER_JOB_MB})"

# Dependencies for building ONNX Runtime
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git \
  cmake \
  python3-dev \
  python3-pip \
  build-essential \
  pkg-config \
  wget \
  ca-certificates \
  zlib1g-dev \
  protobuf-compiler \
  libprotobuf-dev

# Build ONNX Runtime
rm -rf "${ORT_SRC_DIR}"
git clone --depth 1 --branch "${ORT_VERSION}" "${ORT_REPO}" "${ORT_SRC_DIR}"
cd "${ORT_SRC_DIR}"

export PATH="/root/.local/bin:${PATH}"
command -v uv >/dev/null || (curl -LsSf https://astral.sh/uv/install.sh | sh)

uv python install 3.12 --default || true
uv pip install flatbuffers || true

uv run -- ./build.sh \
  --config Release \
  --build_shared_lib \
  --parallel "${JOBS}" \
  --allow_running_as_root \
  --use_xnnpack \
  --skip_onnx_tests --skip_tests

cmake --install build/Linux/Release --prefix /usr/local || true

rm -rf "${ORT_SRC_DIR}"
ldconfig
