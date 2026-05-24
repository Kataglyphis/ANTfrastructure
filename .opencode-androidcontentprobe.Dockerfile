ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN set -eux; \
    test -d /opt/llvm-target; \
    ls -ld /usr /usr/local /usr/local/lib || true; \
    test -d /usr/local/lib/onnxruntime-cpu
