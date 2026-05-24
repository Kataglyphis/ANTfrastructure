ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN test -d /opt/llvm-target
